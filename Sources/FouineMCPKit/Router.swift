// Router.swift — le routeur BI-ÉPOQUE, et la boucle de service.
// SPDX-License-Identifier: MIT
//
// POURQUOI DEUX ÉPOQUES. La révision 2026-07-28 retire `initialize`,
// `notifications/initialized` et `ping`, ajoute `server/discover`, et fait
// porter la version de protocole par chaque requête dans
// `params._meta["io.modelcontextprotocol/protocolVersion"]`. Mais **aucun des
// deux clients cibles ne la parle par défaut aujourd'hui** : Claude Code ne
// négocie 2026-07-28 que si `MCP_PROTOCOL_NEGOTIATION=auto` est posé, et rien
// ne documente que Claude Desktop le fasse. Un serveur qui n'implémenterait que
// la révision courante ne fonctionnerait avec personne ; un serveur qui
// n'implémenterait que l'ancienne serait à réécrire dans six mois.
//
// La spec autorise explicitement la sortie : « A dual-era server MAY serve both
// eras concurrently on the same endpoint or process. »
//
// COMMENT ON TRANCHE. Sur la PREMIÈRE requête, et une seule fois :
//   · `initialize`                                    → époque legacy ;
//   · `server/discover`, ou un `_meta` moderne         → époque moderne.
//   · autre chose (un client qui attaque directement par `tools/list`)
//     → legacy, qui est le régime conservateur : il rend les mêmes charges
//       utiles sans les champs de la révision nouvelle.
//
// Le choix est MÉMORISÉ pour la connexion. Ce n'est pas un état de session au
// sens que la révision 2026-07-28 récuse — le protocole moderne reste sans
// état, chaque requête y reportant sa version : c'est seulement le régime de
// RÉPONSE, et une requête moderne qui arriverait après un `initialize` legacy
// est servie en moderne parce qu'elle porte son `_meta` (voir `era(for:)`).

import Foundation

public final class Router {

    /// Ce que le routeur peut refuser avant même de connaître la méthode.
    private enum Decision {
        case reply([String: Any])
        case silent
    }

    private let registry: ToolRegistry
    private let serverInfo: ResultEnvelope.ServerInfo
    private let instructions: String?
    private let log: StderrLog

    /// Veto d'avant-appel. Rend un message d'erreur MÉTIER (rendu en
    /// `isError: true`) ou `nil` pour laisser passer. C'est par là que le
    /// serveur refuse un `tools/call` sur une base dont le schéma a changé
    /// pendant qu'il tournait, sans cesser de répondre à `initialize`.
    public var toolPreflight: ((String) -> String?)?

    /// L'époque retenue à la première requête. `nil` = pas encore décidée.
    private var settledEra: ProtocolEra?

    public init(registry: ToolRegistry,
                serverInfo: ResultEnvelope.ServerInfo,
                instructions: String? = nil,
                log: StderrLog = StderrLog(level: .quiet)) {
        self.registry = registry
        self.serverInfo = serverInfo
        self.instructions = instructions
        self.log = log
    }

    /// L'époque décidée jusqu'ici — pour les tests et le journal `debug`.
    public var currentEra: ProtocolEra? { settledEra }

    // MARK: - Boucle de service

    /// Lit, traite, écrit, jusqu'à l'EOF. Rend quand l'entrée est fermée :
    /// « Servers SHOULD exit promptly when their standard input is closed. »
    public func serve(on transport: LineTransport) {
        loop: while true {
            switch transport.nextLine() {
            case .endOfInput:
                log.note(.info, ["stdin-closed", "-", "-", "0"])
                break loop
            case .oversized(let bytes):
                let response = JSONRPCResponse.failure(
                    id: nil,
                    error: .parse("message of \(bytes) bytes exceeds the line limit"))
                transport.write(JSONRPCResponse.encode(response))
            case .data(let line):
                if let response = handle(line) { transport.write(response) }
            }
        }
    }

