// LicenseFileTests.swift — l'aller-retour du fichier de licence (lot L1C).
//
// Un dossier jetable par test : jamais `~/Library/Application Support/Fouine`.

import XCTest
@testable import FouineLicense

final class LicenseFileTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-licence-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var fileURL: URL {
        LicenseStore.fileURL(databaseURL: scratch.appendingPathComponent("fouine.db"))
    }

    /// Le fichier suit la BASE : `FOUINE_DB` sur une copie jetable emmène le
    /// fichier de licence avec elle, et aucun test ne peut écrire dans le
    /// dossier réel de quelqu'un.
    func testTheFileSitsNextToTheDatabase() {
        XCTAssertEqual(fileURL.lastPathComponent, "license.json")
        XCTAssertEqual(fileURL.deletingLastPathComponent().path, scratch.path)
    }

    func testARoundTripKeepsEveryField() throws {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let file = LicenseFile(trialStarted: started,
                               key: "ABC123-XYZ456-XYZ456-QRS789",
                               instanceID: "inst_42",
                               instanceName: "MacBook Air",
                               activatedAt: started.addingTimeInterval(60),
                               lastChecked: started.addingTimeInterval(120),
                               activationLimit: 3,
                               state: .active)
        try LicenseStore.save(file, to: fileURL)
        XCTAssertEqual(LicenseStore.load(at: fileURL), file)
    }

    /// Sans clé, le JSON ne porte QUE `trial_started` : rien à écrire tant que
    /// rien n'a été acheté.
    func testATrialFileOnlyCarriesItsStartDate() throws {
        try LicenseStore.save(
            LicenseFile(trialStarted: Date(timeIntervalSince1970: 1_800_000_000)),
            to: fileURL)
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
                as? [String: Any])
        XCTAssertEqual(Array(raw.keys), ["trial_started"])
    }

    /// Une écriture laisse le dossier propre : pas de temporaire oublié à côté.
    func testTheAtomicWriteLeavesNoTemporaryBehind() throws {
        let file = LicenseFile(trialStarted: Date())
        try LicenseStore.save(file, to: fileURL)
        try LicenseStore.save(file, to: fileURL)   // remplacement d'un existant
        let left = try FileManager.default
            .contentsOfDirectory(atPath: scratch.path)
        XCTAssertEqual(left, ["license.json"], "temporaire oublié : \(left)")
    }

    /// Un fichier corrompu vaut « pas de licence » : pas de plantage, et
    /// surtout pas un refus d'indexer.
    func testACorruptFileReadsAsAbsent() throws {
        try Data("{ ceci n'est pas du JSON".utf8).write(to: fileURL)
        XCTAssertNil(LicenseStore.load(at: fileURL))
        XCTAssertEqual(LicenseState.compute(file: LicenseStore.load(at: fileURL)),
                       .trial(daysLeft: 30))
    }

    func testTheTrialStartsOnceAndNeverRestarts() {
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let written = LicenseStore.ensureTrialStarted(at: fileURL, now: first)
        XCTAssertEqual(written.trialStarted, first)
        let later = LicenseStore.ensureTrialStarted(
            at: fileURL, now: first.addingTimeInterval(10 * 86_400))
        XCTAssertEqual(later.trialStarted, first,
                       "un second lancement ne doit pas rallonger l'essai")
    }

    /// Libéré (LC2) : le JSON ne porte plus que l'essai et le mot `released`,
    /// lisible à l'œil — aucune clé, aucune instance.
    func testAReleasedFileOnlyCarriesItsTrialAndTheWordReleased() throws {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let licensed = LicenseFile(trialStarted: started, key: "K",
                                   instanceID: "inst_1", instanceName: "MacBook Air",
                                   lastChecked: started, activationLimit: 3,
                                   state: .active)
        try LicenseStore.save(licensed.released(), to: fileURL)
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
                as? [String: Any])
        XCTAssertEqual(Set(raw.keys), ["trial_started", "state"])
        XCTAssertEqual(raw["state"] as? String, "released")
        XCTAssertEqual(LicenseStore.load(at: fileURL), licensed.released())
    }

    /// Rétrocompatible en lecture : les fichiers écrits avant LC2 — sans
    /// `state`, avec `active`, avec `revoked` — se relisent à l'identique.
    func testFilesWrittenBeforeReleaseExistedStillLoad() throws {
        let bodies: [(String, LicenseFile.State?)] = [
            (#"{"trial_started":"2027-01-15T08:00:00Z","key":"K-1","instance_id":"inst_1"}"#, nil),
            (#"{"trial_started":"2027-01-15T08:00:00Z","key":"K-1","instance_id":"inst_1","state":"active"}"#, .active),
            (#"{"trial_started":"2027-01-15T08:00:00Z","key":"K-1","instance_id":"inst_1","state":"revoked"}"#, .revoked),
        ]
        for (json, expected) in bodies {
            try Data(json.utf8).write(to: fileURL)
            let file = try XCTUnwrap(LicenseStore.load(at: fileURL), json)
            XCTAssertEqual(file.state, expected, json)
            XCTAssertTrue(file.hasKey, json)
        }
    }

    func testDeactivatingKeepsTheTrialDateAndDropsEverythingElse() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let licensed = LicenseFile(trialStarted: started, key: "K",
                                   instanceID: "inst_1", activationLimit: 3,
                                   state: .active)
        XCTAssertEqual(licensed.withoutKey(), LicenseFile(trialStarted: started))
    }
}
