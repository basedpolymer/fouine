// SourceDocument.swift — un fichier recopié par Fouine, tel que l'utilisateur
// le connaît : une carte de SON paquet, une note de SON application (lot AN2).
// Propriété : A-Ingest.
//
// LE PROBLÈME. Une source applicative recopie ses notes en fichiers Markdown
// (`AppSource`), et tout le reste du produit ne voit qu'un `.md` ordinaire.
// C'était le prix d'un lot petit ; il se payait à l'écran : « 625 Physico-chimie
// macromoléculaire.md », sous « Library/Application Support/Fouine/Sources/… »,
// un bouton « Afficher dans le Finder » vers le dossier de travail de Fouine, et
// un mode « Document » qui montrait le fichier brut, commentaires techniques et
// sauts de page compris. Relevé par le propriétaire le 14/09/2026 : ce qu'il
// cherche, ce sont ses cartes, rangées comme dans Anki.
//
// LA DÉCISION : RECONNAÎTRE LE DOCUMENT À SON EMPLACEMENT, et à lui seul. Un
// fichier est une copie de Fouine s'il vit sous `<Sources>/<Notes|Bear|Anki>/`
// — le dossier que Fouine fabrique et dont elle connaît le contenu au fichier
// près. Ce qu'un fichier DIT de lui-même (`fouine-source:` en tête) ne compte
// pas : n'importe quel `.md` d'une racine peut l'écrire, et c'est par là qu'un
// fichier forgé pouvait faire ouvrir un lien de son choix (rapport AN1, § 5).
//
// PUR : une chaîne en entrée, une valeur en sortie. Le seul accès disque est la
// résolution du volume du dossier des sources (`resolving`), faite une fois.

import Foundation
import FouineCore

/// Ce qu'un document recopié représente.
public struct SourceDocument: Sendable, Equatable {
    /// `notes`, `bear`, `anki`.
    public let sourceID: String
    /// Le nom de la racine, « Notes », « Bear », « Anki » : le premier maillon
    /// du fil d'Ariane, et le nom de la facette « Dossiers ».
    public let rootLabel: String
    /// Le nom de la note, ou celui du paquet — jamais un nom de fichier.
    public let title: String
    /// Les dossiers au-dessus : paquets parents d'Anki (et profil quand il y en
    /// a plusieurs). Vide pour Notes et Bear, recopiés à plat.
    public let folders: [String]

    public init(sourceID: String, rootLabel: String, title: String,
                folders: [String]) {
        self.sourceID = sourceID
        self.rootLabel = rootLabel
        self.title = title
        self.folders = folders
    }

    public var isAnkiDeck: Bool { sourceID == AnkiSource.identifier }

    /// La source elle-même, pour son application et son lien de réouverture.
    public var source: (any AppSource)? { AppSources.source(id: sourceID) }

    /// Le séparateur du fil d'Ariane : celui du menu Présentation du Finder et
    /// des chemins de Réglages Système, que les gens lisent déjà.
    public static let separator = " › "

    /// « Anki › M2SU 2026 » : où ranger ce document dans sa tête, à la place
    /// d'un chemin de fichier.
    public var breadcrumb: String {
        ([rootLabel] + folders).joined(separator: Self.separator)
    }
}

/// Où sont les copies, et comment reconnaître un document qui en est une.
public struct SourceDocumentLocator: Sendable, Equatable {

    /// Le dossier des sources, relatif à la racine de SON volume, sans « / »
    /// initial — la forme de `docs.rel_path` et de `roots.rel_path`.
    public let sourcesRelPath: String

    public init(sourcesRelPath: String) {
        var path = sourcesRelPath
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        self.sourcesRelPath = RelPath.normalized(path)
    }

    /// Le localisateur d'un dossier des sources réel : le volume est résolu
    /// comme pour une racine (`VolumeResolver.resolve`), et le chemin absolu
    /// sert de repli quand aucun volume ne répond (un test sans disque).
    public static func resolving(_ sourcesDirectory: URL) -> SourceDocumentLocator {
        if let resolved = try? VolumeResolver.resolve(path: sourcesDirectory) {
            return SourceDocumentLocator(sourcesRelPath: resolved.relPath)
        }
        return SourceDocumentLocator(
            sourcesRelPath: sourcesDirectory.standardizedFileURL.path)
    }

    /// Celui de la base en service (`FOUINE_DB` compris) : l'app, la remise à
    /// Spotlight et les raccourcis regardent le même dossier que la passe qui
    /// l'a rempli. Résolu une fois par processus.
    public static let standard = SourceDocumentLocator.resolving(
        FouinePaths.sourcesDirectory())

    /// La source dont `rootRelPath` est le dossier de copies, ou `nil`.
    public func source(rootRelPath: String) -> (any AppSource)? {
        let path = RelPath.normalized(rootRelPath)
        return AppSources.all.first { path == sourcesRelPath + "/" + $0.rootLabel }
    }

    /// Le document recopié que désigne `relPath`, ou `nil` pour tout document
    /// ordinaire — y compris un `.md` qui se déclarerait recopié ailleurs.
    public func document(relPath: String) -> SourceDocument? {
        let path = RelPath.normalized(relPath)
        let prefix = sourcesRelPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let inside = path.dropFirst(prefix.count)
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard inside.count >= 2, let fileName = inside.last,
              fileName.lowercased().hasSuffix(".md"),
              let source = AppSources.all.first(where: { $0.rootLabel == inside[0] })
        else { return nil }
        let stem = String(fileName.dropLast(3))
        guard !stem.isEmpty else { return nil }
        return SourceDocument(sourceID: source.id, rootLabel: source.rootLabel,
                              title: source.documentTitle(fileStem: stem),
                              folders: Array(inside.dropFirst().dropLast()))
    }
}
