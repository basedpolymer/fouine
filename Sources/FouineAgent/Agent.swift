// Agent.swift — le démon d'indexation en arrière-plan (SPEC §5.7). A-Pack.
//
// Trois boucles, une seule file de travail :
//   · FSEvents (latence 3 s, curseur persisté par le watcher) → crawl delta +
//     extraction de la racine touchée ;
//   · une horloge (60 s par défaut) qui re-sonde les racines et re-décide les
//     conditions OCR du §5.7 ;
//   · OCR par lots courts (10 min), re-décidés à chaque lot.
//
// Les trois passent par la MÊME file série `work` : sur une machine à 8 Gio dont
// 1 Gio de swap est déjà pris, faire tourner Vision (344 Mo/processus, 1,38 Go à
// 4 jobs) pendant que PDFKit extrait (279 Mo/fil) est la meilleure façon de
// swapper. Une salve FSEvents attend donc la fin du lot OCR en cours : c'est
// exactement pourquoi les lots sont courts.
//
// Règles d'agent, non négociables (§7.1) :
//   · AUCUNE invite TCC n'est possible ici. Une racine illisible est journalisée
//     avec son symptôme et le geste exact, puis IGNORÉE — l'agent continue avec
//     les racines lisibles. Il ne meurt jamais en boucle sous launchd.
//   · La lisibilité est re-testée à chaque tour, pas seulement au démarrage
//     (piège n°14 : une racine peut disparaître en cours de route).

import Foundation
import Dispatch
import FouineCore
import FouineCrawl
import FouineLicense
import FouineOCR

public struct AgentState: Equatable, Sendable {
    public var phase: AgentStatusRecord.Phase
    public var lastVerdict: String?
    public var hasNotifiedQueueDrained: Bool
    public var pollPeriod: Int
    public var lockHeldBySelf: Bool
    public var isStopping: Bool
    public var lastJournalRotationCheck: Date?
    /// Dernière fois que l'agent a écrit « licence: trial over » (lot L1C).
    /// Sans elle, un essai fini remplirait le journal d'une ligne par minute
    /// jusqu'à la rotation.
    public var lastLicenceNoticeAt: Date?

    public init(
        phase: AgentStatusRecord.Phase = .idle,
        lastVerdict: String? = nil,
        hasNotifiedQueueDrained: Bool = false,
        pollPeriod: Int = 60,
        lockHeldBySelf: Bool = false,
        isStopping: Bool = false,
        lastJournalRotationCheck: Date? = nil,
        lastLicenceNoticeAt: Date? = nil
    ) {
        self.phase = phase
        self.lastVerdict = lastVerdict
        self.hasNotifiedQueueDrained = hasNotifiedQueueDrained
        self.pollPeriod = pollPeriod
        self.lockHeldBySelf = lockHeldBySelf
        self.isStopping = isStopping
        self.lastJournalRotationCheck = lastJournalRotationCheck
        self.lastLicenceNoticeAt = lastLicenceNoticeAt
    }
}

public enum AgentAction: Equatable, Sendable {
    case none
    case sleep(seconds: Int)
    case runExtraction(rootIDs: Set<Int64>)
    case runOCRBatch(budgetMinutes: Int, jobs: Int, queuedPages: Int)
    /// UN lot de préparation de la recherche par le sens (lot AG1, PR-21).
    case runEmbedBatch(budgetMinutes: Int, pagesLeft: Int)
    case publishStatus(phase: AgentStatusRecord.Phase, detail: String, done: Int?, total: Int?)
    case notifyQueueDrained
    case enforceLogRotation
    /// L'essai est fini : une ligne de journal, rien d'autre (lot L1C).
    case noteLicenceBlocked
    indirect case sequence([AgentAction])
}

final class Agent: @unchecked Sendable {

    let log: AgentLog
    let store: GRDBStore
    let pipeline: AgentPipeline
    /// Réglages partagés (audit U2). Relus au démarrage de chaque passe et de
    /// chaque lot : un changement fait dans la fenêtre de réglages de l'app doit
    /// être vu ici en moins d'un tic de `agent.pollSeconds`, sans quoi la
    /// fenêtre ne serait qu'un affichage.
    let settings: Settings
    /// L'état publié dans `agent_status` (audit F7).
    let status: AgentStatusWriter
    /// Le moteur d'inférence, chargé à la demande et rendu au repos (AG1).
    let embedder: AgentEmbedder
    private let onExit: @Sendable (Int32) -> Void
    private var isOpen = false

    /// File série : crawl, extraction et OCR ne se chevauchent jamais.
    private let work = DispatchQueue(label: "io.github.basedpolymer.fouine.agent.work",
                                     qos: .utility)
    private let control = DispatchQueue(label: "io.github.basedpolymer.fouine.agent.control",
                                        qos: .utility)
    /// La sonde de progression de la préparation du sens a SA file : elle
    /// tourne pendant que `control` sert l'horloge, et deux `DispatchSource`
    /// sur la même file série s'attendent l'un l'autre.
    let embedProbeQueue = DispatchQueue(
        label: "io.github.basedpolymer.fouine.agent.embed.probe", qos: .utility)
    private let mutex = NSLock()

    // État protégé par `mutex`.
    private var watchers: [String: FSEventsWatcher] = [:]   // clé : vol_uuid
    private var watchedSignature: String = ""
    private var readableRoots: [Int64: RootRecord] = [:]
    private var unreadableLabels: [String] = []
    private var pending: Set<Int64> = []
    /// Les règles d'exclusion gardées par racine au dernier tic (lot IG2).
    /// `nil` avant la première lecture.
    private var ignoreRulesSeen: [Int64: String]?
    private var stopping = false
    private var ocrTickQueued = false
    /// Vrai dès qu'une écriture d'indexation a réussi : `fouine.lock` est alors
    /// à NOUS, et le test de disponibilité (qui passe par un second descripteur)
    /// se refuserait à lui-même — flock verrouille la description ouverte.
    private var lockHeldBySelf = false
    private var lastVerdict: String?
    /// Dernière ligne « licence: trial over » écrite (lot L1C).
    private var lastLicenceNoticeAt: Date?
    /// Conditions du §5.7 relues PENDANT un lot de vecteurs, et la date de ce
    /// relevé : `shouldStop` est consulté toutes les quelques secondes, et
    /// chaque évaluation lance `pmset` en sous-processus (§6.2).
    private var embedConditionsOK = true
    private var embedConditionsAt = Date.distantPast
    private var timer: DispatchSourceTimer?
    /// Période courante de l'horloge. Mémorisée pour ne reprogrammer la source
    /// que si `agent.pollSeconds` a réellement changé.
    private var timerPeriod = 0

