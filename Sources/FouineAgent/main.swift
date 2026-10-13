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

import AppKit
import Foundation
import Dispatch
import PDFKit

// PREMIÈRE INSTRUCTION EXÉCUTABLE, et elle doit le rester. L'agent vit dans
// Contents/MacOS du bundle de l'app : Bundle.main lui donne donc l'Info.plist
// de Fouine.app, qui n'a ni LSUIElement ni LSBackgroundOnly — et ne doit pas en
// avoir, c'est l'Info.plist d'une vraie application. La PREMIÈRE instanciation
// de PDFDocument (même vide) fait alors un check-in LaunchServices en
// « Foreground » : le Dock ouvre une SECONDE tuile « Fouine », sans point, la
// fait rebondir quelques secondes, puis la garde morte toute la vie du
// processus — une fois par agent, donc à chaque ouverture de session, bascule
// de l'interrupteur ou relance par launchd (AUDIT-DK, 13/10/2026).
//
// Posée AVANT tout travail, la politique d'activation évite le check-in ; posée
// après, elle ne fait que rétrograder une inscription déjà vue du Dock. Elle
// couvre d'avance tout autre cadre qui s'inscrirait (Vision, CoreML, un futur
// lecteur), pas seulement PDFKit. Elle ne touche PAS l'identité du bundle :
// c'est elle qui porte les autorisations TCC de l'agent (Documents, accès
// complet au disque, reconnaissance vocale), accordées à
// io.github.basedpolymer.fouine. `make ci-bundle-dock` échoue si cette ligne
// disparaît.
let dockPolicyApplied = NSApplication.shared.setActivationPolicy(.prohibited)

// Mode réservé au contrôle de bundle (`make ci-bundle-dock`) : toucher PDFKit,
// le dire, rester vivant le temps que `lsappinfo` lise le type du processus,
// sortir. Rien d'autre — ni base, ni préférences, ni journal, ni Spotlight.
if CommandLine.arguments.contains("--dock-self-check") {
    _ = PDFDocument()
    print("dock-self-check: pdfkit touched, activation policy applied = "
          + "\(dockPolicyApplied), bundle = "
          + "\(Bundle.main.bundleIdentifier ?? "none")")
    fflush(stdout)
    Thread.sleep(forTimeInterval: 4)
    exit(0)
}

let agentLog = AgentLog(url: AgentPaths.logURL())
agentLog.captureStandardStreams()
agentLog.info("——— FouineAgent starting (pid "
              + "\(ProcessInfo.processInfo.processIdentifier)) ———")

// Refus improbable, mais il se verrait autrement comme une icône de Dock
// inexplicable : on le dit, on ne s'arrête pas pour autant.
if !dockPolicyApplied {
    agentLog.warn("activation policy refused: this process may register with "
                  + "LaunchServices and show a second Fouine icon in the Dock "
                  + "(see docs/pitfalls.md, \"A second Fouine icon bounces in "
                  + "the Dock\").")
}

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
