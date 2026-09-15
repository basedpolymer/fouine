// AppSource.swift — le contrat d'une source applicative (lot INT-F4).
// Propriété : A-Ingest.
//
// LE PROBLÈME. Fouine indexe des FICHIERS rangés sous des dossiers désignés.
// Apple Notes et Bear ne rangent rien : leurs notes vivent dans une base
// SQLite, sous `~/Library/Group Containers/…`, où aucun crawl ne va et où
// aucun extracteur ne saurait quoi lire. Elles sont donc invisibles, et c'est
// la dernière famille de documents que le produit ne sait pas trouver.
//
// LA DÉCISION : NE PAS FABRIQUER UN SECOND CHEMIN D'INDEXATION. Une source
// applicative se lit (en LECTURE SEULE, jamais une écriture, jamais le fichier
// verrouillé de l'application), et chaque note est RECOPIÉE en un fichier
// Markdown sous `~/Library/Application Support/Fouine/Sources/<App>/`. Ce
// dossier devient une racine ordinaire, que la passe habituelle parcourt,
// extrait, indexe, donne à Spotlight et rend cherchable. Aucune migration de
// schéma, aucun état nouveau, aucun cas particulier dans la recherche : le
// jour où l'utilisateur éteint la source, on efface le dossier et la racine,
// et le produit revient exactement où il était.
//
// CE QUE ÇA COÛTE, ET POURQUOI C'EST LE BON PRIX : une copie du texte des
// notes, sur le même Mac, dans le dossier de Fouine. C'est écrit en toutes
// lettres dans la fenêtre de réglages et dans `docs/privacy.md`. Le contraire
// — lire la base d'Apple Notes À CHAQUE recherche — supposerait une base
// lisible en permanence (elle ne l'est pas : TCC), un format stable (il ne
// l'est pas : le protobuf change de version), et un second moteur de recherche.
//
// NOTION ET CRAFT ne sont pas ici, et c'est un choix. Notion garde ses pages
// sur son serveur (le cache local est un format privé, chiffré et non
// documenté) et Craft les range dans un conteneur que rien ne promet stable.
// Pour ces deux-là, la réponse est l'EXPORT : un dossier Markdown ou HTML que
// Fouine lit déjà, ajouté comme une racine ordinaire. Il ne reste qu'à savoir
// rouvrir une page dans son application — c'est `SourceLinks`.

import Foundation
import FouineCore

/// UNE note lue dans une application, avant toute écriture.
///
/// VALEUR pure : les tests fabriquent des `SourceNote` à la main, et la
/// matérialisation se prouve sans base SQLite ni application installée.
public struct SourceNote: Sendable, Equatable {
    /// Identifiant STABLE dans l'application d'origine (UUID d'Apple Notes,
    /// `ZUNIQUEIDENTIFIER` de Bear). Il sert à deux choses : le lien de
    /// réouverture, et le suffixe du nom de fichier — deux notes peuvent
    /// porter le même titre, jamais le même identifiant.
    public let id: String
    public let title: String
    public let text: String
    /// Dossier de l'application, quand elle en a un. Informatif : la
    /// matérialisation d'Apple Notes et de Bear est PLATE (voir
    /// `SourceMaterializer`).
    public let folder: String?
    public let modified: Date
    /// Le lien qui rouvre la note dans son application. `nil` quand
    /// l'application n'en a pas (Anki, lot AN1) : l'aperçu retrouve alors
    /// l'application elle-même, sans lien écrit dans le fichier.
    public let openURL: URL?
    /// Chemin du fichier SOUS le dossier de la source, composants déjà
    /// nettoyés par `SourceMaterializer.cleanComponent`, quand la source range
    /// ses fichiers elle-même — Anki : un dossier par paquet parent, un fichier
    /// par paquet (lot AN1). `nil` : à plat, nom tiré du titre et de
    /// l'identifiant, comme pour Apple Notes et Bear.
    public let relativePath: String?
    /// Note à la corbeille : elle n'est pas écrite, et son fichier est effacé
    /// s'il existait.
    public let deleted: Bool
    /// Le titre ouvre-t-il le texte (`# Titre`) ? Oui pour une note : Fouine
    /// n'indexe pas les noms de fichiers, et le titre d'une note se cherche.
    /// Non pour un paquet Anki (lot AN2) : le nom du paquet n'est d'aucune
    /// carte, et en tête de la première il la faisait répondre à chaque mot du
    /// nom du paquet — le nom se trouve par « documents dont le nom contient ».
    public let titleInText: Bool
    /// Note verrouillée par un mot de passe : son texte est chiffré, on ne
    /// l'écrit pas et on le DIT (une ligne de journal), plutôt que d'indexer
    /// un titre sans corps.
    public let locked: Bool
    /// Ce qui a empêché de lire le CORPS de cette note, quand ce n'est pas
    /// ordinaire — aujourd'hui le seul cas est un blob qui dépasse le plafond
    /// de décompression (CM-14). Le motif remonte dans le bilan de
    /// synchronisation ; les autres notes sont écrites normalement.
    public let problem: String?

