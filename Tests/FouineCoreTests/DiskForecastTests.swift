// DiskForecastTests.swift — le budget disque dit vrai (MO-03, C2-18).
// Propriété : A-Core.
//
// Les chiffres viennent de l'audit du 09/09/2026 et de mesures `dbstat` du
// 10/09/2026, pas d'un scénario inventé : ce sont les seuls qui prouvent que la
// projection annonce bien ~2,26 Go et ~452 000 pages là où `status` annonçait
// « 4,9 GiB at 1 M ».

import XCTest
@testable import FouineCore

final class DiskForecastTests: XCTestCase {

    /// La base de production du 09/09/2026 : 2,151 Go, 408 951 pages,
    /// 274 244 pages complètement vectorisées, 2,12 fenêtres réelles par page
    /// complète (mesuré sur la copie : 582 086 fenêtres pour 274 244 pages).
    func testTheSeptember9ProductionCorpusIsNearTheBudget() {
        let f = DiskForecast(bytes: 2_151_112_704,
                             pagesIndexed: 408_951,
                             pagesFullyVectorised: 274_244,
                             windowsPerPage: 2.1225)

        XCTAssertEqual(f.level, .near, "90 % du budget doit avertir, pas se taire")
        XCTAssertTrue(f.warns)
        XCTAssertEqual(f.ratioOfBudgetNow, 0.860, accuracy: 0.002)
        // MO-03 annonçait ~2,26 Go en comptant 384 octets par fenêtre ; les
        // ~26 octets de ligne SQLite mesurés par `dbstat` ajoutent 7 Mo, d'où
        // 2,268 Go. La marge du test couvre les deux lectures.
        XCTAssertEqual(Double(f.bytesAtFullVectors) / 1e9, 2.264, accuracy: 0.010)
        XCTAssertEqual(f.ratioAtFullVectors, 0.906, accuracy: 0.005)
        XCTAssertEqual(f.pagesWithoutVectors, 134_707)
        // ~452 000 pages selon MO-03 (5,40 Kio/page) ; 450 800 avec le coût de
        // ligne. L'échéance est la même à trois jours de campagne près.
        XCTAssertNotNil(f.pagesAtBudget)
        XCTAssertEqual(Double(f.pagesAtBudget ?? 0), 451_500, accuracy: 2_500)
    }

    /// Le second profil mesuré (C2-18) : un fonds de courriers et de factures,
    /// 8,1 Kio/page mais déjà entièrement vectorisé. Le plafond n'y est pas un
    /// sujet — et Fouine ne doit donc RIEN dire.
    func testAHouseholdCorpusSaysNothing() {
        let f = DiskForecast(bytes: 23_785_472,
                             pagesIndexed: 2_858,
                             pagesFullyVectorised: 2_858,
                             windowsPerPage: 2.708)

        XCTAssertEqual(f.level, .ok)
        XCTAssertFalse(f.warns)
        XCTAssertEqual(f.pagesWithoutVectors, 0)
        XCTAssertEqual(f.bytesAtFullVectors, f.bytes,
                       "rien à ajouter : toutes les pages ont leurs vecteurs")
        XCTAssertEqual(f.ratioAtFullVectors, 0.0095, accuracy: 0.0005)
        // 2,5 Go / 8,32 Kio par page : c'est l'ordre de grandeur de C2-18
        // (« ~320 000 pages », calculé en Gio et en pages arrondies).
        XCTAssertEqual(Double(f.pagesAtBudget ?? 0), 300_000, accuracy: 20_000)
    }

    /// Au-delà du budget, Fouine le dit et continue : il n'y a pas d'état
    /// « arrêté » dans cette énumération (décision du 09/09/2026, n° 3).
    func testBeyondTheBudgetTheForecastWarnsAndNothingStops() {
        let f = DiskForecast(bytes: 2_700_000_000,
                             pagesIndexed: 500_000,
                             pagesFullyVectorised: 500_000)

        XCTAssertEqual(f.level, .over)
        XCTAssertTrue(f.warns)
        XCTAssertGreaterThan(f.ratioOfBudgetNow, 1.0)
        XCTAssertLessThan(f.pagesAtBudget ?? .max, 500_000,
                          "le budget a été franchi AVANT les pages présentes")
    }

    /// Le niveau se lit sur la PROJECTION, pas sur la taille du jour : une
    /// campagne sémantique à peine commencée cache les vecteurs à écrire, et
    /// n'avertir qu'une fois écrits serait avertir trop tard.
    func testTheLevelIsReadOnTheProjectionNotOnTodaysSize() {
        let f = DiskForecast(bytes: 1_800_000_000,
                             pagesIndexed: 400_000,
                             pagesFullyVectorised: 0,
                             windowsPerPage: 2.12)

        XCTAssertLessThan(f.ratioOfBudgetNow, DiskForecast.nearRatio)
        XCTAssertEqual(f.level, .near)
    }

    /// Un index vide ne divise pas par zéro et n'annonce pas « 0 page » comme
    /// une échéance.
    func testAnEmptyIndexHasNoDeadline() {
        let f = DiskForecast(bytes: 40_960, pagesIndexed: 0,
                             pagesFullyVectorised: 0)

        XCTAssertEqual(f.level, .ok)
        XCTAssertNil(f.pagesAtBudget)
        XCTAssertNil(f.bytesPerPageAtFullVectors)
        XCTAssertEqual(f.bytesAtFullVectors, 40_960)
        XCTAssertEqual(f.pagesWithoutVectors, 0)
    }

    /// Un budget absurde (zéro, négatif) rend une projection muette plutôt
    /// qu'un `inf` ou un plantage.
    func testAZeroBudgetIsNotADivision() {
        let f = DiskForecast(bytes: 1_000_000, pagesIndexed: 100,
                             pagesFullyVectorised: 100, budgetBytes: 0)

        XCTAssertEqual(f.level, .ok)
        XCTAssertEqual(f.ratioOfBudgetNow, 0)
        XCTAssertEqual(f.ratioAtFullVectors, 0)
        XCTAssertNil(f.pagesAtBudget)
    }
}
