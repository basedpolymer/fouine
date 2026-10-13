// AboutCredits.swift — ce que « À propos de Fouine » offre vraiment (BU-28).
// Propriété : A-App.
//
// Le panneau standard nommait la licence sans y donner accès : ni elle, ni les
// composants tiers, ni le code source — alors que le bundle EMPORTE `LICENSE`
// et `THIRD_PARTY_LICENSES.md` (bundle.sh, audit B1-10). Trois liens le
// règlent, plus la phrase qui dit ce que Fouine fait de vos documents : c'est
// la question que se pose vraiment quelqu'un qui ouvre « À propos ».
//
// Les trois liens survivent au passage en source-available (LI1) : ce n'est
// plus l'AGPL qui oblige à offrir les sources, c'est la licence elle-même qui
// promet un code lisible — une promesse sans lien vers le dépôt ne vaudrait
// rien —, et MIT et Apache-2.0 continuent d'exiger leurs notices.
//
// RIEN SUR UN ACHAT (GR1) : Fouine est gratuit, le panneau n'a plus d'état de
// licence à dire — seulement de quelle licence relève le CODE.
//
// Les deux premiers liens pointent sur des fichiers DU BUNDLE : hors bundle
// (`swift run FouineApp`) ils n'existent pas, et la ligne reste alors du texte
// simple — un lien mort serait pire que pas de lien.

import AppKit
import Foundation

enum AboutCredits {

    /// Le dépôt public — la même URL que le manifeste `.mcpb` et le cask.
    static let sourceRepository = URL(string: "https://github.com/basedpolymer/fouine")!

    // MARK: - Le texte, pur

    static func attributed(licenseURL: URL?,
                           thirdPartyURL: URL?,
                           sourceURL: URL) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 2
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .paragraphStyle: paragraph,
        ]

        let credits = NSMutableAttributedString()

        func append(_ text: String, link: URL? = nil) {
            var attributes = base
            if let link { attributes[.link] = link }
            credits.append(NSAttributedString(string: text, attributes: attributes))
        }

        append(String(localized: "Fouine reads your documents on this Mac and nothing leaves it."))
        append("\n\n")

        append(String(localized: "Source-available licence") + " — ")
        append(String(localized: "Read the licence"), link: licenseURL)
        append("\n")
        append(String(localized: "Third-party components"), link: thirdPartyURL)
        append("\n")
        append(String(localized: "Source code"), link: sourceURL)

        return credits
    }

    // MARK: - Le panneau

    /// Les deux fichiers sont cherchés dans `Bundle.main` — le .app lui-même —
    /// et non par `Bundle.module` : voir GuideLocator et docs/i18n.md.
    @MainActor
    static func show(bundle: Bundle = .main) {
        let credits = attributed(
            licenseURL: bundle.url(forResource: "LICENSE", withExtension: nil),
            thirdPartyURL: bundle.url(forResource: "THIRD_PARTY_LICENSES", withExtension: "md"),
            sourceURL: sourceRepository)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
