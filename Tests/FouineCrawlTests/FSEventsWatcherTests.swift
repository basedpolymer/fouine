// FSEventsWatcherTests.swift — salves, curseur, bascule en crawl delta complet
// (SPEC §5.2). Propriété : A-Ingest.
//
// `deliver` est exercé directement : un test qui attendrait de vrais événements
// du noyau serait lent et instable, alors que la logique à protéger (curseur
// persisté à chaque lot, drapeaux de purge d'historique) est purement locale.

import XCTest
import CoreServices
import FouineCore
@testable import FouineCrawl

/// Boîte verrouillée : les salves peuvent arriver sur la file du flux.
final class BatchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FSEventsWatcher.Batch] = []
    func append(_ batch: FSEventsWatcher.Batch) {
        lock.lock(); storage.append(batch); lock.unlock()
    }
    var batches: [FSEventsWatcher.Batch] {
        lock.lock(); defer { lock.unlock() }; return storage
    }
}

final class FSEventsWatcherTests: XCTestCase {

    let volUUID = "75F6E680-A01E-49E2-A130-1800826B45AA"

    func makeWatcher(store: InMemoryStore, box: BatchBox) -> FSEventsWatcher {
        FSEventsWatcher(roots: [URL(fileURLWithPath: NSTemporaryDirectory())],
                        volUUID: volUUID, store: store,
                        onBatch: { box.append($0) })
    }

