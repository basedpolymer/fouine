// ExternalOpen.swift — « Ouvrir le document » : dans SON application, et à la
// page trouvée quand cette application sait y aller (lot OP1).
// Propriété : A-App.
//
// CE FICHIER NE TOUCHE NI LE DISQUE NI LAUNCHSERVICES. Il reçoit le fichier, la
// page affichée et l'identifiant du lecteur par défaut, et rend un PLAN. Les
// gestes qui l'exécutent — interroger LaunchServices, lancer le lecteur —
// vivent dans `ExternalOpen+Perform.swift` (`perform(fileURL:page:)`). C'est ce partage qui rend la
// table ci-dessous vérifiable par un test, sans lecteur installé.
//
// ─── CE QUI A ÉTÉ MESURÉ LE 13/09/2026 (macOS 15.6, i5 4 cœurs) ────────────
//
// Un PDF de quatre pages, copié hors du dépôt, ouvert à la page 3 :
//
//   1. `NSWorkspace.shared.open(URL(string: "file:///…/x.pdf#page=3"))`
//      -> Aperçu s'ouvre sur « Page 1 of 4 ». Le fragment n'est pas ignoré par
//         Aperçu : IL N'ARRIVE JAMAIS. LaunchServices EFFACE le fragment d'une
//         URL `file:`, ce qu'une page témoin (`document.title = location.hash`)
//         ouverte de la même façon prouve : « HASH=(vide) ». Même résultat avec
//         `open([url], withApplicationAt:)` et avec `/usr/bin/open`.
//      -> Le fragment `#page=` ne peut donc PAS voyager par LaunchServices.
//
//   2. L'exécutable du lecteur, appelé avec l'URL en argument
//      (`…/Google Chrome.app/Contents/MacOS/Google Chrome 'file://…#page=3'`)
//      -> la page témoin rend « HASH=#page=11 », et le PDF s'ouvre sur
//         « 3 / 4 », y compris avec un nom portant espace, apostrophe et
//         guillemets. C'EST LA SEULE VOIE QUI MARCHE, et c'est celle d'ici.
//      -> Safari, essayé de la même façon, ignore l'URL passée en argument :
//         un navigateur WebKit ne se pilote que par événement Apple.
//
//   3. Aperçu (`com.apple.Preview`) ne sait pas aller à une page, par aucun
//      moyen : son dictionnaire AppleScript (`sdef /System/Applications/
//      Preview.app`) n'a que la suite standard — `open`, `print`, `close` —,
//      aucune commande de navigation, aucune propriété de page. Aperçu ouvre
//      le fichier, et c'est tout. Comme c'est le lecteur PDF par défaut de
//      presque tout le monde, LE CAS ORDINAIRE RESTE L'OUVERTURE SIMPLE.
//
// ─── POURQUOI PAS D'ÉVÉNEMENTS APPLE (Skim, Acrobat, PDF Expert) ───────────
//
// Ce sont les trois lecteurs qu'on saurait envoyer à une page autrement : leur
// dictionnaire AppleScript le documente. Ils ne sont pas retenus dans ce lot,
// et ce n'est pas un oubli :
//
//   · le droit `com.apple.security.automation.apple-events` serait obligatoire
//     (runtime durci), or Packaging/Fouine.entitlements est VIDE et son
//     commentaire pose la règle : ne pas demander un droit qu'on n'emploie pas.
//     Le demander pour une voie qu'on n'a pas pu exécuter une seule fois
//     l'échangerait contre rien de mesuré ;
//   · aucun des trois n'est installé sur la machine de référence, et le
//     garde-fou des lots refuse `osascript` : AUCUNE de ces voies n'a pu être
//     essayée. Livrer trois branches jamais exécutées, chacune capable de
//     réclamer « Fouine souhaite contrôler Skim » à quelqu'un qui voulait juste
//     lire sa page, coûte plus que ce qu'elle rend ;
//   · la première fois qu'un de ces lecteurs sera installé, la table gagnera un
//     cas `.script(String)` sans rien changer d'autre : le plan est fait pour.
//
// ─── CE QUI N'A PAS DE PAGE ────────────────────────────────────────────────
//
// Seul un PDF a une page qui veut dire quelque chose pour un autre logiciel.
// La « page 3 » d'un EPUB dépend du corps de texte choisi par le lecteur, celle
// d'un enregistrement est une tranche de dix minutes inventée par Fouine, celle
// d'un `.txt` n'existe pas. Ces documents s'ouvrent tels quels.

