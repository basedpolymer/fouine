// ModelTransferTests.swift — le TRANSFERT du modèle : redirections et plafond.
// Propriété : A-Embed, cible de test uniquement. Audit A1-03, A1-04, D2-08.
//
// AUCUN RÉSEAU. `URLProtocol` fictif branché sur la session : rien ne sort de
// la machine, et le protocole JOURNALISE chaque requête qu'on lui demande de
// servir — c'est ce journal qui permet d'affirmer qu'une requête `http:` n'a
// PAS été émise, et pas seulement qu'elle a échoué.
//
// Ce que ces tests empêchent de revenir :
//   · A1-03 / D2-08 — une redirection `https:` → `http:` était suivie sans
//     contrôle (reproduit via httpbin) : 220 Mo d'un modèle qui va tourner sur
//     la machine passaient en clair. Ce qui manquait n'était pas un plafond de
//     sauts (URLSession les borne déjà à 20) mais un contrôle de SCHÉMA ;
//   · A1-04 — aucun plafond en vol : 419 Mo écrits avant refus, et le contrôle
//     entièrement désarmé dès que `FOUINE_MODEL_SHA256` était posé.

import Foundation
import XCTest
import CryptoKit
@testable import FouineEmbed

// MARK: - Le serveur fictif

/// Ce que le protocole doit répondre. Posé avant chaque test, lu par toutes
/// les instances (URLSession en fabrique une par requête).
enum StubResponse: @unchecked Sendable {
    /// 302 vers `location`, sans corps.
    case redirect(to: String)
    /// 200 SANS `Content-Length`, `total` octets envoyés par tranches.
    case chunked(total: Int, chunk: Int)
    /// 200 AVEC un `Content-Length` annoncé, et un corps de `body` octets.
    case announced(length: Int64, body: Int)
}

/// Journal partagé : ce que le protocole a été prié de servir, dans l'ordre.
final class StubLog: @unchecked Sendable {
    private let mutex = NSLock()
    private var urls: [URL] = []
    private var plan: [String: StubResponse] = [:]

    func reset() { mutex.lock(); urls = []; plan = [:]; mutex.unlock() }

    func answer(_ url: String, with response: StubResponse) {
        mutex.lock(); plan[url] = response; mutex.unlock()
    }

    func record(_ url: URL) { mutex.lock(); urls.append(url); mutex.unlock() }

    func response(for url: URL) -> StubResponse? {
        mutex.lock(); defer { mutex.unlock() }; return plan[url.absoluteString]
    }

    var served: [URL] { mutex.lock(); defer { mutex.unlock() }; return urls }

    static let shared = StubLog()
}

