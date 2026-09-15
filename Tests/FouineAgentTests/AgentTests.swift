// AgentTests.swift — tests de la machine d'états et du cycle de vie d'Agent (SPEC §5.7, audit C2-11).
// Propriété : A-Recette.

import Foundation
import XCTest
import FouineCore
import FouineCrawl
@testable import FouineAgent

final class AgentTests: XCTestCase {

    private var scratch: URL!
    private var dbURL: URL { scratch.appendingPathComponent("test-agent.db") }
    private var logURL: URL { scratch.appendingPathComponent("test-agent.log") }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-agent-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func makeSettingsSnapshot(
        extractJobs: Int = 2,
        ocrJobs: Int = 4,
        ocrLanguages: [String] = ["fr-FR", "en-US"],
        budgetMinutes: Int = 10,
        pollSeconds: Int = 60,
        requireAC: Bool = true,
        pauseLowPower: Bool = true,
        pauseThermal: Bool = true
    ) -> SettingsSnapshot {
        SettingsSnapshot(
            rows: [
                "agent.extractJobs": String(extractJobs),
                "ocr.jobs": String(ocrJobs),
                "ocr.languages": ocrLanguages.joined(separator: ","),
                "agent.ocrBudgetMinutes": String(budgetMinutes),
                "agent.pollSeconds": String(pollSeconds),
                "agent.requireAC": requireAC ? "true" : "false",
                "agent.pauseOnLowPower": pauseLowPower ? "true" : "false",
                "agent.pauseOnThermal": pauseThermal ? "true" : "false"
            ],
            environment: [:]
        )
    }

    // MARK: - Machine d'états : fonction de tick pure

    /// File vide : premier tick notifie la file vidée et publie `.idle`.
    /// Second tick avec file toujours vide : pas de seconde notification, mais
    /// `.idle` est REPUBLIÉ — c'est le battement qui tient `agent_status` à
    /// jour (péremption `AgentStatusRecord.staleAfter` = 5 min dans l'app).
    func testTickEmptyQueueNotifiesOnlyOnceAndPublishesIdle() {
        let settings = makeSettingsSnapshot(pollSeconds: 45)
        let state0 = AgentState(phase: .idle, hasNotifiedQueueDrained: false, pollPeriod: 45)
        let verdict = AgentConditions.Verdict(ok: true, blockers: [])

        // 1er tick : file vide
        let (action1, state1) = Agent.tick(
            state: state0,
            conditions: verdict,
            settings: settings,
            ocrQueueLength: 0
        )

        XCTAssertTrue(state1.hasNotifiedQueueDrained)
        XCTAssertEqual(state1.lastVerdict, AgentStatusDetail.queueDrained)
        let expectedAction1 = AgentAction.sequence([
            .publishStatus(phase: .idle, detail: AgentStatusDetail.queueDrained, done: nil, total: nil),
            .notifyQueueDrained,
            .sleep(seconds: 45)
        ])
        XCTAssertEqual(action1, expectedAction1)

        // 2nd tick : toujours vide
        let (action2, state2) = Agent.tick(
            state: state1,
            conditions: verdict,
            settings: settings,
            ocrQueueLength: 0
        )

        XCTAssertTrue(state2.hasNotifiedQueueDrained)
        let expectedAction2 = AgentAction.sequence([
            .publishStatus(phase: .idle, detail: AgentStatusDetail.queueDrained, done: nil, total: nil),
            .sleep(seconds: 45)
        ])
        XCTAssertEqual(action2, expectedAction2)
    }

    /// File non vide : réinitialise hasNotifiedQueueDrained
    func testTickNonEmptyQueueResetsNotificationFlag() {
        let settings = makeSettingsSnapshot()
        let state0 = AgentState(phase: .idle, hasNotifiedQueueDrained: true)
        let verdict = AgentConditions.Verdict(ok: false, blockers: ["no AC power"])

        let (_, state1) = Agent.tick(
            state: state0,
            conditions: verdict,
            settings: settings,
            ocrQueueLength: 10
        )

        XCTAssertFalse(state1.hasNotifiedQueueDrained)
    }

