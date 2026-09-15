// ReadOnlyStore.swift — la troisième ceinture de la lecture seule.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// TROIS CEINTURES, et il en faut trois parce qu'elles ne protègent pas des
// mêmes fautes :
//
//  1. `SQLITE_OPEN_READONLY` (`Configuration.readonly`, `GRDBStore.openReadOnly`)
//     — **SQLite refuse**. C'est la seule qui tienne contre une écriture qu'on
//     n'aurait pas vue, y compris dans du code de FouineCore appelé
//     indirectement. (Pas `PRAGMA query_only` : GRDB le remet à 0 à la sortie
//     de chaque lecture — voir l'en-tête d'`openReadOnly`.)
//  2. `ReadOnlyStore` — **le compilateur refuse**. C'est ce fichier : il
//     enveloppe un `GRDBStore` et n'en republie que des lectures. Aucun outil
//     de `FouineMCP` ne peut appeler `upsertDoc`, `replacePages` ou
//     `removeRoot`, parce que ces noms n'existent pas ici. Une discipline se
//     relâche ; un mur de types, non.
//  3. Aucun outil d'écriture déclaré — **le modèle ne peut pas demander**.
//     Pas de `fouine_index`, pas de `fouine_add_root`. C'est un choix : un
//     agent qui pourrait lancer une indexation consommerait la batterie, la
//     thermique et le disque de l'utilisateur sans qu'il l'ait demandé, et
//     `root remove` est un geste destructeur. `fouine_status` dit ce qui
//     manque ; l'utilisateur agit dans l'application.
//
// OUVERTURE PARESSEUSE (CM-07). Construire un `ReadOnlyStore` n'ouvre rien :
// la base est ouverte à la première lecture, et une ouverture qui échoue est
// RÉESSAYÉE plus tard. C'est ce qui permet à `initialize` et à `tools/list` de
// répondre alors qu'il n'y a pas d'index lisible — un client qui affiche
// « serveur déconnecté » ne montre jamais la phrase qui porte le geste.
//
// SURFACE. Une ligne par méthode, toutes lectures. Deux d'entre elles font
// exception au « republier tel quel » et sont commentées à leur place :
//
//   · `hybrid(…)` — `HybridSearch.run` prend un `GRDBStore`, pas un
//     `ReadOnlyStore`. Plutôt que de rendre le magasin interne (ce qui
//     abattrait le mur de types du point 2 ci-dessus), on expose l'APPEL :
//     le `GRDBStore` reste privé, et le seul chemin qui y mène de l'extérieur
//     est une recherche.
//   · `vectorisedPageCount()` / `vectorisedPageCounts(forDocIDs:)` — le POINT
//     UNIQUE où « des vecteurs » devient « des pages ». Voir leur commentaire :
//     c'est là, et nulle part ailleurs dans le serveur, que le fenêtrage v5
//     (plusieurs vecteurs par page) interviendra.

import Foundation
import FouineCore
import FouineEmbed

public final class ReadOnlyStore {

    public let databaseURL: URL

    /// Les racines que ce serveur a le droit de servir (`fouine mcp --folders`),
    /// telles que l'utilisateur les a écrites ; `nil` = tout l'index.
    ///
    /// LE PÉRIMÈTRE S'APPLIQUE ICI, ET NULLE PART AILLEURS (lot IG1, PM-01).
    /// Un filtre posé dans les outils serait à reprendre dans chaque outil
    /// ajouté ensuite, et le premier oubli rendrait un document d'un dossier
    /// que l'utilisateur croyait hors de portée. Ce fichier est déjà le point
    /// unique des lectures : c'est donc le seul endroit où le périmètre puisse
    /// être VRAI, y compris pour un outil qui n'existe pas encore.
    public let requestedFolders: [String]?

