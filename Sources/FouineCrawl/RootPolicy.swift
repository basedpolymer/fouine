// RootPolicy.swift — ce qu'un dossier a le droit d'être avant de devenir une
// racine indexée (SPEC §5.2, §7.1). Propriété : A-Ingest.
//
// Depuis l'audit produit du 01/09 (D1), les racines s'ajoutent depuis l'app
// (`NSOpenPanel`, glisser-déposer) et depuis `fouine root add`. Les deux chemins
// passent ICI, et par les mêmes phrases : un refus doit se lire pareil dans une
// alerte et dans un terminal.
//
// Pourquoi refuser, et pas seulement avertir :
//   · `/`, `~` et `~/Library` engloberaient `~/Library/Application Support/Fouine`
//     — Fouine indexerait sa propre base pendant qu'elle écrit dedans, plus les
//     caches de Mail, de Safari et des conteneurs d'apps ;
//   · `/System`, `/Library`, `/Applications` sont scellés ou binaires : des
//     centaines de milliers d'entrées pour zéro document ;
//   · `/private` porte `/private/var/folders`, où le système fabrique et détruit
//     des fichiers en permanence — un crawl y court derrière sa propre queue.
// Les ENFANTS de `/` et de `/private` restent légitimes (`/Volumes/Disque`,
// `/private/tmp/corpus` de la recette) : seul le dossier lui-même est refusé.
// Les arbres système, eux, sont refusés avec leur contenu.
//
// LES DONNÉES D'UNE APPLICATION LUE PAR FOUINE (14/09/2026). Le dossier
// d'Anki, d'Apple Notes ou de Bear reste refusé — il est sous `~/Library`, et
// ses fichiers sont des bases SQLite qu'aucun extracteur ne lit —, mais la
// phrase générique « ne contient pas de documents à indexer » y était FAUSSE :
// le propriétaire a choisi `~/Library/Application Support/Anki2/<profil>` pour
// retrouver ses cartes et n'a lu qu'un refus sans issue. Ces dossiers-là ont
// leur propre refus, qui nomme la case à cocher (réglage `sources.<id>`).
//
// `~/Downloads` n'est pas refusé mais ANNONCÉ : c'est le mode d'échec n°1 du
// projet (audit D19). Le dossier est lisible dans le Finder et muet pour une app
// sans l'autorisation TCC correspondante ; mieux vaut le dire avant l'indexation
// vide que la chercher après.
//
// LE MOTIF EST UN TYPE, PAS UNE PHRASE (palier 3.5, audit U1). `refusal(for:)`
// rend un `Refusal`, dont la CLI et l'agent tirent la phrase anglaise
// (`.english`) et dont l'application refait la sienne depuis le catalogue
// (`RootPolicyText`, FouineApp). Un anglophone ne lit donc plus « Le dossier
// personnel entier ne peut pas être une racine… » dans une alerte par ailleurs
// anglaise, et un francophone retrouve mot pour mot les phrases d'avant.

import Foundation
import FouineCore

public enum RootPolicy {

    // MARK: - Refus

    /// Pourquoi ce dossier ne peut pas devenir une racine, sous forme de
    /// DONNÉES. `path` est déjà abrégé pour l'affichage (`~` pour le dossier
    /// personnel) : c'est une donnée, pas du texte à traduire.
    public enum Refusal: Sendable, Equatable {
        case missing(path: String)
        case notADirectory(path: String)
        case wholeDisk
        case homeDirectory
        case privateFolder
        case systemTree(path: String)
        /// Le dossier où une application que Fouine sait lire range ses
        /// données : le geste est d'allumer la source, pas d'ajouter le dossier.
        case applicationData(path: String, application: Application)
        /// Refus de lecture : le seul cas qui appelle le geste TCC.
        case permissionDenied(path: String)
        case unreadable(path: String, detail: String)

        /// La phrase ANGLAISE, celle de `fouine root add` et de l'agent.
        public var english: String {
            switch self {
            case .missing(let path):
                return "“\(path)” cannot be found (folder moved, renamed or deleted)."
            case .notADirectory(let path):
                return "“\(path)” is a file, not a folder. Choose the folder that contains it."
            case .wholeDisk:
                return "The whole disk cannot be a root: Fouine would index the system, the caches and its own database. Choose a folder of documents."
            case .homeDirectory:
                return "Your entire home folder cannot be a root: it holds ~/Library, the caches and Fouine's own database. Choose a subfolder — Documents, Desktop, a folder of books…"
            case .privateFolder:
                return "“/private” is a system folder: it only holds the system's temporary files."
            case .systemTree(let path):
                return "“\(path)” is a system folder: it holds no documents to index."
            case .applicationData(let path, let application):
                return "“\(path)” is where \(application.displayName) keeps its data: it cannot be added as a folder. Run `fouine sources enable \(application.rawValue)` to search your \(application.itemNoun) instead."
            case .permissionDenied(let path):
                return "“\(path)” is not readable by Fouine. " + RootProbe.tccGuidance
            case .unreadable(let path, let detail):
                return "“\(path)” is not readable: \(detail)"
            }
        }
    }

    /// Les applications dont Fouine lit les données (`AppSource`, FouineIndex).
    /// La valeur brute est l'identifiant de la source — `fouine sources enable
    /// <id>`, clé `sources.<id>` — : FouineCrawl ne dépend pas de FouineIndex,
    /// et `AppSourcesTests` vérifie que les deux listes concordent.
    public enum Application: String, Sendable, CaseIterable {
        case notes, bear, anki

