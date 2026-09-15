// Support.swift — plomberie de la CLI : base, codes de sortie, sorties JSON.
// Propriété : A-Core. SPEC §4.3, §7.1, §10.

import Foundation
import ArgumentParser
import FouineCore
import FouineEmbed
import FouineIndex

enum CLI {

    // MARK: - Emplacement de la base (§10)

    /// `~/Library/Application Support/Fouine/fouine.db`, ou `FOUINE_DB`
    /// (chemin complet du fichier .db) — indispensable aux tests et à la recette.
    static func databaseURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["FOUINE_DB"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Fouine", isDirectory: true)
        return base.appendingPathComponent("fouine.db")
    }

    /// Aucune racine implicite (audit produit du 01/09, D1).
    ///
    /// La CLI enregistrait `~/Livres` et `~/Documents/Cours` sur toute base neuve
    /// — des dossiers d'exemple, sur la machine de n'importe qui. Un inconnu y
    /// gagnait au mieux rien, au pire une indexation surprise. Les racines
    /// s'ajoutent désormais par un geste explicite : `fouine root add <dossier>`
    /// ou « Ajouter un dossier… » dans l'app.
    static func openStore() throws -> GRDBStore {
        let store = GRDBStore()
        try store.open(at: databaseURL())
        store.setWriteLockWaitHandler { holder, timeout in
            let seconds = Int(timeout)
            CLI.warn("database is locked by \(holder.role.english) (pid \(holder.pid)) since \(holder.clockText) — waiting up to \(seconds)s...")
        }
        opened.add(store)
        return store
    }

    /// Ouverture en LECTURE SEULE d'une base qui doit DÉJÀ exister (audit
    /// A1m-09).
    ///
    /// `openStore()` appelle `GRDBStore.open(at:)`, qui CRÉE le schéma quand
    /// `meta` est absente. Toutes les commandes passaient par là, `search`,
    /// `status` et `doctor` compris : une faute de frappe dans `FOUINE_DB`, un
    /// `--db` erroné, un chemin sur un volume démonté, et la commande fabriquait
    /// un index vide — puis répondait « aucun résultat » indéfiniment, sur un
    /// index fantôme posé sur le disque, `fouine.lock` et `-wal` compris. Le
    /// serveur MCP, lui, refusait déjà : le bon comportement était connu et
    /// écrit, il n'était simplement pas appelé ici.
    ///
    /// La CRÉATION reste le geste explicite de `root add`, `index`, `crawl`,
    /// `extract`, `ocr`, `embed`, `config set`, `maintain` et de l'application.
    /// Le refus porte la phrase d'`openReadOnly` — celle qui nomme le geste —
    /// et sort en **3** (`FouineError.databaseFailure`, § 4.3 : « échec de
    /// base »), le même code que le serveur MCP rend déjà pour le même refus.
    ///
    /// Bénéfice second : une recherche cesse d'installer un `ExclusiveLock` et
    /// d'écrire le `-wal` au passage.
    static func openStoreReadOnly() throws -> GRDBStore {
        let store = GRDBStore()
        try store.openReadOnly(at: databaseURL())
        return store
    }