    /// Priorité absolue à l'extraction sur l'OCR
    func testTickPendingExtractionTakesPrecedenceOverOCR() {
        let settings = makeSettingsSnapshot()
        let state0 = AgentState(phase: .idle)
        let verdict = AgentConditions.Verdict(ok: true, blockers: [])

        let (action, state1) = Agent.tick(
            state: state0,
            conditions: verdict,
            settings: settings,
            ocrQueueLength: 100,
            pendingRoots: [12, 34]
        )

        XCTAssertEqual(action, .runExtraction(rootIDs: [12, 34]))
        XCTAssertEqual(state1.phase, state0.phase)
    }

    /// Transition secteur absent : publication .waiting avec le bloqueur et sommeil
    func testTickWithoutACPowerTransitionsToWaitingWithBlocker() {
        let settings = makeSettingsSnapshot(pollSeconds: 30)
        let state0 = AgentState(phase: .idle)
        let verdict = AgentConditions.Verdict(ok: false, blockers: ["no AC power"])

        let (action, state1) = Agent.tick(
            state: state0,
            conditions: verdict,
            settings: settings,
            ocrQueueLength: 25
        )

        XCTAssertEqual(state1.lastVerdict, "OCR waiting — no AC power")
        let expected = AgentAction.sequence([
            .publishStatus(phase: .waiting, detail: "no AC power", done: 0, total: 25),
            .sleep(seconds: 30)
        ])
        XCTAssertEqual(action, expected)
    }

    /// Transition économie d'énergie
    func testTickWithLowPowerModeTransitionsToWaitingWithBlocker() {
        let settings = makeSettingsSnapshot()
        let state0 = AgentState(phase: .idle)
        let verdict = AgentConditions.Verdict(ok: false, blockers: ["low power mode enabled"])

        let (action, state1) = Agent.tick(
            state: state0,
            conditions: verdict,
            settings: settings,
            ocrQueueLength: 15
        )

        XCTAssertEqual(state1.lastVerdict, "OCR waiting — low power mode enabled")
        let expected = AgentAction.sequence([
            .publishStatus(phase: .waiting, detail: "low power mode enabled", done: 0, total: 15),
            .sleep(seconds: 60)
        ])
        XCTAssertEqual(action, expected)
    }

    /// Transition thermique (CPU bridé ou thermalState)
    func testTickWithThermalThrottleTransitionsToWaitingWithBlocker() {
        let settings = makeSettingsSnapshot()
        let state0 = AgentState(phase: .idle)
        let verdict = AgentConditions.Verdict(ok: false, blockers: ["CPU throttled (46% < 70%)"])

        let (action, state1) = Agent.tick(
            state: state0,
            conditions: verdict,
            settings: settings,
            ocrQueueLength: 50
        )

        XCTAssertEqual(state1.lastVerdict, "OCR waiting — CPU throttled (46% < 70%)")
        let expected = AgentAction.sequence([
            .publishStatus(phase: .waiting, detail: "CPU throttled (46% < 70%)", done: 0, total: 50),
            .sleep(seconds: 60)
        ])
        XCTAssertEqual(action, expected)
    }

    /// Transition verrou tenu par un autre processus
    func testTickWithLockHeldElsewhereTransitionsToWaitingWithBlocker() {
        let settings = makeSettingsSnapshot()
        let state0 = AgentState(phase: .idle)
        let verdict = AgentConditions.Verdict(ok: false, blockers: ["write lock held by another process"])

        let (action, state1) = Agent.tick(
            state: state0,
            conditions: verdict,
            settings: settings,
            ocrQueueLength: 8
        )

        XCTAssertEqual(state1.lastVerdict, "OCR waiting — write lock held by another process")
        let expected = AgentAction.sequence([
            .publishStatus(phase: .waiting, detail: "write lock held by another process", done: 0, total: 8),
            .sleep(seconds: 60)
        ])
        XCTAssertEqual(action, expected)
    }