    init(log: AgentLog, store: GRDBStore = GRDBStore(),
         onExit: @escaping @Sendable (Int32) -> Void = { exit($0) }) {
        self.log = log
        self.store = store
        let settings = Settings(store: store)
        let status = AgentStatusWriter(store: store, log: log)
        self.settings = settings
        self.status = status
        self.pipeline = AgentPipeline(store: store, log: log, settings: settings, status: status)
        self.embedder = AgentEmbedder(log: log)
        self.onExit = onExit
    }

    private func locked<T>(_ body: () -> T) -> T {
        mutex.lock(); defer { mutex.unlock() }; return body()
    }

    var isStopping: Bool { locked { stopping } }

    // MARK: - Machine d'états pure (SPEC §5.7, audit C2-11)

    /// Décision de « tick » pure : à partir des conditions injectées, de l'état
    /// courant et des réglages, produit l'action à faire et le nouvel état sans
    /// dépendre de launchd ni d'effets de bord d'I/O.
    static func tick(
        state: AgentState,
        conditions: AgentConditions.Verdict,
        clock: Date = Date(),
        settings: SettingsSnapshot,
        ocrQueueLength: Int,
        pendingRoots: Set<Int64> = [],
        embed: AgentEmbedSituation = .none,
        licenceAllowsIndexing: Bool = true
    ) -> (action: AgentAction, nextState: AgentState) {
        var nextState = state
        if nextState.isStopping {
            return (.none, nextState)
        }

        // 0. L'ESSAI EST-IL FINI ? (lot L1C) Avant tout le reste, et avant
        //    toute sonde : un agent en fin d'essai ne fait RIEN — ni
        //    extraction, ni OCR, ni préparation du sens. Il ne réclame rien
        //    non plus : il n'y a pas de notification, pas de badge, pas de
        //    fenêtre. C'est l'application qui porte le message, là où quelqu'un
        //    peut le lire et agir ; le journal, lui, sert au dépanneur qui se
        //    demande pourquoi l'index ne bouge plus.
        //
        //    UNE LIGNE PAR JOUR AU PLUS. Une par tic serait une ligne par
        //    minute, soit 1 440 par jour pour dire la même chose.
        if !licenceAllowsIndexing {
            let due = nextState.lastLicenceNoticeAt
                .map { clock.timeIntervalSince($0) >= 86_400 } ?? true
            guard due else { return (.none, nextState) }
            nextState.lastLicenceNoticeAt = clock
            return (.noteLicenceBlocked, nextState)
        }

        // 1. Si des racines attendent une extraction, l'extraction a priorité absolue.
        if !pendingRoots.isEmpty {
            return (.runExtraction(rootIDs: pendingRoots), nextState)
        }

        // 2. Vérification de la file OCR. `.idle` est republié À CHAQUE tic,
        //    même sans changement : c'est le BATTEMENT que l'app et `doctor`
        //    guettent (`AgentStatusRecord.staleAfter` = 5 min) — sans lui, un
        //    agent au repos passerait pour « enregistré mais muet ». Seule la
        //    notification de file vidée est unique (audit F7).
        if ocrQueueLength == 0 {
            // 2 bis. LA RECHERCHE PAR LE SENS, APRÈS L'OCR (lot AG1, PR-21).
            //     L'ordre n'est pas un détail : `completeOCR` invalide les
            //     vecteurs de la page qu'il réécrit, et une page vectorisée
            //     avant sa reconnaissance le serait deux fois. La file d'OCR
            //     vide est donc une CONDITION, pas une préférence.
            let meaning = meaningVerdict(embed: embed, conditions: conditions)
            if meaning == .go {
                var actions: [AgentAction] = []
                // La file d'OCR est vide : la notification de fin part comme
                // elle serait partie sans préparation du sens.
                if !nextState.hasNotifiedQueueDrained {
                    nextState.hasNotifiedQueueDrained = true
                    actions.append(.notifyQueueDrained)
                }
                nextState.lastVerdict = meaning.note
                nextState.lockHeldBySelf = true
                actions.append(.publishStatus(
                    phase: .preparingMeaning,
                    detail: AgentStatusDetail.pagesLeft(embed.pagesLeft),
                    done: 0, total: embed.pagesLeft))
                actions.append(.runEmbedBatch(
                    budgetMinutes: settings.agentEmbedBudgetMinutes,
                    pagesLeft: embed.pagesLeft))
                return (.sequence(actions), nextState)
            }

            var actions: [AgentAction] = [
                .publishStatus(phase: .idle, detail: AgentStatusDetail.queueDrained, done: nil, total: nil)
            ]
            if !nextState.hasNotifiedQueueDrained {
                nextState.hasNotifiedQueueDrained = true
                nextState.lastVerdict = AgentStatusDetail.queueDrained
                actions.append(.notifyQueueDrained)
            }
            actions.append(.sleep(seconds: settings.agentPollSeconds))
            // Le refus PORTE SON NOM : sans cela, un agent dont le modèle
            // manque ne préparerait rien et ne le dirait nulle part.
            if let why = meaning.note { nextState.lastVerdict = why }
            return (.sequence(actions), nextState)
        }

        // 3. File non vide : réinitialiser le fanion pour pouvoir renotifier quand la file se revidera.
        nextState.hasNotifiedQueueDrained = false

        // 4. Évaluation des 6 conditions du §5.7
        if !conditions.ok {
            let reason = conditions.blockers.joined(separator: "; ")
            nextState.lastVerdict = "OCR waiting — " + reason
            let actions: [AgentAction] = [
                .publishStatus(phase: .waiting, detail: reason, done: 0, total: ocrQueueLength),
                .sleep(seconds: settings.agentPollSeconds)
            ]
            return (.sequence(actions), nextState)
        }

        // 5. Conditions réunies -> lancement d'un lot OCR
        nextState.lastVerdict = "OCR: the six conditions of §5.7 are met"
        nextState.lockHeldBySelf = true
        let actions: [AgentAction] = [
            .publishStatus(phase: .ocr,
                           detail: AgentStatusDetail.pagesQueued(ocrQueueLength),
                           done: 0, total: ocrQueueLength),
            .runOCRBatch(budgetMinutes: settings.agentOCRBudgetMinutes,
                         jobs: settings.ocrJobs,
                         queuedPages: ocrQueueLength)
        ]
        return (.sequence(actions), nextState)
    }