    /// Refuse tôt, avec la MÊME phrase, quand une commande a besoin d'écrire
    /// mais n'a rien à créer — `doctor --deep`, qui tient le verrou pour
    /// l'`integrity-check` FTS5. Sans cela, `doctor --deep` resterait le seul
    /// diagnostic capable de fabriquer l'index qu'il prétend diagnostiquer.
    static func openExistingStoreForWriting() throws -> GRDBStore {
        let url = databaseURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Une seule phrase de refus dans le produit : celle du cœur.
            throw FouineError.databaseFailure(
                GRDBStore.noIndexMessage(at: url.path))
        }
        return try openStore()
    }

    /// Les bases ouvertes par ce processus, pour rendre `fouine.lock` en sortant.
    ///
    /// Le noyau rend `flock()` à la mort du processus — c'est ce qui faisait dire
    /// à l'audit que « la CLI le rend à sa sortie » (V7) —, mais il ne connaît
    /// rien du NOM que le détenteur inscrit désormais dans le fichier (F3). Sans
    /// cette libération explicite, chaque commande qui écrit laisserait derrière
    /// elle un détenteur mort, et la commande SUIVANTE annoncerait une reprise
    /// de verrou périmé parfaitement banale : un avertissement qui crie au loup
    /// à chaque appel ne sert plus à rien le jour où il y a vraiment eu un
    /// plantage.
    private static let opened = OpenStores()

    private final class OpenStores: @unchecked Sendable {
        private let lock = NSLock()
        private var stores: [GRDBStore] = []

        func add(_ store: GRDBStore) {
            lock.lock(); stores.append(store); lock.unlock()
        }

        func releaseAll() {
            lock.lock()
            let all = stores
            stores.removeAll()
            lock.unlock()
            for store in all { store.releaseWriteLock() }
        }
    }

    /// Sortie des commandes qui n'ont rien à faire sans racine (`crawl`, `index`).
    /// Code 5, celui de toute racine manquante ou illisible (§4.3) : le message,
    /// lui, donne le geste au lieu de laisser croire à un index vide.
    static func dieNoRoots() -> Never {
        opened.releaseAll()
        fail("fouine: no root registered — add a folder to index with "
             + "`fouine root add <folder>`")
        fail("       database: \(databaseURL().path)")
        Foundation.exit(5)
    }

    // MARK: - Codes de sortie (§4.3)

    static func exitCode(for error: Error) -> Int32 {
        // Une requête refusée est une erreur d'USAGE, où qu'elle soit détectée :
        // `SearchCommand.validate()` en fait une `ValidationError` (donc 64),
        // mais le refus d'une étiquette de dossier inconnue exige la BASE et
        // n'est donc levé qu'à l'exécution (idée 5 de l'audit A1). Sans cette
        // ligne, la même faute sortirait en 64 ou en 1 selon le moment où on
        // s'en aperçoit.
        if error is QueryError { return 64 }
        // Même raison, même code : une valeur de filtre que la BASE contredit
        // est une faute de frappe, pas une panne (constat CM-11).
        if error is UsageRefusal { return 64 }
        guard let f = error as? FouineError else { return 1 }
        switch f {
        case .volumeNotMounted: return 2
        case .databaseFailure:  return 3
        case .budgetExhausted:  return 4
        case .rootUnreadable:   return 5
        default:                return 1
        }
    }

    /// Les phrases viennent d'`IndexText` (FouineIndex) : le §4.3 veut que
    /// l'utilisateur lise la MÊME phrase dans la CLI, l'app et l'agent, et trois
    /// copies d'un même `switch` avaient déjà commencé à diverger (l'app avait
    /// perdu le geste TCC). Depuis F3, le message d'un verrou occupé nomme son
    /// détenteur : « la base est en cours d'écriture par l'agent (pid 1234)
    /// depuis 10:32 ».
    static func describe(_ error: Error) -> String {
        // `FouineEmbedError` porte sa phrase dans `description` mais n'est pas
        // `LocalizedError` : `IndexText.describe` retombait donc sur
        // `NSError.localizedDescription` et `fouine embed` sans modèle affichait
        // « The operation couldn't be completed. (FouineEmbedError error 0.) »
        // au lieu du geste à faire. Rattrapé ici plutôt que dans FouineEmbed,
        // dont ce fichier-là est en cours de remaniement par ailleurs.
        if let embed = error as? FouineEmbedError { return embed.description }
        return IndexText.describe(error)
    }

    static func die(_ error: Error) -> Never {
        // `exit()` ne déroule aucun `defer` : la libération est explicite ici.
        opened.releaseAll()
        fail("fouine: " + describe(error))
        Foundation.exit(exitCode(for: error))
    }

    /// Enveloppe le corps d'une sous-commande : toute erreur devient un message
    /// lisible et le code de sortie du §4.3.
    static func guarded(_ body: () throws -> Void) {
        defer { opened.releaseAll() }
        do { try body() } catch { die(error) }
    }

    // MARK: - Sorties

    static func warn(_ message: String) { fail("fouine: warning — " + message) }

    static func fail(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func printJSON(_ object: Any) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    }

    // MARK: - Racines

    /// Chemin absolu d'une racine, ou `nil` si le volume n'est pas monté.
    static func absolutePath(of root: RootRecord) -> URL? {
        try? VolumeResolver.absolutePath(volUUID: root.volUUID, relPath: root.relPath)
    }

    static func isMounted(_ root: RootRecord) -> Bool {
        VolumeResolver.mountPoint(forVolumeUUID: root.volUUID) != nil
    }

    /// Lecture EFFECTIVE d'un fichier de la racine (jamais un simple `stat`).
    ///
    /// Le motif rendu est TYPÉ (`RootProbe.Reason`, palier 3.5) : c'est lui qui
    /// décide du geste TCC, et sa phrase anglaise qui part dans le texte comme
    /// dans la clé `reason` du JSON. Décider sur une phrase — ce que faisait
    /// `isPermissionDenial` avant — cessait de marcher le jour où la phrase
    /// changeait de langue.
    static func readable(_ root: RootRecord) -> (ok: Bool, reason: RootProbe.Reason?) {
        guard let url = absolutePath(of: root) else {
            return (false, .system("volume not mounted (UUID \(root.volUUID))"))
        }
        do { try RootProbe.probe(url); return (true, nil) }
        catch let FouineError.rootUnreadable(_, reason) {
            return (false, RootProbe.reason(reason) ?? .system(reason))
        }
        catch { return (false, .system(describe(error))) }
    }

    static func resolveRoot(_ store: GRDBStore, selector: String) throws -> RootRecord {
        let roots = try store.roots()
        if let id = Int64(selector), let match = roots.first(where: { $0.id == id }) {
            return match
        }
        if let match = roots.first(where: { $0.label == selector }) { return match }
        throw FouineError.rootUnreadable(
            path: selector,
            reason: RootProbe.Reason.system(
                "no root with that name or identifier").token)
    }
}