    /// Transition racines illisibles
    func testTickWithUnreadableRootsTransitionsToWaitingWithBlocker() {
        let settings = makeSettingsSnapshot()
        let state0 = AgentState(phase: .idle)
        let verdict = AgentConditions.Verdict(ok: false, blockers: ["unreadable root(s): Documents"])

        let (action, state1) = Agent.tick(
            state: state0,
            conditions: verdict,
            settings: settings,
            ocrQueueLength: 30
        )

        XCTAssertEqual(state1.lastVerdict, "OCR waiting — unreadable root(s): Documents")
        let expected = AgentAction.sequence([
            .publishStatus(phase: .waiting, detail: "unreadable root(s): Documents", done: 0, total: 30),
            .sleep(seconds: 60)
        ])
        XCTAssertEqual(action, expected)
    }

    /// Reprise : après attente, les 6 conditions sont réunies -> lot OCR lancé
    func testTickResumeWhenConditionsBecomeMetTransitionsToOCRBatch() {
        let settings = makeSettingsSnapshot(ocrJobs: 3, budgetMinutes: 5)
        let state0 = AgentState(phase: .waiting, lastVerdict: "OCR waiting — no AC power")
        let verdict = AgentConditions.Verdict(ok: true, blockers: [])

        let (action, state1) = Agent.tick(
            state: state0,
            conditions: verdict,
            settings: settings,
            ocrQueueLength: 120
        )

        XCTAssertTrue(state1.lockHeldBySelf)
        XCTAssertEqual(state1.lastVerdict, "OCR: the six conditions of §5.7 are met")
        let expected = AgentAction.sequence([
            .publishStatus(phase: .ocr, detail: AgentStatusDetail.pagesQueued(120),
                           done: 0, total: 120),
            .runOCRBatch(budgetMinutes: 5, jobs: 3, queuedPages: 120)
        ])
        XCTAssertEqual(action, expected)
    }

    /// Décision post-lot d'OCR : completed
    func testPostBatchTickCompletedTransitionsToIdleAndNotifiesQueueDrained() {
        let settings = makeSettingsSnapshot(pollSeconds: 30)
        let state0 = AgentState(phase: .ocr, lockHeldBySelf: true)

        let (action, state1) = Agent.postBatchTick(
            state: state0,
            outcome: .completed,
            remainingQueueLength: 0,
            settings: settings
        )

        XCTAssertFalse(state1.lockHeldBySelf)
        XCTAssertTrue(state1.hasNotifiedQueueDrained)
        XCTAssertEqual(state1.lastVerdict, AgentStatusDetail.queueDrained)
        let expected = AgentAction.sequence([
            .publishStatus(phase: .idle, detail: AgentStatusDetail.queueDrained, done: nil, total: nil),
            .notifyQueueDrained,
            .sleep(seconds: 30)
        ])
        XCTAssertEqual(action, expected)
    }

    /// Décision post-lot d'OCR : budget épuisé -> libération du verrou et enchaînement
    func testPostBatchTickBudgetExhaustedReleasesLockAndChainsNextTick() {
        let settings = makeSettingsSnapshot()
        let state0 = AgentState(phase: .ocr, lockHeldBySelf: true)

        let (action, state1) = Agent.postBatchTick(
            state: state0,
            outcome: .budgetExhausted,
            remainingQueueLength: 80,
            settings: settings
        )

        XCTAssertFalse(state1.lockHeldBySelf)
        XCTAssertFalse(state1.hasNotifiedQueueDrained)
        XCTAssertEqual(action, .none)
    }

    /// Horloge de scrutation : rotation du journal et changement de période
    func testTimerTickEnforcesLogRotationAndDetectsPollPeriodChange() {
        let settings0 = makeSettingsSnapshot(pollSeconds: 60)
        let state0 = AgentState(pollPeriod: 60)

        // Pas de changement de période
        let now = Date()
        let (actions0, state1) = Agent.timerTick(state: state0, clock: now, newSettings: settings0)
        XCTAssertEqual(actions0, [.enforceLogRotation])
        XCTAssertEqual(state1.pollPeriod, 60)
        XCTAssertEqual(state1.lastJournalRotationCheck, now)

        // Période changée à 120 s
        let settings1 = makeSettingsSnapshot(pollSeconds: 120)
        let (actions1, state2) = Agent.timerTick(state: state1, clock: now, newSettings: settings1)
        XCTAssertEqual(actions1, [.enforceLogRotation, .sleep(seconds: 120)])
        XCTAssertEqual(state2.pollPeriod, 120)
    }

