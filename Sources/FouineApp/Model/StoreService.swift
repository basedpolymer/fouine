// StoreService.swift — façade asynchrone sur GRDBStore. Propriété : A-App.
//
// Règle du §5.6 : la recherche est synchrone et rapide côté moteur, mais elle ne
// doit JAMAIS s'exécuter sur le fil principal. Toutes les entrées de ce fichier
// renvoient la main immédiatement et travaillent sur une file concurrente ; le
// DatabasePool de GRDB sérialise ce qu'il faut (§3 : SQLite système THREADSAFE=2).

import Foundation
import FouineCore

final class StoreService: @unchecked Sendable {

    let store = GRDBStore()
    let databaseURL: URL

    /// Concurrente : une recherche, ses facettes et le chargement du vocabulaire
    /// se recouvrent — le pool GRDB accepte plusieurs lectures simultanées.
    private let queue = DispatchQueue(label: "io.github.basedpolymer.fouine.store",
                                      qos: .userInitiated, attributes: .concurrent)

    private let vocabLock = NSLock()
    /// Vocabulaire trié par ordre alphabétique, avec le rang de fréquence.
    private var vocabulary: [(term: String, rank: Int)] = []
    private var vocabularyLoaded = false

    init(databaseURL: URL = AppPaths.databaseURL()) {
        self.databaseURL = databaseURL
    }

    // MARK: - Ouverture

    /// Combien de fois l'index a été ouvert dans ce processus.
    ///
    /// Il en faut EXACTEMENT une (BU-02) : `AppModel.start()` part du délégué
    /// d'application et le `.task` de la fenêtre l'attend au lieu de le
    /// refaire. C'est ce compteur qui le prouve, et c'est aussi lui qui dit au
    /// panneau de la barre des menus qu'il n'a pas encore d'index à
    /// interroger — plutôt que de laisser sortir l'erreur du moteur.
    private(set) var openCount = 0

    var isOpen: Bool { openCount > 0 }

    func open() throws {
        try store.open(at: databaseURL)
        openCount += 1
    }

    // MARK: - Plomberie

    private func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: - Lectures

    /// `negative` : expression MATCH des `-terme` (arbitrage T5, portée
    /// DOCUMENT), telle que la rend `QueryParser.searchPlan`.
    ///
    /// Le paramètre est OBLIGATOIRE, sans valeur par défaut, et c'est délibéré :
    /// `QueryParser.fts()` a retiré les négations de l'expression MATCH, si bien
    /// qu'un appelant qui l'oublie rend une recherche où `-terme` n'a AUCUN
    /// effet, en silence (audit F1). Une valeur par défaut aurait laissé
    /// exactement ce bogue se reproduire ; ici, chaque site d'appel doit dire
    /// `nil` ou passer le plan.
    func search(_ q: SearchQuery,
                excludingDocsMatching negative: String?) async throws -> SearchResults {
        try await run { [store] in try store.search(q, excludingDocsMatching: negative) }
    }

    /// Les documents dont le NOM DE FICHIER répond (lot MP1, PR-02).
    ///
    /// À PART de `search`, qui les rend déjà, pour le seul chemin HYBRIDE :
    /// `HybridResults` ne porte pas ce champ (c'est `HybridSearch.run` qui
    /// appelle le canal lexical), et le bandeau ne doit pas dépendre de
    /// l'interrupteur « Chercher aussi par le sens ».
    func documentsMatchingName(_ q: SearchQuery) async throws -> [DocumentListing] {
        try await run { [store] in try store.documentsMatchingName(q) }
    }

    /// Ceux des mots tapés qu'au moins une page porte (lot MC1) : ce qui
    /// distingue « aucun de vos mots n'est dans vos documents » de « vos mots
    /// n'y sont jamais ensemble ». Lu SEULEMENT quand la phrase va être dite.
    func wordsPresent(_ q: SearchQuery, excludingDocsMatching negative: String?)
        async throws -> [String] {
        try await run { [store] in
            try store.wordsPresent(q, excludingDocsMatching: negative)
        }
    }

    /// Mêmes exclusions que la recherche : sans elles, les facettes comptaient
    /// des documents que la liste de résultats n'affiche pas (audit F1).
    func facets(_ q: SearchQuery, by key: FacetKey,
                excludingDocsMatching negative: String?) async throws -> [(String, Int)] {
        try await run { [store] in
            try store.facets(q, by: key, excludingDocsMatching: negative)
        }
    }

    /// Pages touchées par document, pour TOUT le jeu de résultats (audit A12) :
    /// `DocGroup.pageCount` ne compte que les hits CHARGÉS, et l'interface les
    /// annonçait comme « pages touchées ».
    func matchedPageCounts(_ q: SearchQuery,
                           excludingDocsMatching negative: String?) async throws
        -> [Int64: Int] {
        try await run { [store] in
            try store.matchedPageCounts(q, excludingDocsMatching: negative)
        }
    }

