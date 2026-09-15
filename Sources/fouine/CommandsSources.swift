// CommandsSources.swift — `fouine sources` (lot INT-F4). Propriété : A-Core.
//
// Le pendant en ligne de commande de la section « Applications » de la fenêtre
// de réglages : les deux écrivent les MÊMES clés (`sources.notes`,
// `sources.bear`, `sources.anki`) et appellent le MÊME `SourceSync`. Il n'y a donc pas de
// geste possible d'un côté et pas de l'autre — c'est la règle posée par
// `fouine config` face à la fenêtre de réglages (audit U2).
//
// TROIS SOUS-COMMANDES ÉCRIVENT (`enable`, `disable`, `sync`) : elles copient
// des fichiers dans le dossier de Fouine et touchent la table des racines.
// `list`, lui, ne lit rien d'autre que les réglages et le contenu du dossier.
//
// POURQUOI `enable` SYNCHRONISE TOUT DE SUITE. Cocher une case qui ne fait
// rien avant la prochaine passe est un réglage auquel personne ne croit —
// c'est le raisonnement des racines épinglées (audit F4) et de Spotlight
// (INT-S1). Le geste et son effet arrivent ensemble.

import Foundation
import ArgumentParser
import FouineCore
import FouineIndex

/// Une panne de source. `LocalizedError` pour que `CLI.describe` rende la
/// phrase telle quelle ; code de sortie 1 (erreur générique) — l'index, lui,
/// est intact, seule la recopie des notes a échoué.
struct SourcesFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct SourcesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sources",
        abstract: "Index the notes of Apple Notes and Bear, and the flashcards "
                + "of Anki (copied into Fouine's own folder).",
        subcommands: [SourcesList.self, SourcesEnable.self, SourcesDisable.self,
                      SourcesSync.self],
        defaultSubcommand: SourcesList.self)

    /// Le dossier des fichiers matérialisés, à côté de la base ouverte.
    static var directory: URL {
        FouinePaths.sourcesDirectory(for: CLI.databaseURL())
    }

    /// La source nommée, ou une erreur d'USAGE (code 64) avec la liste des
    /// noms valides : une faute de frappe ne doit rien laisser à deviner.
    static func source(named name: String) throws -> any AppSource {
        guard let source = AppSources.source(id: name.lowercased()) else {
            throw ValidationError(
                "unknown source: “\(name)”. Valid names: "
                + AppSources.all.map(\.id).joined(separator: ", "))
        }
        return source
    }

    /// Nombre de notes recopiées, tel qu'il est SUR LE DISQUE.
    ///
    /// Aucun marqueur en base : le dossier EST le bilan, il ne peut pas mentir,
    /// et il n'y a pas une clé de réglage de plus à traduire et à expliquer.
    /// C'est la source qui compte : un fichier par note pour Apple Notes et
    /// Bear, une page par note dans un fichier par paquet pour Anki.
    static func fileCount(for source: any AppSource) -> Int {
        source.copiedNoteCount(
            in: directory.appendingPathComponent(source.rootLabel, isDirectory: true),
            fileManager: .default)
    }

    static func presenceText(_ presence: SourcePresence) -> String {
        switch presence {
        case .absent:       return "not installed"
        case .ready:        return "installed"
        case .accessDenied: return "installed, access denied (Full Disk Access)"
        }
    }
}

// MARK: - fouine sources list

struct SourcesList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Every application source, whether it is installed and "
                + "whether Fouine reads it.")

    @Flag(name: .long, help: "JSON output.") var json = false

    func run() {
        CLI.guarded {
            let store = try CLI.openStoreReadOnly()
            let snapshot = SettingsSnapshot(rows: try store.settingsRows())
            var rows: [[String: Any]] = []
            for source in AppSources.all {
                let enabled = AppSources.settingKey(for: source.id)
                    .map { snapshot.bool($0) } ?? false
                let presence = source.probe()
                let count = SourcesCommand.fileCount(for: source)
                rows.append([
                    "id": source.id,
                    "name": source.displayName,
                    "enabled": enabled,
                    "present": presence != .absent,
                    "access_denied": presence == .accessDenied,
                    "notes": count,
                    "store": source.storeURL.path,
                ])
                if !json {
                    print("\(source.id)  \(source.displayName)")
                    print("      enabled=\(enabled ? "yes" : "no")  "
                          + SourcesCommand.presenceText(presence)
                          + "  \(count) note(s) copied")
                }
            }
            if json { try CLI.printJSON(["sources": rows]) }
        }
    }
}

