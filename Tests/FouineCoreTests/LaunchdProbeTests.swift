// LaunchdProbeTests.swift — analyse des sorties launchctl et rapport doctor.
// B1-05 : validation sur fixtures capturées.

import Foundation
import XCTest
@testable import FouineCore

final class LaunchdProbeTests: XCTestCase {

    private let exConfigFixture = """
    gui/501/io.github.basedpolymer.fouine.agent = {
        active count = 0
        path = (null)
        state = spawn scheduled
        job state = spawn failed
        runs = 5
        last exit code = 78: EX_CONFIG
        program identifier = Contents/MacOS/FouineAgent (mode: 2)
        parent bundle identifier = io.github.basedpolymer.fouine
        parent bundle version = 1
        event triggers = { io.github.basedpolymer.fouine.agent => { descriptor = {
            "Executable" => "/Users/someone/Applications/Fouine.app/Contents/MacOS/FouineAgent"
        } } }
        properties = penalty box | resolve program | has LWCR
    }
    """

    private let runningFixture = """
    gui/501/io.github.basedpolymer.fouine.agent = {
        active count = 2
        path = /Library/LaunchAgents/io.github.basedpolymer.fouine.agent.plist
        state = running
        program = /Applications/Fouine.app/Contents/MacOS/FouineAgent
        runs = 1
        pid = 810
        last exit code = (never exited)
    }
    """

    func testParseEXConfigFixture() {
        let info = LaunchdServiceInfo.parse(exConfigFixture)
        XCTAssertEqual(info.state, "spawn scheduled")
        XCTAssertEqual(info.jobState, "spawn failed")
        XCTAssertEqual(info.runs, 5)
        XCTAssertEqual(info.lastExitCode, "78: EX_CONFIG")
        XCTAssertEqual(info.executablePath,
                       "/Users/someone/Applications/Fouine.app/Contents/MacOS/FouineAgent")
        XCTAssertNil(info.pid)
    }

    func testParseRunningFixture() {
        let info = LaunchdServiceInfo.parse(runningFixture)
        XCTAssertEqual(info.state, "running")
        XCTAssertNil(info.jobState)
        XCTAssertEqual(info.runs, 1)
        XCTAssertEqual(info.pid, 810)
        XCTAssertEqual(info.lastExitCode, "(never exited)")
        XCTAssertEqual(info.executablePath,
                       "/Applications/Fouine.app/Contents/MacOS/FouineAgent")
    }

    func testEvaluateSpawnFailedProducesExpectedGuidanceAndJSON() {
        let info = LaunchdServiceInfo.parse(exConfigFixture)
        let report = LaunchdAgentProbe.evaluate(
            result: .registered(info),
            status: nil
        )

        XCTAssertEqual(
            report.displayText,
            "registered, spawn failed (EX_CONFIG, 5 runs) — re-register it from Fouine.app ▸ “Keep the index up to date automatically”"
        )
        XCTAssertFalse(report.isHealthy)
        XCTAssertEqual(report.json["registered"] as? Bool, true)
        XCTAssertEqual(report.json["status"] as? String, "spawn_failed")
        XCTAssertEqual(report.json["failure_reason"] as? String, "EX_CONFIG")
        XCTAssertEqual(report.json["runs"] as? Int, 5)
        XCTAssertEqual(report.json["guidance"] as? String,
                       "re-register it from Fouine.app ▸ “Keep the index up to date automatically”")
    }

    func testEvaluateRunningWithFreshReport() {
        let info = LaunchdServiceInfo.parse(runningFixture)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // `AgentStatusRecord.isStale` vérifie que le pid du statut est VIVANT
        // (`kill(pid, 0)`) : un pid fixe rendait ce test dépendant de la
        // machine — 810 existait ici, pas sur le runner, qui concluait
        // « silent ». Le pid du processus de test est vivant partout ; celui
        // affiché vient de la fixture launchctl (810), pas du statut.
        let status = AgentStatusRecord(
            phase: .idle,
            detail: "idle",
            done: 0,
            total: 0,
            startedAt: now.addingTimeInterval(-100),
            updatedAt: now.addingTimeInterval(-12),
            pid: ProcessInfo.processInfo.processIdentifier
        )

        let report = LaunchdAgentProbe.evaluate(
            result: .registered(info),
            status: status,
            now: now
        )

        XCTAssertEqual(
            report.displayText,
            "registered, running (pid 810, last report 12 s ago)"
        )
        XCTAssertTrue(report.isHealthy)
        XCTAssertEqual(report.json["registered"] as? Bool, true)
        XCTAssertEqual(report.json["status"] as? String, "running")
        XCTAssertEqual(report.json["pid"] as? Int, 810)
        XCTAssertEqual(report.json["last_report_seconds"] as? Int, 12)
    }

