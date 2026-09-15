// DeepLinkRouter.swift — que faire d'un lien `fouine://` reçu (lot INT-L1).
// Propriété : A-App.
//
// LE ROUTEUR NE TOUCHE NI LA BASE NI LE DISQUE. Il reçoit des fermetures — «
// ce chemin (ou ce document) correspond-il à un document connu ? » et « qu'y
// a-t-il à ce chemin ? » — et rend une DÉCISION. C'est ce qui le rend
// testable : les cas d'un lien reçu se jouent en mémoire, sans base jetable,
// sans fenêtre, sans fichier. Les gestes qui appliquent la décision (montrer la
// fenêtre, ouvrir l'aperçu, lancer la recherche) vivent dans
// `FouineDesktopApp`, là où l'environnement SwiftUI existe.
//
// LE CAS QUI JUSTIFIE `unknownDocument`. Un lien porte le chemin d'un fichier
// tel qu'il était le jour de la citation. Six mois plus tard, le fichier a pu
// être déplacé, ou l'index reconstruit sans lui. Ouvrir un aperçu vide serait
// muet ; ne rien faire serait pire. On le DIT, et on propose le seul geste qui
// vaille encore quelque chose : ouvrir le fichier lui-même, quand il est
// toujours là.
//
// ET C'EST EXACTEMENT LÀ QU'ÉTAIT LA FAILLE (constat BU-01, reproduit à
// l'écran). « Toujours là » se lisait `fileExists`, et le bouton faisait
// `NSWorkspace.shared.open` sur le chemin PORTÉ PAR LE LIEN :
// `fouine://open?path=/System/Applications/Calculator.app` ouvrait une fenêtre
// à l'aspect de Fouine, au premier plan, annonçant « Calculator.app » avec un
// bouton bleu qui aurait lancé la Calculette. Une page web appelle le lien ;
// l'auteur du lien choisit ce qui se lance.
//
// LA RÈGLE, DEPUIS : on n'ouvre QUE ce que Fouine aurait pu indexer. Un fichier
// ORDINAIRE, SOUS UNE RACINE SUIVIE, NON EXÉCUTABLE. Un paquet est refusé — sauf
// ceux qui SONT des documents pour Fouine (`.rtfd` est un dossier, et c'est un
// document) —, un dossier est refusé, un exécutable est refusé, et tout ce qui
// vit hors des dossiers surveillés est refusé. La feuille le dit alors en une
// phrase, plutôt que de proposer un geste qu'elle ne fera pas.

import Foundation
import FouineCore
import FouineExtract

/// Ce qu'il y a au bout du chemin d'un lien. C'est l'APPELANT qui regarde le
/// disque ; le routeur ne fait que trancher.
enum DeepLinkFileKind: Equatable {
    case missing
    case regular
    case directory
    /// Un paquet — `.app`, `.rtfd`, `.pages` : un dossier que le Finder montre
    /// comme un fichier.
    case package
    case executable
}

/// Ce que l'application doit faire d'un lien.
enum DeepLinkAction: Equatable {
    /// Montrer cette page dans sa propre fenêtre d'aperçu.
    ///
    /// `missingPage` porte le numéro DEMANDÉ quand il sort du document
    /// (BU-18) : la page montrée est alors la première, et la fenêtre dit
    /// pourquoi. `nil` dans le cas ordinaire.
    ///
    /// `time` est le moment en secondes d'un enregistrement (lot PV1) : la
    /// fenêtre y pose la tête de lecture, sans démarrer.
    case showPage(HitKey, missingPage: Int? = nil, time: Int? = nil)
    /// Le lien ne nomme pas de page : on ouvre le document à sa page 1.
    case showDocument(docID: Int64)
    /// `fouine://search?q=…` — rejouer une recherche.
    case search(String)
    /// Le lien est bien formé, mais Fouine ne connaît pas ce document.
    /// `canOpen` décide du bouton « Ouvrir le fichier » — et il est vrai
    /// beaucoup plus rarement que « le fichier existe ».
    case unknownDocument(path: String, canOpen: Bool)
    /// Rien à faire : le lien n'est pas un lien Fouine valide.
    case invalid
}

enum DeepLinkRouter {

    /// La décision, pure.
    ///
    /// - Parameters:
    ///   - resolve: rend l'identifiant du document désigné, ou `nil`.
    ///   - probe: ce qu'il y a à ce chemin sur le disque.
    ///   - roots: chemins absolus des dossiers suivis (`AppModel.roots`).
    ///   - pages: le nombre de pages du document résolu (`docs.n_pages`), ou
    ///     `nil` quand il n'est pas connu — une base ancienne peut le porter à
    ///     zéro, et on ne borne alors rien plutôt que de refuser une page
    ///     parfaitement valide.
    static func action(for link: DeepLink,
                       resolve: (DeepLink.Target) -> Int64?,
                       probe: (String) -> DeepLinkFileKind,
                       roots: [String],
                       pages: (Int64) -> Int? = { _ in nil }) -> DeepLinkAction {
        switch link {
        case .search(let query):
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .invalid : .search(text)

        case .open(let target, let page, _, let time):
            guard let docID = resolve(target) else {
                // Faute de chemin (forme `doc`), il n'y a rien à proposer
                // d'ouvrir : la feuille se contente alors de dire que le
                // document est inconnu.
                guard case .path(let path) = target else {
                    return .unknownDocument(path: "", canOpen: false)
                }
                return .unknownDocument(
                    path: path,
                    canOpen: canOpen(path: path, kind: probe(path), roots: roots))
            }
            guard let page else { return .showDocument(docID: docID) }
            // UNE PAGE HORS BORNES (BU-18). Une citation d'il y a un an dont
            // le document a été raccourci ouvrait une fenêtre vide qui
            // affirmait « page 99 999 ». On ouvre la première page, et la
            // fenêtre dit ce qui manque — la page 1 d'un document est toujours
            // une réponse honnête ; une fenêtre muette, jamais.
            if let total = pages(docID), total > 0, page > total {
                // Le moment ne suit PAS une page qui n'existe plus : il valait
                // pour la fenêtre citée, et le poser sur la page 1 ferait
                // écouter un autre passage que celui annoncé.
                return .showPage(HitKey(docID: docID, page: 1),
                                 missingPage: page)
            }
            return .showPage(HitKey(docID: docID, page: page), time: time)
        }
    }

