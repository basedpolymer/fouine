// SearchModel.swift — état de la recherche (SPEC §5.6). Propriété : A-App.
//
// Contraintes tenues ici :
//   · toute recherche part hors du fil principal, avec annulation de la
//     précédente à chaque frappe (anti-rebond 250 ms) ;
//   · `elapsed_ms` et le compte total sont affichés, comme dans la CLI ;
//   · les facettes se recalculent APRÈS les résultats, dans une tâche séparée :
//     elles coûtent cinq requêtes de plus et ne doivent pas retarder l'affichage.

import Foundation
import SwiftUI
import FouineCore

/// `Codable` pour la fenêtre d'aperçu détachée (UX-17) : une scène
/// `WindowGroup(id:for:)` transporte sa valeur et la sérialise pour la
/// restauration d'état de macOS, ce qui l'exige.
struct HitKey: Hashable, Codable, Sendable {
    let docID: Int64
    let page: Int
}

/// Clé de tri des résultats (audit U4 : « pas de tri, toujours le score »).
///
/// AUCUN de ces tris n'est poussé dans la requête : `SearchQuery` est une
/// interface GELÉE (§4.2) et n'a pas de champ d'ordre ; le moteur classe par
/// `bm25` (ou `fz`, `r` en flou) et c'est cet ordre-là qui décide QUELS
/// résultats la tranche de 200 rapporte. Trier autrement ne peut donc porter
/// que sur le jeu CHARGÉ — et l'interface le dit, plutôt que de laisser croire
/// à un tri de tout l'index.
enum SortOrder: String, CaseIterable, Identifiable {
    case score, dateDesc, dateAsc, title, path

    var id: String { rawValue }

    var label: String {
        switch self {
        case .score:    return String(localized: "Relevance")
        case .dateDesc: return String(localized: "Modification date (newest first)")
        case .dateAsc:  return String(localized: "Modification date (oldest first)")
        case .title:    return String(localized: "File name (A → Z)")
        case .path:     return String(localized: "Path (A → Z)")
        }
    }

    var shortLabel: String {
        switch self {
        case .score:    return String(localized: "relevance")
        case .dateDesc: return String(localized: "date ↓")
        case .dateAsc:  return String(localized: "date ↑")
        case .title:    return String(localized: "name")
        case .path:     return String(localized: "path")
        }
    }

    var symbol: String {
        switch self {
        case .score:             return "arrow.up.arrow.down"
        case .dateDesc, .dateAsc: return "calendar"
        case .title:             return "textformat.abc"
        case .path:              return "folder"
        }
    }
}

/// Portée documentaire de la recherche (§5.6, `SearchQuery.inDocIDs`).
enum DocScope: Equatable {
    case all
    case document(id: Int64, name: String)
    case results(ids: [Int64])

    var docIDs: [Int64] {
        switch self {
        case .all: return []
        case .document(let id, _): return [id]
        case .results(let ids): return ids
        }
    }

    var label: String? {
        switch self {
        case .all: return nil
        case .document(_, let name): return String(localized: "in “\(name)”")
        case .results(let ids):
            return String(localized: "in the \(ids.count) document(s) found")
        }
    }
}

/// Clés de préférence propres à la recherche.
///
/// En extension et non dans `Prefs` lui-même : `AppPaths.swift` porte les
/// emplacements et les réglages généraux, et une clé qui n'a de sens que pour
/// `SearchModel` se lit mieux à côté de lui.
extension Prefs {
    /// Tri des résultats (`SortOrder.rawValue`). Absent = `.score`, le tri
    /// d'origine — une préférence absente ne doit jamais changer l'affichage.
    static let sortOrder = "search.sort"
    /// Dernière recherche VALIDÉE, avec ses filtres et sa page (UX, R-11),
    /// sérialisée en JSON. Absente = rien à rejouer, ce qui est le cas d'une
    /// installation neuve et de quiconque a vidé le champ avant de quitter.
    static let lastSession = "search.lastSession"
}

/// Fenêtre de date des puces de filtre (R-07).
///
/// ANNÉES CIVILES : « cette année » veut dire « depuis le 1ᵉʳ janvier », pas
/// « depuis douze mois » — c'est déjà ce que dit la facette « Années », et le
/// même mot doit désigner la même chose aux deux endroits de la barre latérale.
/// Le calcul lui-même vit dans `DateWindow` (FouineCore), partagé avec
/// `fouine search --since`.
enum DateFilter: String, Codable, CaseIterable {
    case any, thisYear, lastFiveYears

    /// Borne à poser dans `SearchQuery.modifiedAfter`, ou `nil` pour « aucune ».
    func modifiedAfter(now: Date = Date(),
                       calendar: Calendar = .current) -> Double? {
        switch self {
        case .any: return nil
        case .thisYear: return DateWindow.startOfYear(now, calendar: calendar)
        case .lastFiveYears:
            return DateWindow.startOfYear(now, yearsBack: 4, calendar: calendar)
        }
    }
}

/// Ce que Fouine retrouve au lancement suivant (R-11) : la dernière requête
/// VALIDÉE — pas le texte en cours de frappe —, ses filtres, et la page qui
/// était sous les yeux.
///
/// La PORTÉE (`DocScope`) n'en fait pas partie, délibérément : « dans les 12
/// documents trouvés » est une liste de `doc_id` d'une session précédente, que
/// l'indexation a pu vider ; la rejouer aurait rendu une recherche vide sans
/// que rien ne le dise.
struct SearchSession: Codable, Equatable {
    var text: String
    var folders: [String] = []
    var exts: [String] = []
    var years: [String] = []
    var sources: [String] = []
    var langs: [String] = []
    var date: DateFilter = .any
    var selectionDocID: Int64?
    var selectionPage: Int?
    /// Optionnel, et non `= []` : une session écrite AVANT DD1 n'a pas la
    /// clé, et le décodage synthétisé refuserait de la lire.
    var docYears: [String]?
}

@MainActor
final class SearchModel: ObservableObject {

    // Saisie
    @Published var text = ""
    @Published var suggestions: [String] = []
    @Published var history: [String] =
        Prefs.defaults.stringArray(forKey: Prefs.history) ?? []

    // Options (§5.6)
    @Published var fuzzy: FuzzyMode = .auto { didSet { persistOptions(); rerun() } }
    @Published var fuzzyScope: FuzzyScope = .ocrOnly { didSet { persistOptions(); rerun() } }
    @Published var scope: DocScope = .all { didSet { rerun() } }

    /// Tri d'affichage. `regroup()` et non `rerun()` : le tri ne change pas la
    /// requête, il réordonne ce qui est déjà là (voir `SortOrder`).
    @Published var sortOrder: SortOrder = .score {
        didSet {
            guard sortOrder != oldValue else { return }
            Prefs.defaults.set(sortOrder.rawValue, forKey: Prefs.sortOrder)
            regroup()
            // Revenir à « pertinence » INTERROMPT le chargement en cours : le
            // sélecteur reste actif pendant qu'il tourne, et c'est le seul
            // moyen de renoncer.
            if sortOrder == .score { stopSortLoad() } else { startSortLoad() }
        }
    }

