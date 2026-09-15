// LockWaitTests.swift — tests d'annonce immédiate du verrou avant d'attendre (audit H4, B1-26).
// Propriété : A-Core. SPEC §5.1.

import XCTest
@testable import FouineCore

private final class WaitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    private var holder: LockHolder?
    private var timeout: TimeInterval = 0
    private var elapsed: TimeInterval = 0
    private let startDate = Date()

    func record(holder: LockHolder, timeout: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        called = true
        self.holder = holder
        self.timeout = timeout
        self.elapsed = Date().timeIntervalSince(startDate)
    }

    var wasCalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return called
    }

    var recordedHolder: LockHolder? {
        lock.lock(); defer { lock.unlock() }
        return holder
    }

    var recordedElapsed: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return elapsed
    }
}

final class LockWaitTests: XCTestCase {

    func testLockWaitHandlerIsCalledImmediatelyWhenLockIsHeld() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-lockwait-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("test.db")
        let lockURL = FouinePaths.lockURL(for: dbURL)

        let store = GRDBStore()
        try store.open(at: dbURL)

        // Un second descripteur / lock prend le verrou simulant l'agent
        let rival = ExclusiveLock(path: lockURL.path)
        rival.setRole(.agent)
        try rival.acquire(timeout: 1)
        defer { rival.release() }

        let recorder = WaitRecorder()
        store.setWriteLockWaitHandler { h, timeout in
            recorder.record(holder: h, timeout: timeout)
        }

        // Tente d'acquérir le verrou (qui est tenu) avec un timeout court de 0.3 s
        let start = Date()
        XCTAssertThrowsError(try store.acquireWriteLock(as: .cli, timeout: 0.3)) { error in
            guard case FouineError.databaseFailure(let msg) = error else {
                XCTFail("Attendu databaseFailure, obtenu \(error)")
                return
            }
            XCTAssertTrue(WriteLock.isBusy(error))
            XCTAssertTrue(msg.contains("fouine-lock-busy"))
        }
        let elapsed = Date().timeIntervalSince(start)

        // Vérifie que le gestionnaire a bien été appelé IMMÉDIATEMENT (dans les premiers 100 ms, bien avant les 0.3s)
        XCTAssertTrue(recorder.wasCalled, "Le gestionnaire d'attente aurait dû être appelé")
        XCTAssertLessThan(recorder.recordedElapsed, 0.15, "L'annonce doit être faite immédiatement avant d'attendre")
        XCTAssertEqual(recorder.recordedHolder?.pid, getpid())
        XCTAssertEqual(recorder.recordedHolder?.role, .agent)
        XCTAssertGreaterThanOrEqual(elapsed, 0.25)
    }

    func testLockAcquisitionSucceedsIfReleasedDuringWait() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-lockwait-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("test.db")
        let lockURL = FouinePaths.lockURL(for: dbURL)

        let store = GRDBStore()
        try store.open(at: dbURL)

        // Un second lock prend le verrou
        let rival = ExclusiveLock(path: lockURL.path)
        rival.setRole(.agent)
        try rival.acquire(timeout: 1)

        let recorder = WaitRecorder()
        store.setWriteLockWaitHandler { h, timeout in
            recorder.record(holder: h, timeout: timeout)
        }

        // Libère le verrou au bout de 100 ms dans un fil d'arrière-plan
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            rival.release()
        }

        // L'acquisition attend le verrou avec un timeout de 2.0 s et doit réussir
        XCTAssertNoThrow(try store.acquireWriteLock(as: .cli, timeout: 2.0))
        XCTAssertTrue(recorder.wasCalled, "L'annonce d'attente a bien été faite au début")
        store.releaseWriteLock()
    }
}