    /// Fouine accepte-t-elle d'ouvrir ce chemin ? PURE, et volontairement
    /// avare.
    static func canOpen(path: String, kind: DeepLinkFileKind,
                        roots: [String]) -> Bool {
        guard isDocument(kind: kind, path: path) else { return false }
        return isUnderARoot(path: path, roots: roots)
    }

    /// Un paquet n'est un DOCUMENT que si son extension en est une pour Fouine :
    /// `.rtfd` (un dossier) et les formats iWork sont des documents que le
    /// crawler indexe, `.app` n'en est pas un.
    private static func isDocument(kind: DeepLinkFileKind, path: String) -> Bool {
        switch kind {
        case .regular:    return true
        case .package:    return isIndexedExtension(path)
        case .missing, .directory, .executable: return false
        }
    }

    private static func isIndexedExtension(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return DefaultExtractorRegistry.supportedExtensions.contains(ext)
            || DefaultExtractorRegistry.imageExtensions.contains(ext)
            || DefaultExtractorRegistry.mediaExtensions.contains(ext)
    }

    /// Le chemin est-il SOUS l'une des racines ?
    ///
    /// La comparaison porte sur des chemins standardisés et exige le `/`
    /// final : sans lui, `/Users/x/Documents2/piege.pdf` passerait pour être
    /// sous `/Users/x/Documents`. Une racine EST elle-même acceptée comme
    /// préfixe d'elle-même, mais jamais comme fichier — un dossier n'est pas un
    /// document.
    private static func isUnderARoot(path: String, roots: [String]) -> Bool {
        let file = (path as NSString).standardizingPath
        return roots.contains { root in
            let folder = (root as NSString).standardizingPath
            guard !folder.isEmpty else { return false }
            let prefix = folder.hasSuffix("/") ? folder : folder + "/"
            return file.hasPrefix(prefix)
        }
    }

    /// La même décision depuis une URL brute : une URL qui n'est pas un lien
    /// Fouine est `.invalid`, jamais une exception.
    static func action(for url: URL,
                       resolve: (DeepLink.Target) -> Int64?,
                       probe: (String) -> DeepLinkFileKind,
                       roots: [String],
                       pages: (Int64) -> Int? = { _ in nil }) -> DeepLinkAction {
        guard let link = DeepLink(url: url) else { return .invalid }
        return action(for: link, resolve: resolve, probe: probe, roots: roots,
                      pages: pages)
    }

    /// Ce qu'il y a à ce chemin, POUR DE VRAI. Le seul endroit de ce fichier
    /// qui touche le disque, et il est appelé par `FouineDesktopApp`, pas par
    /// la décision.
    static func probeFileSystem(_ path: String,
                                fileManager: FileManager = .default)
        -> DeepLinkFileKind {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path,
                                     isDirectory: &isDirectory) else { return .missing }
        // L'EXÉCUTABLE D'ABORD : un script `.sh` est un fichier ordinaire pour
        // `FileManager`, et c'est justement celui qu'il ne faut pas lancer.
        if !isDirectory.boolValue,
           fileManager.isExecutableFile(atPath: path) { return .executable }
        guard isDirectory.boolValue else { return .regular }
        let url = URL(fileURLWithPath: path)
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?
            .isPackage ?? false
        return isPackage ? .package : .directory
    }
}

/// Le lien reçu AVANT que l'index soit ouvert.
///
/// macOS remet `fouine://…` dès le lancement, souvent avant que `AppModel.start()`
/// ait fini d'ouvrir la base : résoudre un chemin à cet instant rendrait
/// « document inconnu » pour une page parfaitement indexée. Le lien attend donc,
/// et se rejoue à l'ouverture.
///
/// UN SEUL lien en attente, LE DERNIER : deux clics coup sur coup pendant les
/// deux secondes d'ouverture sont un utilisateur qui hésite, pas une file à
/// dérouler — et ouvrir deux fenêtres d'aperçu pour un seul geste voulu serait
/// une surprise.
struct DeepLinkQueue: Equatable {

    private(set) var pending: URL?

    /// Rend l'URL à traiter TOUT DE SUITE, ou `nil` si elle a été mise en
    /// attente.
    mutating func submit(_ url: URL, isReady: Bool) -> URL? {
        guard isReady else {
            pending = url
            return nil
        }
        pending = nil
        return url
    }

    /// L'URL en attente, une seule fois.
    mutating func resume() -> URL? {
        defer { pending = nil }
        return pending
    }
}