    /// Arrêt demandé : tick retourne .none
    func testTickWhenStoppingReturnsNone() {
        let settings = makeSettingsSnapshot()
        let state = AgentState(isStopping: true)
        let verdict = AgentConditions.Verdict(ok: true, blockers: [])

        let (action, _) = Agent.tick(
            state: state,
            conditions: verdict,
            settings: settings,
            ocrQueueLength: 50
        )
        XCTAssertEqual(action, .none)
    }

    // MARK: - Cycle de vie de l'Agent et composants réels

    func testAgentInitPropertiesAreImmutableLet() throws {
        let log = AgentLog(url: logURL)
        let store = GRDBStore()
        try store.open(at: dbURL)

        let agent = Agent(log: log, store: store, onExit: { _ in })
        XCTAssertNotNil(agent.log)
        XCTAssertNotNil(agent.store)
        XCTAssertNotNil(agent.pipeline)
        XCTAssertNotNil(agent.settings)
        XCTAssertNotNil(agent.status)
        XCTAssertFalse(agent.isStopping)
    }

    func testAgentCanonicalResolvesSymlinks() {
        let canonicalTmp = Agent.canonical("/tmp")
        XCTAssertEqual(canonicalTmp, "/private/tmp")
    }

    func testAgentRefreshRootsDetectsReadableAndUnreadableRoots() throws {
        let log = AgentLog(url: logURL)
        let store = GRDBStore()
        try store.open(at: dbURL)

        let agent = Agent(log: log, store: store, onExit: { _ in })

        // Démarrage initial avec 0 racine configurée
        try agent.start(dbURL: dbURL)
        defer { agent.requestStop(signal: "SIGINT") }

        XCTAssertFalse(agent.isStopping)
    }

    func testAgentOCRTickWithEmptyQueuePublishesIdleStatus() throws {
        let log = AgentLog(url: logURL)
        let store = GRDBStore()
        try store.open(at: dbURL)

        let agent = Agent(log: log, store: store, onExit: { _ in })

        // ocrQueueLength vaut 0
        XCTAssertEqual(try store.ocrQueueLength(), 0)

        // ocrTick() doit s'exécuter, constater que la file est vide, et publier idle
        agent.ocrTick()

        let statusRecord = try store.agentStatus()
        XCTAssertNotNil(statusRecord)
        XCTAssertEqual(statusRecord?.phase, .idle)
        XCTAssertEqual(statusRecord?.detail, AgentStatusDetail.queueDrained)
    }

    func testAgentStartAndRequestStopWithInjectedOnExit() throws {
        let log = AgentLog(url: logURL)
        let store = GRDBStore()
        try store.open(at: dbURL)

        final class ExitBox: @unchecked Sendable {
            private let lock = NSLock()
            var code: Int32?
            func set(_ c: Int32) { lock.lock(); code = c; lock.unlock() }
            var get: Int32? { lock.lock(); defer { lock.unlock() }; return code }
        }

        let exitExpectation = expectation(description: "onExit called")
        let exitBox = ExitBox()

        let agent = Agent(log: log, store: store, onExit: { code in
            exitBox.set(code)
            exitExpectation.fulfill()
        })

        try agent.start(dbURL: dbURL)
        XCTAssertFalse(agent.isStopping)

        agent.requestStop(signal: "SIGTERM")
        wait(for: [exitExpectation], timeout: 5.0)

        XCTAssertTrue(agent.isStopping)
        XCTAssertEqual(exitBox.get, 0)

        // Statut publié : stopped
        let statusRecord = try store.agentStatus()
        XCTAssertNotNil(statusRecord)
        XCTAssertEqual(statusRecord?.phase, .stopped)
    }

