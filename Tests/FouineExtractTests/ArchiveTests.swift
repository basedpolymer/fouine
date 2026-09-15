// ArchiveTests.swift — docx, odt, xlsx, pptx, epub, cbz (SPEC §5.3).
// Propriété : A-Ingest.
//
// Toutes les fixtures sont fabriquées par le test : aucun fichier du corpus
// personnel n'est nécessaire, et rien n'est jamais écrit dans une archive.

import XCTest
import FouineCore
@testable import FouineExtract

final class ArchiveExtractorTests: XCTestCase {

    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("archives")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    // MARK: - docx

    func makeDocx(paragraphs: [String], media: [String] = []) throws -> URL {
        let body = paragraphs.map {
            "<w:p><w:r><w:t>\($0)</w:t></w:r></w:p>"
        }.joined()
        var entries: [(name: String, data: Data)] = [
            ("word/document.xml",
             Fixtures.xml("<w:document xmlns:w=\"x\"><w:body>\(body)</w:body></w:document>")),
        ]
        for (index, name) in media.enumerated() {
            entries.append((name, Fixtures.pngBytes(UInt8(index + 1))))
        }
        let url = file("cours.docx")
        try Fixtures.makeArchive(entries, at: url)
        return url
    }

    func testDocxTextAndEmbeddedMedia() throws {
        let url = try makeDocx(
            paragraphs: ["Enthalpie libre", "Chromatographie sur papier"],
            media: ["word/media/image10.png", "word/media/image2.png",
                    "word/media/image1.png", "word/media/notes.txt"])

        let result = try OOXMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pages.count, 1)
        let text = try XCTUnwrap(result.pages.first).text
        XCTAssertTrue(text.contains("Enthalpie libre"), text)
        XCTAssertTrue(text.contains("Chromatographie sur papier"), text)