final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        StubLog.shared.record(url)
        guard let plan = StubLog.shared.response(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch plan {
        case .redirect(let location):
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": location])!
            var next = URLRequest(url: URL(string: location)!)
            next.httpMethod = "GET"
            client?.urlProtocol(self, wasRedirectedTo: next,
                                redirectResponse: response)
            // Sans ce `didFinishLoading`, un refus de redirection laisse la
            // tâche pendue jusqu'au délai de requête (60 s) : c'est un artefact
            // du protocole fictif, pas du produit.
            client?.urlProtocolDidFinishLoading(self)

        case .chunked(let total, let chunk):
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/zip"])!
            client?.urlProtocol(self, didReceive: response,
                                cacheStoragePolicy: .notAllowed)
            var sent = 0
            while sent < total {
                let size = min(chunk, total - sent)
                client?.urlProtocol(self, didLoad: Data(repeating: 0x5A, count: size))
                sent += size
            }
            client?.urlProtocolDidFinishLoading(self)

        case .announced(let length, let body):
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(length),
                               "Content-Type": "application/zip"])!
            client?.urlProtocol(self, didReceive: response,
                                cacheStoragePolicy: .notAllowed)
            if body > 0 {
                client?.urlProtocol(self, didLoad: Data(repeating: 0x5A, count: body))
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

// MARK: - Les tests

final class ModelTransferTests: XCTestCase {

    /// Plancher du plafond, ABAISSÉ pour la recette : en production le plafond
    /// vaut `2 × 220 Mo`, et le franchir demanderait de pousser 880 Mo à
    /// travers le protocole fictif. Le code exercé est le même, à la constante
    /// près.
    private let floor: Int64 = 1_000
    private var cap: Int64 { 2 * floor }

    private var sandbox: URL!

    override func setUpWithError() throws {
        StubLog.shared.reset()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-transfer-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StubLog.shared.reset()
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    private func fetch(_ url: String) throws -> ModelDownloader.Fetched {
        try ModelDownloader.download(
            from: URL(string: url)!,
            to: sandbox.appendingPathComponent("model.zip"),
            expectedBytes: 0,
            cancellation: ModelDownloadCancellation(),
            progress: nil,
            floorBytes: floor,
            protocolClasses: [StubURLProtocol.self])
    }

    private var destination: URL { sandbox.appendingPathComponent("model.zip") }

    // MARK: - A1-03 / D2-08 : le schéma des redirections

    /// 302 vers `http://` : refus, et surtout AUCUNE requête `http:` émise.
    /// C'est la seconde moitié qui compte — un refus après coup laisserait le
    /// serveur en clair apprendre qu'on est passé.
    func testRedirectToPlainHTTPIsRefusedAndNeverRequested() throws {
        StubLog.shared.answer("https://example.invalid/model.zip",
                              with: .redirect(to: "http://example.invalid/model.zip"))
        StubLog.shared.answer("http://example.invalid/model.zip",
                              with: .chunked(total: 128, chunk: 128))

        XCTAssertThrowsError(try fetch("https://example.invalid/model.zip")) {
            guard let error = $0 as? ModelDownloadError,
                  case .unsupportedScheme(let named) = error else {
                return XCTFail("attendu .unsupportedScheme, obtenu \($0)")
            }
            XCTAssertTrue(named.hasPrefix("http://"), named)
        }
        let schemes = StubLog.shared.served.map { $0.scheme ?? "?" }
        XCTAssertEqual(schemes, ["https"],
                       "une requête non-https a été émise : \(StubLog.shared.served)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "le temporaire doit être nettoyé")
    }

    /// Contre-épreuve : une redirection `https:` → `https:` reste suivie —
    /// c'est le chemin NORMAL de GitHub (302 vers
    /// release-assets.githubusercontent.com) —, et les DEUX hôtes sont rendus.
    func testHTTPSRedirectIsFollowedAndBothHostsAreReported() throws {
        StubLog.shared.answer("https://premier.invalid/model.zip",
                              with: .redirect(to: "https://second.invalid/asset.zip"))
        StubLog.shared.answer("https://second.invalid/asset.zip",
                              with: .chunked(total: 64, chunk: 64))

        let fetched = try fetch("https://premier.invalid/model.zip")
        XCTAssertEqual(fetched.bytes, 64)
        XCTAssertEqual(fetched.hosts, ["premier.invalid", "second.invalid"])
    }

    // MARK: - A1-04 : le plafond en vol

    /// Réponse SANS `Content-Length`, trois fois le plafond : le transfert doit
    /// s'arrêter au plafond, pas à la fin. Avant le correctif, tout était écrit.
    func testUnannouncedOversizedBodyIsCutAtTheCap() throws {
        let total = Int(cap) * 3
        StubLog.shared.answer("https://example.invalid/gros.zip",
                              with: .chunked(total: total, chunk: 256))

        XCTAssertThrowsError(try fetch("https://example.invalid/gros.zip")) {
            guard let error = $0 as? ModelDownloadError,
                  case .sizeMismatch(let expected, let got) = error else {
                return XCTFail("attendu .sizeMismatch, obtenu \($0)")
            }
            XCTAssertEqual(expected, cap)
            XCTAssertGreaterThan(got, cap)
            // `got` est ce que le serveur a POUSSÉ ; ce qui a été ÉCRIT est
            // borné par le plafond (le morceau est tronqué), et le test unitaire
            // du puits ci-dessous le vérifie à l'octet.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "l'archive partielle doit être effacée")
    }

    /// `Content-Length` au-delà du plafond : refus AVANT le premier octet.
    func testAnnouncedOversizedBodyIsRefusedBeforeTheFirstByte() throws {
        StubLog.shared.answer("https://example.invalid/annonce.zip",
                              with: .announced(length: cap * 3, body: Int(cap) * 3))

        XCTAssertThrowsError(try fetch("https://example.invalid/annonce.zip")) {
            guard let error = $0 as? ModelDownloadError,
                  case .sizeMismatch(let expected, let got) = error else {
                return XCTFail("attendu .sizeMismatch, obtenu \($0)")
            }
            XCTAssertEqual(expected, cap)
            // `got` est la taille ANNONCÉE, pas un nombre d'octets écrits :
            // c'est la signature du refus avant transfert.
            XCTAssertEqual(got, cap * 3)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// Ce qui est ÉCRIT ne dépasse jamais le plafond, à l'octet près : le
    /// morceau qui le franchit est tronqué, pas écrit puis regretté. Sur un
    /// disque plein, la différence est la panne dont A1-04 parle.
    func testTheSinkNeverWritesPastTheCap() throws {
        let target = sandbox.appendingPathComponent("plafond.bin")
        let sink = try DownloadSink(destination: target, expectedBytes: 0,
                                    floorBytes: floor, progress: nil)
        let reported = OversizeBox()
        sink.setOverflowHandler { reported.set($0) }

        sink.append(Data(repeating: 0x5A, count: Int(cap) * 3))
        try sink.close()

        XCTAssertEqual(sink.bytes, cap)
        XCTAssertEqual(reported.value, cap * 3)
        let onDisk = (try FileManager.default
            .attributesOfItem(atPath: target.path)[.size] as? Int) ?? -1
        XCTAssertEqual(Int64(onDisk), cap,
                       "le fichier temporaire dépasse le plafond")
        // Et rien n'est écrit après : le puits est fermé au sens propre.
        sink.append(Data(repeating: 0x5A, count: 512))
        XCTAssertEqual(sink.bytes, cap)
    }

    /// Le plafond ne dépend PAS de `FOUINE_MODEL_SHA256` : `expectedBytes = 0`
    /// (ce que pose l'override d'empreinte) laisse le plancher faire son
    /// office. C'est exactement le cas où le contrôle disparaissait.
    func testTheCapSurvivesAnOverriddenFingerprint() throws {
        let sink = try DownloadSink(destination: sandbox
                                        .appendingPathComponent("cap.bin"),
                                    expectedBytes: 0,
                                    progress: nil)
        XCTAssertEqual(sink.cap, 2 * ModelDownloader.expectedBytes,
                       "sans taille attendue, le plafond doit retomber sur la "
                       + "constante de l'asset — et non sur zéro")
        sink.discard()
    }

    /// Un transfert nominal passe : le plafond ne gêne pas le cas normal, et
    /// l'empreinte est bien celle du contenu reçu.
    func testANormalTransferIsUnaffected() throws {
        StubLog.shared.answer("https://example.invalid/ok.zip",
                              with: .chunked(total: Int(floor), chunk: 128))
        let fetched = try fetch("https://example.invalid/ok.zip")
        XCTAssertEqual(fetched.bytes, floor)
        XCTAssertEqual(fetched.hosts, ["example.invalid"])
        XCTAssertEqual(
            fetched.sha256,
            ModelDownloader.hex(SHA256.hash(
                data: Data(repeating: 0x5A, count: Int(floor)))))
    }
}

/// Boîte à chiffre, écrite depuis le gestionnaire de dépassement.
final class OversizeBox: @unchecked Sendable {
    private let mutex = NSLock()
    private var stored: Int64?
    func set(_ value: Int64) { mutex.lock(); stored = value; mutex.unlock() }
    var value: Int64? { mutex.lock(); defer { mutex.unlock() }; return stored }
}
