// SearchFouineIntent.swift — « Chercher dans Fouine » (lot INT-R1).
// Propriété : A-App. SPEC §5.6.
//
// L'ACTION NE LANCE PAS L'APPLICATION (`openAppWhenRun = false`). Un raccourci
// qui cherche pour enchaîner sur Mail ou Notes n'a aucune raison d'amener une
// fenêtre au premier plan, et l'y amener volerait le clavier à qui travaillait.
// C'est « Ouvrir dans Fouine » qui ouvre — et lui seul.
//
// LEXICALE, JAMAIS HYBRIDE, pour la même raison que le panneau de la barre des
// menus (INT-M1) : le canal sémantique charge un modèle CoreML (~2,5 s la
// première fois) et Raccourcis coupe une action qui traîne. La recherche par le
// sens reste dans la fenêtre, où l'attente s'explique.

import Foundation
import AppIntents
import FouineCore

struct SearchFouineIntent: AppIntent {

    static var title: LocalizedStringResource = "Search in Fouine"

    static var description = IntentDescription(
        "Searches the text of your indexed documents and returns the pages that match.",
        categoryName: "Fouine",
        searchKeywords: ["search", "documents", "pdf", "index"])

    /// Fouine ne se met pas au premier plan pour répondre : voir l'en-tête.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Search", description: "What to look for. The same syntax as Fouine: \"exact phrase\", prefix*, -excluded.")
    var query: String

    /// `10` et `(1, 50)` EN LITTÉRAL, et non `IntentSupport.defaultLimit` :
    /// l'extraction des valeurs constantes exige une littérale
    /// (« expect a compile-time constant literal » à la compilation), parce que
    /// ces valeurs partent dans les métadonnées lues par Raccourcis, avant que
    /// le moindre code de Fouine ne tourne. Le test `IntentsTests` vérifie que
    /// les deux constantes de `IntentSupport` disent la même chose.
    @Parameter(title: "Number of results", default: 10, inclusiveRange: (1, 50))
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Search for \(\.$query) in Fouine") {
            \.$limit
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[FouineHitEntity]> {
        let url = AppPaths.databaseURL()
        try IntentSupport.checkIndex(at: url)

        let plan = try IntentSupport.plan(query: query, limit: limit)
        let store = GRDBStore()
        try store.openReadOnly(at: url)
        let results = try store.search(plan.query,
                                       excludingDocsMatching: plan.negative)

        // Une sonde par document, sur la clé primaire : `Hit.path` porte le
        // chemin RELATIF, et le lien `fouine://` canonique veut le chemin
        // absolu, donc le volume (voir `DeepLink`).
        var rows: [Int64: DocRow] = [:]
        for id in Set(results.hits.map(\.docID)) {
            rows[id] = try store.docRow(id: id)
        }

        let entities = results.hits.compactMap { hit -> FouineHitEntity? in
            guard let row = rows[hit.docID] else { return nil }
            return FouineHitEntity.make(docID: hit.docID, page: hit.page,
                                        row: row, rawSnippet: hit.snippet)
        }
        return .result(value: entities)
    }
}
