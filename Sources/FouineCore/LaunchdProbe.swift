// LaunchdProbe.swift — sonde launchctl pour l'agent d'arrière-plan.
// B1-05 : diagnostic de l'agent sans lier ServiceManagement.

import Foundation

/// Informations extraites de `launchctl print gui/$UID/<label>`.
public struct LaunchdServiceInfo: Equatable, Sendable {
    public let state: String?
    public let jobState: String?
    public let lastExitCode: String?
    public let runs: Int?
    public let pid: pid_t?
    public let executablePath: String?

    public init(
        state: String? = nil,
        jobState: String? = nil,
        lastExitCode: String? = nil,
        runs: Int? = nil,
        pid: pid_t? = nil,
        executablePath: String? = nil
    ) {
        self.state = state
        self.jobState = jobState
        self.lastExitCode = lastExitCode
        self.runs = runs
        self.pid = pid
        self.executablePath = executablePath
    }

    /// Analyse la sortie texte brute de `launchctl print`.
    public static func parse(_ text: String) -> LaunchdServiceInfo {
        var state: String?
        var jobState: String?
        var lastExitCode: String?
        var runs: Int?
        var pid: pid_t?
        var executablePath: String?

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("state = ") {
                state = String(trimmed.dropFirst("state = ".count))
            } else if trimmed.hasPrefix("job state = ") {
                jobState = String(trimmed.dropFirst("job state = ".count))
            } else if trimmed.hasPrefix("last exit code = ") {
                lastExitCode = String(trimmed.dropFirst("last exit code = ".count))
            } else if trimmed.hasPrefix("runs = ") {
                runs = Int(String(trimmed.dropFirst("runs = ".count)))
            } else if trimmed.hasPrefix("pid = ") {
                if let p = Int(String(trimmed.dropFirst("pid = ".count))) {
                    pid = pid_t(p)
                }
            } else if trimmed.hasPrefix("program = ") {
                executablePath = String(trimmed.dropFirst("program = ".count))
            } else if trimmed.contains("\"Executable\" => ") {
                if let start = trimmed.range(of: "\"Executable\" => \"")?.upperBound,
                   let end = trimmed[start...].range(of: "\"")?.lowerBound {
                    executablePath = String(trimmed[start..<end])
                }
            }
        }

        return LaunchdServiceInfo(
            state: state,
            jobState: jobState,
            lastExitCode: lastExitCode,
            runs: runs,
            pid: pid,
            executablePath: executablePath
        )
    }
}

/// Résultat brut de l'appel à launchctl.
public enum LaunchdAgentResult: Equatable, Sendable {
    case notRegistered
    case registered(LaunchdServiceInfo)
    case failed(error: String)
}

/// Rapport de santé de l'agent d'arrière-plan.
public struct BackgroundAgentReport: Equatable, @unchecked Sendable {
    public enum Diagnosis: Equatable, Sendable {
        case notRegistered
        case running(pid: pid_t, lastReportAge: TimeInterval?)
        case spawnFailed(reason: String, runs: Int)
        case silent(lastReportAge: TimeInterval?)
        case launchctlError(String)
    }

    public let diagnosis: Diagnosis
    public let serviceInfo: LaunchdServiceInfo?
    public let agentStatus: AgentStatusRecord?
    public let displayText: String
    public let json: [String: Any]
    public let isHealthy: Bool

    public static func == (lhs: BackgroundAgentReport, rhs: BackgroundAgentReport) -> Bool {
        lhs.diagnosis == rhs.diagnosis
            && lhs.serviceInfo == rhs.serviceInfo
            && lhs.agentStatus == rhs.agentStatus
            && lhs.displayText == rhs.displayText
            && lhs.isHealthy == rhs.isHealthy
    }
}

/// Sonde et évaluation de l'état de l'agent launchd.
public enum LaunchdAgentProbe {

    public static func formatAgeDuration(_ seconds: TimeInterval) -> String {
        if seconds < 90 {
            return "\(max(0, Int(seconds))) s"
        } else if seconds < 5_400 {
            return "\(Int(seconds / 60)) min"
        } else {
            return "\(Int(seconds / 3_600)) h"
        }
    }

