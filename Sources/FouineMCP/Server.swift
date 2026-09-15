// Server.swift — assemblage, cycle de vie, et le contrôle de schéma à chaud.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// Ce fichier ne contient AUCUNE logique de protocole : tout cela est dans
// `FouineMCPKit`, qui ne connaît pas Fouine. Ici on branche une base en lecture
// seule sur un registre d'outils, et on tient trois promesses de cycle de vie.
//
//  1. **Sortie sur EOF.** « Servers SHOULD exit promptly when their standard
//     input is closed. » La boucle du routeur rend sur EOF ; `run()` rend ;
//     la commande sort en 0. Pas de délai, pas de processus orphelin dans la
//     liste de l'utilisateur.
//
//  2. **Sortie sur SIGTERM/SIGINT.** C'est ainsi qu'un client MCP arrête un
//     serveur qu'il a lancé. Le traitement par défaut ferait déjà l'affaire,
//     mais il ne laisserait pas une ligne dans le journal — et « le serveur
//     s'est arrêté sans rien dire » est précisément la panne qu'on ne sait pas
//     diagnostiquer six mois plus tard.
//
//  3. **Contrôle de schéma à chaque `tools/call`**, depuis une valeur en cache
//     60 s. Le serveur vit des heures ; l'utilisateur peut mettre Fouine à jour
//     pendant ce temps, et l'application migrera la base sous lui. Rendre alors
//     des chiffres tirés d'un schéma qu'on ne comprend plus serait la pire
//     panne possible — silencieuse et fausse. On refuse par un
//     `isError: true` qui porte le geste, et `initialize` / `tools/list`
//     continuent de répondre : le client reste utilisable, et l'utilisateur
//     lit pourquoi.
//
//  4. **Ouverture PARESSEUSE de l'index** (CM-07). Le même raisonnement, pour
//     l'état de la base au DÉMARRAGE : base absente, schéma plus récent,
//     fichier qui n'est pas une base, journal d'écriture à reprendre. Ouvrir
//     dans `init` faisait sortir le processus avant la première réponse, et
//     le client n'affichait que « serveur déconnecté ». Ce constructeur ne
//     lève donc plus rien ; le refus passe par le même `isError` que le
//     point 3, et l'ouverture est réessayée tant qu'elle échoue.

import Foundation
import FouineCore
import FouineMCPKit

/// Traduction des erreurs de FouineCore en une phrase ANGLAISE pour un client
/// MCP. `IndexText` (FouineIndex) fait ce travail pour la CLI, l'app et
/// l'agent, mais `FouineMCP` ne dépend pas de FouineIndex — et n'a pas à en
/// dépendre pour trois cas.
public enum MCPText {
    public static func describe(_ error: Error) -> String {
        if let busy = WriteLock.busy(error), let holder = busy.holder {
            return "the index is being written by \(holder.role.english) "
                + "(pid \(holder.pid)) — retry in a few seconds"
        }
        switch error as? FouineError {
        case .databaseFailure(let message)?: return message
        case .volumeNotMounted(let uuid)?:
            return "the volume \(uuid) is not mounted — results from it are missing"
        case .rootUnreadable(let path, let reason)?:
            return "cannot read \(path): \(reason)"
        default: return (error as NSError).localizedDescription
        }
    }
}

public final class MCPServer {

    public struct Options {
        public var databaseURL: URL
        public var logLevel: LogLevel
        /// Durée de vie de la version de schéma en cache. 60 s en production ;
        /// les tests la mettent à zéro pour vérifier la bascule sans attendre.
        public var schemaCacheTTL: TimeInterval
        /// Les racines servies (`--folders`), ou `nil` pour tout l'index.
        /// Ce qui est hors de cette liste n'existe pas pour ce serveur : ni
        /// dans `roots`, ni dans une recherche, ni sous son `doc_id` (lot IG1).
        public var folders: [String]?

