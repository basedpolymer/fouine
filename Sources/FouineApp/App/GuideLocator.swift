// GuideLocator.swift — où est le guide, et dans quelle langue (BU-27, DC1).
// Propriété : A-App.
//
// Le guide n'est pas une ressource SwiftPM : `Packaging/bundle.sh` copie
// `docs/app.md` en `Contents/Resources/Guide.en.md` et `docs/fr/app.md` en
// `Guide.fr.md`, comme il copie LICENSE. Passer par `Bundle.module` ferait un
// `fatalError` au lancement de Fouine.app — le bundle SwiftPM voisin reste hors
// du .app (voir la cible FouineApp de Package.swift et docs/i18n.md). On lit
// donc `Bundle.main`, et on accepte qu'il n'y ait RIEN sous
// `swift run FouineApp` : la fenêtre le dit en une phrase au lieu de rester
// vide.

import Foundation

enum GuideLocator {

    /// Le nom du fichier attendu pour une langue donnée. Seul le français a sa
    /// traduction ; toute autre langue lit l'anglais, qui fait foi.
    static func resourceName(languageCode: String?) -> String {
        languageCode?.hasPrefix("fr") == true ? "Guide.fr" : "Guide.en"
    }

    static let resourceExtension = "md"

    /// Le guide dans une copie donnée de Fouine — `nil` hors bundle.
    ///
    /// REPLI : une copie à qui il manquerait un des deux fichiers (un bundle
    /// bâti à la main, jamais `bundle.sh`, qui échoue dur) sert l'autre plutôt
    /// que rien. Un guide dans la mauvaise langue reste lisible ; une fenêtre
    /// vide, non.
    static func url(bundle: Bundle = .main,
                    languageCode: String? = Bundle.main.preferredLocalizations.first)
    -> URL? {
        let wanted = resourceName(languageCode: languageCode)
        if let url = bundle.url(forResource: wanted, withExtension: resourceExtension) {
            return url
        }
        let other = wanted == "Guide.fr" ? "Guide.en" : "Guide.fr"
        return bundle.url(forResource: other, withExtension: resourceExtension)
    }

    /// La page prête à afficher : HTML rendu, et le dossier qui sert de base
    /// aux liens relatifs de la page.
    static func page(bundle: Bundle = .main,
                     languageCode: String? = Bundle.main.preferredLocalizations.first)
    -> (html: String, baseURL: URL)? {
        guard let url = url(bundle: bundle, languageCode: languageCode),
              let markdown = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let html = MarkdownHTML.render(markdown,
                                       title: String(localized: "Fouine Guide"))
        return (html, url.deletingLastPathComponent())
    }

    /// Un lien du guide part-il dans le navigateur ? Tout ce qui sort de la
    /// page — `http`, `https`, `mailto` — s'ouvre dehors ; une ancre `#…`
    /// reste dans la fenêtre, sinon le guide se refermerait sur lui-même à
    /// chaque renvoi interne.
    static func opensInBrowser(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme)
    }
}
