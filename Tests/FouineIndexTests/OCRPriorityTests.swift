// OCRPriorityTests.swift — la table de vérité du §6.1 (audit F4, A9).
// Propriété : A-Core.
//
// Ce que ces cas empêchent de revenir : `if rootLabel != "Livres" { return 0 }`,
// recopié dans les trois pipelines. Sur une base neuve — plus aucune racine
// implicite depuis D1 —, AUCUNE racine ne s'appelle « Livres » : toute la file
// partait à 0, et les 5 291 images des archives BD passaient devant les
// documents utiles.

import XCTest
import FouineCore
@testable import FouineIndex

final class OCRPriorityTests: XCTestCase {

    func testTruthTable() {
        // Archives BD : le moins urgent, quel que soit le nombre de pages.
        XCTAssertEqual(OCRPriority.forDocument(extension: "cbz", pageCount: 12), 3)
        XCTAssertEqual(OCRPriority.forDocument(extension: "cbr", pageCount: 900), 3)
        XCTAssertEqual(OCRPriority.forDocument(extension: "CBZ", pageCount: 12), 3,
                       "l'extension doit être comparée en minuscules")

        // Petits documents : d'abord, les gains visibles arrivent tôt.
        XCTAssertEqual(OCRPriority.forDocument(extension: "pdf", pageCount: 1), 1)
        XCTAssertEqual(OCRPriority.forDocument(extension: "pdf", pageCount: 99), 1)
        XCTAssertEqual(OCRPriority.forDocument(extension: "djvu", pageCount: 0), 1)

        // Le seuil du §6.1 est à 100 pages, borne INCLUSE du côté « gros ».
        XCTAssertEqual(OCRPriority.forDocument(extension: "pdf", pageCount: 100), 2)
        XCTAssertEqual(OCRPriority.forDocument(extension: "pdf", pageCount: 1_570), 2)
    }

    /// La racine épinglée : le paramètre existe, la colonne pas encore
    /// (palier 2.3). Il l'emporte sur tout le reste, archives comprises.
    func testPinnedRootWinsOverEveryOtherCriterion() {
        XCTAssertEqual(OCRPriority.forDocument(extension: "cbz", pageCount: 900,
                                               isPinnedRoot: true), 0)
        XCTAssertEqual(OCRPriority.forDocument(extension: "pdf", pageCount: 1_570,
                                               isPinnedRoot: true), 0)
    }

    /// Le sens de l'échelle, qui est le seul vrai risque d'inversion : la file
    /// est servie par `ORDER BY q.prio` — ASCENDANT (`GRDBStore.nextOCRBatch`,
    /// `idx_ocr_prio`, `Schema` : « 0 = le plus urgent »).
    func testSmallerIsMoreUrgent() {
        let comic = OCRPriority.forDocument(extension: "cbz", pageCount: 50)
        let small = OCRPriority.forDocument(extension: "pdf", pageCount: 50)
        let big = OCRPriority.forDocument(extension: "pdf", pageCount: 500)
        XCTAssertLessThan(OCRPriority.pinned, small)
        XCTAssertLessThan(small, big)
        XCTAssertLessThan(big, comic)
        XCTAssertEqual(comic, OCRPriority.comicArchives)
    }

    /// Plus aucune étiquette de racine n'entre dans la décision : c'est le
    /// défaut F4 lui-même. Deux documents identiques sous deux racines de noms
    /// différents ont la même priorité — la fonction ne connaît pas les racines.
    func testPriorityDoesNotDependOnAnyLabel() {
        XCTAssertEqual(OCRPriority.forDocument(extension: "pdf", pageCount: 42),
                       OCRPriority.forDocument(extension: "pdf", pageCount: 42))
    }
}