    // Filtres de facettes
    @Published var selectedFolders: Set<String> = [] { didSet { rerun() } }
    @Published var selectedExts: Set<String> = [] { didSet { rerun() } }
    /// L'année n'est pas exprimable dans `SearchQuery` : elle filtre l'AFFICHAGE
    /// du jeu chargé, ce que l'interface dit explicitement.
    @Published var selectedYears: Set<String> = [] { didSet { regroup() } }
    /// L'année INSCRITE dans le document (DD1, PR-07 : `DocRecord.docDate`).
    /// Filtre d'affichage comme l'année du fichier — `SearchQuery` reste
    /// gelée —, et la facette `doc_year` du moteur en donne les valeurs.
    @Published var selectedDocYears: Set<String> = [] { didSet { regroup() } }
    /// Provenance du texte (lot P3) : VRAI filtre depuis le 05/09/2026 —
    /// `SearchQuery.sources`, une jointure sur `page_src`. C'était le dernier
    /// filtre d'affichage à se faire passer pour une requête : il cachait des
    /// pages déjà chargées pendant que les totaux, « Charger plus » et les
    /// autres facettes continuaient de compter les pages cachées.
    @Published var selectedSources: Set<String> = [] { didSet { rerun() } }
    /// Langue du document (R-10) : VRAI filtre, comme dossier et extension —
    /// `docs.lang` est une colonne, pas une propriété de la page affichée.
    @Published var selectedLangs: Set<String> = [] { didSet { rerun() } }
    /// Fenêtre de date des puces « Cette année » / « 5 dernières années »
    /// (R-07). Vraie requête elle aussi : `SearchQuery.modifiedAfter`.
    @Published var dateFilter: DateFilter = .any { didSet { rerun() } }

    // Résultats
    @Published private(set) var hits: [Hit] = []
    @Published private(set) var groups: [DocGroup] = []
    @Published private(set) var docRows: [Int64: DocRow] = [:]
    @Published private(set) var totalPages = 0
    @Published private(set) var totalDocs = 0
    @Published private(set) var totalsApproximate = false
    /// La recherche exacte n'a rien rendu et le moteur a rejoué la requête en
    /// tolérant les fautes, sur tous les documents (lot MP1, C2-08). Ce qui est
    /// affiché n'est donc pas ce qui a été tapé : la ligne sous le champ le dit.
    @Published private(set) var fuzzyFallback = false
    /// Moins de dix pages portaient TOUS les mots et le moteur a montré aussi
    /// celles qui en portent la plupart (lot RK2, RK-04). ARMÉ par défaut dans
    /// le cœur depuis le 11/09/2026 (`SearchQuery.quorum`), que l'application
    /// ne désarme jamais. Le
    /// drapeau vient donc des résultats, et la ligne sous le champ le dit.
    @Published private(set) var quorum = false
    /// Documents dont le NOM DE FICHIER répond (lot MP1, PR-02), au plus cinq.
    /// Ce ne sont pas des résultats : ils s'affichent au-dessus, et ne touchent
    /// ni les comptes ni l'ordre des pages.
    @Published private(set) var nameMatches: [DocumentListing] = []
    @Published private(set) var elapsedMS: Double = 0
    @Published private(set) var isSearching = false
    @Published private(set) var isFaceting = false
    @Published private(set) var canLoadMore = false
    /// La ligne « Charger plus » a-t-elle le droit de se déclencher SEULE en
    /// apparaissant (audit A10.3) ?
    ///
    /// `canLoadMore` compare `hits.count` au total du moteur et ignore le filtre
    /// client (l'année, seule de son espèce depuis le lot P3) : quand ce filtre
    /// vide la liste, la ligne se
    /// retrouve visible d'emblée et rejoue la requête par tranches de 200 jusqu'à
    /// épuisement, sans un geste de l'utilisateur. Le chargement automatique n'est
    /// donc rearmé que si le DERNIER chargement a rendu au moins un hit VISIBLE ;
    /// sinon le bouton reste là, mais il faut cliquer.
    @Published private(set) var autoLoadMore = false
    /// Fouine charge les tranches suivantes POUR POUVOIR TRIER (PR-08).
    ///
    /// Trier par date les 200 premiers résultats d'un fonds de 29 000 pages ne
    /// rend pas les 200 plus récents : cela remet en ordre les plus pertinents.
    /// « Montre-moi le document le plus récent qui parle de X » n'avait donc
    /// pas de réponse. Dès qu'un ordre autre que la pertinence est demandé, le
    /// jeu est chargé en entier — jusqu'au plafond `sortLoadCap` — avant d'être
    /// trié, et la ligne de tri dit que c'est en cours.
    @Published private(set) var isLoadingForSort = false
    @Published var errorText: String?
    /// Les étiquettes des racines, telles que la barre latérale les affiche.
    /// Posées par `AppModel` à chaque relecture des racines : `SearchModel` ne
    /// lit pas la base lui-même, et `dossier:Xyz` doit être confronté à cette
    /// liste AVANT d'être envoyé au moteur (idée 5 de l'audit A1).
    var knownFolders: [String] = []
    @Published private(set) var facets: [FacetKey: [(String, Int)]] = [:]
    /// Pages touchées par document sur TOUT le jeu, pas seulement sur la
    /// tranche chargée (audit A12). Rempli en différé, après les facettes :
    /// vide tant qu'il ne l'est pas, et l'en-tête de groupe le dit alors.
    @Published private(set) var matchedPageCounts: [Int64: Int] = [:]
    @Published private(set) var terms: [HighlightTerm] = []
    /// Termes exclus (`-terme`) de la requête exécutée. Affichés comme une
    /// pastille de filtre : jusqu'ici l'exclusion était non seulement
    /// inopérante, mais invisible — « rien ne trahit la cause » (audit F1).
    @Published private(set) var excludedTerms: [String] = []
    @Published private(set) var executedText = ""
    /// Moteur par page (natif / Vision / importé), chargé en différé après les
    /// résultats — cf. StoreService.engines(for:).
    @Published private(set) var engines: [HitKey: OCREngineID] = [:]

    // Sélection
    @Published var selection: HitKey? {
        didSet {
            explainSelection()
            // La page qu'on regardait fait partie de « où j'en étais ».
            rememberSession()
        }
    }

    /// Pourquoi le résultat SÉLECTIONNÉ est là (lot U1, R-06). Calculée à la
    /// sélection, sur le texte entier de la page — pas sur toutes les lignes :
    /// une phrase par ligne serait un mur, et il faudrait lire autant de pages
    /// qu'il y a de résultats affichés.
    ///
    /// `nil` tant que la tâche n'a pas répondu, et remise à `nil` DÈS que la
    /// sélection change : une phrase périmée sous une autre page est pire que
    /// pas de phrase.
    @Published private(set) var selectionExplanation: HitExplanation?

    static let pageSize = 200

