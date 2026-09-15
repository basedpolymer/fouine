// SpotlightSyncTests.swift — la remise à Spotlight, sans Spotlight (INT-S1).
// Propriété : A-Core.
//
// Un donateur d'essai remplace `CSSearchableIndex` : c'est la seule façon
// d'éprouver ce qui compte — qui est donné, qui est retiré, où va le marqueur —
// puisque le vrai service exige un bundle installé. La base, elle, est vraie :
// `documentsChanged` et `pageTexts` sont du SQL, et un faux store ne prouverait
// rien de leur exactitude (voir `SpotlightStoreTests` côté cœur).

import Foundation
import XCTest
import FouineCore
@testable import FouineIndex

/// Un donateur qui note ce qu'on lui demande.
final class FakeDonor: SpotlightDonating, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var indexed: [SpotlightItem] = []
    private(set) var deleted: [String] = []
    private(set) var deleteAllCalls = 0
    var available = true
    /// Fait échouer la remise, comme un service système occupé.
    var failure: Error?

    var isAvailable: Bool { available }

    func index(_ items: [SpotlightItem]) throws {
        if let failure { throw failure }
        lock.lock(); indexed.append(contentsOf: items); lock.unlock()
    }

    func delete(identifiers: [String]) throws {
        if let failure { throw failure }
        lock.lock(); deleted.append(contentsOf: identifiers); lock.unlock()
    }

    func deleteAll() throws {
        if let failure { throw failure }
        lock.lock(); deleteAllCalls += 1; lock.unlock()
    }
}

/// Une base en mémoire, réduite à ce que la remise demande.
final class FakeSpotlightStore: SpotlightSyncStore, @unchecked Sendable {
    private let lock = NSLock()
    var rows: [String: String] = [:]
    var documents: [DocumentChange] = []
    var pages: [Int64: [IndexedPage]] = [:]

    func settingsRows() throws -> [String: String] {
        lock.lock(); defer { lock.unlock() }; return rows
    }

    func writeSetting(_ key: String, _ value: String) throws {
        lock.lock(); rows[key] = value; lock.unlock()
    }

    func documentsChanged(since: Double, limit: Int) throws -> [DocumentChange] {
        documents.filter { $0.indexedAt >= since }
            .sorted { ($0.indexedAt, $0.id) < ($1.indexedAt, $1.id) }
            .prefix(limit)
            .map { $0 }
    }

    func pageTexts(docID: Int64, limit: Int, fromPage: Int) throws -> [IndexedPage] {
        (pages[docID] ?? []).filter { $0.page >= fromPage }.prefix(limit).map { $0 }
    }
}

final class SpotlightSyncTests: XCTestCase {

    private func document(_ id: Int64, ext: String = "djvu",
                          state: DocState = .extracted,
                          at time: Double = 1_700_000_000) -> DocumentChange {
        DocumentChange(id: id, volUUID: "TEST-VOL", relPath: "Livres/\(id).\(ext)",
                       ext: ext, topFolder: "Livres", state: state,
                       ocrState: .notNeeded, indexedAt: time, scannedPages: 0)
    }

    private func store(_ documents: [DocumentChange]) -> FakeSpotlightStore {
        let store = FakeSpotlightStore()
        store.documents = documents
        for document in documents {
            store.pages[document.id] = [IndexedPage(page: 1, text: "azote et oxydation")]
        }
        return store
    }

    // MARK: - 1 · La première remise donne tout, après avoir tout effacé

    func testFirstRunHandsEverythingOverAndMovesTheMarker() throws {
        let store = store([document(1), document(2)])
        let donor = FakeDonor()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let report = try SpotlightSync.run(store: store, policy: SpotlightPolicy(),
                                           donor: donor, now: now)

        XCTAssertTrue(report.full)
        XCTAssertEqual(donor.deleteAllCalls, 1,
                       "une remise complète efface d'abord : c'est le seul geste "
                       + "qui retire les documents supprimés de la base")
        XCTAssertEqual(donor.indexed.map(\.identifier), ["doc:1", "doc:2"])
        XCTAssertEqual(report.indexed, 2)
        XCTAssertEqual(store.rows[SettingKeys.spotlightSyncedAt.key],
                       String(Int(now.timeIntervalSince1970)))
    }

