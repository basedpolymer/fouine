// CommandsConfig.swift — `fouine config` (SPEC §4.3, audit U2). A-Core.
//
// Le pendant en ligne de commande de la fenêtre de réglages : les deux écrivent
// dans la MÊME table `settings` (schéma v4), avec la MÊME validation
// (`SettingSpec.normalize`). Il n'y a donc pas de réglage joignable d'un côté et
// pas de l'autre — c'était le reproche de fond de l'audit U2, où les réglages de
// l'agent n'existaient que sous forme de variables d'environnement dans un plist
// enfoui dans le bundle.
//
// AUCUNE de ces sous-commandes ne prend `fouine.lock` (voir l'en-tête de
// `GRDBStore+Settings.swift`) : `fouine config set agent.ocrBudgetMinutes 2`
// doit marcher PENDANT que l'agent OCRise, sinon le seul moment où l'on veut
// baisser le budget est justement celui où l'on ne peut pas.

import Foundation
import ArgumentParser
import FouineCore
import FouineIndex
import FouineOCR

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read and write the settings shared by the app, the CLI and the agent.",
        subcommands: [ConfigList.self, ConfigGet.self, ConfigSet.self,
                      ConfigReset.self],
        defaultSubcommand: ConfigList.self)

    /// Une ligne de tableau : clé, valeur effective, provenance, défaut.
    static func describe(_ entry: (spec: SettingSpec, value: String,
                                   source: SettingSource)) -> String {
        let value = entry.value.isEmpty ? "(empty)" : entry.value
        let key = entry.spec.key.padding(
            toLength: max(28, entry.spec.key.count), withPad: " ", startingAt: 0)
        return key + " " + value + "  [" + entry.source.english + "]"
    }

    static func json(_ entry: (spec: SettingSpec, value: String,
                               source: SettingSource)) -> [String: Any] {
        var object: [String: Any] = [
            "key": entry.spec.key,
            "value": entry.value,
            "source": entry.source.rawValue,
            "default": entry.spec.fallback,
            "summary": entry.spec.summary,
        ]
        if let name = entry.spec.environmentVariable { object["env"] = name }
        if let bounds = entry.spec.range {
            object["min"] = bounds.min
            object["max"] = bounds.max
        }
        return object
    }
}

// MARK: - fouine config list

struct ConfigList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Every setting, its effective value and where it comes from.")

    @Flag(name: .long, help: "JSON output.") var json = false

    func run() {
        CLI.guarded {
            let store = try CLI.openStoreReadOnly()
            let snapshot = SettingsSnapshot(rows: try store.settingsRows())
            let table = snapshot.table()

            if json {
                try CLI.printJSON(["settings": table.map(ConfigCommand.json)])
                return
            }
            for warning in snapshot.warnings { CLI.warn(warning) }
            for entry in table {
                print(ConfigCommand.describe(entry))
                print("      \(entry.spec.summary)")
                if let name = entry.spec.environmentVariable {
                    print("      default \(entry.spec.fallback.isEmpty ? "(empty)" : entry.spec.fallback)"
                          + " · variable \(name) (takes priority over this table)")
                }
            }
        }
    }
}

// MARK: - fouine config get

struct ConfigGet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get", abstract: "The effective value of one setting.")

    @Argument(help: "Setting key (see `fouine config list`).")
    var key: String

    @Flag(name: .long, help: "JSON output.") var json = false

    /// Une clé inconnue est une ERREUR D'USAGE, pas une panne : `ValidationError`
    /// sort en 64 et affiche l'usage, comme un argument manquant (§4.3).
    func validate() throws {
        guard SettingKeys.spec(for: key) != nil else {
            throw ValidationError(Settings.unknownKeyMessage(key))
        }
    }

    func run() {
        CLI.guarded {
            let store = try CLI.openStoreReadOnly()
            let snapshot = SettingsSnapshot(rows: try store.settingsRows())
            guard let spec = SettingKeys.spec(for: key) else { return }
            let effective = snapshot.effective(spec)
            let entry = (spec: spec, value: effective.value, source: effective.source)
            if json {
                try CLI.printJSON(ConfigCommand.json(entry))
            } else {
                // La valeur SEULE sur la sortie standard : `fouine config get`
                // doit être utilisable dans un script (`$(fouine config get
                // agent.pollSeconds)`). La provenance part sur l'erreur standard.
                print(effective.value)
                CLI.fail("       (\(effective.source.english))")
            }
        }
    }
}