    /// Plafond du chargement pour trier (PR-08) : au-delà, on s'arrête et on le
    /// DIT. Dix tranches de 200, soit une poignée de secondes sur le fonds de
    /// référence — au-delà, l'attente ne se justifierait plus par ce qu'elle
    /// apporte : les 2 000 meilleurs résultats d'une requête contiennent déjà
    /// le document le plus récent dans tous les cas mesurés.
    static let sortLoadCap = 2_000

    /// Exclusions de la requête EXÉCUTÉE, sous la forme attendue par
    /// `GRDBStore.search(_:excludingDocsMatching:)`.
    ///
    /// Retenue ici parce qu'elle survit à la recherche initiale : « Charger
    /// plus » et les facettes rejouent la requête bien après, et chacun doit
    /// rejouer AUSSI ses exclusions (audit F1).
    /// `private(set) internal` : les tests la lisent.
    private(set) var executedNegative: String?

    private let service: StoreService
    private var debounceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var facetTask: Task<Void, Never>?
    /// Chargement différé des moteurs OCR — suivi et annulé comme les autres
    /// (audit A10.8).
    private var enginesTask: Task<Void, Never>?
    /// Lecture de la page pour la phrase « pourquoi ce résultat » : annulable
    /// comme les autres, et gardée par la génération courante.
    private var explainTask: Task<Void, Never>?
    /// Numéro de la recherche en cours. Sert de garde aux tâches différées :
    /// une réponse de la recherche *n* ne doit rien fusionner dans la *n+1*.
    private var generation = 0
    /// Arme les `didSet` groupés (remise à zéro des filtres) pour ne relancer
    /// qu'une seule recherche.
    private var suppressRerun = false
    /// Chargement des tranches suivantes pour trier (PR-08) : suivi et annulé
    /// comme les autres tâches différées.
    private var sortLoadTask: Task<Void, Never>?
    init(service: StoreService) {
        self.service = service
        if let raw = Prefs.defaults.string(forKey: Prefs.fuzzyMode),
           let mode = FuzzyMode(rawValue: raw) { fuzzy = mode }
        if let raw = Prefs.defaults.string(forKey: Prefs.fuzzyScope),
           let s = FuzzyScope(rawValue: raw) { fuzzyScope = s }
        if let raw = Prefs.defaults.string(forKey: Prefs.sortOrder),
           let order = SortOrder(rawValue: raw) { sortOrder = order }
    }

    // MARK: - Saisie