    /// Le compte que la fenêtre de réglages affiche (audit BU-26). Il n'est
    /// écrit que par une remise QUI A DONNÉ quelque chose : sans cela, la
    /// première ouverture de Fouine suivant une remise complète — rien de neuf
    /// à donner — remplacerait « 1 527 documents » par « 0 document ».
    func testTheHandedOverCountIsWrittenAndKept() throws {
        let store = store([document(1), document(2)])
        let donor = FakeDonor()

        _ = try SpotlightSync.run(store: store, policy: SpotlightPolicy(),
                                  donor: donor,
                                  now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(store.rows[SettingKeys.spotlightSyncedCount.key], "2")

        // Une passe qui ne trouve rien de neuf laisse le compte en place.
        _ = try SpotlightSync.run(store: store, policy: SpotlightPolicy(),
                                  donor: donor,
                                  now: Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(store.rows[SettingKeys.spotlightSyncedCount.key], "2")

        // Le retrait remet tout à zéro : plus rien n'a été remis.
        try SpotlightSync.requestFullRebuild(store: store)
        XCTAssertEqual(store.rows[SettingKeys.spotlightSyncedCount.key], "0")
        XCTAssertEqual(store.rows[SettingKeys.spotlightSyncedAt.key], "0")
    }

    // MARK: - 2 · Ensuite, seulement ce qui a changé

    func testSecondRunOnlyHandsOverWhatChanged() throws {
        let store = store([document(1, at: 1_000), document(2, at: 2_000)])
        store.rows[SettingKeys.spotlightSyncedAt.key] = "1500"
        let donor = FakeDonor()

        let report = try SpotlightSync.run(store: store, policy: SpotlightPolicy(),
                                           donor: donor,
                                           now: Date(timeIntervalSince1970: 3_000))

        XCTAssertFalse(report.full)
        XCTAssertEqual(donor.deleteAllCalls, 0)
        XCTAssertEqual(donor.indexed.map(\.identifier), ["doc:2"])
    }

    // MARK: - 3 · Un document qui sort de la portée est retiré

    func testDocumentOutOfScopeIsRemoved() throws {
        // Un `.djvu` devenu illisible : plus rien à montrer dans Spotlight.
        let store = store([document(1, state: .failed, at: 2_000),
                           // Et un format que Spotlight lit lui-même.
                           document(2, ext: "docx", at: 2_000)])
        store.rows[SettingKeys.spotlightSyncedAt.key] = "1000"
        let donor = FakeDonor()

        let report = try SpotlightSync.run(store: store, policy: SpotlightPolicy(),
                                           donor: donor,
                                           now: Date(timeIntervalSince1970: 3_000))

        XCTAssertTrue(donor.indexed.isEmpty)
        XCTAssertEqual(donor.deleted.sorted(), ["doc:1", "doc:2"])
        XCTAssertEqual(report.deleted, 2)
    }

    // MARK: - 4 · Éteinte, ou sans bundle, la remise ne fait rien

    func testDisabledOrUnavailableDoesNothing() throws {
        let store = store([document(1)])
        let donor = FakeDonor()

        let off = try SpotlightSync.run(store: store,
                                        policy: SpotlightPolicy(enabled: false),
                                        donor: donor)
        XCTAssertEqual(off.skipped, .disabled)

        donor.available = false
        let noBundle = try SpotlightSync.run(store: store, policy: SpotlightPolicy(),
                                             donor: donor)
        XCTAssertEqual(noBundle.skipped, .unavailable)

        XCTAssertEqual(donor.deleteAllCalls, 0)
        XCTAssertTrue(donor.indexed.isEmpty)
        XCTAssertNil(store.rows[SettingKeys.spotlightSyncedAt.key],
                     "rien n'a été donné : le marqueur ne doit pas avancer")
    }

    // MARK: - 5 · Un lot plein n'avance le marqueur que jusqu'au dernier donné

    func testFullBatchStopsTheMarkerAtTheLastDocument() throws {
        let store = store([document(1, at: 1_000), document(2, at: 2_000),
                           document(3, at: 3_000)])
        store.rows[SettingKeys.spotlightSyncedAt.key] = "500"
        let donor = FakeDonor()

        _ = try SpotlightSync.run(store: store, policy: SpotlightPolicy(),
                                  donor: donor,
                                  now: Date(timeIntervalSince1970: 9_000), limit: 2)

        XCTAssertEqual(donor.indexed.map(\.identifier), ["doc:1", "doc:2"])
        XCTAssertEqual(store.rows[SettingKeys.spotlightSyncedAt.key], "2000",
                       "le troisième document doit rester à donner")
    }

    // MARK: - 6 · Une panne de Spotlight n'est pas une panne d'indexation

    func testDonorFailureNeverBreaksThePass() {
        let store = store([document(1)])
        let donor = FakeDonor()
        donor.failure = SpotlightFailure("Spotlight is busy")
        var lines: [String] = []

        // `afterPass` est ce qu'appellent les fins de passe : elle ne lève pas.
        SpotlightSync.afterPass(store: store, donor: donor) { lines.append($0) }

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("Spotlight: "), lines[0])
        XCTAssertNil(store.rows[SettingKeys.spotlightSyncedAt.key],
                     "le marqueur n'avance pas : la passe suivante refera la remise")
    }

    // MARK: - 7 · Le texte est lu par tranches jusqu'au plafond

    func testTextIsReadInChunksUpToTheLimit() throws {
        let store = FakeSpotlightStore()
        let page = String(repeating: "x", count: 100)
        store.pages[1] = (1...200).map { IndexedPage(page: $0, text: page) }

        let pages = try SpotlightSync.text(of: 1, store: store, limitBytes: 500)

        // Assez de pages pour dépasser le plafond (le constructeur coupe
        // ensuite), mais pas les deux cents : on ne charge pas un livre entier
        // pour en donner un demi-kilooctet.
        XCTAssertGreaterThan(pages.count, 4)
        XCTAssertLessThan(pages.count, 40)
    }
}
