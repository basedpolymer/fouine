// LicenseCheckTests.swift — ce qu'une vérification change au fichier (LC2).
//
// `LicenseCheck` est pure : chaque cas se joue en mémoire, sur les corps que
// Creem a réellement rendus le 14/09/2026 (`CreemReplies`), passés par le même
// `parse` que le client.

import XCTest
@testable import FouineLicense

final class LicenseCheckTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var now: Date { start.addingTimeInterval(400 * 86_400) }

    private var licensed: LicenseFile {
        LicenseFile(trialStarted: start,
                    key: "JKV88-3USJ9-7F5DX-M770U-E9EKC",
                    instanceID: "lki_1gAoG4SalItdXZHUYWMraB",
                    instanceName: "MacBook A",
                    activatedAt: start.addingTimeInterval(86_400),
                    lastChecked: start.addingTimeInterval(86_400),
                    activationLimit: 3,
                    state: .active)
    }

    private func reply(_ json: String) -> Result<LicenseResponse, Error> {
        .success(LicenseClient.parse(Data(json.utf8))!)
    }

    // MARK: - Quand

    func testACheckIsDueOnlyWithAKeyUnseenForThirtyDays() {
        let checked = start
        var file = licensed
        file.lastChecked = checked
        XCTAssertFalse(LicenseCheck.isDue(file, now: checked.addingTimeInterval(29 * 86_400)))
        XCTAssertTrue(LicenseCheck.isDue(file, now: checked.addingTimeInterval(31 * 86_400)))
        file.lastChecked = nil
        XCTAssertTrue(LicenseCheck.isDue(file, now: checked), "jamais vérifiée : due")
        XCTAssertFalse(LicenseCheck.isDue(LicenseFile(trialStarted: start), now: now),
                       "sans clé, rien à vérifier")
        XCTAssertFalse(LicenseCheck.isDue(nil, now: now))
        XCTAssertFalse(LicenseCheck.isDue(licensed.released(), now: now),
                       "un Mac libéré n'a plus de clé à vérifier")
    }

    // MARK: - Ce que la réponse change

    func testAnActiveKeyOnAnActiveInstanceStaysLicensedAndIsStamped() throws {
        let next = try XCTUnwrap(LicenseCheck.file(after: reply(CreemReplies.activated),
                                                   of: licensed, now: now))
        XCTAssertEqual(next.state, .active)
        XCTAssertEqual(next.lastChecked, now)
        XCTAssertEqual(next.key, licensed.key)
        guard case .licensed = LicenseState.compute(file: next, now: now) else {
            return XCTFail("attendu : sous licence")
        }
    }

    /// LE DÉFAUT MESURÉ : 200, clé `active`, instance `deactivated`. Ce Mac a
    /// été libéré depuis le portail — la clé est oubliée, l'essai reprend.
    func testAMacReleasedFromThePortalForgetsItsKey() throws {
        let next = try XCTUnwrap(LicenseCheck.file(after: reply(CreemReplies.validatedAfterRelease),
                                                   of: licensed, now: now))
        XCTAssertEqual(next, LicenseFile(trialStarted: start, state: .released))
        XCTAssertFalse(next.hasKey)
        XCTAssertEqual(LicenseState.compute(file: next, now: now),
                       .released(trialDaysLeft: 0))
        XCTAssertFalse(LicenseState.compute(file: next, now: now).allowsIndexing)
    }

    /// La dernière instance libérée : la clé passe `inactive`. C'est encore
    /// une libération, pas une fraude.
    func testAnInactiveKeyWithADeactivatedInstanceIsReleasedToo() {
        XCTAssertEqual(LicenseCheck.file(after: reply(CreemReplies.lastInstanceDeactivated),
                                         of: licensed, now: now)?.state,
                       .released)
    }

    /// 404 d'instance inconnue : même traitement. Avant LC2, c'était une
    /// « panne », et la vérification se rejouait à chaque lancement pour
    /// toujours sans rien changer.
    func testAnInstanceCreemNoLongerKnowsIsReleased() {
        XCTAssertEqual(LicenseCheck.file(after: .failure(LicenseClientError.instanceNotFound),
                                         of: licensed, now: now),
                       licensed.released())
    }

    /// Le vendeur a désactivé la clé : révoquée, clé gardée — le vendeur peut
    /// la réactiver, et la vérification suivante la rendra.
    func testADisabledKeyIsRevokedAndKeepsItsKey() throws {
        let next = try XCTUnwrap(LicenseCheck.file(
            after: .success(LicenseResponse(status: "disabled")), of: licensed, now: now))
        XCTAssertEqual(next.state, .revoked)
        XCTAssertEqual(next.key, licensed.key)
        XCTAssertEqual(next.lastChecked, now)
        XCTAssertEqual(LicenseState.compute(file: next, now: now), .revoked(reason: "disabled"))
    }

    func testAnExpiredKeyIsRevokedEvenIfItsInstanceWasReleased() {
        let response = LicenseResponse(
            status: "expired",
            instance: LicenseInstance(id: "lki_1", status: "deactivated"))
        XCTAssertEqual(LicenseCheck.file(after: .success(response),
                                         of: licensed, now: now)?.state,
                       .revoked)
    }

    /// Une réponse muette sur l'instance ne libère personne : le relais rend
    /// le corps de Creem, qui la porte toujours ; son absence est une panne.
    func testAnActiveKeyWithNoInstanceInTheAnswerStaysLicensed() {
        XCTAssertEqual(LicenseCheck.file(after: .success(LicenseResponse(status: "active")),
                                         of: licensed, now: now)?.state,
                       .active)
    }

    /// HORS LIGNE, PANNE, RÉPONSE ILLISIBLE, AUTRE REFUS : rien ne change, pas
    /// même la date.
    func testNothingChangesWhenTheServiceCannotAnswer() {
        let failures: [Error] = [LicenseClientError.offline,
                                 LicenseClientError.serviceUnavailable,
                                 LicenseClientError.malformed,
                                 LicenseClientError.keyRefused(detail: "HTTP 429"),
                                 URLError(.timedOut)]
        for failure in failures {
            XCTAssertNil(LicenseCheck.file(after: .failure(failure), of: licensed, now: now),
                         "\(failure)")
        }
    }

    /// Un Mac libéré se réactive comme n'importe quel autre : l'état écrit à
    /// l'activation (`active`) l'emporte, et l'essai d'origine est gardé.
    func testAReleasedMacCanBeActivatedAgain() {
        var file = licensed.released()
        file.key = "JKV88-3USJ9-7F5DX-M770U-E9EKC"
        file.instanceID = "lki_new"
        file.state = .active
        guard case .licensed = LicenseState.compute(file: file, now: now) else {
            return XCTFail("attendu : sous licence")
        }
        XCTAssertEqual(file.trialStarted, start)
    }
}