    /// Délai minimal entre deux tentatives d'ouverture ratées. Voir `opened()`.
    private let retryInterval: TimeInterval
    private let mutex = NSLock()
    private var store: GRDBStore?
    private var lastFailure: (error: Error, at: Date)?
    /// Les étiquettes du périmètre ramenées à leur écriture réelle, une fois
    /// que la base a pu être lue. Voir `scopeFolders()`.
    private var resolvedFolders: [String]?

    /// N'OUVRE RIEN. C'est le correctif CM-07 : jusqu'ici l'ouverture se faisait
    /// dans ce constructeur, donc avant `router.serve`, et une base absente, d'un
    /// autre schéma ou dont le journal d'écriture attendait un écrivain tuait le
    /// processus AVANT la première réponse. Le client n'affichait alors que
    /// « serveur déconnecté », sans un mot, et la phrase qui porte le geste
    /// partait sur une sortie d'erreur que personne ne sait où chercher.
    ///
    /// - Parameter retryInterval: on réessaie l'ouverture à la demande suivante,
    ///   mais au plus une fois par intervalle : la base peut apparaître pendant
    ///   que le serveur tourne (l'utilisateur indexe enfin un dossier), et
    ///   rouvrir un `DatabaseQueue` à chaque appel d'outil pour relire la même
    ///   panne coûterait sans rien apprendre.
    /// - Parameter folders: étiquettes des racines à servir (`--folders`), ou
    ///   `nil` pour tout l'index. Elles ne sont PAS vérifiées ici : le
    ///   constructeur n'ouvre rien, et une étiquette inconnue doit se dire par
    ///   une erreur d'outil qui nomme les racines existantes, pas par un
    ///   processus qui meurt avant `initialize` (CM-07).
    public init(path: URL, retryInterval: TimeInterval = 60,
                folders: [String]? = nil) {
        self.databaseURL = path
        self.retryInterval = retryInterval
        self.requestedFolders = folders.map { $0.filter { !$0.isEmpty } }
    }

    /// Le magasin ouvert, ou l'erreur d'ouverture — celle que l'utilisateur doit
    /// lire, avec son geste (`GRDBStore.noIndexMessage`, `schemaMismatch`,
    /// `cantOpenGuidance`).
    private func opened() throws -> GRDBStore {
        mutex.lock()
        defer { mutex.unlock() }
        if let store { return store }
        if let failure = lastFailure,
           Date().timeIntervalSince(failure.at) < retryInterval {
            throw failure.error
        }
        let candidate = GRDBStore()
        do {
            try candidate.openReadOnly(at: databaseURL)
        } catch {
            lastFailure = (error, Date())
            throw error
        }
        lastFailure = nil
        store = candidate
        return candidate
    }

    /// Ouvre si ce n'est pas déjà fait. C'est par là que passent le journal de
    /// démarrage et le veto d'avant-appel : eux seuls ont besoin de connaître
    /// l'échec sans avoir de lecture à faire.
    public func ensureOpen() throws { _ = try opened() }

    // MARK: - Périmètre (lot IG1, constat PM-01)

    /// Les étiquettes du périmètre, ramenées à leur écriture réelle, ou `nil`
    /// quand tout l'index est servi.
    ///
    /// La canonisation passe par `FolderCheck`, comme partout : `--folders
    /// livres` sert `Livres`, et une étiquette qui ne nomme aucune racine lève
    /// `QueryError.unknownFolder` EN NOMMANT celles qui existent. Elle est
    /// faite à la première lecture, pas dans le constructeur : la base peut
    /// n'être lisible que plus tard (ouverture paresseuse), et le refus doit
    /// alors atteindre le modèle par une erreur d'outil.
    private func scopeFolders() throws -> [String]? {
        guard let requestedFolders, !requestedFolders.isEmpty else { return nil }
        mutex.lock()
        if let resolvedFolders { mutex.unlock(); return resolvedFolders }
        mutex.unlock()
        let resolved = try FolderCheck.resolve(requestedFolders,
                                               known: try opened().roots().map(\.label))
        mutex.lock(); resolvedFolders = resolved; mutex.unlock()
        return resolved
    }