    func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fouine-fsevents-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        return root
    }

    func testLatencyIsThreeSeconds() {
        XCTAssertEqual(FSEventsWatcher.defaultLatency, 3.0)
    }

    func testBatchPersistsCursorAtEachLot() throws {
        let store = InMemoryStore()
        let box = BatchBox()
        let watcher = makeWatcher(store: store, box: box)

        watcher.deliver(paths: ["/a/x.pdf", "/a/y.pdf"], flags: [0, 0], ids: [41, 42])
        XCTAssertEqual(box.batches.count, 1)
        XCTAssertEqual(box.batches[0].paths, ["/a/x.pdf", "/a/y.pdf"])
        XCTAssertFalse(box.batches[0].requiresFullDelta)
        XCTAssertEqual(box.batches[0].lastEventID, 42)
        XCTAssertEqual(try store.fseventID(volUUID: volUUID), 42)

        watcher.deliver(paths: ["/a/z.pdf"], flags: [0], ids: [99])
        XCTAssertEqual(try store.fseventID(volUUID: volUUID), 99)
        XCTAssertEqual(watcher.currentEventID, 99)
    }

    func testRescanFlagsRequireAFullDelta() {
        for flag in [kFSEventStreamEventFlagMustScanSubDirs,
                     kFSEventStreamEventFlagUserDropped,
                     kFSEventStreamEventFlagKernelDropped,
                     kFSEventStreamEventFlagEventIdsWrapped,
                     kFSEventStreamEventFlagRootChanged,
                     kFSEventStreamEventFlagUnmount] {
            XCTAssertTrue(
                FSEventsWatcher.requiresFullDelta(flags: FSEventStreamEventFlags(flag)),
                "drapeau \(flag)")
        }
        XCTAssertFalse(FSEventsWatcher.requiresFullDelta(
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)))
    }

    func testDroppedEventsAskForAFullDelta() {
        let store = InMemoryStore()
        let box = BatchBox()
        let watcher = makeWatcher(store: store, box: box)
        watcher.deliver(
            paths: ["/a"],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)],
            ids: [7])
        XCTAssertEqual(box.batches.count, 1)
        XCTAssertTrue(box.batches[0].requiresFullDelta)
    }

    /// A3-03 : `HistoryDone` marque la FIN du rejeu, ce n'est pas un symptôme.
    /// Seul, il ne demande RIEN — le §5.2 y voyait un historique purgé, et c'est
    /// en réalité le démarrage ordinaire d'un agent quand rien n'a bougé. Une
    /// vraie perte porte un drapeau (`testDroppedEventsAskForAFullDelta`).
    /// L'événement lui-même n'est jamais un chemin à traiter.
    func testHistoryDoneWithoutEventsAsksForNothing() {
        let store = InMemoryStore()
        let box = BatchBox()
        let watcher = makeWatcher(store: store, box: box)
        watcher.deliver(
            paths: [""],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)],
            ids: [0])
        XCTAssertTrue(box.batches.isEmpty)
    }

    /// Et une perte d'historique RÉELLE reste vue, `HistoryDone` ou pas : c'est
    /// le drapeau qui parle.
    func testHistoryDoneWithADroppedFlagStillAsksForAFullDelta() {
        let store = InMemoryStore()
        let box = BatchBox()
        let watcher = makeWatcher(store: store, box: box)
        watcher.deliver(
            paths: ["/a", ""],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped),
                    FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)],
            ids: [5, 6])
        XCTAssertEqual(box.batches.count, 1)
        XCTAssertTrue(box.batches[0].requiresFullDelta)
    }

    func testHistoryDoneAfterRealEventsDoesNotAskForAFullDelta() {
        let store = InMemoryStore()
        let box = BatchBox()
        let watcher = makeWatcher(store: store, box: box)
        watcher.deliver(
            paths: ["/a/x.pdf", ""],
            flags: [0, FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)],
            ids: [10, 11])
        XCTAssertEqual(box.batches.count, 1)
        XCTAssertFalse(box.batches[0].requiresFullDelta)
        XCTAssertEqual(box.batches[0].paths, ["/a/x.pdf"])
    }

    /// A3-03, LA MESURE. Un curseur VALIDE et rien qui ait bougé sur le disque :
    /// c'est le démarrage ordinaire de l'agent, plusieurs fois par jour. FSEvents
    /// livre alors `HistoryDone` sans le moindre événement de fichier — ce qui,
    /// jusqu'au 04/09/2026, déclenchait un crawl delta COMPLET de toutes les
    /// racines. Aucun drapeau de perte n'accompagne cette salve : le cas est donc
    /// bien distinct d'un historique réellement tronqué, que FSEvents signale par
    /// `MustScanSubDirs` / `UserDropped` / `KernelDropped`.
    ///
    /// Le flux est un VRAI flux : c'est tout l'objet du test, `deliver` ne peut
    /// pas prouver ce que le système livre.
    func testAQuietRestartOnAValidCursorAsksForNothing() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // La CRÉATION de la racine est elle-même un événement, et fseventsd ne
        // lui attribue son identifiant qu'avec un peu de retard : sans cette
        // pause, `FSEventsGetCurrentEventId()` rend un curseur ANTÉRIEUR à
        // l'événement de création, et le flux le rejoue (mesuré : deux salves).
        usleep(400_000)

        let store = InMemoryStore()
        // Curseur valide (≤ celui du système) et à jour : rien ne s'est passé
        // depuis. `resuming` sera vrai, `sawFileEvents` faux.
        try store.setFSEventID(volUUID: volUUID,
                               UInt64(FSEventsGetCurrentEventId()))

        let box = BatchBox()
        let quiet = expectation(description: "aucune salve")
        quiet.isInverted = true
        // Un `fulfill` de trop sur une attente satisfaite est une
        // NSInternalInconsistencyException qui tue TOUT le processus de test
        // (piège déjà rencontré ci-dessous, gate du 03/09/2026) — et le code
        // d'AVANT ce lot en livrait bien deux.
        quiet.assertForOverFulfill = false
        let watcher = FSEventsWatcher(roots: [root], volUUID: volUUID, store: store,
                                      latency: 0.05,
                                      onBatch: { batch in
            box.append(batch)
            quiet.fulfill()
        })
        try watcher.start()
        defer { watcher.stop() }

        wait(for: [quiet], timeout: 3)
        XCTAssertTrue(box.batches.isEmpty,
                      "un démarrage sans changement ne doit rien demander : "
                      + "\(box.batches.map(\.requiresFullDelta))")
    }

    /// Identifiant enregistré plus récent que celui du système : il est invalide,
    /// le suivi incrémental ne peut pas reprendre.
    func testInvalidStoredCursorAsksForAFullDeltaAtStart() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = InMemoryStore()
        try store.setFSEventID(volUUID: volUUID, UInt64.max - 1)

        let arrived = expectation(description: "salve de rattrapage")
        // Un curseur invalide provoque DEUX rappels FSEvents rapprochés (la
        // demande de rescan, puis `HistoryDone`), chacun livré comme salve de
        // rattrapage : le second peut arriver entre `wait` et `stop()`. Un
        // `fulfill` de trop est alors une NSInternalInconsistencyException qui
        // tue TOUT le processus de test (vu au gate du 03/09/2026), pas un échec.
        arrived.assertForOverFulfill = false
        let box = BatchBox()
        // On attend LA salve qui demande le parcours complet, pas la première
        // venue : sous une machine saturée (charge 60 au gate du 05/09/2026),
        // une salve ordinaire peut la précéder, et lire `batches.first` faisait
        // échouer le test sans qu'aucun comportement du veilleur ait changé.
        let watcher = FSEventsWatcher(roots: [root], volUUID: volUUID, store: store,
                                      onBatch: { batch in
            box.append(batch)
            if batch.requiresFullDelta { arrived.fulfill() }
        })
        try watcher.start()
        defer { watcher.stop() }
        wait(for: [arrived], timeout: 10)
        XCTAssertTrue(box.batches.contains { $0.requiresFullDelta })
    }

    // MARK: - Curseur posé dès le démarrage (§5.2)

    /// Sans curseur de démarrage, `volumes.fsevent_id` reste à 0 tant qu'aucune
    /// salve n'arrive, et chaque redémarrage de l'agent repart en crawl delta
    /// complet de toutes les racines.
    func testStartPersistsTheCursorWithoutWaitingForABatch() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = InMemoryStore()
        XCTAssertEqual(try store.fseventID(volUUID: volUUID), 0)

        let watcher = FSEventsWatcher(roots: [root], volUUID: volUUID,
                                      store: store, onBatch: { _ in })
        try watcher.start()
        defer { watcher.stop() }

        let cursor = try store.fseventID(volUUID: volUUID)
        XCTAssertGreaterThan(cursor, 0)
        XCTAssertGreaterThanOrEqual(watcher.currentEventID, cursor)
    }

    /// L'arbitrage du curseur de démarrage : sur-couvrir est inoffensif,
    /// sous-couvrir perd des modifications.
    func testStartupCursorNeverOverwritesAResumedCursor() {
        // Base neuve : on pose « maintenant ».
        XCTAssertEqual(FSEventsWatcher.startupCursor(stored: 0, current: 900), 900)
        // Reprise valide : la base porte un curseur plus ancien, on n'y touche pas
        // — le flux est en train de rejouer cette fenêtre.
        XCTAssertNil(FSEventsWatcher.startupCursor(stored: 500, current: 900))
        XCTAssertNil(FSEventsWatcher.startupCursor(stored: 900, current: 900))
        // Identifiant invalide (historique purgé) : le flux repart de maintenant,
        // le curseur aussi.
        XCTAssertEqual(FSEventsWatcher.startupCursor(stored: 901, current: 900), 900)
    }

    func testStartAndStop() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = FSEventsWatcher(roots: [root], volUUID: volUUID,
                                      store: InMemoryStore(), onBatch: { _ in })
        XCTAssertFalse(watcher.isRunning)
        try watcher.start()
        XCTAssertTrue(watcher.isRunning)
        watcher.stop()
        XCTAssertFalse(watcher.isRunning)
    }

    func testNoRootsIsRefused() {
        let watcher = FSEventsWatcher(roots: [], volUUID: volUUID,
                                      store: InMemoryStore(), onBatch: { _ in })
        XCTAssertThrowsError(try watcher.start())
    }

    /// C2-10 : 50 cycles start/stop rapprochés avec des événements réels.
    /// Aucun plantage, aucun rappel après stop(), et deinit observé (weak ref).
    func testFiftyStartStopCyclesWithRealEvents() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        final class AtomicCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() {
                lock.lock(); count += 1; lock.unlock()
            }
            var value: Int {
                lock.lock(); defer { lock.unlock() }; return count
            }
        }

        final class StoppedFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var isStopped = false
            func set() { lock.lock(); isStopped = true; lock.unlock() }
            var get: Bool { lock.lock(); defer { lock.unlock() }; return isStopped }
        }

        let postStopCounter = AtomicCounter()

        for cycle in 0..<50 {
            weak var weakWatcher: FSEventsWatcher?
            let stopped = StoppedFlag()

            try {
                let store = InMemoryStore()
                let watcher = FSEventsWatcher(
                    roots: [root],
                    volUUID: volUUID,
                    store: store,
                    latency: 0.01,
                    onBatch: { _ in
                        if stopped.get {
                            postStopCounter.increment()
                        }
                    }
                )
                weakWatcher = watcher
                try watcher.start()

                let fileURL = root.appendingPathComponent("event-\(cycle).txt")
                try "test-\(cycle)".write(to: fileURL, atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: fileURL)

                watcher.stop()
                stopped.set()
            }()

            // Vérifie que l'instance est bien déallouée (aucun cycle de rétention /
            // fuite). La libération du contexte par FSEvents suit `Invalidate`
            // de façon ASYNCHRONE sur la file du flux : sous `--parallel` (huit
            // xctest en concurrence, gate du 03/09/2026) 100 ms ne suffisaient
            // pas. On prouve que le watcher meurt, pas qu'il meurt vite : 3 s.
            var deallocated = false
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if weakWatcher == nil {
                    deallocated = true
                    break
                }
                usleep(5_000) // 5 ms
            }
            XCTAssertTrue(deallocated, "deinit non observé au cycle \(cycle)")
        }

        // Vérifie qu'aucun rappel n'a été délivré après stop()
        XCTAssertEqual(postStopCounter.value, 0, "Des rappels ont été délivrés après stop()")
    }
}
