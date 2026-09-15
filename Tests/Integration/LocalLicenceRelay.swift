// LocalLicenceRelay.swift — un relais de licence de poche, pour la recette (LC2).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// `fouine license activate|deactivate|status` parlent au relais : jusqu'à LC2,
// la recette ne pouvait donc exercer que `status` sur un fichier sans clé, et
// la ligne de commande — qui n'a pas d'autre test que cette recette — laissait
// ses trois appels sans preuve. `FOUINE_LICENSE_RELAY` accepte
// `http://127.0.0.1:<port>` : ce relais y écoute, répond par action le corps
// qu'on lui donne (les réponses réelles de Creem du 14/09/2026), et retient ce
// qu'il a reçu. Aucune connexion ne quitte la machine.
//
// HTTP/1.1 minimal, une requête par connexion : le client envoie un POST de
// quelques dizaines d'octets et `Connection: close` suffit. Ce n'est pas un
// serveur, c'est un double.

import Foundation
import Network

final class LocalLicenceRelay: @unchecked Sendable {

    struct Answer {
        let status: Int
        let body: String
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fouine.recette.licence-relay")
    private let lock = NSLock()
    private let answers: [String: Answer]
    private var received: [[String: Any]] = []

    /// L'adresse à passer dans `FOUINE_LICENSE_RELAY`.
    private(set) var url: URL!

    /// - Parameter answers: par action (`activate`, `validate`, `deactivate`),
    ///   le code et le corps rendus. Une action absente rend 500.
    init(answers: [String: Answer]) throws {
        self.answers = answers
        let parameters = NWParameters.tcp
        // Sur l'adresse de bouclage SEULEMENT : rien n'écoute sur le réseau.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success,
              let port = listener.port?.rawValue, port > 0 else {
            listener.cancel()
            throw RecetteRefus(description: "le relais local n'a pas pu écouter sur 127.0.0.1")
        }
        url = URL(string: "http://127.0.0.1:\(port)/api/fouine/license")!
    }

    deinit { listener.cancel() }

    /// Ferme l'écoute : l'adresse ne répond plus (« hors ligne »).
    func stop() {
        listener.cancel()
    }

    /// Les corps JSON reçus, dans l'ordre.
    var requests: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    // MARK: - Une connexion

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let body = Self.completeBody(buffer) {
                return self.respond(on: connection, to: body)
            }
            if isComplete || error != nil { return connection.cancel() }
            self.receive(on: connection, buffer: buffer)
        }
    }

    /// Le corps, une fois les en-têtes ET `Content-Length` octets arrivés.
    private static func completeBody(_ buffer: Data) -> Data? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        let length = head.components(separatedBy: "\r\n").lazy.compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
            else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let body = buffer[end.upperBound...]
        return body.count >= length ? Data(body.prefix(length)) : nil
    }

    private func respond(on connection: NWConnection, to body: Data) {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        lock.lock()
        received.append(json)
        lock.unlock()
        let answer = answers[json["action"] as? String ?? ""]
            ?? Answer(status: 500, body: #"{ "error": "no answer for this action" }"#)
        let payload = Data(answer.body.utf8)
        let head = "HTTP/1.1 \(answer.status) Relay\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(payload.count)\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
