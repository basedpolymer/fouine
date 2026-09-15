// GetPageTextIntent.swift — « Obtenir le texte d'une page » (lot INT-R1).
// Propriété : A-App. SPEC §5.6.
//
// CE QU'ELLE REND, ET CE QU'ELLE NE REND PAS. Le texte que Fouine a EXTRAIT ou
// OCÉRISÉ de la page — jamais le fichier d'origine, jamais une image. C'est la
// même règle que le serveur MCP (docs/mcp.md) : ce qui sort de l'index est du
// texte, et il ne quitte pas la machine à cause de cette action.
//
// LE PLAFOND EST VISIBLE. Une page tronquée sans le dire part dans une note où
// il manquera trois paragraphes que personne ne cherchera. La note de troncature
// est donc collée au texte, traduite, et le plafond vit dans `IntentSupport`.

import Foundation
import AppIntents
import FouineCore

struct GetPageTextIntent: AppIntent {

    static var title: LocalizedStringResource = "Get the text of a page"

    static var description = IntentDescription(
        "Returns the text Fouine read on that page. The original file is not opened.",
        categoryName: "Fouine")

    static var openAppWhenRun: Bool = false

    @Parameter(title: "Result")
    var hit: FouineHitEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get the text of \(\.$hit)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let key = IntentSupport.key(fromEntityID: hit.id) else {
            throw FouineIntentError.resultUnavailable
        }
        let url = AppPaths.databaseURL()
        try IntentSupport.checkIndex(at: url)

        let store = GRDBStore()
        try store.openReadOnly(at: url)
        guard let text = try store.pageText(docID: key.docID, page: key.page) else {
            throw FouineIntentError.resultUnavailable
        }
        return .result(value: IntentSupport.truncate(
            pageText: text,
            note: String(localized: "[The rest of this page was not included.]")))
    }
}