    /// La phrase à opposer à TOUT appel d'outil quand `--folders` nomme une
    /// racine qui n'existe pas, `nil` sinon. Une panne d'ouverture n'en est pas
    /// une : elle est déjà dite par `openRefusal`, et la redire ici masquerait
    /// le geste à faire.
    public func scopeRefusal() -> String? {
        do {
            _ = try scopeFolders()
            return nil
        } catch let error as QueryError {
            return error.errorDescription ?? "unknown folder in --folders"
        } catch {
            return nil
        }
    }

    /// Le périmètre effectivement servi, étiquettes réelles — ce que publie
    /// `fouine_status.scope`. `nil` = tout l'index.
    public func servedFolders() throws -> [String]? { try scopeFolders() }

    /// Les racines demandées CROISÉES avec le périmètre.
    ///
    /// Une intersection VIDE ne devient jamais « aucun filtre » — ce serait
    /// servir tout l'index à qui a demandé le dossier qu'on protège. Elle lève,
    /// avec la phrase de `FolderCheck` qui ne nomme QUE les racines servies :
    /// pour le modèle, un dossier hors périmètre n'existe pas.
    private func intersect(_ asked: [String], with scope: [String]) throws -> [String] {
        guard !asked.isEmpty else { return scope }
        let kept = asked.filter { label in
            scope.contains { $0.lowercased() == label.lowercased() }
        }
        guard !kept.isEmpty else {
            throw QueryError.unknownFolder(asked[0], known: scope.sorted())
        }
        return kept
    }

    /// La requête, restreinte au périmètre. Point de passage de `search`, du
    /// canal des noms, des facettes et des deux appels sémantiques.
    private func scoped(_ query: SearchQuery) throws -> SearchQuery {
        guard let scope = try scopeFolders() else { return query }
        var out = query
        out.folders = try intersect(query.folders, with: scope)
        return out
    }

    /// Ceux de ces documents que le périmètre laisse voir. `nil` = pas de
    /// périmètre, donc tous. UNE requête, quel que soit le nombre de documents.
    private func visible(_ ids: [Int64]) throws -> Set<Int64>? {
        guard let scope = try scopeFolders(), !ids.isEmpty else { return nil }
        return try opened().docIDsMatchingFilters(folders: scope, exts: [],
                                                  inDocIDs: ids,
                                                  excludingDocsMatching: nil)
            ?? Set(ids)
    }

    /// Ce document est-il servi ? Hors périmètre, il est INCONNU — le même
    /// refus qu'un `doc_id` qui n'existe pas. Dire « il existe mais vous n'y
    /// avez pas droit » apprendrait au modèle ce que le périmètre cache.
    private func isVisible(_ id: Int64) throws -> Bool {
        guard let scope = try scopeFolders() else { return true }
        guard let row = try opened().docRow(id: id) else { return false }
        return scope.contains { $0.lowercased() == row.record.topFolder.lowercased() }
    }

    /// Ces identifiants, privés de ceux que le périmètre cache.
    private func inScope(_ ids: [Int64]) throws -> [Int64] {
        guard let visible = try visible(ids) else { return ids }
        return ids.filter { visible.contains($0) }
    }

    /// Idem pour des rowids de PAGE : le document se lit dans le rowid
    /// structuré (§4.1), sans une requête de plus.
    private func inScope(pageRowIDs rowids: [Int64]) throws -> [Int64] {
        guard try scopeFolders() != nil else { return rowids }
        let visible = try visible(rowids.map(Self.docID(ofPageRowID:)))
        guard let visible else { return rowids }
        return rowids.filter { visible.contains(Self.docID(ofPageRowID: $0)) }
    }

    /// Le document d'une page, depuis son rowid structuré (§4.1).
    private static func docID(ofPageRowID rowid: Int64) -> Int64 {
        rowid / Schema.pagesPerDocLimit
    }

    // MARK: - Lectures

