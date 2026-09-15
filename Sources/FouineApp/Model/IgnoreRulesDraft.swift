// IgnoreRulesDraft.swift — la logique de la feuille « Ce que Fouine ignore… »
// (lot IG2). Propriété : A-App. PURE : c'est la partie qui se teste, la vue ne
// fait qu'afficher.
//
// CE QUE LA FEUILLE PROMET. On exclut sans jamais taper de motif — un dossier
// choisi dans un panneau, un type de fichier choisi dans un menu, un nom tapé —,
// on lit chaque règle en clair (« Le dossier “Santé” », « Tous les fichiers
// .md »), et la conséquence est dite AVANT d'enregistrer. Les règles du fichier
// `.fouineignore` sont montrées aussi, sans croix : Fouine ne modifie pas ce
// fichier, et une règle qui exclut sans apparaître dans la feuille ferait
// chercher pendant des heures un document « disparu ».
//
// UN BROUILLON. Rien n'est écrit tant que « Enregistrer » n'est pas cliqué :
// ajouter puis retirer une règle ne doit rien coûter, ni réveiller l'agent.

import Foundation
import FouineCore
import FouineCrawl

struct IgnoreRulesDraft {

    /// Ce que la feuille lit une fois, à son ouverture.
    struct Snapshot {
        /// Les règles gardées, telles qu'elles se relisent de la base.
        let stored: IgnoreRuleSet
        /// Le fichier de la racine, `nil` s'il n'y en a pas.
        let file: IgnoreRules?
        /// Les documents de la racine, `nil` si on n'a pas pu les lire : la
        /// conséquence se dit alors sans nombre.
        let docs: [DocRow]?
    }

    /// Une ligne de la liste.
    struct Row: Identifiable, Equatable {
        /// Le rang compte dans l'identité : un fichier peut répéter une ligne,
        /// et deux lignes de même identité brouillent la liste SwiftUI.
        let id: String
        let rule: String
        let phrase: String
        /// Vient du fichier `.fouineignore` : grisée, et sans croix.
        let fromFile: Bool
    }

    /// Ce qu'a donné un geste d'ajout.
    enum Outcome: Equatable {
        case added
        /// Une règle gardée l'exclut déjà : rien à ajouter.
        case alreadySkipped
        /// Le fichier `.fouineignore` l'exclut déjà.
        case skippedByFile
        case refused(Refusal)
    }

    enum Refusal: Error, Equatable {
        /// Le dossier choisi n'est pas sous la racine.
        case outsideFolder
        /// Le dossier choisi EST la racine.
        case wholeFolder
        /// Le nom tapé porte un dossier ou plusieurs lignes.
        case notOneName
        /// Le nom commence par `!` ou `#`, que le format réserve.
        case reservedFirstCharacter
    }

    /// La phrase qui précède l'enregistrement.
    enum Consequence: Equatable {
        /// Environ N documents de l'index sortiront.
        case leaving(Int)
        /// Aucun document de l'index n'est concerné.
        case nothingLeaves
        /// Les documents n'ont pas pu être lus : « des documents ».
        case unknown
    }

    let rootLabel: String
    /// Chemin absolu de la racine, `nil` si le disque n'est pas branché : le
    /// sélecteur de dossier n'a alors nulle part où s'ouvrir.
    let rootPath: String?
    let rootRelPath: String
    private(set) var saved: IgnoreRuleSet
    private(set) var draft: IgnoreRuleSet
    let file: IgnoreRules?
    let docs: [DocRow]?

    init(rootLabel: String, rootPath: String?, rootRelPath: String,
         snapshot: Snapshot) {
        self.rootLabel = rootLabel
        self.rootPath = rootPath
        self.rootRelPath = rootRelPath
        self.saved = snapshot.stored
        self.draft = snapshot.stored
        self.file = snapshot.file
        self.docs = snapshot.docs
    }

    // MARK: - La liste

    /// Les règles gardées d'abord (on peut les retirer), puis celles du
    /// fichier. Une règle gardée qui répète le fichier est montrée deux fois :
    /// la retirer ne change rien tant que la ligne du fichier est là, et la
    /// feuille doit le laisser voir plutôt que le cacher.
    var rows: [Row] {
        draft.rules.enumerated().map { index, rule in
            Row(id: "kept-\(index)-\(rule)", rule: rule,
                phrase: Self.phrase(for: rule), fromFile: false)
        }
        + (file?.entries ?? []).enumerated().map { index, entry in
            Row(id: "file-\(index)-\(entry.rule)", rule: entry.rule,
                phrase: Self.phrase(for: entry.rule), fromFile: true)
        }
    }