        public init(databaseURL: URL, logLevel: LogLevel = .info,
                    schemaCacheTTL: TimeInterval = 60,
                    folders: [String]? = nil) {
            self.databaseURL = databaseURL
            self.logLevel = logLevel
            self.schemaCacheTTL = schemaCacheTTL
            self.folders = folders
        }
    }

    /// Ce que le serveur annonce comme identité.
    public static func serverInfo(version: String) -> ResultEnvelope.ServerInfo {
        ResultEnvelope.ServerInfo(name: "fouine", title: "Fouine", version: version)
    }

    /// Le mot d'accueil qu'un client peut montrer au modèle. Court, et il dit la
    /// seule chose qu'un agent doit savoir avant d'appeler : c'est un index
    /// local, en lecture seule.
    public static let instructions =
        "Fouine is a local full-text index of the user's own documents. "
        + "This server is read-only: it never writes to the index, never starts "
        + "an indexing pass, and never returns the original files — only the text "
        + "Fouine extracted or OCRed. Nothing leaves the machine."

    private let options: Options
    private let log: StderrLog
    private let store: ReadOnlyStore
    private let router: Router
    private let statusTool: StatusTool
    private let semantic: SemanticEngine

    private let schemaMutex = NSLock()
    private var schemaCache: (version: Int?, at: Date)?

    /// - Parameter makeStatusTool: point d'injection des TESTS, et d'eux seuls.
    ///   Une transcription « golden » ne peut dépendre ni de `launchctl` ni de
    ///   la présence d'un modèle de 220 Mo sur la machine qui la rejoue.
    public init(options: Options, version: String,
                makeSemanticEngine: (ReadOnlyStore) -> SemanticEngine = {
                    SemanticEngine(store: $0)
                },
                makeStatusTool: (ReadOnlyStore, SemanticEngine) -> StatusTool = {
                    StatusTool(store: $0, semantic: $1)
                }) {
        self.options = options
        self.log = StderrLog(level: options.logLevel)
        // NE LÈVE PLUS (CM-07). L'ouverture est PARESSEUSE : elle se fait à la
        // première lecture, et son échec devient un `isError` d'outil au lieu
        // d'un processus qui meurt avant d'avoir répondu à `initialize`.
        let store = ReadOnlyStore(path: options.databaseURL,
                                  retryInterval: options.schemaCacheTTL,
                                  folders: options.folders)
        self.store = store
        let semantic = makeSemanticEngine(store)
        self.semantic = semantic
        self.statusTool = makeStatusTool(store, semantic)
        // L'ORDRE EST CELUI DE `tools/list`, et il est celui du parcours qu'un
        // agent doit faire : savoir ce qu'il y a (status), chercher, lire,
        // rebondir de proche en proche, et lister quand il ne trouve rien.
        self.router = Router(
            registry: ToolRegistry([
                statusTool,
                SearchTool(store: store, semantic: semantic),
                ReadPageTool(store: store),
                SimilarPagesTool(store: store, semantic: semantic),
                ListDocumentsTool(store: store),
            ]),
            serverInfo: Self.serverInfo(version: version),
            instructions: Self.instructions,
            log: log)
        router.toolPreflight = { [weak self] _ in
            // Le périmètre EN DERNIER : une base illisible ou d'un autre schéma
            // se dit d'abord, sans quoi « unknown folder “Livres” » serait la
            // seule phrase qu'on lise d'un index qu'on n'a même pas pu ouvrir.
            self?.openRefusal() ?? self?.schemaRefusal() ?? self?.store.scopeRefusal()
        }
    }

