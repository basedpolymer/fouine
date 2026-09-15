// CommandsRoot.swift — arborescence des commandes, `root` et `volume` (SPEC §4.3).
// Propriété : A-Core.

import Foundation
import ArgumentParser
import FouineCore
import FouineCrawl

struct FouineCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fouine",
        abstract: "Full-text search engine for macOS, with non-destructive OCR.",
        version: FouineVersion.string,
        subcommands: [RootCommand.self, VolumeCommand.self, CrawlCommand.self,
                      ExtractCommand.self, OCRCommand.self, IndexCommand.self,
                      EmbedCommand.self, ModelCommand.self, SearchCommand.self,
                      // AJOUT au §4.3 (lot BR1, constat PR-06) : PARCOURIR
                      // l'index. Rangé juste après `search`, dont il est le
                      // pendant — chercher un mot / voir ce qu'il y a.
                      ListCommand.self,
                      // AJOUT au §4.3 (lot MC3, constat PM-18) : LIRE une page
                      // trouvée, et voir ce qui lui ressemble. Rangés après
                      // `list` parce qu'ils prolongent le même geste —
                      // chercher, parcourir, puis lire. Le serveur MCP savait
                      // le faire depuis le palier 4 ; le terminal, non.
                      ReadCommand.self, SimilarCommand.self,
                      ConfigCommand.self, StatusCommand.self, DoctorCommand.self,
                      // Lot INT-F4 : les notes des applications (Apple Notes,
                      // Bear). AJOUT au §4.3, comme `licenses` et `mcp`.
                      SourcesCommand.self,
                      BackupCommand.self, MaintainCommand.self,
                      // AJOUT au contrat gelé du §4.3 (on ajoute, on ne renomme
                      // pas) : les notices des composants redistribués devaient
                      // être atteignables depuis le binaire (audit B1-10/B1-22).
                      LicensesCommand.self,
                      // AJOUT au §4.3 (lot L1C) : l'essai de 30 jours et la
                      // clé d'achat. Au SINGULIER, et juste à côté de
                      // `licenses` au pluriel — les deux résumés d'aide se
                      // distinguent en une ligne.
                      LicenseCommand.self,
                      // Palier 4 : le serveur MCP. Même règle — un AJOUT au
                      // §4.3, aucune sortie existante ne change (docs/mcp.md).
                      MCPCommand.self])
}

// MARK: - fouine root

struct RootCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "root",
        abstract: "Manage the indexed roots.",
        // `ignore` (lot IG2) : AJOUT au §4.3, après les trois d'origine.
        subcommands: [RootAdd.self, RootList.self, RootRemove.self,
                      RootIgnore.self],
        defaultSubcommand: RootList.self)
}

struct RootAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a root (resolves volume + rel_path, tests readability).")

    @Argument(help: "Absolute path of the folder to index.")
    var path: String

    @Option(name: .long, help: "Facet label (default: last path component).")
    var label: String?

    /// Un dossier interdit (le dossier personnel, `~/Library`, `/System`…) est
    /// une ERREUR D'USAGE, pas une panne : `ValidationError` sort en 64 et
    /// affiche l'usage de la commande, comme un argument manquant (§4.3).
    /// La même phrase est affichée par l'app dans son alerte (`RootPolicy`).
    func validate() throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if let refusal = RootPolicy.refusalReason(for: url) {
            throw ValidationError(refusal)
        }
    }

    func run() {
        CLI.guarded {
            let store = try CLI.openStore()
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if let notice = RootPolicy.warning(for: url) { CLI.warn(notice) }
            let id = try store.addRoot(path: url, label: label)
            let roots = try store.roots()
            guard let added = roots.first(where: { $0.id == id }) else { return }
            print("root \(id) “\(added.label)” added")
            print("  volume   \(added.volUUID)")
            print("  rel_path \(added.relPath)")
            // Le dossier porte DÉJÀ des exclusions (lot IG1) : il faut le dire
            // maintenant. Les découvrir à la première recherche qui ne trouve
            // pas un document qu'on sait être là coûte beaucoup plus cher
            // qu'une ligne ici.
            if let rules = IgnoreRules.loadFile(root: url), !rules.isEmpty {
                print("  \(IgnoreRules.fileName) found: \(rules.count) rule"
                      + (rules.count == 1 ? "" : "s")
                      + " — matching files stay out of the index")
            }
        }
    }
}

