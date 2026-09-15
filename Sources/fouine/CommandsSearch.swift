// CommandsSearch.swift — `fouine search` (SPEC §4.3, §5.5). Propriété : A-Core.

import Foundation
import ArgumentParser
import FouineCore
import FouineEmbed

/// Le CONTRAT GELÉ d'un résultat (§4.3), en un seul endroit — constat CM-22.
///
/// `docs/cli.md` annonce les clés hybrides « en plus » ; le mode hybride en
/// RETIRAIT quatre : `total_pages` et `total_docs` à la racine, `folder` et
/// `engine` par résultat. Un script qui lit `hits[].folder` cassait dès que
/// l'utilisateur ajoutait `--hybrid`. Deux constructeurs voisins ont divergé
/// parce que rien ne les obligeait à se ressembler : il n'y en a plus qu'un.
enum SearchJSON {

    /// `score` est ARRONDI À 4 DÉCIMALES (constat CM-21) : la CLI publiait
    /// 17 chiffres significatifs (`-39.03995683050397`) dans un contrat gelé
    /// dont d'autres programmes dépendent — ce sont 17 chiffres qui bougeront
    /// au premier changement de FTS5. C'est la même grandeur, et désormais le
    /// même arrondi, que le `bm25` de l'outil MCP.
    ///
    /// `score` est le seul champ OPTIONNEL : un résultat rendu par le seul
    /// canal sémantique n'a pas de score bm25, et en inventer un — 0, par
    /// exemple — serait un chiffre faux dans un contrat gelé.
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

    @Flag(name: .long,
          help: "RRF merge with the semantic search (needs the model and vectors produced by `fouine embed`).")
    var hybrid = false

    /// `--hybrid=auto` N'EST PAS EXPRIMABLE en ArgumentParser (lot CL2) : une
    /// option à valeur FACULTATIVE n'existe pas dans la bibliothèque, et
    /// transformer `--hybrid` en `@Option` aurait fait avaler le mot suivant —
    /// `fouine search --hybrid azote` aurait cherché « --hybrid=azote ». D'où
    /// un drapeau séparé, qui dit la même chose : fusionne si le modèle et les
    /// vecteurs sont là, cherche en plein texte sinon, et ce n'est PAS une
    /// panne (aucune sortie 3, aucun avertissement — c'est ce qui a été
    /// demandé).
    @Flag(name: .customLong("hybrid-auto"),
          help: "Merge with the semantic search when the model and the vectors are there, and search full text otherwise, without failing.")
    var hybridAuto = false

    @Option(name: .long,
            help: "Depth of the merged lists in hybrid mode (200 by default).")
    var depth: Int = HybridSearch.defaultDepth

    @Option(name: .customLong("vec-floor"),
            help: "Drop semantic hits whose margin z is below this (0 disables, the default).")
    var vecFloor: Double = HybridSearch.defaultVectorFloor

    @Option(name: .customLong("lex-weight"),
            help: "Weight of the lexical list in the RRF merge (1 by default).")
    var lexWeight: Double = 1

    @Option(name: .customLong("vec-weight"),
            help: "Weight of the semantic list in the RRF merge (1 by default).")
    var vecWeight: Double = 1

    @Flag(name: .customLong("vec-center"),
          help: "Subtract the corpus mean vector before comparing (calibration).")
    var vecCenter = false

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

