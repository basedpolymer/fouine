// MaterializedTextTests.swift — un paquet Anki recopié se lit carte par carte,
// et rien d'autre ne change de pagination (lot AN1). Propriété : A-Ingest.

import XCTest
import FouineCore
@testable import FouineExtract

final class MaterializedTextTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fouine-an1-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func extract(_ text: String, name: String = "Paquet.md") throws -> ExtractionResult {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return try PlainTextExtractor().extract(url: url, limits: ExtractLimits())
    }

    private let header = "<!-- fouine-source: anki -->\n"

    /// Une carte, une page : le saut de page n'est dans aucune page, et
    /// l'en-tête technique dans aucune non plus (lot AN2).
    func testAMaterializedDeckHasOnePagePerCard() throws {
        let text = header + "Qu'est-ce que l'enthalpie ?\n"
            + "\u{0C}Unité de l'entropie ?\n\nJ/K\n"
            + "\u{0C}Premier principe\n"
        let result = try extract(text)
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertEqual(result.pages.map(\.page), [1, 2, 3])
        XCTAssertEqual(result.pages[0].text, "Qu'est-ce que l'enthalpie ?\n")
        XCTAssertEqual(result.pages[1].text, "Unité de l'entropie ?\n\nJ/K\n")
        XCTAssertFalse(result.pages.contains { $0.text.contains("\u{0C}") })
    }

    /// Une carte plus longue qu'une page ordinaire se repagine à l'intérieur de
    /// son segment : la carte suivante garde une page à elle.
    func testALongCardIsSplitWithoutSwallowingTheNextOne() throws {
        let long = String(repeating: "polymère réticulé en solution. ", count: 300)
        let result = try extract(header + "# Paquet\n\n" + long + "\u{0C}suivante\n")
        XCTAssertGreaterThan(result.pageCount, 2)
        XCTAssertEqual(result.pages.last?.text, "suivante\n")
        for page in result.pages {
            XCTAssertLessThanOrEqual(page.text.count, ExtractLimits().pageSplitChars)
        }
    }

    /// Un `.txt` ordinaire qui porte des sauts de page — une RFC, un source
    /// découpé par ^L — garde EXACTEMENT la pagination d'avant, et le marqueur
    /// cité plus bas qu'en première ligne ne compte pas.
    func testOrdinaryTextWithFormFeedsKeepsItsPagination() throws {
        let text = "Network Working Group\n\u{0C}Page 2\n\u{0C}Page 3\n"
            + "<!-- fouine-source: anki -->\n"
        let result = try extract(text, name: "rfc.txt")
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertEqual(result.pages.first?.text, text)
    }

    /// Entrées sans carte : un en-tête seul, des sauts de page en rafale, un
    /// fichier vide. Aucune ne piège ; les emplacements vides restent comptés
    /// pour que la numérotation des cartes suivantes ne bouge pas.
    func testDegenerateMaterializedFilesDoNotTrap() throws {
        XCTAssertEqual(try extract(header).pageCount, 1)

        let bursts = try extract(header + "# P\n"
                                 + String(repeating: "\u{0C}", count: 50) + "fin\n")
        XCTAssertEqual(bursts.pageCount, 51)
        XCTAssertEqual(bursts.pages.map(\.page), [1, 51], "les pages vides ne s'indexent pas")

        XCTAssertEqual(try extract("", name: "vide.md").pageCount, 0)
    }

    /// Les noms d'images d'une carte ne sont PAS dans le texte indexé, et ils
    /// restent attachés à la PREMIÈRE page de leur carte, même longue : c'est ce
    /// que l'aperçu relit.
    func testImageLinesLeaveTheTextAndStayWithTheirCard() throws {
        let long = String(repeating: "courbe de titrage. ", count: 400)
        let text = header + "# Paquet\n\ncarte 1\n<!-- fouine-image: p139.png -->\n"
            + "\u{0C}" + long + "\n<!-- fouine-image: a.png -->\n<!-- fouine-image: b.svg -->\n"
            + "\u{0C}carte 3\n"
        let pages = MaterializedText.pages(text, limit: ExtractLimits().pageSplitChars)
        XCTAssertEqual(pages.first?.images, ["p139.png"])
        XCTAssertEqual(pages[1].images, ["a.png", "b.svg"])
        XCTAssertTrue(pages.dropFirst(2).dropLast().allSatisfy { $0.images.isEmpty },
                      "les pages suivantes d'une carte longue n'ont pas d'image")
        XCTAssertEqual(pages.last?.text, "carte 3\n")

        let result = try extract(text)
        XCTAssertEqual(result.pageCount, pages.count)
        XCTAssertEqual(result.pages.first?.text, "# Paquet\n\ncarte 1\n")
        XCTAssertFalse(result.pages.contains { $0.text.contains("fouine-image") || $0.text.contains(".png") })

        // Hors d'un fichier recopié, la même ligne reste du texte ordinaire.
        let ordinary = try extract("notes\n<!-- fouine-image: x.png -->\n", name: "n.md")
        XCTAssertTrue(ordinary.pages.first?.text.contains("x.png") ?? false)
    }

    /// L'en-tête d'une note recopiée — la source, puis le lien de Notes ou de
    /// Bear — n'entre pas dans l'index (lot AN2) : ses mots faisaient répondre
    /// la première page de chaque note à « fouine », « source », « notes »,
    /// et l'extrait s'ouvrait sur « …anki --> ». Le titre, lui, reste : c'est
    /// par lui qu'on cherche une note. Une ligne qui IMITE l'en-tête plus bas
    /// reste du texte.
    func testTheHeaderLinesAreNotIndexed() throws {
        let note = "<!-- fouine-source: notes -->\r\n"
            + "<!-- fouine-open: notes://showNote?identifier=A1B2 -->\n"
            + "# Rendez-vous\n\nchez maître Dupont\n"
            + "<!-- fouine-open: plus bas, du texte -->\n"
        let result = try extract(note, name: "Rendez-vous-A1B2.md")
        XCTAssertEqual(result.pages.map(\.text),
                       ["# Rendez-vous\n\nchez maître Dupont\n<!-- fouine-open: plus bas, du texte -->\n"])
        XCTAssertEqual(MaterializedText.withoutHeader(header), "")
        XCTAssertEqual(MaterializedText.withoutHeader("# sans en-tête\n"), "# sans en-tête\n")
    }

    func testOnlyTheFirstLineDeclaresAMaterializedFile() {
        XCTAssertTrue(MaterializedText.isMaterialized(header + "# x"))
        XCTAssertTrue(MaterializedText.isMaterialized("  <!-- fouine-source: notes -->"))
        XCTAssertFalse(MaterializedText.isMaterialized("# titre\n" + header))
        XCTAssertFalse(MaterializedText.isMaterialized("fouine-source: anki"))
        XCTAssertFalse(MaterializedText.isMaterialized(""))
    }
}
