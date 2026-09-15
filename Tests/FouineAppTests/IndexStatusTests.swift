// IndexStatusTests.swift — l'état unique de l'index (session UX du 04/09/2026).
// Propriété : A-App. SPEC §5.6, amendement « carte Index ».
//
// Les tests comparent des CAS, jamais des phrases ; les phrases sont
// vérifiées à part pour ce qu'elles ne doivent PAS dire (« agent », « OCR »,
// « verrou », « ré-enregistrer »).

import XCTest
import FouineCore
@testable import FouineApp

final class IndexStatusTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func root(id: Int64 = 1, label: String = "Docs", mounted: Bool = true,
                      readable: Bool = true) -> RootStatus {
        RootStatus(
            record: RootRecord(id: id, volUUID: "U\(id)", relPath: label.lowercased(),
                               label: label, enabled: true),
            absolutePath: mounted ? "/Volumes/Data/\(label)" : nil,
            mounted: mounted, readable: readable, reason: nil)
    }

    private func status(_ phase: AgentStatusRecord.Phase, detail: String = "",
                        done: Int = 0, total: Int = 0,
                        age: TimeInterval = 2) -> AgentStatusRecord {
        AgentStatusRecord(phase: phase, detail: detail, done: done, total: total,
                          startedAt: now.addingTimeInterval(-600),
                          updatedAt: now.addingTimeInterval(-age),
                          pid: getpid())   // vivant : c'est ce processus
    }

    private func input(probed: Bool = true,
                       roots: [RootStatus]? = nil,
                       rootsError: String? = nil,
                       agentState: AgentOperationalState = .active,
                       appCopies: AppCopiesReport.Verdict = .ok,
                       lock: WriteLock.LockStatus = .free,
                       indexing: IndexingState = IndexingState(),
                       automatic: Bool = true,
                       agentStatus: AgentStatusRecord? = nil,
                       scans: Int = 0,
                       remaining: TimeInterval? = nil) -> IndexStatusInput {
        let roots = roots ?? [root()]
        let health = HealthBannerEvaluator.evaluate(
            agentState: agentState, appCopies: appCopies, lockStatus: lock,
            semanticInstalled: true, hasVectors: true, roots: roots)
        return IndexStatusInput(
            probed: probed, roots: roots, rootsError: rootsError, health: health,
            indexing: indexing, automatic: automatic, agentState: agentState,
            agentStatus: agentStatus, scansWaiting: scans,
            agentRemainingSeconds: remaining, now: now)
    }

    // MARK: - Démarrage

    /// Tant que rien n'a été lu, on ne dit rien — et surtout pas « ne démarre
    /// pas » avec un bouton : c'était le « Ré-enregistrer » furtif.
    func testNothingIsSaidBeforeTheFirstProbe() {
        let i = input(probed: false, agentState: .registeredButSilent)
        XCTAssertEqual(IndexStatusEvaluator.evaluate(i), .checking)
        XCTAssertNil(IndexStatus.checking.primaryAction)
    }

    func testNoFoldersOffersToAddOne() {
        let s = IndexStatusEvaluator.evaluate(input(roots: []))
        XCTAssertEqual(s, .noFolders)
        XCTAssertEqual(s.primaryAction, .addFolder)
    }

    /// Une lecture des racines qui échoue n'est pas « aucun dossier ».
    func testRootsErrorIsNotNoFolders() {
        let s = IndexStatusEvaluator.evaluate(
            input(roots: [], rootsError: "boom", agentStatus: status(.idle)))
        XCTAssertNotEqual(s, .noFolders)
    }

    // MARK: - La passe de l'application passe avant tout

    func testForegroundPassIsWorkingAndStoppable() {
        var indexing = IndexingState(running: true, phase: "extracting")
        indexing.total = 10
        indexing.done = 3
        let s = IndexStatusEvaluator.evaluate(
            input(agentState: .registeredButSilent, indexing: indexing))
        guard case .working(let activity, let progress, let detail, let stoppable) = s else {
            return XCTFail("\(s)")
        }
        XCTAssertEqual(activity, .updating)
        XCTAssertEqual(progress, IndexProgress(done: 3, total: 10, remainingSeconds: nil))
        XCTAssertEqual(detail, "extracting")
        XCTAssertTrue(stoppable)
        XCTAssertEqual(s.primaryAction, .stop)
    }

    func testForegroundOCRReadsScans() {
        var indexing = IndexingState(running: true, activity: .readingScans, phase: "")
        indexing.cancelled = true
        let s = IndexStatusEvaluator.evaluate(input(indexing: indexing))
        guard case .working(let activity, let progress, let detail, let stoppable) = s else {
            return XCTFail("\(s)")
        }
        XCTAssertEqual(activity, .readingScans)
        XCTAssertNil(progress, "total nul = indéterminé")
        XCTAssertNil(detail, "phrase vide = pas de détail")
        XCTAssertFalse(stoppable, "déjà en cours d'annulation")
        XCTAssertNil(s.primaryAction)
    }

    // MARK: - Ce qui réclame un geste

    func testUnreadableFolderComesFirstWithItsGesture() {
        let s = IndexStatusEvaluator.evaluate(
            input(roots: [root(readable: false)], agentState: .requiresApproval))
        XCTAssertEqual(s, .needsAttention(.folderNotAllowed(folder: "Docs")))
        XCTAssertEqual(s.primaryAction, .openPrivacySettings)
    }

    func testUnpluggedDiskAsksToCheckAgain() {
        let s = IndexStatusEvaluator.evaluate(input(roots: [root(mounted: false)]))
        XCTAssertEqual(s, .needsAttention(.diskNotPluggedIn(folder: "Docs")))
        XCTAssertEqual(s.primaryAction, .retestFolders)
    }

    func testAgentAttentionsCarryTheirGesture() {
        XCTAssertEqual(
            IndexStatusEvaluator.evaluate(input(agentState: .requiresApproval)),
            .needsAttention(.awaitingApproval))
        XCTAssertEqual(
            IndexStatusEvaluator.evaluate(input(agentState: .notFound)),
            .needsAttention(.serviceMissing))
        XCTAssertEqual(
            IndexStatusEvaluator.evaluate(
                input(agentState: .registeredButSilent,
                      appCopies: .multipleCopies(extras: ["/tmp/Fouine.app"]))),
            .needsAttention(.severalCopies))
        // AP-21 : hors du dossier Applications, « Relancer » ne pouvait que
        // réafficher le problème — le ré-enregistrement se refuse avant même
        // d'atteindre le système. Le geste qui répare est de montrer la copie
        // à déplacer.
        XCTAssertEqual(IndexStatus.needsAttention(.serviceMissing).primaryAction,
                       .revealInstalledCopy)
        XCTAssertEqual(IndexStatus.needsAttention(.severalCopies).primaryAction,
                       .restartAutomaticUpdates)
        XCTAssertEqual(
            IndexStatus.needsAttention(.automaticUpdatesNotStarting).primaryAction,
            .restartAutomaticUpdates)
    }

    /// Enregistré, aucun rapport jamais écrit : là, il ne démarre vraiment pas.
    func testSilentWithoutAnyReportNeedsARestart() {
        let s = IndexStatusEvaluator.evaluate(
            input(agentState: .registeredButSilent, agentStatus: nil))
        XCTAssertEqual(s, .needsAttention(.automaticUpdatesNotStarting))
        XCTAssertEqual(s.primaryAction, .restartAutomaticUpdates)
    }

    /// Enregistré, processus VIVANT mais muet depuis six minutes (machine
    /// sortie de veille) : au repos, pas en panne. Chaque réveil affichait
    /// sinon une minute d'orange et un bouton inutile.
    func testSilentButAliveIsIdleNotBroken() {
        let stale = status(.idle, age: 6 * 60)
        XCTAssertTrue(stale.isStale(at: now))
        let s = IndexStatusEvaluator.evaluate(
            input(agentState: .registeredButSilent, agentStatus: stale, scans: 12))
        XCTAssertEqual(s, .idle(automatic: true, scansWaiting: 12,
                                lastUpdate: stale.updatedAt))
        XCTAssertNil(s.primaryAction)
    }

    /// Processus DISPARU : là, c'est une panne.
    func testSilentAndDeadNeedsARestart() {
        var dead = status(.ocr, age: 6 * 60)
        dead.pid = 2_147_483_000   // aucun processus ne porte ce numéro
        XCTAssertFalse(dead.isAlive)
        let s = IndexStatusEvaluator.evaluate(
            input(agentState: .registeredButSilent, agentStatus: dead))
        XCTAssertEqual(s, .needsAttention(.automaticUpdatesNotStarting))
    }

    // MARK: - Ce que l'agent fait

    func testAgentPhasesMapToActivities() {
        let crawl = IndexStatusEvaluator.evaluate(
            input(agentStatus: status(.crawl, detail: AgentStatusDetail.starting)))
        XCTAssertEqual(crawl, .working(activity: .updating, progress: nil,
                                       detail: nil, stoppable: false))

        let extract = IndexStatusEvaluator.evaluate(
            input(agentStatus: status(.extract, detail: AgentStatusDetail.document("Cours.pdf"),
                                      done: 4, total: 9)))
        XCTAssertEqual(extract, .working(
            activity: .updating,
            progress: IndexProgress(done: 4, total: 9, remainingSeconds: nil),
            detail: "Cours.pdf", stoppable: false))

        let ocr = IndexStatusEvaluator.evaluate(
            input(agentStatus: status(.ocr, detail: AgentStatusDetail.pagesLeft(315),
                                      done: 11, total: 326),
                  remaining: 7_200))
        XCTAssertEqual(ocr, .working(
            activity: .readingScans,
            progress: IndexProgress(done: 11, total: 326, remainingSeconds: 7_200),
            detail: nil, stoppable: false))
        XCTAssertNil(ocr.primaryAction, "la passe de l'agent ne s'arrête pas d'ici")
    }

    /// Le total publié peut être inférieur au fait (file qui grossit) : la
    /// barre ne dépasse jamais 100 %.
    func testProgressNeverExceedsTotal() {
        let s = IndexStatusEvaluator.evaluate(
            input(agentStatus: status(.ocr, done: 40, total: 30)))
        guard case .working(_, let progress?, _, _) = s else { return XCTFail("\(s)") }
        XCTAssertEqual(progress.total, 40)
        XCTAssertEqual(progress.fraction, 1)
    }

    func testWaitingReasonsAreNamed() {
        let battery = IndexStatusEvaluator.evaluate(
            input(agentStatus: status(.waiting, detail: "no AC power; CPU_Speed_Limit 33% (< 70%)"),
                  scans: 13_716))
        XCTAssertEqual(battery, .paused(reason: .onBattery, scansWaiting: 13_716))
        XCTAssertEqual(battery.primaryAction, .readScans,
                       "on peut passer outre et lire tout de suite")

        XCTAssertEqual(IndexPauseReason.parse("low power mode is on"), .lowPowerMode)
        XCTAssertEqual(IndexPauseReason.parse("CPU_Speed_Limit 46% (< 70%)"), .machineHot)
        XCTAssertEqual(IndexPauseReason.parse("thermalState serious"), .machineHot)
        XCTAssertEqual(IndexPauseReason.parse("fouine.lock is held by another process"),
                       .anotherProgramWriting)
        XCTAssertEqual(IndexPauseReason.parse("unreadable root(s): Livres"), .folderUnreadable)
        XCTAssertEqual(IndexPauseReason.parse("mercury retrograde"),
                       .other("mercury retrograde"))
    }

    func testIdleAgentIsUpToDate() {
        let idle = status(.idle, detail: AgentStatusDetail.queueDrained, age: 30)
        let s = IndexStatusEvaluator.evaluate(input(agentStatus: idle))
        XCTAssertEqual(s, .idle(automatic: true, scansWaiting: 0, lastUpdate: idle.updatedAt))
        XCTAssertNil(s.primaryAction)
        XCTAssertNil(s.secondaryAction)
    }

    /// L'interrupteur éteint : la carte propose « Mettre à jour maintenant »
    /// et, s'il y a des pages scannées, « Lire les pages scannées… » en second.
    func testManualModeOffersTheTwoGestures() {
        let s = IndexStatusEvaluator.evaluate(
            input(agentState: .off, automatic: false, agentStatus: nil, scans: 5))
        XCTAssertEqual(s, .idle(automatic: false, scansWaiting: 5, lastUpdate: nil))
        XCTAssertEqual(s.primaryAction, .updateNow)
        XCTAssertEqual(s.secondaryAction, .readScans)

        let none = IndexStatusEvaluator.evaluate(
            input(agentState: .off, automatic: false, agentStatus: nil, scans: 0))
        XCTAssertEqual(none.primaryAction, .updateNow)
        XCTAssertNil(none.secondaryAction)
    }

    /// Interrupteur éteint mais un vieux statut en base : il ne compte plus.
    func testManualModeIgnoresAStaleAgentStatus() {
        let s = IndexStatusEvaluator.evaluate(
            input(agentState: .off, automatic: false, agentStatus: status(.ocr, done: 1, total: 9)))
        guard case .idle(let automatic, _, _) = s else { return XCTFail("\(s)") }
        XCTAssertFalse(automatic)
    }

    // MARK: - Un autre programme écrit

    func testCommandLineWriteIsWorkingWithoutAGesture() {
        let holder = LockHolder(pid: 4242, role: .cli, since: now.addingTimeInterval(-60))
        let s = IndexStatusEvaluator.evaluate(
            input(lock: .held(holder), agentStatus: status(.idle)))
        XCTAssertEqual(s, .working(activity: .externalWrite, progress: nil,
                                   detail: nil, stoppable: false))
        XCTAssertNil(s.primaryAction)
    }

    /// SA PROPRE ÉCRITURE N'EST PAS CELLE D'UN AUTRE (BU-31). Le rapport de
    /// santé ne se relit que toutes les trente secondes : entre la fin d'une
    /// passe lancée d'ici et la lecture suivante, la carte annonçait « Un
    /// autre programme écrit dans l'index » alors que Fouine venait de lire
    /// ses propres pages scannées.
    func testItsOwnWriteIsNotAnotherProgram() {
        let mine = LockHolder(pid: getpid(), role: .app,
                              since: now.addingTimeInterval(-60))
        let s = IndexStatusEvaluator.evaluate(
            input(lock: .held(mine), agentStatus: status(.idle)))
        guard case .idle = s else {
            return XCTFail("attendu « à jour », obtenu \(s)")
        }

        // Une SECONDE Fouine ouverte sur la même base, elle, est bien un autre
        // programme : c'est le pid qui tranche, pas le rôle.
        let other = LockHolder(pid: 4242, role: .app,
                               since: now.addingTimeInterval(-60))
        XCTAssertEqual(
            IndexStatusEvaluator.evaluate(
                input(lock: .held(other), agentStatus: status(.idle))),
            .working(activity: .externalWrite, progress: nil,
                     detail: nil, stoppable: false))
    }

    /// Le verrou de l'agent sans statut frais : il travaille, on le dit.
    func testAgentLockWithoutFreshStatusIsWorking() {
        let holder = LockHolder(pid: 4242, role: .agent, since: now.addingTimeInterval(-60))
        let s = IndexStatusEvaluator.evaluate(input(lock: .held(holder), agentStatus: nil))
        XCTAssertEqual(s, .working(activity: .updating, progress: nil,
                                   detail: nil, stoppable: false))
    }

    /// Un verrou PÉRIMÉ se répare seul : ce n'est pas un travail en cours.
    func testStaleLockIsNotWork() {
        let holder = LockHolder(pid: 4242, role: .cli, since: now.addingTimeInterval(-9_000))
        let s = IndexStatusEvaluator.evaluate(
            input(lock: .stale(holder), agentStatus: status(.idle)))
        guard case .idle = s else { return XCTFail("\(s)") }
    }

    // MARK: - Les gestes qui exigent la fenêtre principale (IX2)

    /// Un geste qui s'accroche à la fenêtre principale ne ferait RIEN, lancé
    /// depuis la fenêtre « Votre index » alors qu'elle est fermée : on la
    /// ramène d'abord. Même table de vérité que l'ancien
    /// `MenuBarModel.needsWindow` (test déplacé de `MenuBarModelTests`).
    func testGesturesThatHangOnTheMainWindowBringItBack() {
        for action: IndexAction in [.updateNow, .readScans, .addFolder,
                                    .restartAutomaticUpdates] {
            XCTAssertTrue(action.needsMainWindow, "\(action)")
        }
        for action: IndexAction in [.stop, .openLoginItems, .openPrivacySettings,
                                    .revealInstalledCopy, .retestFolders] {
            XCTAssertFalse(action.needsMainWindow, "\(action)")
        }
    }

    // MARK: - Pictogramme de la barre des menus (AP1, rendu après IX2)

    /// Trois familles, et le partage exact des états entre elles : tout ce qui
    /// n'est ni un travail en cours ni un geste attendu reste la loupe — un
    /// contrôle en cours ou une mise à jour en pause n'a pas à alerter.
    func testGlyphFamilies() {
        XCTAssertEqual(IndexStatus.checking.glyph, .quiet)
        XCTAssertEqual(IndexStatus.noFolders.glyph, .quiet)
        XCTAssertEqual(IndexStatus.idle(automatic: true, scansWaiting: 0, lastUpdate: nil).glyph, .quiet)
        XCTAssertEqual(IndexStatus.paused(reason: .onBattery, scansWaiting: 3).glyph, .quiet)
        XCTAssertEqual(IndexStatus.working(activity: .updating, progress: nil,
                                           detail: nil, stoppable: true).glyph, .working)
        XCTAssertEqual(IndexStatus.needsAttention(.awaitingApproval).glyph, .attention)
    }

    // MARK: - Temps restant

    func testEstimatorNeedsTwoPointsAndRealProgress() {
        var e = IndexRateEstimator()
        XCTAssertNil(e.remainingSeconds)
        e.observe(status(.ocr, done: 10, total: 1_010, age: 100), now: now)
        XCTAssertNil(e.remainingSeconds, "un seul point")
        e.observe(status(.ocr, done: 10, total: 1_010, age: 50), now: now)
        XCTAssertNil(e.remainingSeconds, "aucune progression")
        e.observe(status(.ocr, done: 110, total: 1_010, age: 0), now: now)
        // 100 pages en 100 s = 1 p/s ; 900 restantes = 900 s.
        XCTAssertEqual(e.remainingSeconds ?? -1, 900, accuracy: 1)
    }

    func testEstimatorResetsWhenThePhaseOrTotalChanges() {
        var e = IndexRateEstimator()
        e.observe(status(.ocr, done: 0, total: 100, age: 100), now: now)
        e.observe(status(.ocr, done: 50, total: 100, age: 50), now: now)
        XCTAssertNotNil(e.remainingSeconds)
        e.observe(status(.extract, done: 1, total: 20, age: 40), now: now)
        XCTAssertNil(e.remainingSeconds, "nouvelle phase : le débit repart de zéro")
        e.observe(status(.extract, done: 3, total: 20, age: 20), now: now)
        XCTAssertNotNil(e.remainingSeconds)
        e.observe(status(.extract, done: 3, total: 40, age: 10), now: now)
        XCTAssertNil(e.remainingSeconds, "nouveau total : idem")
    }

    func testEstimatorIgnoresAbsurdlySlowRates() {
        var e = IndexRateEstimator()
        e.observe(status(.ocr, done: 0, total: 100_000, age: 7_200), now: now)
        e.observe(status(.ocr, done: 1, total: 100_000, age: 0), now: now)
        XCTAssertNil(e.remainingSeconds, "une page en deux heures ne projette rien d'utile")
    }

    func testEstimatorSlidesItsWindow() {
        var e = IndexRateEstimator()
        // Débit lent il y a longtemps, rapide récemment : la fenêtre de dix
        // minutes ne garde que le récent.
        e.observe(status(.ocr, done: 0, total: 10_000, age: 3_000), now: now)
        e.observe(status(.ocr, done: 10, total: 10_000, age: 2_000), now: now)
        e.observe(status(.ocr, done: 20, total: 10_000, age: 500), now: now)
        e.observe(status(.ocr, done: 520, total: 10_000, age: 0), now: now)
        // Entre −500 s et 0 : 500 pages en 500 s = 1 p/s → 9 480 s restantes.
        XCTAssertEqual(e.remainingSeconds ?? -1, 9_480, accuracy: 1)
    }

    // MARK: - Les phrases

    /// Aucun mot du jargon dans ce que la carte affiche, quel que soit l'état.
    func testTextsSpeakToNonTechnicians() {
        let statuses: [IndexStatus] = [
            .checking, .noFolders,
            .needsAttention(.folderNotAllowed(folder: "Docs")),
            .needsAttention(.diskNotPluggedIn(folder: "Docs")),
            .needsAttention(.awaitingApproval),
            .needsAttention(.automaticUpdatesNotStarting),
            .needsAttention(.severalCopies),
            .needsAttention(.serviceMissing),
            .working(activity: .updating, progress: nil, detail: nil, stoppable: true),
            .working(activity: .readingScans, progress: nil, detail: nil, stoppable: false),
            .working(activity: .preparingMeaning, progress: nil, detail: nil, stoppable: true),
            .working(activity: .externalWrite, progress: nil, detail: nil, stoppable: false),
            .paused(reason: .onBattery, scansWaiting: 3),
            .paused(reason: .lowPowerMode, scansWaiting: 3),
            .paused(reason: .machineHot, scansWaiting: 3),
            .paused(reason: .anotherProgramWriting, scansWaiting: 3),
            .paused(reason: .folderUnreadable, scansWaiting: 3),
            .idle(automatic: true, scansWaiting: 0, lastUpdate: now.addingTimeInterval(-200)),
            .idle(automatic: true, scansWaiting: 7, lastUpdate: nil),
            .idle(automatic: false, scansWaiting: 0, lastUpdate: nil),
            .idle(automatic: false, scansWaiting: 7, lastUpdate: nil),
        ]
        let banned = ["agent", "OCR", "verrou", "lock", "pid", "vecteur", "vector",
                      "register", "enregistr", "launchd", "embed", "sémantique", "semantic"]
        for status in statuses {
            var texts = [IndexStatusText.headline(status)]
            if let detail = IndexStatusText.detail(status, now: now) { texts.append(detail) }
            if let action = status.primaryAction { texts.append(IndexStatusText.label(action)) }
            if let action = status.secondaryAction { texts.append(IndexStatusText.label(action)) }
            for text in texts {
                XCTAssertFalse(text.isEmpty, "\(status) rend une phrase vide")
                for word in banned {
                    XCTAssertFalse(text.lowercased().contains(word.lowercased()),
                                   "« \(word) » dans « \(text) » (\(status))")
                }
            }
        }
    }

    func testRemainingTimeIsSaidInRoundFigures() {
        XCTAssertEqual(IndexStatusText.remaining(30), "less than two minutes left")
        XCTAssertEqual(IndexStatusText.remaining(25 * 60), "about 25 min left")
        XCTAssertEqual(IndexStatusText.remaining(2.4 * 3600), "about 2 h left")
        // Hors bundle, un pluriel se rend par sa CLÉ (« day(s) ») : le rendu
        // « days » est prouvé par `L10nTests.testCompiledCataloguesRenderTheCountsThemselves`.
        XCTAssertTrue(IndexStatusText.remaining(3 * 86_400).hasPrefix("about 3 day"))
        let line = IndexStatusText.progressLine(
            IndexProgress(done: 312, total: 1_200, remainingSeconds: 7_200))
        XCTAssertTrue(line.contains("312"), line)
        XCTAssertTrue(line.hasSuffix("about 2 h left"), line)
    }

    func testAgeIsSaidWithoutSeconds() {
        XCTAssertEqual(IndexStatusText.age(since: now.addingTimeInterval(-10), now: now), "a moment")
        XCTAssertEqual(IndexStatusText.age(since: now.addingTimeInterval(-600), now: now), "10 min")
        XCTAssertEqual(IndexStatusText.age(since: now.addingTimeInterval(-7_200), now: now), "2 h")
        XCTAssertTrue(IndexStatusText.age(since: now.addingTimeInterval(-3 * 86_400), now: now).hasPrefix("3 day"))
    }

    /// Toutes les clés de la carte sont dans le catalogue, en anglais et en
    /// français.
    func testEveryIndexStatusKeyIsTranslated() throws {
        let catalog = try L10nTests.catalog()
        let keys = [
            "Checking…", "Up to date", "Up to date — %lld scanned page(s) to read",
            "Manual updates", "Manual updates — %lld scanned page(s) to read",
            "Updating the index", "Reading scanned pages", "Preparing search by meaning",
            "The index is being updated", "Update now", "Read scanned pages…",
            "Restart automatic updates", "Check again", "about %lld min left",
            "about %lld h left", "about %lld day(s) left",
            "They will be read once the Mac is plugged in.",
            "Automatic updates are not starting", "Waiting: %@", "Updated %@ ago",
        ]
        for key in keys {
            XCTAssertTrue(catalog.keys.contains(key), "« \(key) » manque au catalogue")
        }
    }

    // MARK: - Habillage de la carte (UX-03)

    /// La couleur porte, à elle seule, « tout va bien » / « à toi de jouer » :
    /// une correspondance fausse ne se verrait qu'à l'usage, sur la machine de
    /// quelqu'un d'autre.
    func testTheCardTintFollowsTheState() {
        XCTAssertEqual(IndexStatus.checking.tint, .quiet)
        XCTAssertEqual(IndexStatus.noFolders.tint, .quiet)
        XCTAssertEqual(IndexStatus.needsAttention(.awaitingApproval).tint, .attention)
        XCTAssertEqual(IndexStatus.working(activity: .updating, progress: nil,
                                           detail: nil, stoppable: true).tint,
                       .working)
        // « En attente : sur batterie » dit AUSSI que l'index est à jour ; ce
        // qui reste se fera tout seul, il n'y a pas de quoi alerter.
        XCTAssertEqual(IndexStatus.paused(reason: .onBattery, scansWaiting: 12).tint,
                       .upToDate)
        XCTAssertEqual(IndexStatus.idle(automatic: true, scansWaiting: 0,
                                        lastUpdate: nil).tint, .upToDate)
        XCTAssertEqual(IndexStatus.idle(automatic: false, scansWaiting: 0,
                                        lastUpdate: nil).tint, .quiet)
    }

    /// Le pictogramme suit CE QUI SE PASSE, pas la famille d'état : lire des
    /// pages scannées et parcourir des dossiers ne se dessinent pas pareil.
    func testTheCardSymbolFollowsTheActivity() {
        func symbol(_ activity: IndexActivity) -> String {
            IndexStatus.working(activity: activity, progress: nil, detail: nil,
                                stoppable: false).symbol
        }
        XCTAssertEqual(symbol(.updating), "arrow.triangle.2.circlepath")
        XCTAssertEqual(symbol(.readingScans), "text.viewfinder")
        XCTAssertEqual(symbol(.preparingMeaning), "wand.and.stars")
        XCTAssertEqual(IndexStatus.needsAttention(.severalCopies).symbol,
                       "exclamationmark.triangle.fill")
        XCTAssertNotEqual(IndexStatus.checking.symbol,
                          IndexStatus.idle(automatic: true, scansWaiting: 0,
                                           lastUpdate: nil).symbol)
    }

    // MARK: - La place qui reste sur le disque (MO-03, 11/09/2026)

    /// Trois phrases possibles, dont la plus fréquente est le silence : la
    /// carte ne parle du disque que si la place manque. Plus de « taille
    /// prévue » : le propriétaire l'avait lue comme un plafond. Les chiffres
    /// sont ceux de l'audit du 09/09/2026 et du corpus de recette C2.
    func testTheCardSpeaksOfTheDiskOnlyWhenRoomIsShort() {
        let production = DiskForecast(bytes: 2_151_112_704, pagesIndexed: 408_951,
                                      pagesFullyVectorised: 274_244)
        let household = DiskForecast(bytes: 23_785_472, pagesIndexed: 2_858,
                                     pagesFullyVectorised: 2_858)

        // 29 Go libres : rien à dire, même à 86 % du critère P5 de la SPEC —
        // ce critère ne regarde plus l'application.
        XCTAssertEqual(DiskSpaceNotice.decide(freeBytes: 29_000_000_000,
                                              forecast: production), .silent)
        XCTAssertNil(DiskSpaceNotice.decide(freeBytes: 29_000_000_000,
                                            forecast: production).text)

        // 3,2 Go libres : on dit le reste et ce que l'index occupe.
        XCTAssertEqual(DiskSpaceNotice.decide(freeBytes: 3_200_000_000,
                                              forecast: production),
                       .low(free: 3_200_000_000, index: 2_151_112_704))

        // 100 Mo libres alors que la préparation du sens doit encore écrire
        // ~118 Mo (134 707 pages × 2,13 fenêtres × 410 octets) : la place ne
        // suffit pas pour finir.
        XCTAssertEqual(DiskSpaceNotice.decide(freeBytes: 100_000_000,
                                              forecast: production),
                       .tight(free: 100_000_000, index: 2_151_112_704))

        // Un petit fonds entièrement préparé, mais 800 Mo libres : sous 1 Go,
        // on parle fort quoi qu'il reste à écrire.
        XCTAssertEqual(DiskSpaceNotice.decide(freeBytes: 800_000_000,
                                              forecast: household),
                       .tight(free: 800_000_000, index: 23_785_472))

        // Le volume n'a pas répondu : silence, pas une phrase fausse.
        XCTAssertEqual(DiskSpaceNotice.decide(freeBytes: nil,
                                              forecast: production), .silent)
    }

    /// Le seuil « la place manque pour finir » suit ce qu'il reste à écrire :
    /// à couverture pleine, seul le plancher absolu de 1 Go joue encore.
    func testTheTightThresholdFollowsWhatRemainsToBeWritten() {
        let done = DiskForecast(bytes: 2_270_000_000, pagesIndexed: 408_951,
                                pagesFullyVectorised: 408_951)
        XCTAssertEqual(DiskSpaceNotice.decide(freeBytes: 1_500_000_000,
                                              forecast: done),
                       .low(free: 1_500_000_000, index: 2_270_000_000))
        XCTAssertEqual(DiskSpaceNotice.decide(freeBytes: 999_999_999,
                                              forecast: done),
                       .tight(free: 999_999_999, index: 2_270_000_000))
    }

    // MARK: - Les pages scannées sans texte lisible (IX2, remplace PR-24)

    /// Rien à dire à qui n'en a aucune : parler de pages mal lues à qui n'a
    /// aucun scan ne fait qu'inquiéter.
    func testScannedPagesWithoutTextAreSilentAtZero() {
        XCTAssertNil(ScannedPagesWithoutText.of(noLines: 0, doubtful: 0))
        XCTAssertNil(ScannedPagesWithoutText.of(noLines: -1, doubtful: 0),
                     "un compte absurde ne fait pas parler")
    }

    /// Chaque population a SA ligne, seule ou avec l'autre, les pages sans
    /// texte d'abord : une page blanche et une page aux lettres incertaines ne
    /// se comprennent pas de la même façon. Comptes de la production du
    /// 12/09/2026 : 3 157 sans ligne, 1 053 douteuses.
    func testEachPopulationOfScannedPagesHasItsOwnLine() throws {
        let blank = try XCTUnwrap(ScannedPagesWithoutText.of(noLines: 3_157, doubtful: 0))
        XCTAssertEqual(blank.lines.count, 1)
        XCTAssertTrue(blank.lines[0].title.contains("no text"), blank.lines[0].title)
        XCTAssertTrue(blank.lines[0].title.contains("157"), blank.lines[0].title)

        let faint = try XCTUnwrap(ScannedPagesWithoutText.of(noLines: 0, doubtful: 1_053))
        XCTAssertEqual(faint.lines.count, 1)
        XCTAssertTrue(faint.lines[0].title.contains("uncertain"), faint.lines[0].title)
        XCTAssertTrue(faint.lines[0].title.contains("053"), faint.lines[0].title)

        let both = try XCTUnwrap(ScannedPagesWithoutText.of(noLines: 3_157, doubtful: 1_053))
        XCTAssertEqual(both.lines, blank.lines + faint.lines)
        XCTAssertNotEqual(both.lines[0].explanation, both.lines[1].explanation)
        XCTAssertFalse(both.lines.contains { $0.explanation.isEmpty })
    }

    /// Les deux comptes sont des clés à VARIATION DE PLURIEL. L'accord lui-même
    /// (« 1 page scannée… ») se vérifie sur le catalogue COMPILÉ, pas ici : le
    /// processus de test n'embarque pas `Localizable.xcstrings`. C'est
    /// `l10n-lint.sh` et `make ci-bundle-i18n` qui en répondent.
    func testScannedPagesCountsArePluralKeys() {
        XCTAssertEqual(ScannedPagesWithoutText.pluralKeys.count, 2)
        XCTAssertTrue(ScannedPagesWithoutText.pluralKeys.allSatisfy { $0.contains("%lld") },
                      "les deux comptes doivent être des clés à variation")
    }

    /// Aucun mot du jargon, et AUCUNE PROMESSE : ni « OCR », ni « file », ni
    /// « seront relues » — la relecture en masse rendait le même texte.
    func testScannedPagesSentencesAvoidJargonAndPromises() throws {
        let both = try XCTUnwrap(ScannedPagesWithoutText.of(noLines: 3_157, doubtful: 1_053))
        let sentences = both.lines.flatMap { [$0.title, $0.explanation] }
            + [ScannedPagesWithoutText.closing]
        for sentence in sentences {
            for word in ["OCR", "queue", "file", "confidence", "agent", "vect"] {
                XCTAssertFalse(sentence.localizedCaseInsensitiveContains(word),
                               "« \(word) » n'a rien à faire dans « \(sentence) »")
            }
            XCTAssertFalse(sentence.localizedCaseInsensitiveContains("will be read again"),
                           "« \(sentence) » promet une relecture")
        }
    }

    /// Aucune phrase ne parle la langue de l'informaticien : le public visé
    /// n'a pas à savoir qu'il existe des vecteurs, un budget de spécification,
    /// une taille « prévue » ou des gibioctets.
    func testTheDiskSentencesAvoidJargon() throws {
        let sentences = [
            try XCTUnwrap(DiskSpaceNotice
                .low(free: 3_200_000_000, index: 2_151_112_704).text),
            try XCTUnwrap(DiskSpaceNotice
                .tight(free: 100_000_000, index: 2_151_112_704).text),
        ]
        for sentence in sentences {
            for word in ["Gio", "GiB", "vect", "budget", "octet", "planned", "prévu"] {
                XCTAssertFalse(sentence.localizedCaseInsensitiveContains(word),
                               "« \(word) » n'a rien à faire dans « \(sentence) »")
            }
        }
    }
}

