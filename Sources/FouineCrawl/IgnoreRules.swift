// IgnoreRules.swift — le fichier `.fouineignore` d'une racine (lot IG1, PM-01).
// Propriété : A-Ingest.
//
// POURQUOI UN FICHIER, ET PAS UN RÉGLAGE. `CrawlExclusions` est la liste des
// NUISANCES — caches, `.git`, `~/Library` : elle est la même pour tout le monde
// et personne n'a à la connaître. Ce qu'un utilisateur veut tenir hors de
// l'index, lui, n'appartient qu'à lui (« Santé », « Comptes_et_Codes », les
// notes que Fouine a lui-même fabriquées) et vit DANS son dossier : il le voit
// à côté de ses fichiers, il le sauvegarde avec eux, il le déplace avec eux, et
// aucune base de données ne peut en perdre le contenu. C'est aussi la seule
// forme qui survive à un `root remove` suivi d'un `root add`.
//
// ET AUSSI UN RÉGLAGE, DEPUIS LE LOT IG2 (14/09/2026). Le fichier demandait un
// terminal. L'app ne l'écrit pas pour autant : elle n'écrit dans aucun dossier
// de l'utilisateur. Les règles saisies dans « Ce que Fouine ignore… » sont
// gardées par Fouine (`IgnoreRuleSet`, `roots.ignore_rules`), et
// `load(root:stored:)` rend l'UNION des deux sources, compilées par le même
// code. Le fichier reste la voie des dossiers partagés, et de qui veut que
// l'exclusion voyage avec le dossier.
//
// UNE SEULE RÈGLE PAR RACINE, à sa racine, jamais plus bas. Un `.gitignore` par
// sous-dossier se lit à quatre endroits et se déduit mal ; ici on répond à la
// question « qu'est-ce qui est exclu de ce dossier ? » en ouvrant UN fichier.
//
// TROIS FORMES, ET PAS PLUS. La quatrième — la négation `!` de gitignore —
// est refusée : elle n'a de sens qu'avec un ordre d'évaluation et des règles
// imbriquées, c'est-à-dire exactement ce qu'on ne veut pas avoir à expliquer.
// Une ligne `!` est ignorée AVEC un avertissement : la refuser en silence
// laisserait croire qu'un dossier est réindexé alors qu'il ne l'est pas.
//
// CASSE ET ACCENTS IGNORÉS. APFS compare les noms sans la casse par défaut, et
// `Santé` tapé dans un terminal peut arriver décomposé (`Sante´`) là où le
// Finder l'écrit précomposé. Une règle qui manquerait sa cible pour un accent
// décomposé n'excluerait rien et ne dirait rien — la panne la plus coûteuse de
// tout ce fichier. Le repli (`folding`) traite les deux d'un coup.

import Foundation
import FouineCore

/// Les exclusions que l'utilisateur a écrites pour UNE racine.
public struct IgnoreRules: Sendable, Equatable {

    /// Le nom du fichier, à la racine du dossier suivi. Caché (point initial) :
    /// `.skipsHiddenFiles` le tient donc hors de l'index de lui-même.
    public static let fileName = ".fouineignore"

    /// D'où vient une règle (lot IG2). Le nom de la source est celui que
    /// `fouine root list --json` publie.
    public enum Source: String, Sendable, Equatable, CaseIterable {
        /// Le fichier `.fouineignore`, écrit par l'utilisateur dans son dossier.
        case file
        /// Les règles gardées par Fouine (`roots.ignore_rules`), saisies dans
        /// les réglages de l'app ou par `fouine root ignore add`.
        case settings
    }

    /// Une règle telle qu'on la MONTRE : son texte, sans `/` initial, et sa
    /// source. `entries[i]` est la règle compilée `rules[i]`.
    public struct Entry: Sendable, Equatable {
        public let rule: String
        public let source: Source
        public init(rule: String, source: Source) {
            self.rule = rule
            self.source = source
        }
    }

    /// Une règle compilée. Trois formes, dans l'ordre où on les explique.
    enum Rule: Equatable {
        /// Chemin RELATIF À LA RACINE, replié. `directoryOnly` = la ligne
        /// portait le `/` final : elle ne désigne qu'un dossier et son contenu.
        case path(String, directoryOnly: Bool)
        /// Motif `fnmatch` sur le seul NOM, replié : `*.md`, `INDEX.md`,
        /// `*brouillon*`. S'applique partout sous la racine.
        case name(String)
    }

    let rules: [Rule]

    /// Les règles retenues, dans l'ordre : celles du fichier d'abord, puis
    /// celles des réglages qui ne le répètent pas.
    public let entries: [Entry]