// MARK: - Refus d'une valeur que la base contredit (constat CM-11)

/// Une valeur d'option qui ne désigne rien dans CET index : `--lang xx`,
/// `--in 999999`, `roots.pinned 999`, `--only <chemin inconnu>`.
///
/// POURQUOI UN TYPE À PART. `ValidationError` d'ArgumentParser sort bien en 64,
/// mais elle ne se lève que dans `validate()`, avant toute ouverture de base :
/// or nommer les valeurs réelles EXIGE la base. C'est le même raisonnement que
/// `QueryError.unknownFolder` (idée 5 de l'audit A1), qui a sa ligne dans
/// `CLI.exitCode`. Sans ce type, la même faute sortirait en 64 ou en 1 selon
/// l'endroit où on s'en aperçoit.
///
/// LA RÈGLE, celle de `FolderCheck` : ON NE REFUSE QUE CE QU'ON PEUT
/// CONTREDIRE. Une liste vide — index neuf, langues jamais détectées, aucune
/// racine — ne fonde aucun refus.
struct UsageRefusal: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    /// La phrase du serveur MCP, sans son préfixe d'outil : c'est le même
    /// modèle de refus des deux côtés (`SearchTool.unknownLanguageMessage`),
    /// et deux formulations pour la même faute coûteraient un essai de plus à
    /// qui les lit.
    static func unknownLanguage(_ asked: String, known: [String]) -> UsageRefusal {
        UsageRefusal(message: "unknown language “\(asked)” — languages in this "
                     + "index: " + known.joined(separator: ", "))
    }

    static func unknownDocuments(_ unknown: [Int64]) -> UsageRefusal {
        let list = unknown.map(String.init).joined(separator: ", ")
        return UsageRefusal(
            message: "unknown document id\(unknown.count > 1 ? "s" : "") \(list)"
            + " — `fouine search … --json` gives doc_id")
    }
}

// MARK: - Une requête qui commence par un tiret (lot MN1)

/// La ligne de plus à mettre sous le refus d'ArgumentParser quand la commande
/// refusée portait une REQUÊTE prise pour une option.
///
/// `fouine search -type:pdf réacteur` sort en 64 sur « Unknown option
/// '-type:pdf' » : le tiret de tête appartient à la grammaire de Fouine
/// (exclusions et exclusions de filtres), pas à celle des options, et
/// ArgumentParser lit les arguments avant que Fouine ne voie la chaîne. Le
/// message est juste ; il ne dit pas le geste, qui est `--`.
///
/// FONCTION PURE : elle ne lit que les arguments du processus, et le point
/// d'entrée ne l'appelle que sur une sortie 64.
enum DashedQueryHint {