    // MARK: - Tests supplémentaires d'intégration sur Agent

    func testAgentExecuteActions() throws {
        let log = AgentLog(url: logURL)
        let store = GRDBStore()
        try store.open(at: dbURL)

        let agent = Agent(log: log, store: store, onExit: { _ in })

        // Exécution de publishStatus avec done/total
        agent.execute(action: .publishStatus(phase: .waiting, detail: "battery low", done: 0, total: 10))
        var status = try store.agentStatus()
        XCTAssertEqual(status?.phase, .waiting)
        XCTAssertEqual(status?.detail, "battery low")

        // Exécution de sequence avec enforceLogRotation et idle
        agent.execute(action: .sequence([
            .enforceLogRotation,
            .publishStatus(phase: .idle, detail: AgentStatusDetail.queueDrained, done: nil, total: nil),
            .notifyQueueDrained
        ]))
        status = try store.agentStatus()
        XCTAssertEqual(status?.phase, .idle)
        XCTAssertEqual(status?.detail, AgentStatusDetail.queueDrained)
    }

    func testAgentWithRealRootAndFSEventsBatch() throws {
        let log = AgentLog(url: logURL)
        let store = GRDBStore()
        try store.open(at: dbURL)

        let rootDir = scratch.appendingPathComponent("my-root", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let testDoc = rootDir.appendingPathComponent("test.txt")
        try "hello world indexing test".write(to: testDoc, atomically: true, encoding: .utf8)

        let rootID = try store.addRoot(path: rootDir, label: "MyRoot")
        let rootRecord = try store.roots().first { $0.id == rootID }
        XCTAssertNotNil(rootRecord)
        guard let root = rootRecord else { return }

        let agent = Agent(log: log, store: store, onExit: { _ in })

        // refreshRoots avec racine présente
        agent.refreshRoots(announceAll: true)

        // rebuildWatchers
        agent.rebuildWatchers()

        // scheduleCatchUp
        agent.scheduleCatchUp()

        // drain de la file d'extraction
        agent.drain()

        // receive d'un batch FSEvents
        let batchNormal = FSEventsWatcher.Batch(
            paths: [testDoc.path],
            lastEventID: 1001,
            requiresFullDelta: false
        )
        agent.receive(batch: batchNormal, volUUID: root.volUUID)

        let batchFull = FSEventsWatcher.Batch(
            paths: [],
            lastEventID: 1002,
            requiresFullDelta: true
        )
        agent.receive(batch: batchFull, volUUID: root.volUUID)

        let batchUnmatched = FSEventsWatcher.Batch(
            paths: ["/private/var/unmatched/test.txt"],
            lastEventID: 1003,
            requiresFullDelta: false
        )
        agent.receive(batch: batchUnmatched, volUUID: root.volUUID)

        // drain à nouveau
        agent.drain()

        // arrêt propre des watchers
        agent.requestStop(signal: "SIGINT")
    }

    /// Une salve qui ne touche AUCUNE racine rend `fouine.lock` (A2-06).
    ///
    /// C'est le cas d'une racine déplacée (`docs/agent.md` § 4, ligne « matched
    /// no active root ») : le watcher vient de persister son curseur, donc
    /// d'écrire, donc de prendre le verrou. Ce chemin n'empile rien sur la file
    /// de travail — personne ne le rendait avant le tic suivant, et `fouine
    /// index` sortait en 3 pendant une minute sans qu'aucun travail ne tourne.
    func testUnmatchedFSEventsBurstReleasesTheWriteLock() throws {
        let log = AgentLog(url: logURL)
        let store = GRDBStore()
        try store.open(at: dbURL)

        let rootDir = scratch.appendingPathComponent("racine", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir,
                                                withIntermediateDirectories: true)
        try "texte".write(to: rootDir.appendingPathComponent("a.txt"),
                          atomically: true, encoding: .utf8)
        let rootID = try store.addRoot(path: rootDir, label: "Racine")
        let root = try XCTUnwrap(try store.roots().first { $0.id == rootID })

        let agent = Agent(log: log, store: store, onExit: { _ in })
        agent.refreshRoots(announceAll: true)

        // Le geste du watcher : persister le curseur passe par `writeLocked`.
        try store.setFSEventID(volUUID: root.volUUID, 4_242)
        let lock = FouinePaths.lockURL(for: dbURL)
        XCTAssertEqual(AgentConditions.lockAvailable(at: lock), false,
                       "une écriture doit avoir pris fouine.lock")

        agent.receive(batch: FSEventsWatcher.Batch(
            paths: ["/private/var/nulle-part/x.txt"], lastEventID: 7,
            requiresFullDelta: false), volUUID: root.volUUID)

        XCTAssertEqual(AgentConditions.lockAvailable(at: lock), true,
                       "A2-06 : le verrou est confisqué jusqu'au tic suivant")
    }
}

/// A2-12 — le journal de l'agent était noyé par une seule ligne.
///
/// Sur le journal réel de la machine du 01 au 03/09 (219 182 octets, 1 781
/// lignes), 44 % des lignes et 45 % des octets étaient `vocab_tri`, et les
/// lignes « OCR waiting — CPU_Speed_Limit N % » repartaient à chaque tic parce
/// que le pourcentage bougeait. Le journal est, de l'aveu de `docs/agent.md`
/// § 4, « le seul endroit où un incident est visible ».
final class AgentJournalNoiseTests: XCTestCase {

