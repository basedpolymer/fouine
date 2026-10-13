// DiskForecastTests.swift — le budget disque dit vrai (MO-03, C2-18).
// Propriété : A-Core.
//
// Les chiffres viennent de l'audit du 09/09/2026 et de mesures `dbstat` du
// 10/09/2026, pas d'un scénario inventé : ce sont les seuls qui prouvent que la
// projection annonce bien une échéance en pages là où `status` annonçait
// « 4,9 GiB at 1 M ».

import XCTest
@testable import FouineCore

final class DiskForecastTests: XCTestCase {

    /// La base de production du 09/09/2026 : 2,151 Go pour 408 951 pages.
    func testTheSeptember9ProductionCorpusIsNearTheBudget() {
        let f = DiskForecast(bytes: 2_151_112_704, pagesIndexed: 408_951)

        XCTAssertEqual(f.level, .near, "86 % du budget doit avertir, pas se taire")
        XCTAssertTrue(f.warns)
        XCTAssertEqual(f.ratioOfBudgetNow, 0.860, accuracy: 0.002)
        // 5,26 Kio par page mesurés sur cette base : le budget tombe un peu
        // au-delà de 475 000 pages, et c'est CETTE échéance que `status` doit
        // dire — pas « 4,9 GiB at 1 M », un nombre de pages que personne n'a.
        XCTAssertEqual(f.bytesPerPage ?? 0, 5_260, accuracy: 20)
        XCTAssertNotNil(f.pagesAtBudget)
        XCTAssertEqual(Double(f.pagesAtBudget ?? 0), 475_400, accuracy: 2_500)
    }

    /// Le second profil mesuré (C2-18) : un fonds de courriers et de factures,
    /// 8,1 Kio/page. Le plafond n'y est pas un sujet — et Fouine ne doit donc
    /// RIEN dire.
    func testAHouseholdCorpusSaysNothing() {
        let f = DiskForecast(bytes: 23_785_472, pagesIndexed: 2_858)

        XCTAssertEqual(f.level, .ok)
        XCTAssertFalse(f.warns)
        XCTAssertEqual(f.ratioOfBudgetNow, 0.0095, accuracy: 0.0005)
        // 2,5 Go / 8,32 Kio par page : c'est l'ordre de grandeur de C2-18
        // (« ~320 000 pages », calculé en Gio et en pages arrondies).
        XCTAssertEqual(Double(f.pagesAtBudget ?? 0), 300_000, accuracy: 20_000)
    }

    /// Au-delà du budget, Fouine le dit et continue : il n'y a pas d'état
    /// « arrêté » dans cette énumération (décision du 09/09/2026, n° 3).
    func testBeyondTheBudgetTheForecastWarnsAndNothingStops() {
        let f = DiskForecast(bytes: 2_700_000_000, pagesIndexed: 500_000)

        XCTAssertEqual(f.level, .over)
        XCTAssertTrue(f.warns)
        XCTAssertGreaterThan(f.ratioOfBudgetNow, 1.0)
        XCTAssertLessThan(f.pagesAtBudget ?? .max, 500_000,
                          "le budget a été franchi AVANT les pages présentes")
    }

    /// Le seuil d'avertissement tombe AVANT la limite : découvrir le plafond
    /// en le crevant ne laisse aucune marge de manœuvre.
    func testTheWarningComesBeforeTheLimit() {
        let f = DiskForecast(bytes: 2_100_000_000, pagesIndexed: 400_000)

        XCTAssertGreaterThanOrEqual(f.ratioOfBudgetNow, DiskForecast.nearRatio)
        XCTAssertLessThan(f.ratioOfBudgetNow, DiskForecast.overRatio)
        XCTAssertEqual(f.level, .near)
    }

    /// Un index vide ne divise pas par zéro et n'annonce pas « 0 page » comme
    /// une échéance.
    func testAnEmptyIndexHasNoDeadline() {
        let f = DiskForecast(bytes: 40_960, pagesIndexed: 0)

        XCTAssertEqual(f.level, .ok)
        XCTAssertNil(f.pagesAtBudget)
        XCTAssertNil(f.bytesPerPage)
    }

    /// Un budget absurde (zéro, négatif) rend une projection muette plutôt
    /// qu'un `inf` ou un plantage.
    func testAZeroBudgetIsNotADivision() {
        let f = DiskForecast(bytes: 1_000_000, pagesIndexed: 100, budgetBytes: 0)

        XCTAssertEqual(f.level, .ok)
        XCTAssertEqual(f.ratioOfBudgetNow, 0)
        XCTAssertNil(f.pagesAtBudget)
    }
}