import Foundation

enum ExternalOpen {

    /// Ce qu'il faut faire pour ouvrir le document.
    enum Plan: Equatable {
        /// Ouvrir le fichier, sans plus : le lecteur choisit sa page. C'est le
        /// cas d'Aperçu, de tout ce qui n'est pas un PDF, d'un lecteur inconnu
        /// et d'une page absente — c'est-à-dire du cas ordinaire.
        case open(URL)
        /// Lancer le LECTEUR PAR DÉFAUT avec cette ligne de commande, dont
        /// l'unique argument est l'URL du fichier suivie de `#page=N`.
        /// `file` reste le repli si le lancement échoue.
        case arguments([String], file: URL)
    }

    /// Les lecteurs auxquels on passe l'URL en argument.
    ///
    /// `#page=N` est un « paramètre d'ouverture de PDF » d'Adobe, que suivent
    /// tous les afficheurs de PDF des navigateurs (PDFium côté Chromium,
    /// pdf.js côté Firefox). On n'inscrit ici QUE des lecteurs dont on sait que
    /// l'exécutable accepte une URL en argument : un lecteur qui l'ignorerait
    /// se contenterait de passer devant, SANS OUVRIR LE DOCUMENT — le repli ne
    /// se déclenche pas quand le lancement réussit. Dans le doute, on n'inscrit
    /// pas : le pire des deux mondes serait un bouton « Ouvrir le document »
    /// qui n'ouvre rien.
    private static let commandLineReaders: Set<String> = [
        // Vérifié le 13/09/2026 sur Chrome 141 : « 3 / 4 » à l'écran.
        "com.google.Chrome",
        // Non vérifié (pas installés), mais ce sont le MÊME binaire Chromium et
        // la même ligne de commande : `chrome <url>` est documenté par le
        // projet Chromium (« Run Chromium with flags »).
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "company.thebrowser.Browser",
        // Non vérifié : `firefox <url>` est documenté par Mozilla (« Command
        // line options »), et pdf.js suit `#page=`.
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
    ]

    /// Le plan pour ce document.
    ///
    /// - Parameters:
    ///   - fileURL: le fichier tel qu'il est sur le disque.
    ///   - page: la page affichée par Fouine. Aucun seuil : la page 1 est
    ///     demandée comme les autres — c'est au lecteur de n'en rien faire.
    ///   - handlerBundleID: l'identifiant du lecteur par défaut de ce fichier,
    ///     `nil` quand LaunchServices n'en connaît pas.
    static func plan(fileURL: URL, page: Int?, handlerBundleID: String?) -> Plan {
        guard let page, page >= 1, isPDF(fileURL),
              let handlerBundleID, commandLineReaders.contains(handlerBundleID),
              let pageURL = pageURL(fileURL, page: page)
        else { return .open(fileURL) }
        return .arguments([pageURL.absoluteString], file: fileURL)
    }

    /// L'infobulle du bouton « Ouvrir le document ».
    ///
    /// Elle ne parle de la page QUE là où une page veut dire quelque chose pour
    /// un autre logiciel, et elle ne promet rien : « quand elle le permet »,
    /// parce qu'Aperçu, lui, ne le permet pas.
    static func helpText(fileURL: URL?, page: Int?) -> String {
        guard let fileURL, isPDF(fileURL), let page, page >= 1 else {
            return String(localized: "Open in the default application")
        }
        return String(localized: "Open in the default application — at page \(page) when it can")
    }

    /// Ce que la lecture d'écran ajoute au nom du bouton.
    static func accessibilityHint(fileURL: URL?, page: Int?) -> String {
        guard let fileURL, isPDF(fileURL), let page, page >= 1 else {
            return String(localized: "Opens the file in the default application.")
        }
        return String(localized: "Opens the file at page \(page) when the application can go to it.")
    }

    // MARK: - Détail

    private static func isPDF(_ fileURL: URL) -> Bool {
        fileURL.pathExtension.lowercased() == "pdf"
    }

    /// L'URL du fichier, fragment `#page=N` posé.
    ///
    /// `URLComponents` garde l'encodage du chemin (l'espace reste `%20`, le
    /// guillemet français `%C2%AB`) et n'encode pas le fragment, qui n'en a pas
    /// besoin : c'est exactement la chaîne essayée à la main le 13/09.
    private static func pageURL(_ fileURL: URL, page: Int) -> URL? {
        guard var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.fragment = "page=\(page)"
        return components.url
    }
}