    /// `nil` = rien à ajouter, et le message d'ArgumentParser part tel quel.
    ///
    /// LA FORME RECONNUE est celle d'un FILTRE : un tiret, deux lettres ou
    /// plus, un deux-points, une valeur. C'est ce qui distingue `-type:pdf` et
    /// `-ext:md` d'une option mal tapée (`-limit`), dont la bonne réponse est
    /// le message d'usage et non une requête entre guillemets. Ni une heure
    /// (`-10:30`, des chiffres), ni une adresse (`-http://…`, la valeur
    /// commence par une barre) n'y entrent : mêmes exclusions que
    /// `QueryParser.unknownPrefix`, dont c'est la règle.
    static func line(arguments: [String]) -> String? {
        // APRÈS UN `--`, IL N'Y A PLUS D'OPTION : la requête est déjà écrite
        // comme il faut, et la faute est ailleurs (un préfixe inconnu, par
        // exemple, que l'analyseur refuse avec sa propre phrase). Proposer `--`
        // à qui vient de l'écrire serait la pire ligne d'aide possible.
        let typed = arguments.prefix { $0 != "--" }
        guard let first = typed.firstIndex(where: looksLikeFilter) else { return nil }
        // La sous-commande est le premier mot nu (`search`, `similar`) ; la
        // requête commence au jeton fautif, et les options longues qui la
        // suivent n'en font pas partie — elles se replacent AVANT le `--`.
        let subcommand = typed.dropFirst().first { !$0.hasPrefix("-") } ?? "search"
        let query = typed[first...]
            .filter { !$0.hasPrefix("--") }
            .joined(separator: " ")
        return "fouine: hint — a query that starts with “-” is read as an "
            + "option; put it after “--” (options before it): "
            + "fouine \(subcommand) -- '\(query)'"
    }

    private static func looksLikeFilter(_ argument: String) -> Bool {
        guard argument.hasPrefix("-"), !argument.hasPrefix("--") else { return false }
        let bare = argument.dropFirst()
        guard let colon = bare.firstIndex(of: ":") else { return false }
        let head = bare[bare.startIndex..<colon]
        guard head.count >= 2, head.allSatisfy({ $0.isLetter }) else { return false }
        let value = bare[bare.index(after: colon)...]
        return !value.isEmpty && !value.hasPrefix("/")
    }
}

// MARK: - Silence de l'agent (constat CM-12)

/// Depuis combien de temps l'agent d'arrière-plan n'a rien fait, en clair.
///
/// POURQUOI. Le README dit « en cas de doute, `fouine doctor` — c'est le
/// premier geste, toujours ». Sur une production dont l'agent était arrêté
/// depuis 3 j 10 h, `doctor` répondait « background agent : not registered »
/// et `ok: true` : la ligne dit ce que launchd sait, jamais ce que la BASE
/// sait. `fouine status`, lui, le disait — deux commandes, deux réponses à la
/// même question.
///
/// FONCTION PURE, testée par la recette : elle ne lit ni la base ni launchd,
/// elle reçoit ce que les deux ont répondu.
enum AgentIdle {

    /// En deçà, le silence ne veut rien dire : l'agent scrute toutes les 60 s
    /// et peut dormir avec la machine. Une heure est le premier seuil au-delà
    /// duquel « il ne s'est rien passé » est une information.
    static let threshold: TimeInterval = 3600

    struct Report {
        let lastRun: Date
        let idleSeconds: Int
        /// « 3 d 10 h ».
        let duration: String
        /// ISO 8601 dans le fuseau de la machine : c'est une date que
        /// l'utilisateur doit reconnaître dans son propre calendrier.
        let iso: String
        /// La phrase complète, geste compris.
        let text: String
        let guidance: String
    }

    /// Le libellé RÉEL de l'interrupteur, dans la langue de la CLI — l'ANGLAIS.
    ///
    /// La consigne demandait le nom français (« Mettre l'index à jour
    /// automatiquement ») ; `doctor` imprime déjà le nom anglais dans ses deux
    /// autres branches de remédiation (`LaunchdAgentProbe.remediationGuidance`,
    /// « spawn failed » et « registered but silent »). Deux noms pour un seul
    /// interrupteur dans la même sortie coûteraient plus cher que la
    /// traduction : c'est précisément ce que CM-03 vient de réparer.
    static let guidance =
        "turn “Keep the index up to date automatically” back on in Fouine.app"

    /// `nil` quand il n'y a rien à dire : aucun rapport d'agent sur cette base,
    /// un agent qui TOURNE, ou un silence de moins d'une heure.
    ///
    /// - Parameter running: l'agent est enregistré ET vivant (launchd le dit
    ///   `running`). Un service non enregistré, ou enregistré mais silencieux,
    ///   vaut `false`.
    static func describe(status: AgentStatusRecord?, running: Bool,
                         now: Date = Date()) -> Report? {
        guard !running, let status, let updated = status.updatedAt else { return nil }
        let idle = now.timeIntervalSince(updated)
        guard idle >= threshold else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        let iso = formatter.string(from: updated)
        let duration = describeDuration(idle)
        return Report(
            lastRun: updated, idleSeconds: Int(idle), duration: duration,
            iso: iso,
            text: "has not run since \(iso) (\(duration)) — \(guidance)",
            guidance: guidance)
    }

