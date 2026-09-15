// AgentConditions.swift — les six conditions d'entrée en OCR (SPEC §5.7).
// Propriété : A-Pack.
//
//   alimentation secteur  ·  isLowPowerModeEnabled == false
//   CPU_Speed_Limit ≥ 70 %  ·  thermalState ∈ {.nominal, .fair}
//   verrou fouine.lock disponible  ·  chaque racine active lisible
//
// Toutes doivent être vraies. Elles sont re-décidées AVANT CHAQUE LOT : c'est ce
// qui permet d'interrompre proprement à la frontière de page sans toucher à
// OCRRun, dont le `--budget-minutes` s'arrête déjà entre deux pages (§6.3).
//
// `thermalState` seul ne suffit pas — mesuré, il reste à `.fair` pendant que le
// CPU est bridé à 46 % (piège n°4) : c'est `CPU_Speed_Limit` qui pilote. La
// lecture de `pmset -g therm` est recodée ici parce que `ThermalGovernor`
// (FouineOCR) est interne à son module ; le seuil et l'analyse sont les mêmes.

import Foundation
import IOKit.ps
import FouineCore
import FouineExtract

enum AgentConditions {

    /// Les conditions du §5.7 que l'utilisateur peut DÉSARMER (audit U2).
    ///
    /// Trois sur six, et pas une de plus. Les deux dernières conditions —
    /// verrou `fouine.lock` disponible, racines lisibles — ne sont pas des
    /// préférences : OCRiser sans le verrou corromprait la file, OCRiser une
    /// racine illisible ne produirait que des échecs. Elles restent en dur.
    ///
    /// `pauseOnThermal` couvre les DEUX conditions thermiques (CPU_Speed_Limit
    /// et thermalState) : elles disent la même chose à l'utilisateur — « la
    /// machine chauffe » — et `thermalState` seul ne suffit pas (piège n°4 : il
    /// reste à `.fair` pendant que le CPU est bridé à 46 %).
    struct Policy: Sendable {
        var requireAC = true
        var pauseOnLowPower = true
        var pauseOnThermal = true

        static let strict = Policy()

        init(requireAC: Bool = true, pauseOnLowPower: Bool = true,
             pauseOnThermal: Bool = true) {
            self.requireAC = requireAC
            self.pauseOnLowPower = pauseOnLowPower
            self.pauseOnThermal = pauseOnThermal
        }

        init(_ settings: SettingsSnapshot) {
            self.init(requireAC: settings.agentRequireAC,
                      pauseOnLowPower: settings.agentPauseOnLowPower,
                      pauseOnThermal: settings.agentPauseOnThermal)
        }

        /// Les conditions désarmées, pour le journal de démarrage : un agent qui
        /// OCRise sur batterie parce qu'on le lui a demandé ne doit pas se lire
        /// comme un agent qui ignore le §5.7.
        var relaxed: [String] {
            var out: [String] = []
            if !requireAC { out.append("AC power not required") }
            if !pauseOnLowPower { out.append("low power mode ignored") }
            if !pauseOnThermal { out.append("thermal guard turned off") }
            return out
        }
    }

    /// Plancher imposé par le §5.7.
    static let cpuSpeedFloor = 70

    struct Verdict {
        /// Vrai si les six conditions sont réunies.
        let ok: Bool
        /// Ce qui bloque, en clair, dans l'ordre du §5.7. Vide si `ok`.
        let blockers: [String]
        /// Les mêmes blocages, NATURE SEULE, sans les nombres qui bougent.
        ///
        /// `CPU_Speed_Limit 33 % (< 70 %)` devient `CPU_Speed_Limit below
        /// floor` : le pourcentage change à chaque tic, donc la signature
        /// changeait à chaque tic, donc le garde-fou de `Agent.note()` — « ne
        /// journaliser qu'au changement » — était neutralisé et une ligne
        /// partait toutes les soixante secondes (A2-12).
        let kinds: [String]

        /// Signature stable, pour ne journaliser qu'aux CHANGEMENTS d'état.
        var signature: String { ok ? "ok" : kinds.joined(separator: " · ") }

        init(ok: Bool, blockers: [String], kinds: [String]? = nil) {
            self.ok = ok
            self.blockers = blockers
            self.kinds = kinds ?? blockers
        }
    }