struct RootList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List the registered roots.")

    @Flag(name: .long, help: "JSON output.") var json = false

    func run() {
        CLI.guarded {
            let store = try CLI.openStoreReadOnly()
            let roots = try store.roots()
            if json {
                try CLI.printJSON(try roots.map {
                    try RootReport(root: $0).countingIgnoreRules(store: store).json
                })
                return
            }
            if roots.isEmpty { print("no root registered"); return }
            for root in roots {
                let r = try RootReport(root: root).countingIgnoreRules(store: store)
                print("[\(root.id)] \(root.label)  \(r.path)")
                print("      enabled=\(root.enabled ? "yes" : "no") "
                      + "mounted=\(r.mounted ? "yes" : "no") "
                      + "readable=\(r.readable ? "yes" : "no") "
                      + "ignore_rules=\(r.ignoreRules ?? 0)"
                      + (r.ignoreRuleSources.map { "  (\($0))" } ?? "")
                      + (r.reasonText.map { "  (\($0))" } ?? ""))
            }
        }
    }
}

struct RootRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a root. Without --purge, it is only disabled.")

    @Argument(help: "Identifier or label of the root.")
    var selector: String

    @Flag(name: .long, help: "Also purge the indexed documents and pages.")
    var purge = false

    func run() {
        CLI.guarded {
            let store = try CLI.openStore()
            let root = try CLI.resolveRoot(store, selector: selector)
            if purge {
                try store.removeRoot(id: root.id)
                print("root \(root.id) “\(root.label)” deleted (documents purged)")
            } else {
                try store.setRootEnabled(id: root.id, false)
                print("root \(root.id) “\(root.label)” disabled "
                      + "(index kept; --purge erases everything)")
            }
        }
    }
}

// MARK: - fouine root ignore (lot IG2)

/// Ce que Fouine ignore dans une racine, SANS écrire dans le dossier.
///
/// La même chose que la feuille « Ce que Fouine ignore… » des réglages de
/// l'app : les règles se gardent dans la base (`roots.ignore_rules`), le
/// fichier `.fouineignore` reste lu et n'est jamais modifié. Le crawl applique
/// l'union des deux.
struct RootIgnore: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ignore",
        abstract: "Show or change what Fouine skips in a root (kept by Fouine, "
            + "never written into the folder).",
        subcommands: [RootIgnoreList.self, RootIgnoreAdd.self, RootIgnoreRemove.self],
        defaultSubcommand: RootIgnoreList.self)
}

struct RootIgnoreList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the rules of a root, from its .fouineignore file and "
            + "from the settings.")

    @Argument(help: "Identifier or label of the root.")
    var selector: String

    @Flag(name: .long, help: "JSON output.") var json = false

    func run() {
        CLI.guarded {
            let store = try CLI.openStoreReadOnly()
            let root = try CLI.resolveRoot(store, selector: selector)
            let report = try IgnoreReport(root: root, store: store)
            report.warnAboutUnreadableRules()
            if json { try CLI.printJSON(report.json); return }
            report.printRules()
        }
    }
}

