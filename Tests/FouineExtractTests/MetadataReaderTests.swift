// MetadataReaderTests.swift — la date d'un fichier, format par format (lot DD1,
// constat PR-07). Propriété : A-Ingest.
//
// Deux choses sont prouvées ici, sur des fixtures FABRIQUÉES dans le test :
//
//   1. chaque format rend la date qu'il porte, aussi bien par l'EXTRACTION
//      (`meta["date"]`, chemin de l'indexation) que par le LECTEUR SEUL
//      (`MetadataReader.date`, chemin du rattrapage) — les deux doivent dire la
//      même chose, sans quoi un fonds rattrapé et un fonds réindexé ne se
//      rangeraient pas pareil ;
//   2. une entrée hostile ne fait rien exploser : archive tronquée, fichier
//      dont l'extension ment, entité XML récursive, nom qui commence par un
//      tiret. Le lecteur rend `nil`, et c'est tout (règle d'extraction).

import XCTest
import ImageIO
import PDFKit
@testable import FouineCore
@testable import FouineExtract

final class MetadataReaderTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("metadata")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// Le jour civil d'une chaîne brute, pour comparer sans dépendre du fuseau.
    private func day(_ raw: String?) -> String? {
        guard let raw, let seconds = DocumentDate.parse(raw) else { return nil }
        let c = DocumentDate.civil(seconds)
        return String(format: "%04d-%02d-%02d", c.year, c.month, c.day)
    }

    // MARK: - PDF

    /// Un PDF MINIMAL écrit octet par octet, avec le `/CreationDate` que l'on
    /// veut. Il faut en passer par là : `CGContext` et `PDFDocument.write(to:)`
    /// réécrivent tous deux la date de création à l'instant de l'écriture
    /// (vérifié ici même — c'est ce qui a fait échouer la première version de
    /// ce test), et une fixture datée d'aujourd'hui ne prouverait rien.
    private func makeMinimalPDF(_ url: URL, creationDate: String?) throws {
        var objects = [
            "<</Type/Catalog/Pages 2 0 R>>",
            "<</Type/Pages/Kids[3 0 R]/Count 1>>",
            "<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>",
        ]
        if let creationDate {
            objects.append("<</CreationDate(\(creationDate))>>")
        }
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        let info = creationDate == nil ? "" : "/Info \(objects.count) 0 R"
        pdf += "trailer\n<</Size \(objects.count + 1)/Root 1 0 R\(info)>>\n"
            + "startxref\n\(xref)\n%%EOF\n"
        try Data(pdf.utf8).write(to: url)
    }

    func testPDFCreationDateReachesBothPaths() throws {
        let url = file("livre.pdf")
        try makeMinimalPDF(url, creationDate: "D:20030412103000+02\'00\'")
        XCTAssertNotNil(PDFDocument(url: url), "la fixture est un PDF valide")

        let extracted = try PDFExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(day(extracted.meta["date"]), "2003-04-12")
        XCTAssertEqual(day(MetadataReader.date(of: url)), "2003-04-12",
                       "le rattrapage lit la même date que l'extraction")
    }

    /// Le rattrapage ne doit RIEN rendre plutôt qu'une date fausse quand le
    /// fichier n'en porte pas.
    func testAPDFWithoutACreationDateHasNoDate() throws {
        let url = file("sans-date.pdf")
        try makeMinimalPDF(url, creationDate: nil)
        XCTAssertNotNil(PDFDocument(url: url))
        XCTAssertNil(MetadataReader.date(of: url))
    }

    // MARK: - Bureautique

    private func makeDocx(_ url: URL, core: String?) throws {
        var entries: [(name: String, data: Data)] = [
            ("word/document.xml",
             Data("""
             <?xml version="1.0"?>
             <w:document xmlns:w="x"><w:body><w:p><w:t>cristallographie</w:t></w:p></w:body></w:document>
             """.utf8)),
        ]
        if let core {
            entries.append(("docProps/core.xml", Data(core.utf8)))
        }
        try Fixtures.makeArchive(entries, at: url)
    }

    func testDocxCreationDate() throws {
        let url = file("rapport.docx")
        try makeDocx(url, core: """
            <?xml version="1.0"?>
            <cp:coreProperties xmlns:cp="c" xmlns:dcterms="t">
              <dcterms:created>2003-04-12T10:30:00Z</dcterms:created>
              <dcterms:modified>2024-08-01T09:00:00Z</dcterms:modified>
            </cp:coreProperties>
            """)
        let extracted = try OOXMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(day(extracted.meta["date"]), "2003-04-12")
        XCTAssertEqual(day(MetadataReader.date(of: url)), "2003-04-12",
                       "la date de MODIFICATION n'est jamais prise : c'est mtime")
    }

    func testDocxWithoutCorePropertiesHasNoDate() throws {
        let url = file("nu.docx")
        try makeDocx(url, core: nil)
        XCTAssertNil(MetadataReader.date(of: url))
        let extracted = try OOXMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertNil(extracted.meta["date"])
    }

    func testOpenDocumentCreationDate() throws {
        let url = file("lettre.odt")
        try Fixtures.makeArchive([
            ("content.xml",
             Data("""
             <?xml version="1.0"?>
             <office xmlns:text="t"><text:p>entropie libre</text:p></office>
             """.utf8)),
            ("meta.xml",
             Data("""
             <?xml version="1.0"?>
             <office xmlns:meta="m" xmlns:dc="d">
               <meta:creation-date>1998-07-03T08:00:00</meta:creation-date>
             </office>
             """.utf8)),
        ], at: url)
        XCTAssertEqual(day(MetadataReader.date(of: url)), "1998-07-03")
    }

    // MARK: - EPUB

    func testEPUBPublicationDate() throws {
        let url = file("ouvrage.epub")
        try Fixtures.makeArchive([
            ("META-INF/container.xml",
             Data("""
             <?xml version="1.0"?>
             <container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>
             """.utf8)),
            ("OEBPS/content.opf",
             Data("""
             <?xml version="1.0"?>
             <package xmlns:dc="http://purl.org/dc/elements/1.1/">
               <metadata>
                 <dc:title>Traité</dc:title>
                 <dc:date>1978-05-09</dc:date>
                 <dc:date>2019-01-01</dc:date>
               </metadata>
               <manifest><item id="c1" href="c1.xhtml"/></manifest>
               <spine><itemref idref="c1"/></spine>
             </package>
             """.utf8)),
            ("OEBPS/c1.xhtml",
             Data("<html><body><p>cristallographie</p></body></html>".utf8)),
        ], at: url)

        let extracted = try EPUBExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(day(extracted.meta["date"]), "1978-05-09",
                       "le PREMIER dc:date, celui de la publication")
        XCTAssertEqual(day(MetadataReader.date(of: url)), "1978-05-09")
    }

    // MARK: - Photo

    func testImageExifDateTimeOriginal() throws {
        let url = file("photo.jpg")
        let image = try XCTUnwrap(ImageFixture.grayImage(
            width: 400, height: 300, noise: true, text: nil))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2003:04:12 10:30:00",
            ],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let extracted = try ImageExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(day(extracted.meta["date"]), "2003-04-12")
        XCTAssertEqual(day(MetadataReader.date(of: url)), "2003-04-12")
    }

    // MARK: - Courriel

    func testEmailDateHeader() throws {
        let url = file("message.eml")
        try Data("""
        From: a@example.org
        To: b@example.org
        Subject: Attestation
        Date: Sat, 12 Apr 2003 10:30:00 +0200

        Le corps du message, assez long pour être indexé sans mal.
        """.utf8).write(to: url)

        let extracted = try EMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(day(extracted.meta["date"]), "2003-04-12")
        XCTAssertEqual(day(MetadataReader.date(of: url)), "2003-04-12")
    }

    /// Un courriel dont la pièce jointe pèse plus que la fenêtre d'en-têtes :
    /// le lecteur ne lit que la tête et trouve quand même la date.
    func testEmailDateIsFoundWithoutReadingTheWholeFile() throws {
        let url = file("lourd.eml")
        let filler = String(repeating: "A", count: MetadataReader.emailHeaderBytes * 2)
        try Data("""
        From: a@example.org
        Date: Sat, 12 Apr 2003 10:30:00 +0200
        Subject: pièce jointe

        \(filler)
        """.utf8).write(to: url)
        XCTAssertEqual(day(MetadataReader.date(of: url)), "2003-04-12")
    }

    // MARK: - Entrées hostiles

    /// Aucune de ces entrées ne doit lever, ni tuer le processus : le
    /// rattrapage parcourt un fonds entier, il ne peut pas s'arrêter au premier
    /// fichier cassé.
    func testHostileInputsYieldNilAndNothingElse() throws {
        // 1. Archive tronquée au milieu d'une structure.
        let truncated = file("tronque.docx")
        try makeDocx(truncated, core: "<?xml version=\"1.0\"?><cp><dcterms:created>2003-04-12</dcterms:created></cp>")
        let bytes = try Data(contentsOf: truncated)
        try bytes.prefix(bytes.count / 3).write(to: truncated)
        XCTAssertNil(MetadataReader.date(of: truncated))

        // 2. Un PNG qui se fait passer pour un document Word.
        let liar = file("menteur.docx")
        try ImageFixture.pngData(width: 40, height: 40).write(to: liar)
        XCTAssertNil(MetadataReader.date(of: liar))

        // 3. Fichier vide, et fichier qui n'existe pas.
        let empty = file("vide.pdf")
        try Data().write(to: empty)
        XCTAssertNil(MetadataReader.date(of: empty))
        XCTAssertNil(MetadataReader.date(of: file("jamais-ecrit.epub")))

        // 4. Entité XML récursive (« milliard de rires ») dans core.xml, et
        //    entité EXTERNE : `XMLParser` ne résout ni l'une ni l'autre.
        let bomb = file("bombe.docx")
        try makeDocx(bomb, core: """
            <?xml version="1.0"?>
            <!DOCTYPE cp [
              <!ENTITY a "aaaaaaaaaa">
              <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">
              <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">
              <!ENTITY passwd SYSTEM "file:///etc/passwd">
            ]>
            <cp:coreProperties xmlns:cp="c" xmlns:dcterms="t">
              <dcterms:created>&c;&passwd;</dcterms:created>
            </cp:coreProperties>
            """)
        let bombDate = MetadataReader.date(of: bomb)
        XCTAssertNil(DocumentDate.parse(bombDate ?? ""),
                     "une entité n'est pas une date, et rien du disque n'en sort")
        XCTAssertFalse((bombDate ?? "").contains("root:"))

        // 5. Nom de fichier qui commence par un tiret (piège d'outil externe).
        let dashed = file("-piege.docx")
        try makeDocx(dashed, core: """
            <?xml version="1.0"?>
            <cp:coreProperties xmlns:cp="c" xmlns:dcterms="t">
              <dcterms:created>2003-04-12T10:30:00Z</dcterms:created>
            </cp:coreProperties>
            """)
        XCTAssertEqual(day(MetadataReader.date(of: dashed)), "2003-04-12")

        // 6. Un format qui ne date rien : on n'ouvre même pas le fichier.
        let text = file("notes.txt")
        try Data("entropie".utf8).write(to: text)
        XCTAssertNil(MetadataReader.date(of: text))
    }
}