    /// « 3 d 10 h », « 5 h 12 min », « 75 min ». Deux unités au plus : au-delà,
    /// on lit un nombre au lieu d'une durée.
    static func describeDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(minutes) min" }
        return "\(minutes) min"
    }

    /// La dernière ligne non vide du journal de l'agent, ou `nil` s'il n'y a
    /// pas de journal. C'est le SEUL endroit où un incident se voit (racine
    /// illisible, OCR en échec), et `doctor` ne le lisait pas.
    ///
    /// On lit la QUEUE du fichier (8 Kio) : le journal d'une campagne pèse
    /// plusieurs mégaoctets, et `doctor` doit rester instantané.
    static func lastLogLine(at url: URL, tailBytes: Int = 8_192) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let start = UInt64(max(0, Int64(size) - Int64(tailBytes)))
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).last
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - Énumérations d'options (§4.3)

enum FuzzyModeArg: String, ExpressibleByArgument, CaseIterable {
    case off, auto, on
    var value: FuzzyMode {
        switch self {
        case .off: return .off
        case .auto: return .auto
        case .on: return .on
        }
    }
}

enum FuzzyScopeArg: String, ExpressibleByArgument, CaseIterable {
    case ocr, all
    var value: FuzzyScope { self == .ocr ? .ocrOnly : .all }
}

/// `--mark` (lot CL2) : ce qui entoure les mots trouvés dans un extrait.
///
/// LES MÊMES QUATRE VALEURS QUE `marks` CÔTÉ SERVEUR MCP, et pour la même
/// raison : un corpus français écrit ses citations entre guillemets, et le
/// surlignage par défaut est fait des mêmes caractères — on ne distingue alors
/// plus ce que Fouine a trouvé de ce que l'auteur citait. Le défaut ne bouge
/// pas : les extraits de `--json` sont un contrat gelé (§4.3).
enum MarkArg: String, ExpressibleByArgument, CaseIterable {
    case guillemets, brackets, asterisks, none

    var value: (open: String, close: String) {
        switch self {
        case .guillemets: return ("«", "»")
        case .brackets:   return ("[", "]")
        case .asterisks:  return ("**", "**")
        case .none:       return ("", "")
        }
    }
}

/// `--source` (lot P3) : UNE valeur, pas une liste répétable. Il n'y a que
/// deux provenances du point de vue de qui cherche — le texte que le document
/// portait déjà, et celui que Fouine a lu sur l'image — et les demander toutes
/// les deux, c'est ne pas filtrer.
/// Les TROIS provenances d'une page, et elles partitionnent l'énumération :
/// `native` (le document portait le texte), `ocr` (lu sur l'image), `transcript`
/// (la parole d'un média mise par écrit, lot INT-F3).
enum SourceArg: String, ExpressibleByArgument, CaseIterable {
    case native, ocr, transcript
    var value: Set<PageSource> {
        switch self {
        case .native:     return PageSource.typed
        case .ocr:        return PageSource.scanned
        case .transcript: return PageSource.transcribed
        }
    }
}

enum FacetArg: String, ExpressibleByArgument, CaseIterable {
    /// `doc_year` EN PREMIER : c'est l'année que le DOCUMENT porte
    /// (`docs.doc_date`, schéma v9), et c'est celle qu'un humain veut. L'autre
    /// est celle de la dernière modification du FICHIER — un livre de 2003
    /// copié sur le Mac en 2024 y tombe en 2024, et son nom le dit maintenant
    /// (lot MC3, constat PM-25).
    case docYear = "doc_year"
    case modifiedYear = "modified_year"
    case folder, ext, source, lang

    var value: FacetKey {
        switch self {
        case .folder: return .folder
        case .ext: return .ext
        case .modifiedYear: return .year
        case .source: return .source
        case .lang: return .lang
        case .docYear: return .docYear
        }
    }

    /// `year` reste ACCEPTÉ, sans être annoncé : le §4.3 gèle les sorties, et
    /// un script écrit avant ce lot ne doit pas tomber en 64. Il n'apparaît ni
    /// dans `--help` ni dans la doc — la clé rendue, elle, est toujours
    /// `modified_year`, pour qu'il n'y ait qu'un nom à lire.
    init?(argument: String) {
        let normalised = argument == "year" ? "modified_year" : argument
        guard let value = FacetArg(rawValue: normalised) else { return nil }
        self = value
    }
}

enum CrawlModeArg: String, ExpressibleByArgument, CaseIterable {
    case full, delta
    var value: CrawlMode { self == .full ? .full : .delta }
}