struct RootIgnoreAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Skip a folder, a kind of file or a file name in a root.",
        discussion: """
            A rule takes one of three forms: `Folder/` or `Folder/Sub/` (that \
            folder and everything in it, from the top of the root), `*.ext` \
            (every file of that kind), `name.ext` (every file of that name). \
            Quote patterns so the shell leaves them alone: '*.md'. The rule is \
            kept by Fouine: nothing is written into the folder, and documents \
            it matches leave the index at the next pass.
            """)

    @Argument(help: "Identifier or label of the root.")
    var selector: String

    @Argument(help: "The rule: Folder/, '*.ext' or name.ext.")
    var rule: String

    @Flag(name: .long, help: "JSON output.") var json = false

    /// Une règle invalide est une erreur d'USAGE (§4.3, sortie 64), refusée
    /// AVANT d'ouvrir la base : la syntaxe ne dépend pas de l'index, et la
    /// phrase nomme la règle.
    func validate() throws {
        do { _ = try IgnoreRuleSet.canonical(rule) }
        catch let error as IgnoreRuleError { throw ValidationError(error.message) }
    }

    func run() {
        CLI.guarded {
            let store = try CLI.openStore()
            let root = try CLI.resolveRoot(store, selector: selector)
            let before = try IgnoreReport(root: root, store: store)
            before.warnAboutUnreadableRules()
            var kept = before.stored
            let canonical = try IgnoreRuleSet.canonical(rule)
            // UNE RÈGLE, UN ENDROIT : ce que le fichier exclut déjà ne se garde
            // pas une seconde fois — sinon retirer la ligne du fichier ne
            // rendrait rien, sans que rien ne dise pourquoi.
            let inFile = before.file?.contains(rule: canonical) ?? false
            let changed = inFile ? false : try kept.add(canonical)
            if changed { try store.setIgnoreRulesJSON(rootID: root.id, kept.json) }
            let after = changed ? try IgnoreReport(root: root, store: store) : before
            if json {
                var out = after.json
                out["changed"] = changed
                try CLI.printJSON(out)
                return
            }
            if inFile {
                print("root \(root.id) “\(root.label)”: “\(canonical)” is already "
                      + "skipped by its \(IgnoreRules.fileName) file")
            } else if !changed {
                print("root \(root.id) “\(root.label)” already skips "
                      + "“\(kept.stored(canonical) ?? canonical)”")
            } else {
                print("root \(root.id) “\(root.label)” now skips “\(canonical)” "
                      + "(kept in the settings; nothing written into the folder)")
            }
            after.printConsequence()
        }
    }
}

struct RootIgnoreRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Stop skipping a rule kept in the settings of a root.")

    @Argument(help: "Identifier or label of the root.")
    var selector: String

    @Argument(help: "The rule, as `fouine root ignore list` shows it.")
    var rule: String

    @Flag(name: .long, help: "JSON output.") var json = false

    func validate() throws {
        do { _ = try IgnoreRuleSet.canonical(rule) }
        catch let error as IgnoreRuleError { throw ValidationError(error.message) }
    }

    func run() {
        CLI.guarded {
            let store = try CLI.openStore()
            let root = try CLI.resolveRoot(store, selector: selector)
            let before = try IgnoreReport(root: root, store: store)
            before.warnAboutUnreadableRules()
            var kept = before.stored
            let canonical = try IgnoreRuleSet.canonical(rule)
            guard kept.remove(canonical) else {
                // Deux refus distincts, et tous deux en 64 : la règle existe
                // mais n'est pas à nous (le fichier ne se modifie pas d'ici),
                // ou elle n'existe pas du tout.
                if before.file?.contains(rule: canonical) == true {
                    throw UsageRefusal(
                        message: "“\(canonical)” comes from the \(IgnoreRules.fileName) "
                        + "file in \(before.path) — Fouine never writes into your "
                        + "folders: edit that file to remove the line")
                }
                throw UsageRefusal(
                    message: "root “\(root.label)” does not skip “\(canonical)” — "
                    + "`fouine root ignore list \(root.id)` shows its rules")
            }
            try store.setIgnoreRulesJSON(rootID: root.id, kept.json)
            let after = try IgnoreReport(root: root, store: store)
            if json {
                var out = after.json
                out["changed"] = true
                try CLI.printJSON(out)
                return
            }
            print("root \(root.id) “\(root.label)” no longer skips “\(canonical)”: "
                  + "what it excluded comes back at the next pass")
        }
    }
}

/// Les règles d'une racine, leurs deux sources, et ce qu'elles retirent.
struct IgnoreReport {
    let root: RootRecord
    let path: String
    let mounted: Bool
    /// Le fichier, `nil` s'il n'y en a pas ou si le volume n'est pas monté.
    let file: IgnoreRules?
    /// Les règles gardées, telles qu'elles se relisent.
    let stored: IgnoreRuleSet
    let storedWarnings: [String]
    /// L'union, `nil` sans aucune règle.
    let rules: IgnoreRules?
    /// Documents ENCORE dans l'index que ces règles excluent : ils sortent à
    /// la passe suivante.
    let documentsMatching: Int