    /// Texte indexé d'une page, tel qu'il est en base (`page_fts`). Sert
    /// l'aperçu des formats sans rendu par page (txt, md, html, epub, docx,
    /// rtf, djvu…) : aucun accès disque, donc aucun refus TCC possible et
    /// aucune ré-extraction (audit U4).
    func pageText(docID: Int64, page: Int) async throws -> String? {
        try await run { [store] in try store.pageText(docID: docID, page: page) }
    }

    /// Pourquoi cette page est dans les résultats (lot U1, R-06), calculé sur
    /// le texte INDEXÉ de la page — jamais sur l'extrait.
    ///
    /// C'est ce qui distingue l'application des deux autres surfaces : elle
    /// seule voit toute la page, donc elle seule peut dire qu'un mot n'y est
    /// PAS. Le texte vient de `page_fts`, exactement celui que le moteur a
    /// apparié : aucun accès disque, donc aucun refus TCC possible, et le
    /// verdict ne peut pas diverger de la recherche.
    ///
    /// La lecture ET le calcul se font ici, sur la file de la façade : sans
    /// quoi le découpage en jetons d'une page dense se paierait sur le fil
    /// principal à chaque changement de sélection.
    func explanation(docID: Int64, page: Int, words: [QueryWord],
                     fuzzyDistance: Int, lexRank: Int?, vecRank: Int?,
                     fallbackText: String) async throws -> HitExplanation? {
        try await run { [store] in
            let text = try store.pageText(docID: docID, page: page)
            return HitExplanation(words: words, text: text ?? fallbackText,
                                  fuzzyDistance: fuzzyDistance,
                                  lexRank: lexRank, vecRank: vecRank,
                                  // Faute de texte indexé (page qui attend
                                  // encore l'OCR), on retombe sur l'extrait —
                                  // et on cesse alors de conclure à un manque.
                                  textIsWholePage: text != nil)
        }
    }

    /// Numéros des pages d'un document qui portent du texte indexé, triés.
    /// Commande la navigation « page précédente / suivante » de l'aperçu :
    /// `docs.n_pages` compte aussi les pages vides, qui n'ont rien à afficher.
    func textPages(docID: Int64) async throws -> [Int] {
        try await run { [store] in try store.textPages(docID: docID) }
    }

    func roots() async throws -> [RootRecord] {
        try await run { [store] in try store.roots() }
    }

    func stats() async throws -> [String: Int] {
        try await run { [store] in try store.stats() }
    }

    /// Les documents que Fouine n'a pas pu lire (UX-16). Hors du fil principal
    /// comme tout le reste de cette façade : la fenêtre s'ouvre vide et se
    /// remplit, elle ne fige jamais l'interface.
    func unreadableDocuments(limit: Int) async throws -> [DocumentListing] {
        try await run { [store] in try store.unreadableDocuments(limit: limit) }
    }

    // MARK: - Parcourir l'index (lot BR1, constat PR-06)

    /// Une tranche de la fenêtre « Tous vos documents ». Paginée PAR SQLITE
    /// (voir `AllDocumentsModel`), hors du fil principal comme tout ici.
    func listDocuments(_ filter: DocumentFilter, order: DocumentOrder,
                       limit: Int, offset: Int) async throws -> [DocumentListing] {
        try await run { [store] in
            try store.listDocuments(filter, order: order, limit: limit,
                                    offset: offset)
        }
    }

    /// Le compte annoncé par la fenêtre : TOUS les documents qui répondent au
    /// filtre, pas seulement ceux de la tranche affichée.
    func countDocuments(_ filter: DocumentFilter) async throws -> Int {
        try await run { [store] in try store.countDocuments(filter) }
    }

    /// Les extensions du menu « Type ».
    func documentExtensions() async throws -> [String] {
        try await run { [store] in try store.documentExtensions() }
    }

    // MARK: - Relire une page (lot BR1, constat PR-24)

    /// Remet UNE page scannée en file d'OCR. La seule ÉCRITURE de cette façade,
    /// et c'est assumé : le geste vient de l'aperçu, il doit être servi là où
    /// l'aperçu lit déjà. L'écriture prend le verrou (`writeLocked`) — donc elle
    /// peut être refusée pendant une passe, et l'appelant le dit.
    func requeueOCRPage(docID: Int64, page: Int) async throws -> OCRRequeueResult {
        try await run { [store] in
            try store.requeueOCRPage(docID: docID, page: page)
        }
    }

    // `requeueOCRPages(_:)` a été retiré avec le geste « Les relire » de la
    // carte « Index » (IX2) : la relecture en masse rendait le même résultat.
    // `fouine ocr requeue` garde l'écriture du cœur pour les dépanneurs.

    func docRow(id: Int64) async throws -> DocRow? {
        try await run { [store] in try store.docRow(id: id) }
    }

    /// Le document qui vit à ce chemin absolu (lien `fouine://open?path=…`,
    /// lot INT-L1). `nil` = Fouine ne le connaît pas, ou son volume n'est pas
    /// monté — deux cas que l'appelant présente de la même façon.
    func docID(forAbsolutePath path: String) async throws -> Int64? {
        try await run { [store] in try store.docID(forAbsolutePath: path) }
    }