    var hasChanges: Bool { draft != saved }

    /// Les règles ajoutées depuis l'ouverture (ou le dernier enregistrement).
    var added: [String] { draft.rules.filter { !saved.contains($0) } }
    /// Les règles retirées.
    var removed: [String] { saved.rules.filter { !draft.contains($0) } }

    // MARK: - Les trois gestes

    /// « Ignorer un dossier… » : le dossier choisi devient `Chemin/`.
    mutating func addFolder(at path: String) -> Outcome {
        guard let rootPath else { return .refused(.outsideFolder) }
        switch Self.folderRule(chosen: path, root: rootPath) {
        case .failure(let refusal): return .refused(refusal)
        case .success(let rule): return add(rule, probe: (String(rule.dropLast()), true))
        }
    }

    /// « Ignorer un type de fichier » : `*.ext`.
    mutating func addKindOfFile(_ ext: String) -> Outcome {
        let clean = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .lowercased()
        // Sans sonde : un nom d'essai (« x.pdf ») pourrait tomber sous une
        // règle de NOM sans rapport (« x.pdf » exclu), et la feuille dirait
        // « déjà ignoré » d'un type entier qui ne l'est pas.
        return add("*.\(clean)", probe: nil)
    }

    /// « Ignorer les fichiers nommés… » : le nom tapé, tel quel.
    mutating func addFileName(_ typed: String) -> Outcome {
        switch Self.fileNameRule(typed) {
        case .failure(let refusal): return .refused(refusal)
        case .success(let rule): return add(rule, probe: (rule, false))
        }
    }

    mutating func remove(_ rule: String) {
        draft.remove(rule)
    }

    /// Ajoute une règle déjà canonique, sauf si ce qu'elle désigne est déjà
    /// exclu. `probe` est un chemin que la règle désigne : c'est lui qu'on
    /// soumet aux règles existantes, parce que « déjà exclu » se juge sur ce
    /// qui est exclu, pas sur le texte — `Santé/2025/` sous `Santé/`, ou
    /// `INDEX.md` sous `*.md`, n'ajouteraient rien.
    private mutating func add(_ rule: String,
                              probe: (path: String, isDirectory: Bool)?) -> Outcome {
        if draft.contains(rule)
            || probe.map({ IgnoreRules(stored: draft).matches(relPath: $0.path,
                                                              isDirectory: $0.isDirectory) })
                == true {
            return .alreadySkipped
        }
        if let file,
           file.contains(rule: rule)
            || probe.map({ file.matches(relPath: $0.path, isDirectory: $0.isDirectory) })
                == true {
            return .skippedByFile
        }
        // `add` ne lève que sur une règle invalide, et les trois gestes n'en
        // fabriquent pas : un échec ici serait un défaut de ce fichier.
        guard (try? draft.add(rule)) == true else { return .alreadySkipped }
        return .added
    }

    /// Le dossier choisi, relatif à la racine, en règle `Chemin/`.
    ///
    /// Chemins CANONIQUES des deux côtés (`realpath`) : le panneau d'ouverture
    /// rend `/private/tmp/…` là où la racine a pu être enregistrée en `/tmp/…`,
    /// et une comparaison brute déclarerait « hors du dossier » un sous-dossier
    /// légitime.
    static func folderRule(chosen: String, root: String) -> Result<String, Refusal> {
        let base = canonical(root)
        let target = canonical(chosen)
        if target == base { return .failure(.wholeFolder) }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard target.hasPrefix(prefix) else { return .failure(.outsideFolder) }
        let relative = String(target.dropFirst(prefix.count))
        guard let rule = try? IgnoreRuleSet.canonical(relative + "/") else {
            return .failure(.outsideFolder)
        }
        return .success(rule)
    }

    /// Le nom tapé, validé : un nom, pas un chemin, sur une ligne.
    static func fileNameRule(_ typed: String) -> Result<String, Refusal> {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.contains("/") else { return .failure(.notOneName) }
        do {
            return .success(try IgnoreRuleSet.canonical(name))
        } catch IgnoreRuleError.negation, IgnoreRuleError.comment {
            return .failure(.reservedFirstCharacter)
        } catch {
            return .failure(.notOneName)
        }
    }

