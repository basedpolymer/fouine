// AgentStateMachineTests.swift — tests de la machine à états de l'agent.
// B1-05 : machine à états pure sans launchd réel.

import Foundation
import ServiceManagement
import XCTest
import FouineCore
@testable import FouineApp

final class AgentStateMachineTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testEnabledWithNoStatusAndNoTimestampIsRegisteredButSilent() {
        // App ouverte avec agent déjà activé antérieurement, mais aucun rapport en base
        let state = AgentStateMachine.evaluate(
            serviceStatus: .enabled,
            switchEnabled: true,
            agentStatus: nil,
            enabledAt: nil,
            now: now
        )
        XCTAssertEqual(state, .registeredButSilent)
    }

    func testEnabledWithNoStatusWithinFiveMinutesIsWaitingFirstReport() {
        // Interrupteur tout juste armé (30 s avant maintenant)
        let enabledAt = now.addingTimeInterval(-30)
        let state = AgentStateMachine.evaluate(
            serviceStatus: .enabled,
            switchEnabled: true,
            agentStatus: nil,
            enabledAt: enabledAt,
            now: now
        )
        XCTAssertEqual(state, .waitingFirstReport)
    }

    func testEnabledWithNoStatusPastFiveMinutesIsRegisteredButSilent() {
        // Armé il y a 6 minutes sans jamais avoir publié
        let enabledAt = now.addingTimeInterval(-360)
        let state = AgentStateMachine.evaluate(
            serviceStatus: .enabled,
            switchEnabled: true,
            agentStatus: nil,
            enabledAt: enabledAt,
            now: now
        )
        XCTAssertEqual(state, .registeredButSilent)
    }

    func testEnabledWithFreshStatusIsActive() {
        // Rapport publié il y a 15 s par un processus vivant
        let record = AgentStatusRecord(
            phase: .crawl,
            detail: "Livres",
            done: 10,
            total: 100,
            startedAt: now.addingTimeInterval(-60),
            updatedAt: now.addingTimeInterval(-15),
            pid: getpid()
        )
        let state = AgentStateMachine.evaluate(
            serviceStatus: .enabled,
            switchEnabled: true,
            agentStatus: record,
            enabledAt: now.addingTimeInterval(-100),
            now: now
        )
        XCTAssertEqual(state, .active)
    }

    func testEnabledWithStaleStatusIsRegisteredButSilent() {
        // Rapport figé depuis 10 minutes
        let record = AgentStatusRecord(
            phase: .ocr,
            detail: "page.pdf",
            done: 5,
            total: 50,
            startedAt: now.addingTimeInterval(-1_000),
            updatedAt: now.addingTimeInterval(-600),
            pid: getpid()
        )
        let state = AgentStateMachine.evaluate(
            serviceStatus: .enabled,
            switchEnabled: true,
            agentStatus: record,
            enabledAt: now.addingTimeInterval(-1_000),
            now: now
        )
        XCTAssertEqual(state, .registeredButSilent)
    }

    func testDisarmedSwitchIsOffEvenIfServiceStatusIsEnabled() {
        // Interrupteur éteint dans l'app
        let state = AgentStateMachine.evaluate(
            serviceStatus: .enabled,
            switchEnabled: false,
            agentStatus: nil,
            enabledAt: nil,
            now: now
        )
        XCTAssertEqual(state, .off)
    }

    func testNotRegisteredIsOff() {
        let state = AgentStateMachine.evaluate(
            serviceStatus: .notRegistered,
            switchEnabled: false,
            agentStatus: nil,
            enabledAt: nil,
            now: now
        )
        XCTAssertEqual(state, .off)
    }

    func testRequiresApprovalIsRequiresApproval() {
        let state = AgentStateMachine.evaluate(
            serviceStatus: .requiresApproval,
            switchEnabled: true,
            agentStatus: nil,
            enabledAt: now,
            now: now
        )
        XCTAssertEqual(state, .requiresApproval)
    }

    func testNotFoundIsNotFound() {
        let state = AgentStateMachine.evaluate(
            serviceStatus: .notFound,
            switchEnabled: false,
            agentStatus: nil,
            enabledAt: nil,
            now: now
        )
        XCTAssertEqual(state, .notFound)
    }
}