    private var scratch: URL!
    private var dbURL: URL { scratch.appendingPathComponent("bruit.db") }
    private var logURL: URL { scratch.appendingPathComponent("bruit.log") }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-agent-noise-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func journal() throws -> [String] {
        try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    /// Trois tics qui ne diffèrent QUE par le pourcentage : une seule ligne.
    func testThrottlingKeepsOnlyTheFirstOfAKind() throws {
        let log = AgentLog(url: logURL)
        let store = GRDBStore()
        try store.open(at: dbURL)
        let agent = Agent(log: log, store: store, onExit: { _ in })

        // La signature ne porte QUE la nature : c'est elle qui dédoublonne.
        let signature = "CPU_Speed_Limit below floor"
        for limit in [33, 28, 25] {
            agent.execute(
                action: .publishStatus(phase: .waiting,
                                       detail: "CPU_Speed_Limit \(limit)% (< 70%)",
                                       done: 0, total: 12),
                verdictSignature: signature)
        }

        let waiting = try journal().filter { $0.contains("OCR waiting") }
        XCTAssertEqual(waiting.count, 1,
                       "A2-12 : une ligne par tic, parce que le pourcentage "
                       + "changeait la signature\n" + waiting.joined(separator: "\n"))
        XCTAssertTrue(waiting[0].contains("33%"),
                      "la PREMIÈRE ligne garde son chiffre, elle est détaillée")
    }

    /// Un changement de NATURE, lui, reparle : c'est tout l'intérêt.
    func testANewKindOfBlockerIsLogged() throws {
        let log = AgentLog(url: logURL)
        let store = GRDBStore()
        try store.open(at: dbURL)
        let agent = Agent(log: log, store: store, onExit: { _ in })

        agent.execute(action: .publishStatus(phase: .waiting,
                                             detail: "CPU_Speed_Limit 33% (< 70%)",
                                             done: 0, total: 12),
                      verdictSignature: "CPU_Speed_Limit below floor")
        agent.execute(action: .publishStatus(phase: .waiting,
                                             detail: "no AC power",
                                             done: 0, total: 12),
                      verdictSignature: "no AC power")

        XCTAssertEqual(try journal().filter { $0.contains("OCR waiting") }.count, 2)
    }

    /// `Verdict.signature` ne porte plus de nombre : c'est la condition pour
    /// que le dédoublonnage tienne.
    func testSignatureCarriesNoMovingNumber() {
        let verdict = AgentConditions.Verdict(
            ok: false,
            blockers: ["CPU_Speed_Limit 33% (< 70%)", "no AC power"],
            kinds: ["CPU_Speed_Limit below floor", "no AC power"])
        XCTAssertEqual(verdict.signature,
                       "CPU_Speed_Limit below floor · no AC power")
        XCTAssertFalse(verdict.signature.contains("33"))
        // Le message DÉTAILLÉ, lui, garde le chiffre : c'est ce qu'on lit.
        XCTAssertTrue(verdict.blockers[0].contains("33%"))
    }
}

/// A2-09 — une lecture de curseur qui ÉCHOUE ne fabrique plus un crawl complet.
///
/// Le `try?` d'origine rendait « la base n'a pas répondu » indiscernable
/// d'« aucun curseur en base », et l'agent programmait alors un crawl delta de
/// toutes les racines en le journalisant comme s'il l'avait choisi. Le §5.7,
/// amendement du 03/09/2026 point 4, annonçait pourtant « suppression des
/// `try?` silencieux » : celui-ci avait survécu, et c'était le seul du fichier
/// dont la valeur de repli FABRIQUE du travail.
final class AgentCatchUpTests: XCTestCase {