    init(root: RootRecord, store: GRDBStore) throws {
        self.root = root
        let url = CLI.absolutePath(of: root)
        self.path = url?.path ?? "/" + root.relPath
        self.mounted = url != nil
        let loaded = try Self.rules(of: root, store: store)
        self.file = url.flatMap { IgnoreRules.loadFile(root: $0) }
        self.stored = loaded.stored
        self.storedWarnings = loaded.warnings
        self.rules = loaded.rules
        self.documentsMatching = try loaded.rules.map {
            $0.countMatching(try store.docs(underRoot: root.id), rootRelPath: root.relPath)
        } ?? 0
    }

    /// Le fichier (s'il se lit) uni aux règles gardées — la lecture du crawl.
    static func rules(of root: RootRecord, store: GRDBStore) throws
        -> (rules: IgnoreRules?, stored: IgnoreRuleSet, warnings: [String]) {
        let decoded = IgnoreRuleSet.decode(try store.ignoreRulesJSON(rootID: root.id))
        let url = CLI.absolutePath(of: root)
        let rules = url.map { IgnoreRules.load(root: $0, stored: decoded.set) }
            ?? (decoded.set.isEmpty ? nil : IgnoreRules(stored: decoded.set))
        return (rules, decoded.set, decoded.warnings)
    }

    static func json(_ entry: IgnoreRules.Entry) -> [String: Any] {
        ["rule": entry.rule, "source": entry.source.rawValue]
    }

    var json: [String: Any] {
        [
            "id": root.id, "label": root.label, "path": path, "mounted": mounted,
            "rules": (rules?.entries ?? []).map(Self.json),
            "documents_matching": documentsMatching,
            "warnings": (rules?.warnings ?? []) + storedWarnings,
        ]
    }

    func warnAboutUnreadableRules() {
        for warning in (rules?.warnings ?? []) + storedWarnings { CLI.warn(warning) }
    }

    func printRules() {
        print("[\(root.id)] \(root.label)  \(path)")
        let entries = rules?.entries ?? []
        if entries.isEmpty {
            print("      no rule: Fouine skips nothing in this root")
        }
        let width = entries.map(\.rule.count).max() ?? 0
        for entry in entries {
            print("      " + entry.rule.padding(toLength: width, withPad: " ", startingAt: 0)
                  + "  " + entry.source.rawValue)
        }
        if !mounted {
            print("      (volume not mounted: its \(IgnoreRules.fileName) file cannot be read)")
        }
        printConsequence()
    }

    func printConsequence() {
        guard documentsMatching > 0 else { return }
        print("      \(documentsMatching) document\(documentsMatching == 1 ? "" : "s") "
              + "of the index match\(documentsMatching == 1 ? "es" : "") these rules and "
              + "leave it at the next pass (`fouine index`, or on its own when "
              + "automatic updates are on) — your files are not touched")
    }
}

// MARK: - fouine volume (annexe A)

struct VolumeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "volume",
        abstract: "Manage volumes (the external drive case, appendix A).",
        subcommands: [VolumeAdd.self, VolumeList.self],
        defaultSubcommand: VolumeList.self)
}

struct VolumeAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Register a mounted volume and its roots.")

    @Option(name: .long, help: "Path of a mount point.")
    var path: String

    @Option(name: .long, help: "Subfolders to index, separated by commas.")
    var roots: String?

    func run() {
        CLI.guarded {
            let store = try CLI.openStore()
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let resolved = try VolumeResolver.resolve(path: url)
            try store.registerVolume(uuid: resolved.volUUID, label: resolved.volLabel)
            print("volume \(resolved.volUUID) “\(resolved.volLabel)” registered")
            for name in (roots ?? "").split(separator: ",").map(String.init)
                where !name.trimmingCharacters(in: .whitespaces).isEmpty {
                let sub = url.appendingPathComponent(
                    name.trimmingCharacters(in: .whitespaces), isDirectory: true)
                let id = try store.addRoot(path: sub, label: nil)
                print("  root \(id): \(sub.path)")
            }
        }
    }
}