    // MARK: - Une ligne

    /// Rend la réponse à écrire, ou `nil` s'il n'y en a pas (notification, ou
    /// ligne blanche). C'est le point d'entrée que rejouent les transcriptions.
    public func handle(_ line: Data) -> Data? {
        let started = Date()
        switch JSONRPCParser.parse(line) {
        case .blank:
            return nil
        case .malformed(let id, let error):
            let response = JSONRPCResponse.encode(
                JSONRPCResponse.failure(id: id, error: error))
            log.request(method: "?", tool: nil,
                        durationMS: Date().timeIntervalSince(started) * 1000,
                        resultBytes: response.count)
            return response
        case .request(let request):
            let outcome = dispatch(request)
            guard case .reply(let message) = outcome else {
                log.note(.debug, ["notification", request.method, "0", "0"])
                return nil
            }
            let response = JSONRPCResponse.encode(message)
            log.request(method: request.method,
                        tool: request.params["name"] as? String,
                        durationMS: Date().timeIntervalSince(started) * 1000,
                        resultBytes: response.count)
            return response
        }
    }

    // MARK: - Époque

    /// L'époque d'UNE requête. Une requête qui porte un `_meta` moderne est
    /// servie en moderne, quoi qu'ait décidé la première : le protocole moderne
    /// est sans état, et c'est le seul cas où l'on peut le savoir avec
    /// certitude.
    private func era(for request: JSONRPCRequest) -> ProtocolEra {
        if request.meta[ResultEnvelope.protocolVersionMetaKey] is String { return .modern }
        if request.method == "server/discover" { return .modern }
        if let settled = settledEra { return settled }
        return .legacy(version: ResultEnvelope.preferredLegacyVersion)
    }

    private func settle(_ era: ProtocolEra, method: String) {
        guard settledEra == nil else { return }
        settledEra = era
        switch era {
        case .legacy(let version):
            log.note(.debug, ["era-legacy", method, version, "0"])
        case .modern:
            log.note(.debug, ["era-modern", method, ResultEnvelope.modernVersion, "0"])
        }
    }

    /// Contrôle de version de l'époque moderne. `nil` = tout va bien.
    ///
    /// En 2026-07-28, `_meta` n'est pas décoratif : `RequestParams` l'exige, et
    /// `protocolVersion` avec lui — c'est ce qui remplace la poignée de main
    /// retirée. Une requête moderne qui l'omet est donc malformée, et le dire
    /// vaut mieux que de deviner : c'est `-32602`, pas un service silencieux
    /// dans une version qu'on aurait choisie à la place du client.
    private func versionRefusal(_ request: JSONRPCRequest) -> [String: Any]? {
        guard let asked = request.meta[ResultEnvelope.protocolVersionMetaKey] as? String
        else {
            return JSONRPCResponse.failure(
                id: request.id,
                error: .invalidParams(
                    "this connection is in the \(ResultEnvelope.modernVersion) era "
                    + "(it opened with server/discover): every request must carry "
                    + "params._meta[\"\(ResultEnvelope.protocolVersionMetaKey)\"]"))
        }
        guard asked != ResultEnvelope.modernVersion else { return nil }
        // Une révision LEGACY annoncée dans un `_meta` moderne est une
        // contradiction du client : on la refuse comme la spec le demande, en
        // disant ce qu'on sert.
        return JSONRPCResponse.failure(
            id: request.id,
            raw: unsupportedProtocolVersion(
                asked,
                supported: [ResultEnvelope.modernVersion,
                            ResultEnvelope.preferredLegacyVersion]))
    }

    // MARK: - Aiguillage

