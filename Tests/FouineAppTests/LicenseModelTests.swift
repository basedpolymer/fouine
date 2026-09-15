// LicenseModelTests.swift — le mandataire de licence de l'application (L1C, LC2).
// Propriété : A-App.
//
// Le modèle est mince exprès : l'état est décidé par `FouineLicense`, le réseau
// par `LicenseClient`. Ce qui se teste ici est la couture — ce que le modèle
// ÉCRIT quand une activation aboutit, et ce qu'il NE change pas quand elle
// échoue. Un `URLProtocol` de substitution répond à la place du relais : aucune
// connexion ne part de cette suite.

import XCTest
import FouineLicense
@testable import FouineApp

/// Le relais de substitution. Une classe par suite : `URLProtocol` s'installe
/// par configuration de session, et deux suites qui partageraient le même
/// double se marcheraient dessus sous `make ci-unit` (un processus par test,
/// mais les classes restent distinctes).
final class LicenceRelayDouble: URLProtocol {

    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var transportError: Error?

    static func answer(_ status: Int, _ json: String) {
        self.status = status
        self.body = Data(json.utf8)
        self.transportError = nil
    }

    static func offline() {
        transportError = URLError(.notConnectedToInternet)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let error = Self.transportError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class LicenseModelTests: XCTestCase {

    private var scratch: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-licence-model-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
        databaseURL = scratch.appendingPathComponent("copie.db")
        LicenceRelayDouble.transportError = nil
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeModel() -> LicenseModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LicenceRelayDouble.self]
        return LicenseModel(
            databaseURL: databaseURL,
            client: LicenseClient(session: URLSession(configuration: configuration),
                                  endpoint: URL(string: "https://relais.test/l")!,
                                  version: "1.0.0"))
    }

    private var licenceFile: LicenseFile? {
        LicenseStore.load(at: LicenseStore.fileURL(databaseURL: databaseURL))
    }

    private static let activeBody = """
        { "id": "lic_1", "status": "active", "activation": 1,
          "activation_limit": 3,
          "instance": { "id": "inst_77", "name": "Mac de test", "status": "active" } }
        """

    // Corps RÉELS du bac à sable Creem, 14/09/2026 (voir
    // `FouineLicenseTests/CreemReplies.swift`, dont ce sont des copies : les
    // deux cibles de test ne se voient pas).
    private static let limitReached = #"{"trace_id":"38fc4633-683b-4514-9414-7aaf786f883c","status":400,"error":"Bad Request","message":"Activation limit reached","timestamp":1789389364622}"#
    private static let instanceNotFound = #"{"trace_id":"2b26641a-9d2b-4bdd-889c-9902121de4bb","status":404,"error":"Bad Request","message":["License key instance not found"],"timestamp":1789389364809}"#
    private static let validatedAfterRelease = #"{"object":"license","id":"lk_3Bkq8BGQ2DGRSkQ9OuFqXq","product_id":"prod_1OiconyhdjZKiMpWMaoJEB","status":"active","key":"JKV88-3USJ9-7F5DX-M770U-E9EKC","activation":2,"activation_limit":3,"expires_at":null,"created_at":"2026-09-14T12:09:21.795Z","instance":{"object":"license-instance","id":"lki_1gAoG4SalItdXZHUYWMraB","name":"MacBook A","status":"deactivated","created_at":"2026-09-14T12:36:03.610Z","mode":"test"},"mode":"test"}"#
    private static let alreadyDeactivated = #"{"trace_id":"5b93faf6-c1fe-4823-874c-d7ff37ea0cdf","status":400,"error":"Bad Request","message":"License key instnace is already deactivated","timestamp":1789389365629}"#

    // MARK: - Le démarrage

    func testTheFirstLaunchStartsTheTrialAndWritesItOnce() {
        let model = makeModel()
        model.start()
        XCTAssertEqual(model.state, .trial(daysLeft: 30))
        let first = licenceFile?.trialStarted
        XCTAssertNotNil(first)
        model.start()
        XCTAssertEqual(licenceFile?.trialStarted, first,
                       "un second lancement ne doit pas repartir de zéro")
    }

    // MARK: - L'activation

    func testASuccessfulActivationWritesTheFileAndTurnsLicensed() async {
        LicenceRelayDouble.answer(200, Self.activeBody)
        let model = makeModel()
        model.start()

        await model.activate(key: " abc123-xyz456-xyz456-qrs789 ")

        // La date de vérification n'est comparée qu'à la seconde : elle passe
        // par l'ISO 8601 du fichier, qui n'a pas de sous-seconde.
        guard case .licensed(let masked, let checked) = model.state else {
            return XCTFail("état attendu : sous licence, obtenu \(model.state)")
        }
        XCTAssertEqual(masked, "·····QRS789")
        XCTAssertNotNil(checked)
        XCTAssertNil(model.errorMessage)
        let file = licenceFile
        // La clé est enregistrée NETTOYÉE : espaces retirés, majuscules.
        XCTAssertEqual(file?.key, "ABC123-XYZ456-XYZ456-QRS789")
        XCTAssertEqual(file?.instanceID, "inst_77")
        XCTAssertEqual(file?.instanceName, "Mac de test")
        XCTAssertEqual(file?.activationLimit, 3)
        XCTAssertEqual(file?.state, .active)
        XCTAssertTrue(model.allowsIndexing)
    }

