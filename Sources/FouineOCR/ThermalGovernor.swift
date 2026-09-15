// ThermalGovernor.swift — garde-fou thermique sur CPU_Speed_Limit (SPEC §6.3).
// Propriété : A-OCR.
//
// Piège n°4, mesuré : à 4 fils Vision, `CPU_Speed_Limit` tombe à 46 % en moins de
// 90 s pendant que `ProcessInfo.thermalState` reste bloqué à `.fair`. Une pause
// conditionnée à `.serious` NE SE DÉCLENCHE JAMAIS. La seule grandeur qui bouge
// est celle que `pmset -g therm` publie.
//
// Règle appliquée, telle quelle :
//   · relevé toutes les 30 s ;
//   · < 70 %              -> concurrence effective ramenée à 2 ;
//   · < 50 % DURABLEMENT  -> (deux relevés consécutifs) suspension jusqu'au retour
//                            à ≥ 50 % ;
//   · `pmset` indisponible ou illisible -> on continue SANS garde-fou, en le
//     disant une fois. Un OCR qui refuserait de tourner faute de thermomètre
//     serait un plus grand mal.

import Foundation
import FouineExtract

final class ThermalGovernor: @unchecked Sendable {

    /// Période de relevé (§6.3).
    static let sampleInterval: TimeInterval = 30
    /// Sous ce pourcentage, la concurrence tombe à `throttledConcurrency`.
    static let reduceBelow = 70
    /// Sous ce pourcentage, deux fois de suite, on suspend.
    static let suspendBelow = 50
    /// Concurrence de repli.
    static let throttledConcurrency = 2
    /// Pas d'attente des fils mis au repos.
    static let waitStep: TimeInterval = 0.5

    private let mutex = NSLock()
    private let nominalConcurrency: Int
    private let log: @Sendable (String) -> Void

    private var lastSample: Date?
    private var lastLimit: Int?
    private var lowSampleStreak = 0
    private var suspended = false
    private var probeFailed = false
    private var announcedProbeFailure = false
    private var announcedState: String?
    private var cancelled = false
    private var waitedSeconds: TimeInterval = 0

    /// Cumul des secondes réellement passées à attendre le thermomètre,
    /// pour le résumé de run.
    var suspendedSeconds: TimeInterval {
        mutex.lock(); defer { mutex.unlock() }
        return waitedSeconds
    }

    init(nominalConcurrency: Int, log: @escaping @Sendable (String) -> Void) {
        self.nominalConcurrency = max(1, nominalConcurrency)
        self.log = log
    }

    // MARK: - Interruption

    /// Débloque tous les fils en attente (budget épuisé, fin de run).
    func cancel() {
        mutex.lock(); cancelled = true; mutex.unlock()
    }

    var isCancelled: Bool {
        mutex.lock(); defer { mutex.unlock() }
        return cancelled
    }

    // MARK: - Portillon

    /// Bloque le fil `worker` tant que la machine ne peut pas l'accueillir.
    /// Rend `false` si le run est annulé — ou si `deadline` tombe pendant l'attente.
    ///
    /// Le second cas n'est pas une précaution de style : sans lui, une suspension
    /// thermique doublée d'un `--budget-minutes` bloquerait `fouine ocr`
    /// indéfiniment, le budget ne pouvant plus être constaté par personne.
    func admit(worker: Int, deadline: Date? = nil) -> Bool {
        var waitedFrom: Date?
        defer {
            if let from = waitedFrom {
                let waited = Date().timeIntervalSince(from)
                mutex.lock(); waitedSeconds += waited; mutex.unlock()
            }
        }
        while true {
            let state = currentState()
            if state.cancelled { return false }
            if !state.suspended && worker < state.concurrency { return true }
            if let deadline, Date() >= deadline { return false }
            if waitedFrom == nil { waitedFrom = Date() }
            Thread.sleep(forTimeInterval: Self.waitStep)
        }
    }

    /// Concurrence autorisée à l'instant du dernier relevé (diagnostic, tests).
    var allowedConcurrency: Int { currentState().concurrency }

    // MARK: - Relevé

    private struct State {
        let concurrency: Int
        let suspended: Bool
        let cancelled: Bool
    }