    /// Le journal de démarrage : version, base, schéma. Une ligne, sur stderr.
    /// C'est ce qu'on demandera à l'utilisateur de coller quand « le serveur
    /// n'apparaît pas ».
    ///
    /// C'est aussi la PREMIÈRE tentative d'ouverture. Elle peut échouer sans
    /// conséquence pour le service : la ligne dit alors `schema=?` et la cause,
    /// le serveur continue de répondre, et l'ouverture est réessayée au premier
    /// appel d'outil.
    public func logStartup(version: String) {
        var fields = ["start", "fouine/\(version)", options.databaseURL.path]
        if let folders = options.folders, !folders.isEmpty {
            fields.append("folders=" + folders.joined(separator: ","))
        }
        if let refusal = openRefusal() {
            fields.append("schema=?")
            fields.append(refusal)
        } else {
            let schema = ((try? store.schemaVersion()) ?? nil).map(String.init) ?? "?"
            fields.append("schema=v" + schema)
        }
        log.note(.info, fields)
    }

    /// Boucle jusqu'à l'EOF de l'entrée. Rend quand le client a fermé.
    public func run(transport: LineTransport) {
        installSignalHandlers()
        router.serve(on: transport)
        log.note(.info, ["stop", "-", "-", "0"])
    }

    /// Une ligne, une réponse — sans transport. C'est par là que passent les
    /// transcriptions « golden ».
    public func handle(_ line: Data) -> Data? { router.handle(line) }

    // MARK: - Ouverture et contrôle de schéma

    /// `nil` = la base est ouverte. Sinon, la phrase de l'ouverture — avec son
    /// geste : « no Fouine index at … », « update the fouine binary », « run
    /// `fouine maintain` once ». C'est elle que le modèle lit dans l'`isError`,
    /// et la seule que l'utilisateur puisse suivre.
    ///
    /// Une nouvelle tentative a lieu à chaque appel d'outil, au plus une fois
    /// par `schemaCacheTTL` (`ReadOnlyStore.opened()`) : une base créée ou
    /// réparée pendant que le serveur tourne est servie sans le relancer.
    private func openRefusal() -> String? {
        do {
            try store.ensureOpen()
            return nil
        } catch {
            return MCPText.describe(error)
        }
    }

    /// `nil` = la base est bien à la version que ce binaire comprend.
    private func schemaRefusal() -> String? {
        schemaMutex.lock()
        let fresh = schemaCache.map { Date().timeIntervalSince($0.at) < options.schemaCacheTTL }
            ?? false
        var version = schemaCache?.version
        schemaMutex.unlock()

        if !fresh {
            version = (try? store.schemaVersion()) ?? nil
            schemaMutex.lock()
            schemaCache = (version, Date())
            schemaMutex.unlock()
        }
        guard let version else {
            return "this database is no longer a readable Fouine index "
                + "(no schema_version in meta)"
        }
        guard version != Schema.version else { return nil }
        return GRDBStore.schemaMismatch(found: version)
    }

    // MARK: - Signaux

    private static let signalSources = SignalBox()

    private func installSignalHandlers() {
        signal(SIGPIPE, SIG_IGN)
        let log = self.log
        for number in [SIGTERM, SIGINT] {
            // Le traitement par défaut doit être désarmé AVANT d'installer la
            // source : sans cela le processus meurt avant que GCD ne voie quoi
            // que ce soit.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number,
                                                         queue: .global(qos: .userInitiated))
            source.setEventHandler {
                log.note(.info, ["signal", number == SIGTERM ? "SIGTERM" : "SIGINT",
                                 "-", "0"])
                exit(0)
            }
            source.resume()
            Self.signalSources.keep(source)
        }
    }

    /// Les sources GCD doivent survivre à la portée qui les crée, sans quoi
    /// elles sont annulées à la sortie de la fonction et le signal reprend son
    /// traitement… qu'on vient justement de désarmer (le processus deviendrait
    /// insensible à `SIGTERM`).
    private final class SignalBox: @unchecked Sendable {
        private let mutex = NSLock()
        private var sources: [DispatchSourceSignal] = []
        func keep(_ source: DispatchSourceSignal) {
            mutex.lock(); sources.append(source); mutex.unlock()
        }
    }
}
