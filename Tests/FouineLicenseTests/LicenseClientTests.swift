// LicenseClientTests.swift — le client du relais, sans réseau (lots L1C, LC2).
//
// Un `URLProtocol` de substitution répond à la place du relais : AUCUN de ces
// tests n'ouvre une connexion, et ils passent donc sur une machine hors ligne
// comme en intégration continue.

import XCTest
@testable import FouineLicense

/// Répond ce qu'on lui dit de répondre, et retient la dernière requête vue.
final class StubRelay: URLProtocol {

    struct Reply {
        var status = 200
        var body = Data()
        var error: Error?
    }

    nonisolated(unsafe) static var reply = Reply()
    nonisolated(unsafe) static var lastBody: [String: Any] = [:]

    static func answer(_ status: Int, _ json: String) {
        reply = Reply(status: status, body: Data(json.utf8), error: nil)
    }

    static func fail(_ error: Error) {
        reply = Reply(status: 0, body: Data(), error: error)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // `httpBody` est vidé par URLSession au moment de l'envoi : le corps se
        // relit par le flux, sans quoi l'assertion sur `instance_name` porterait
        // toujours sur un dictionnaire vide.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(contentsOf: buffer[0..<read])
            }
            stream.close()
            Self.lastBody = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any] ?? [:]
        }
        let reply = Self.reply
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class LicenseClientTests: XCTestCase {

    private var client: LicenseClient!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubRelay.self]
        client = LicenseClient(session: URLSession(configuration: configuration),
                               endpoint: URL(string: "https://relais.test/licence")!,
                               version: "1.0.0")
        StubRelay.lastBody = [:]
    }

    // MARK: - Le cas qui marche

    /// L'activation réelle du 14/09/2026 (`CreemReplies`).
    func testAnActivationKeepsTheInstanceIdentifier() async throws {
        StubRelay.answer(200, CreemReplies.activated)
        let response = try await client.activate(key: "JKV88-3USJ9-7F5DX-M770U-E9EKC",
                                                 instanceName: "MacBook A")
        XCTAssertTrue(response.isActive)
        XCTAssertTrue(response.instanceIsActive)
        XCTAssertEqual(response.instance?.id, "lki_1gAoG4SalItdXZHUYWMraB")
        XCTAssertEqual(response.instance?.name, "MacBook A")
        XCTAssertEqual(response.activationLimit, 3)
        XCTAssertEqual(response.activation, 1)
    }

    /// Ce qui part, exhaustivement : l'action, la clé, le nom du Mac.
    func testOnlyTheKeyAndTheMacNameAreSent() async throws {
        StubRelay.answer(200, CreemReplies.activated)
        _ = try await client.activate(key: "K-1", instanceName: "MacBook Air")
        XCTAssertEqual(Set(StubRelay.lastBody.keys),
                       ["action", "key", "instance_name"])
        XCTAssertEqual(StubRelay.lastBody["instance_name"] as? String, "MacBook Air")
    }

    func testAValidationSendsTheInstanceInsteadOfTheMacName() async throws {
        StubRelay.answer(200, CreemReplies.activated)
        _ = try await client.validate(key: "K-1", instanceID: "inst_77")
        XCTAssertEqual(Set(StubRelay.lastBody.keys),
                       ["action", "key", "instance_id"])
        XCTAssertEqual(StubRelay.lastBody["action"] as? String, "validate")
    }

    // MARK: - L'instance compte, pas seulement la clé (LC2)

    /// Mesuré : un Mac libéré depuis le portail valide en **200**, clé
    /// `active`, instance `deactivated`. La clé seule disait « sous licence ».
    func testAReleasedMacValidatesWithAnActiveKeyButADeactivatedInstance() async throws {
        StubRelay.answer(200, CreemReplies.validatedAfterRelease)
        let response = try await client.validate(key: "K-1",
                                                 instanceID: "lki_1gAoG4SalItdXZHUYWMraB")
        XCTAssertTrue(response.isActive, "la clé sert encore sur d'autres Mac")
        XCTAssertEqual(response.instance?.status, "deactivated")
        XCTAssertFalse(response.instanceIsActive, "mais plus sur celui-ci")
    }

    /// Une réponse sans instance ne dit pas « ce Mac » : jamais active.
    func testAnActiveKeyWithoutAnInstanceIsNotAnActiveInstance() {
        XCTAssertFalse(LicenseResponse(status: "active").instanceIsActive)
        XCTAssertFalse(LicenseResponse(
            status: "disabled",
            instance: LicenseInstance(id: "i", status: "active")).instanceIsActive)
    }

    // MARK: - Les refus

    func testAnUnknownKeyIsFourOhFour() async {
        StubRelay.answer(404, #"{ "message": ["License not found"], "status": 404 }"#)
        await assertThrows(.unknownKey) { try await self.client.activate(key: "NOPE") }
    }

    /// La limite d'activation RÉELLE : **400** (pas 409), `message` en chaîne,
    /// et un `error: "Bad Request"` qui masquait le texte tant qu'il était lu
    /// en premier.
    func testTheRealActivationLimitIsAFourHundredWithAStringMessage() async {
        StubRelay.answer(400, CreemReplies.activationLimitReached)
        await assertThrows(.keyRefused(detail: "Activation limit reached")) {
            try await self.client.activate(key: "K-1")
        }
        XCTAssertTrue(LicenseClientError.keyRefused(detail: "Activation limit reached")
            .isActivationLimit)
    }

    /// Un autre refus n'est PAS la limite : sa phrase ne doit pas envoyer la
    /// personne libérer un Mac.
    func testAnotherRefusalIsNotTheActivationLimit() {
        XCTAssertFalse(LicenseClientError.keyRefused(detail: "License key is disabled")
            .isActivationLimit)
        XCTAssertFalse(LicenseClientError.unknownKey.isActivationLimit)
    }

    /// Valider une instance inconnue : **404** JSON, `message` en tableau.
    /// C'est l'instance qui manque, pas la clé.
    func testAValidationFourOhFourIsALostInstanceNotAnUnknownKey() async {
        StubRelay.answer(404, CreemReplies.instanceNotFound)
        await assertThrows(.instanceNotFound) {
            try await self.client.validate(key: "K-1", instanceID: "lki_bidon")
        }
    }

    func testADeactivationFourOhFourIsALostInstanceToo() async {
        StubRelay.answer(404, CreemReplies.instanceNotFound)
        await assertThrows(.instanceNotFound) {
            try await self.client.deactivate(key: "K-1", instanceID: "lki_bidon")
        }
        XCTAssertTrue(LicenseClientError.instanceNotFound.meansAlreadyReleased)
    }

    /// Désactiver deux fois : **400**, faute de Creem comprise. Ce Mac était
    /// déjà libéré, et c'est ce que le refus doit dire.
    func testDeactivatingTwiceSaysTheMacWasAlreadyReleased() async {
        StubRelay.answer(400, CreemReplies.alreadyDeactivated)
        let expected = LicenseClientError.keyRefused(
            detail: "License key instnace is already deactivated")
        await assertThrows(expected) {
            try await self.client.deactivate(key: "K-1",
                                             instanceID: "lki_1gAoG4SalItdXZHUYWMraB")
        }
        XCTAssertTrue(expected.meansAlreadyReleased)
        // Le jour où Creem corrige sa faute, la phrase se reconnaît encore.
        XCTAssertTrue(LicenseClientError.keyRefused(
            detail: "License key instance is ALREADY DEACTIVATED").meansAlreadyReleased)
        XCTAssertFalse(expected.isActivationLimit)
        XCTAssertFalse(LicenseClientError.offline.meansAlreadyReleased)
        XCTAssertFalse(LicenseClientError.keyRefused(detail: "Activation limit reached")
            .meansAlreadyReleased)
    }

    // MARK: - Le détail, sous ses trois formes

    func testTheDetailReadsAStringMessageBeforeTheUselessError() {
        XCTAssertEqual(LicenseClient.detail(Data(CreemReplies.activationLimitReached.utf8),
                                            code: 400),
                       "Activation limit reached")
    }

    func testTheDetailReadsAnArrayMessage() {
        XCTAssertEqual(LicenseClient.detail(Data(CreemReplies.instanceNotFound.utf8),
                                            code: 404),
                       "License key instance not found")
    }

    /// Le relais, lui, ne rend que `error` (clé absente, JSON invalide).
    func testTheDetailFallsBackOnTheRelayErrorThenOnTheCode() {
        XCTAssertEqual(LicenseClient.detail(Data(#"{ "error": "key missing" }"#.utf8),
                                            code: 400),
                       "key missing")
        XCTAssertEqual(LicenseClient.detail(Data("<html>".utf8), code: 418), "HTTP 418")
    }

    /// Un 404 qui n'est PAS du JSON est une panne du relais, pas une mauvaise
    /// clé : c'est ce que rend l'hébergeur pour une route absente, et dire
    /// « clé non reconnue » à qui vient de payer serait le pire des messages.
    func testAFourOhFourThatIsNotJSONIsAnOutage() async {
        StubRelay.answer(404, "<!DOCTYPE html><html><body>404</body></html>")
        await assertThrows(.serviceUnavailable) {
            try await self.client.activate(key: "K-1")
        }
        await assertThrows(.serviceUnavailable) {
            try await self.client.validate(key: "K-1", instanceID: "i")
        }
    }

    func testAFiveHundredIsAServiceOutage() async {
        StubRelay.answer(502, #"{ "error": "bad gateway" }"#)
        await assertThrows(.serviceUnavailable) {
            try await self.client.activate(key: "K-1")
        }
    }

    func testNoNetworkAtAllIsOffline() async {
        StubRelay.fail(URLError(.notConnectedToInternet))
        await assertThrows(.offline) { try await self.client.activate(key: "K-1") }
    }

    func testATwoHundredWithNonsenseInsideIsMalformed() async {
        StubRelay.answer(200, "not json at all")
        await assertThrows(.malformed) { try await self.client.activate(key: "K-1") }
    }

    /// Une réponse 200 sans `status` ne dit rien : elle est aussi inutilisable
    /// qu'un corps illisible, et se traite pareil.
    func testATwoHundredWithoutAStatusIsMalformed() async {
        StubRelay.answer(200, #"{ "id": "lic_1" }"#)
        await assertThrows(.malformed) { try await self.client.activate(key: "K-1") }
    }

    // MARK: -

    private func assertThrows(_ expected: LicenseClientError,
                              file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("aucune erreur levée, \(expected) attendue", file: file, line: line)
        } catch let error as LicenseClientError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("erreur inattendue : \(error)", file: file, line: line)
        }
    }
}