    /// Ce qui n'a pas pu être lu, en anglais, pour le journal (jamais pour
    /// l'app : ces phrases s'adressent à qui dépanne).
    public let warnings: [String]

    /// Nombre de règles RETENUES. C'est ce que `fouine root list` affiche : une
    /// ligne refusée ne compte pas, sans quoi le compte promettrait une
    /// exclusion qui n'a pas lieu.
    public var count: Int { rules.count }
    public var isEmpty: Bool { rules.isEmpty }

    // MARK: - Lecture

    public init(text: String) {
        var rules: [Rule] = []
        var entries: [Entry] = []
        var warnings: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            // Le `\r` d'un fichier écrit sous Windows ou collé depuis un
            // courriel : il ferait d'« INDEX.md » un motif qui ne correspond à
            // rien, sans un mot.
            while line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("!") {
                warnings.append(
                    "\(Self.fileName): “\(line)” ignored — negation (!) is not "
                    + "supported; remove the line or the rule it cancels")
                continue
            }
            // Un `/` initial est TOLÉRÉ et retiré : tout chemin est déjà
            // relatif à la racine, et `/Santé/` est ce qu'on écrit
            // spontanément en pensant « à la racine ».
            while line.hasPrefix("/") { line.removeFirst() }
            guard let rule = Self.compile(line) else { continue }
            rules.append(rule)
            entries.append(Entry(rule: RelPath.normalized(line), source: .file))
        }
        self.rules = rules
        self.entries = entries
        self.warnings = warnings
    }

    /// Les règles gardées par Fouine (lot IG2), déjà validées à la saisie.
    public init(stored: IgnoreRuleSet) {
        var rules: [Rule] = []
        var entries: [Entry] = []
        for text in stored.rules {
            guard let rule = Self.compile(text), !rules.contains(rule) else { continue }
            rules.append(rule)
            entries.append(Entry(rule: text, source: .settings))
        }
        self.rules = rules
        self.entries = entries
        self.warnings = []
    }

    init(rules: [Rule], entries: [Entry] = [], warnings: [String] = []) {
        self.rules = rules
        self.entries = entries
        self.warnings = warnings
    }

    /// Une ligne DÉJÀ débarrassée de ses espaces, de son `#`, de son `!` et de
    /// ses `/` initiaux. `nil` : il ne reste rien à compiler.
    ///
    /// UN SEUL COMPILATEUR pour les deux sources : une règle gardée par l'app
    /// et la même ligne écrite dans le fichier doivent exclure exactement les
    /// mêmes documents, et deux copies de ce code finiraient par diverger.
    static func compile(_ line: String) -> Rule? {
        guard !line.isEmpty else { return nil }
        if line.contains("/") {
            let directoryOnly = line.hasSuffix("/")
            var path = line
            while path.hasSuffix("/") { path.removeLast() }
            guard !path.isEmpty else { return nil }
            return .path(Self.fold(path), directoryOnly: directoryOnly)
        }
        return .name(Self.fold(line))
    }

    /// L'UNION de deux jeux de règles : les miennes, puis celles de `other`
    /// qui n'en répètent aucune. Deux règles sont la même quand elles se
    /// compilent pareil — `Santé/` du fichier et `sante/` des réglages
    /// n'excluent qu'une fois, et ne se comptent qu'une fois.
    public func merging(_ other: IgnoreRules) -> IgnoreRules {
        var rules = self.rules
        var entries = self.entries
        for (index, rule) in other.rules.enumerated() where !rules.contains(rule) {
            rules.append(rule)
            if other.entries.indices.contains(index) {
                entries.append(other.entries[index])
            }
        }
        return IgnoreRules(rules: rules, entries: entries,
                           warnings: warnings + other.warnings)
    }

    /// Les règles d'une source seulement, dans l'ordre.
    public func entries(from source: Source) -> [Entry] {
        entries.filter { $0.source == source }
    }

    /// Ce jeu porte-t-il déjà cette règle, écrite sous une forme ou une autre
    /// (`/Santé/`, `sante/`) ? C'est ce qui permet de dire « le fichier
    /// l'exclut déjà » au lieu de garder deux fois la même règle.
    public func contains(rule text: String) -> Bool {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while line.hasPrefix("/") { line.removeFirst() }
        guard let rule = Self.compile(line) else { return false }
        return rules.contains(rule)
    }

    /// Les règles d'une racine : son fichier `.fouineignore` UNI aux règles
    /// gardées par Fouine (lot IG2). `nil` s'il n'y a ni fichier ni règle
    /// gardée — c'est ce qui dit à `root add` qu'aucun fichier n'a été trouvé.
    ///
    /// Même sémantique, même priorité : un document exclu par l'une OU l'autre
    /// source est exclu. Il n'y a pas d'ordre entre elles à expliquer, puisque
    /// la négation n'existe dans aucune des deux.
    public static func load(root: URL,
                            stored: IgnoreRuleSet = IgnoreRuleSet()) -> IgnoreRules? {
        let file = loadFile(root: root)
        guard !stored.isEmpty else { return file }
        let kept = IgnoreRules(stored: stored)
        return file.map { $0.merging(kept) } ?? kept
    }

    /// Le fichier seul, ou `nil` s'il n'y en a pas.
    ///
    /// On OUVRE ce fichier même si le reste du crawl s'interdit d'ouvrir un
    /// fichier non résident (`FileResidency`) : il pèse quelques centaines
    /// d'octets, et le sauter ferait indexer ce que l'utilisateur a
    /// explicitement exclu — le pire des deux maux.
    public static func loadFile(root: URL) -> IgnoreRules? {
        let url = root.appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else {
            return IgnoreRules(rules: [], warnings: [
                "\(fileName): not valid UTF-8 text — no rule applied",
            ])
        }
        return IgnoreRules(text: text)
    }

    // MARK: - LA décision, PURE

    /// Ce chemin — relatif à LA RACINE, séparé par des `/`, sans `/` initial —
    /// est-il exclu ?
    ///
    /// Les descendants d'un chemin exclu le sont aussi, alors que le crawler
    /// appelle déjà `skipDescendants()` : la redondance est délibérée. La sonde
    /// `firstFile` et FSEvents ne descendent pas dans le même ordre, et une
    /// règle qui ne tiendrait qu'avec un appelant discipliné finirait par
    /// laisser passer un document.
    public func matches(relPath: String, isDirectory: Bool) -> Bool {
        guard !rules.isEmpty else { return false }
        var path = relPath
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { return false }
        let folded = Self.fold(path)
        let name = Self.fold((path as NSString).lastPathComponent)
        for rule in rules {
            switch rule {
            case .path(let wanted, let directoryOnly):
                if folded == wanted { if !directoryOnly || isDirectory { return true } }
                if folded.hasPrefix(wanted + "/") { return true }
            case .name(let pattern):
                if fnmatch(pattern, name, 0) == 0 { return true }
            }
        }
        return false
    }

    /// Combien de ces documents une passe retirerait de l'index (lot IG2) :
    /// la conséquence dite AVANT d'enregistrer une règle, dans l'app comme
    /// dans `fouine root ignore add`.
    ///
    /// `docs` sont ceux de la racine (`docs(underRoot:)`) ; leur `rel_path` est
    /// relatif au VOLUME, on en retire celui de la racine pour retrouver le
    /// chemin que les règles nomment. Un paquet-document (`.pages`, `.rtfd`)
    /// est un DOSSIER pour le crawl : il est compté comme tel, sans quoi
    /// `Rapport.pages/` ne le compterait pas.
    ///
    /// Approché, et dit « environ » : un document dont l'extension n'est plus
    /// allumée reste en place au crawl (constat C2-04) mais est compté ici.
    public func countMatching(_ docs: [DocRow], rootRelPath: String) -> Int {
        guard !rules.isEmpty else { return 0 }
        let root = RelPath.normalized(rootRelPath)
        let prefix = root.isEmpty ? "" : root + "/"
        var count = 0
        for doc in docs {
            // Pas de normalisation par document : `docs.rel_path` est déjà en
            // NFC (A3-10), et `hasPrefix` de Swift compare par équivalence
            // canonique. `matches` replie le reste.
            let path = doc.record.relPath
            guard prefix.isEmpty || path.hasPrefix(prefix) else { continue }
            let sub = String(path.dropFirst(prefix.count))
            let ext = doc.record.ext.lowercased()
            if matches(relPath: sub,
                       isDirectory: CrawlExclusions.documentPackageExtensions.contains(ext)) {
                count += 1
            }
        }
        return count
    }

    // MARK: - Repli

    /// Casse et accents ramenés à rien, forme Unicode unifiée au passage
    /// (`folding` décompose puis retire les diacritiques : « é » et « e´ »
    /// arrivent tous deux sur « e »). `locale: nil` et non `.current` : une
    /// règle ne doit pas s'appliquer différemment selon la langue du système.
    static func fold(_ s: String) -> String {
        RelPath.normalized(s).folding(options: [.caseInsensitive, .diacriticInsensitive],
                                      locale: nil)
    }
}