// MARK: - fouine config set

struct ConfigSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Write a setting into the database.")

    @Argument(help: "Setting key (see `fouine config list`).")
    var key: String

    @Argument(help: "Value. For a list: items separated by commas.")
    var value: String

    func validate() throws {
        guard let spec = SettingKeys.spec(for: key) else {
            throw ValidationError(Settings.unknownKeyMessage(key))
        }
        do { _ = try spec.normalize(value) }
        catch { throw ValidationError(CLI.describe(error)) }
    }

    func run() {
        CLI.guarded {
            let store = try CLI.openStore()
            let settings = Settings(store: store)
            // REFUSÉ AVANT D'ÊTRE ÉCRIT (constat CM-11) : `roots.pinned 999`
            // s'écrivait et s'affichait « roots.pinned = 999 » pour un
            // identifiant qui ne désigne aucune racine — un réglage sans effet,
            // impossible à distinguer d'un réglage armé.
            try Self.refuseUnknownRoots(store: store, key: key, value: value)
            // Une langue d'OCR inconnue de Vision est refusée ICI (CM-24), pas
            // à la passe suivante — qui peut arriver des jours plus tard. Ce
            // qui est retenu est la forme CANONIQUE de la machine (« fr-fr »
            // tapé à la main devient « fr-FR »), comme à la passe.
            let effective = try Self.canonicalOCRLanguages(key: key, value: value)
                ?? value
            let written = try settings.set(key, effective)
            var line = "\(key) = \(written.isEmpty ? "(empty)" : written)"
            // « ocr.jobs = 4 » pour un 99 tapé ne dit pas POURQUOI (CM-24). Le
            // bornage reste la règle (`docs/cli.md` § config set) ; il cesse
            // d'être muet.
            if let clamp = Self.clampNote(key: key, asked: value, written: written) {
                line += " (\(clamp))"
            }
            print(line)

            // Deux avertissements qui valent mieux qu'un réglage sans effet.
            if let spec = SettingKeys.spec(for: key),
               let name = spec.environmentVariable,
               let override = ProcessInfo.processInfo.environment[name],
               !override.isEmpty {
                CLI.warn("the \(name) variable = “\(override)” still takes "
                         + "PRIORITY over this setting in this terminal; unset it "
                         + "to see the effect of the value you just wrote")
            }
            if key == SettingKeys.pinnedRoots.key {
                try PinnedRoots.repriorize(store: store,
                                           pinned: settings.snapshot().pinnedRoots)
            }
        }
    }

    // MARK: - Refus et bornage dits (constats CM-11, CM-24)

    /// `roots.pinned` confronté aux racines qui existent. Rien n'est écrit
    /// quand un identifiant ne désigne personne, et le message NOMME les
    /// racines (`id · étiquette`) : le public de Fouine ne connaît pas ses
    /// identifiants par cœur.
    ///
    /// Un index SANS racine ne fonde aucun refus (règle de `FolderCheck`).
    static func refuseUnknownRoots(store: GRDBStore, key: String,
                                   value: String) throws {
        guard key == SettingKeys.pinnedRoots.key else { return }
        let roots = try store.roots()
        guard !roots.isEmpty else { return }
        let known = Set(roots.map(\.id))
        let asked = SettingSpec.tokens(value).compactMap { Int64($0) }
        let unknown = asked.filter { !known.contains($0) }
        guard !unknown.isEmpty else { return }
        // Une INTERPOLATION, et non une chaîne de `+` : mesuré le 14/09/2026
        // (lot BT1), la forme concaténée coûtait 2,0 s de type-checking. Le
        // message est le même mot pour mot.
        let ids = unknown.map(String.init).joined(separator: ", ")
        let yours = roots.map { "\($0.id) · \($0.label)" }.joined(separator: ", ")
        throw UsageRefusal(message: """
            no root with id \(ids) — yours are: \(yours) (nothing was written)
            """)
    }

    /// `ocr.languages` confrontée à ce que Vision sait lire SUR CETTE MACHINE.
    /// Rend la forme canonique à écrire, ou `nil` pour toute autre clé.
    ///
    /// Le cœur écarte déjà les langues inconnues à la passe (`OCRRun`, audit
    /// X2) — mais des jours plus tard, dans un journal que personne n'ouvre :
    /// c'est tout le constat CM-24. La règle du cœur ne change pas, la CLI
    /// refuse plus tôt.
    ///
    /// `filterLanguages` rend une liste `rejected` vide quand la machine ne
    /// répond pas (`supportedLanguages()` vide) : on ne refuse alors rien,
    /// faute de pouvoir contredire.
    static func canonicalOCRLanguages(key: String, value: String) throws -> String? {
        guard key == SettingKeys.ocrLanguages.key else { return nil }
        let asked = SettingSpec.tokens(value)
        guard !asked.isEmpty else { return nil }
        let (kept, rejected) = VisionOCREngine.filterLanguages(asked)
        guard rejected.isEmpty else {
            // Même remarque qu'au-dessus : cette phrase concaténée était
            // l'expression la plus lente de toute la CLI — 5,9 s de
            // type-checking pour cinq morceaux (lot BT1). Texte inchangé.
            let unknown = rejected.joined(separator: ", ")
            let reads = VisionOCREngine.supportedLanguages().joined(separator: ", ")
            throw UsageRefusal(message: """
                OCR language(s) unknown to this Mac: \(unknown) — Vision reads: \
                \(reads) (nothing was written)
                """)
        }
        return kept.joined(separator: ",")
    }

    /// La phrase qui dit pourquoi la valeur retenue n'est pas celle qui a été
    /// tapée. `nil` quand elle l'est.
    static func clampNote(key: String, asked: String, written: String) -> String? {
        guard let spec = SettingKeys.spec(for: key), let bounds = spec.range,
              let value = Int(asked.trimmingCharacters(in: .whitespacesAndNewlines)),
              written != String(value) else { return nil }
        return "\(value) is outside \(bounds.min)–\(bounds.max)"
    }
}