    public init(id: String, title: String, text: String, folder: String? = nil,
                modified: Date, openURL: URL?, relativePath: String? = nil,
                titleInText: Bool = true,
                deleted: Bool = false, locked: Bool = false,
                problem: String? = nil) {
        self.id = id
        self.title = title
        self.text = text
        self.folder = folder
        self.modified = modified
        self.openURL = openURL
        self.relativePath = relativePath
        self.titleInText = titleInText
        self.deleted = deleted
        self.locked = locked
        self.problem = problem
    }
}

/// Pourquoi une source n'a pas pu être lue.
///
/// `accessDenied` est DISTINCT de `missing`, et c'est tout l'intérêt du type :
/// « Bear n'est pas installé sur ce Mac » et « macOS refuse à Fouine l'accès à
/// vos notes » appellent deux phrases et deux gestes opposés. Confondre les
/// deux, c'est envoyer quelqu'un dans les Réglages Système pour une
/// application qu'il n'a jamais installée.
public enum SourceError: Error, Equatable, LocalizedError {
    /// Ni l'application ni sa base ne sont là.
    case missing(source: String)
    /// La base est là et macOS refuse la lecture : « Accès complet au disque ».
    case accessDenied(source: String)
    /// Base illisible pour une autre raison (corrompue, schéma inconnu).
    case unreadable(source: String, detail: String)

    /// ANGLAIS, comme tout ce que la CLI et les journaux impriment.
    public var errorDescription: String? {
        switch self {
        case .missing(let source):
            return "\(source): not installed on this Mac (nothing to read)."
        case .accessDenied(let source):
            return "\(source): macOS denies access to its notes. Grant Full "
                 + "Disk Access to Fouine in System Settings ▸ Privacy & "
                 + "Security ▸ Full Disk Access, then try again."
        case .unreadable(let source, let detail):
            return "\(source): notes are unreadable (\(detail))."
        }
    }
}

/// Ce que Fouine sait d'une source SANS la lire entièrement.
public enum SourcePresence: Sendable, Equatable {
    /// L'application n'est pas installée (sa base n'existe pas).
    case absent
    /// La base est là et lisible.
    case ready
    /// La base est là et macOS en refuse la lecture (TCC).
    case accessDenied
}

/// Une application dont Fouine sait lire les notes.
public protocol AppSource: Sendable {
    /// Identifiant technique, celui de la CLI et du réglage : `notes`, `bear`.
    var id: String { get }
    /// Nom de l'APPLICATION, tel qu'un utilisateur la connaît.
    var displayName: String { get }
    /// Étiquette de la racine indexée, et nom du sous-dossier. Court : c'est
    /// ce qui s'affiche dans la facette « Dossiers ».
    var rootLabel: String { get }
    /// La base à lire.
    var storeURL: URL { get }
    /// Le gabarit de lien de réouverture, `%@` à la place de l'identifiant.
    /// Publié pour la documentation et les tests ; `notes()` rend déjà des
    /// liens résolus.
    var openURLTemplate: String { get }
    /// L'application est-elle là ? (l'existence de sa base, pas celle du
    /// `.app` : c'est la base qu'on lit, et elle survit à une désinstallation
    /// — les notes aussi.)
    func isPresent(fileManager: FileManager) -> Bool
    /// Présence ET lisibilité, sans lire les notes. Une ouverture SQLite en
    /// lecture seule, refermée aussitôt : c'est le seul moyen de distinguer un
    /// refus TCC d'une absence, `access(2)` mentant sous TCC.
    func probe(fileManager: FileManager) -> SourcePresence
    /// Toutes les notes, corbeille et notes verrouillées comprises (c'est
    /// l'appelant qui décide de leur sort — une note effacée doit faire
    /// effacer son fichier).
    func notes() throws -> [SourceNote]
    /// Ce qu'un FICHIER recopié représente, en anglais, pour les bilans de la
    /// CLI et du journal : « note » (un fichier par note), « deck » (Anki, un
    /// fichier par paquet).
    var fileNoun: String { get }
    /// Le nombre de NOTES cherchables dans `folder`, tel qu'il est sur le
    /// disque — ce que disent la fenêtre de réglages et `sources list`.
    func copiedNoteCount(in folder: URL, fileManager: FileManager) -> Int
    /// Les identifiants de paquet de l'application, du plus récent au plus
    /// ancien : l'app en tire l'icône de l'application et le bouton qui
    /// l'ouvre (lot AN2), jamais d'un chemin lu dans un fichier.
    var bundleIdentifiers: [String] { get }
    /// Le nom qu'un fichier recopié porte pour l'utilisateur, depuis le nom du
    /// fichier sans extension (lot AN2) : le titre de la note, ou le paquet.
    func documentTitle(fileStem: String) -> String
}