    func testARefusedKeyLeavesTheStateAloneAndSaysWhy() async {
        LicenceRelayDouble.answer(404, #"{ "message": ["not found"], "status": 404 }"#)
        let model = makeModel()
        model.start()

        await model.activate(key: "MAUVAISE-CLE")

        XCTAssertEqual(model.state, .trial(daysLeft: 30),
                       "un refus ne doit rien changer à l'essai en cours")
        XCTAssertEqual(model.errorMessage,
                       LicenseModel.message(for: .unknownKey))
        XCTAssertNil(licenceFile?.key, "aucune clé ne doit être écrite")
    }

    /// La limite RÉELLE (400, message-chaîne) garde sa phrase à elle.
    func testTheRealActivationLimitSaysThreeMacs() async {
        LicenceRelayDouble.answer(400, Self.limitReached)
        let model = makeModel()
        model.start()

        await model.activate(key: "JKV88-3USJ9-7F5DX-M770U-E9EKC")

        XCTAssertEqual(model.errorMessage,
                       LicenseModel.message(for: .keyRefused(detail: "Activation limit reached")))
        XCTAssertNotEqual(model.errorMessage,
                          LicenseModel.message(for: .keyRefused(detail: "License key is disabled")),
                          "la limite et un autre refus ne disent pas la même chose")
        XCTAssertNil(licenceFile?.key)
    }

    /// Tout autre refus ne parle pas de « 3 Mac » : libérer un Mac n'y
    /// changerait rien (LC2).
    func testAnotherRefusalDoesNotSendThePersonToFreeAMac() async {
        LicenceRelayDouble.answer(400, #"{"status":400,"error":"Bad Request","message":"License key is disabled"}"#)
        let model = makeModel()
        model.start()

        await model.activate(key: "JKV88-3USJ9-7F5DX-M770U-E9EKC")

        XCTAssertEqual(model.errorMessage,
                       LicenseModel.message(for: .keyRefused(detail: "License key is disabled")))
        XCTAssertNotEqual(model.errorMessage,
                          LicenseModel.message(for: .keyRefused(detail: "Activation limit reached")))
    }

    /// Une activation qui rend une clé active mais une instance qui ne l'est
    /// pas n'active rien : c'est le couple qui compte.
    func testAnActivationWithAnInactiveInstanceWritesNothing() async {
        LicenceRelayDouble.answer(200, Self.validatedAfterRelease)
        let model = makeModel()
        model.start()

        await model.activate(key: "JKV88-3USJ9-7F5DX-M770U-E9EKC")

        XCTAssertNil(licenceFile?.key)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.state, .trial(daysLeft: 30))
    }

    func testNoConnectionSaysSoWithoutTouchingTheFile() async {
        LicenceRelayDouble.offline()
        let model = makeModel()
        model.start()

        await model.activate(key: "ABC123-XYZ456")

        XCTAssertEqual(model.errorMessage, LicenseModel.message(for: .offline))
        XCTAssertNil(licenceFile?.key)
    }

    /// Une nouvelle tentative efface le message précédent : une erreur qui
    /// reste affichée pendant l'essai suivant laisse croire qu'elle vient
    /// d'arriver.
    func testRetryingClearsThePreviousError() async {
        LicenceRelayDouble.answer(404, "{}")
        let model = makeModel()
        model.start()
        await model.activate(key: "MAUVAISE")
        XCTAssertNotNil(model.errorMessage)

        LicenceRelayDouble.answer(200, Self.activeBody)
        await model.activate(key: "ABC123-XYZ456-XYZ456-QRS789")
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - La désactivation

    func testDeactivatingKeepsTheTrialDateAndReturnsToItsState() async {
        LicenceRelayDouble.answer(200, Self.activeBody)
        let model = makeModel()
        model.start()
        let started = licenceFile?.trialStarted
        await model.activate(key: "ABC123-XYZ456-XYZ456-QRS789")

        await model.deactivate()

        XCTAssertNil(licenceFile?.key)
        XCTAssertEqual(licenceFile?.trialStarted, started,
                       "la date d'essai ne se rejoue pas")
        XCTAssertEqual(model.state, .trial(daysLeft: 30))
    }

    /// Un Mac déjà libéré (400 « already deactivated », faute de Creem
    /// comprise) : l'application nettoie ce Mac, sans message — il n'y avait
    /// plus rien à libérer (LC2).
    func testDeactivatingAMacAlreadyReleasedCleansItQuietly() async {
        LicenceRelayDouble.answer(200, Self.activeBody)
        let model = makeModel()
        model.start()
        await model.activate(key: "ABC123-XYZ456-XYZ456-QRS789")

        LicenceRelayDouble.answer(400, Self.alreadyDeactivated)
        await model.deactivate()

        XCTAssertNil(licenceFile?.key)
        XCTAssertNil(licenceFile?.state, "un geste d'ici n'est pas une libération d'ailleurs")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.state, .trial(daysLeft: 30))
    }

    // MARK: - La vérification silencieuse

    /// Une clé vérifiée hier ne redemande rien : au plus une fois par mois.
    func testARecentlyCheckedLicenceIsNotRevalidated() async {
        LicenceRelayDouble.answer(200, Self.activeBody)
        let model = makeModel()
        model.start()
        await model.activate(key: "ABC123-XYZ456-XYZ456-QRS789")
        let checked = licenceFile?.lastChecked

        // Le relais répondrait « disabled » — mais on ne doit pas l'appeler.
        LicenceRelayDouble.answer(200, #"{ "status": "disabled" }"#)
        await model.revalidateIfDue()

        XCTAssertEqual(licenceFile?.lastChecked, checked)
        XCTAssertEqual(licenceFile?.state, .active)
    }

    func testAKeyDisabledBySinceTheLastCheckBecomesRevoked() async {
        LicenceRelayDouble.answer(200, Self.activeBody)
        let model = makeModel()
        model.start()
        await model.activate(key: "ABC123-XYZ456-XYZ456-QRS789")

        LicenceRelayDouble.answer(200, #"{ "status": "disabled" }"#)
        await model.revalidateIfDue(now: Date().addingTimeInterval(40 * 86_400))

        XCTAssertEqual(model.state, .revoked(reason: "disabled"))
        XCTAssertFalse(model.allowsIndexing)
    }

    /// LE DÉFAUT MESURÉ LE 14/09/2026 : un Mac libéré depuis le portail valide
    /// en 200, clé `active`, instance `deactivated`. Il cesse d'être sous
    /// licence, la clé est oubliée, et l'état le dit (LC2).
    func testAMacReleasedFromThePortalStopsBeingLicensed() async {
        LicenceRelayDouble.answer(200, Self.activeBody)
        let model = makeModel()
        model.start()
        await model.activate(key: "ABC123-XYZ456-XYZ456-QRS789")

        LicenceRelayDouble.answer(200, Self.validatedAfterRelease)
        await model.revalidateIfDue(now: Date().addingTimeInterval(40 * 86_400))

        XCTAssertEqual(model.state, .released(trialDaysLeft: 0))
        XCTAssertFalse(model.allowsIndexing)
        XCTAssertNil(licenceFile?.key, "la clé est oubliée")
        XCTAssertEqual(licenceFile?.state, .released)
        XCTAssertEqual(LicenseStatusText.headline(model.state),
                       String(localized: "This Mac was released from your customer portal. Enter your key again to use it here."))
    }

    /// 404 d'instance : même chose. Avant LC2, une « panne » réessayée à
    /// chaque lancement pour toujours, le Mac restant sous licence.
    func testAnInstanceUnknownToTheSellerIsReleasedToo() async {
        LicenceRelayDouble.answer(200, Self.activeBody)
        let model = makeModel()
        model.start()
        await model.activate(key: "ABC123-XYZ456-XYZ456-QRS789")

        LicenceRelayDouble.answer(404, Self.instanceNotFound)
        await model.revalidateIfDue(now: Date().addingTimeInterval(40 * 86_400))

        XCTAssertEqual(model.state, .released(trialDaysLeft: 0))
        XCTAssertEqual(licenceFile?.state, .released)
    }

    /// HORS LIGNE : RIEN NE CHANGE. Ni l'état, ni la date de dernière
    /// vérification — sinon on n'essaierait plus avant un mois.
    func testAnOfflineRevalidationChangesNothingAtAll() async {
        LicenceRelayDouble.answer(200, Self.activeBody)
        let model = makeModel()
        model.start()
        await model.activate(key: "ABC123-XYZ456-XYZ456-QRS789")
        let checked = licenceFile?.lastChecked

        LicenceRelayDouble.offline()
        await model.revalidateIfDue(now: Date().addingTimeInterval(40 * 86_400))

        XCTAssertEqual(licenceFile?.lastChecked, checked)
        XCTAssertEqual(licenceFile?.state, .active)
        XCTAssertTrue(model.allowsIndexing)
    }
}
