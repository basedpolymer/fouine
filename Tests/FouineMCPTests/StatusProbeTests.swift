// StatusProbeTests.swift — vérification du cache et du court-circuit de la sonde launchd.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available

import Foundation
import XCTest
import FouineCore
import FouineMCP
import FouineMCPKit

final class StatusProbeTests: XCTestCase {

    func testIncludeAgentFalseNeverCallsProbe() throws {
        let index = try TempIndex()
        let store = ReadOnlyStore(path: index.databaseURL)
        let semantic = SemanticEngine(store: store, modelDirectory: index.directory)

        var probeCallCount = 0
        let statusTool = StatusTool(
            store: store,
            semantic: semantic,
            modelDirectory: index.directory,
            launchdProbe: {
                probeCallCount += 1
                return .notRegistered
            }
        )

        let result = try statusTool.call(arguments: ["include_agent": false])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(probeCallCount, 0, "include_agent: false ne doit JAMAIS appeler la sonde launchd")
        let agent = result.structured["agent"] as? [String: Any]
        XCTAssertEqual(agent?["queried"] as? Bool, false)
    }

    func testProbeIsCachedForSixtySeconds() throws {
        let index = try TempIndex()
        let store = ReadOnlyStore(path: index.databaseURL)
        let semantic = SemanticEngine(store: store, modelDirectory: index.directory)

        var simulatedTime = Date()
        var probeCallCount = 0
        let statusTool = StatusTool(
            store: store,
            semantic: semantic,
            modelDirectory: index.directory,
            launchdProbe: {
                probeCallCount += 1
                return .notRegistered
            },
            cacheTTL: 60,
            now: { simulatedTime }
        )

        // 1er appel : la sonde doit être appelée
        _ = try statusTool.call(arguments: ["include_agent": true])
        XCTAssertEqual(probeCallCount, 1)

        // 2e appel 30 s plus tard : servi depuis le cache
        simulatedTime.addTimeInterval(30)
        _ = try statusTool.call(arguments: ["include_agent": true])
        XCTAssertEqual(probeCallCount, 1, "la sonde doit être en cache 60 s")

        // 3e appel 61 s plus tard : le cache a expiré, la sonde est rappelée
        simulatedTime.addTimeInterval(31) // total +61 s
        _ = try statusTool.call(arguments: ["include_agent": true])
        XCTAssertEqual(probeCallCount, 2, "après expiration du cache (60 s), la sonde doit être réévaluée")
    }

    /// Ce que l'agent DIT qu'il fait arrive au modèle en ANGLAIS (audit
    /// A1m-10). `agent_status.detail` est un jeton sans langue : « 
    /// pages-queued(20226) » ne veut rien dire pour un modèle, et une phrase
    /// française écrite par un agent d'une version antérieure — le cas relevé
    /// sur la machine du mainteneur — n'a rien à faire dans une sortie anglaise.
    func testAgentReportDetailIsRenderedInEnglish() throws {
        let index = try TempIndex()
        let store = GRDBStore()
        try store.open(at: index.databaseURL)
        try store.writeAgentStatus(AgentStatusRecord(
            phase: .ocr, detail: AgentStatusDetail.pagesQueued(20226),
            done: 0, total: 20226))
        store.releaseWriteLock()

        let readOnly = ReadOnlyStore(path: index.databaseURL)
        let tool = StatusTool(
            store: readOnly,
            semantic: SemanticEngine(store: readOnly, modelDirectory: index.directory),
            modelDirectory: index.directory,
            launchdProbe: { .notRegistered })
        let agent = try XCTUnwrap(
            tool.call(arguments: [:]).structured["agent"] as? [String: Any])
        XCTAssertEqual(agent["report_detail"] as? String, "20226 page(s) queued")
    }
}
