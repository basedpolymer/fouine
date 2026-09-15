// FouineAgent — indexation en arrière-plan (SPEC §5.7, §10). Propriété : A-Pack.
//
// Enregistré par `SMAppService.agent(plistName: "io.github.basedpolymer.fouine.agent.plist")`
// depuis l'interrupteur de Fouine.app — JAMAIS par un plist déposé à la main
// (§5.7), et JAMAIS avant que l'app ait obtenu l'autorisation TCC (§11.2) : un
// agent sans interface ne peut pas faire apparaître l'invite, il serait refusé
// en silence.
//
// Pas d'interface, pas de sortie terminal : tout passe par
// ~/Library/Logs/Fouine/fouine.log.

import Foundation
import Dispatch

let agentLog = AgentLog(url: AgentPaths.logURL())
agentLog.captureStandardStreams()
agentLog.info("——— FouineAgent starting (pid "
              + "\(ProcessInfo.processInfo.processIdentifier)) ———")

let agent = Agent(log: agentLog)
do {
    try agent.start()
} catch {
    agentLog.error("cannot start: \(AgentText.describe(error))")
    agentLog.error("exit 0 ON PURPOSE: with KeepAlive/SuccessfulExit=false, "
                   + "exiting with an error would restart the agent in a loop. "
                   + "Fix the cause, then turn background indexing back on from "
                   + "Fouine.app.")
    exit(0)
}

// launchd arrête un agent par SIGTERM et tue à 20 s. SIGINT sert au test manuel.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM,
                                              queue: .global(qos: .utility))
sigterm.setEventHandler { agent.requestStop(signal: "SIGTERM") }
sigterm.resume()

let sigint = DispatchSource.makeSignalSource(signal: SIGINT,
                                             queue: .global(qos: .utility))
sigint.setEventHandler { agent.requestStop(signal: "SIGINT") }
sigint.resume()

dispatchMain()
