// SourceSync.swift — mettre les notes des applications à jour, puis laisser
// l'index faire son travail (lot INT-F4). Propriété : A-Ingest.
//
// L'ENCHAÎNEMENT, en trois temps et pas un de plus :
//
//   1. LIRE la base de l'application (lecture seule stricte) ;
//   2. ÉCRIRE les fichiers Markdown sous `<sources>/<App>/` et effacer ceux
//      dont la note a disparu ;
//   3. S'ASSURER que ce dossier est une racine indexée, une seule fois.
//
// Le reste — parcours, extraction, indexation, Spotlight — est le chemin
// habituel, inchangé. C'est pourquoi la synchronisation a lieu AU DÉBUT d'une
// passe : les fichiers sont à jour avant que le crawl ne les regarde, et la
// même passe indexe donc ce qui vient d'être écrit.
//
// RIEN ICI N'EST FATAL. Une base refusée par TCC, une application désinstallée,
// un schéma changé : le bilan porte la phrase, la passe continue. L'inverse —
// une passe d'indexation qui tombe parce qu'Apple a modifié une table dans une
// mise à jour de macOS — serait un mode de panne inacceptable pour un index
// qui tourne tout seul en arrière-plan.
//
// LA RACINE N'EST PAS AJOUTÉE PAR `RootPolicy`. Ce dossier vit sous
// `~/Library`, que la politique de racine REFUSE à juste titre pour un geste
// d'utilisateur (« Ajouter un dossier… » sur `~/Library` indexerait les caches
// de tout le système et la base de Fouine elle-même). Ici, ce n'est pas un
// dossier choisi par quelqu'un : c'est un dossier fabriqué par Fouine, dont
// elle connaît le contenu au fichier près. Le crawl, lui, n'exclut que
// `~/Library` EXACTEMENT (`CrawlExclusions.isHomeLibrary`) : un dossier situé
// dessous et désigné comme racine se parcourt normalement.

import Foundation
import FouineCore

/// Ce que la synchronisation demande à la base : trois méthodes, celles des
/// racines. Un protocole étroit plutôt qu'`IndexStore` tout entier, pour que le
/// test n'ait pas à implémenter trente méthodes qu'il n'appelle pas.
public protocol SourceRootStore: Sendable {
    func roots() throws -> [RootRecord]
    func addRoot(path: URL, label: String?) throws -> Int64
    func removeRoot(id: Int64) throws
}

extension GRDBStore: SourceRootStore {}

/// Le bilan d'une synchronisation, source par source.
public struct SourceSyncReport: Sendable, Equatable {

    public struct Entry: Sendable, Equatable {
        public let sourceID: String
        public let displayName: String
        /// Ce qu'un fichier représente dans le bilan : « note », ou « deck »
        /// pour Anki (un fichier par paquet, lot AN1).
        public var fileNoun = "note"
        /// Fichiers écrits, inchangés, effacés, notes sautées.
        public var written = 0
        public var unchanged = 0
        public var removed = 0
        public var skipped = 0
        /// La panne rencontrée, s'il y en a une.
        public var error: String?
        /// Fichiers présents après coup.
        public var files: Int { written + unchanged }

        public init(sourceID: String, displayName: String) {
            self.sourceID = sourceID
            self.displayName = displayName
        }

        /// Une ligne de journal, en anglais comme tout ce que la CLI imprime.
        ///
        /// La phrase d'erreur NOMME DÉJÀ la source (`SourceError` la porte) :
        /// la préfixer une seconde fois donnait « Apple Notes: Apple Notes:
        /// macOS denies… » — mesuré à la main le 08/09.
        public var summary: String {
            if let error { return error }
            return "\(displayName): \(files) \(fileNoun)(s) copied "
                 + "(\(written) written, \(removed) removed, \(skipped) skipped)"
        }
    }

    public var entries: [Entry] = []
    public init() {}

    public var written: Int { entries.reduce(0) { $0 + $1.written } }
    public var removed: Int { entries.reduce(0) { $0 + $1.removed } }
    public var skipped: Int { entries.reduce(0) { $0 + $1.skipped } }
    public var files: Int { entries.reduce(0) { $0 + $1.files } }
    public var errors: [String] { entries.compactMap(\.error) }
    public var didSomething: Bool { written > 0 || removed > 0 }
}

public enum SourceSync {

