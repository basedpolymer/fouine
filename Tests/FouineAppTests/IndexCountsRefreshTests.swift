// IndexCountsRefreshTests.swift — la fenêtre « Votre index » suit la mise à
// jour sans marteler la base (lot MN2). Propriété : A-App.

import XCTest
@testable import FouineApp

final class IndexCountsRefreshTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Pendant un travail, au rythme d'une sonde de 2 s : une relecture toutes
    /// les dix secondes, à compter de celle de l'ouverture.
    func testWhileWorkingReadsAtMostEveryInterval() {
        var refresh = IndexCountsRefresh()
        refresh.noteRead(at: t0)
        let ticks = stride(from: 2.0, through: 24.0, by: 2.0).map {
            ($0, refresh.shouldRead(working: true, now: at($0)))
        }
        XCTAssertEqual(ticks.filter(\.1).map(\.0), [10, 20])
    }

    /// Sans lecture préalable, le premier battement d'un travail relit.
    func testTheFirstTickOfWorkReadsWhenNothingWasRead() {
        var refresh = IndexCountsRefresh()
        XCTAssertTrue(refresh.shouldRead(working: true, now: t0))
        XCTAssertFalse(refresh.shouldRead(working: true, now: at(2)))
    }

    /// Le travail fini, une relecture TOUT DE SUITE — les derniers nombres
    /// sont les bons —, puis plus rien au repos.
    func testTheEndOfWorkReadsOnceThenRests() {
        var refresh = IndexCountsRefresh()
        refresh.noteRead(at: t0)
        XCTAssertFalse(refresh.shouldRead(working: true, now: at(2)))
        XCTAssertTrue(refresh.shouldRead(working: false, now: at(4)),
                      "la fin du travail relit, même avant l'intervalle")
        XCTAssertFalse(refresh.shouldRead(working: false, now: at(6)))
        XCTAssertFalse(refresh.shouldRead(working: false, now: at(60)))
    }

    /// Au repos du début à la fin : aucune relecture, quel que soit le temps.
    func testAtRestNothingIsRead() {
        var refresh = IndexCountsRefresh()
        refresh.noteRead(at: t0)
        for seconds in [2.0, 30, 600] {
            XCTAssertFalse(refresh.shouldRead(working: false, now: at(seconds)))
        }
    }
}