    /// Exécute `launchctl print gui/$UID/<label>` avec un délai de garde de 5 s.
    public static func run(
        label: String = FouinePaths.agentServiceLabel,
        uid: uid_t = getuid(),
        timeout: TimeInterval = 5.0
    ) -> LaunchdAgentResult {
        let launchctlPath = "/bin/launchctl"
        guard FileManager.default.isExecutableFile(atPath: launchctlPath) else {
            return .failed(error: "launchctl not found at \(launchctlPath)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchctlPath)
        process.arguments = ["print", "gui/\(uid)/\(label)"]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C.UTF-8"
        ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        do {
            try process.run()
        } catch {
            return .failed(error: "failed to run launchctl: \((error as NSError).localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }

        if process.isRunning {
            process.terminate()
            let graceDeadline = Date().addingTimeInterval(1.0)
            while process.isRunning && Date() < graceDeadline {
                usleep(20_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            let timeoutText: String
            if timeout < 1.0 {
                timeoutText = "\(Int(round(timeout * 1000))) ms"
            } else if timeout == Double(Int(timeout)) {
                timeoutText = "\(Int(timeout)) s"
            } else {
                timeoutText = String(format: "%.1f s", timeout)
            }
            return .failed(error: "launchctl print timed out after \(timeoutText)")
        }

        group.wait()

        let stdout = String(decoding: outData, as: UTF8.self)
        let stderr = String(decoding: errData, as: UTF8.self)

        if process.terminationStatus == 0 {
            return .registered(LaunchdServiceInfo.parse(stdout))
        } else {
            let combined = (stderr + "\n" + stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            if combined.contains("Could not find service") {
                return .notRegistered
            } else {
                return .failed(error: combined.isEmpty ? "exit code \(process.terminationStatus)" : combined)
            }
        }
    }

    /// Évalue l'état de santé en croisant launchctl et agent_status.
    public static func evaluate(
        result: LaunchdAgentResult,
        status: AgentStatusRecord?,
        now: Date = Date()
    ) -> BackgroundAgentReport {
        // Le libellé RÉEL de l'interrupteur, celui que l'utilisateur voit dans
        // l'application (CM-03) : trois documents et deux sondes en donnaient
        // trois noms différents, dont un qui n'existait plus depuis UX-03.
        let remediationGuidance =
            "re-register it from Fouine.app ▸ “Keep the index up to date automatically”"

        switch result {
        case .notRegistered:
            // PM-17, REPRODUIT EN DIRECT le 13/09/2026 : launchd répondait
            // « Could not find service », `agent_status` portait
            // `signal-received(SIGTERM)`, et cette branche déclarait quand même
            // `healthy: true` pendant que `fouine status --json` disait
            // `alive: false, stale: true`. Les deux surfaces lisent la MÊME
            // table et se contredisaient.
            //
            // LE DÉPARTAGE EST LE RAPPORT LUI-MÊME. Un enregistrement absent
            // ALORS QU'UN RAPPORT EXISTE veut dire que l'agent a tourné puis a
            // disparu : il est tombé, ou il a été désenregistré. Sans aucun
            // rapport, personne ne l'a jamais armé — « pas installé » n'est pas
            // « cassé », et c'est aussi l'état d'un utilisateur qui a ÉTEINT la
            // mise à jour automatique.
            let everRan = status != nil
            var json: [String: Any] = [
                "registered": false,
                "status": "not_registered"
            ]
            // Appelée ici aussi (second défaut de PM-17) : `report_phase`,
            // `report_alive` et `last_report_seconds` disparaissaient de la
            // sortie exactement au moment où ils disaient quelque chose.
            populateLaunchdFields(&json, info: nil, status: status)
            if let age = status?.age(at: now) { json["last_report_seconds"] = Int(age) }

            var display = "not registered"
            if let status {
                let ageText = status.age(at: now).map { formatAgeDuration($0) } ?? "0 s"
                display += " — last report \(ageText) ago"
                let detail = AgentStatusDetail.english(status.detail)
                if !status.detail.isEmpty { display += " (\(detail))" }
            }
            return BackgroundAgentReport(
                diagnosis: .notRegistered,
                serviceInfo: nil,
                agentStatus: status,
                displayText: display,
                json: json,
                isHealthy: !everRan
            )

        case .failed(let error):
            let json: [String: Any] = [
                "registered": false,
                "status": "error",
                "error": error
            ]
            return BackgroundAgentReport(
                diagnosis: .launchctlError(error),
                serviceInfo: nil,
                agentStatus: status,
                displayText: "could not query launchd: \(error)",
                json: json,
                isHealthy: false
            )

        case .registered(let info):
            let isSpawnFailed = (info.jobState == "spawn failed")
                || (info.lastExitCode?.contains("EX_CONFIG") == true)
                || (info.lastExitCode?.contains("78") == true)

            if isSpawnFailed {
                var reason = "EX_CONFIG"
                if let code = info.lastExitCode {
                    if let colon = code.firstIndex(of: ":") {
                        reason = String(code[code.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    } else {
                        reason = code
                    }
                }
                let runs = info.runs ?? 1
                let runsText = runs == 1 ? "1 run" : "\(runs) runs"
                let display = "registered, spawn failed (\(reason), \(runsText)) — \(remediationGuidance)"

                var json: [String: Any] = [
                    "registered": true,
                    "status": "spawn_failed",
                    "failure_reason": reason,
                    "runs": runs,
                    "guidance": remediationGuidance
                ]
                populateLaunchdFields(&json, info: info, status: status)

                return BackgroundAgentReport(
                    diagnosis: .spawnFailed(reason: reason, runs: runs),
                    serviceInfo: info,
                    agentStatus: status,
                    displayText: display,
                    json: json,
                    isHealthy: false
                )
            }

            let isRunning = info.state == "running"
            let age = status?.age(at: now)
            let isStale = status?.isStale(at: now) ?? true

            if isRunning && !isStale, let status {
                let ageStr = age.map { formatAgeDuration($0) } ?? "0 s"
                let pid = info.pid ?? status.pid
                let display = "registered, running (pid \(pid), last report \(ageStr) ago)"

                var json: [String: Any] = [
                    "registered": true,
                    "status": "running",
                    "pid": Int(pid),
                    "last_report_seconds": Int(age ?? 0)
                ]
                populateLaunchdFields(&json, info: info, status: status)

                return BackgroundAgentReport(
                    diagnosis: .running(pid: pid, lastReportAge: age),
                    serviceInfo: info,
                    agentStatus: status,
                    displayText: display,
                    json: json,
                    isHealthy: true
                )
            } else {
                // Enregistré mais silencieux
                let silentDetail: String
                if let age {
                    silentDetail = "no report for \(formatAgeDuration(age))"
                } else {
                    silentDetail = "no report published yet"
                }
                let display = "registered but silent (\(silentDetail)) — \(remediationGuidance)"

                var json: [String: Any] = [
                    "registered": true,
                    "status": "silent",
                    "guidance": remediationGuidance
                ]
                if let age { json["last_report_seconds"] = Int(age) }
                populateLaunchdFields(&json, info: info, status: status)

                return BackgroundAgentReport(
                    diagnosis: .silent(lastReportAge: age),
                    serviceInfo: info,
                    agentStatus: status,
                    displayText: display,
                    json: json,
                    isHealthy: false
                )
            }
        }
    }

    /// `info` est NUL quand launchd ne connaît plus le service : il n'y a alors
    /// rien à dire de l'enregistrement, mais tout à dire du dernier rapport.
    private static func populateLaunchdFields(
        _ json: inout [String: Any],
        info: LaunchdServiceInfo?,
        status: AgentStatusRecord?
    ) {
        if let info {
            if let state = info.state { json["launchd_state"] = state }
            if let jobState = info.jobState { json["job_state"] = jobState }
            if let lastExitCode = info.lastExitCode { json["last_exit_code"] = lastExitCode }
            if let runs = info.runs { json["runs"] = runs }
            if let pid = info.pid { json["pid"] = Int(pid) }
            if let path = info.executablePath {
                json["executable"] = path
                json["executable_exists"] = FileManager.default.fileExists(atPath: path)
            }
        }
        if let status {
            json["report_phase"] = status.phase.rawValue
            json["report_alive"] = status.isAlive
        }
    }

    /// Point d'entrée pour la commande doctor.
    public static func evaluate(
        store: GRDBStore?,
        label: String = FouinePaths.agentServiceLabel,
        uid: uid_t = getuid(),
        timeout: TimeInterval = 5.0,
        now: Date = Date()
    ) -> BackgroundAgentReport {
        let status = try? store?.agentStatus()
        let result = run(label: label, uid: uid, timeout: timeout)
        return evaluate(result: result, status: status, now: now)
    }
}
