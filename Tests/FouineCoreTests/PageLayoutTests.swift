// PageLayoutTests.swift — ce qu'un numéro de page DÉSIGNE (lot MC2, constat
// PM-19). Propriété : A-Core.
//
// Le fait mesuré : un `.pptx` de 53 diapositives fait 202 pages, parce que ses
// 149 images incorporées sont des pages numérotées APRÈS le texte. « page 170 »
// y désigne une figure OCRisée que personne ne retrouvera en feuilletant ses
// diapositives. La frontière est `max(page)` des lignes natives de `page_src`,
// et ces tests prouvent qu'on la lit et qu'on ne l'invente pas ailleurs.

import XCTest
@testable import FouineCore

final class PageLayoutTests: XCTestCase {

    func testUneDiapositiveEstUneDiapositiveEtUneImageEstUneImage() throws {
        XCTAssertEqual(PageLayout.page(53, ext: "pptx", textPages: 53).slide, 53)
        XCTAssertNil(PageLayout.page(53, ext: "pptx", textPages: 53).embeddedImage)
        let image = PageLayout.page(170, ext: "pptx", textPages: 53)
        XCTAssertNil(image.slide)
        XCTAssertEqual(image.embeddedImage, 117)
    }

    /// Un tableur ou un traitement de texte range ses images pareil, mais
    /// « diapositive 3 » d'un `.xlsx` n'apprendrait rien à personne.
    func testSeulUnDiaporamaARDesDiapositives() throws {
        XCTAssertNil(PageLayout.page(2, ext: "xlsx", textPages: 4).slide)
        XCTAssertEqual(PageLayout.page(6, ext: "xlsx", textPages: 4).embeddedImage, 2)
        XCTAssertEqual(PageLayout.page(2, ext: "odp", textPages: 4).slide, 2)
    }

    /// Un PDF, un DjVu, un iWork : leurs pages sont les pages du document, et
    /// les deux clés doivent rester nulles — les annoncer serait faux.
    func testUnPDFNAJamaisNiDiapositiveNiImageIncorporee() throws {
        let pdf = PageLayout.page(233, ext: "pdf", textPages: 100)
        XCTAssertNil(pdf.slide)
        XCTAssertNil(pdf.embeddedImage)
        let inconnu = PageLayout.page(3, ext: "pptx", textPages: nil)
        XCTAssertNil(inconnu.slide)
        XCTAssertNil(inconnu.embeddedImage)
    }

    /// La frontière se lit en base, sans colonne ni migration : les pages
    /// natives d'abord, les images (OCRisées) ensuite.
    func testLaFrontiereSeLitDansPageSrc() throws {
        let db = try makeDB()
        let cours = try addDoc(db, relPath: "Users/a/M2SU/cours.pptx", ext: "pptx")
        let livre = try addDoc(db, relPath: "Users/a/Livres/manuel.pdf")
        try db.store.replacePages(docID: cours, pages: [
            page(1, "titre du cours"),
            page(2, "bilan de matiere"),
            page(3, "figure scannee", .ocrAccurate),
            page(4, "schema scanne", .ocrAccurate),
        ])
        try db.store.replacePages(docID: livre, pages: [page(1, "chapitre premier")])

        let counts = try db.store.textPageCounts(forDocIDs: [cours, livre])
        XCTAssertEqual(counts[cours], 2, "deux diapositives, puis deux images")
        XCTAssertEqual(counts[livre], 1)
        XCTAssertEqual(PageLayout.page(3, ext: "pptx", textPages: counts[cours])
                           .embeddedImage, 1)
        XCTAssertEqual(try db.store.textPageCounts(forDocIDs: []), [:])
    }

    /// Un document dont AUCUNE page n'est native n'a pas d'entrée : un scan
    /// intégral ne doit pas déclarer « zéro diapositive, tout est image ».
    func testUnDocumentEntierementScanneNAPasDeFrontiere() throws {
        let db = try makeDB()
        let scan = try addDoc(db, relPath: "Users/a/Livres/photocopie.pptx",
                              ext: "pptx")
        try db.store.replacePages(docID: scan, pages: [
            page(1, "planche une", .ocrAccurate),
            page(2, "planche deux", .ocrAccurate),
        ])
        XCTAssertNil(try db.store.textPageCounts(forDocIDs: [scan])[scan])
    }
}
