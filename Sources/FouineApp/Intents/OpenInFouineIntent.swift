// OpenInFouineIntent.swift — « Ouvrir dans Fouine » (lot INT-R1).
// Propriété : A-App. SPEC §5.6.
//
// AUCUN CODE D'OUVERTURE ICI, ET C'EST LE POINT. Le schéma `fouine://`
// appartient à Fouine (Packaging/Info.plist), le routeur qui le comprend existe
// depuis INT-L1 (`DeepLinkRouter`, `onOpenURL`), et Spotlight passe déjà par lui
// (INT-S1). Cette action ne fait donc qu'OUVRIR L'URL que l'entité porte :
// macOS la rend à Fouine, `onOpenURL` la reçoit, et la reprise « base pas encore
// ouverte » qui existe déjà s'applique telle quelle. Réimplémenter l'ouverture
// ici aurait fabriqué un quatrième chemin à maintenir, qui aurait divergé.
//
// `openAppWhenRun = true` : c'est la seule des trois actions qui doit amener
// Fouine au premier plan — on la déclenche justement pour LIRE la page.

import Foundation
import AppKit
import AppIntents

struct OpenInFouineIntent: AppIntent {

    static var title: LocalizedStringResource = "Open in Fouine"

    static var description = IntentDescription(
        "Opens Fouine on the page of a result.",
        categoryName: "Fouine")

    static var openAppWhenRun: Bool = true

    @Parameter(title: "Result")
    var hit: FouineHitEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$hit) in Fouine")
    }

    /// `@MainActor` : `NSWorkspace.open` s'adresse à AppKit, et l'action est
    /// exécutée dans le processus de l'application (voir l'en-tête de
    /// `FouineHitEntity`) — pas dans une extension.
    @MainActor
    func perform() async throws -> some IntentResult {
        NSWorkspace.shared.open(hit.link)
        return .result()
    }
}