public extension AppSource {
    // LES RACCOURCIS SANS ARGUMENT SONT À PART, et ce n'est pas du style (lot
    // AN1). Tant que l'implémentation par défaut portait elle-même
    // `fileManager: FileManager = .default`, un appel `source.probe()` sur un
    // `any AppSource` ne pouvait viser que ce membre d'extension — l'exigence du
    // protocole attend un argument — et Swift l'appelle STATIQUEMENT : la
    // version d'Anki n'était jamais jouée, et `fouine sources enable anki`
    // répondait « accès refusé » après avoir ouvert en SQLite… un dossier.
    // Mesuré le 14/09/2026. Les raccourcis renvoient maintenant à l'exigence,
    // qui, elle, passe par la table du type.

    func isPresent() -> Bool { isPresent(fileManager: .default) }
    func probe() -> SourcePresence { probe(fileManager: .default) }
    func copiedNoteCount(in folder: URL) -> Int {
        copiedNoteCount(in: folder, fileManager: .default)
    }

    func isPresent(fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: storeURL.path)
    }

    func probe(fileManager: FileManager) -> SourcePresence {
        guard isPresent(fileManager: fileManager) else { return .absent }
        do {
            let reader = try SQLiteReader(url: storeURL, source: displayName)
            reader.close()
            return .ready
        } catch SourceError.accessDenied {
            return .accessDenied
        } catch {
            // Base présente et illisible pour une autre raison : ce n'est pas
            // une absence — la fenêtre de réglages doit proposer le geste TCC,
            // qui est le seul geste connu, plutôt que de se taire.
            return .accessDenied
        }
    }

    var fileNoun: String { "note" }

    /// Un fichier par note se nomme « Titre-1a2b3c4d.md »
    /// (`SourceMaterializer.fileName`) : le suffixe d'identifiant s'en va. Le
    /// titre lui-même peut porter un tiret — seul le DERNIER segment, fait de
    /// lettres et de chiffres et pas plus long que le suffixe, est retiré.
    func documentTitle(fileStem: String) -> String {
        guard let dash = fileStem.lastIndex(of: "-") else { return fileStem }
        let suffix = fileStem[fileStem.index(after: dash)...]
        let head = fileStem[..<dash].trimmingCharacters(in: .whitespaces)
        guard !suffix.isEmpty, !head.isEmpty,
              suffix.count <= SourceMaterializer.identifierLength,
              suffix.allSatisfy({ $0.isLetter || $0.isNumber }) else { return fileStem }
        return head
    }

    /// Un fichier par note : compter les notes, c'est compter les `.md`, sous-
    /// dossiers compris.
    func copiedNoteCount(in folder: URL, fileManager: FileManager) -> Int {
        SourceMaterializer.markdownFiles(in: folder, fileManager: fileManager).count
    }

    /// Le lien de réouverture d'une note, depuis son identifiant.
    func openURL(forNote id: String) -> URL? {
        let escaped = id.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? id
        return URL(string: openURLTemplate.replacingOccurrences(of: "%@",
                                                               with: escaped))
    }
}

// MARK: - Le catalogue

/// Les sources connues, et le réglage qui les allume.
///
/// UN seul endroit : la CLI, la fenêtre de réglages et la passe d'indexation
/// lisent cette table plutôt que d'en tenir chacune une copie — c'est la leçon
/// du catalogue de réglages (`SettingKeys.all`).
public enum AppSources {

    /// Dans l'ordre d'affichage.
    public static let all: [any AppSource] = [AppleNotesSource(), BearSource(),
                                              AnkiSource()]

    public static func source(id: String) -> (any AppSource)? {
        all.first { $0.id == id }
    }

    /// La clé de réglage d'une source.
    public static func settingKey(for id: String) -> SettingSpec? {
        switch id {
        case AppleNotesSource.identifier: return SettingKeys.sourceNotes
        case BearSource.identifier:       return SettingKeys.sourceBear
        case AnkiSource.identifier:       return SettingKeys.sourceAnki
        default:                          return nil
        }
    }

    /// Les sources ALLUMÉES dans ces réglages.
    public static func enabled(_ snapshot: SettingsSnapshot) -> [any AppSource] {
        all.filter { source in
            guard let spec = settingKey(for: source.id) else { return false }
            return snapshot.bool(spec)
        }
    }
}