    @Flag(name: .customLong("raw-semantic-ranks"),
          help: "Hybrid: fuse the semantic ranks as they are, without rescaling them to the vector coverage (calibration).")
    var rawSemanticRanks = false

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
        guard depth > 0 else {
            throw ValidationError("Depth must be positive.")
        }
        guard lexWeight >= 0, vecWeight >= 0 else {
            throw ValidationError("Weights must be non-negative.")
        }
        guard lexWeight > 0 || vecWeight > 0 else {
            throw ValidationError("At least one of --lex-weight / --vec-weight must be positive.")
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
            // ensemble, p < 0,001). Livrés désarmés, ils sont devenus des
            // options de calibration comme les quatre ci-dessus : `--no-*`
            // les éteint pour le banc.
            //
            // EN HYBRIDE AUSSI, depuis le lot MN1 — décision du 14/09/2026,
            // réversible. Le quorum était désarmé dans ce mode parce que
            // `HybridResults` ne transportait pas le drapeau : la fusion
            // relâchait le ET sans que rien ne le dise, ce qui est exactement
            // ce que `SearchAdvice.quorum` existe pour éviter. Le drapeau
            // voyage depuis le lot MC2 (`HybridResults.quorum`), le serveur MCP
            // l'arme en hybride depuis ce jour-là, et deux surfaces qui disent
            // deux choses des mêmes résultats sont pires qu'une convention
            // discutable : on garde CELLE DU SERVEUR. Ce qui la fonde : le
            // quorum a été jugé au banc en LEXICAL (790 jugements, +0,031
            // nDCG@10, 6 victoires / 43 égalités / 0 défaite) ; en hybride,
            // il reste à rejouer à couverture pleine — d'où « réversible », et
            // `--no-quorum` qui l'éteint dans les deux modes.
            q.quorum = !noQuorum
            q.demoteTableOfContents = !noDemoteTOC
            // Filtres de DOCUMENT (lot U2) : ils portent sur tout l'index, et
            // le chemin hybride les applique donc aux deux canaux comme
            // `dossier:` et `ext:`.
            q.langs = lang
            q.modifiedAfter = since.flatMap { DateWindow.startOfDay(iso8601: $0) }
            // Filtre de PAGE (lot P3), le seul : la provenance est une
            // propriété de la page, pas du document. Le chemin hybride le
            // porte lui aussi, sur ses deux canaux.
            q.sources = source?.value
            // Les marqueurs de surlignage (lot CL2) : le défaut est inchangé,
            // et `TranscriptTime` lit l'ouvrant pour savoir où commence le mot
            // trouvé — d'où la valeur portée par la requête plutôt que par un
            // paramètre de sortie.
            q.snippetMarkers = mark.value
            // RK-01 : une requête à phrase exacte ne consulte pas le sens.
            // Le refus est prononcé ICI, avant de charger le modèle et l'index
            // vectoriel (une seconde de mur pour rien), et la sortie rendue est
            // la sortie LEXICALE complète — facettes, pagination, canal des
            // noms —, exactement comme le repli faute de modèle. `--raw-fts`
            // n'a pas d'analyseur : ses guillemets appartiennent à FTS5.
            var disarmed: SemanticDisarmReason? =
                wantsHybrid && !rawFTS && QueryParser.asksForExactPhrase(query)
                ? .exactPhrase : nil
            if let disarmed { CLI.warn(disarmed.advice) }
            // Le PÉRIMÈTRE du sens, quand il peut changer quelque chose (lot
            // CL2, constat PM-06) : sans cela, `dossier:M2SU --hybrid` chargeait
            // le modèle et l'index vectoriel — quatre secondes — pour comparer
            // zéro vecteur, puis annonçait la couverture GLOBALE comme si elle
            // décrivait le dossier demandé.
            //
            // IL N'A LIEU QUE S'IL PEUT CHANGER QUELQUE CHOSE : sans filtre de
            // document, le périmètre EST l'index, la fusion en connaît déjà les
            // chiffres, et les deux comptes coûtaient **240 ms** mesurés sur la
            // base de production (1 747 → 1 984 ms sur `réacteur piston`) pour
            // réapprendre ce que l'on savait. Même garde que le serveur MCP.
            var scope: SemanticScope?
            if wantsHybrid, disarmed == nil, q.filtersDocuments {
                scope = try Self.semanticScope(store: store, q: q,
                                               negative: negative)
                // `filtered` compte dans la condition : un index qui n'a PAS UN
                // vecteur n'est pas un périmètre mal choisi, et son refus (3,
                // ou le repli de `--hybrid-auto`) dit déjà le bon geste.
                if scope?.vectors == 0, scope?.filtered == true {
                    disarmed = .noVectorsInScope
                }
            }
            // Rien à encoder (`nom:rapport` seul, lot QP1) : la recherche reste
            // lexicale, sans avertissement — il n'y avait pas de sens à chercher.
            if wantsHybrid, disarmed == nil, rawFTS || !semanticText.isEmpty {
                switch try runHybrid(store: store, q: q, negative: negative,
                                     scope: scope) {
                case .handled:
                    return
                case .fallback:
                    break
                }
            }
            if disarmed == .noVectorsInScope, let scope {
                // LA PHRASE CHIFFRÉE, celle qui porte le geste — la même que
                // `note` côté serveur MCP, parce que c'est la MÊME fonction
                // depuis le lot MN1. La raison générique
                // (`SemanticDisarmReason.advice`) dirait deux fois le même fait.
                CLI.warn(SemanticDisarmReason.noVectorsInScopeNote(
                    scope, folders: q.folders))
            }
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
            // même règle que l'avertissement de couverture du mode hybride.
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
                             offset: offset, hasMore: hasMore, disarmed: disarmed,
                             scope: scope)
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

