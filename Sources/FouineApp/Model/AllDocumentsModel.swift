// AllDocumentsModel.swift — « Tous vos documents » (lot BR1, constat PR-06).
// Propriété : A-App.
//
// POURQUOI CETTE FENÊTRE EXISTE. L'audit du 09/09/2026 a mesuré qu'on ne peut
// RIEN parcourir : l'application ouvre sur un champ de recherche, et il n'y
// avait aucun moyen de voir la liste des documents indexés, de parcourir un
// dossier sans chercher un mot, ni de répondre à « qu'est-ce que Fouine
// connaît, au juste ? ». Le cœur savait le faire depuis le palier MCP
// (`listDocuments`) : l'assistant pouvait lister, l'humain non. Le Finder,
// DEVONthink et EagleFiler ouvrent tous sur une liste ; Spotlight a
// « Récents ».
//
// TROIS MORCEAUX, ET LA SÉPARATION EST LE POINT (même partage que
// `UnreadableDocumentsModel`) :
//   · `AllDocumentsQuery` — ce que la fenêtre DEMANDE, converti en
//     `DocumentFilter`. Pur, testé sans base : c'est là que se décident le
//     filtre vide (qui ne doit pas devenir un `LIKE '%%'`) et l'ordre.
//   · `AllDocumentsRow` — ce qu'une ligne AFFICHE, depuis une `DocumentListing`.
//     Pur aussi : aucun chemin en clair, le dossier abrégé comme dans la liste
//     de résultats (AP-15).
//   · `AllDocumentsModel` — la lecture, hors du fil principal (`StoreService`),
//     par tranches, avec sa pagination et ses trois états.
//
// LA PAGINATION EST CELLE DE SQLITE (`limit`/`offset` sur l'ordre TOTAL de
// `DocumentOrder`) : sans elle, « Charger plus » pourrait sauter ou redonner des
// lignes dès que l'agent écrit entre deux tranches — et personne ne s'en
// apercevrait.

import Foundation
import SwiftUI
import FouineCore
import FouineIndex

/// L'ordre proposé par le menu de la fenêtre. TROIS, et pas les cinq de la
/// liste de résultats : ici il n'y a pas de pertinence, et « chemin » ne veut
/// rien dire pour le public visé — c'est le NOM qu'il cherche à trier.
enum AllDocumentsOrder: String, CaseIterable, Identifiable, Sendable {
    case recent, name, pages

    var id: String { rawValue }

    /// L'ordre du cœur. `name` passe par `path` : `rel_path` finit par le nom
    /// du fichier, et trier sur le chemin garde ensemble les documents d'un
    /// même dossier — ce qui est exactement ce qu'on veut en parcourant.
    var value: DocumentOrder {
        switch self {
        case .recent: return .recent
        case .name:   return .path
        case .pages:  return .pages
        }
    }

    var label: String {
        switch self {
        case .recent: return String(localized: "Recent")
        case .name:   return String(localized: "Name")
        case .pages:  return String(localized: "Pages")
        }
    }
}

/// Ce que dit — et ce que FAIT — la ligne des comptes du pied de la carte
/// « Index » (constat PR-06).
///
/// Le pied annonçait « 1 527 documents · 396 912 pages » sans qu'on puisse en
/// voir un seul : le compte devient donc un GESTE, comme le compte de pages
/// d'un résultat depuis `PageCountAffordance`. La décision — compte seul ou
/// geste — et ses libellés vivent ici, hors de la vue, parce que c'est la seule
/// partie qui se teste : une vue SwiftUI ne se vérifie qu'à l'œil.
enum DocumentCountAffordance: Equatable {
    /// `stats()` n'a pas encore répondu (ou a échoué) : on ne prétend pas
    /// compter, et il n'y a rien à ouvrir.
    case unavailable
    /// Un index vide — installation neuve, dossiers jamais indexés : ouvrir une
    /// liste de zéro ligne n'apprendrait rien.
    case empty
    /// Le cas normal : le compte ouvre « Tous vos documents ».
    case gesture(documents: Int, pages: Int)

    static func decide(documents: Int?, pages: Int?) -> DocumentCountAffordance {
        guard let documents, let pages else { return .unavailable }
        return documents > 0 ? .gesture(documents: documents, pages: pages) : .empty
    }

    var isGesture: Bool {
        if case .gesture = self { return true }
        return false
    }

    /// Ce qui s'écrit. La MÊME chaîne qu'avant le geste (mêmes deux nombres,
    /// même séparateur) : cliquer sur un compte ne doit pas changer ce qu'il
    /// dit.
    var label: String {
        switch self {
        case .unavailable:
            return String(localized: "statistics unavailable")
        case .empty:
            return String(localized: "\(Format.integer(0)) documents · \(Format.integer(0)) pages")
        case .gesture(let documents, let pages):
            return String(localized: "\(Format.integer(documents)) documents · \(Format.integer(pages)) pages")
        }
    }

    /// L'info-bulle du geste, `nil` quand il n'y en a pas : une indication sur
    /// un texte non cliquable promettrait une action.
    var help: String? {
        isGesture
            ? String(localized: "Shows every document Fouine has indexed, most recent first.")
            : nil
    }

