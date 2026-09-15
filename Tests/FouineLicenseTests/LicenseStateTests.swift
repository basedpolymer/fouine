// LicenseStateTests.swift — les cinq états, jour par jour (lots L1C, LC2).
//
// `LicenseState.compute` est pure : ces cas se jouent en mémoire, sans fichier
// et sans horloge du système.

import XCTest
@testable import FouineLicense

final class LicenseStateTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(daysAfterStart days: Double,
                       file: LicenseFile? = nil) -> LicenseState {
        LicenseState.compute(file: file ?? LicenseFile(trialStarted: start),
                             now: start.addingTimeInterval(days * 86_400))
    }

    // MARK: - L'essai

    func testDayZeroLeavesTheWholeTrial() {
        XCTAssertEqual(state(daysAfterStart: 0), .trial(daysLeft: 30))
    }

    func testDayTwentyNineLeavesOneDay() {
        XCTAssertEqual(state(daysAfterStart: 29), .trial(daysLeft: 1))
    }

    /// Le dernier jour est ENTIER : à J+29,9 il reste un jour, pas zéro.
    func testTheLastDayIsWholeUntilItEnds() {
        XCTAssertEqual(state(daysAfterStart: 29.9), .trial(daysLeft: 1))
    }

    func testDayThirtyEndsTheTrial() {
        XCTAssertEqual(state(daysAfterStart: 30), .trialOver)
    }

    func testDayThirtyOneIsStillOver() {
        XCTAssertEqual(state(daysAfterStart: 31), .trialOver)
    }

    /// Horloge reculée : une date de départ dans le futur compte comme
    /// aujourd'hui. Ni rallonge par triche, ni essai perdu par pile morte.
    func testAStartDateInTheFutureCountsAsToday() {
        let file = LicenseFile(trialStarted: start.addingTimeInterval(400 * 86_400))
        XCTAssertEqual(LicenseState.compute(file: file, now: start),
                       .trial(daysLeft: 30))
    }

    /// Fichier absent ou illisible : l'essai est réputé commencer maintenant.
    func testNoFileMeansAFreshTrial() {
        XCTAssertEqual(LicenseState.compute(file: nil, now: start),
                       .trial(daysLeft: 30))
    }

    // MARK: - La clé

    func testAnActivatedKeyIsLicensedEvenLongAfterTheTrial() {
        let checked = start.addingTimeInterval(90 * 86_400)
        let file = LicenseFile(trialStarted: start,
                               key: "ABC123-XYZ456-XYZ456-QRS789",
                               instanceID: "inst_1",
                               lastChecked: checked)
        XCTAssertEqual(state(daysAfterStart: 400, file: file),
                       .licensed(maskedKey: "·····QRS789", lastChecked: checked))
    }

    /// Une clé sans instance n'en est pas une : le couple est ce qui permet de
    /// vérifier et de désactiver ce Mac.
    func testAKeyWithoutAnInstanceIsNotALicence() {
        let file = LicenseFile(trialStarted: start, key: "ABC123-XYZ456")
        XCTAssertEqual(state(daysAfterStart: 40, file: file), .trialOver)
    }

    func testARevokedKeyIsRevoked() {
        let file = LicenseFile(trialStarted: start, key: "ABC123-XYZ456",
                               instanceID: "inst_1", state: .revoked)
        XCTAssertEqual(state(daysAfterStart: 1, file: file),
                       .revoked(reason: "disabled"))
    }

    // MARK: - Le Mac libéré (LC2)

    /// Libéré depuis le portail, l'essai fini : ni sous licence, ni révoqué —
    /// un état à lui, qui arrête la mise à jour comme la fin d'essai.
    func testAReleasedMacAfterTheTrialIsReleasedWithNoDayLeft() {
        let file = LicenseFile(trialStarted: start, state: .released)
        XCTAssertEqual(state(daysAfterStart: 400, file: file), .released(trialDaysLeft: 0))
        XCTAssertFalse(state(daysAfterStart: 400, file: file).allowsIndexing)
    }

    /// Libéré pendant l'essai (rare : horloge, fichier retouché) : l'essai
    /// continue son cours, la mise à jour aussi.
    func testAReleasedMacDuringTheTrialKeepsWhatIsLeftOfIt() {
        let file = LicenseFile(trialStarted: start, state: .released)
        XCTAssertEqual(state(daysAfterStart: 10, file: file), .released(trialDaysLeft: 20))
        XCTAssertTrue(state(daysAfterStart: 10, file: file).allowsIndexing)
    }

    /// Les fichiers d'avant LC2 se lisent comme avant : sans `state`, avec
    /// `active`, avec `revoked`.
    func testTheStatesWrittenBeforeReleaseStillReadTheSame() {
        let bare = LicenseFile(trialStarted: start, key: "ABC123-XYZ456-XYZ456-QRS789",
                               instanceID: "inst_1")
        var active = bare
        active.state = .active
        XCTAssertEqual(state(daysAfterStart: 40, file: bare),
                       .licensed(maskedKey: "·····QRS789", lastChecked: nil))
        XCTAssertEqual(state(daysAfterStart: 40, file: active),
                       .licensed(maskedKey: "·····QRS789", lastChecked: nil))
        XCTAssertEqual(state(daysAfterStart: 40, file: LicenseFile(trialStarted: start)),
                       .trialOver)
    }

    // MARK: - Ce que chaque état permet

    func testOnlyTrialAndLicenceKeepTheIndexUpToDate() {
        XCTAssertTrue(LicenseState.trial(daysLeft: 1).allowsIndexing)
        XCTAssertTrue(LicenseState.licensed(maskedKey: "·····X",
                                            lastChecked: nil).allowsIndexing)
        XCTAssertFalse(LicenseState.trialOver.allowsIndexing)
        XCTAssertFalse(LicenseState.revoked(reason: "disabled").allowsIndexing)
    }

    func testTheJSONNamesAreTheContractOfTheCommandLine() {
        XCTAssertEqual(LicenseState.trial(daysLeft: 3).jsonName, "trial")
        XCTAssertEqual(LicenseState.trialOver.jsonName, "trial_over")
        XCTAssertEqual(LicenseState.licensed(maskedKey: "x",
                                             lastChecked: nil).jsonName, "licensed")
        XCTAssertEqual(LicenseState.revoked(reason: "disabled").jsonName, "revoked")
        XCTAssertEqual(LicenseState.released(trialDaysLeft: 0).jsonName, "released")
    }

    // MARK: - La clé collée depuis un courriel

    func testAPastedKeyIsCleanedUp() {
        XCTAssertEqual(LicenseState.normalize("  abc123-xyz456\n"),
                       "ABC123-XYZ456")
        XCTAssertEqual(LicenseState.normalize("ABC123 - XYZ456"),
                       "ABC123-XYZ456")
    }

    func testTheMaskShowsTheLastSixCharacters() {
        XCTAssertEqual(LicenseState.mask("ABC123-XYZ456-XYZ456-QRS789"),
                       "·····QRS789")
        XCTAssertEqual(LicenseState.suffix("ABC123-XYZ456-XYZ456-QRS789"),
                       "QRS789")
        // Trop courte pour être une clé Creem : masquée, elle n'apprendrait rien.
        XCTAssertEqual(LicenseState.mask("ABC12"), "ABC12")
    }
}
