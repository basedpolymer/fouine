// CommandsSearch.swift — `fouine search` (SPEC §4.3, §5.5). Propriété : A-Core.

import Foundation
import ArgumentParser
import FouineCore

/// Le CONTRAT GELÉ d'un résultat (§4.3), en un seul endroit — constat CM-22.
/// UN SEUL constructeur : deux constructeurs voisins avaient divergé parce que
/// rien ne les obligeait à se ressembler, et un script qui lisait
/// `hits[].folder` cassait selon le mode de recherche.
enum SearchJSON {

    /// `score` est ARRONDI À 4 DÉCIMALES (constat CM-21) : la CLI publiait
    /// 17 chiffres significatifs (`-39.03995683050397`) dans un contrat gelé
    /// dont d'autres programmes dépendent — ce sont 17 chiffres qui bougeront
    /// au premier changement de FTS5. C'est la même grandeur, et désormais le
    /// même arrondi, que le `bm25` de l'outil MCP.
    ///
    /// `score` reste OPTIONNEL dans la signature : le contrat gelé l'annonce
    /// ainsi, et inventer un 0 serait un chiffre faux.
    /// - Parameters:
    ///   - relevancePct: la pertinence RELATIVE (`HitRelevance`) — celle que la
    ///     sortie texte imprime depuis toujours et que le JSON taisait.
    ///   - time: le moment de l'extrait dans l'enregistrement, pour une page
    ///     transcrite seulement ; `link` le porte aussi (`&t=`).
    ///   - slide / embeddedImage: ce que la page DÉSIGNE (`PageLayout`).
    static func hit(docID: Int64, path: String, folder: String, page: Int,
                    score: Double?, source: String, engine: String,
                    fuzzyDistance: Int, snippet: String,
                    link: String, relevancePct: Int,
                    time: Int?, slide: Int?, embeddedImage: Int?)
        -> [String: Any] {
        var entry: [String: Any] = [
            "doc_id": docID,
            "path": path,
            "folder": folder,
            "page": page,
            "source": source,
            "engine": engine,
            "fuzzy_distance": fuzzyDistance,
            "snippet": snippet,
            // Le lien qui rouvre Fouine sur CETTE page (lot INT-L1) : `path`
            // est relatif au volume et ne ramène nulle part tout seul.
            "link": link,
            // `bm25` À CÔTÉ DE `score`, MÊME NOMBRE (lot CL2, constat PM-16b).
            // Le serveur MCP appelle `bm25` ce que la CLI appelle `score` : un
            // programme qui lit les deux surfaces devait connaître les deux
            // noms du même nombre. `score` RESTE — le §4.3 est gelé —, et c'est
            // LUI qui est déprécié : « score » ne dit pas de quelle échelle il
            // parle, alors que `bm25` nomme la sienne. Contrairement à lui,
            // `bm25` est TOUJOURS présent, `null` pour une page rendue par le
            // seul canal du sens : une clé absente n'apprend rien.
            "bm25": score.map { JSONNumber.rounded($0, places: 4) as Any } ?? NSNull(),
            "relevance_pct": relevancePct,
            "time_seconds": time.map { $0 as Any } ?? NSNull(),
            "slide": slide.map { $0 as Any } ?? NSNull(),
            "embedded_image": embeddedImage.map { $0 as Any } ?? NSNull(),
        ]
        if let score { entry["score"] = JSONNumber.rounded(score, places: 4) }
        return entry
    }
}