    /// Ce que VoiceOver annonce. Le NOM du geste d'abord — « Tous vos
    /// documents, bouton » —, les comptes en VALEUR : la ligne des comptes est
    /// un texte statique depuis BU-15, et un bouton dont le libellé serait
    /// « 1 527 documents · 396 912 pages » ferait lire deux nombres sans jamais
    /// dire où l'on va.
    var accessibilityLabel: String {
        isGesture ? String(localized: "All your documents") : label
    }
}

/// Ce que la fenêtre demande à l'index. PUR.
struct AllDocumentsQuery: Equatable, Sendable {
    /// Ce qui est tapé dans « Filtrer par nom ».
    var nameFilter: String = ""
    /// Étiquette de racine, `nil` = tous les dossiers.
    var folder: String?
    /// Extension en minuscules, `nil` = tous les types.
    var ext: String?
    var order: AllDocumentsOrder = .recent

    /// La traduction en filtre du cœur.
    ///
    /// UN FILTRE VIDE EST `nil`, PAS UNE CHAÎNE VIDE : `pathContains: ""`
    /// deviendrait `rel_path LIKE '%%'`, c'est-à-dire un balayage complet de
    /// `docs` pour ne rien filtrer. Le cœur s'en garde déjà
    /// (`documentClause` ignore les chaînes vides), mais la décision se prend
    /// ici, où elle se teste.
    var filter: DocumentFilter {
        let needle = nameFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        return DocumentFilter(folder: folder, ext: ext,
                              pathContains: needle.isEmpty ? nil : needle,
                              // AUCUN filtre d'état : la fenêtre répond « ce que
                              // Fouine connaît », ce qui inclut les documents
                              // qu'il n'a pas su lire — ils portent alors leur
                              // marqueur. Les cacher reproduirait le trou que
                              // l'audit a relevé.
                              states: nil)
    }
}

/// Une ligne de la fenêtre.
struct AllDocumentsRow: Identifiable, Equatable, Sendable {
    let id: Int64
    /// Nom du fichier, seul.
    let fileName: String
    /// Le dossier qui le contient, ABRÉGÉ comme dans la liste de résultats
    /// (AP-15) : jamais `Users/<nom de session>/…`.
    let folderPath: String
    /// Étiquette de la racine surveillée.
    let folder: String
    /// Chemin relatif, pour l'infobulle et rien d'autre.
    let relPath: String
    /// La note ou le paquet que ce fichier recopie, quand c'en est un (lot
    /// AN2) : la ligne montre alors son nom et son fil d'Ariane, jamais le
    /// fichier.
    let source: SourceDocument?
    let pages: Int
    let modified: Date
    let state: DocState
    /// Motif brut de `docs.err`, quand le document n'a pas pu être lu.
    let rawReason: String?
    /// Chemin absolu quand le volume est monté, sinon `nil` : le Finder n'a
    /// alors rien à montrer, et un bouton qui ne fait rien vaut moins que pas
    /// de bouton (même règle que la fenêtre des documents illisibles).
    let fileURL: URL?

    /// Le document a-t-il été lu ? `discovered` n'est pas un échec : c'est
    /// « pas encore », et la ligne le dit autrement.
    var isUnreadable: Bool { state == .failed || state == .skipped }
    var isPending: Bool { state == .discovered }

    /// `@MainActor` pour la seule raison qu'il abrège le chemin par
    /// `SearchModel.displayPath` — la règle du projet, isolée sur le fil
    /// principal comme tout `SearchModel`. En recopier la règle ici donnerait
    /// deux abréviations du même chemin, ce que l'audit AP-15 vient justement
    /// de corriger ; les lignes se construisent de toute façon dans
    /// `AllDocumentsModel`, qui est sur ce fil.
    @MainActor
    init(listing: DocumentListing) {
        id = listing.id
        source = DocumentDisplay.source(listing.relPath)
        fileName = DocumentDisplay.name(listing.relPath)
        folderPath = source?.breadcrumb ?? SearchModel.displayPath(
            (listing.relPath as NSString).deletingLastPathComponent)
        folder = listing.topFolder
        relPath = listing.relPath
        pages = listing.nPages
        modified = Date(timeIntervalSince1970: listing.mtime)
        state = listing.state
        rawReason = listing.err
        fileURL = try? VolumeResolver.absolutePath(volUUID: listing.volUUID,
                                                   relPath: listing.relPath)
    }
}

/// Ce que la fenêtre montre à l'instant t. PUR, donc testé : c'est la
/// distinction entre « pas encore lu » et « lu et vide » qui évite d'annoncer
/// « aucun document » pendant les 200 ms de la lecture.
enum AllDocumentsPhase: Equatable {
    case loading
    case empty
    case list
    /// La base n'a pas répondu ; la phrase est celle de l'app
    /// (`ErrorText.describe`).
    case failure(String)
}

@MainActor
final class AllDocumentsModel: ObservableObject {

    /// Une tranche. 200 lignes : au-delà, `List` construit plus de vues que
    /// personne ne regarde, et la pagination du cœur est là pour ça.
    static let pageSize = 200