    private static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            return (path as NSString).standardizingPath
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Le menu des types de fichier

    /// Les extensions RÉELLEMENT présentes sous cette racine, les plus
    /// nombreuses d'abord, moins celles qu'une règle `*.ext` exclut déjà.
    /// Proposer « .pptx » dans un dossier qui n'en contient aucun ferait croire
    /// à un réglage global.
    var kindsOfFile: [(ext: String, count: Int)] {
        guard let docs else { return [] }
        var counts: [String: Int] = [:]
        for doc in docs {
            let ext = doc.record.ext.lowercased()
            guard !ext.isEmpty else { continue }
            counts[ext, default: 0] += 1
        }
        let union = self.union
        return counts
            .filter { !(union?.contains(rule: "*.\($0.key)") ?? false) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (ext: $0.key, count: $0.value) }
    }

    // MARK: - La conséquence

    /// Ce que le brouillon, uni au fichier, exclut.
    private var union: IgnoreRules? {
        let kept = IgnoreRules(stored: draft)
        return file.map { $0.merging(kept) } ?? (draft.isEmpty ? nil : kept)
    }

    /// `nil` tant que rien n'a été ajouté. Les documents qu'on compte sont
    /// ceux encore dans l'index que le brouillon exclut : ils sortiront à la
    /// prochaine mise à jour.
    var consequence: Consequence? {
        guard !added.isEmpty else { return nil }
        guard let docs else { return .unknown }
        let count = union?.countMatching(docs, rootRelPath: rootRelPath) ?? 0
        return count == 0 ? .nothingLeaves : .leaving(count)
    }

    /// Les phrases sous la liste, dans l'ordre où elles se lisent.
    var consequenceSentences: [String] {
        var sentences: [String] = []
        switch consequence {
        case .leaving(let count):
            sentences.append(String(localized: "About \(count) document(s) will leave the index at the next update. Your files are not touched."))
        case .nothingLeaves:
            sentences.append(String(localized: "No document in the index is affected. Your files are not touched."))
        case .unknown:
            sentences.append(String(localized: "Some documents may leave the index at the next update. Your files are not touched."))
        case nil:
            break
        }
        if !removed.isEmpty {
            sentences.append(String(localized: "What you no longer skip comes back at the next update."))
        }
        return sentences
    }

    /// Enregistré : le brouillon devient l'état de référence.
    mutating func markSaved() {
        saved = draft
    }

    // MARK: - Les phrases

    /// Une règle en clair, sans motif.
    static func phrase(for rule: String) -> String {
        switch IgnoreRuleSet.shape(of: rule) {
        case .folder(let components):
            return String(localized: "The folder “\(components.joined(separator: " › "))”")
        case .path(let components):
            return String(localized: "“\(components.joined(separator: " › "))” in this folder")
        case .fileExtension(let ext):
            return String(localized: "Every .\(ext) file")
        case .fileName(let name):
            return String(localized: "Files named “\(name)”")
        case .namePattern(let pattern):
            return String(localized: "Names like “\(pattern)”")
        }
    }

    func text(for outcome: Outcome) -> String? {
        switch outcome {
        case .added:
            return nil
        case .alreadySkipped:
            return String(localized: "Fouine already skips this.")
        case .skippedByFile:
            return String(localized: "The .fouineignore file in this folder already skips this.")
        case .refused(.outsideFolder):
            return String(localized: "Choose a folder inside “\(rootLabel)”.")
        case .refused(.wholeFolder):
            return String(localized: "That is the whole folder. To stop indexing it, untick it in the list.")
        case .refused(.notOneName):
            return String(localized: "Type one file name, without a folder: for example INDEX.md.")
        case .refused(.reservedFirstCharacter):
            return String(localized: "A name to skip cannot start with “!” or “#”.")
        }
    }

    /// « Mettre à jour maintenant » n'est proposé que si personne ne le fera :
    /// la mise à jour automatique relit les règles d'elle-même à son tic.
    static func offersUpdateNow(agentState: AgentOperationalState) -> Bool {
        switch agentState {
        case .active, .waitingFirstReport: return false
        default: return true
        }
    }

    static func savedText(automaticUpdates: Bool) -> String {
        automaticUpdates
            ? String(localized: "Saved. Fouine applies the change on its own within a few minutes.")
            : String(localized: "Saved. The change applies at the next update.")
    }
}