    /// - Parameter unreadableRoots: racines actives dont la lecture effective
    ///   échoue (sondées par l'appelant, qui a le store).
    /// - Parameter lockHeldBySelf: vrai si CE processus détient déjà le verrou
    ///   d'écriture — auquel cas le test de disponibilité, qui se ferait sur un
    ///   second descripteur, se refuserait à lui-même (flock verrouille la
    ///   description de fichier ouverte, pas le processus).
    static func evaluate(lock: URL, lockHeldBySelf: Bool,
                         unreadableRoots: [String],
                         policy: Policy = .strict) -> Verdict {
        var blockers: [String] = []
        // La NATURE de chaque blocage, en parallèle : c'est elle qui décide si
        // le journal doit reparler, pas le chiffre du moment (A2-12).
        var kinds: [String] = []

        if policy.requireAC, !onACPower() {
            blockers.append("no AC power")
            kinds.append("no AC power")
        }
        if policy.pauseOnLowPower, ProcessInfo.processInfo.isLowPowerModeEnabled {
            blockers.append("low power mode is on")
            kinds.append("low power mode is on")
        }
        if policy.pauseOnThermal, let limit = cpuSpeedLimit(),
           limit < cpuSpeedFloor {
            blockers.append("CPU_Speed_Limit \(limit)% (< \(cpuSpeedFloor)%)")
            kinds.append("CPU_Speed_Limit below floor")
        }
        if policy.pauseOnThermal, !thermalOK() {
            // L'état thermique, LUI, reste dans la signature : passer de
            // « fair » à « serious » est un changement de nature.
            let state = "thermalState \(describe(ProcessInfo.processInfo.thermalState))"
            blockers.append(state)
            kinds.append(state)
        }
        if !lockHeldBySelf, lockAvailable(at: lock) == false {
            blockers.append("fouine.lock is held by another process")
            kinds.append("fouine.lock is held by another process")
        }
        if !unreadableRoots.isEmpty {
            blockers.append("unreadable root(s): "
                            + unreadableRoots.joined(separator: ", "))
            kinds.append("unreadable root(s): "
                         + unreadableRoots.joined(separator: ", "))
        }
        return Verdict(ok: blockers.isEmpty, blockers: blockers, kinds: kinds)
    }

    // MARK: - Alimentation

    /// Secteur : adaptateur externe présent, ou source d'alimentation « AC Power ».
    /// Un Mac sans batterie rend « AC Power » — c'est le comportement voulu.
    static func onACPower() -> Bool {
        if let details = IOPSCopyExternalPowerAdapterDetails(),
           let dict = details.takeRetainedValue() as? [String: Any],
           !dict.isEmpty {
            return true
        }
        guard let blob = IOPSCopyPowerSourcesInfo() else { return false }
        let snapshot = blob.takeRetainedValue()
        guard let type = IOPSGetProvidingPowerSourceType(snapshot)?
            .takeUnretainedValue() as String? else { return false }
        return type == kIOPSACPowerValue
    }

    // MARK: - Thermique

    static func thermalOK() -> Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair: return true
        default: return false
        }
    }

    static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// `CPU_Speed_Limit` en pourcentage, ou `nil` si `pmset` est illisible —
    /// auquel cas on ne bloque PAS : un OCR qui refuserait de tourner faute de
    /// thermomètre serait un plus grand mal (même règle que ThermalGovernor).
    static func cpuSpeedLimit() -> Int? {
        guard let output = runPMSet() else { return nil }
        for line in output.split(separator: "\n") where line.contains("CPU_Speed_Limit") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            if let n = Int(value) { return n }
        }
        return nil
    }

    /// DÉLAI DE GARDE, depuis l'audit F6 — même correctif qu'au gouverneur
    /// thermique, et pour la même raison : ici, l'attente non bornée était sur
    /// le fil qui décide si l'agent a le droit de travailler. Un `pmset` bloqué
    /// figeait l'agent avant même qu'il ne prenne le verrou.
    ///
    /// L'invariant A8 (« jamais de fork/exec sous le verrou ») est intact : le
    /// site d'appel n'a pas bougé, seule la façon de lancer change.
    private static func runPMSet() -> String? {
        BoundedTool.text("/usr/bin/pmset", ["-g", "therm"],
                         what: "CPU_Speed_Limit")
    }

    // MARK: - Verrou

    /// Disponibilité du verrou d'écriture, TESTÉE SANS LE RETENIR : on prend
    /// `LOCK_EX | LOCK_NB`, on relâche immédiatement, on ferme. `nil` = le
    /// fichier n'a pas pu être ouvert (le store le créera).
    static func lockAvailable(at url: URL) -> Bool? {
        // 0600 si ce test crée le fichier (audit A1-06) : sans cela l'agent
        // pouvait fabriquer un `fouine.lock` en 0644 avant même que le store ne
        // l'ouvre. `fchmod` en rattrapage, best-effort.
        let fd = open(url.path, O_RDWR | O_CREAT, FilePermissions.file)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fchmod(fd, FilePermissions.file)
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(fd, LOCK_UN)
            return true
        }
        return errno == EWOULDBLOCK ? false : nil
    }
}
