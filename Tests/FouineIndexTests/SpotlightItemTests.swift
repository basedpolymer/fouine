// SpotlightItemTests.swift — l'élément remis à Spotlight (INT-S1).
// Propriété : A-Core.

import Foundation
import XCTest
import FouineCore
@testable import FouineIndex

final class SpotlightItemTests: XCTestCase {

    private let document = DocumentChange(
        id: 1_329, volUUID: "TEST-VOL", relPath: "Cours/L3/notes scannées.pdf",
        ext: "pdf", topFolder: "Cours", state: .extracted, ocrState: .done,
        indexedAt: 1_700_000_000, scannedPages: 12)

    // MARK: - 1 · Ce que Spotlight reçoit

    func testItemCarriesWhatTheUserRecognises() throws {
        let pages = [IndexedPage(page: 1, text: "Électrolyse de l'eau."),
                     IndexedPage(page: 2, text: "Rendement faradique.")]
        let item = try XCTUnwrap(SpotlightItemBuilder.item(
            document: document, absolutePath: "/Users/x/Cours/L3/notes scannées.pdf",
            pages: pages, limitBytes: 1_024 * 1_024))

        XCTAssertEqual(item.identifier, "doc:1329")
        // Le NOM du fichier : Fouine n'indexe pas les noms (SPEC §5.3 (e)),
        // Spotlight le rendra donc cherchable là où Fouine ne le fait pas.
        XCTAssertEqual(item.title, "notes scannées.pdf")
        XCTAssertEqual(item.textContent,
                       "Électrolyse de l'eau.\n\nRendement faradique.")
        XCTAssertEqual(item.contentDescription,
                       "Électrolyse de l'eau. Rendement faradique.")
        XCTAssertEqual(item.keywords, ["Cours", "pdf"])
        XCTAssertEqual(item.contentURL?.path,
                       "/Users/x/Cours/L3/notes scannées.pdf")
        XCTAssertEqual(item.domainIdentifier,
                       "io.github.basedpolymer.fouine.documents")
        XCTAssertEqual(item.contentTypeIdentifier, "com.adobe.pdf")
    }

    func testItemWithoutTextIsNotHandedOver() {
        XCTAssertNil(SpotlightItemBuilder.item(
            document: document, absolutePath: nil, pages: [], limitBytes: 4_096))
        XCTAssertNil(SpotlightItemBuilder.item(
            document: document, absolutePath: nil,
            pages: [IndexedPage(page: 1, text: "   \n ")], limitBytes: 4_096))
    }

    func testDescriptionIsCappedOnOneLine() {
        let long = String(repeating: "mot ", count: 200)
        let item = SpotlightItemBuilder.item(
            document: document, absolutePath: nil,
            pages: [IndexedPage(page: 1, text: long)], limitBytes: 1_048_576)
        let description = try? XCTUnwrap(item?.contentDescription)
        XCTAssertEqual(description?.count, 301)   // 300 + le caractère de coupe
        XCTAssertFalse(description?.contains("\n") ?? true)
    }

    // MARK: - 2 · Le clic sur un résultat

    func testClickOnAResultBecomesADeepLink() {
        XCTAssertEqual(SpotlightItemBuilder.link(identifier: "doc:42",
                                                 query: "électrolyse"),
                       .open(target: .doc(42), page: nil, query: "électrolyse"))
        // Sans requête transmise : le document, à sa première page.
        XCTAssertEqual(SpotlightItemBuilder.link(identifier: "doc:42", query: "  "),
                       .open(target: .doc(42), page: nil, query: nil))
        // Ce qui ne vient pas de nous n'ouvre rien.
        XCTAssertNil(SpotlightItemBuilder.link(identifier: "note:42", query: nil))
        XCTAssertNil(SpotlightItemBuilder.link(identifier: nil, query: "x"))
    }
}
