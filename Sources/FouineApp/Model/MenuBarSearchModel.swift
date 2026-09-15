// MenuBarSearchModel.swift — la mini-recherche de la barre des menus (INT-M1).
// Propriété : A-App. SPEC §5.6, amendement « mini-recherche ».
//
// POURQUOI UN SECOND MODÈLE DE RECHERCHE. `SearchModel` porte la fenêtre
// entière : filtres, facettes, historique, session mémorisée, canal sémantique,
// pagination, surlignage, explication du résultat sélectionné. Le panneau de la
// barre des menus n'a besoin d'aucune de ces choses, et surtout il ne doit RIEN
// changer de l'état de la grande fenêtre — taper trois mots dans la barre des
// menus ne doit pas effacer les filtres posés à côté, ni la requête qu'on y
// avait laissée. Deux modèles, donc, et pas un drapeau dans le premier.
//
// LEXICAL SEULEMENT, JAMAIS L'HYBRIDE. Un panneau qui s'ouvre sous le curseur
// doit répondre en moins de 100 ms ; le canal sémantique charge un modèle
// CoreML (~2,5 s la première fois) et interroge un index vectoriel. La
// recherche par le sens reste dans la fenêtre, où l'attente s'explique.
//
// La construction des lignes est une fonction PURE et statique (`rows(from:)`) :
// c'est elle que les tests interrogent — troncature, ordre, plafond,
// regroupement —, la partie qui touche la base n'étant qu'un aiguillage.

import Foundation
import SwiftUI
import FouineCore

/// Une ligne du panneau : UNE page trouvée.
///
/// Pas un document dépliable comme dans la fenêtre : un panneau de huit lignes
/// n'a pas la place d'un arbre, et ce qu'on vient y chercher est la page à
/// ouvrir, pas l'inventaire d'un ouvrage.
struct MenuBarSearchRow: Identifiable, Equatable {
    let docID: Int64
    let page: Int
    /// Le nom du fichier, sans son chemin : le panneau est étroit, et le
    /// chemin ne distingue rien qu'on puisse lire en 360 points.
    let fileName: String
    /// L'extrait sur UNE ligne, marqueurs FTS5 retirés et tronqué.
    let snippet: String

    var key: HitKey { HitKey(docID: docID, page: page) }
    var id: HitKey { key }
}

/// Ce que le panneau dit sous le champ, tant qu'il n'a pas de lignes à montrer.
enum MenuBarSearchState: Equatable {
    case idle
    case searching
    case results(pages: Int, docs: Int)
    case empty
    case error(String)
    /// L'index n'est pas encore ouvert (BU-02). Un cas à lui, et pas une
    /// erreur : ce n'est pas une panne, c'est un moment — et le panneau a une
    /// phrase du produit à dire au lieu du message du moteur, « base :
    /// database not open (call open(at:)) », qui est resté à l'écran d'un
    /// public qui ne sait pas ce qu'est une base.
    case indexNotOpen
}

@MainActor
final class MenuBarSearchModel: ObservableObject {

    /// Huit lignes : au-delà, le panneau dépasse la moitié de l'écran d'un 13"
    /// et cesse d'être un coup d'œil. « Voir tous les résultats dans Fouine »
    /// prend le relais.
    static let limit = 8

    /// L'extrait tient sur une ligne de 360 points en `caption` : au-delà de
    /// 90 caractères il serait tronqué par SwiftUI au milieu d'un mot, sans
    /// que VoiceOver, lui, cesse de lire la fin.
    static let snippetLimit = 90

    @Published var text = ""
    @Published private(set) var rows: [MenuBarSearchRow] = []
    @Published private(set) var state: MenuBarSearchState = .idle
    /// La ligne désignée au clavier (↑↓). `nil` = le champ garde la main, et
    /// ⏎ ouvre alors la grande fenêtre sur la requête.
    @Published var selection: HitKey?

    /// Total de pages trouvées, tous documents confondus : c'est lui qui décide
    /// de la ligne « Voir tous les résultats ».
    private(set) var totalPages = 0

    /// La question que les lignes affichées ont vraiment posée (rognée).
    /// Sert à une seule décision, `returnSearchesHere` : savoir si ce qui est
    /// dans le champ a déjà été cherché.
    private(set) var executedText = ""