/// Épingler une racine sans toucher la file serait un réglage auquel personne
/// ne croirait : 21 730 pages y attendent depuis des jours (mesuré sur la base
/// de l'auteur), et rien ne bougerait avant la prochaine extraction — c'est-à-
/// dire jamais, pour un corpus stable. La re-priorisation des pages DÉJÀ en
/// file se fait donc dans le même geste, à l'écriture COMME à l'effacement.
///
/// C'est le seul endroit du produit qui prenne `fouine.lock` pour un réglage,
/// et c'est normal : c'est un `UPDATE ocr_queue`, donc une écriture
/// d'indexation. Mesuré sur la base de production copiée : 21 730 pages
/// re-priorisées en 0,18 s, processus compris.
enum PinnedRoots {
    static func repriorize(store: GRDBStore, pinned: Set<Int64>) throws {
        var total = 0
        for root in try store.roots() {
            total += try OCRPriority.repriorize(
                store: store, rootID: root.id, pinned: pinned.contains(root.id))
        }
        if total > 0 {
            print("\(total) page(s) already queued were re-prioritised")
        }
    }
}

// MARK: - fouine config reset

struct ConfigReset: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Erase a setting: the value goes back to the default.")

    @Argument(help: "Setting key (see `fouine config list`).")
    var key: String

    func validate() throws {
        guard SettingKeys.spec(for: key) != nil else {
            throw ValidationError(Settings.unknownKeyMessage(key))
        }
    }

    func run() {
        CLI.guarded {
            let store = try CLI.openStore()
            let settings = Settings(store: store)
            try settings.reset(key)
            guard let spec = SettingKeys.spec(for: key) else { return }
            let snapshot = settings.snapshot()
            let effective = snapshot.effective(spec)
            print("\(key) erased — effective value: "
                  + (effective.value.isEmpty ? "(empty)" : effective.value)
                  + " [\(effective.source.english)]")
            // Effacer `roots.pinned` DÉPINGLE : la file doit suivre, exactement
            // comme à l'écriture. Sans cela, `reset` laisserait 21 730 pages en
            // priorité 0 pour un réglage qui n'existe plus.
            if key == SettingKeys.pinnedRoots.key {
                try PinnedRoots.repriorize(store: store,
                                           pinned: snapshot.pinnedRoots)
            }
        }
    }
}