    func textChanged() {
        suggestions = service.suggestions(prefix: lastWord(of: text))
        debounceTask?.cancel()
        // « Chercher pendant que je tape » éteint (AP1) : la frappe ne fait
        // plus que proposer des mots, c'est ⏎ (`submit()`) qui cherche. Relu
        // ICI et non retenu à l'ouverture de la fenêtre : le réglage se change
        // dans les Réglages, et il doit valoir dès la touche suivante.
        guard Prefs.searchesAsYouType else { return }
        let snapshot = text
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            // La saisie n'a pas bougé ET diffère de la requête déjà exécutée
            // (sinon on relancerait la même recherche après chaque submit()).
            guard self.text == snapshot, snapshot != self.executedText else { return }
            self.execute(remember: false)
        }
    }

    func submit() {
        debounceTask?.cancel()
        suggestions = []
        execute(remember: true)
    }

    func applySuggestion(_ term: String) {
        var words = text.split(separator: " ", omittingEmptySubsequences: false)
                        .map(String.init)
        if words.isEmpty { words = [""] }
        words[words.count - 1] = term
        text = words.joined(separator: " ")
        suggestions = []
        submit()
    }

    private func lastWord(of s: String) -> String {
        String(s.split(separator: " ", omittingEmptySubsequences: false).last ?? "")
    }

    private func rerun() {
        guard !suppressRerun else { return }
        guard !executedText.isEmpty || !text.isEmpty else { return }
        execute(remember: false)
    }

    var hasFilters: Bool {
        !selectedFolders.isEmpty || !selectedExts.isEmpty || !selectedYears.isEmpty
            || !selectedDocYears.isEmpty
            || !selectedSources.isEmpty || !selectedLangs.isEmpty
            || dateFilter != .any || scope != .all
    }

    // MARK: - Filtres en un clic (R-07)

    /// Les puces reposent sur les MÊMES états que les facettes : une puce n'est
    /// pas un filtre de plus, c'est un raccourci vers un filtre existant. Une
    /// puce cochée se décoche donc en cliquant la valeur correspondante dans la
    /// facette, et réciproquement — deux commandes qui se contrediraient
    /// seraient pires que l'absence de l'une des deux.

    /// « PDF seulement » : vraie requête (`SearchQuery.exts`).
    var pdfOnly: Bool { selectedExts == ["pdf"] }
    func togglePDFOnly() { selectedExts = pdfOnly ? [] : ["pdf"] }

    /// Les provenances scannées, telles que `GRDBStore.sourceLabel` les nomme.
    static let scannedSources: Set<String> = ["ocr_accurate"]

    /// « Pages scannées seulement » : vraie requête (`SearchQuery.sources`),
    /// comme « PDF seulement » et les deux puces de date. La provenance est une
    /// propriété de la PAGE et non du document — un même livre peut porter des
    /// pages tapées et des planches scannées —, et c'est le seul filtre du
    /// moteur qui joigne `page_src`.
    var scannedOnly: Bool { selectedSources == Self.scannedSources }
    func toggleScannedOnly() {
        selectedSources = scannedOnly ? [] : Self.scannedSources
    }

    /// Une puce de date active se désactive d'un clic, comme les autres.
    func toggleDate(_ filter: DateFilter) {
        dateFilter = (dateFilter == filter) ? .any : filter
    }

    /// Filtres appliqués à l'AFFICHAGE seulement — l'année, et elle seule depuis
    /// le lot P3 : ce sont eux qui peuvent masquer une tranche entière de
    /// résultats chargée par le moteur.
    var hasDisplayFilters: Bool { !selectedYears.isEmpty || !selectedDocYears.isEmpty }

    func clearFilters() {
        guard hasFilters else { return }
        suppressRerun = true
        selectedFolders = []
        selectedExts = []
        selectedYears = []
        selectedDocYears = []
        selectedSources = []
        selectedLangs = []
        dateFilter = .any
        scope = .all
        suppressRerun = false
        execute(remember: false)
    }

    // MARK: - Exécution

    func execute(remember: Bool) {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        facetTask?.cancel()
        enginesTask?.cancel()
        explainTask?.cancel()
        // Une nouvelle requête arrête net le chargement pour trier : ses
        // tranches parleraient de la requête précédente (PR-08).
        stopSortLoad()
        // Toute recherche ouvre une génération : ce qui revient d'une tâche
        // différée plus ancienne est jeté (audit A10.8).
        generation &+= 1

        guard !input.isEmpty else {
            hits = []; groups = []; docRows = [:]
            totalPages = 0; totalDocs = 0; totalsApproximate = false; elapsedMS = 0
            facets = [:]; terms = []; excludedTerms = []; errorText = nil
            executedText = ""; executedNegative = nil; matchedPageCounts = [:]
            canLoadMore = false; autoLoadMore = false
            selection = nil
            // Les deux fanions de travail retombent ICI (audit A2-01). Les
            // tâches qui viennent d'être annulées sortent toutes par un
            // `if Task.isCancelled { return }` placé AVANT le `isSearching =
            // false` (et avant le `defer` qui rabaisse `isFaceting`) : sans
            // ces deux lignes, vider le champ pendant qu'une recherche est en
            // vol laissait la ligne d'état bloquée sur « recherche… » jusqu'à
            // la requête suivante.
            isSearching = false; isFaceting = false
            selectionExplanation = nil
            fuzzyFallback = false; nameMatches = []
            quorum = false
            return
        }
        if remember {
            rememberQuery(input)
            // La session ne suit que les requêtes VALIDÉES : ce que l'anti-rebond
            // exécute pendant la frappe n'est pas encore une question posée.
            sessionQuery = input
        }

        executedText = input
        terms = QueryTerms.extract(from: input)
        excludedTerms = QueryTerms.excluded(from: input)
        // Comptes de la recherche PRÉCÉDENTE : les garder ferait afficher, le
        // temps que la tâche différée réponde, des « pages touchées » qui ne
        // parlent pas de la requête en cours (audit A12).
        matchedPageCounts = [:]
        errorText = nil
        isSearching = true

        let plan: (query: SearchQuery, negative: String?)
        do { plan = try buildPlan(input: input, offset: 0) } catch {
            isSearching = false
            errorText = ErrorText.describe(error)
            hits = []; groups = []; totalPages = 0; totalDocs = 0
            executedNegative = nil
            return
        }
        executedNegative = plan.negative

        runLexical(query: plan.query, negative: plan.negative, append: false)
        loadFacets(input: input)
        rememberSession()
    }

    func loadMore() {
        guard canLoadMore, !isSearching, !executedText.isEmpty else { return }
        let offset = hits.count
        // `buildPlan` et non `buildQuery` : la tranche suivante doit porter les
        // MÊMES exclusions que la première, sinon « Charger plus » réintroduit
        // les documents que `-terme` venait d'écarter (audit F1).
        guard let plan = try? buildPlan(input: executedText, offset: offset)
        else { return }
        isSearching = true
        runLexical(query: plan.query, negative: plan.negative, append: true)
    }

    /// La recherche. La garde de génération écarte ce qui revient d'une
    /// requête plus ancienne.
    private func runLexical(query: SearchQuery, negative: String?, append: Bool) {
        let generation = self.generation
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await self.service.search(
                    query, excludingDocsMatching: negative)
                if Task.isCancelled || generation != self.generation { return }
                let rows = try await self.service.docRows(ids: results.hits.map(\.docID))
                if Task.isCancelled || generation != self.generation { return }
                self.apply(results: results, rows: rows, append: append)
            } catch {
                if Task.isCancelled || generation != self.generation { return }
                self.isSearching = false
                self.errorText = ErrorText.describe(error)
                if !append {
                    self.hits = []; self.groups = []
                    self.totalPages = 0; self.totalDocs = 0
                }
            }
        }
    }

    private func apply(results: SearchResults, rows: [Int64: DocRow], append: Bool) {
        // Combien de hits le filtre client laissait passer AVANT ce chargement :
        // c'est la référence qui dit si celui-ci a apporté quelque chose de
        // visible (audit A10.3). `groups` porte déjà le jeu filtré du dernier
        // `regroup()` — inutile de refiltrer, ce qui coûterait un `DateFormatter`
        // par hit quand un filtre d'année est actif (A10.11).
        let visibleBefore = append ? groups.reduce(0) { $0 + $1.hits.count } : 0
        hits = append ? hits + results.hits : results.hits
        docRows = append ? docRows.merging(rows) { _, new in new } : rows
        loadEngines(for: results.hits, append: append)
        // Les deux canaux du lot MP1. La tranche SUIVANTE (« Charger plus ») ne
        // lit pas les noms — le moteur ne les rend qu'au premier appel — et ne
        // doit donc pas effacer le bandeau.
        fuzzyFallback = results.fuzzyFallback
        quorum = results.quorum
        if !append { nameMatches = results.nameMatches }
        totalPages = results.totalPages
        totalDocs = results.totalDocs
        totalsApproximate = results.totalsApproximate
        elapsedMS = results.elapsedMS
        canLoadMore = hits.count < results.totalPages && !results.hits.isEmpty
        isSearching = false
        regroup()
        let visibleAfter = groups.reduce(0) { $0 + $1.hits.count }
        autoLoadMore = canLoadMore && visibleAfter > visibleBefore
        restoreSelection()
        // Une recherche neuve rend un jeu de 200 : si un ordre autre que la
        // pertinence est en place — il est PERSISTÉ d'une session à l'autre —,
        // le chargement repart tout seul. Sans cela, il faudrait quitter le tri
        // puis y revenir pour retrouver un classement complet.
        if !append { startSortLoad() }
    }

    /// Pourquoi la page sélectionnée est là. Rien ne bloque : la phrase paraît
    /// quand elle est prête, et elle ne paraît pas du tout s'il n'y a rien
    /// d'honnête à dire.
    private func explainSelection() {
        explainTask?.cancel()
        // AVANT la lecture, pas après : sans cette ligne, la phrase de la page
        // précédente resterait affichée sous la nouvelle le temps du trajet.
        selectionExplanation = nil
        guard let key = selection, !executedText.isEmpty else { return }
        let words = HitExplanation.words(ofQuery: executedText)
        guard !words.isEmpty else { return }
        guard let hit = hits.first(where: {
            HitKey(docID: $0.docID, page: $0.page) == key
        }) else { return }
        let generation = self.generation
        explainTask = Task { [weak self] in
            guard let self else { return }
            let explanation = try? await self.service.explanation(
                docID: key.docID, page: key.page, words: words,
                fuzzyDistance: hit.fuzzyDistance,
                fallbackText: hit.snippet)
            if Task.isCancelled || generation != self.generation
                || self.selection != key { return }
            self.selectionExplanation = explanation
        }
    }

    /// La sélection survit à un rechargement si sa page est toujours là ; sinon
    /// elle retombe sur la première ligne visible.
    private func restoreSelection() {
        // La page d'une session précédente, si elle est encore là (R-11). Elle
        // n'est proposée qu'une fois : la recherche suivante n'a plus à s'en
        // souvenir.
        if let wanted = pendingSelection {
            pendingSelection = nil
            if hits.contains(where: {
                HitKey(docID: $0.docID, page: $0.page) == wanted
            }) {
                selection = wanted
                return
            }
        }
        if selection == nil || !hits.contains(where: {
            HitKey(docID: $0.docID, page: $0.page) == selection
        }) {
            selection = groups.first.flatMap { g in
                g.hits.first.map { HitKey(docID: $0.docID, page: $0.page) }
            }
        } else {
            // Même page, mais la requête a pu changer (une facette, un mot de
            // plus) : la phrase « pourquoi » aussi. Sans cette relance, elle
            // resterait celle de la recherche précédente.
            explainSelection()
        }
    }

    func regroup() {
        let visible = filteredHits
        var built = ResultGrouping.group(visible)
        // Le vrai compte de pages touchées, quand il est arrivé (audit A12).
        if !matchedPageCounts.isEmpty {
            built = built.map { group in
                DocGroup(docID: group.docID, path: group.path, score: group.score,
                         pageCount: group.pageCount, firstPage: group.firstPage,
                         hits: group.hits,
                         matchedPageCount: matchedPageCounts[group.docID])
            }
        }
        groups = sorted(built)
        // Un filtre d'affichage qui ne laisse plus rien passer désarme le
        // chargement automatique : la ligne « Charger plus » deviendrait visible
        // sur-le-champ et enchaînerait les tranches de 200 toute seule (A10.3).
        if visible.isEmpty { autoLoadMore = false }
    }

    /// Applique le tri demandé AUX GROUPES.
    ///
    /// Trier les groupes et non les pages : le regroupement par document est la
    /// forme d'affichage (§5.1), et trier les pages en travers des documents
    /// casserait les groupes. Les pages d'un document restent dans leur ordre
    /// numérique. `.score` ne réordonne rien : `ResultGrouping.group` a déjà
    /// classé par score D-R5.
    private func sorted(_ groups: [DocGroup]) -> [DocGroup] {
        switch sortOrder {
        case .score:
            return groups
        case .dateDesc:
            return groups.sorted { mtime($0) > mtime($1) }
        case .dateAsc:
            return groups.sorted { mtime($0) < mtime($1) }
        case .title:
            return groups.sorted {
                fileName($0.path).localizedStandardCompare(fileName($1.path))
                    == .orderedAscending
            }
        case .path:
            return groups.sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
        }
    }

    /// `mtime` d'un document, 0 si sa ligne `docs` n'est pas encore chargée —
    /// un tri stable vaut mieux qu'un ordre qui saute quand `docRows` arrive.
    private func mtime(_ group: DocGroup) -> Double {
        docRows[group.docID]?.record.mtime ?? 0
    }

    /// Le tri porte-t-il sur un jeu PARTIEL ? L'interface doit le dire : trier
    /// par date les 200 premiers résultats d'un total de 5 000 ne rend pas les
    /// 200 documents les plus récents, mais les plus pertinents remis en ordre.
    var sortIsPartial: Bool {
        sortOrder != .score && canLoadMore
    }

    /// Le plafond a coupé : le tri porte sur les `sortLoadCap` premiers
    /// résultats, et il reste des pages derrière. C'est le SEUL cas où la
    /// mention « partiel » subsiste une fois le chargement terminé.
    var sortCapReached: Bool {
        sortIsPartial && !isLoadingForSort && hits.count >= Self.sortLoadCap
    }

    /// Charge les tranches suivantes jusqu'à épuisement ou jusqu'au plafond,
    /// puis laisse `apply` retrier (PR-08).
    ///
    /// Le coût sur le chemin normal est NUL : tant que le tri est « pertinence »,
    /// cette fonction sort à la première ligne et pas une tranche de plus n'est
    /// demandée au moteur.
    private func startSortLoad() {
        guard sortOrder != .score, canLoadMore, !isLoadingForSort,
              !executedText.isEmpty, hits.count < Self.sortLoadCap else { return }
        isLoadingForSort = true
        let generation = self.generation
        sortLoadTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, generation == self.generation,
                  self.sortOrder != .score, self.canLoadMore,
                  self.hits.count < Self.sortLoadCap {
                // MÊMES exclusions que la première tranche (audit F1) : c'est
                // pour cela qu'on repasse par `buildPlan` à chaque tour.
                guard let plan = try? self.buildPlan(input: self.executedText,
                                                     offset: self.hits.count),
                      let results = try? await self.service.search(
                          plan.query, excludingDocsMatching: plan.negative),
                      !Task.isCancelled, generation == self.generation,
                      let rows = try? await self.service.docRows(
                          ids: results.hits.map(\.docID)),
                      !Task.isCancelled, generation == self.generation
                else { break }
                self.apply(results: results, rows: rows, append: true)
            }
            if generation == self.generation { self.isLoadingForSort = false }
        }
    }

    private func stopSortLoad() {
        sortLoadTask?.cancel()
        sortLoadTask = nil
        isLoadingForSort = false
    }

    /// Charge en différé le moteur (natif / Vision / importé) de chaque page OCR.
    ///
    /// La tâche est SUIVIE et annulée comme `searchTask` et `facetTask`, et son
    /// résultat n'est fusionné que si la génération n'a pas changé entre-temps
    /// (audit A10.8) : `pageMeta` coûte un balayage de `page_src`, largement de
    /// quoi laisser une recherche abandonnée réinjecter ses pictogrammes de
    /// provenance dans les résultats de la suivante. Une pagination (`append`)
    /// reste dans la même génération : sa tranche a le droit d'arriver après.
    private func loadEngines(for newHits: [Hit], append: Bool) {
        if !append {
            engines = [:]
            enginesTask?.cancel()
        }
        let ocrKeys = newHits.filter { $0.source != .native }
                             .map { (docID: $0.docID, page: $0.page) }
        guard !ocrKeys.isEmpty else { return }
        let generation = self.generation
        enginesTask = Task { [weak self] in
            guard let self,
                  let byRowID = try? await self.service.engines(for: ocrKeys),
                  !Task.isCancelled,
                  generation == self.generation
            else { return }
            var merged = self.engines
            for key in ocrKeys {
                let rowid = Schema.ftsRowID(docID: key.docID, page: key.page)
                if let engine = byRowID[rowid] {
                    merged[HitKey(docID: key.docID, page: key.page)] = engine
                }
            }
            self.engines = merged
        }
    }

    /// Filtre d'affichage appliqué au jeu chargé : l'ANNÉE seulement. La
    /// provenance n'est plus ici depuis le lot P3 — elle est dans la requête,
    /// et refiltrer une seconde fois ce que le moteur a déjà écarté ne
    /// pourrait plus que mentir sur les totaux.
    var filteredHits: [Hit] {
        guard !selectedYears.isEmpty || !selectedDocYears.isEmpty else { return hits }
        return hits.filter { hit in
            guard let row = docRows[hit.docID] else { return false }
            if !selectedYears.isEmpty,
               !selectedYears.contains(Self.year(of: row.record.mtime)) {
                return false
            }
            // La date du document (DD1) : un document qui n'en porte pas ne
            // peut satisfaire aucune année cochée — comme le moteur, qui le
            // range sous la clé vide de la facette.
            if !selectedDocYears.isEmpty {
                guard let docDate = row.record.docDate,
                      selectedDocYears.contains(String(DocumentDate.year(docDate)))
                else { return false }
            }
            return true
        }
    }

    /// Les provenances cochées, telles que `SearchQuery` les attend.
    ///
    /// Les étiquettes viennent de `GRDBStore.sourceLabel` : c'est la facette
    /// « Origine du texte » qui les produit, et la puce « Pages scannées
    /// seulement » emprunte les mêmes. Une sélection vide — ou qui ne nomme
    /// aucune provenance connue, ce qu'une session enregistrée par une version
    /// future pourrait contenir — vaut « toutes » : mieux vaut ne pas filtrer
    /// que filtrer sur rien.
    static func pageSources(_ labels: Set<String>) -> Set<PageSource>? {
        guard !labels.isEmpty else { return nil }
        let known = PageSource.allCases.filter {
            labels.contains(GRDBStore.sourceLabel($0.rawValue))
        }
        return known.isEmpty ? nil : Set(known)
    }

    /// Calendrier grégorien en heure locale : même convention que la facette
    /// `.year` du moteur (`strftime('%Y', …, 'unixepoch', 'localtime')`).
    private static let gregorian = Calendar(identifier: .gregorian)

    /// Millésime d'un `mtime`.
    ///
    /// Sans formateur du tout (audit A10.11) : cette fonction est appelée UNE
    /// FOIS PAR HIT, sur le fil principal, dès qu'un filtre d'année est actif —
    /// instancier un `DateFormatter` à chaque appel coûtait plus cher que le
    /// filtrage lui-même. `Calendar.component` lit la même valeur.
    static func year(of mtime: Double) -> String {
        String(gregorian.component(.year, from: Date(timeIntervalSince1970: mtime)))
    }

    /// Construit la requête moteur.
    ///
    /// `applyingFolderFilter` / `applyingExtFilter` ne concernent QUE les
    /// sélections de facettes de la barre latérale ; les contraintes écrites dans
    /// la requête elle-même (`folder:Livres`, `ext:pdf`) restent toujours
    /// appliquées — elles font partie de ce que l'utilisateur a demandé.
    private func buildQuery(input: String, offset: Int,
                            applyingFolderFilter: Bool = true,
                            applyingExtFilter: Bool = true,
                            applyingLangFilter: Bool = true,
                            applyingSourceFilter: Bool = true) throws -> SearchQuery {
        try buildPlan(input: input, offset: offset,
                      applyingFolderFilter: applyingFolderFilter,
                      applyingExtFilter: applyingExtFilter,
                      applyingLangFilter: applyingLangFilter,
                      applyingSourceFilter: applyingSourceFilter).query
    }

    /// `buildQuery` + l'expression des exclusions par document (arbitrage T5).
    private func buildPlan(input: String, offset: Int,
                           applyingFolderFilter: Bool = true,
                           applyingExtFilter: Bool = true,
                           applyingLangFilter: Bool = true,
                           applyingSourceFilter: Bool = true)
        throws -> (query: SearchQuery, negative: String?) {
        let plan = try QueryParser.searchPlan(
            input, limit: Self.pageSize, offset: offset,
            inDocIDs: scope.docIDs, groupByDoc: true,
            fuzzy: fuzzy, fuzzyScope: fuzzyScope)
        var q = plan.query
        // `dossier:Xyz` mal recopié rendait zéro résultat, sans un mot (idée 5
        // de l'audit A1). Les étiquettes viennent de `AppModel.roots` : les
        // pastilles de facette, elles, passent déjà l'étiquette exacte et n'ont
        // rien à valider — mais elles arrivent APRÈS cette résolution, sans
        // quoi une racine cochée serait confrontée à elle-même.
        if !q.folders.isEmpty {
            q.folders = try FolderCheck.resolve(q.folders, known: knownFolders)
        }
        if applyingFolderFilter {
            q.folders = Array(Set(q.folders).union(selectedFolders))
        }
        if applyingExtFilter {
            q.exts = Array(Set(q.exts).union(selectedExts))
        }
        if applyingLangFilter {
            q.langs = Array(selectedLangs)
        }
        if applyingSourceFilter {
            q.sources = Self.pageSources(selectedSources)
        }
        // La borne de date s'applique à TOUTES les dimensions, la facette
        // « Années » comprise : celle-ci ne filtre que le jeu chargé, qui est
        // déjà borné — lui montrer des années qu'aucun résultat ne peut porter
        // ferait des lignes qui, cliquées, ne rendent rien.
        q.modifiedAfter = dateFilter.modifiedAfter()
        return (q, plan.negative)
    }

    // MARK: - Facettes

    /// Recalcule les cinq facettes.
    ///
    /// Chaque dimension est comptée SANS son propre filtre, les autres restant
    /// appliqués — la convention de tout facettage à sélection multiple (audit
    /// A10.4). Sans cela, cocher « Livres » réduisait la section « Dossiers » à la
    /// seule ligne « Livres » (la requête de facettage portait déjà
    /// `top_folder IN ('Livres')`) et il devenait impossible d'ajouter une
    /// seconde racine. L'année filtre l'affichage, pas la requête : elle garde
    /// tous les filtres moteur.
    private func loadFacets(input: String) {
        var bases: [FacetKey: SearchQuery] = [:]
        let negative: String?
        do {
            // Le plan d'une dimension quelconque porte les mêmes exclusions que
            // les autres : elles ne dépendent d'aucun filtre de facette.
            negative = try buildPlan(input: input, offset: 0).negative
        } catch { return }
        for key in Self.facetKeys {
            guard let q = try? buildQuery(input: input, offset: 0,
                                          applyingFolderFilter: key != .folder,
                                          applyingExtFilter: key != .ext,
                                          applyingLangFilter: key != .lang,
                                          applyingSourceFilter: key != .source)
            else { return }
            bases[key] = q
        }
        // Comptage des pages touchées par document : même requête que les
        // résultats — tous les filtres, exclusions comprises. Il coûte une
        // exécution FTS de plus, comme une cinquième facette, et il est le
        // seul moyen d'annoncer un compte honnête (audit A12).
        let countBase = try? buildQuery(input: input, offset: 0)
        isFaceting = true
        let generation = self.generation
        facetTask = Task { [weak self, bases, countBase, negative] in
            guard let self else { return }
            var out: [FacetKey: [(String, Int)]] = [:]
            for key in Self.facetKeys {
                if Task.isCancelled { return }
                guard let base = bases[key] else { continue }
                if let values = try? await self.service.facets(
                    base, by: key, excludingDocsMatching: negative) {
                    out[key] = values.filter { !$0.0.isEmpty }
                }
            }
            if Task.isCancelled || generation != self.generation { return }
            self.facets = out
            // `isFaceting` ne retombe qu'APRÈS le comptage : c'est la cinquième
            // facette, et « le modèle est au repos » doit le comprendre. Posé
            // avant, les tests qui attendent le repos lisaient un compte
            // encore vide sous forte charge (lot I2, gate parallèle).
            defer { self.isFaceting = false }
            guard let countBase,
                  let counts = try? await self.service.matchedPageCounts(
                      countBase, excludingDocsMatching: negative),
                  !Task.isCancelled, generation == self.generation
            else { return }
            self.matchedPageCounts = counts
            self.regroup()
        }
    }

    /// Cinq dimensions depuis le lot U2 : « Langue » est la cinquième, et
    /// coûte une exécution FTS de plus par recherche — le même prix que les
    /// autres, sur le même prélude. La barre latérale ne l'AFFICHE que si le
    /// corpus trouvé porte au moins deux langues (`SidebarView`).
    private static let facetKeys: [FacetKey] = [.folder, .ext, .docYear, .year, .source, .lang]

    // MARK: - Portée documentaire (§5.6)

    func searchInsideCurrentDocument(name: String) {
        guard let docID = selection?.docID else { return }
        scope = .document(id: docID, name: name)
    }

    /// Restreindre à UN document désigné, sans passer par la sélection.
    ///
    /// `searchInsideCurrentDocument` part de `selection` : elle ne convient pas
    /// au compte de pages d'une ligne quelconque de la liste (PERSP-Q4), qui
    /// désigne son propre document. Le garde évite une relance pour rien —
    /// `didSet` ne compare pas, il se déclenche même sur une portée identique.
    func scopeToDocument(id: Int64, name: String) {
        let wanted = DocScope.document(id: id, name: name)
        guard scope != wanted else { return }
        scope = wanted
    }

    func searchInsideResults() {
        let ids = Array(Set(hits.map(\.docID)))
        guard !ids.isEmpty else { return }
        scope = .results(ids: ids)
    }

    func clearScope() { scope = .all }

    // MARK: - Historique

    private func rememberQuery(_ query: String) {
        var list = history.filter { $0 != query }
        list.insert(query, at: 0)
        if list.count > Prefs.historyLimit { list.removeLast(list.count - Prefs.historyLimit) }
        history = list
        Prefs.defaults.set(list, forKey: Prefs.history)
    }

    func clearHistory() {
        history = []
        Prefs.defaults.removeObject(forKey: Prefs.history)
    }

    // MARK: - Recherches enregistrées (PR-17)

    /// Les recherches épinglées, dans l'ordre où la barre latérale les montre.
    /// Portées par `SearchModel` et non par un objet à part : les deux vues qui
    /// les affichent (le menu de l'historique, la barre latérale) l'observent
    /// déjà, et un `ObservableObject` imbriqué ne préviendrait ni l'une ni
    /// l'autre de ses changements.
    @Published private(set) var savedSearches: [SavedSearch] =
        SavedSearches.load()

    /// Le nom proposé : la requête TELLE QUE TAPÉE, préfixes compris.
    /// `dossier:Factures 2025` s'enregistre tel quel — c'est une recherche
    /// complète, pas un mot-clé à décorer.
    var suggestedSavedName: String {
        executedText.isEmpty ? text : executedText
    }

    func saveCurrentSearch(name: String) {
        let query = suggestedSavedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(SavedSearches.adding(
            SavedSearch(name: label.isEmpty ? query : label, query: query),
            to: savedSearches))
    }

    func renameSavedSearch(query: String, to name: String) {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        update(SavedSearches.renaming(query: query, to: label, in: savedSearches))
    }

    func removeSavedSearch(query: String) {
        update(SavedSearches.removing(query: query, from: savedSearches))
    }

    /// Le glisser-déposer de la barre latérale (lot MN2). La liste ne permet
    /// d'en prendre qu'une à la fois ; un lot de plusieurs lignes, qu'aucun
    /// geste de l'interface ne fabrique, est ignoré plutôt que deviné.
    func moveSavedSearches(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard offsets.count == 1, let source = offsets.first else { return }
        update(SavedSearches.moving(from: source, to: destination, in: savedSearches))
    }

    /// Rejouer une recherche enregistrée : exactement le geste d'une entrée
    /// d'historique. Les facettes cochées ne sont PAS rejouées — elles ne font
    /// pas partie de ce qui a été enregistré, et l'aide le dit.
    func runSavedSearch(_ saved: SavedSearch) {
        text = saved.query
        submit()
    }

    private func update(_ list: [SavedSearch]) {
        savedSearches = list
        SavedSearches.save(list)
    }

    // MARK: - Reprendre où j'en étais (R-11)

    /// Requête dont la SESSION est mémorisée : la dernière que l'utilisateur a
    /// validée (touche Entrée, historique, suggestion). Les recherches
    /// relancées par une frappe ou par un filtre gardent cette valeur ; elles
    /// mettent la session à jour tant qu'elles portent le même texte, et ne la
    /// remplacent jamais par un texte que personne n'a validé.
    private var sessionQuery: String?

    /// Ce qu'il faudra sélectionner quand les résultats seront là — la page
    /// d'une session précédente. Consommée une seule fois : si elle n'est plus
    /// dans le jeu (document réindexé, supprimé, page disparue), la sélection
    /// retombe sur la première ligne, sans message. Il n'y a rien à annoncer :
    /// la recherche, elle, a bien été rejouée.
    private var pendingSelection: HitKey?

    /// Rejoue la dernière recherche validée, ses filtres et sa page. Appelée
    /// une fois, au démarrage, quand l'index est prêt.
    ///
    /// Ne fait rien si l'utilisateur a déjà tapé quelque chose : au lancement
    /// c'est impossible, mais la fonction ne doit pas écraser une saisie si un
    /// jour elle est rappelée ailleurs.
    func restoreLastSession() {
        guard text.isEmpty, executedText.isEmpty,
              let session = Self.loadSession(),
              !session.text.isEmpty else { return }
        suppressRerun = true
        text = session.text
        selectedFolders = Set(session.folders)
        selectedExts = Set(session.exts)
        selectedYears = Set(session.years)
        selectedDocYears = Set(session.docYears ?? [])
        selectedSources = Set(session.sources)
        selectedLangs = Set(session.langs)
        dateFilter = session.date
        suppressRerun = false
        if let docID = session.selectionDocID, let page = session.selectionPage {
            pendingSelection = HitKey(docID: docID, page: page)
        }
        sessionQuery = session.text
        // `remember: false` : la requête est déjà dans l'historique, et la
        // rejouer au lancement ne fait pas d'elle une requête plus récente que
        // celles d'avant.
        execute(remember: false)
    }

    /// Oublie la session : le geste « effacer » (la croix du champ) efface
    /// aussi ce que Fouine rouvrira. Sans cela, vider le champ avant de quitter
    /// ne servirait à rien — c'est pourtant exactement ce qu'on fait pour
    /// « repartir de zéro ».
    func forgetLastSession() {
        sessionQuery = nil
        pendingSelection = nil
        Prefs.defaults.removeObject(forKey: Prefs.lastSession)
    }

    /// Écrit la session courante, si et seulement si la requête exécutée est
    /// celle que l'utilisateur a validée.
    private func rememberSession() {
        guard let sessionQuery, sessionQuery == executedText else { return }
        let session = SearchSession(
            text: sessionQuery,
            folders: Array(selectedFolders).sorted(),
            exts: Array(selectedExts).sorted(),
            years: Array(selectedYears).sorted(),
            sources: Array(selectedSources).sorted(),
            langs: Array(selectedLangs).sorted(),
            date: dateFilter,
            selectionDocID: selection?.docID,
            selectionPage: selection?.page,
            docYears: Array(selectedDocYears).sorted())
        guard let data = try? JSONEncoder().encode(session) else { return }
        Prefs.defaults.set(data, forKey: Prefs.lastSession)
    }

    /// `internal` : les tests lisent ce que l'app rouvrira sans passer par un
    /// second `SearchModel`.
    static func loadSession() -> SearchSession? {
        guard let data = Prefs.defaults.data(forKey: Prefs.lastSession) else {
            return nil
        }
        return try? JSONDecoder().decode(SearchSession.self, from: data)
    }

    private func persistOptions() {
        Prefs.defaults.set(fuzzy.rawValue, forKey: Prefs.fuzzyMode)
        Prefs.defaults.set(fuzzyScope.rawValue, forKey: Prefs.fuzzyScope)
    }

    // MARK: - Export (audit U4)

    /// Lignes à exporter : le jeu AFFICHÉ, dans l'ordre affiché.
    var exportRows: [ResultExport.Row] {
        ResultExport.rows(groups: groups, docRows: docRows)
    }

    /// Ce que le panneau d'enregistrement doit annoncer : combien de lignes
    /// partent, et sur quel total. Le dire est la moitié de la fonction — un
    /// export tronqué en silence trompe plus qu'il ne sert.
    var exportSummary: String {
        let lignes = groups.reduce(0) { $0 + $1.hits.count }
        var phrase = String(localized: "\(lignes) line(s) — the results currently loaded")
        if totalPages > hits.count {
            phrase = String(localized: "\(phrase), out of \(totalPages) page(s) found")
        }
        if hasDisplayFilters {
            phrase = String(localized: "\(phrase), display filters applied")
        }
        return phrase + "."
    }

    var canExport: Bool { !groups.isEmpty }

    // MARK: - Accès pour les vues

    func docRow(_ id: Int64) -> DocRow? { docRows[id] }

    /// Le nom d'un document : celui de la note ou du paquet quand c'est une
    /// copie de Fouine (lot AN2), celui du fichier sinon.
    func fileName(_ path: String) -> String {
        DocumentDisplay.name(path)
    }

    /// Chemin relatif affiché : on retire le préfixe du volume jusqu'à la racine
    /// utilisateur pour ne montrer que ce qui distingue les documents.
    func displayPath(_ path: String) -> String { Self.displayPath(path) }

    /// La même règle, sans modèle : l'en-tête de l'aperçu en a besoin et ne
    /// connaît pas `SearchModel` (AP-15). Deux copies de cette règle
    /// divergeraient, et c'est exactement ce que l'audit a relevé.
    ///
    /// Une copie de Fouine n'a pas de chemin à montrer : c'est son fil
    /// d'Ariane, « Anki › M2SU 2026 », qui la situe (lot AN2).
    static func displayPath(_ path: String) -> String {
        if let document = DocumentDisplay.source(path) { return document.breadcrumb }
        var p = path
        if let range = p.range(of: "Users/") {
            p = String(p[range.upperBound...])
            if let slash = p.firstIndex(of: "/") { p = String(p[p.index(after: slash)...]) }
        }
        return p
    }

    // MARK: - Citer une page (lot INT-L1)

    /// Le lien `fouine://` d'une page de résultat.
    ///
    /// Le chemin ABSOLU passe par le volume — `hit.path` est relatif à lui, et
    /// un chemin relatif ne rouvrirait rien. Volume débranché : on n'a plus
    /// que la forme `doc`, et c'est `DeepLink.link` qui tranche.
    func pageLink(docID: Int64, page: Int) -> URL {
        let absolute = docRow(docID).flatMap { row -> String? in
            try? VolumeResolver.absolutePath(volUUID: row.record.volUUID,
                                             relPath: row.record.relPath).path
        }
        return DeepLink.link(absolutePath: absolute, docID: docID, page: page)
    }

    /// Les deux lignes à coller pour citer une page de résultat.
    ///
    /// `path` sert de repli au nom du fichier : la ligne `docs` peut n'avoir
    /// pas encore été chargée, alors que le `Hit` porte déjà son chemin.
    func pageReference(docID: Int64, page: Int, path: String) -> String {
        let relPath = docRow(docID)?.record.relPath ?? path
        let name = fileName(relPath)
        return Citation.reference(fileName: name, page: page,
                                  unit: DocumentDisplay.unit(relPath),
                                  link: pageLink(docID: docID, page: page))
    }

    /// « Copier la référence de cette page » (⇧⌘C) : agit sur la SÉLECTION.
    /// Sans sélection, il n'y a rien à citer et l'élément de menu est désactivé.
    func copySelectionReference() {
        guard let key = selection else { return }
        let path = hits.first { $0.docID == key.docID && $0.page == key.page }?.path ?? ""
        Citation.copy(pageReference(docID: key.docID, page: key.page, path: path))
    }

    /// Toutes les références du JEU CHARGÉ, dans l'ordre affiché (PR-19).
    ///
    /// Une par résultat, chacune sur ses deux lignes (nom et page, puis le
    /// lien) : c'est la forme que « Copier la référence » a déjà, et coller
    /// vingt citations ne doit pas obliger à en corriger vingt.
    var allReferences: String {
        groups.flatMap { group in
            group.hits.map {
                pageReference(docID: $0.docID, page: $0.page, path: $0.path)
            }
        }.joined(separator: "\n")
    }

    /// « Copier toutes les références » (⌥⌘C) : le jeu chargé, pas le total —
    /// même règle que l'export, et la même raison.
    func copyAllReferences() {
        guard canExport else { return }
        Citation.copy(allReferences)
    }

    // `bestScore` et `percentage(for:)` ont été RETIRÉS (AP-08, décision du
    // 09/09/2026). Le pourcentage affiché sur chaque ligne était un rapport au
    // meilleur score du jeu CHARGÉ : il changeait à chaque « Charger plus », le
    // même document portait d'autres chiffres d'une requête à l'autre, et dans
    // un groupe — rangé par numéro de page — il descendait puis remontait. Ne
    // pas le faire revenir : un score de classement n'est pas une pertinence
    // lisible, et le §5.6 interdit d'en montrer un.

    /// Le chemin absolu d'un document trouvé, quand il en a un.
    ///
    /// Trois surfaces en ont besoin — le glisser-déposer d'une ligne, « Afficher
    /// dans le Finder » et « Ouvrir » du menu contextuel, le Coup d'œil (PR-15,
    /// PR-16) —, et toutes trois doivent viser le document de LA LIGNE, pas
    /// celui de l'aperçu : un clic droit ne change pas la sélection.
    func absoluteURL(docID: Int64) -> URL? {
        guard let row = docRow(docID) else { return nil }
        return try? VolumeResolver.absolutePath(volUUID: row.record.volUUID,
                                                relPath: row.record.relPath)
    }
}