    /// Faut-il préparer la recherche par le sens maintenant ? Décision PURE
    /// (lot AG1, PR-21). Elle suppose la file d'OCR déjà vide : c'est l'appelant
    /// qui le garantit.
    static func meaningVerdict(embed: AgentEmbedSituation,
                               conditions: AgentConditions.Verdict)
        -> AgentEmbedVerdict {
        guard embed.enabled else { return .nothingToDo }
        guard embed.modelInstalled else { return .noModel }
        guard embed.pagesLeft > 0 else { return .nothingToDo }
        if embed.campaignHeldByAnother { return .campaignBusy }
        guard conditions.ok else {
            return .waiting(conditions.blockers.joined(separator: "; "))
        }
        return .go
    }

    /// Décision post-lot de vecteurs : plus rien à faire, budget épuisé, ou
    /// arrêt. Le pendant exact de `postBatchTick` pour l'OCR.
    static func postEmbedBatchTick(
        state: AgentState,
        outcome: EmbedBatchOutcome,
        remainingPages: Int,
        settings: SettingsSnapshot
    ) -> (action: AgentAction, nextState: AgentState) {
        var nextState = state
        nextState.lockHeldBySelf = false
        if nextState.isStopping { return (.none, nextState) }

        switch outcome {
        case .budgetExhausted:
            // Rien à publier : le tic suivant re-décide, conditions comprises.
            return (.none, nextState)
        case .completed, .stopped:
            nextState.lastVerdict = outcome == .completed
                ? "meaning: every indexed page is ready"
                : "meaning: batch stopped"
            let actions: [AgentAction] = [
                .publishStatus(phase: .idle, detail: AgentStatusDetail.queueDrained,
                               done: nil, total: nil),
                .sleep(seconds: settings.agentPollSeconds),
            ]
            return (.sequence(actions), nextState)
        }
    }

    /// Décision post-lot d'OCR : file vidée ou budget épuisé.
    static func postBatchTick(
        state: AgentState,
        outcome: OCRRunOutcome,
        remainingQueueLength: Int,
        settings: SettingsSnapshot
    ) -> (action: AgentAction, nextState: AgentState) {
        var nextState = state
        nextState.lockHeldBySelf = false
        if nextState.isStopping {
            return (.none, nextState)
        }

        switch outcome {
        case .completed:
            nextState.hasNotifiedQueueDrained = true
            nextState.lastVerdict = AgentStatusDetail.queueDrained
            let actions: [AgentAction] = [
                .publishStatus(phase: .idle, detail: AgentStatusDetail.queueDrained, done: nil, total: nil),
                .notifyQueueDrained,
                .sleep(seconds: settings.agentPollSeconds)
            ]
            return (.sequence(actions), nextState)

        case .budgetExhausted:
            nextState.hasNotifiedQueueDrained = false
            return (.none, nextState)
        }
    }

    /// Décision de scrutation périodique (timer) : rotation du journal et mise à jour de période.
    static func timerTick(
        state: AgentState,
        clock: Date = Date(),
        newSettings: SettingsSnapshot
    ) -> (actions: [AgentAction], nextState: AgentState) {
        var nextState = state
        var actions: [AgentAction] = []

        // Rotation du journal bornée
        actions.append(.enforceLogRotation)
        nextState.lastJournalRotationCheck = clock

        // Période de scrutation
        if nextState.pollPeriod != newSettings.agentPollSeconds {
            nextState.pollPeriod = newSettings.agentPollSeconds
            actions.append(.sleep(seconds: newSettings.agentPollSeconds))
        }

        return (actions, nextState)
    }

    // MARK: - Démarrage

    func start(dbURL: URL = AgentPaths.databaseURL()) throws {
        if !isOpen {
            try store.open(at: dbURL)
            isOpen = true
            log.info("database open: \(dbURL.path)")
        }
        let current = settings.reload()
        for warning in current.warnings { log.warn(warning) }
        // Les réglages sont ANNONCÉS avec leur provenance : un agent qui hérite
        // d'un `FOUINE_AGENT_JOBS` posé dans son plist doit le dire, sinon la
        // valeur saisie dans la fenêtre de réglages semble sans effet (audit U2).
        log.info("settings: extraction \(current.agentExtractJobs) job(s) · OCR "
                 + "\(current.ocrJobs) job(s) in batches of "
                 + "\(current.agentOCRBudgetMinutes) min · polling every "
                 + "\(current.agentPollSeconds) s · OCR languages "
                 + current.ocrLanguages.joined(separator: ", "))
        let overridden = current.table()
            .filter { $0.source == .environment }
            .map { "\($0.spec.environmentVariable ?? $0.spec.key)=\($0.value)" }
        if !overridden.isEmpty {
            log.warn("settings forced by the environment (they take priority "
                     + "over the settings window): "
                     + overridden.joined(separator: " · "))
        }
        status.publish(.idle, detail: AgentStatusDetail.starting)

        refreshRoots(announceAll: true)
        announceConditions()
        // La décision de rattrapage se prend AVANT d'ouvrir les flux : depuis que
        // le watcher pose le curseur dès son démarrage, l'ordre inverse ferait
        // toujours lire un curseur non nul et le rattrapage ne partirait jamais
        // sur une base neuve. `scheduleCatchUp` ne fait qu'empiler du travail sur
        // la file série ; les flux s'ouvrent dans la milliseconde qui suit.
        scheduleCatchUp()
        noticeIgnoreRuleChanges()
        rebuildWatchers()
        startTimer()
    }

    /// État des six conditions au démarrage. Purement informatif, mais c'est le
    /// seul moyen pour l'utilisateur de comprendre pourquoi l'OCR ne part pas.
    private func announceConditions() {
        let (held, unreadable) = locked { (lockHeldBySelf, unreadableLabels) }
        let policy = AgentConditions.Policy(settings.snapshot())
        let verdict = AgentConditions.evaluate(lock: AgentPaths.lockURL(),
                                               lockHeldBySelf: held,
                                               unreadableRoots: unreadable,
                                               policy: policy)
        if !policy.relaxed.isEmpty {
            log.warn("OCR conditions TURNED OFF by the settings: "
                     + policy.relaxed.joined(separator: " · "))
        }
        let limit = AgentConditions.cpuSpeedLimit().map { "\($0)%" } ?? "unreadable"
        log.info("OCR conditions (§5.7): AC power "
                 + "\(AgentConditions.onACPower() ? "yes" : "no") · low power "
                 + "mode \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "yes" : "no")"
                 + " · CPU_Speed_Limit \(limit) · thermalState "
                 + AgentConditions.describe(ProcessInfo.processInfo.thermalState)
                 + " → " + (verdict.ok ? "met"
                            : "waiting (" + verdict.blockers.joined(separator: "; ") + ")"))
    }