        /// Nom anglais, celui de la CLI ; l'app a le sien dans le catalogue.
        public var displayName: String {
            switch self {
            case .notes: return "Apple Notes"
            case .bear: return "Bear"
            case .anki: return "Anki"
            }
        }

        var itemNoun: String {
            self == .anki ? "cards" : "notes"
        }

        /// Le dossier des données, relatif au dossier personnel : ceux que
        /// lisent `AppleNotesSource`, `BearSource` et `AnkiSource`.
        var homeRelativeStore: String {
            switch self {
            case .notes: return "Library/Group Containers/group.com.apple.notes"
            case .bear: return "Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear"
            case .anki: return "Library/Application Support/Anki2"
            }
        }
    }

    /// Ce qu'il faut dire À CÔTÉ d'un dossier accepté. Un seul cas connu.
    public enum Advisory: Sendable, Equatable {
        case downloads

        public var english: String {
            switch self {
            case .downloads:
                return "The Downloads folder needs a specific macOS permission: if indexing turns up nothing, grant it to Fouine in System Settings ▸ Privacy & Security ▸ Files and Folders."
            }
        }
    }

    /// `nil` = ce dossier peut devenir une racine.
    public static func refusal(for url: URL) -> Refusal? {
        let path = canonical(url)
        let fm = FileManager.default

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing(path: display(path))
        }
        guard isDirectory.boolValue else {
            return .notADirectory(path: display(path))
        }

        if path == "/" { return .wholeDisk }
        if path == home { return .homeDirectory }
        if path == "/private" { return .privateFolder }
        // AVANT les arbres système, qui les contiennent : la phrase générique
        // y serait fausse.
        if let application = application(owning: path) {
            return .applicationData(path: display(path), application: application)
        }
        for tree in refusedTrees where path == tree || path.hasPrefix(tree + "/") {
            return .systemTree(path: display(tree))
        }

        // Lisibilité : un simple `access(2)` mentirait sous TCC (le refus n'arrive
        // qu'à l'ouverture). On énumère réellement le dossier — la lecture d'un
        // fichier, elle, reste le travail de `RootProbe.probe` au moment de
        // l'enregistrement.
        do {
            _ = try fm.contentsOfDirectory(atPath: path)
        } catch {
            let ns = error as NSError
            if ns.code == NSFileReadNoPermissionError || ns.code == EACCES
                || ns.code == EPERM {
                return .permissionDenied(path: display(path))
            }
            return .unreadable(path: display(path),
                               detail: ns.localizedDescription)
        }
        return nil
    }

    /// La phrase anglaise du refus, pour la CLI et l'agent. L'application, elle,
    /// part de `refusal(for:)` et rend la sienne depuis le catalogue.
    public static func refusalReason(for url: URL) -> String? {
        refusal(for: url)?.english
    }

    // MARK: - Avertissement (n'empêche rien)

    /// Ce qu'il y a à dire d'un dossier ACCEPTÉ, ou `nil`. Le seul cas connu est
    /// `~/Downloads`, dont l'accès dépend d'une autorisation TCC distincte de
    /// celle de Documents.
    public static func advisory(for url: URL) -> Advisory? {
        let path = canonical(url)
        guard let downloads = downloadsDirectory,
              path == downloads || path.hasPrefix(downloads + "/") else { return nil }
        return .downloads
    }

    /// La phrase anglaise de l'avertissement, pour la CLI et l'agent.
    public static func warning(for url: URL) -> String? {
        advisory(for: url)?.english
    }

    // MARK: - Étiquettes

    /// Étiquette proposée par défaut : dernier composant du chemin. Vide (racine
    /// d'un volume) → `nil`, l'appelant retombe sur le nom du volume.
    public static func suggestedLabel(for url: URL) -> String? {
        let last = url.standardizedFileURL.lastPathComponent
        return last.isEmpty || last == "/" ? nil : last
    }

    // MARK: - Interne

    /// L'application dont `path` (canonique) est le dossier de données, ou un
    /// dossier dessous. Le dossier PARENT (`~/Library/Group Containers`) n'en
    /// est pas un : il reste un arbre système ordinaire.
    static func application(owning path: String, home: String = home) -> Application? {
        Application.allCases.first { application in
            let store = home + "/" + application.homeRelativeStore
            return path == store || path.hasPrefix(store + "/")
        }
    }

    /// Arbres refusés AVEC leur contenu.
    private static var refusedTrees: [String] {
        ["/System", "/Library", "/Applications", home + "/Library"]
    }

    private static var home: String {
        canonical(FileManager.default.homeDirectoryForCurrentUser)
    }

    private static var downloadsDirectory: String? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            .first.map(canonical)
    }

    /// Chemin comparable : symboliques résolus (`/tmp` → `/private/tmp`), `..`
    /// réduits, barre oblique finale retirée. `/` reste `/`.
    private static func canonical(_ url: URL) -> String {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        if resolved.count > 1, resolved.hasSuffix("/") { return String(resolved.dropLast()) }
        return resolved
    }

    /// Chemin abrégé pour l'affichage : `~` au lieu du dossier personnel.
    private static func display(_ path: String) -> String {
        let h = home
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }
}