    func testEvaluateRunningWithStaleReportYieldsSilent() {
        let info = LaunchdServiceInfo.parse(runningFixture)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Rapport vieux de 14 minutes (840 s)
        let status = AgentStatusRecord(
            phase: .idle,
            detail: "idle",
            done: 0,
            total: 0,
            startedAt: now.addingTimeInterval(-1_000),
            updatedAt: now.addingTimeInterval(-840),
            pid: 810
        )

        let report = LaunchdAgentProbe.evaluate(
            result: .registered(info),
            status: status,
            now: now
        )

        XCTAssertEqual(
            report.displayText,
            "registered but silent (no report for 14 min) — re-register it from Fouine.app ▸ “Keep the index up to date automatically”"
        )
        XCTAssertFalse(report.isHealthy)
        XCTAssertEqual(report.json["registered"] as? Bool, true)
        XCTAssertEqual(report.json["status"] as? String, "silent")
        XCTAssertEqual(report.json["last_report_seconds"] as? Int, 840)
    }

    func testEvaluateNotRegistered() {
        let report = LaunchdAgentProbe.evaluate(
            result: .notRegistered,
            status: nil
        )

        // AUCUN rapport : personne n'a jamais armé la mise à jour automatique,
        // ou l'utilisateur l'a éteinte. « Pas installé » n'est pas « cassé ».
        XCTAssertEqual(report.displayText, "not registered")
        XCTAssertTrue(report.isHealthy)
        XCTAssertEqual(report.json["registered"] as? Bool, false)
        XCTAssertEqual(report.json["status"] as? String, "not_registered")
        XCTAssertNil(report.json["last_report_seconds"])
    }

    /// PM-17, le cas REPRODUIT le 13/09/2026 : launchd ne connaît plus le
    /// service, mais `agent_status` porte la preuve que l'agent a tourné et
    /// vient de recevoir un SIGTERM. Il est TOMBÉ.
    func testEvaluateNotRegisteredWithAReportIsNotHealthy() {
        let now = Date()
        let status = AgentStatusRecord(
            phase: .stopped, detail: "signal-received(SIGTERM)",
            updatedAt: now.addingTimeInterval(-93), pid: 72_830)
        let report = LaunchdAgentProbe.evaluate(result: .notRegistered,
                                                status: status, now: now)

        XCTAssertFalse(report.isHealthy)
        XCTAssertEqual(report.displayText,
                       "not registered — last report 1 min ago (SIGTERM received)")
        // Les trois champs qui DISPARAISSAIENT exactement au moment où ils
        // disent quelque chose (`populateLaunchdFields` n'était pas appelée).
        XCTAssertEqual(report.json["last_report_seconds"] as? Int, 93)
        XCTAssertEqual(report.json["report_phase"] as? String, "stopped")
        XCTAssertEqual(report.json["report_alive"] as? Bool, false)
        // Rien de launchd : il n'y a pas d'enregistrement à décrire.
        XCTAssertNil(report.json["launchd_state"])
        XCTAssertNil(report.json["runs"])
    }

    func testEvaluateLaunchctlFailure() {
        let report = LaunchdAgentProbe.evaluate(
            result: .failed(error: "domain not accessible"),
            status: nil
        )

        XCTAssertEqual(report.displayText, "could not query launchd: domain not accessible")
        XCTAssertFalse(report.isHealthy)
        XCTAssertEqual(report.json["registered"] as? Bool, false)
        XCTAssertEqual(report.json["status"] as? String, "error")
    }
}
