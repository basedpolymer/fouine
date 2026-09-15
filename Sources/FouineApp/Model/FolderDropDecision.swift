// FolderDropDecision.swift — un dossier déposé sur l'icône du Dock (lot DD2).
// Propriété : A-App.
//
// LE GESTE. On tient un dossier dans le Finder, on le lâche sur l'icône de
// Fouine : c'est le premier geste que quelqu'un essaie quand il veut « chercher
// là-dedans ». Deux situations, et deux seulement :
//   — le dossier est DÉJÀ suivi (ou vit sous un dossier suivi) : Fouine n'a
//     rien à ajouter, elle prépare la recherche restreinte à ce dossier et
//     laisse la personne taper ce qu'elle cherche ;
//   — il n'est suivi par personne : Fouine DEMANDE avant de l'ajouter. Le
//     dépôt sur la barre latérale, lui, ajoute sans confirmation — parce qu'on
//     y vise la liste des dossiers, ce qui est déjà dire « ajoute-le ». Sur
//     l'icône du Dock on vise l'application, ce qui ne dit rien de tel : le
//     même geste peut vouloir dire « cherche » comme « ajoute », et indexer
//     d'autorité un dossier de cent mille fichiers sur un simple lâcher serait
//     une surprise coûteuse.
//
// L'ÉTIQUETTE EST CELLE DE LA RACINE, PAS DU SOUS-DOSSIER. `dossier:` filtre
// sur `top_folder`, c'est-à-dire sur la racine suivie : il n'existe aucun
// filtre plus fin. Déposer `Cours/Thermo` prépare donc `dossier:"Cours"`, et
// non un filtre sur `Thermo` qui n'existe pas — mieux vaut un filtre honnête
// et plus large qu'un filtre inventé qui rendrait zéro résultat.
//
// LA DÉCISION EST PURE, ET C'EST TOUT CE QUI EST ICI. Regarder le disque
// (dossier ? paquet ? fichier ?) appartient à l'appelant, comme pour
// `DeepLinkRouter` : les cas se jouent alors en mémoire, sans Finder et sans
// base jetable.

import Foundation

/// Une racine suivie, réduite à ce dont la décision a besoin.
struct DroppedFolderRoot: Equatable {
    /// L'étiquette de la racine — celle que `dossier:` attend.
    let label: String
    /// Son chemin absolu.
    let path: String
}

enum FolderDropDecision {

    enum Decision: Equatable {
        /// Le dossier est suivi : préparer `dossier:"<étiquette>" ` sans lancer.
        case search(label: String)
        /// Personne ne suit ce dossier : demander avant de l'ajouter.
        case proposeAdd(URL)
        /// Rien à faire, et sans un mot : ce n'est pas un dossier.
        case ignore
    }

    /// - Parameters:
    ///   - kind: ce qu'il y a à ce chemin, vu par l'appelant
    ///     (`DeepLinkRouter.probeFileSystem`). Un PAQUET — `.rtfd`, `.pages`,
    ///     une application — est un dossier pour le système de fichiers mais un
    ///     fichier pour qui le dépose : il tombe en `.ignore`, comme un fichier
    ///     ordinaire. Fouine n'est pas un lecteur de documents ; ouvrir quelque
    ///     chose sur un fichier déposé serait promettre ce qu'elle ne fait pas.
    ///   - roots: les racines suivies (`AppModel.roots`), celles dont le chemin
    ///     est connu.
    static func decide(url: URL, kind: DeepLinkFileKind,
                       roots: [DroppedFolderRoot]) -> Decision {
        guard kind == .directory else { return .ignore }
        let dropped = normalized(url.path)
        guard !dropped.isEmpty else { return .ignore }
        // LA RACINE LA PLUS LONGUE GAGNE. Rien n'interdit d'avoir ajouté
        // `Documents` puis `Documents/Cours` : le dossier déposé est alors sous
        // les deux, et l'étiquette qui renseigne est la plus proche de lui.
        let match = roots
            .compactMap { root -> (depth: Int, label: String)? in
                let folder = normalized(root.path)
                guard !folder.isEmpty else { return nil }
                let prefix = folder.hasSuffix("/") ? folder : folder + "/"
                guard dropped == folder || dropped.hasPrefix(prefix) else { return nil }
                return (folder.count, root.label)
            }
            .max { $0.depth < $1.depth }
        if let match { return .search(label: match.label) }
        return .proposeAdd(url)
    }

    /// Ce qui se pose dans le champ de recherche, sans être lancé.
    ///
    /// GUILLEMETS TOUJOURS, ESPACE FINALE TOUJOURS. L'étiquette par défaut est
    /// le nom du dossier, et un nom de dossier porte des espaces une fois sur
    /// deux (« Mes cours ») : sans guillemets, le filtre partirait sans valeur
    /// et le reste du nom deviendrait des mots à chercher (audit A1m-04).
    /// L'espace finale, elle, évite de coller le premier mot tapé au filtre.
    static func searchText(label: String) -> String {
        "dossier:\"\(label)\" "
    }

    /// La FORME UNICODE. Un chemin remis par le Finder peut être décomposé
    /// (« é » = e + accent), là où les racines enregistrées sont composées :
    /// deux écritures du même dossier qui ne se ressemblent pas octet pour
    /// octet, et un dossier parfaitement suivi qu'on proposerait d'ajouter une
    /// seconde fois. Les deux côtés passent donc par la forme composée.
    private static func normalized(_ path: String) -> String {
        (path as NSString).standardizingPath.precomposedStringWithCanonicalMapping
    }
}

/// La garde contre le DOUBLE traitement d'une même remise (lot DD2).
///
/// macOS a deux chemins pour remettre une URL à une application SwiftUI :
/// `application(_:open:)` du délégué et `.onOpenURL` de la scène. Les deux sont
/// branchés — lequel tire dépend de la version du système et de ce que le
/// délégué implémente —, et si les deux tirent, un seul dossier déposé
/// ouvrirait deux alertes identiques. On retient donc ce qui vient d'arriver :
/// la même URL dans la même seconde est la seconde livraison du même geste, pas
/// un second geste.
struct RecentOpenedURLs: Equatable {

    /// Une seconde : au-delà, c'est un vrai second dépôt. Personne ne relâche
    /// deux fois le même dossier en moins de temps que ça, et la double
    /// livraison du système, elle, est immédiate.
    static let window: TimeInterval = 1

    private var seen: [String: Date] = [:]

    /// Vrai s'il faut traiter cette URL.
    mutating func accept(_ url: URL, now: Date = Date()) -> Bool {
        // Un fichier se reconnaît à son chemin standardisé (l'espace finale
        // d'un dossier, la forme Unicode et le `/private` d'un lien symbolique
        // varient d'une livraison à l'autre) ; un lien `fouine://`, lui, se
        // reconnaît à son texte entier — sa requête EST son identité.
        let key = url.isFileURL
            ? url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
            : url.absoluteString
        if let last = seen[key], now >= last,
           now.timeIntervalSince(last) < Self.window { return false }
        // Les entrées trop vieilles pour compter s'en vont : la garde ne
        // grossit pas avec la durée de vie de l'application.
        seen = seen.filter { now.timeIntervalSince($0.value) < Self.window }
        seen[key] = now
        return true
    }
}