    func docRows(ids: [Int64]) async throws -> [Int64: DocRow] {
        try await run { [store] in
            var out: [Int64: DocRow] = [:]
            for id in Set(ids) {
                if let row = try store.docRow(id: id) { out[id] = row }
            }
            return out
        }
    }

    /// Provenance d'UNE page. Volontairement appelée à la sélection seulement :
    /// `pageMeta` balaie `page_src` (bogue connu, relevé par la recette du
    /// 31/08/2026, rapport interne, § 3 bogue 2), donc
    /// ~100 ms sur l'index complet — inacceptable à chaque ligne de résultat, sans
    /// conséquence une fois par changement de sélection.
    func provenance(docID: Int64, page: Int) async throws
        -> (source: PageSource, engine: OCREngineID, conf: Double?)? {
        try await run { [store] in
            let key = Schema.ftsRowID(docID: docID, page: page)
            return try store.pageMeta(for: [(docID: docID, page: page)])[key]
        }
    }

    func ocrLayout(docID: Int64, page: Int) async throws -> [OCRLine]? {
        try await run { [store] in try store.ocrLayout(docID: docID, page: page) }
    }

    /// Provenance fine (moteur) de TOUT un jeu de résultats, en UNE requête :
    /// le coût de `pageMeta` est celui d'un balayage de `page_src`, indépendant
    /// du nombre de clés — une fois par recherche, en tâche de fond, il paie le
    /// pictogramme « OCR importé » du §5.6 sans ralentir l'affichage.
    func engines(for keys: [(docID: Int64, page: Int)]) async throws
        -> [Int64: OCREngineID] {
        try await run { [store] in
            try store.pageMeta(for: keys).mapValues(\.engine)
        }
    }

    // MARK: - Vocabulaire (autocomplétion, §5.6)

    var isVocabularyLoaded: Bool {
        vocabLock.lock(); defer { vocabLock.unlock() }
        return vocabularyLoaded
    }

    /// Charge une fois pour toutes les N termes les plus fréquents. Mesuré sur la
    /// base de production (1 486 739 termes) : ~4 s de balayage — d'où le
    /// chargement en tâche de fond, à basse priorité, et la complétion en mémoire
    /// qui, elle, tient largement sous les 20 ms demandées.
    func loadVocabulary(limit: Int = 60_000, minLength: Int = 3) {
        queue.async { [weak self] in
            guard let self else { return }
            let terms = (try? self.store.topVocabulary(limit: limit,
                                                       minLength: minLength)) ?? []
            var ranked: [(term: String, rank: Int)] = []
            ranked.reserveCapacity(terms.count)
            for (rank, term) in terms.enumerated() { ranked.append((term, rank)) }
            ranked.sort { $0.term < $1.term }
            self.vocabLock.lock()
            self.vocabulary = ranked
            self.vocabularyLoaded = true
            self.vocabLock.unlock()
        }
    }

    /// Suggestions par préfixe, en mémoire : recherche dichotomique puis tri par
    /// fréquence. Les termes de `fts5vocab` sont déjà en minuscules et sans
    /// accents (tokenizer `unicode61 remove_diacritics 2`), le préfixe est plié
    /// de la même façon.
    func suggestions(prefix raw: String, limit: Int = 8) -> [String] {
        let prefix = Self.fold(raw)
        guard prefix.count >= 2 else { return [] }
        vocabLock.lock()
        let table = vocabulary
        vocabLock.unlock()
        guard !table.isEmpty else { return [] }

        var low = 0, high = table.count
        while low < high {
            let mid = (low + high) / 2
            if table[mid].term < prefix { low = mid + 1 } else { high = mid }
        }
        var found: [(term: String, rank: Int)] = []
        var i = low
        while i < table.count, table[i].term.hasPrefix(prefix), found.count < 400 {
            if table[i].term != prefix { found.append(table[i]) }
            i += 1
        }
        return found.sorted { $0.rank < $1.rank }.prefix(limit).map(\.term)
    }

    /// Repliement de casse et d'accents du préfixe d'autocomplétion.
    ///
    /// `en_US_POSIX` et non `fr_FR` (palier 3.2, audit U1) : ce repliement doit
    /// donner le MÊME résultat quelle que soit la langue de l'utilisateur, parce
    /// qu'il doit correspondre à celui de `fts5vocab`, dont le tokenizer
    /// (`unicode61 remove_diacritics 2`) ne connaît aucune locale. `en_US_POSIX`
    /// est la locale conventionnelle de ce cas : invariable, indépendante des
    /// réglages du système. Le comportement sur les accents français est
    /// inchangé — `fr_FR` n'apportait aucune règle propre au français ici (le
    /// turc et l'azéri sont les seules locales à changer le repliement de casse,
    /// avec le « i » sans point).
    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive],
                  locale: Locale(identifier: "en_US_POSIX"))
    }
}