// MARK: - La recherche par le sens préparée en arrière-plan (AG1, PR-21)

extension IndexStatusTests {

    /// La phase publiée par la mise à jour automatique devient l'activité que
    /// la carte affiche DÉJÀ pour la campagne lancée depuis l'application : une
    /// seule phrase pour un seul travail, et la barre porte « N pages sur M ».
    func testThePreparingMeaningPhaseBecomesTheExistingActivity() {
        let record = self.status(.preparingMeaning,
                                 detail: AgentStatusDetail.pagesLeft(700),
                                 done: 300, total: 1_000)
        let status = IndexStatusEvaluator.evaluate(input(agentStatus: record))
        guard case .working(let activity, let progress, _, let stoppable) = status
        else { return XCTFail("« travaille » attendu, obtenu \(status)") }
        XCTAssertEqual(activity, .preparingMeaning)
        XCTAssertEqual(progress?.done, 300)
        XCTAssertEqual(progress?.total, 1_000)
        // On n'arrête pas d'ici ce que le réglage commande : le bouton
        // « Arrêter » de la carte ne vaut que pour une passe de cette fenêtre.
        XCTAssertFalse(stoppable)
        XCTAssertEqual(status.tint, .working)
    }

    /// Le bouton « Préparer la recherche par le sens… » disparaît quand Fouine
    /// s'en charge — et SEULEMENT alors. Les trois conditions comptent : sans
    /// modèle rien ne se prépare, et un agent muet ou en attente d'approbation
    /// ne prépare rien non plus (sans quoi le bouton disparaîtrait sans que le
    /// travail se fasse).
    func testThePrepareButtonOnlyStepsAsideWhenFouineReallyDoesIt() {
        XCTAssertEqual(MeaningPreparation.decide(settingOn: true,
                                                 modelInstalled: true,
                                                 agent: .active),
                       .inBackground)
        XCTAssertEqual(MeaningPreparation.decide(settingOn: true,
                                                 modelInstalled: true,
                                                 agent: .waitingFirstReport),
                       .inBackground)
        XCTAssertEqual(MeaningPreparation.decide(settingOn: false,
                                                 modelInstalled: true,
                                                 agent: .active),
                       .byHand)
        XCTAssertEqual(MeaningPreparation.decide(settingOn: true,
                                                 modelInstalled: false,
                                                 agent: .active),
                       .byHand)
        for silent: AgentOperationalState in [.off, .registeredButSilent,
                                              .requiresApproval, .notFound,
                                              .unknown] {
            XCTAssertEqual(MeaningPreparation.decide(settingOn: true,
                                                     modelInstalled: true,
                                                     agent: silent),
                           .byHand, "état « \(silent.rawValue) »")
        }
    }
}
