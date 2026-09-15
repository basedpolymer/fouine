// IndexCardSummaryTests.swift — ce que la carte « Index » peint, et ce qu'elle
// ne peint plus (IX2, demande du propriétaire du 12/09/2026). Propriété : A-App.
//
// La carte avait regagné sept lignes ; le propriétaire a demandé l'essentiel.
// Ces tests protègent le tri, une famille d'état à la fois : une ligne revenue
// sous la carte — le nom du document, « 312 / 1 200 pages », un second bouton,
// la place disque ordinaire, une confirmation sous l'interrupteur — ne se
// verrait qu'à l'écran. Ils comparent des CAS et des phrases d'`IndexStatusText`
// (le processus de test n'embarque pas le catalogue : les phrases y sont les
// clés anglaises).

import XCTest
import FouineCore
@testable import FouineApp

final class IndexCardSummaryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ status: IndexStatus,
                      disk: DiskSpaceNotice = .silent) -> IndexCardSummary {
        IndexCardSummary(status: status, disk: disk, now: now)
    }

    // MARK: - Une famille d'état à la fois

    /// Au démarrage : le titre, et rien d'autre à dire ni à faire.
    func testCheckingShowsItsHeadlineAndNothingElse() {
        let c = card(.checking)
        XCTAssertEqual(c.headline, IndexStatusText.headline(.checking))
        XCTAssertNil(c.detail)
        XCTAssertNil(c.bar)
        XCTAssertNil(c.action)
        XCTAssertNil(c.diskSpace)
    }

    func testNoFoldersOffersToAddOne() {
        let c = card(.noFolders)
        XCTAssertEqual(c.action, .addFolder)
        XCTAssertNil(c.bar)
    }

    /// Une attention garde sa phrase ET son geste : c'est la raison d'être de
    /// la carte.
    func testAttentionKeepsItsSentenceAndItsGesture() throws {
        let status = IndexStatus.needsAttention(.awaitingApproval)
        let c = card(status)
        XCTAssertEqual(try XCTUnwrap(c.detail), IndexStatusText.detail(status, now: now))
        XCTAssertEqual(c.action, .openLoginItems)
        XCTAssertNil(c.bar)
    }

    /// Un travail au total et au débit connus : la barre se remplit, et la
    /// ligne dit le temps restant — ni le nom du document, ni « 300 / 1 200
    /// pages ».
    func testWorkingWithTimeLeftShowsTheBarAndTheTimeLeftOnly() throws {
        let status = IndexStatus.working(
            activity: .readingScans,
            progress: IndexProgress(done: 300, total: 1_200, remainingSeconds: 7_200),
            detail: "Clayden.pdf", stoppable: true)
        let c = card(status)
        XCTAssertEqual(c.bar, .determinate(0.25))
        let line = try XCTUnwrap(c.detail)
        XCTAssertEqual(line.lowercased(), IndexStatusText.remaining(7_200).lowercased())
        XCTAssertTrue(line.first?.isUppercase ?? false, "seule sous le titre, la ligne commence comme une phrase : \(line)")
        XCTAssertFalse(line.contains("Clayden"), line)
        XCTAssertFalse(line.contains("300"), line)
        XCTAssertEqual(c.action, .stop)
    }

    /// Sans temps restant, PAS de ligne : le nom du document ne revient pas
    /// par la bande. Sans total, la barre reste indéterminée.
    func testWorkingWithoutTimeLeftHasNoLine() {
        let unknown = IndexStatus.working(activity: .updating, progress: nil,
                                          detail: "Rapport 2024.pdf", stoppable: false)
        XCTAssertNil(card(unknown).detail)
        XCTAssertEqual(card(unknown).bar, .indeterminate)
        XCTAssertNil(card(unknown).action)

        let counted = IndexStatus.working(
            activity: .preparingMeaning,
            progress: IndexProgress(done: 3, total: 10, remainingSeconds: nil),
            detail: "Rapport 2024.pdf", stoppable: false)
        XCTAssertNil(card(counted).detail)
        XCTAssertEqual(card(counted).bar, .determinate(0.3))
    }

    /// ST1 — « Stop » cliqué, la passe n'a pas encore rendu la main : le bouton
    /// RESTE (désarmé, `isStopping`) et la phrase de la passe reparaît sous le
    /// titre. C'est la seule exception à la règle d'IX2 : pendant un arrêt, ce
    /// qu'on attend est justement la réponse à la question qu'on vient de poser.
    func testStoppingKeepsTheButtonDisarmedAndNamesWhatIsAwaited() throws {
        let status = IndexStatus.working(
            activity: .updating,
            progress: IndexProgress(done: 3, total: 10, remainingSeconds: 7_200),
            detail: "Stopping — finishing “cours.mp4”…", stoppable: false)
        let c = IndexCardSummary(status: status, disk: .silent, stopping: true,
                                 now: now)
        XCTAssertTrue(c.isStopping)
        XCTAssertEqual(c.action, .stop)
        XCTAssertEqual(try XCTUnwrap(c.detail), "Stopping — finishing “cours.mp4”…")
        XCTAssertEqual(c.bar, .determinate(0.3))

        // Hors travail, la demande d'arrêt ne veut rien dire : rien ne change.
        let idle = IndexCardSummary(status: .idle(automatic: false, scansWaiting: 0,
                                                  lastUpdate: nil),
                                    disk: .silent, stopping: true, now: now)
        XCTAssertFalse(idle.isStopping)
        XCTAssertEqual(idle.action, .updateNow)
    }

    /// Un autre programme écrit : la carte garde SA phrase, la seule qui dise
    /// que la recherche marche quand même.
    func testExternalWriteKeepsItsSentence() {
        let status = IndexStatus.working(activity: .externalWrite, progress: nil,
                                         detail: nil, stoppable: false)
        let c = card(status)
        XCTAssertEqual(c.detail, IndexStatusText.anotherProgramWriting)
        XCTAssertEqual(c.detail, IndexStatusText.detail(status))
        XCTAssertEqual(c.bar, .indeterminate)
        XCTAssertNil(c.action)
    }

    /// En attente avec des scans à lire : la raison de l'attente, et AUCUN
    /// bouton — « Lire les pages scannées… » est parti dans la fenêtre.
    func testPausedWithScansHasNoButton() {
        let status = IndexStatus.paused(reason: .onBattery, scansWaiting: 40)
        XCTAssertEqual(status.primaryAction, .readScans, "l'état propose toujours le geste…")
        let c = card(status)
        XCTAssertNil(c.action, "… mais la carte ne le porte plus")
        XCTAssertEqual(c.detail, IndexStatusText.pauseSentence(.onBattery))
        XCTAssertNil(c.bar)
    }

    /// Mise à jour manuelle avec des scans : « Mettre à jour maintenant », seul.
    func testManualIdleWithScansOffersUpdateNowAlone() {
        let status = IndexStatus.idle(automatic: false, scansWaiting: 12, lastUpdate: nil)
        XCTAssertEqual(status.secondaryAction, .readScans, "le second geste existe…")
        let c = card(status)
        XCTAssertEqual(c.action, .updateNow, "… la carte n'en porte qu'un")
        XCTAssertNotNil(c.detail)
    }

    /// À jour en automatique : « Mis à jour il y a 3 min », aucun bouton.
    func testAutomaticIdleSaysWhenAndOffersNothing() throws {
        let status = IndexStatus.idle(automatic: true, scansWaiting: 0,
                                      lastUpdate: now.addingTimeInterval(-180))
        let c = card(status)
        XCTAssertEqual(try XCTUnwrap(c.detail), IndexStatusText.detail(status, now: now))
        XCTAssertTrue(try XCTUnwrap(c.detail).contains("3"))
        XCTAssertNil(c.action)
        XCTAssertNil(c.bar)
    }

    /// La place disque : sur la carte SEULEMENT quand Fouine risque d'en
    /// manquer. Moins de 5 Go libres se dit dans la fenêtre, où rien ne presse.
    func testOnlyATightDiskIsSpokenOfOnTheCard() throws {
        let idle = IndexStatus.idle(automatic: true, scansWaiting: 0, lastUpdate: nil)
        let tight = DiskSpaceNotice.tight(free: 100_000_000, index: 2_151_112_704)
        let low = DiskSpaceNotice.low(free: 3_200_000_000, index: 2_151_112_704)

        XCTAssertEqual(try XCTUnwrap(card(idle, disk: tight).diskSpace), tight.text)
        XCTAssertNil(card(idle, disk: low).diskSpace)
        XCTAssertNotNil(low.text, "la fenêtre, elle, a une phrase à dire")
        XCTAssertNil(card(idle, disk: .silent).diskSpace)
    }

    // MARK: - Le message de l'interrupteur

    /// Une confirmation ne se montre pas sous la carte (la carte dit déjà
    /// l'état) ; un problème, si (l'interrupteur est revenu en arrière).
    func testOnlyAProblemShowsUnderTheCard() {
        XCTAssertFalse(AutomaticUpdatesMessage.confirmation("on").showsUnderCard)
        XCTAssertTrue(AutomaticUpdatesMessage.problem("refused").showsUnderCard)
    }
}

// MARK: - Du geste sur l'interrupteur à la nature de sa réponse

@MainActor
final class AutomaticUpdatesMessageTests: XCTestCase {

    /// Un interrupteur refusé revient en arrière : sa phrase est un PROBLÈME,
    /// donc visible sous la carte. C'est le seul chemin d'`AppModel` qui se
    /// joue sans parler au système — sans dossier, le refus précède tout
    /// enregistrement ; les confirmations passent par `SMAppService`.
    func testARefusedSwitchExplainsItselfUnderTheCard() throws {
        let db = try TempAppDB()
        let app = AppModel(service: db.service)
        XCTAssertFalse(app.canToggleBackgroundIndexing, "aucun dossier")

        app.setBackgroundIndexing(true)

        let message = try XCTUnwrap(app.agentMessage)
        XCTAssertEqual(message.kind, .problem)
        XCTAssertTrue(message.showsUnderCard)
        XCTAssertFalse(app.backgroundIndexing, "l'interrupteur est revenu en arrière")
    }
}