// MARK: - fouine sources enable / disable

struct SourcesEnable: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Read the notes of an application and index them "
                + "(copies them into Fouine's folder).")

    @Argument(help: "Source name: notes, bear or anki.") var name: String

    func validate() throws { _ = try SourcesCommand.source(named: name) }

    func run() {
        CLI.guarded {
            let source = try SourcesCommand.source(named: name)
            let store = try CLI.openStore()
            guard let spec = AppSources.settingKey(for: source.id) else { return }
            // L'ACCÈS D'ABORD, LA CLÉ ENSUITE (constat CM-19). `fouine sources
            // enable bear` sortait en 1 — « Bear: not installed on this Mac » —
            // APRÈS avoir écrit `sources.bear = true` : une commande qui rend un
            // échec avait changé l'état, et `sources list --json` annonçait
            // ensuite `enabled: true` pour une source que rien ne lit.
            let presence = source.probe()
            if presence == .absent {
                throw SourcesFailure(
                    message: (SourceError.missing(source: source.displayName)
                        .errorDescription ?? "not installed")
                    + " Setting left unchanged.")
            }
            // Le refus TCC se dit AVANT la synchronisation ET avant l'écriture :
            // « 0 note » sans explication laisserait croire à un dossier vide.
            if presence == .accessDenied {
                throw SourcesFailure(
                    message: (SourceError.accessDenied(source: source.displayName)
                        .errorDescription ?? "access denied")
                    + " Setting left unchanged.")
            }
            _ = try Settings(store: store).set(spec.key, "true")
            print("\(source.displayName): enabled")
            try SourcesSync.perform(store: store, sources: [source])
        }
    }
}

struct SourcesDisable: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Stop indexing the notes of an application and delete the "
                + "copies Fouine had made.")

    @Argument(help: "Source name: notes, bear or anki.") var name: String

    func validate() throws { _ = try SourcesCommand.source(named: name) }

    func run() {
        CLI.guarded {
            let source = try SourcesCommand.source(named: name)
            let store = try CLI.openStore()
            guard let spec = AppSources.settingKey(for: source.id) else { return }
            _ = try Settings(store: store).set(spec.key, "false")
            let entry = SourceSync.disable(source: source, store: store,
                                           directory: SourcesCommand.directory)
            print("\(source.displayName): disabled, \(entry.removed) copied "
                  + "note(s) deleted")
            if let error = entry.error { CLI.warn(error) }
        }
    }
}

// MARK: - fouine sources sync

struct SourcesSync: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Copy the notes of the enabled applications again "
                + "(the indexing pass does it too).")

    func run() {
        CLI.guarded {
            let store = try CLI.openStore()
            let snapshot = SettingsSnapshot(rows: try store.settingsRows())
            let sources = AppSources.enabled(snapshot)
            guard !sources.isEmpty else {
                print("no application source enabled "
                      + "(see `fouine sources enable notes`)")
                return
            }
            try Self.perform(store: store, sources: sources)
        }
    }

    /// La synchronisation, partagée avec `enable`. Les phrases du bilan partent
    /// sur la sortie standard ; une panne devient un code de sortie, parce
    /// qu'un script doit pouvoir s'en apercevoir.
    static func perform(store: GRDBStore, sources: [any AppSource]) throws {
        let report = SourceSync.run(store: store, sources: sources,
                                    directory: SourcesCommand.directory)
        for entry in report.entries { print(entry.summary) }
        guard report.errors.isEmpty else {
            throw SourcesFailure(message: report.errors.joined(separator: " · "))
        }
        print("run `fouine index` to search them "
              + "(the background agent does it by itself).")
    }
}