    /// JAMAIS de `fork`/`exec` sous le verrou (audit A8 du 01/09/2026) : `pmset
    /// -g therm` coûte 10 à 20 ms (mesuré), et les quatre fils passent tous par
    /// `admit()` -> `currentState()` avant chaque page. Le motif est donc, dans
    /// cet ordre : période échue décidée SOUS verrou (et échéance réservée tout
    /// de suite, pour qu'un seul fil relève), relevé HORS verrou, publication
    /// SOUS verrou. La réservation de l'échéance est ce qui empêche le double
    /// relevé concurrent : les autres fils voient déjà `lastSample` à jour et
    /// repartent avec la dernière valeur connue.
    private func currentState() -> State {
        mutex.lock()
        if cancelled {
            mutex.unlock()
            return State(concurrency: nominalConcurrency, suspended: false,
                         cancelled: true)
        }
        if probeFailed {
            mutex.unlock()
            return State(concurrency: nominalConcurrency, suspended: false,
                         cancelled: false)
        }
        let now = Date()
        let due = lastSample.map { now.timeIntervalSince($0) >= Self.sampleInterval }
            ?? true
        if due { lastSample = now }   // réservé : un seul fil relèvera
        mutex.unlock()

        // ---- Relevé HORS VERROU ---------------------------------------------
        let sample: Int?? = due ? .some(Self.cpuSpeedLimit()) : nil

        // ---- Publication SOUS VERROU ----------------------------------------
        mutex.lock()
        defer { mutex.unlock() }
        // Re-vérification : le run a pu être annulé pendant le sous-processus.
        if cancelled {
            return State(concurrency: nominalConcurrency, suspended: false,
                         cancelled: true)
        }
        if let sample {
            if let limit = sample {
                lastLimit = limit
                if limit < Self.suspendBelow {
                    lowSampleStreak += 1
                } else {
                    lowSampleStreak = 0
                }
                // « < 50 % DURABLEMENT » = deux relevés consécutifs (§6.3).
                suspended = lowSampleStreak >= 2
            } else {
                probeFailed = true
                if !announcedProbeFailure {
                    announcedProbeFailure = true
                    log("thermal guard off: `pmset -g therm` is unreadable "
                        + "(no CPU_Speed_Limit) — the run continues without it")
                }
                return State(concurrency: nominalConcurrency, suspended: false,
                             cancelled: false)
            }
        } else if probeFailed {
            // Un autre fil vient de constater l'échec pendant notre attente.
            return State(concurrency: nominalConcurrency, suspended: false,
                         cancelled: false)
        }

        let limit = lastLimit ?? 100
        let concurrency = limit < Self.reduceBelow
            ? min(nominalConcurrency, Self.throttledConcurrency)
            : nominalConcurrency
        announce(limit: limit, concurrency: concurrency, suspended: suspended)
        return State(concurrency: concurrency, suspended: suspended, cancelled: false)
    }

    /// Un message par CHANGEMENT d'état, jamais un par page.
    private func announce(limit: Int, concurrency: Int, suspended: Bool) {
        let state = suspended ? "suspended"
            : (concurrency < nominalConcurrency ? "reduced to \(concurrency)" : "nominal")
        guard announcedState != state else { return }
        announcedState = state
        switch state {
        case "nominal":
            if limit < 100 || lastLimit != nil {
                log("thermal: CPU_Speed_Limit \(limit)%, nominal concurrency "
                    + "(\(concurrency))")
            }
        case "suspended":
            log("thermal: CPU_Speed_Limit \(limit)% on two samples — "
                + "OCR SUSPENDED until it is back at \(Self.suspendBelow)%")
        default:
            log("thermal: CPU_Speed_Limit \(limit)% — concurrency \(state)")
        }
    }

    // MARK: - pmset

    /// `CPU_Speed_Limit` en pourcentage, ou nil si `pmset` est indisponible.
    static func cpuSpeedLimit() -> Int? {
        if ProcessInfo.processInfo.environment["FOUINE_DISABLE_THERMAL_GOVERNOR"] != nil {
            return nil
        }
        guard let output = runPMSet() else { return nil }
        return parseSpeedLimit(output)
    }

    static func parseSpeedLimit(_ output: String) -> Int? {
        for line in output.split(separator: "\n") {
            guard line.contains("CPU_Speed_Limit") else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            if let n = Int(value) { return n }
        }
        return nil
    }

    /// DÉLAI DE GARDE, depuis l'audit F6.
    ///
    /// AVANT : `Process()` nu, puis `readDataToEndOfFile()` puis
    /// `waitUntilExit()` — deux attentes NON BORNÉES à la suite, sur le fil qui
    /// pilote la concurrence OCR. Un `pmset` qui ne rend pas la main gelait le
    /// gouverneur, donc la pompe entière, sans une ligne de journal.
    ///
    /// MAINTENANT : `BoundedTool` (5 s, chemin explicite, environnement figé,
    /// SIGTERM puis SIGKILL). Un dépassement rend `nil`, c'est-à-dire
    /// exactement ce que rend un `pmset` absent : « sonde illisible », le
    /// garde-fou se désactive EN LE DISANT. Jamais un blocage.
    private static func runPMSet() -> String? {
        BoundedTool.text("/usr/bin/pmset", ["-g", "therm"],
                         what: "CPU_Speed_Limit")
    }
}