    /// `stats()` ne balaie plus `page_fts` depuis le correctif C2-03 : le
    /// compte de pages vient de la table d'ombre `page_fts_docsize`, mesurée
    /// 127× moins chère. C'est ce qui rend `fouine_status` tenable — un outil
    /// de statut qui bloquait seize secondes est un outil que le modèle cesse
    /// d'appeler.
    public func stats() throws -> [String: Int] { try opened().stats() }

    /// Les racines SERVIES. C'est d'elles que `FolderCheck` tire la liste
    /// qu'il nomme dans ses refus (`SearchTool`), et c'est ce qui fait qu'un
    /// `folder` hors périmètre est refusé en ne nommant que le périmètre.
    public func roots() throws -> [RootRecord] {
        let all = try opened().roots()
        guard let scope = try scopeFolders() else { return all }
        return all.filter { root in
            scope.contains { $0.lowercased() == root.label.lowercased() }
        }
    }

    public func ocrQueueLength() throws -> Int { try opened().ocrQueueLength() }

    public func vecMeta() throws -> [String: String] { try opened().vecMeta() }

    // MARK: - Valeurs connues d'un filtre (CM-11)

    /// Les langues présentes dans le PÉRIMÈTRE SERVI. Sert à REFUSER un `lang`
    /// inconnu en nommant les vraies, comme `roots()` sert à refuser un
    /// `folder` inconnu — et comme `roots()`, elle ne nomme que ce que
    /// `--folders` laisse voir (lot MN1, reste d'IG1) : une langue qui n'existe
    /// que hors périmètre n'y est pas, sans quoi le refus apprend au modèle
    /// qu'il y a des documents derrière le périmètre.
    public func knownLanguages() throws -> [String] {
        guard let scope = try scopeFolders() else { return try opened().knownLanguages() }
        return try opened().knownLanguages(inFolders: scope)
    }

    /// Ceux de ces identifiants qui ne désignent aucun document.
    public func unknownDocIDs(_ ids: [Int64]) throws -> [Int64] {
        let unknown = try opened().unknownDocIDs(ids)
        guard let visible = try visible(ids) else { return unknown }
        // Hors périmètre = inconnu, mot pour mot : c'est ce refus-là que le
        // modèle lit, et il ne doit pas pouvoir distinguer les deux cas.
        return (Set(unknown).union(ids.filter { !visible.contains($0) })).sorted()
    }

    // MARK: - Recherche

    public func search(_ q: SearchQuery,
                       excludingDocsMatching negative: String?) throws -> SearchResults {
        try opened().search(try scoped(q), excludingDocsMatching: negative)
    }

    /// Les documents dont le NOM DE FICHIER répond (lot MP1, PR-02). À part de
    /// `search` parce que le canal hybride ne passe pas par elle : c'est
    /// `HybridSearch.run` qui appelle le canal lexical, et son type de retour
    /// ne porte pas ce champ.
    public func documentsMatchingName(_ q: SearchQuery,
                                      limit: Int = 5) throws -> [DocumentListing] {
        try opened().documentsMatchingName(try scoped(q), limit: limit)
    }

    public func facets(_ q: SearchQuery, by key: FacetKey,
                       excludingDocsMatching negative: String?) throws -> [(String, Int)] {
        try opened().facets(try scoped(q), by: key, excludingDocsMatching: negative)
    }

    public func docIDsMatchingFilters(folders: [String], exts: [String],
                                      inDocIDs: [Int64],
                                      excludingDocsMatching negative: String?)
        throws -> Set<Int64>? {
        var folders = folders
        if let scope = try scopeFolders() {
            folders = try intersect(folders, with: scope)
        }
        return try opened().docIDsMatchingFilters(folders: folders, exts: exts,
                                                  inDocIDs: inDocIDs,
                                                  excludingDocsMatching: negative)
    }

    // MARK: - Documents et pages