    // MARK: - Racines

    /// Chemin absolu d'une racine : volume par UUID, jamais par point de montage
    /// mémorisé (§2.3).
    private func url(of root: RootRecord) throws -> URL {
        guard let mount = VolumeResolver.mountPoint(forVolumeUUID: root.volUUID) else {
            throw FouineError.volumeNotMounted(uuid: root.volUUID)
        }
        return root.relPath.isEmpty ? mount
            : mount.appendingPathComponent(root.relPath)
    }

    /// Chemin CANONIQUE (realpath). Indispensable pour FSEvents : le flux
    /// rapporte toujours des chemins canoniques, et `resolvingSymlinksInPath`
    /// de Foundation rend `/tmp/x` là où le noyau dit `/private/tmp/x`
    /// (même précaution que `FouineCrawler.canonicalPath`). Sans elle, la salve
    /// arrive et n'est rattachée à AUCUNE racine — vérifié au banc d'essai.
    static func canonical(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buffer) != nil { return String(cString: buffer) }
        return (path as NSString).standardizingPath
    }

    /// Sonde la lecture EFFECTIVE de chaque racine active (§5.2, §7.1) et met à
    /// jour l'état. Ne journalise que les CHANGEMENTS, sauf au démarrage.
    func refreshRoots(announceAll: Bool = false) {
        let active: [RootRecord]
        do { active = try store.roots().filter(\.enabled) }
        catch {
            log.error("cannot read the roots: \(AgentText.describe(error))")
            return
        }
        if active.isEmpty {
            if announceAll {
                log.warn("no active root: nothing to watch. Add one "
                         + "(`fouine root add <folder>`), or open Fouine.app "
                         + "once.")
            }
            locked { readableRoots = [:]; unreadableLabels = [] }
            return
        }

        var ok: [Int64: RootRecord] = [:]
        var bad: [String] = []
        var reasons: [Int64: String] = [:]
        for root in active {
            do {
                let target = try url(of: root)
                try RootProbe.probe(target)
                ok[root.id] = root
            } catch {
                bad.append(root.label)
                reasons[root.id] = AgentText.describe(error)
            }
        }

        let (newlyOK, newlyBad) = locked { () -> ([RootRecord], [Int64]) in
            let previouslyOK = Set(readableRoots.keys)
            let nowOK = Set(ok.keys)
            let gained = nowOK.subtracting(previouslyOK).compactMap { ok[$0] }
            let lost = previouslyOK.subtracting(nowOK).sorted()
            readableRoots = ok
            unreadableLabels = bad
            return (gained, lost)
        }

        if announceAll {
            for root in ok.values.sorted(by: { $0.label < $1.label }) {
                log.info("readable root: \(root.label) — "
                         + ((try? url(of: root).path) ?? root.relPath))
            }
        } else {
            for root in newlyOK.sorted(by: { $0.label < $1.label }) {
                log.info("root readable again: \(root.label)")
            }
        }
        // Racine illisible : on nomme le symptôme et le geste, PUIS ON CONTINUE
        // avec les autres. Un agent qui mourrait ici redémarrerait en boucle
        // sous launchd sans jamais rien indexer (§5.7, §7.1).
        for root in active where ok[root.id] == nil {
            guard announceAll || newlyBad.contains(root.id) else { continue }
            log.warn("root “\(root.label)” IGNORED — "
                     + (reasons[root.id] ?? "unknown cause"))
            log.warn("a background agent CANNOT show a permission prompt: open "
                     + "Fouine.app once, or grant the access by hand (§7.1).")
        }
    }

    // MARK: - FSEvents

    /// Un flux par volume, sur toutes les racines lisibles de ce volume.
    func rebuildWatchers() {
        var byVolume: [String: [URL]] = [:]
        let roots = locked { Array(readableRoots.values) }
        for root in roots {
            guard let target = try? url(of: root) else { continue }
            byVolume[root.volUUID, default: []].append(
                URL(fileURLWithPath: Self.canonical(target.path), isDirectory: true))
        }
        let signature = byVolume.keys.sorted().map { uuid in
            uuid + ":" + byVolume[uuid]!.map(\.path).sorted().joined(separator: "|")
        }.joined(separator: ";")

        if locked({ signature == watchedSignature }) { return }

        let previous = locked { () -> [FSEventsWatcher] in
            let old = Array(watchers.values)
            watchers = [:]
            watchedSignature = signature
            return old
        }
        for watcher in previous { watcher.stop() }
        if byVolume.isEmpty {
            log.warn("no readable root: FSEvents watching suspended")
            return
        }

        for (uuid, urls) in byVolume {
            let watcher = FSEventsWatcher(
                roots: urls.sorted(by: { $0.path < $1.path }),
                volUUID: uuid, store: store,
                latency: FSEventsWatcher.defaultLatency,
                queue: DispatchQueue(label: "io.github.basedpolymer.fouine.agent.fsevents.\(uuid)",
                                     qos: .utility)
            ) { [weak self] batch in
                self?.receive(batch: batch, volUUID: uuid)
            }
            do {
                try watcher.start()
                locked { watchers[uuid] = watcher }
                log.info("FSEvents live on \(urls.count) root(s) of volume "
                         + "\(uuid) (latency \(Int(FSEventsWatcher.defaultLatency)) s)")
            } catch {
                log.error("FSEvents refused on volume \(uuid): "
                          + AgentText.describe(error)
                          + " — a silent stream is a symptom of a missing "
                          + "permission, not of inactivity (§5.2).")
            }
        }
    }

    /// Quelles racines méritent un crawl de rattrapage. Décision PURE.
    ///
    /// TROIS cas, et non deux (A2-09). Un `try?` avalait l'échec de lecture et
    /// le rendait indiscernable d'« aucun curseur en base » : une base
    /// momentanément verrouillée, un schéma illisible, et l'agent programmait
    /// un crawl delta de TOUTES les racines en le journalisant comme s'il
    /// l'avait choisi. C'est le seul `try?` du fichier dont la valeur de repli
    /// FABRIQUE du travail. Une erreur se journalise et ne programme rien : le
    /// curseur sera relu au tic suivant.
    static func catchUpRoots(_ roots: [RootRecord],
                             cursor: (String) throws -> UInt64,
                             onError: (RootRecord, Error) -> Void) -> [Int64] {
        var toCrawl: [Int64] = []
        for root in roots {
            do {
                if try cursor(root.volUUID) == 0 { toCrawl.append(root.id) }
            } catch {
                onError(root, error)
            }
        }
        return toCrawl
    }

    /// Curseur inexistant (base neuve, historique jamais posé) : crawl delta de
    /// rattrapage au démarrage. L'historique PURGÉ, lui, est signalé par le
    /// watcher (`requiresFullDelta`) et traité dans `receive`.
    func scheduleCatchUp() {
        let roots = locked { Array(readableRoots.values) }
        let toCrawl = Self.catchUpRoots(
            roots,
            cursor: { [store] in try store.fseventID(volUUID: $0) },
            onError: { [log] root, error in
                log.warn("cannot read the FSEvents cursor of root “\(root.label)”: "
                         + AgentText.describe(error)
                         + " — no catch-up crawl scheduled, the cursor will be "
                         + "read again at the next tick")
            })
        guard !toCrawl.isEmpty else { return }
        log.info("no FSEvents cursor on record: catch-up delta crawl on "
                 + "\(toCrawl.count) root(s)")
        enqueue(rootIDs: Set(toCrawl))
    }

    // MARK: - Règles d'exclusion gardées (lot IG2)

    /// Quelles racines reparcourir parce que leurs règles gardées ont changé.
    /// Décision PURE.
    ///
    /// POURQUOI L'AGENT DOIT REGARDER. Le fichier `.fouineignore` remonte un
    /// événement FSEvents quand on l'enregistre (mesuré au lot IG1) : la passe
    /// part toute seule. Une règle saisie dans les réglages ne touche AUCUN
    /// fichier — sans ce regard, elle attendrait qu'un document de la racine
    /// change, c'est-à-dire parfois des semaines, pendant que la feuille de
    /// l'app promet « à la prochaine mise à jour ».
    ///
    /// AU DÉMARRAGE (`previous == nil`) : toute racine qui porte des règles
    /// gardées. Elles ont pu être saisies pendant que l'agent était arrêté, et
    /// rien d'autre ne le dirait. Le prix est un crawl delta de ces racines à
    /// chaque lancement — quelques secondes, et seulement sur les racines qui
    /// ont des règles.
    static func rootsWithChangedIgnoreRules(previous: [Int64: String]?,
                                            current: [Int64: String]) -> Set<Int64> {
        guard let previous else { return Set(current.keys) }
        let ids = Set(previous.keys).union(current.keys)
        return ids.filter { previous[$0] != current[$0] }
    }

    /// Relit les règles gardées de toutes les racines (une requête) et met en
    /// file celles qui ont changé, parmi les racines lisibles.
    func noticeIgnoreRuleChanges() {
        let current: [Int64: String]
        do { current = try store.ignoreRulesJSONByRoot() }
        catch {
            // Rien n'est retenu : la comparaison se refera au tic suivant,
            // contre le dernier état LU, et ne perdra donc aucun changement.
            log.warn("cannot read the ignore rules kept in the settings: "
                     + AgentText.describe(error))
            return
        }
        let (changed, readable) = locked { () -> (Set<Int64>, [Int64: RootRecord]) in
            let changed = Self.rootsWithChangedIgnoreRules(previous: ignoreRulesSeen,
                                                           current: current)
            ignoreRulesSeen = current
            return (changed, readableRoots)
        }
        let toCrawl = changed.filter { readable[$0] != nil }
        guard !toCrawl.isEmpty else { return }
        let labels = toCrawl.compactMap { readable[$0]?.label }.sorted()
        log.info("ignore rules kept in the settings: pass on "
                 + labels.joined(separator: ", "))
        enqueue(rootIDs: toCrawl)
    }

    func receive(batch: FSEventsWatcher.Batch, volUUID: String) {
        if isStopping { return }
        // Le watcher vient de persister le curseur : le verrou d'écriture est à nous.
        locked { lockHeldBySelf = true }

        let roots = locked { Array(readableRoots.values) }
            .filter { $0.volUUID == volUUID }
        var affected: Set<Int64> = []
        if batch.requiresFullDelta {
            log.warn("FSEvents history too short (volume \(volUUID)): full "
                     + "delta crawl of the roots of this volume")
            for root in roots { affected.insert(root.id) }
        }
        // Comparaison sur les chemins CANONIQUES des deux côtés.
        let bases: [(id: Int64, prefix: String)] = roots.compactMap { root in
            guard let target = try? url(of: root).path else { return nil }
            let canonical = Self.canonical(target)
            return (root.id, canonical.hasSuffix("/") ? canonical : canonical + "/")
        }
        for raw in batch.paths {
            let path = Self.canonical(raw)
            for base in bases
            where path.hasPrefix(base.prefix) || path + "/" == base.prefix {
                affected.insert(base.id)
            }
        }
        guard !affected.isEmpty else {
            // POINT DE REPOS (A2-06). Le verrou est à nous depuis que le
            // watcher a persisté son curseur (`setFSEventID` passe par
            // `writeLocked`), et ce chemin ne va rien empiler sur `work` :
            // sans cette libération, une salve qui ne touche aucune racine —
            // une racine DÉPLACÉE, cas documenté ci-dessous — confisque
            // `fouine.lock` jusqu'au tic suivant (`agent.pollSeconds`, 60 s par
            // défaut), et `fouine index` comme « Indexer maintenant » échouent
            // en sortie 3 alors qu'aucun travail n'est en cours.
            releaseWriteLock()
            log.warn("FSEvents burst (\(batch.paths.count) path(s)) matched no "
                     + "active root — first path: "
                     + (batch.paths.first ?? "none"))
            return
        }
        let labels = roots.filter { affected.contains($0.id) }.map(\.label).sorted()
        log.info("FSEvents burst: \(batch.paths.count) path(s), root(s) "
                 + labels.joined(separator: ", ")
                 + " (cursor \(batch.lastEventID))")
        enqueue(rootIDs: affected)
    }

    // MARK: - File de travail

    func enqueue(rootIDs: Set<Int64>) {
        locked { pending.formUnion(rootIDs) }
        work.async { [weak self] in self?.drain() }
    }

    /// Point de repos : on rend `fouine.lock`. Sans cela l'agent le confisque
    /// jusqu'à sa mort et ni la CLI ni l'app ne peuvent plus indexer (§5.1).
    /// `lockHeldBySelf` retombe du même coup à faux : le test de disponibilité du
    /// §5.7, qui se ferait sur un second descripteur, redevient significatif.
    func releaseWriteLock() {
        store.releaseWriteLock()
        locked { lockHeldBySelf = false }
    }

    func drain() {
        // `defer` : la libération doit avoir lieu même en sortie anticipée
        // (arrêt demandé) ou sur un throw non rattrapé.
        defer { releaseWriteLock() }
        // L'état revient au repos quoi qu'il arrive : sans ce `defer`, une
        // erreur fatale laisserait « extraction du texte » figée dans l'app
        // jusqu'à la péremption des cinq minutes (audit F7).
        defer { if !isStopping { status.publish(.idle, resetProgress: true) } }
        var worked = false
        while !isStopping {
            let next: RootRecord? = locked {
                while let id = pending.first {
                    pending.remove(id)
                    if let root = readableRoots[id] { return root }
                }
                return nil
            }
            guard let root = next else { break }
            worked = true
            do {
                // `IndexPass` prend `fouine.lock` en entrée de passe et le rend
                // en `defer` (audit F3) : le drapeau couvre exactement cette
                // fenêtre, et le `defer` de `drain` le rabaisse.
                locked { lockHeldBySelf = true }
                try pipeline.index(root: root, shouldStop: { [weak self] in
                    self?.isStopping ?? true
                })
            } catch {
                log.error("root “\(root.label)”: \(AgentText.describe(error))")
            }
        }
        if worked && !isStopping {
            pipeline.warmVocabulary()
            requestOCRTick()
        }
    }

    // MARK: - OCR (§5.7)

    private func startTimer() {
        rescheduleTimer(period: settings.snapshot().agentPollSeconds)
        // Première décision OCR sans attendre le premier tic.
        requestOCRTick()
    }

    /// (Re)programme l'horloge, et seulement si la période a changé.
    ///
    /// `agent.pollSeconds` est désormais un RÉGLAGE (audit U2). Une source de
    /// temps créée une fois pour toutes garderait la période du démarrage : la
    /// valeur saisie dans la fenêtre de réglages n'aurait d'effet qu'au prochain
    /// lancement de l'agent — c'est-à-dire jamais, pour un démon que launchd
    /// garde en vie.
    private func rescheduleTimer(period: Int) {
        let (needed, previous) = locked { () -> (Bool, DispatchSourceTimer?) in
            if timer != nil, timerPeriod == period { return (false, nil) }
            let old = timer
            timer = nil
            timerPeriod = period
            return (true, old)
        }
        guard needed else { return }
        // Annuler une source depuis son propre gestionnaire est légal : c'est
        // exactement ce qui se passe quand le tic relit un `pollSeconds` changé.
        previous?.cancel()
        if previous != nil {
            log.info("polling period: \(period) s (agent.pollSeconds)")
        }

        let t = DispatchSource.makeTimerSource(queue: control)
        t.schedule(deadline: .now() + .seconds(period),
                   repeating: .seconds(period), leeway: .seconds(5))
        t.setEventHandler { [weak self] in
            guard let self, !self.isStopping else { return }
            let current = self.settings.reload()
            for warning in current.warnings { self.log.warn(warning) }

            let currentState = self.locked {
                AgentState(phase: .idle,
                           lastVerdict: self.lastVerdict,
                           hasNotifiedQueueDrained: self.lastVerdict == AgentStatusDetail.queueDrained,
                           pollPeriod: self.timerPeriod,
                           lockHeldBySelf: self.lockHeldBySelf,
                           isStopping: self.stopping)
            }
            let (actions, nextState) = Self.timerTick(state: currentState, newSettings: current)
            for action in actions {
                if case .enforceLogRotation = action {
                    self.log.enforceRotation()
                } else if case .sleep(let seconds) = action {
                    self.rescheduleTimer(period: seconds)
                }
            }
            if nextState.pollPeriod == current.agentPollSeconds && self.timerPeriod != current.agentPollSeconds {
                self.rescheduleTimer(period: current.agentPollSeconds)
            }
            self.refreshRoots()
            self.noticeIgnoreRuleChanges()
            self.rebuildWatchers()
            self.requestOCRTick()
        }
        t.resume()
        locked { timer = t; timerPeriod = period }
    }

    /// Un seul tic OCR en attente à la fois : sans cela, une horloge à 60 s
    /// empilerait dix décisions derrière un lot de dix minutes.
    func requestOCRTick() {
        let alreadyQueued = locked { () -> Bool in
            if ocrTickQueued { return true }
            ocrTickQueued = true
            return false
        }
        guard !alreadyQueued else { return }
        work.async { [weak self] in
            guard let self else { return }
            self.locked { self.ocrTickQueued = false }
            self.ocrTick()
        }
    }

    func ocrTick() {
        guard !isStopping else { return }
        // Second point de repos (cf. `drain`). On rend le verrou À L'ENTRÉE aussi :
        // le watcher a pu le reprendre en persistant son curseur de démarrage, et
        // le test de disponibilité du §5.7 — qui passe par un second descripteur —
        // se refuserait alors à lui-même. `defer` pour couvrir les sorties
        // anticipées (file vide, conditions non réunies, échec du lot) ; le lot
        // suivant, enchaîné par `requestOCRTick`, passe par la même file série et
        // ne démarre donc qu'après cette libération.
        releaseWriteLock()
        defer { releaseWriteLock() }

        let queued: Int
        do { queued = try store.ocrQueueLength() }
        catch {
            note("cannot read the OCR queue: \(AgentText.describe(error))")
            return
        }

        let current = settings.snapshot()
        let (heldBySelf, unreadable, rootsPending, prevVerdict) = locked {
            (lockHeldBySelf, unreadableLabels, pending, lastVerdict)
        }
        // Ce que l'agent sait de la préparation du sens (AG1). Sondé ICI, hors
        // de `tick` qui reste pure — et pas du tout quand le réglage est
        // éteint ou que l'OCR a encore du travail.
        let embed = embedSituation(settings: current, ocrQueued: queued)
        let meaningWantsToWork = embed.enabled && embed.modelInstalled
            && embed.pagesLeft > 0 && !embed.campaignHeldByAnother
        // Les sondes du §5.7 (`pmset -g therm` en sous-processus, IOKit) ne se
        // paient que s'il y a du travail : file vide ou extraction en attente,
        // `tick` ne consulte pas le verdict, on ne le calcule pas (§6.2).
        let verdict: AgentConditions.Verdict
        if (queued > 0 || meaningWantsToWork) && rootsPending.isEmpty {
            verdict = AgentConditions.evaluate(lock: AgentPaths.lockURL(),
                                               lockHeldBySelf: heldBySelf,
                                               unreadableRoots: unreadable,
                                               policy: AgentConditions.Policy(current))
        } else {
            verdict = AgentConditions.Verdict(ok: true, blockers: [])
        }
        let currentState = AgentState(
            phase: .idle,
            lastVerdict: prevVerdict,
            hasNotifiedQueueDrained: prevVerdict == AgentStatusDetail.queueDrained,
            pollPeriod: locked { timerPeriod },
            lockHeldBySelf: heldBySelf,
            isStopping: isStopping,
            lastLicenceNoticeAt: locked { lastLicenceNoticeAt }
        )
        let (action, nextState) = Self.tick(
            state: currentState,
            conditions: verdict,
            clock: Date(),
            settings: current,
            ocrQueueLength: queued,
            pendingRoots: rootsPending,
            embed: embed,
            // Le fichier de licence est relu À CHAQUE RÉVEIL, et pas mémorisé :
            // une clé activée depuis l'application doit remettre l'agent au
            // travail au tic suivant, sans redémarrage de launchd. Une lecture
            // de quelques centaines d'octets par minute (lot L1C).
            // AUCUN RÉSEAU ICI, JAMAIS : l'agent lit le verdict, il ne le
            // demande à personne.
            licenceAllowsIndexing: Self.licenceAllowsIndexing()
        )
        locked { lastLicenceNoticeAt = nextState.lastLicenceNoticeAt }
        // LE MOTEUR NE SURVIT PAS À UN TIC QUI NE PRÉPARE RIEN (AG1). ~90 Mio
        // gardés sur une machine à 8 Gio pour un travail qu'on ne fait plus,
        // c'est le genre de démon qu'on finit par éteindre.
        if !Self.leadsToEmbedBatch(action) { embedder.release() }
        // Conditions du lot à venir : la sonde d'interruption repart de ce
        // relevé plutôt que de lancer `pmset` dans la seconde qui suit.
        locked { embedConditionsOK = verdict.ok; embedConditionsAt = Date() }
        // `lastVerdict` n'est PAS recopié depuis `nextState` : c'est `note()`,
        // dans `execute`, qui le pose — et qui ne journalise qu'au CHANGEMENT.
        // Le poser avant ferait taire le journal (« OCR waiting — … », « OCR
        // queue empty ») pour toujours.
        locked { lockHeldBySelf = nextState.lockHeldBySelf }

        execute(action: action, queued: queued, current: current,
                verdictSignature: verdict.signature)
    }

    /// - Parameter verdictSignature: la NATURE des blocages du §5.7, sans les
    ///   nombres (`AgentConditions.Verdict.signature`). C'est elle qui décide
    ///   si `note()` doit reparler : le pourcentage de `CPU_Speed_Limit` bouge
    ///   à chaque tic, et le journal partait avec lui (A2-12).
    func execute(action: AgentAction, queued: Int = 0,
                 current: SettingsSnapshot? = nil,
                 verdictSignature: String? = nil) {
        let currentSnapshot = current ?? settings.snapshot()
        switch action {
        case .none, .sleep:
            break
        case .noteLicenceBlocked:
            log.info("licence: trial over, nothing to do — searching still "
                     + "works; enter a licence key in Fouine to resume indexing")
        case .runExtraction(let rootIDs):
            enqueue(rootIDs: rootIDs)
        case .runOCRBatch(let minutes, let jobs, let queuedPages):
            note("OCR: the six conditions of §5.7 are met")
            log.info("OCR: batch of \(minutes) min at \(jobs) job(s)")
            locked { lockHeldBySelf = true }
            let probe = startOCRProbe(initial: queuedPages)
            defer { probe.cancel() }
            do {
                let outcome = try OCRRun.run(store: store, jobs: jobs,
                                             budgetMinutes: minutes,
                                             prioFolder: nil, only: nil,
                                             languages: currentSnapshot.ocrLanguages,
                                             log: { [log] in log.info($0) })
                switch outcome {
                case .completed:
                    log.info("OCR: queue empty")
                case .budgetExhausted:
                    log.info("OCR: batch budget reached, queue intact — the "
                             + "conditions will be decided again for the next batch")
                    if !isStopping { requestOCRTick() }
                }
            } catch {
                log.error("OCR: \(AgentText.describe(error))")
            }
        case .runEmbedBatch(let minutes, let pages):
            runEmbedBatch(budgetMinutes: minutes, pagesLeft: pages)
        case .publishStatus(let phase, let detail, let done, let total):
            if !detail.isEmpty {
                // Le journal est ANGLAIS (docs/i18n.md) : le jeton s'y rend,
                // il ne s'y imprime pas — « queue-drained » n'est une phrase
                // dans aucune langue (audit A1m-10).
                let english = AgentStatusDetail.english(detail)
                let text = phase == .waiting ? "OCR waiting — " + english : english
                // La ligne détaillée part au premier passage, avec son
                // pourcentage ; ensuite, silence tant que la NATURE du blocage
                // ne change pas.
                let key = (phase == .waiting ? verdictSignature : nil).map {
                    "OCR waiting — " + $0
                }
                note(text, key: key)
            }
            if done == nil && total == nil {
                status.publish(phase, detail: detail, resetProgress: true)
            } else {
                status.publish(phase, detail: detail, done: done ?? 0, total: total ?? queued)
            }
        case .notifyQueueDrained:
            note(AgentStatusDetail.english(AgentStatusDetail.queueDrained))
        case .enforceLogRotation:
            log.enforceRotation()
        case .sequence(let actions):
            for a in actions {
                execute(action: a, queued: queued, current: currentSnapshot,
                        verdictSignature: verdictSignature)
            }
        }
    }

    /// Sonde de progression d'un lot d'OCR (audit F7).
    ///
    /// `OCRRun` ne rapporte rien à son appelant — sa signature est imposée par
    /// le §6.3 — mais la file rétrécit page par page (une transaction par page).
    /// On la mesure donc de l'extérieur, toutes les 2 s, avec le SEUL compte
    /// dont on a besoin : `ocrQueueLength()` et non `stats()`, qui ferait une
    /// quinzaine de `count(*)` dont un sur une table FTS5 de 380 000 pages —
    /// toutes les deux secondes, pendant dix minutes.
    private func startOCRProbe(initial: Int) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2),
                       leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, !self.isStopping else { return }
            guard let remaining = try? self.store.ocrQueueLength() else { return }
            self.status.progress(done: max(0, initial - remaining),
                                 total: initial,
                                 detail: AgentStatusDetail.pagesLeft(remaining))
        }
        timer.resume()
        return timer
    }

    // MARK: - Préparation du sens : ce que l'exécutant doit à la décision (AG1)

    /// Le verdict de licence, lu sur le disque (lot L1C).
    ///
    /// L'essai N'EST PAS DÉMARRÉ ici : c'est l'application ou `fouine crawl`
    /// qui posent `trial_started`, jamais un démon qui tourne tout seul — un
    /// agent qui consommerait le premier jour d'essai d'une machine où
    /// personne n'a rien ouvert serait un vol de jour.
    static func licenceAllowsIndexing() -> Bool {
        let url = LicenseStore.fileURL(databaseURL: AgentPaths.databaseURL())
        return LicenseState.compute(file: LicenseStore.load(at: url)).allowsIndexing
    }

    /// L'action mène-t-elle à un lot de vecteurs ? (Une `sequence` en porte un.)
    static func leadsToEmbedBatch(_ action: AgentAction) -> Bool {
        switch action {
        case .runEmbedBatch: return true
        case .sequence(let actions): return actions.contains(where: leadsToEmbedBatch)
        default: return false
        }
    }

    /// L'état courant, tel que les décisions post-lot le demandent.
    func currentAgentState() -> AgentState {
        locked {
            AgentState(phase: .preparingMeaning,
                       lastVerdict: lastVerdict,
                       hasNotifiedQueueDrained: true,
                       pollPeriod: timerPeriod,
                       lockHeldBySelf: lockHeldBySelf,
                       isStopping: stopping)
        }
    }

    /// Coupe le lot en cours quand l'arrêt est demandé ou qu'une condition du
    /// §5.7 tombe. Les conditions sont relues au plus toutes les 30 s : chaque
    /// évaluation lance `pmset` en sous-processus, et `shouldStop` est consulté
    /// entre deux lots d'inférence, c'est-à-dire toutes les cinq secondes.
    func shouldStopEmbedding() -> Bool {
        if isStopping { return true }
        let (ok, at) = locked { (embedConditionsOK, embedConditionsAt) }
        guard Date().timeIntervalSince(at) >= 30 else { return !ok }
        let (held, unreadable) = locked { (lockHeldBySelf, unreadableLabels) }
        let verdict = AgentConditions.evaluate(
            lock: AgentPaths.lockURL(), lockHeldBySelf: held,
            unreadableRoots: unreadable,
            policy: AgentConditions.Policy(settings.snapshot()))
        locked { embedConditionsOK = verdict.ok; embedConditionsAt = Date() }
        if !verdict.ok {
            log.info("meaning: stopping the batch — "
                     + verdict.blockers.joined(separator: "; "))
        }
        return !verdict.ok
    }

    /// Point de repos après un lot de vecteurs.
    func releaseWriteLockAfterEmbed() { releaseWriteLock() }

    /// Horodate la fin du lot : c'est ce que `fouine status` relit pour dire
    /// « last batch … » quand l'agent n'est pas en train de travailler à la
    /// seconde où on le regarde. Écriture hors `fouine.lock` (settings).
    func markEmbedBatchDone() {
        do {
            try store.writeSetting(SettingKeys.agentLastEmbedBatchAt.key,
                                   String(Int(Date().timeIntervalSince1970)))
        } catch {
            log.warn("meaning: could not record the end of the batch: "
                     + AgentText.describe(error))
        }
    }

    /// Journalise un état d'attente une seule fois, tant qu'il ne change pas :
    /// un agent qui écrit une ligne par minute remplit 10 Mo pour rien.
    ///
    /// - Parameter key: la clé de dédoublonnage, quand elle diffère du message.
    ///   Le message d'attente porte des NOMBRES qui bougent à chaque tic
    ///   (`CPU_Speed_Limit 33 %`, puis 28, puis 25…) : dédoublonner dessus ne
    ///   dédoublonnait rien, et ces lignes faisaient 44 % du journal (A2-12).
    ///   La clé est alors la NATURE du blocage, `Verdict.signature`.
    func note(_ message: String, key: String? = nil) {
        let identity = key ?? message
        let changed = locked { () -> Bool in
            if lastVerdict == identity { return false }
            lastVerdict = identity
            return true
        }
        if changed { log.info(message) }
    }

    // MARK: - Arrêt (SIGTERM de launchd)

    func requestStop(signal name: String) {
        let already = locked { () -> Bool in
            if stopping { return true }
            stopping = true
            return false
        }
        if already { return }

        log.info("\(name) received — shutting down")
        // Publié TOUT DE SUITE : l'app doit lire « arrêté » à la seconde, et non
        // au bout des cinq minutes de péremption d'`agent_status` (audit F7).
        status.stopped(AgentStatusDetail.signalReceived(name))
        let (t, running) = locked { (timer, Array(watchers.values)) }
        t?.cancel()
        for watcher in running { watcher.stop() }
        locked { watchers = [:]; watchedSignature = "" }

        // Barrière : on attend que le travail en vol rende la main. Au-delà de la
        // grâce (launchd tue à 20 s), on sort quand même : le §6.3 garantit qu'une
        // page = une transaction, donc la file reste cohérente et la page en cours
        // sera simplement reprise.
        let done = DispatchSemaphore(value: 0)
        work.async { done.signal() }
        let grace = AgentPaths.shutdownGraceSeconds
        if done.wait(timeout: .now() + grace) == .timedOut {
            log.warn(String(format: "work still in flight after %.0f s — "
                            + "exiting now; the page in progress will be picked "
                            + "up again (one page = one transaction, §6.3)",
                            grace))
        }
        log.info("stopped")
        onExit(0)
    }
}