    // MARK: - Hybride (fusion RRF lexical + sémantique, §12)

    /// Le mode hybride a-t-il répondu ?
    private enum HybridOutcome {
        /// La fusion a écrit sa sortie ; il n'y a plus rien à faire.
        case handled
        /// Le canal du sens n'a pas pu servir : l'appelant enchaîne sur le
        /// plein texte.
        case fallback
    }

    /// `--hybrid` ou `--hybrid-auto` : la fusion a été DEMANDÉE.
    private var wantsHybrid: Bool { hybrid || hybridAuto }

    /// Ce que le canal du sens voit du périmètre demandé, AVANT tout chargement
    /// (lot CL2, constat PM-06).
    ///
    /// Deux comptes quand rien ne filtre — le coût est nul, il n'y a rien à
    /// recompter ; deux lectures par document autorisé quand un filtre porte,
    /// soit ~30 ms sur 1 883 documents. C'est à payer avant les quatre secondes
    /// du modèle et de l'index vectoriel, pas après.
    static func semanticScope(store: GRDBStore, q: SearchQuery,
                              negative: String?) throws -> SemanticScope {
        let vectors = try store.vectorisedPageCount()
        let pages = try store.indexedPageCount()
        // Aucun vecteur DU TOUT : le périmètre n'y est pour rien, et ce cas a
        // son propre message (et sa propre sortie) plus bas.
        guard vectors > 0 else {
            return SemanticScope(vectors: 0, pagesIndexed: pages, filtered: false)
        }
        return try HybridSearch.scope(store: store, query: q,
                                      excludingDocsMatching: negative,
                                      vectors: vectors, pagesIndexed: pages)
    }