        // Trois images (le .txt n'en est pas une), numérotées APRÈS le texte.
        XCTAssertEqual(result.pageCount, 4)
        XCTAssertEqual(result.ocrCandidates, [2, 3, 4])
    }

    /// Signature imposée, consommée par A-OCR en vague 2.
    func testMediaMapIsDeterministicAndOrdered() throws {
        let url = try makeDocx(paragraphs: ["Texte"],
                               media: ["word/media/image10.png",
                                       "word/media/image2.png",
                                       "word/media/image1.png"])
        let first = try OOXMLMedia.mediaMap(url: url, limits: ExtractLimits())
        let second = try OOXMLMedia.mediaMap(url: url, limits: ExtractLimits())

        XCTAssertEqual(first.textPages, second.textPages)
        XCTAssertEqual(first.media, second.media)
        XCTAssertEqual(first.textPages, 1)
        XCTAssertEqual(first.media, ["word/media/image1.png",
                                     "word/media/image2.png",
                                     "word/media/image10.png"])

        // La numérotation des médias suit exactement celle de l'extraction.
        let result = try OOXMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.ocrCandidates,
                       (1...first.media.count).map { first.textPages + $0 })

        let bytes = try OOXMLMedia.extractEntry(url: url, entry: first.media[0])
        XCTAssertEqual(bytes, Fixtures.pngBytes(3))   // image1.png, 3e entrée écrite
    }

    func testDocxWithoutDocumentXMLIsAnError() throws {
        let url = file("vide.docx")
        try Fixtures.makeArchive([("[Content_Types].xml", Fixtures.xml("<t/>"))], at: url)
        XCTAssertThrowsError(try OOXMLExtractor().extract(url: url,
                                                          limits: ExtractLimits())) {
            guard case FouineError.extraction = $0 else {
                return XCTFail("attendu extraction, obtenu \($0)")
            }
        }
    }

    // MARK: - R-13 : notes de bas de page et de fin DOCX

    func testDocxWithFootnotesAndEndnotes() throws {
        let docXML = Fixtures.xml("""
        <w:document xmlns:w="x"><w:body>
        <w:p><w:r><w:t>Corps du texte principal</w:t></w:r></w:p>
        </w:body></w:document>
        """)
        let footnotesXML = Fixtures.xml("""
        <w:footnotes xmlns:w="x">
        <w:footnote w:type="separator"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>
        <w:footnote w:id="1"><w:p><w:r><w:t>Première note de bas de page</w:t></w:r></w:p></w:footnote>
        <w:footnote w:id="2"><w:p><w:r><w:t>Deuxième note de bas de page</w:t></w:r></w:p></w:footnote>
        </w:footnotes>
        """)
        let endnotesXML = Fixtures.xml("""
        <w:endnotes xmlns:w="x">
        <w:endnote w:type="continuationSeparator"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:endnote>
        <w:endnote w:id="1"><w:p><w:r><w:t>Note de fin de document</w:t></w:r></w:p></w:endnote>
        </w:endnotes>
        """)
        let url = file("notes.docx")
        try Fixtures.makeArchive([
            ("word/document.xml", docXML),
            ("word/footnotes.xml", footnotesXML),
            ("word/endnotes.xml", endnotesXML),
        ], at: url)

        let result = try OOXMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pages.count, 1)
        let text = try XCTUnwrap(result.pages.first).text
        XCTAssertTrue(text.contains("Corps du texte principal"), text)
        XCTAssertTrue(text.contains("Première note de bas de page"), text)
        XCTAssertTrue(text.contains("Deuxième note de bas de page"), text)
        XCTAssertTrue(text.contains("Note de fin de document"), text)

        // Les notes viennent après le corps, séparées par une ligne vide (\n\n)
        guard let bodyRange = text.range(of: "Corps du texte principal"),
              let fn1Range = text.range(of: "Première note de bas de page"),
              let fn2Range = text.range(of: "Deuxième note de bas de page"),
              let enRange = text.range(of: "Note de fin de document") else {
            return XCTFail("Morceau manquant dans le texte : \(text)")
        }
        XCTAssertTrue(bodyRange.upperBound < fn1Range.lowerBound)
        XCTAssertTrue(fn1Range.upperBound < fn2Range.lowerBound)
        XCTAssertTrue(fn2Range.upperBound < enRange.lowerBound)
        // Vérifie la séparation par ligne vide entre corps et notes
        let betweenBodyAndNotes = String(text[bodyRange.upperBound..<fn1Range.lowerBound])
        XCTAssertTrue(betweenBodyAndNotes.contains("\n\n"), betweenBodyAndNotes)
    }

    func testDocxWithoutFootnotesExtractsAsBefore() throws {
        let url = try makeDocx(paragraphs: ["Seul le corps existe"])
        let result = try OOXMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pages.count, 1)
        let text = try XCTUnwrap(result.pages.first).text
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "Seul le corps existe")
    }

    func testDocxBudgetTruncatesNotesBeforeBodyWhenSmall() throws {
        let docXML = Fixtures.xml("""
        <w:document xmlns:w="x"><w:body>
        <w:p><w:r><w:t>Corps conserve</w:t></w:r></w:p>
        </w:body></w:document>
        """)
        let footnotesXML = Fixtures.xml("""
        <w:footnotes xmlns:w="x">
        <w:footnote w:id="1"><w:p><w:r><w:t>Note rejetee car hors budget</w:t></w:r></w:p></w:footnote>
        </w:footnotes>
        """)
        let url = file("budget.docx")
        try Fixtures.makeArchive([
            ("word/document.xml", docXML),
            ("word/footnotes.xml", footnotesXML),
        ], at: url)

        // Budget calibré exactement pour le corps ("Corps conserve\n" = 15 octets)
        var limits = ExtractLimits()
        limits.maxTextBytes = 15
        let result = try OOXMLExtractor().extract(url: url, limits: limits)
        let text = result.pages.map(\.text).joined()
        XCTAssertTrue(text.contains("Corps conserve"), text)
        XCTAssertFalse(text.contains("Note rejetee"), text)
    }

    // MARK: - odt

    func testOdt() throws {
        let url = file("memo.odt")
        try Fixtures.makeArchive([
            ("content.xml", Fixtures.xml("""
            <office:document-content xmlns:office="o" xmlns:text="t">
            <office:body><office:text>
            <text:h>Titre du mémo</text:h>
            <text:p>Cinétique du <text:span>premier</text:span> ordre</text:p>
            </office:text></office:body></office:document-content>
            """)),
        ], at: url)
        let result = try OOXMLExtractor().extract(url: url, limits: ExtractLimits())
        let text = result.pages.map(\.text).joined()
        XCTAssertTrue(text.contains("Titre du mémo"), text)
        XCTAssertTrue(text.contains("Cinétique du premier ordre"), text)
        XCTAssertTrue(result.ocrCandidates.isEmpty)
    }

    // MARK: - ods

    func testOds() throws {
        let url = file("classeur.ods")
        try Fixtures.makeArchive([
            ("content.xml", Fixtures.xml("""
            <office:document-content xmlns:office="o" xmlns:text="t" xmlns:table="tab">
            <office:body><office:spreadsheet>
            <table:table><table:table-row><table:table-cell>
            <text:p>Cellule A1 chlore</text:p>
            </table:table-cell></table:table-row></table:table>
            </office:spreadsheet></office:body></office:document-content>
            """)),
        ], at: url)
        let result = try OOXMLExtractor().extract(url: url, limits: ExtractLimits())
        let text = result.pages.map(\.text).joined()
        XCTAssertTrue(text.contains("Cellule A1 chlore"), text)
        XCTAssertTrue(result.ocrCandidates.isEmpty)
    }

    // MARK: - odp

    func testOdp() throws {
        let url = file("presentation.odp")
        try Fixtures.makeArchive([
            ("content.xml", Fixtures.xml("""
            <office:document-content xmlns:office="o" xmlns:text="t" xmlns:draw="d">
            <office:body><office:presentation>
            <draw:page>
            <text:p>Diapositive ODF phosphore</text:p>
            </draw:page>
            </office:presentation></office:body></office:document-content>
            """)),
        ], at: url)
        let result = try OOXMLExtractor().extract(url: url, limits: ExtractLimits())
        let text = result.pages.map(\.text).joined()
        XCTAssertTrue(text.contains("Diapositive ODF phosphore"), text)
        XCTAssertTrue(result.ocrCandidates.isEmpty)
    }

    // MARK: - xlsx

    func testXlsxResolvesSharedStringsAndOnePagePerSheet() throws {
        let url = file("suivi.xlsx")
        let shared = Fixtures.xml("""
        <sst xmlns="s" count="3" uniqueCount="3">
        <si><t>Échantillon</t></si><si><t>Rendement</t></si><si><t>Titrage</t></si>
        </sst>
        """)
        let sheet1 = Fixtures.xml("""
        <worksheet xmlns="s"><sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
        <row r="2"><c r="A2"><v>42</v></c><c r="B2" t="inlineStr"><is><t>libre</t></is></c></row>
        </sheetData></worksheet>
        """)
        let sheet2 = Fixtures.xml("""
        <worksheet xmlns="s"><sheetData>
        <row r="1"><c r="A1" t="s"><v>2</v></c></row>
        </sheetData></worksheet>
        """)
        try Fixtures.makeArchive([
            ("xl/sharedStrings.xml", shared),
            ("xl/worksheets/sheet1.xml", sheet1),
            ("xl/worksheets/sheet2.xml", sheet2),
            ("xl/media/image1.png", Fixtures.pngBytes(9)),
        ], at: url)

        let result = try OOXMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 3)          // 2 feuilles + 1 image
        XCTAssertEqual(result.pages.count, 2)
        XCTAssertTrue(result.pages[0].text.contains("Échantillon\tRendement"),
                      result.pages[0].text)
        XCTAssertTrue(result.pages[0].text.contains("42\tlibre"), result.pages[0].text)
        XCTAssertEqual(result.pages[1].text, "Titrage")
        XCTAssertEqual(result.ocrCandidates, [3])
    }

    // MARK: - pptx

    func testPptxOneSlidePerPageInNumericOrder() throws {
        let url = file("soutenance.pptx")
        func slide(_ text: String) -> Data {
            Fixtures.xml("""
            <p:sld xmlns:p="p" xmlns:a="a"><p:cSld><p:spTree>
            <p:sp><p:txBody><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></p:txBody></p:sp>
            </p:spTree></p:cSld></p:sld>
            """)
        }
        try Fixtures.makeArchive([
            ("ppt/slides/slide10.xml", slide("Dixième diapositive")),
            ("ppt/slides/slide2.xml", slide("Deuxième diapositive")),
            ("ppt/slides/slide1.xml", slide("Première diapositive")),
            ("ppt/slides/_rels/slide1.xml.rels", Fixtures.xml("<Relationships/>")),
            ("ppt/media/image1.png", Fixtures.pngBytes(1)),
            ("ppt/media/image2.png", Fixtures.pngBytes(2)),
        ], at: url)

        let result = try OOXMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pages.count, 3)
        XCTAssertEqual(result.pages.map(\.page), [1, 2, 3])
        XCTAssertTrue(result.pages[0].text.contains("Première"), result.pages[0].text)
        XCTAssertTrue(result.pages[1].text.contains("Deuxième"), result.pages[1].text)
        XCTAssertTrue(result.pages[2].text.contains("Dixième"), result.pages[2].text)
        XCTAssertEqual(result.pageCount, 5)
        XCTAssertEqual(result.ocrCandidates, [4, 5])
    }

    // MARK: - epub

    func testEpubFollowsTheSpineOrderAndSplitsInsideEachFile() throws {
        let url = file("livre.epub")
        let long = String(repeating: "chapitre premier ", count: 400)  // 6 800 car.
        try Fixtures.makeArchive([
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Fixtures.xml("""
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf"
            media-type="application/oebps-package+xml"/></rootfiles></container>
            """)),
            ("OEBPS/content.opf", Fixtures.xml("""
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Chimie organique</dc:title><dc:creator>Arnaud</dc:creator>
            <dc:language>fr</dc:language></metadata>
            <manifest>
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine><itemref idref="c2"/><itemref idref="c1"/></spine>
            </package>
            """)),
            ("OEBPS/ch1.xhtml",
             Data("<html><body><p>Fin du livre</p></body></html>".utf8)),
            ("OEBPS/ch2.xhtml",
             Data("<html><body><p>\(long)</p></body></html>".utf8)),
        ], at: url)

        let result = try EPUBExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.meta["title"], "Chimie organique")
        XCTAssertEqual(result.meta["author"], "Arnaud")
        XCTAssertEqual(result.meta["lang"], "fr")
        // ch2 vient en premier (ordre du spine), et il est découpé à 4 000.
        XCTAssertGreaterThanOrEqual(result.pageCount, 3)
        XCTAssertTrue(result.pages[0].text.contains("chapitre premier"))
        XCTAssertLessThanOrEqual(result.pages[0].text.count, 4_000)
        XCTAssertTrue(try XCTUnwrap(result.pages.last).text.contains("Fin du livre"))
        XCTAssertTrue(result.ocrCandidates.isEmpty)
    }

    // MARK: - cbz

    func testComicArchiveIsAllImagesAndNoText() throws {
        let url = file("bd.cbz")
        try Fixtures.makeArchive([
            ("bd/img10.jpg", Fixtures.pngBytes(10)),
            ("bd/img2.jpg", Fixtures.pngBytes(2)),
            ("bd/img1.jpg", Fixtures.pngBytes(1)),
            ("bd/lisezmoi.txt", Data("pas une image".utf8)),
            ("__MACOSX/bd/._img1.jpg", Fixtures.pngBytes(99)),
        ], at: url)

        let entries = try ArchiveImages.imageEntries(archiveURL: url)
        XCTAssertEqual(entries, ["bd/img1.jpg", "bd/img2.jpg", "bd/img10.jpg"])

        let result = try ComicArchiveExtractor().extract(url: url,
                                                         limits: ExtractLimits())
        XCTAssertTrue(result.pages.isEmpty)
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertEqual(result.ocrCandidates, [1, 2, 3])

        // L'ordre des entrées EST la numérotation des pages.
        XCTAssertEqual(try ArchiveImages.extractEntry(archiveURL: url,
                                                      entry: entries[1]),
                       Fixtures.pngBytes(2))
    }

    func testArchiveEntryNamesWithGlobCharactersAreExact() throws {
        let url = file("bd2.cbz")
        try Fixtures.makeArchive([
            ("img[1].png", Fixtures.pngBytes(7)),
            ("img1.png", Fixtures.pngBytes(8)),
        ], at: url)
        // Sans échappement, bsdtar traite « img[1].png » comme une classe de
        // caractères et rendrait img1.png (vérifié sur la machine).
        XCTAssertEqual(try Bsdtar.extract(archive: url, entry: "img[1].png"),
                       Fixtures.pngBytes(7))
    }

    func testMissingEntryRaisesTheStderrMessage() throws {
        let url = file("bd3.cbz")
        try Fixtures.makeArchive([("img1.png", Fixtures.pngBytes(1))], at: url)
        XCTAssertThrowsError(try Bsdtar.extract(archive: url, entry: "absent.png")) {
            guard case let FouineError.extraction(message) = $0 else {
                return XCTFail("attendu extraction, obtenu \($0)")
            }
            XCTAssertTrue(message.contains("Not found in archive"), message)
        }
    }

    // MARK: - X1 : le listage est borné

    /// Une archive d'entrées VIDES : quelques dizaines d'octets chacune dans le
    /// fichier, une ligne entière au listage. C'est la « bombe d'entrées »,
    /// cousine de la bombe de décompression d'A11.2 — et c'est ce que les deux
    /// plafonds de `list` arrêtent.
    func makeManyEntries(_ count: Int, named name: String) throws -> URL {
        let url = file(name)
        try Fixtures.makeArchive((0..<count).map {
            (name: String(format: "p/%05d.png", $0), data: Data())
        }, at: url)
        return url
    }

    func testListingIsRefusedBeyondTheEntryCap() throws {
        let url = try makeManyEntries(300, named: "bombe.cbz")

        // Sous le plafond : le listage se fait, entrées de dossier comprises.
        let entries = try Bsdtar.list(archive: url, maxEntries: 400)
        XCTAssertGreaterThanOrEqual(entries.count, 300)

        // Au-dessus : refus explicite, pas un dépassement mémoire silencieux.
        XCTAssertThrowsError(try Bsdtar.list(archive: url, maxEntries: 100)) {
            guard case let FouineError.extraction(message) = $0 else {
                return XCTFail("attendu extraction, obtenu \($0)")
            }
            XCTAssertTrue(message.contains("archive refused"), message)
            XCTAssertTrue(message.contains("cap 100"), message)
            XCTAssertTrue(message.contains("bombe.cbz"), message)
        }
    }

    /// Le second plafond, en octets : c'est celui qui interrompt bsdtar EN COURS
    /// de listage, donc le seul qui borne vraiment la mémoire d'un worker.
    func testListingIsRefusedBeyondTheByteCap() throws {
        let url = try makeManyEntries(300, named: "longue.cbz")
        XCTAssertThrowsError(try Bsdtar.list(archive: url, maxEntries: 10_000,
                                             maxBytes: 512)) {
            guard case let FouineError.extraction(message) = $0 else {
                return XCTFail("attendu extraction, obtenu \($0)")
            }
            XCTAssertTrue(message.contains("output too large"), message)
        }
    }

    /// Les valeurs de service, telles que la CLI et l'agent les appliquent.
    func testServiceListingCapsAreTheDocumentedOnes() {
        XCTAssertEqual(Bsdtar.maxListingEntries, 100_000)
        XCTAssertEqual(Bsdtar.maxListingBytes, 16 << 20)
        // Le listage est BEAUCOUP plus serré que le contenu : ce sont des noms.
        XCTAssertLessThan(Bsdtar.maxListingBytes, Bsdtar.maxDecompressedBytes)
    }
}