    /// `nil` pour un document hors périmètre, exactement comme pour un
    /// identifiant qui n'existe pas : les outils qui lisent une page
    /// (`fouine_read_page`, `fouine_similar_pages`) refusent déjà sur ce `nil`
    /// avec la bonne phrase, et n'ont rien à savoir du périmètre.
    public func docRow(id: Int64) throws -> DocRow? {
        guard let row = try opened().docRow(id: id) else { return nil }
        guard let scope = try scopeFolders() else { return row }
        return scope.contains { $0.lowercased() == row.record.topFolder.lowercased() }
            ? row : nil
    }

    public func docs(underRoot rootID: Int64) throws -> [DocRow] {
        guard try roots().contains(where: { $0.id == rootID }) else { return [] }
        return try opened().docs(underRoot: rootID)
    }

    /// `DocumentFilter.folder` ne porte QU'UNE étiquette (il répond à
    /// `fouine_list_documents.folder`), là où un périmètre peut en servir
    /// plusieurs. Un périmètre de plusieurs racines se liste donc en une
    /// requête PAR racine, fusionnées dans l'ordre demandé avant d'en découper
    /// la fenêtre : chaque requête rend déjà ses `offset + limit` premières
    /// lignes dans l'ordre TOTAL de `DocumentOrder`, et la fusion d'ordres
    /// totaux est exacte. Le coût est celui de k requêtes paginées par SQLite,
    /// jamais celui d'un listage complet en mémoire.
    public func listDocuments(_ filter: DocumentFilter, order: DocumentOrder,
                              limit: Int, offset: Int) throws -> [DocumentListing] {
        guard let scope = try scopeFolders() else {
            return try opened().listDocuments(filter, order: order,
                                              limit: limit, offset: offset)
        }
        let folders = try intersect(filter.folder.map { [$0] } ?? [], with: scope)
        if folders.count == 1 {
            var scopedFilter = filter
            scopedFilter.folder = folders[0]
            return try opened().listDocuments(scopedFilter, order: order,
                                              limit: limit, offset: offset)
        }
        var rows: [DocumentListing] = []
        for label in folders {
            var scopedFilter = filter
            scopedFilter.folder = label
            rows += try opened().listDocuments(scopedFilter, order: order,
                                               limit: limit + offset, offset: 0)
        }
        return Array(rows.sorted(by: Self.before(order)).dropFirst(offset).prefix(limit))
    }

    /// L'ordre TOTAL de `DocumentOrder`, recopié pour la fusion ci-dessus — il
    /// vit en SQL dans `GRDBStore+Documents` et SQLite ne sait pas fusionner
    /// deux de ses propres résultats. Chaque cas se termine par `id`, comme la
    /// clause SQL : c'est ce qui en fait un ordre total, et donc une pagination
    /// qui ne saute ni ne double de ligne. `ScopeTests` compare les deux.
    private static func before(_ order: DocumentOrder)
        -> (DocumentListing, DocumentListing) -> Bool {
        switch order {
        case .path:
            return { $0.relPath == $1.relPath ? $0.id < $1.id : $0.relPath < $1.relPath }
        case .pages:
            return { $0.nPages == $1.nPages ? $0.id < $1.id : $0.nPages > $1.nPages }
        case .recent:
            return { $0.mtime == $1.mtime ? $0.id < $1.id : $0.mtime > $1.mtime }
        }
    }

    public func countDocuments(_ filter: DocumentFilter) throws -> Int {
        guard let scope = try scopeFolders() else {
            return try opened().countDocuments(filter)
        }
        var total = 0
        for label in try intersect(filter.folder.map { [$0] } ?? [], with: scope) {
            var scopedFilter = filter
            scopedFilter.folder = label
            total += try opened().countDocuments(scopedFilter)
        }
        return total
    }

    public func ocrPageCounts(forDocIDs ids: [Int64]) throws -> [Int64: Int] {
        try opened().ocrPageCounts(forDocIDs: try inScope(ids))
    }