struct SearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search the index. FTS5 syntax is not required (§5.5.1).",
        discussion: """
        Accepted input:
          azote reduction          both words (AND)
          "gaz parfait"            exact phrase
          spectro*                 prefix (at least 4 letters before *)
          -biologie                exclusion
          pres:5 azote reduction   within 5 words of each other (near:5 works too)
          dossier:Cours enthalpie  root filter (folder:Cours works too)
          ext:pdf                  extension filter
          nom:rapport              file or folder NAME only (name:rapport works too)
          texte:rapport            page TEXT only, file names do not count (body:)
          chemin:Offres            the whole PATH contains this (path:Offres too)
          -ext:md                  exclude an extension
          -dossier:Cours           exclude a folder (-folder: works too)
          -nom:draft               exclude documents whose NAME matches (-name:)
          -chemin:Archive          exclude documents whose PATH contains this
          1512,50                  amounts match with or without their space

        The `dossier:`, `ext:`, `pres:`, `nom:`, `texte:` and `chemin:` prefixes
        belong to the query language: they are typed, not translated —
        `folder:`, `near:`, `name:`, `body:` and `path:` are accepted as English
        aliases. Any other `word:value` is refused (64) rather than searched as
        a word — `-word:value` included. `nom:` and `chemin:` alone list the
        matching documents, one line each. The four filters that pick documents
        also exist in the negative, written with a leading `-`; their value may
        be quoted, like the positive form. `pres:` and `texte:` do not: they
        say nothing about which documents to keep, and `-word` already excludes
        a word. Typographic quotes (“ ” « ») count as straight quotes, and
        accents may be typed or pasted in either Unicode form.

        A query that STARTS with `-` has to come after `--`, otherwise the
        shell's argument parser reads it as an option and refuses (64):

          fouine search -- '-type:pdf reactor'
          fouine search --json -- '-ext:md polymer'

        Options go before the `--`; everything after it is the query.

        When the exact search finds nothing, the query is replayed once
        tolerating typos over every document (`fuzzy_fallback` in JSON); the
        documents whose FILE NAME matches are listed on their own line
        (`name_matches`).
        """)

    @Argument(help: "Query.")
    var query: String

    @Option(name: .long, help: "Number of pages returned (50 by default).")
    var limit: Int = 50

    @Option(name: .long, help: "Number of pages to skip (0 by default).")
    var offset: Int = 0

    @Option(name: .long,
            help: ArgumentHelp("Facet to compute: doc_year (the year the document "
                + "carries), modified_year (the year the file was last "
                + "modified), folder, ext, source or lang."))
    var facet: FacetArg?

    @Option(name: .long, parsing: .singleValue,
            help: "Restrict to this document language, ISO 639-1 (\"und\" = undetermined). Repeatable.")
    var lang: [String] = []

    @Option(name: .long,
            help: "Only documents modified on or after this date (YYYY-MM-DD).")
    var since: String?

    @Option(name: .long,
            help: "Restrict to pages whose text has this origin: native (already in the document), ocr (read on the page image) or transcript (speech written down from an audio or video file).")
    var source: SourceArg?

    @Option(name: .customLong("in"), parsing: .singleValue,
            help: "Restrict to this doc_id (repeatable).")
    var inDocs: [Int64] = []

    @Flag(name: .long, help: "JSON output, on the stable schema of §4.3.")
    var json = false

    @Flag(name: .customLong("raw-fts"), help: "Bypass the query parser.")
    var rawFTS = false

    @Option(name: .long, help: "Fuzzy search: off, auto (default) or on.")
    var fuzzy: FuzzyModeArg = .auto

    @Option(name: .customLong("fuzzy-scope"),
            help: "Scope of the fuzzy search: ocr (default) or all.")
    var fuzzyScope: FuzzyScopeArg = .ocr

    @Option(name: .long,
            help: "What surrounds the matched words in a snippet: guillemets (default), brackets, asterisks or none.")
    var mark: MarkArg = .guillemets

    @Flag(name: .customLong("no-proximity"),
          help: "Disable the phrase, proximity and file-name ranking bonuses (calibration).")
    var noProximity = false

    @Flag(name: .customLong("no-morphology"),
          help: "Search the typed words only, without their singular and plural forms (calibration).")
    var noMorphology = false

    @Flag(name: .customLong("no-diversity"),
          help: "Do not demote the 4th and following pages of a same document (calibration).")
    var noDiversity = false

    @Flag(name: .customLong("no-typed-form"),
          help: "Do not promote the pages carrying the words as typed over those carrying only an inflected form (calibration).")
    var noTypedForm = false

    @Flag(name: .customLong("no-quorum"),
          help: "Require every word on the same page even when fewer than 10 pages carry them all (calibration).")
    var noQuorum = false

    @Flag(name: .customLong("no-demote-toc"),
          help: "Leave tables of contents and indexes where the ranking puts them (calibration).")
    var noDemoteTOC = false

    /// Une requête que l'analyseur refuse est une ERREUR D'USAGE, pas une
    /// panne : `ValidationError` sort en 64 et affiche l'usage, comme un
    /// argument manquant (§4.3, `docs/cli.md` § codes de sortie). Elle sortait
    /// en 1, c'est-à-dire dans le fourre-tout des pannes, alors que `root add`
    /// et `config get` refusaient déjà leurs arguments en 64.
    ///
    /// `--raw-fts` n'est pas validé : la chaîne part telle quelle à FTS5, dont
    /// le refus éventuel est une erreur de base (3), pas d'argument.
    func validate() throws {
        guard offset >= 0 else {
            throw ValidationError("Offset must be non-negative.")
        }
        // `--limit=-1` PLANTAIT le programme sans un mot (SIGILL, sortie 132,
        // stdout et stderr vides) : `SearchResults.hits.prefix(limit)` piège sur
        // une longueur négative, et SQLite lit `LIMIT -1` comme « pas de
        // limite ». Mesuré le 04/09/2026 sur une copie de la base de production
        // (A1m-02). Une valeur négative est une erreur d'ARGUMENT, comme
        // `--offset` : sortie 64.
        guard limit >= 0 else {
            throw ValidationError("Limit must be non-negative.")
        }
        // Une date illisible est une erreur d'ARGUMENT (64), pas une recherche
        // sans borne : filtrer sur rien du tout en silence ferait annoncer un
        // résultat pour une question qui n'a pas été posée.
        if let since, DateWindow.startOfDay(iso8601: since) == nil {
            throw ValidationError("--since expects a date written YYYY-MM-DD.")
        }
        guard !rawFTS else { return }
        do {
            _ = try QueryParser.searchPlan(
                query, limit: limit, offset: offset, inDocIDs: inDocs, groupByDoc: true,
                fuzzy: fuzzy.value, fuzzyScope: fuzzyScope.value)
        } catch let error as QueryError {
            throw ValidationError(CLI.describe(error))
        }
    }

    func run() {
        CLI.guarded {
            let store = try CLI.openStoreReadOnly()
            var q: SearchQuery
            // Expression des exclusions `-terme` : portée DOCUMENT (arbitrage
            // T5). `--raw-fts` court-circuite la traduction : un NOT y garde
            // la sémantique FTS5 native (exclusion par page).
            let negative: String?
            if rawFTS {
                q = SearchQuery(terms: [], fts: query, limit: limit + 1, offset: offset,
                                folders: [], exts: [], inDocIDs: inDocs,
                                groupByDoc: true, fuzzy: fuzzy.value,
                                fuzzyScope: fuzzyScope.value)
                negative = nil
            } else {
                (q, negative) = try QueryParser.searchPlan(
                    query, limit: limit + 1, offset: offset, inDocIDs: inDocs, groupByDoc: true,
                    fuzzy: fuzzy.value, fuzzyScope: fuzzyScope.value)
            }
            // `dossier:Xyz` qui ne correspond à aucune racine rendait ZÉRO
            // RÉSULTAT, sans un mot : indiscernable d'un corpus qui ne contient
            // pas le terme (idée 5 de l'audit A1). Une étiquette de casse
            // différente est canonisée au passage — `top_folder` se compare
            // exactement en SQL.
            if !q.folders.isEmpty || !q.folderExcludes.isEmpty {
                let known = try store.roots().map(\.label)
                q.folders = try FolderCheck.resolve(q.folders, known: known)
                // `-dossier:Xyz` est confronté aux mêmes étiquettes que
                // `dossier:Xyz` (lot MC1) : exclure un dossier qui n'existe
                // pas n'exclut rien, et c'est exactement le silence que le
                // refus répare.
                q.folderExcludes = try FolderCheck.resolve(q.folderExcludes,
                                                           known: known)
            }
            // Les MÊMES refus pour `--lang` et `--in` (constat CM-11) : ils
            // rendaient zéro résultat en silence, c'est-à-dire la réponse
            // « votre corpus ne traite pas de ce sujet ». Le serveur MCP les
            // refuse depuis le lot MC1 ; la CLI le fait ici, avec la même
            // phrase.
            try Self.refuseUnknownFilters(store: store, langs: lang, docs: inDocs)
            // Option de CALIBRATION, comme `--vec-floor` : elle rend le
            // classement d'avant le lot M1, pour comparer deux ordres sur la
            // même base sans rebâtir un binaire.
            q.rankingBoosts = !noProximity
            // Deux options de calibration de plus (lot R1), même logique :
            // le classement livré d'un côté, celui d'avant de l'autre.
            // `--raw-fts` : la chaîne part TELLE QUELLE à FTS5 — sans
            // morphologie (le cœur s'en garde aussi : `morphologyApplies`),
            // sinon `body:polymere` devenait du FTS5 invalide (AUDIT-R1 I1).
            q.morphology = !noMorphology && !rawFTS
            q.diversifyDocuments = !noDiversity
            // Lot P1 : la sonde « forme tapée présente ». Elle ne vit que
            // quand la morphologie a décliné quelque chose — `--no-morphology`
            // et `--raw-fts` l'éteignent donc de fait, sans qu'il y ait rien à
            // écrire ici.
            q.typedFormBoost = !noTypedForm
            // LES DEUX RÉGLAGES DU LOT RK2, ARMÉS PAR DÉFAUT depuis le
            // 11/09/2026 (AUDIT-RK2 : jugés sur 149 candidats, +0,052 nDCG@10
            // ensemble, p < 0,001, 790 jugements pour le quorum seul :
            // +0,031, 6 victoires / 43 égalités / 0 défaite). Livrés désarmés,
            // ils sont devenus des options de calibration comme les quatre
            // ci-dessus : `--no-*` les éteint pour le banc.
            q.quorum = !noQuorum
            q.demoteTableOfContents = !noDemoteTOC
            // Filtres de DOCUMENT (lot U2) : ils portent sur tout l'index.
            q.langs = lang
            q.modifiedAfter = since.flatMap { DateWindow.startOfDay(iso8601: $0) }
            // Filtre de PAGE (lot P3), le seul : la provenance est une
            // propriété de la page, pas du document.
            q.sources = source?.value
            // Les marqueurs de surlignage (lot CL2) : le défaut est inchangé,
            // et `TranscriptTime` lit l'ouvrant pour savoir où commence le mot
            // trouvé — d'où la valeur portée par la requête plutôt que par un
            // paramètre de sortie.
            q.snippetMarkers = mark.value
            let results = try store.search(q, excludingDocsMatching: negative)
            let hasMore = results.hits.count > limit
            let trimmedHits = Array(results.hits.prefix(limit))
            let trimmedResults = SearchResults(hits: trimmedHits,
                                               totalPages: results.totalPages,
                                               totalDocs: results.totalDocs,
                                               elapsedMS: results.elapsedMS,
                                               totalsApproximate: results.totalsApproximate,
                                               fuzzyFallback: results.fuzzyFallback,
                                               nameMatches: results.nameMatches,
                                               quorum: results.quorum)
            let facets = try facet.map {
                try store.facets(q, by: $0.value, excludingDocsMatching: negative)
            }
            // LE REPLI EST DIT AVANT LES RÉSULTATS, sur l'ERREUR STANDARD, ET
            // DANS LES DEUX MODES : c'est le contexte dans lequel les résultats
            // se lisent (« Villeurbanne » n'est pas « Villeurbane »), et
            // quelqu'un qui lit du JSON dans son terminal doit le voir aussi.
            // stderr laisse la sortie exploitable telle quelle par un tube — la
            // même règle que les autres avertissements de contexte.
            if results.fuzzyFallback { CLI.warn(SearchAdvice.fuzzyFallback) }
            // LE QUORUM SE DIT AU MÊME ENDROIT, et pour la même raison : ce qui
            // suit les pages strictes ne porte pas tous les mots demandés.
            if results.quorum { CLI.warn(SearchAdvice.quorum) }
            // L'EXPANSION ORDINAIRE SE DIT AUSSI (lot MC1, PM-13). Pas en même
            // temps que le repli : celui-ci est déjà une phrase sur les
            // orthographes proches, et deux avertissements pour un seul fait
            // se lisent comme deux faits.
            if results.fuzzyExpanded, !results.fuzzyFallback {
                CLI.warn(SearchAdvice.fuzzyExpanded)
            }

            if json {
                try emitJSON(store: store, results: trimmedResults, facets: facets,
                             offset: offset, hasMore: hasMore)
            } else {
                try emitText(store: store, results: trimmedResults, facets: facets)
            }
        }
    }

    // MARK: - Filtres dont la valeur n'existe pas (constat CM-11)

    /// Refuse en **64** une langue ou un `doc_id` que l'index contredit, en
    /// nommant ce qui existe.
    ///
    /// ON NE REFUSE QUE CE QU'ON PEUT CONTREDIRE, comme `FolderCheck` : sur un
    /// index dont aucun document ne porte de langue, la liste est vide et le
    /// filtre part tel quel — un refus fondé sur une liste vide serait un faux
    /// positif.
    ///
    /// `und` est TOUJOURS accepté : c'est la valeur documentée de `--lang`
    /// (« langue non déterminée »), et la refuser sur un index où tout est
    /// détecté reviendrait à refuser une demande parfaitement formée.
    static func refuseUnknownFilters(store: GRDBStore, langs: [String],
                                     docs: [Int64]) throws {
        if !langs.isEmpty {
            let known = try store.knownLanguages()
            if !known.isEmpty {
                let folded = Set(known.map { $0.lowercased() })
                if let unknown = langs.first(where: {
                    $0.lowercased() != "und" && !folded.contains($0.lowercased())
                }) {
                    throw UsageRefusal.unknownLanguage(unknown, known: known)
                }
            }
        }
        if !docs.isEmpty {
            let unknown = try store.unknownDocIDs(docs)
            if !unknown.isEmpty { throw UsageRefusal.unknownDocuments(unknown) }
        }
    }

    /// Les mots POSITIFS de la requête, pour l'objet `why` (A1-08).
    ///
    /// `--raw-fts` en rend AUCUN, et c'est juste : la chaîne part telle quelle
    /// à FTS5, l'analyseur ne l'a pas vue, et deviner ses termes serait
    /// inventer. `why` est alors simplement absent.
    private var explanationWords: [QueryWord] {
        rawFTS ? [] : HitExplanation.words(ofQuery: query)
    }

    /// `why` se calcule sur l'EXTRAIT, pas sur la page relue : coût nul, et
    /// c'est de toute façon l'extrait que l'appelant a sous les yeux.
    ///
    /// D'où `textIsWholePage: false` : sur un extrait, l'absence d'un mot ne
    /// prouve rien. `fouine search 'cinetique reticulation' --json` sur la base
    /// de production annonçait « “cinetique” manque » pour une page que FTS5
    /// avait appariée sur les deux mots — l'extrait n'en montrait qu'un. Un hit
    /// lexical les porte tous, par construction ; `terms_missing` n'apparaît
    /// donc jamais ici, seule l'application (qui lit la page) peut le dire.
    private func why(words: [QueryWord], text: String, fuzzyDistance: Int,
                     tableOfContents: Bool = false,
                     quorum: Bool = false) -> [String: Any]? {
        HitExplanation(words: words, text: text, fuzzyDistance: fuzzyDistance,
                       textIsWholePage: false, quorum: quorum)
            .map { HitExplanation.json($0, tableOfContents: tableOfContents) }
    }

    /// Le lien `fouine://` d'une page, forme choisie par `DeepLink.link` — le
    /// point unique du dépôt, partagé avec l'application et le serveur MCP :
    /// trois surfaces qui citeraient la même page autrement produiraient trois
    /// citations qu'on ne peut pas rapprocher.
    private static func link(_ row: DocRow?, docID: Int64, page: Int,
                             time: Int? = nil) -> String {
        let absolute = row.flatMap { r -> String? in
            try? VolumeResolver.absolutePath(volUUID: r.record.volUUID,
                                             relPath: r.record.relPath).path
        }
        return DeepLink.link(absolutePath: absolute, docID: docID,
                             page: page, time: time).absoluteString
    }

    // MARK: - Ce que chaque résultat porte en plus (lot CL2 ; PM-19, PM-22)

    /// Ce qu'il a fallu LIRE pour dire ce qu'une page désigne et à quel moment
    /// de l'enregistrement elle correspond — une fois pour toute la page de
    /// résultats, comme `SearchTool.decorations` côté serveur.
    private struct Decorations {
        /// Pages de TEXTE des conteneurs qui rangent leurs images après
        /// (`PageLayout.textThenMedia`), par document. Rien pour un PDF.
        let textPages: [Int64: Int]
        /// Moment de la page transcrite, en secondes, par rowid.
        let times: [Int64: Int]

        func time(docID: Int64, page: Int) -> Int? {
            times[Schema.ftsRowID(docID: docID, page: page)]
        }

        func label(docID: Int64, page: Int, rows: [Int64: DocRow])
            -> (slide: Int?, embeddedImage: Int?) {
            PageLayout.page(page, ext: rows[docID]?.record.ext ?? "",
                            textPages: textPages[docID])
        }
    }

    /// Les deux lectures qui habillent les résultats, groupées.
    ///
    /// Le moment se lit d'abord sur l'EXTRAIT — le dernier marqueur `[MM:SS]`
    /// avant le mot trouvé, c'est-à-dire le paragraphe qui le porte — et
    /// seulement à défaut sur le début de la page (soixante-quatre caractères,
    /// de quoi porter un `[00:01] `). Une page de transcription couvre dix
    /// minutes : citer « page 1 » d'une vidéo de deux heures ne renvoie
    /// personne nulle part.
    private func decorations(
        store: GRDBStore,
        pages: [(docID: Int64, page: Int, source: PageSource, snippet: String)],
        rows: [Int64: DocRow]) throws -> Decorations {
        let containers = Set(pages.map(\.docID)).filter {
            PageLayout.textThenMedia.contains(
                (rows[$0]?.record.ext ?? "").lowercased())
        }
        let textPages = containers.isEmpty
            ? [:] : try store.textPageCounts(forDocIDs: Array(containers))

        var times: [Int64: Int] = [:]
        var unresolved: [Int64] = []
        for page in pages where page.source == .transcript {
            let rowid = Schema.ftsRowID(docID: page.docID, page: page.page)
            if let seconds = TranscriptTime.seconds(inSnippet: page.snippet,
                                                    opening: mark.value.open) {
                times[rowid] = seconds
            } else {
                unresolved.append(rowid)
            }
        }
        if !unresolved.isEmpty {
            let heads = try store.pagePreviews(for: unresolved, maxChars: 64)
            for rowid in unresolved {
                if let text = heads[rowid]?.preview,
                   let seconds = TranscriptTime.first(in: text) {
                    times[rowid] = seconds
                }
            }
        }
        return Decorations(textPages: textPages, times: times)
    }

    // MARK: - Sorties

    private func metadata(_ store: GRDBStore, _ results: SearchResults)
        throws -> (folders: [Int64: String], engines: [Int64: OCREngineID],
                   rows: [Int64: DocRow]) {
        var folders: [Int64: String] = [:]
        // Les lignes `docs` sont RETENUES : `folder` et le lien `fouine://`
        // (lot INT-L1) en viennent tous les deux, et une seconde sonde par
        // document pour le seul volume serait payée pour rien.
        var rows: [Int64: DocRow] = [:]
        for id in Set(results.hits.map(\.docID)) {
            let row = try store.docRow(id: id)
            rows[id] = row
            folders[id] = row?.record.topFolder ?? ""
        }
        let keys = results.hits.map { (docID: $0.docID, page: $0.page) }
        let meta = try store.pageMeta(for: keys)
        var engines: [Int64: OCREngineID] = [:]
        for (rowid, value) in meta { engines[rowid] = value.engine }
        return (folders, engines, rows)
    }

    private func emitJSON(store: GRDBStore, results: SearchResults,
                          facets: [(String, Int)]?,
                          offset: Int, hasMore: Bool) throws {
        let (folders, engines, rows) = try metadata(store, results)
        let words = explanationWords
        // LE MÊME TYPE QUE LA SORTIE TEXTE ET QUE LE SERVEUR (`HitRelevance`) :
        // la formule vivait ici, à la main, et le JSON ne la publiait pas.
        let relevance = HitRelevance.percentages(bm25: results.hits.map(\.score))
        let extras = try decorations(
            store: store,
            pages: results.hits.map { (docID: $0.docID, page: $0.page,
                                       source: $0.source, snippet: $0.snippet) },
            rows: rows)
        let hits: [[String: Any]] = results.hits.enumerated().map { rank, hit in
            let rowid = Schema.ftsRowID(docID: hit.docID, page: hit.page)
            let time = extras.time(docID: hit.docID, page: hit.page)
            let label = extras.label(docID: hit.docID, page: hit.page, rows: rows)
            // LE constructeur du contrat gelé (CM-21, CM-22) : `score` y est
            // arrondi une fois pour toutes.
            var entry = SearchJSON.hit(
                docID: hit.docID, path: hit.path,
                folder: folders[hit.docID] ?? "", page: hit.page,
                score: hit.score,
                source: GRDBStore.sourceLabel(hit.source.rawValue),
                engine: GRDBStore.engineLabel(engines[rowid] ?? .none),
                fuzzyDistance: hit.fuzzyDistance, snippet: hit.snippet,
                // Forme `doc` quand le volume n'est pas monté ; `&t=` quand la
                // page est une transcription.
                link: Self.link(rows[hit.docID], docID: hit.docID, page: hit.page,
                                time: time),
                relevancePct: relevance[rank], time: time,
                slide: label.slide, embeddedImage: label.embeddedImage)
            if let why = self.why(words: words, text: hit.snippet,
                                  fuzzyDistance: hit.fuzzyDistance,
                                  tableOfContents: hit.tableOfContents,
                                  quorum: results.quorum) {
                entry["why"] = why
            }
            return entry
        }
        var payload: [String: Any] = [
            "query": query,
            "offset": offset,
            "has_more": hasMore,
            "elapsed_ms": JSONNumber.rounded(results.elapsedMS, places: 2),
            "total_pages": results.totalPages,
            "total_docs": results.totalDocs,
            "hits": hits,
        ]
        // LES DEUX CLÉS DU LOT MP1, ADDITIVES. `fuzzy_fallback` n'apparaît que
        // s'il a eu lieu — ce qui est affiché n'est alors plus ce qui a été
        // demandé, et un script qui l'ignore lit au moins les mêmes hits
        // qu'avant. `name_matches` est toujours là quand il y a des noms : c'est
        // un CANAL, pas une note sur les résultats.
        if results.fuzzyFallback { payload["fuzzy_fallback"] = true }
        // LA MÊME MÉCANIQUE POUR LE QUORUM (lot RK2) : la clé n'apparaît que
        // s'il a eu lieu, et elle dit que les pages qui suivent la tête ne
        // portent pas tous les mots.
        if results.quorum { payload["quorum"] = true }
        // `fuzzy_expanded` (lot MC1, PM-13) : additive comme les deux
        // au-dessus. Elle dit qu'une partie des résultats porte une
        // orthographe PROCHE du mot tapé — ce que `fuzzy_fallback`, qui ne
        // parle que du repli, laissait deviner hit par hit.
        if results.fuzzyExpanded { payload["fuzzy_expanded"] = true }
        if !results.nameMatches.isEmpty {
            payload["name_matches"] = try results.nameMatches.map { doc in
                [
                    "doc_id": doc.id,
                    "path": doc.relPath,
                    "folder": doc.topFolder,
                    "link": Self.link(try store.docRow(id: doc.id),
                                      docID: doc.id, page: 1),
                ] as [String: Any]
            }
        }
        // Le filtre de provenance est publié : sans lui, deux exécutions dont
        // les totaux diffèrent seraient indiscernables dans un journal.
        if let source { payload["source"] = source.rawValue }
        if results.totalsApproximate { payload["totals_approximate"] = true }
        if let facets, let key = facet {
            var buckets: [String: Int] = [:]
            for (name, count) in facets { buckets[name] = count }
            payload["facets"] = [key.rawValue: buckets]
        }
        try CLI.printJSON(payload)
    }

    private func formatCount(_ count: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        return f.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private func emitText(store: GRDBStore, results: SearchResults,
                          facets: [(String, Int)]?) throws {
        let pagesStr = results.totalsApproximate
            ? "> \(formatCount(results.totalPages))"
            : "\(results.totalPages)"
        let docsStr = results.totalsApproximate
            ? "> \(formatCount(results.totalDocs))"
            : "\(results.totalDocs)"
        print("\(pagesStr) page(s) in \(docsStr) document(s) "
              + String(format: "in %.2f ms", results.elapsedMS))
        // Le total borné dit que le mot est PARTOUT — et c'est aussi ce qui
        // vient de coûter sept secondes de `ORDER BY bm25` (A1m-08). Le dire
        // avant les résultats : le geste qui répare est un second mot.
        if results.totalsApproximate { print(SearchAdvice.veryCommonWord) }
        // LES NOMS DE FICHIER, sur leur propre ligne : ce sont des DOCUMENTS,
        // pas des pages, et ils ne se mélangent donc pas aux résultats.
        if !results.nameMatches.isEmpty {
            let names = results.nameMatches
                .map { ($0.relPath as NSString).lastPathComponent }
                .joined(separator: " · ")
            print("\(results.nameMatches.count) document(s) whose name matches: "
                  + names)
        }
        if results.hits.isEmpty { print("no result"); return }
        let (folders, _, _) = try metadata(store, results)

        // LE TYPE, PAS LA FORMULE (lot CL2, § « Pour MC4 et CL2 » de MC2) : le
        // même pourcentage se calculait ici à la main et là-bas dans
        // `HitRelevance` — deux copies qui n'avaient rien pour rester
        // identiques, comme `score` et `bm25` avant elles. Le chiffre imprimé
        // ne bouge pas ; il a désormais un seul auteur, et il est publié.
        var percentages: [Int64: Int] = [:]
        let relevance = HitRelevance.percentages(bm25: results.hits.map(\.score))
        for (rank, hit) in results.hits.enumerated() {
            percentages[Schema.ftsRowID(docID: hit.docID, page: hit.page)] =
                relevance[rank]
        }
        for group in ResultGrouping.group(results.hits) {
            let folder = folders[group.docID] ?? ""
            print("")
            print("• [\(group.docID)] \(folder) · \(group.path)")
            // « loaded » et non « matched » : le compte porte sur les hits
            // rendus (limite de la requête), pas sur toutes les pages du document
            // qui répondent (audit A12).
            print("  \(group.pageCount) page(s) loaded, first page "
                  + "\(group.firstPage)")
            for hit in group.hits {
                let pct = percentages[Schema.ftsRowID(docID: hit.docID,
                                                      page: hit.page)] ?? 100
                let fuzzy = hit.fuzzyDistance > 0 ? "  ~d\(hit.fuzzyDistance)" : ""
                let src = GRDBStore.sourceLabel(hit.source.rawValue)
                // Colonnes calées à la main : `%-5d` et `%3d` de
                // `String(format:)` liraient un `Int` sur 32 bits (CM-05), et
                // le seul service qu'ils rendaient ici était l'alignement.
                let page = "\(hit.page)".padding(toLength: max(5, "\(hit.page)".count),
                                                 withPad: " ", startingAt: 0)
                let pctText = String(repeating: " ",
                                     count: max(0, 3 - "\(pct)".count)) + "\(pct)"
                let excerpt = hit.snippet.replacingOccurrences(of: "\n", with: " ")
                print("    p.\(page) \(pctText)%  \(excerpt) [\(src)]\(fuzzy)")
            }
        }
        if let facets, let key = facet, !facets.isEmpty {
            print("")
            print("facet \(key.rawValue):")
            for (name, count) in facets { print("  \(name)  \(count)") }
        }
    }
}