    /// Rend `.fallback` quand le modèle sémantique n'est pas installé :
    /// l'appelant enchaîne alors sur la recherche plein texte.
    ///
    /// C'est ce que `docs/cli.md` promet depuis `doctor` — « sans lui, `embed`
    /// refuse de partir et `search --hybrid` retombe sur le plein texte » —,
    /// et ce que le code ne faisait pas : il sortait en 1. Le repli est
    /// ANNONCÉ sur l'erreur standard, jamais silencieux, et le JSON porte
    /// `hybrid: false` pour qu'un script sache ce qu'il a réellement obtenu.
    /// Une base SANS VECTEUR reste une erreur : le modèle est là, il n'y a
    /// qu'à lancer `fouine embed`, et taire ce cas cacherait le geste.
    ///
    /// `--hybrid-auto` est l'exception, et c'est toute sa raison d'être : les
    /// deux manques y sont SILENCIEUX et sans erreur — l'appelant a demandé
    /// « fusionne si tu peux », et lui répondre par un avertissement ou par la
    /// sortie 3 serait répondre à une autre demande.
    private func runHybrid(store: GRDBStore, q: SearchQuery,
                           negative: String?,
                           scope: SemanticScope?) throws -> HybridOutcome {
        let directory = EmbedPaths.modelDirectory()
        guard EmbedPaths.modelAvailable(at: directory) else {
            if !hybridAuto {
                CLI.warn("--hybrid ignored: the semantic model is missing from "
                         + "\(directory.path) — `fouine model download` installs "
                         + "it. Falling back to full-text search.")
            }
            return .fallback
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let engine = try E5Encoder(modelDir: directory)
        let tModel = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000

        let t1 = DispatchTime.now().uptimeNanoseconds
        var index = try VectorIndex(store: store, dim: engine.dimension)
        if vecCenter { index = index.centered() }
        let tIndex = Double(DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000

        guard index.count > 0 else {
            if hybridAuto { return .fallback }
            throw FouineError.databaseFailure(
                "no vector in the database — run `fouine embed` first")
        }
        let results = try HybridSearch.run(
            store: store, engine: engine, index: index, query: q,
            excludingDocsMatching: negative, rawQuery: semanticText,
            typedQuery: rawFTS ? "" : query,
            limit: limit, offset: offset, depth: depth,
            lexWeight: lexWeight, vecWeight: vecWeight, vecFloor: vecFloor,
            coverageScaling: !rawSemanticRanks,
            modelLoadMS: tModel, indexLoadMS: tIndex,
            // Le périmètre a déjà été lu pour décider de charger le modèle : le
            // repasser évite de le recompter (deux lectures par document).
            scope: scope)
        // La couverture est dite AVANT les résultats — c'est le contexte dans
        // lequel ils se lisent, pas une note de bas de page (C2-02). Elle est
        // celle du PÉRIMÈTRE depuis le lot CL2 : annoncer « 67,9 % » sur un
        // dossier vectorisé à 3 % décrivait un autre corpus que celui cherché.
        let seen = results.scope
        if seen.pagesIndexed > 0, seen.coveragePct < 50 {
            CLI.warn(String(format: "semantic channel covers %.1f %% of the pages",
                            seen.coveragePct)
                     + " \(seen.filtered ? "searched here" : "in the index")"
                     + " (\(seen.vectors) / \(seen.pagesIndexed))"
                     + " — hybrid results are drawn from that subset;"
                     + " `fouine embed` extends it")
        }
        // LE REPLI EN FLOU AUSSI EN HYBRIDE (lot RK1) : le canal lexical de la
        // fusion passe par `GRDBStore.search`, donc il repliait déjà — sans que
        // ce mode le dise. Même phrase, même canal de sortie que le lexical.
        if results.fuzzyFallback { CLI.warn(SearchAdvice.fuzzyFallback) }
        // LE QUORUM AUSSI, pour la même raison et depuis le lot MN1 : il est
        // désormais armé dans ce mode, donc les pages qui suivent la tête ne
        // portent pas forcément tous les mots — et c'est le contexte dans
        // lequel la liste se lit, pas une note de bas de page.
        if results.quorum { CLI.warn(SearchAdvice.quorum) }
        // CE QUE L'INDEX PORTE VRAIMENT (lot MC1). La phrase « aucun de vos
        // mots » se disait sur le seul « aucune page ne les porte tous » : on
        // lit donc, et seulement dans ce cas, lesquels existent.
        let present = results.lexTotalPages == 0 && !results.hits.isEmpty
            ? try store.wordsPresent(q, excludingDocsMatching: negative) : []
        if json {
            try emitHybridJSON(store: store, results)
        } else {
            emitHybridText(results, wordsPresent: present)
        }
        return .handled
    }

    /// Texte envoyé au modèle : la même fonction que l'application et le
    /// serveur MCP (`QueryParser.semanticText`, lot QP1).
    private var semanticText: String { QueryParser.semanticText(query) }

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
                     lexRank: Int? = nil, vecRank: Int? = nil,
                     tableOfContents: Bool = false,
                     quorum: Bool = false) -> [String: Any]? {
        HitExplanation(words: words, text: text, fuzzyDistance: fuzzyDistance,
                       lexRank: lexRank, vecRank: vecRank,
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

    private func emitHybridText(_ results: HybridResults,
                                wordsPresent: [String] = []) {
        var timing = String(format: "in %.2f ms", results.elapsedMS)
        if let m = results.modelLoadMS, let idx = results.indexLoadMS {
            timing = String(format: "in %.2f ms (model load %.2f ms, index load %.2f ms)",
                            results.elapsedMS, m, idx)
        }
        let coverage = results.pagesIndexed > 0
            ? "(\(results.vectors) vectors, "
              + String(format: "%.1f %% of pages)", results.coveragePct)
            : "(\(results.vectors) vectors)"
        print("\(results.hits.count) hybrid hit(s) — lexical: "
              + "\(results.lexTotalPages) page(s) / \(results.lexTotalDocs) "
              + "document(s), semantic only: \(results.semanticOnly), "
              + "\(timing) \(coverage)")
        // AUCUNE page ne porte les mots, et il y a pourtant des résultats :
        // c'est du sens seul, et le dire est la seule chose honnête à faire
        // (R-04 ; pas de filtre, cf. `SearchAdvice.noLexicalMatch`).
        if results.lexTotalPages == 0, !results.hits.isEmpty {
            print(SearchAdvice.noLexicalMatch(wordsPresent: wordsPresent))
        }
        for hit in results.hits {
            var channels: [String] = []
            if let r = hit.lexRank { channels.append("lex#\(r)") }
            if let r = hit.vecRank {
                // La MARGE, pas le cosinus (C2-13) : « cos 0.85 » se lit comme
                // « 85 % de pertinence » alors que tous les cosinus du corpus
                // tiennent dans 0,78-0,88. Le cosinus reste dans le JSON pour
                // qui sait ce qu'il en fait.
                channels.append("sem#\(r) " + String(format: "z%+.1f", hit.z ?? 0))
            }
            print("")
            // `doc_id` est un `Int64` : `%d` de `String(format:)` le lirait sur
            // 32 bits, comme la taille de `backup` (CM-05). Les entiers passent
            // par l'interpolation ; seul le `rrf` reste formaté.
            print("• [\(hit.docID)] \(hit.path) p.\(hit.page) — "
                  + String(format: "rrf %.4f", hit.rrf)
                  + " · " + channels.joined(separator: " · "))
            let excerpt = (hit.lexical?.snippet ?? hit.preview)
                .replacingOccurrences(of: "\n", with: " ")
            print("    \(excerpt)")
        }
    }

    /// L'objet `semantic_stats` du JSON hybride. Il est PERMANENT : c'est
    /// l'outil qui permet de calibrer un plancher de marge sans deviner, et
    /// c'est aussi ce qui permet à un appelant (script, futur serveur MCP) de
    /// savoir si le canal sémantique avait quelque chose à dire. Le cosinus
    /// seul, lui, ne le dit pas — c'est tout le constat C2-01.
    ///
    /// Quatre décimales sur μ et σ : la bande utile d'e5-small tient dans
    /// 0,10 de cosinus, deux décimales l'écraseraient.
    /// `semantic_scope`, aux clés du serveur MCP : ce que le canal du sens voit
    /// de la recherche DEMANDÉE. « 0 sur 31 986, filtré » est une phrase ;
    /// « 67,85 % » n'en est pas une quand le dossier cherché n'a pas un vecteur.
    private static func scopeJSON(_ scope: SemanticScope) -> [String: Any] {
        ["pages": scope.pagesIndexed,
         "vectorised": scope.vectors,
         "filtered": scope.filtered]
    }

    private static func semanticStatsJSON(_ s: SemanticStats) -> [String: Any] {
        var out: [String: Any] = [
            "mu": JSONNumber.rounded(s.mu, places: 4),
            "sigma": JSONNumber.rounded(s.sigma, places: 4),
            "scanned": s.scanned,
            "zero_vectors": s.zeroVectors,
        ]
        if let c = s.cosMax { out["cos_max"] = JSONNumber.rounded(Double(c), places: 4) }
        if let z = s.zMax { out["z_max"] = JSONNumber.rounded(z, places: 2) }
        if let z = s.zAt10 { out["z_at_10"] = JSONNumber.rounded(z, places: 2) }
        if let z = s.zAt200 { out["z_at_200"] = JSONNumber.rounded(z, places: 2) }
        return out
    }

    private func emitHybridJSON(store: GRDBStore,
                                _ results: HybridResults) throws {
        let words = explanationWords
        // Le lien a besoin du VOLUME, que `HybridHit` ne porte pas ; `folder`
        // et `engine` viennent des mêmes sondes que le mode lexical (CM-22) —
        // une par document sur la clé primaire, une seule pour les pages.
        var rows: [Int64: DocRow] = [:]
        var folders: [Int64: String] = [:]
        for id in Set(results.hits.map(\.docID)) {
            let row = try store.docRow(id: id)
            rows[id] = row
            folders[id] = row?.record.topFolder ?? ""
        }
        let meta = try store.pageMeta(
            for: results.hits.map { (docID: $0.docID, page: $0.page) })
        // EN HYBRIDE, LA PERTINENCE SE LIT SUR LE RRF et non sur le `bm25`
        // (`HitRelevance`, lot MC2) : une page trouvée par le seul canal du
        // sens n'a pas de `bm25`, et la moitié d'une liste hybride serait sans
        // pourcentage.
        let relevance = HitRelevance.percentages(rrf: results.hits.map(\.rrf))
        let sources = results.hits.map { hit -> PageSource in
            let rowid = Schema.ftsRowID(docID: hit.docID, page: hit.page)
            return hit.lexical?.source ?? meta[rowid]?.source ?? .native
        }
        let extras = try decorations(
            store: store,
            pages: zip(results.hits, sources).map {
                (docID: $0.docID, page: $0.page, source: $1,
                 snippet: $0.lexical?.snippet ?? $0.preview)
            },
            rows: rows)
        let hits: [[String: Any]] = results.hits.enumerated().map { rank, hit in
            let rowid = Schema.ftsRowID(docID: hit.docID, page: hit.page)
            let snippet = hit.lexical?.snippet ?? hit.preview
            let time = extras.time(docID: hit.docID, page: hit.page)
            let label = extras.label(docID: hit.docID, page: hit.page, rows: rows)
            var entry = SearchJSON.hit(
                docID: hit.docID, path: hit.path,
                folder: folders[hit.docID] ?? "", page: hit.page,
                score: hit.lexical?.score,
                // Un résultat purement sémantique porte quand même la
                // PROVENANCE de sa page : elle est lue sur `page_src`, comme en
                // lexical, et non déduite du canal qui l'a trouvée.
                source: GRDBStore.sourceLabel(sources[rank].rawValue),
                engine: GRDBStore.engineLabel(meta[rowid]?.engine ?? .none),
                fuzzyDistance: hit.lexical?.fuzzyDistance ?? 0,
                snippet: snippet,
                link: Self.link(rows[hit.docID], docID: hit.docID, page: hit.page,
                                time: time),
                relevancePct: relevance[rank], time: time,
                slide: label.slide, embeddedImage: label.embeddedImage)
            entry["rrf"] = JSONNumber.rounded(hit.rrf, places: 6)
            entry["semantic_only"] = hit.lexical == nil
            if let r = hit.lexRank { entry["lex_rank"] = r }
            if let r = hit.vecRank { entry["vec_rank"] = r }
            if let c = hit.cosine {
                entry["cosine"] = JSONNumber.rounded(Double(c), places: 3)
            }
            if let z = hit.z { entry["z"] = JSONNumber.rounded(z, places: 2) }
            if let why = self.why(words: words,
                                  text: hit.lexical?.snippet ?? hit.preview,
                                  fuzzyDistance: hit.lexical?.fuzzyDistance ?? 0,
                                  lexRank: hit.lexRank, vecRank: hit.vecRank,
                                  // `partial` ET NON `exact` EN HYBRIDE AUSSI
                                  // (lot MN1) : le quorum y est armé, et `why`
                                  // annonçait « exact » avec neuf mots sur une
                                  // page qui en porte trois.
                                  quorum: results.quorum) {
                entry["why"] = why
            }
            return entry
        }
        var payload: [String: Any] = [
            "query": query,
            "offset": results.offset,
            "has_more": results.hasMore,
            "hybrid": true,
            "elapsed_ms": JSONNumber.rounded(results.elapsedMS, places: 2),
            // LES DEUX CLÉS DU SCHÉMA GELÉ, RENDUES (CM-22). Elles valent les
            // totaux LEXICAUX — la seule population que l'on sache compter :
            // le canal sémantique rend un voisinage, pas un ensemble de pages
            // appariées. `lex_total_*` restent, à l'identique, pour qui les
            // lit déjà.
            "total_pages": results.lexTotalPages,
            "total_docs": results.lexTotalDocs,
            "lex_total_pages": results.lexTotalPages,
            "lex_total_docs": results.lexTotalDocs,
            "semantic_only": results.semanticOnly,
            "semantic_floor": results.semanticFloor,
            "semantic_kept": results.semanticKept,
            "vectors": results.vectors,
            "pages_indexed": results.pagesIndexed,
            // L'échelle des rangs sémantiques dans la fusion (lot R1) : 1 quand
            // tout est vectorisé ou avec --raw-semantic-ranks.
            "semantic_rank_scale": JSONNumber.rounded(results.semanticRankScale, places: 2),
            // `coveragePct` EST DÉJÀ un pourcentage (vectors × 100 / pages) :
            // le multiplier de nouveau publiait « 1718.86 » pour 17,2 % de
            // couverture, mesuré sur la base de production (A1m-01).
            //
            // C'est celle du PÉRIMÈTRE depuis le lot CL2, comme côté serveur :
            // `vectors` et `pages_indexed` disent l'index entier, `semantic_scope`
            // dit ce que la recherche demandée voit. Les trois valent la même
            // chose quand aucun filtre de document ne porte.
            "semantic_coverage_pct": JSONNumber.percentage(results.scope.coveragePct,
                                                           places: 2),
            "semantic_scope": Self.scopeJSON(results.scope),
            "hits": hits,
        ]
        if let source { payload["source"] = source.rawValue }
        // La MÊME clé additive qu'en lexical (lot MP1) : le repli agissait déjà
        // sur le canal lexical de la fusion, il se lit maintenant dans les deux
        // modes.
        if results.fuzzyFallback { payload["fuzzy_fallback"] = true }
        // LE QUORUM, MÊME CLÉ ET MÊME RÈGLE QU'EN LEXICAL (lot MN1) : présente
        // seulement quand il a eu lieu, et un script qui lit les deux modes n'a
        // plus à savoir lequel relâche le ET.
        if results.quorum { payload["quorum"] = true }
        if let m = results.modelLoadMS {
            payload["model_load_ms"] = JSONNumber.rounded(m, places: 2)
        }
        if let idx = results.indexLoadMS {
            payload["index_load_ms"] = JSONNumber.rounded(idx, places: 2)
        }
        payload["semantic_stats"] = Self.semanticStatsJSON(results.semantic)
        try CLI.printJSON(payload)
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
                          offset: Int, hasMore: Bool,
                          disarmed: SemanticDisarmReason? = nil,
                          scope: SemanticScope? = nil) throws {
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
            // Le MÊME constructeur qu'en hybride (CM-21, CM-22) : `score` y est
            // arrondi, et aucune des deux sorties ne peut plus perdre une clé
            // que l'autre porte.
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
        // `hybrid` n'apparaît que si l'utilisateur l'a DEMANDÉ : à `false`, il
        // dit qu'il y a eu repli faute de modèle. Une recherche ordinaire garde
        // exactement les clés du §4.3, sans champ de plus.
        if wantsHybrid { payload["hybrid"] = false }
        // LE PÉRIMÈTRE DU SENS, MÊME QUAND LE SENS N'A PAS SERVI (lot CL2) :
        // c'est le repli qui a le plus besoin de l'expliquer — « 0 vecteur sur
        // 31 986 pages, filtré » dit pourquoi la réponse est lexicale. Les deux
        // clés ne sortent que si la fusion a été demandée ET qu'un filtre de
        // document a fait lire le périmètre : une recherche ordinaire garde le
        // §4.3 intact, et un repli sans filtre ne paie pas deux comptes pour
        // republier ce que `vectors` et `pages_indexed` diraient.
        if wantsHybrid, let scope {
            payload["semantic_coverage_pct"] =
                JSONNumber.percentage(scope.coveragePct, places: 2)
            payload["semantic_scope"] = Self.scopeJSON(scope)
        }
        // POURQUOI le repli, quand ce n'est pas le modèle qui manque (RK-01) :
        // `hybrid: false` seul ferait croire à une installation incomplète.
        if let disarmed { payload["hybrid_disarmed"] = disarmed.rawValue }
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