struct VolumeList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List the known volumes.")

    func run() {
        CLI.guarded {
            let store = try CLI.openStore()
            let known = try store.volumes()
            if known.isEmpty { print("no volume registered"); return }
            for v in known {
                let mount = VolumeResolver.mountPoint(forVolumeUUID: v.uuid)
                print("\(v.uuid)  \(v.label)  "
                      + (mount.map { "mounted on \($0.path)" } ?? "NOT MOUNTED"))
            }
        }
    }
}

// MARK: - Rapport de racine, partagé par root list / status / doctor

struct RootReport {
    let root: RootRecord
    let mounted: Bool
    let readable: Bool
    /// Le motif TYPÉ (palier 3.5) : c'est lui qui décide du geste TCC.
    let reason: RootProbe.Reason?
    let path: String
    /// Nombre de règles d'exclusion de cette racine — celles du `.fouineignore`
    /// (lot IG1) UNIES à celles gardées par Fouine (lot IG2), sans doublon —,
    /// `nil` quand l'appelant ne l'a pas demandé.
    ///
    /// HORS de l'initialiseur, et c'est délibéré : `status` et `doctor`
    /// construisent le même rapport et n'ont aucune raison d'ouvrir un fichier
    /// de plus par racine, ni de publier une clé qu'ils ne publiaient pas.
    /// Seul `root list` la renseigne — c'est la commande qui répond à « que
    /// contient l'index, et qu'en ai-je exclu ? ».
    var ignoreRules: Int?
    /// Les mêmes règles, une par une, avec leur source (`file` / `settings`).
    var ignoreEntries: [IgnoreRules.Entry] = []

    init(root: RootRecord) {
        self.root = root
        self.mounted = CLI.isMounted(root)
        let probe = CLI.readable(root)
        self.readable = probe.ok
        self.reason = probe.reason
        self.path = CLI.absolutePath(of: root)?.path ?? "/" + root.relPath
    }

    /// La phrase du motif. La clé `reason` du JSON reste une PHRASE et non un
    /// jeton : c'est ce que le contrat du §4.3 publie depuis toujours, seule sa
    /// langue change.
    var reasonText: String? { reason?.english }

    var json: [String: Any] {
        var out: [String: Any] = [
            "id": root.id, "label": root.label, "path": path,
            "enabled": root.enabled, "mounted": mounted, "readable": readable,
        ]
        if let reasonText { out["reason"] = reasonText }
        if let ignoreRules {
            out["ignore_rules"] = ignoreRules
            out["ignore_rule_list"] = ignoreEntries.map(IgnoreReport.json)
        }
        return out
    }

    /// « file 1, settings 2 » — `nil` sans règle : la ligne de `root list` ne
    /// s'allonge que quand il y a quelque chose à dire.
    var ignoreRuleSources: String? {
        guard !ignoreEntries.isEmpty else { return nil }
        return IgnoreRules.Source.allCases.compactMap { source in
            let n = ignoreEntries.filter { $0.source == source }.count
            return n == 0 ? nil : "\(source.rawValue) \(n)"
        }.joined(separator: ", ")
    }

    /// Les règles d'exclusion de cette racine : le fichier, lu sur le disque
    /// (lot IG1), et les règles gardées par Fouine, lues dans la base (lot
    /// IG2). Volume démonté ou racine illisible : le fichier ne compte pas —
    /// on ne peut pas le lire, et prétendre un nombre serait pire que de n'en
    /// annoncer aucun ; les règles gardées, elles, se lisent toujours.
    func countingIgnoreRules(store: GRDBStore) throws -> RootReport {
        var copy = self
        let rules = try IgnoreReport.rules(of: root, store: store).rules
        copy.ignoreRules = rules?.count ?? 0
        copy.ignoreEntries = rules?.entries ?? []
        return copy
    }
}
