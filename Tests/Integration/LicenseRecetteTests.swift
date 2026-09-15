// LicenseRecetteTests.swift — recette de `fouine license` (lot L1C).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// Le fichier de licence vit À CÔTÉ DE LA BASE : `FOUINE_DB` posée sur une base
// jetable emmène donc le fichier avec elle, et cette recette ne peut pas
// toucher `~/Library/Application Support/Fouine/license.json`. C'est le même
// mécanisme d'isolation que les autres suites d'intégration, sans variable
// nouvelle.
//
// AUCUNE CONNEXION NE QUITTE LA MACHINE. Jusqu'à LC2, seul `status` sur un
// fichier sans clé était exercé ici ; `activate`, `deactivate` et la
// vérification mensuelle de `status` parlent désormais à `LocalLicenceRelay`,
// sur 127.0.0.1, par `FOUINE_LICENSE_RELAY` — avec les corps que Creem a
// réellement rendus dans son bac à sable le 14/09/2026.

import Foundation
import XCTest

final class LicenseRecetteTests: XCTestCase {

    private var scratch: URL!
    private var database: URL!

    override func setUpWithError() throws {
        _ = try Recette.requireBinary()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-licence-recette-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
        database = scratch.appendingPathComponent("copie.db")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Un dossier neuf : l'essai n'a pas encore commencé, et le JSON le dit
    /// sans le démarrer — `status` ne consomme pas un jour d'essai.
    func testLicenceStatusOnAFreshFolderReportsATrial() throws {
        let result = try Recette.run(["license", "status", "--json"],
                                     database: database)
        XCTAssertEqual(result.status, 0, result.describe)

        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
        let json = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(json["state"] as? String, "trial")
        XCTAssertEqual(json["days_left"] as? Int, 30)
        XCTAssertNil(json["key_suffix"], "aucune clé n'a été activée")

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: scratch.appendingPathComponent("license.json").path),
            "`license status` ne doit pas démarrer l'essai")
    }

    /// La forme texte dit la même chose, et donne l'adresse d'achat.
    func testTheTextFormNamesThePriceAndTheShop() throws {
        let result = try Recette.run(["license", "status"], database: database)
        XCTAssertEqual(result.status, 0, result.describe)
        XCTAssertTrue(result.stdout.contains("Trial:"), result.stdout)
        XCTAssertTrue(result.stdout.contains("creem.io"), result.stdout)
    }

    /// Un essai vieux de soixante jours : `crawl` refuse en **6**, en nommant
    /// les deux gestes, et dit que la recherche marche toujours.
    func testAnExpiredTrialRefusesToCrawlWithItsOwnExitCode() throws {
        let licence = scratch.appendingPathComponent("license.json")
        let started = Date().addingTimeInterval(-60 * 86_400)
        let json = ["trial_started": ISO8601DateFormatter().string(from: started)]
        try JSONSerialization.data(withJSONObject: json).write(to: licence)

        let crawl = try Recette.run(["crawl"], database: database)
        XCTAssertEqual(crawl.status, 6, crawl.describe)
        XCTAssertTrue(crawl.stderr.contains("Trial over"), crawl.stderr)
        XCTAssertTrue(crawl.stderr.contains("Search still works"), crawl.stderr)

        let status = try Recette.run(["license", "status", "--json"],
                                     database: database)
        XCTAssertEqual(status.status, 0, status.describe)
        let object = try JSONSerialization.jsonObject(with: Data(status.stdout.utf8))
        XCTAssertEqual((object as? [String: Any])?["state"] as? String, "trial_over")
    }

    // MARK: - Ce que Creem répond vraiment (LC2)

    // Corps RÉELS du bac à sable Creem, 14/09/2026 (copies de
    // `FouineLicenseTests/CreemReplies.swift` : les cibles ne se voient pas).
    private static let activated = #"{"object":"license","id":"lk_3Bkq8BGQ2DGRSkQ9OuFqXq","product_id":"prod_1OiconyhdjZKiMpWMaoJEB","status":"active","key":"JKV88-3USJ9-7F5DX-M770U-E9EKC","activation":1,"activation_limit":3,"expires_at":null,"created_at":"2026-09-14T12:09:21.795Z","instance":{"object":"license-instance","id":"lki_1gAoG4SalItdXZHUYWMraB","name":"MacBook A","status":"active","created_at":"2026-09-14T12:36:03.610Z","mode":"test"},"mode":"test"}"#
    private static let limitReached = #"{"trace_id":"38fc4633-683b-4514-9414-7aaf786f883c","status":400,"error":"Bad Request","message":"Activation limit reached","timestamp":1789389364622}"#
    private static let validatedAfterRelease = #"{"object":"license","id":"lk_3Bkq8BGQ2DGRSkQ9OuFqXq","product_id":"prod_1OiconyhdjZKiMpWMaoJEB","status":"active","key":"JKV88-3USJ9-7F5DX-M770U-E9EKC","activation":2,"activation_limit":3,"expires_at":null,"created_at":"2026-09-14T12:09:21.795Z","instance":{"object":"license-instance","id":"lki_1gAoG4SalItdXZHUYWMraB","name":"MacBook A","status":"deactivated","created_at":"2026-09-14T12:36:03.610Z","mode":"test"},"mode":"test"}"#
    private static let alreadyDeactivated = #"{"trace_id":"5b93faf6-c1fe-4823-874c-d7ff37ea0cdf","status":400,"error":"Bad Request","message":"License key instnace is already deactivated","timestamp":1789389365629}"#

    private var licenceURL: URL { scratch.appendingPathComponent("license.json") }

    /// Un fichier sous licence, vérifié pour la dernière fois il y a `days`.
    private func writeLicensedFile(checkedDaysAgo days: Double) throws {
        let iso = ISO8601DateFormatter()
        let now = Date()
        let json: [String: Any] = [
            "trial_started": iso.string(from: now.addingTimeInterval(-400 * 86_400)),
            "key": "JKV88-3USJ9-7F5DX-M770U-E9EKC",
            "instance_id": "lki_1gAoG4SalItdXZHUYWMraB",
            "instance_name": "MacBook A",
            "activated_at": iso.string(from: now.addingTimeInterval(-300 * 86_400)),
            "last_checked": iso.string(from: now.addingTimeInterval(-days * 86_400)),
            "activation_limit": 3,
            "state": "active",
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: licenceURL)
    }

    private var licenceOnDisk: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: licenceURL)))
            as? [String: Any] ?? [:]
    }

    private func license(_ arguments: [String],
                         relay: LocalLicenceRelay) throws -> CommandResult {
        try Recette.run(["license"] + arguments, database: database, timeout: 60,
                        extraEnvironment: ["FOUINE_LICENSE_RELAY": relay.url.absoluteString])
    }

    private func json(_ result: CommandResult) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
        return try XCTUnwrap(object as? [String: Any], result.describe)
    }

    /// LE DÉFAUT MESURÉ : un Mac libéré depuis le portail valide en 200, clé
    /// `active`, instance `deactivated`. Vérifié il y a 31 jours, `status` le
    /// vérifie, l'annonce `released`, et oublie la clé.
    func testAMonthOldLicenceOnAMacReleasedFromThePortalBecomesReleased() throws {
        try writeLicensedFile(checkedDaysAgo: 31)
        let relay = try LocalLicenceRelay(answers: [
            "validate": .init(status: 200, body: Self.validatedAfterRelease)])

        let status = try license(["status", "--json"], relay: relay)

        XCTAssertEqual(status.status, 0, status.describe)
        let out = try json(status)
        XCTAssertEqual(out["state"] as? String, "released", status.describe)
        XCTAssertNil(out["days_left"], "l'essai est fini depuis longtemps")
        XCTAssertNil(out["key_suffix"], "la clé est oubliée")
        XCTAssertEqual(relay.requests.count, 1)
        XCTAssertEqual(relay.requests.first?["action"] as? String, "validate")
        XCTAssertEqual(Set(relay.requests.first?.keys.map { $0 } ?? []),
                       ["action", "key", "instance_id"])
        XCTAssertEqual(Set(licenceOnDisk.keys), ["trial_started", "state"])
        XCTAssertEqual(licenceOnDisk["state"] as? String, "released")

        // Déjà libéré, plus rien à vérifier : la forme texte ne sort plus.
        let text = try license(["status"], relay: relay)
        XCTAssertEqual(text.status, 0, text.describe)
        XCTAssertTrue(text.stdout.contains("released from your customer portal"), text.stdout)
        XCTAssertTrue(text.stdout.contains("fouine license activate"), text.stdout)
        XCTAssertEqual(relay.requests.count, 1, "un Mac libéré n'a plus de clé à vérifier")

        // Et l'index cesse de se mettre à jour, comme en fin d'essai.
        let crawl = try Recette.run(["crawl"], database: database)
        XCTAssertEqual(crawl.status, 6, crawl.describe)
    }

    /// Vérifiée hier : `status` ne contacte rien.
    func testARecentlyCheckedLicenceContactsNothing() throws {
        try writeLicensedFile(checkedDaysAgo: 1)
        let relay = try LocalLicenceRelay(answers: [
            "validate": .init(status: 200, body: Self.validatedAfterRelease)])

        let status = try license(["status", "--json"], relay: relay)

        XCTAssertEqual(status.status, 0, status.describe)
        XCTAssertEqual(try json(status)["state"] as? String, "licensed")
        XCTAssertEqual(try json(status)["key_suffix"] as? String, "-E9EKC")
        XCTAssertTrue(relay.requests.isEmpty, "au plus une vérification tous les 30 jours")
    }

    /// Service injoignable : RIEN NE CHANGE, ni l'état ni la date ; une ligne
    /// sur stderr, le JSON intact sur stdout.
    func testAnUnreachableServiceChangesNothing() throws {
        try writeLicensedFile(checkedDaysAgo: 31)
        let before = try Data(contentsOf: licenceURL)
        let relay = try LocalLicenceRelay(answers: [:])
        relay.stop()

        let status = try license(["status", "--json"], relay: relay)

        XCTAssertEqual(status.status, 0, status.describe)
        XCTAssertEqual(try json(status)["state"] as? String, "licensed")
        XCTAssertTrue(status.stderr.contains("could not be checked"), status.stderr)
        XCTAssertEqual(try Data(contentsOf: licenceURL), before, "le fichier ne bouge pas")
    }

    /// Désactiver un Mac déjà libéré (400 « already deactivated », faute de
    /// Creem comprise) : ce Mac est nettoyé, sortie 0. Avant LC2 : sortie 7 et
    /// une clé morte gardée.
    func testDeactivatingAMacAlreadyReleasedCleansItAndSucceeds() throws {
        try writeLicensedFile(checkedDaysAgo: 1)
        let relay = try LocalLicenceRelay(answers: [
            "deactivate": .init(status: 400, body: Self.alreadyDeactivated)])

        let result = try license(["deactivate"], relay: relay)

        XCTAssertEqual(result.status, 0, result.describe)
        XCTAssertTrue(result.stdout.contains("This Mac was already released."), result.describe)
        XCTAssertNil(licenceOnDisk["key"], "la clé morte est retirée")
        XCTAssertNotNil(licenceOnDisk["trial_started"], "l'essai ne se rejoue pas")
        XCTAssertEqual(relay.requests.first?["action"] as? String, "deactivate")
    }

    /// Une désactivation qui aboutit garde sa phrase d'avant.
    func testAnOrdinaryDeactivationStillSaysSo() throws {
        try writeLicensedFile(checkedDaysAgo: 1)
        let relay = try LocalLicenceRelay(answers: [
            "deactivate": .init(status: 200, body: Self.validatedAfterRelease)])

        let result = try license(["deactivate"], relay: relay)

        XCTAssertEqual(result.status, 0, result.describe)
        XCTAssertTrue(result.stdout.contains("no longer counts towards your activations"),
                      result.describe)
        XCTAssertNil(licenceOnDisk["key"])
    }

    /// Le quatrième Mac : 400 réel, sortie **7**, et la phrase de la limite.
    /// Un autre refus garde la sortie 7 mais ne parle pas de « 3 Macs ».
    func testTheActivationLimitExitsSevenWithItsOwnSentence() throws {
        let limit = try LocalLicenceRelay(answers: [
            "activate": .init(status: 400, body: Self.limitReached)])
        let refused = try license(["activate", "JKV88-3USJ9-7F5DX-M770U-E9EKC",
                                   "--instance-name", "Mac D"], relay: limit)
        XCTAssertEqual(refused.status, 7, refused.describe)
        XCTAssertTrue(refused.stderr.contains("already in use on 3 Macs"), refused.stderr)
        XCTAssertTrue(refused.stderr.contains("Activation limit reached"), refused.stderr)
        XCTAssertNil(licenceOnDisk["key"], "aucune clé écrite")

        let disabled = try LocalLicenceRelay(answers: [
            "activate": .init(status: 400,
                              body: #"{"status":400,"error":"Bad Request","message":"License key is disabled"}"#)])
        let other = try license(["activate", "JKV88-3USJ9-7F5DX-M770U-E9EKC"], relay: disabled)
        XCTAssertEqual(other.status, 7, other.describe)
        XCTAssertFalse(other.stderr.contains("3 Macs"), other.stderr)
        XCTAssertTrue(other.stderr.contains("Contact the seller"), other.stderr)
    }

    /// Une activation réelle écrit la clé et l'instance rendues par Creem.
    func testAnActivationThroughTheRelayWritesTheInstance() throws {
        let relay = try LocalLicenceRelay(answers: [
            "activate": .init(status: 200, body: Self.activated)])

        let result = try license(["activate", "jkv88-3usj9-7f5dx-m770u-e9ekc",
                                  "--instance-name", "MacBook A"], relay: relay)

        XCTAssertEqual(result.status, 0, result.describe)
        XCTAssertEqual(licenceOnDisk["instance_id"] as? String, "lki_1gAoG4SalItdXZHUYWMraB")
        XCTAssertEqual(licenceOnDisk["key"] as? String, "JKV88-3USJ9-7F5DX-M770U-E9EKC")
        XCTAssertEqual(licenceOnDisk["state"] as? String, "active")
        XCTAssertEqual(relay.requests.first?["instance_name"] as? String, "MacBook A")
    }
}