    private enum Boom: Error { case databaseBusy }

    private func root(_ id: Int64, _ uuid: String) -> RootRecord {
        RootRecord(id: id, volUUID: uuid, relPath: "docs",
                   label: "Racine \(id)", enabled: true)
    }

    /// Curseur ABSENT : rattrapage, c'est le contrat d'origine.
    func testMissingCursorSchedulesACatchUp() {
        let roots = [root(1, "A"), root(2, "B")]
        var errors = 0
        let out = Agent.catchUpRoots(roots, cursor: { _ in 0 },
                                     onError: { _, _ in errors += 1 })
        XCTAssertEqual(out.sorted(), [1, 2])
        XCTAssertEqual(errors, 0)
    }

    /// Curseur PRÉSENT : rien à faire.
    func testKnownCursorSchedulesNothing() {
        let out = Agent.catchUpRoots([root(1, "A")], cursor: { _ in 4_242 },
                                     onError: { _, _ in XCTFail("aucune erreur") })
        XCTAssertTrue(out.isEmpty)
    }

    /// Lecture qui ÉCHOUE : journalisée, et RIEN n'est programmé.
    func testAFailedReadSchedulesNothingAndIsReported() {
        var reported: [String] = []
        let out = Agent.catchUpRoots([root(1, "A"), root(2, "B")],
                                     cursor: { _ in throw Boom.databaseBusy },
                                     onError: { r, _ in reported.append(r.label) })
        XCTAssertTrue(out.isEmpty,
                      "A2-09 : une base qui n'a pas répondu ne vaut pas « base neuve »")
        XCTAssertEqual(reported, ["Racine 1", "Racine 2"])
    }

    /// Une racine en échec n'empêche pas les autres d'être traitées.
    func testOneFailureDoesNotHideTheOthers() {
        var reported: [String] = []
        let out = Agent.catchUpRoots([root(1, "A"), root(2, "B")],
                                     cursor: { uuid in
                                         if uuid == "A" { throw Boom.databaseBusy }
                                         return 0
                                     },
                                     onError: { r, _ in reported.append(r.label) })
        XCTAssertEqual(out, [2])
        XCTAssertEqual(reported, ["Racine 1"])
    }

    /// Et sur l'agent réel, une base FERMÉE écrit un `warn` sans rien empiler.
    func testClosedStoreWarnsInTheJournal() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-catchup-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let logURL = scratch.appendingPathComponent("fouine.log")
        let log = AgentLog(url: logURL)

        _ = Agent.catchUpRoots([root(1, "A")],
                               cursor: { _ in throw Boom.databaseBusy },
                               onError: { r, error in
                                   log.warn("cannot read the FSEvents cursor of root "
                                            + "“\(r.label)”: \(AgentText.describe(error))")
                               })
        let journal = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(journal.contains("warn"), journal)
        XCTAssertTrue(journal.contains("FSEvents cursor"), journal)
    }
}