    /// Le temps qu'on laisse à la frappe avant de relire. Mesuré sur la base de
    /// production : une tranche coûte quelques millisecondes, mais chaque
    /// caractère relit AUSSI le total (`countDocuments`) — relancer à chaque
    /// touche ferait clignoter le compte.
    static let debounce: TimeInterval = 0.3

    @Published var nameFilter = "" {
        didSet { if nameFilter != oldValue { scheduleReload(after: Self.debounce) } }
    }
    @Published var folder: String? {
        didSet { if folder != oldValue { scheduleReload(after: 0) } }
    }
    @Published var ext: String? {
        didSet { if ext != oldValue { scheduleReload(after: 0) } }
    }
    @Published var order: AllDocumentsOrder = .recent {
        didSet { if order != oldValue { scheduleReload(after: 0) } }
    }

    /// `nil` = pas encore lu (la fenêtre attend), `[]` = lu et vide.
    @Published private(set) var rows: [AllDocumentsRow]?
    /// Documents répondant au filtre, TOUS — pas seulement ceux qui sont à
    /// l'écran : c'est le nombre que la fenêtre annonce.
    @Published private(set) var total = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    /// Les extensions présentes dans l'index, pour le menu « Type ». Lues une
    /// fois : elles ne changent qu'à l'indexation.
    @Published private(set) var extensions: [String] = []

    private let service: StoreService
    private var reloadTask: Task<Void, Never>?
    /// Numéro de la demande en cours. Une réponse d'une génération précédente
    /// est JETÉE : sans cela, une lecture lente lancée sur « Liv » écraserait
    /// celle de « Livres » arrivée avant elle.
    private var generation = 0

    init(service: StoreService) { self.service = service }

    var query: AllDocumentsQuery {
        AllDocumentsQuery(nameFilter: nameFilter, folder: folder, ext: ext,
                          order: order)
    }

    var phase: AllDocumentsPhase {
        if let errorText { return .failure(errorText) }
        guard let rows else { return .loading }
        return rows.isEmpty ? .empty : .list
    }

    /// Reste-t-il des documents à charger ? Comparaison au TOTAL, jamais au
    /// nombre de lignes de la dernière tranche : une tranche pleine peut être
    /// la dernière.
    var canLoadMore: Bool { (rows?.count ?? 0) < total }

    // MARK: - Lecture

    /// Première lecture de la fenêtre : les extensions, puis la première
    /// tranche.
    func start() async {
        if extensions.isEmpty {
            extensions = (try? await service.documentExtensions()) ?? []
        }
        await load()
    }

    /// Relit depuis le début, avec les filtres courants.
    func load() async {
        generation += 1
        let mine = generation
        let asked = query
        isLoading = true
        defer { if mine == generation { isLoading = false } }
        do {
            let count = try await service.countDocuments(asked.filter)
            let listed = try await service.listDocuments(
                asked.filter, order: asked.order.value,
                limit: Self.pageSize, offset: 0)
            guard mine == generation else { return }
            total = count
            rows = listed.map(AllDocumentsRow.init(listing:))
            errorText = nil
        } catch {
            guard mine == generation else { return }
            // Une base illisible ne laisse pas la fenêtre muette : on dit ce
            // qui s'est passé, avec la phrase que l'app emploie ailleurs.
            errorText = ErrorText.describe(error)
            if rows == nil { rows = [] }
        }
    }

    /// La tranche suivante, ajoutée à la fin. L'`offset` est le nombre de lignes
    /// DÉJÀ affichées : c'est ce qui rend la suite exacte même si l'index a
    /// grossi entre-temps (l'ordre du cœur est total).
    func loadMore() async {
        guard !isLoading, canLoadMore, let current = rows else { return }
        let mine = generation
        let asked = query
        isLoading = true
        defer { if mine == generation { isLoading = false } }
        do {
            let listed = try await service.listDocuments(
                asked.filter, order: asked.order.value,
                limit: Self.pageSize, offset: current.count)
            guard mine == generation else { return }
            rows = current + listed.map(AllDocumentsRow.init(listing:))
            errorText = nil
        } catch {
            guard mine == generation else { return }
            errorText = ErrorText.describe(error)
        }
    }

    /// Relit TOUT DE SUITE, en annulant la relecture différée qu'un changement
    /// de filtre vient peut-être de programmer.
    ///
    /// Sans cette annulation, deux lectures se courent après : celle qu'on
    /// attend et celle de la frappe. La seconde gagne (elle porte la génération
    /// la plus haute) et la première est jetée — c'est le bon comportement à
    /// l'écran, mais un appelant qui attend la fin de SA lecture doit pouvoir
    /// écarter l'autre.
    func reload() async {
        reloadTask?.cancel()
        reloadTask = nil
        await load()
    }

    private func scheduleReload(after delay: TimeInterval) {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            // Le test d'annulation vaut pour LES DEUX chemins : une tâche sans
            // délai n'a pas encore commencé quand elle est annulée (elle attend
            // son tour sur le fil principal), et elle partirait quand même.
            if Task.isCancelled { return }
            await self?.load()
        }
    }
}