    private func dispatch(_ request: JSONRPCRequest) -> Decision {
        // Les notifications sont ignorées AVANT tout le reste : la spec interdit
        // d'y répondre, y compris par une erreur. `notifications/cancelled` en
        // fait partie — ce serveur traite une requête à la fois et n'a rien à
        // annuler.
        if request.isNotification { return .silent }

        let era = era(for: request)
        settle(era, method: request.method)

        if case .modern = era, request.method != "server/discover",
           let refusal = versionRefusal(request) {
            return .reply(refusal)
        }

        switch request.method {
        case "initialize":
            guard case .legacy = era else {
                return .reply(JSONRPCResponse.failure(
                    id: request.id,
                    error: .methodNotFound(
                        "initialize",
                        reason: "initialize was removed in \(ResultEnvelope.modernVersion)"
                            + " — use server/discover")))
            }
            let asked = (request.params["protocolVersion"] as? String) ?? ""
            let served = ResultEnvelope.legacyVersions.contains(asked)
                ? asked : ResultEnvelope.preferredLegacyVersion
            settledEra = .legacy(version: served)
            return .reply(JSONRPCResponse.success(
                id: request.id,
                result: ResultEnvelope.initialize(version: served,
                                                  serverInfo: serverInfo,
                                                  instructions: instructions)))

        case "server/discover":
            return .reply(JSONRPCResponse.success(
                id: request.id,
                result: ResultEnvelope.discover(serverInfo: serverInfo,
                                                instructions: instructions)))

        case "ping":
            // Retiré par la révision 2026-07-28 ; toujours là en legacy, où
            // certains clients s'en servent comme battement de cœur.
            guard case .legacy = era else {
                return .reply(JSONRPCResponse.failure(
                    id: request.id,
                    error: .methodNotFound(
                        "ping",
                        reason: "ping was removed in \(ResultEnvelope.modernVersion)")))
            }
            return .reply(JSONRPCResponse.success(id: request.id, result: [:]))

        case "tools/list":
            return .reply(JSONRPCResponse.success(
                id: request.id,
                result: ResultEnvelope.listTools(registry.descriptors(), era: era,
                                                 serverInfo: serverInfo)))

        case "tools/call":
            return .reply(callTool(request, era: era))

        case "resources/list":
            return .reply(JSONRPCResponse.success(
                id: request.id,
                result: ResultEnvelope.listResources(era: era, serverInfo: serverInfo)))

        case "prompts/list":
            return .reply(JSONRPCResponse.success(
                id: request.id,
                result: ResultEnvelope.listPrompts(era: era, serverInfo: serverInfo)))

        default:
            return .reply(JSONRPCResponse.failure(
                id: request.id, error: .methodNotFound(request.method)))
        }
    }

    private func callTool(_ request: JSONRPCRequest, era: ProtocolEra) -> [String: Any] {
        guard let name = request.params["name"] as? String, !name.isEmpty else {
            return JSONRPCResponse.failure(
                id: request.id,
                error: .invalidParams("tools/call requires a tool name"))
        }
        let raw = request.params["arguments"]
        if raw != nil, !(raw is NSNull), !(raw is [String: Any]) {
            return JSONRPCResponse.failure(
                id: request.id,
                error: .invalidParams("tools/call arguments must be an object"))
        }
        let arguments = raw as? [String: Any] ?? [:]

        // Le veto d'avant-appel rend une erreur d'OUTIL, jamais une erreur
        // JSON-RPC : le client garde une session utilisable et le modèle lit
        // une phrase qui lui dit quoi faire.
        if let refusal = toolPreflight?(name) {
            return JSONRPCResponse.success(
                id: request.id,
                result: ResultEnvelope.callTool(.failure(refusal), era: era,
                                                serverInfo: serverInfo))
        }
        do {
            let result = try registry.call(name: name, arguments: arguments)
            return JSONRPCResponse.success(
                id: request.id,
                result: ResultEnvelope.callTool(result, era: era, serverInfo: serverInfo))
        } catch let error as JSONRPCError {
            return JSONRPCResponse.failure(id: request.id, error: error)
        } catch {
            return JSONRPCResponse.failure(
                id: request.id, error: .internalError(String(describing: error)))
        }
    }
}
