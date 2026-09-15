// PageLabelTests.swift — le numéro IMPRIMÉ sur la page (lot MC4, PM-20).
// Propriété : A-Core.
//
// Le PDF est écrit À LA MAIN ici, et pas produit par `Tools/make_fixtures.swift` :
// celui-ci dessine des pages avec CoreGraphics, qui n'écrit AUCUN dictionnaire
// `/PageLabels` — or c'est exactement ce dictionnaire qu'on éprouve. Six
// objets, une table de références croisées, et PDFKit le lit.

import Foundation
import XCTest
@testable import FouineCore

final class PageLabelTests: XCTestCase {

    /// Un PDF de trois pages dont les deux premières sont des préliminaires en
    /// chiffres romains : rang 1 → « i », rang 2 → « ii », rang 3 → « 1 ».
    /// C'est la forme du décalage mesuré sur 44 % des livres du corpus.
    private func makePDF(withLabels: Bool) throws -> URL {
        let catalog = withLabels
            ? "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums "
                + "[ 0 << /S /r >> 2 << /S /D /St 1 >> ] >> >>"
            : "<< /Type /Catalog /Pages 2 0 R >>"
        var objects = [catalog,
                       "<< /Type /Pages /Kids [ 3 0 R 4 0 R 5 0 R ] /Count 3 >>"]
        for _ in 0..<3 {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [ 0 0 200 200 ] >>")
        }

        var body = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(body.utf8.count)
            body += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xrefAt = body.utf8.count
        body += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            body += String(format: "%010d 00000 n \n", offset)
        }
        body += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
            + "startxref\n\(xrefAt)\n%%EOF\n"

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-labels-\(UUID().uuidString).pdf")
        try Data(body.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAPDFWithFrontMatterGivesItsPrintedNumbers() throws {
        let url = try makePDF(withLabels: true)
        let labels = PDFPageLabels.read(path: url.path, ext: "pdf", pages: [1, 2, 3])
        XCTAssertEqual(labels[1], "i")
        XCTAssertEqual(labels[2], "ii")
        // Le rang 3 porte « 1 » : c'est le décalage lui-même, et c'est
        // précisément ce qu'une citation « page 3 » ferait perdre.
        XCTAssertEqual(labels[3], "1")
    }

    func testALabelThatRepeatsTheRankIsDropped() throws {
        let url = try makePDF(withLabels: false)
        // Sans dictionnaire, PDFKit rend le RANG : « 1 », « 2 », « 3 ». Les
        // publier ferait recopier une précision qui n'en est pas une.
        XCTAssertTrue(PDFPageLabels.read(path: url.path, ext: "pdf",
                                         pages: [1, 2, 3]).isEmpty)
    }

    func testNothingIsOpenedForAnythingButAPDF() throws {
        let url = try makePDF(withLabels: true)
        XCTAssertTrue(PDFPageLabels.read(path: url.path, ext: "pptx",
                                         pages: [1]).isEmpty)
        XCTAssertTrue(PDFPageLabels.read(path: nil, ext: "pdf", pages: [1]).isEmpty)
        XCTAssertTrue(PDFPageLabels.read(path: "/nowhere/absent.pdf", ext: "pdf",
                                         pages: [1]).isEmpty)
        // Hors de la plage du document : aucune étiquette, et surtout pas de
        // plantage sur `page(at:)`.
        XCTAssertTrue(PDFPageLabels.read(path: url.path, ext: "pdf",
                                         pages: [0, 4, 99]).isEmpty)
    }

    /// La clé est TOUJOURS présente dans la charge utile, `null` compris : un
    /// modèle ne peut pas deviner ce qu'une clé absente voudrait dire.
    func testTheKeyIsAlwaysThereEvenWhenThereIsNoLabel() throws {
        let db = try makeDB()
        let id = try addDoc(db, relPath: "Users/essai/Livres/livre.pdf")
        try db.store.setPageCount(id, 2)
        try db.store.replacePages(docID: id, pages: [page(1, "premiere page du livre"),
                                                     page(2, "seconde page du livre")])
        let reading = try PageReading.load(store: db.store, docID: id, page: 1,
                                           maxChars: 500, contextPages: 1)
        let json = reading.json()
        XCTAssertTrue(json.keys.contains("page_label"))
        XCTAssertTrue(json["page_label"] is NSNull)
        let context = try XCTUnwrap(json["context"] as? [[String: Any]])
        XCTAssertTrue(context[0]["page_label"] is NSNull)
    }
}