    /// Pages de TEXTE par document (lot MC2, PM-19) : la frontière entre les
    /// diapositives d'un `.pptx` et les images qu'il incorpore, lue là où elle
    /// est déjà — `page_src`.
    public func textPageCounts(forDocIDs ids: [Int64]) throws -> [Int64: Int] {
        try opened().textPageCounts(forDocIDs: try inScope(ids))
    }

    public func pagePreviews(for rowids: [Int64], maxChars: Int, offset: Int = 0)
        throws -> [Int64: (relPath: String, preview: String, totalChars: Int)] {
        try opened().pagePreviews(for: try inScope(pageRowIDs: rowids),
                                  maxChars: maxChars, offset: offset)
    }

    public func pageMeta(for keys: [(docID: Int64, page: Int)]) throws
        -> [Int64: (source: PageSource, engine: OCREngineID, conf: Double?)] {
        guard let visible = try visible(keys.map(\.docID)) else {
            return try opened().pageMeta(for: keys)
        }
        return try opened().pageMeta(for: keys.filter { visible.contains($0.docID) })
    }

    public func ocrLayout(docID: Int64, page: Int) throws -> [OCRLine]? {
        guard try isVisible(docID) else { return nil }
        return try opened().ocrLayout(docID: docID, page: page)
    }

    /// Dénominateur de la couverture sémantique : pages indexées, comptées sur
    /// la table d'ombre `page_fts_docsize` (0,13 s contre 16,5 s, C2-03).
    public func indexedPageCount() throws -> Int { try opened().indexedPageCount() }

    // MARK: - Pages vectorisées — LE POINT UNIQUE (fenêtrage v5)

    /// Nombre de pages portant un vecteur, pour tout l'index.
    ///
    /// Fenêtrage v5 (fusionné le même jour) : `vectorCount()` compte des
    /// LIGNES de `page_vec`, c'est-à-dire des FENÊTRES ; les pages que le canal
    /// sémantique voit sont celles qui portent une fenêtre 0, et c'est
    /// `GRDBStore.vectorisedPageCount()` qui les compte. Tout ce que le serveur
    /// MCP annonce en pages — `semantic_coverage_pct`, `coverage_pct`,
    /// `vector_coverage_pct` de `fouine_status` — passe par ici.
    ///
    /// Le compte de FRAÎCHEUR de l'index vectoriel, lui, ne passe PAS par ici :
    /// `SemanticEngine` compare des lignes à des lignes (`vectorLineCount()`
    /// contre `index.count`), et c'est ce qu'il doit continuer de faire.
    public func vectorisedPageCount() throws -> Int { try opened().vectorisedPageCount() }

    /// Idem, par document (`fouine_list_documents.vectorised_pages`).
    public func vectorisedPageCounts(forDocIDs ids: [Int64]) throws -> [Int64: Int] {
        try opened().vectorisedPageCounts(forDocIDs: try inScope(ids))
    }

    /// Dimension lue sur un blob, quand `vec_meta` manque. Voir son
    /// commentaire dans FouineCore : c'est un recours, pas la source normale.
    public func vectorBlobDimension() throws -> Int? {
        try opened().vectorBlobDimension()
    }

    /// Nombre de LIGNES de `page_vec`, pour la seule comparaison de fraîcheur
    /// avec `VectorIndex.count`. Ne jamais s'en servir pour annoncer une
    /// couverture : voir `vectorisedPageCount()`.
    public func vectorLineCount() throws -> Int { try opened().vectorCount() }

    // MARK: - Sémantique

    /// Charge l'index vectoriel en mémoire. Le `GRDBStore` interne ne sort pas :
    /// c'est l'appel qui traverse le mur, pas le magasin.
    public func makeVectorIndex(dim: Int) throws -> VectorIndex {
        try VectorIndex(store: try opened(), dim: dim)
    }