    /// Les lignes `docs` des documents affichés, pour retrouver le fichier sur
    /// le disque (⌘-clic) sans repasser par la base à chaque geste.
    private var docRows: [Int64: DocRow] = [:]

    private let service: StoreService
    private var debounceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    /// Même garde que `SearchModel` : la réponse de la recherche *n* ne doit
    /// rien écrire quand la *n+1* est déjà partie. Sans elle, une requête lente
    /// tapée en premier écrasait la réponse d'une requête plus récente.
    private var generation = 0

    init(service: StoreService) {
        self.service = service
    }

    // MARK: - Saisie

    /// Reste-t-il des pages que le panneau n'a pas montrées ?
    var hasMore: Bool { totalPages > rows.count }

    /// Anti-rebond de 250 ms, le même que la fenêtre : on cherche pendant la
    /// frappe, mais pas à chaque touche. Appelé par la vue (`onChange`) et non
    /// par un `didSet` : `reset()` doit pouvoir vider le champ sans armer une
    /// recherche de plus.
    func textChanged() {
        debounceTask?.cancel()
        // « Chercher pendant que je tape » éteint (AP1) : la frappe n'arme
        // rien, c'est ⏎ (`submit()`) qui cherche. Relu à chaque touche, comme
        // dans la fenêtre : le réglage vaut dès qu'il change.
        guard Prefs.searchesAsYouType else { return }
        let snapshot = text
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, self.text == snapshot else { return }
            self.execute()
        }
    }

    /// ⏎ dans le champ, quand la frappe n'a rien cherché : la recherche part
    /// tout de suite (AP1). Il n'y a pas d'anti-rebond à annuler dans ce
    /// cas-là, mais `submit()` doit rester juste si le réglage vient d'être
    /// éteint pendant qu'une frappe attendait son quart de seconde.
    func submit() {
        debounceTask?.cancel()
        execute()
    }

    /// ⏎ sans ligne désignée : chercher ICI, ou passer la question à la grande
    /// fenêtre ?
    ///
    /// Réglage allumé, les résultats sont déjà sous le champ : ⏎ ouvre la
    /// fenêtre, comme avant AP1. Éteint, la frappe n'a rien cherché — ⏎ cherche
    /// d'abord dans le panneau, et c'est un second ⏎ qui ouvre la fenêtre.
    /// Sans quoi le panneau ne pourrait plus rien montrer une fois le réglage
    /// éteint, ce qui le viderait de son objet.
    var returnSearchesHere: Bool {
        guard !Prefs.searchesAsYouType else { return false }
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !input.isEmpty && input != executedText
    }

    /// Le panneau se rouvre : on repart du champ vide plutôt que d'afficher les
    /// résultats d'une question posée il y a deux heures.
    func reset() {
        debounceTask?.cancel()
        searchTask?.cancel()
        generation &+= 1
        text = ""
        rows = []
        docRows = [:]
        totalPages = 0
        executedText = ""
        selection = nil
        state = .idle
    }

    func execute() {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        generation &+= 1
        executedText = input

        guard !input.isEmpty else {
            rows = []; docRows = [:]; totalPages = 0; selection = nil
            state = .idle
            return
        }

        // L'index n'est pas ouvert : on le DIT, on ne le demande pas au moteur
        // (BU-02). Le cas subsiste après la correction du démarrage — un index
        // qui refuse de s'ouvrir (disque plein, base d'une version plus
        // récente) laisse le panneau vivant, et il doit rester compréhensible.
        guard service.isOpen else {
            rows = []; docRows = [:]; totalPages = 0; selection = nil
            state = .indexNotOpen
            return
        }

        let plan: (query: SearchQuery, negative: String?)
        do {
            plan = try QueryParser.searchPlan(input, limit: Self.limit,
                                              offset: 0, groupByDoc: true)
        } catch {
            rows = []; docRows = [:]; totalPages = 0; selection = nil
            state = .error(ErrorText.describe(error))
            return
        }

        state = .searching
        let generation = self.generation
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await self.service.search(
                    plan.query, excludingDocsMatching: plan.negative)
                if Task.isCancelled { return }
                let docs = try await self.service.docRows(
                    ids: results.hits.map(\.docID))
                if Task.isCancelled { return }
                self.apply(results: results, docRows: docs, generation: generation)
            } catch {
                if Task.isCancelled { return }
                self.fail(ErrorText.describe(error), generation: generation)
            }
        }
    }

    /// `internal` et non `private` : c'est ici que se prouve la garde de
    /// génération, et un test ne peut pas fabriquer une recherche lente.
    func apply(results: SearchResults, docRows: [Int64: DocRow],
               generation: Int) {
        guard generation == self.generation else { return }
        self.docRows = docRows
        totalPages = results.totalPages
        rows = Self.rows(from: results, docRows: docRows)
        selection = nil
        state = rows.isEmpty ? .empty
                             : .results(pages: results.totalPages,
                                        docs: results.totalDocs)
    }

    func fail(_ message: String, generation: Int) {
        guard generation == self.generation else { return }
        rows = []; docRows = [:]; totalPages = 0; selection = nil
        state = .error(message)
    }

    // MARK: - Construction des lignes (pure)

    /// Les lignes du panneau, dans l'ordre du moteur, les pages d'un même
    /// document rassemblées.
    ///
    /// Le moteur rend des pages classées ; deux pages d'un même ouvrage peuvent
    /// donc être séparées par une page d'un autre. Dans une liste de huit
    /// lignes où le nom du fichier est répété, cet entrelacement se lit comme
    /// un désordre. On regroupe donc par document EN GARDANT l'ordre
    /// d'apparition — le document dont la meilleure page est première reste
    /// premier —, ce qui ne déclasse rien et rend la liste lisible.
    static func rows(from results: SearchResults,
                     docRows: [Int64: DocRow]) -> [MenuBarSearchRow] {
        var order: [Int64] = []
        var byDoc: [Int64: [Hit]] = [:]
        for hit in results.hits {
            if byDoc[hit.docID] == nil { order.append(hit.docID) }
            byDoc[hit.docID, default: []].append(hit)
        }
        var out: [MenuBarSearchRow] = []
        for docID in order {
            for hit in byDoc[docID] ?? [] {
                guard out.count < limit else { return out }
                let path = docRows[docID]?.record.relPath ?? hit.path
                out.append(MenuBarSearchRow(
                    docID: hit.docID, page: hit.page,
                    fileName: DocumentDisplay.name(path),
                    snippet: plainSnippet(hit.snippet)))
            }
        }
        return out
    }

    /// L'extrait FTS5 réduit à une ligne : marqueurs « » retirés (le panneau ne
    /// colore rien — huit lignes de surlignage en 360 points font un vitrail),
    /// retours à la ligne aplatis, puis troncature sur une frontière de MOT.
    ///
    /// Couper au caractère près donnerait « …la thermodynamiq », qu'on lit deux
    /// fois avant de comprendre que le mot n'est pas coupé dans le document.
    static func plainSnippet(_ snippet: String) -> String {
        let flat = SnippetParser.segments(snippet)
            .map(\.text)
            .joined()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let collapsed = flat.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard collapsed.count > snippetLimit else { return collapsed }
        let cut = collapsed.prefix(snippetLimit)
        // Le dernier espace de la tranche : s'il n'y en a pas (un « mot » de
        // 90 caractères, ce qu'une page mal océrisée produit), on coupe net
        // plutôt que de rendre une ligne vide.
        let head = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        return head.trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Gestes

    /// Le fichier sur le disque, pour ⌘-clic. `nil` quand le volume n'est pas
    /// monté : le geste est alors sans objet, et la ligne reste cliquable pour
    /// l'aperçu — l'index, lui, est sur le disque interne.
    func fileURL(for row: MenuBarSearchRow) -> URL? {
        guard let record = docRows[row.docID]?.record else { return nil }
        return try? VolumeResolver.absolutePath(volUUID: record.volUUID,
                                                relPath: record.relPath)
    }

    /// ↓ puis ↑ : la sélection part de la première ligne et ne sort pas de la
    /// liste par le haut — remonter au-delà rend la main au champ (`nil`),
    /// ce qui est ce que fait tout champ de recherche de macOS.
    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        guard let current = selection,
              let index = rows.firstIndex(where: { $0.key == current }) else {
            selection = delta > 0 ? rows.first?.key : rows.last?.key
            return
        }
        let next = index + delta
        guard next >= 0 else { selection = nil; return }
        guard next < rows.count else { return }
        selection = rows[next].key
    }

    var selectedRow: MenuBarSearchRow? {
        selection.flatMap { key in rows.first { $0.key == key } }
    }
}