    /// Met à jour les sources données. Ne jette JAMAIS.
    ///
    /// - Parameter directory: le dossier des sources
    ///   (`FouinePaths.sourcesDirectory()` en production, un dossier temporaire
    ///   dans les tests — aucun chemin n'est écrit en dur ici).
    @discardableResult
    public static func run(store: any SourceRootStore,
                           sources: [any AppSource],
                           directory: URL = FouinePaths.sourcesDirectory(),
                           fileManager: FileManager = .default,
                           log: (String) -> Void = { _ in }) -> SourceSyncReport {
        var report = SourceSyncReport()
        for source in sources {
            var entry = SourceSyncReport.Entry(sourceID: source.id,
                                               displayName: source.displayName)
            entry.fileNoun = source.fileNoun
            let folder = directory.appendingPathComponent(source.rootLabel,
                                                          isDirectory: true)
            do {
                let notes = try source.notes()
                let written = SourceMaterializer.write(
                    notes: notes, sourceID: source.id, into: folder,
                    fileManager: fileManager)
                entry.written = written.written
                entry.unchanged = written.unchanged
                entry.removed = written.removed
                entry.skipped = written.skipped
                // Une panne d'écriture ne nomme pas la source, contrairement à
                // une `SourceError` : on la préfixe ici, et là seulement.
                if let first = written.errors.first {
                    entry.error = "\(source.displayName): \(first)"
                }
                for message in written.errors { log(message) }
                // La racine est assurée MÊME quand rien n'a changé : elle a pu
                // être retirée à la main entre deux passes.
                _ = try ensureRoot(store: store, source: source, folder: folder,
                                   log: log)
                let locked = notes.filter(\.locked).count
                if locked > 0 {
                    log("\(source.displayName): \(locked) locked note(s) skipped "
                        + "(their text is encrypted)")
                }
            } catch {
                entry.error = IndexText.describe(error)
            }
            log(entry.summary)
            report.entries.append(entry)
        }
        return report
    }

    /// La racine de cette source, créée si besoin. Rend son identifiant.
    ///
    /// La comparaison se fait sur l'ÉTIQUETTE et non sur le chemin : le chemin
    /// est stocké en (volume, rel_path) et sa reconstruction dépend du montage,
    /// là où l'étiquette est fixée par Fouine elle-même (« Notes », « Bear »).
    @discardableResult
    public static func ensureRoot(store: any SourceRootStore,
                                  source: any AppSource, folder: URL,
                                  log: (String) -> Void = { _ in }) throws -> Int64 {
        if let existing = try store.roots().first(where: { $0.label == source.rootLabel }) {
            return existing.id
        }
        let id = try store.addRoot(path: folder, label: source.rootLabel)
        log("\(source.displayName): folder “\(source.rootLabel)” is now indexed")
        return id
    }

    /// Éteindre une source : la racine part avec son index, et le dossier des
    /// fichiers matérialisés est effacé.
    ///
    /// Les deux vont ENSEMBLE. Laisser les fichiers derrière ferait de la
    /// désactivation un demi-geste : des copies de notes personnelles
    /// resteraient sur le disque, dans un dossier que personne ne pense à
    /// visiter. Laisser la racine ferait réapparaître les documents à la
    /// première passe.
    @discardableResult
    public static func disable(source: any AppSource,
                               store: any SourceRootStore,
                               directory: URL = FouinePaths.sourcesDirectory(),
                               fileManager: FileManager = .default,
                               log: (String) -> Void = { _ in })
        -> SourceSyncReport.Entry {
        var entry = SourceSyncReport.Entry(sourceID: source.id,
                                           displayName: source.displayName)
        do {
            if let root = try store.roots().first(where: { $0.label == source.rootLabel }) {
                try store.removeRoot(id: root.id)
            }
        } catch {
            entry.error = IndexText.describe(error)
        }
        let folder = directory.appendingPathComponent(source.rootLabel,
                                                      isDirectory: true)
        if fileManager.fileExists(atPath: folder.path) {
            // En NOTES, sous-dossiers compris : un paquet Anki recopié en porte
            // des centaines.
            let count = source.copiedNoteCount(in: folder, fileManager: fileManager)
            do {
                try fileManager.removeItem(at: folder)
                entry.removed = count
            } catch {
                entry.error = entry.error ?? error.localizedDescription
            }
        }
        log("\(source.displayName): \(entry.removed) copied note(s) deleted")
        return entry
    }
}