    /// Recherche hybride (RRF lexical + vectoriel, §12). Même raison que
    /// ci-dessus : `HybridSearch.run` réclame un `GRDBStore`, on lui passe le
    /// nôtre — ouvert en `SQLITE_OPEN_READONLY` — sans jamais le publier.
    public func hybrid(engine: any EmbedEngine, index: VectorIndex,
                       query: SearchQuery, excludingDocsMatching negative: String?,
                       rawQuery: String, typedQuery: String,
                       limit: Int, offset: Int,
                       depth: Int = HybridSearch.defaultDepth,
                       scope: SemanticScope? = nil) throws -> HybridResults {
        try HybridSearch.run(store: try opened(), engine: engine, index: index,
                             query: try scoped(query), excludingDocsMatching: negative,
                             rawQuery: rawQuery, typedQuery: typedQuery,
                             limit: limit, offset: offset, depth: depth,
                             scope: scope)
    }

    /// Ce que le canal du sens VOIT du périmètre demandé (lot MC2, PM-06).
    ///
    /// Le serveur l'appelle AVANT de charger le modèle : un périmètre sans
    /// vecteur coûtait 6,2 s de mur — 2,3 s de CoreML, 1,9 s d'index — pour
    /// comparer zéro vecteur, et rendait la couverture globale comme si elle
    /// décrivait le dossier demandé. Même chemin que la fusion : le calcul est
    /// dans `HybridSearch`, ici il n'y a qu'un magasin à traverser.
    public func semanticScope(query: SearchQuery,
                              excludingDocsMatching negative: String?,
                              vectors: Int, pagesIndexed: Int) throws -> SemanticScope {
        try HybridSearch.scope(store: try opened(), query: try scoped(query),
                               excludingDocsMatching: negative,
                               vectors: vectors, pagesIndexed: pagesIndexed)
    }

    public func agentStatus() throws -> AgentStatusRecord? { try opened().agentStatus() }

    public func settingsRows() throws -> [String: String] { try opened().settingsRows() }

    public func databaseBytes() -> Int { (try? opened())?.databaseBytes() ?? 0 }

    /// Relue à la demande : la base peut changer de version pendant que le
    /// serveur tourne (l'utilisateur met Fouine à jour, l'app migre).
    public func schemaVersion() throws -> Int? { try opened().schemaVersion() }

    /// Le verrou qui gouverne CETTE base. Il est à côté du `.db` et porte son
    /// nom (`GRDBStore.open`, `FouinePaths.lockURL` depuis BU-30), et il est
    /// vide — donc « libre » — dès que son détenteur le rend.
    public var lockFileURL: URL { FouinePaths.lockURL(for: databaseURL) }

    // MARK: - Lecture d'une page (lot MC4)

    /// Le texte d'une page et de ses voisines, par le chemin PARTAGÉ avec
    /// `fouine read` (`PageReading`, lot MC3).
    ///
    /// Troisième exception au « republier tel quel », même raison que
    /// `hybrid(…)` et `semanticScope(…)` : le chargeur réclame un `GRDBStore`,
    /// on lui passe le nôtre — ouvert en `SQLITE_OPEN_READONLY` — sans jamais
    /// le publier. C'est la condition posée par l'audit (PM-18) : deux
    /// implémentations de la même lecture divergeraient comme `score` et
    /// `bm25`.
    public func pageReading(docID: Int64, page: Int, maxChars: Int,
                            offset: Int = 0, contextPages: Int = 0,
                            missingTextNote: String
                                = PageReading.assistantMissingTextNote,
                            pageLabels: Bool = true) throws -> PageReading {
        // Le périmètre (lot IG1) s'applique ici aussi : un document hors
        // `--folders` est INCONNU, mot pour mot comme un identifiant absent —
        // c'est la même `Failure`, donc la même phrase dans `fouine_read_page`.
        guard try isVisible(docID) else {
            throw PageReading.Failure.unknownDocument(docID)
        }
        return try PageReading.load(store: try opened(), docID: docID, page: page,
                             maxChars: maxChars, offset: offset,
                             contextPages: contextPages,
                             missingTextNote: missingTextNote,
                             pageLabels: pageLabels)
    }
}
