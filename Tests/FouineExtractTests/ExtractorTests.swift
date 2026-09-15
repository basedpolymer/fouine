// ExtractorTests.swift — les 17 formats du §5.3 sur fixtures synthétiques.
// Propriété : A-Ingest.

import XCTest
import FouineCore
import FouineCrawl
@testable import FouineExtract

final class RegistryTests: XCTestCase {

    /// Le registre est l'UNION des extracteurs, et le crawler en tient la copie
    /// (`Package.swift` est gele : FouineCrawl n'a pas FouineExtract dans ses
    /// dependances). Cette suite-ci, elle, voit les deux modules : c'est donc
    /// ici que l'egalite se prouve, et non par deux litteraux qui derivent.
    func testSupportedExtensionsMirrorTheCrawlerList() {
        XCTAssertEqual(DefaultExtractorRegistry.supportedExtensions,
                       FouineCrawler.defaultIndexableExtensions)
    }

    /// Les familles du §5.3, amende le 08/09/2026 (INT-F1) : bureautique
    /// ancienne, courriels hors `.eml`, fichiers techniques.
    func testEveryFamilyOfSection53IsCovered() {
        let supported = DefaultExtractorRegistry.supportedExtensions
        for ext in ["pdf", "doc", "rtf", "rtfd", "docx", "odt", "ods", "odp",
                    "xlsx", "pptx", "xls", "ppt", "html", "htm", "webarchive",
                    "txt", "md", "csv", "tsv", "tex", "json", "log",
                    "epub", "cbz", "cbr", "djvu", "pages", "numbers", "key",
                    "srt", "vtt", "ipynb",
                    "eml", "emlx", "olk15msgsource", "mbox",
                    "xml", "xsd", "xsl", "xslt", "svg", "plist",
                    "py", "js", "tsx", "swift", "yaml", "sql", "sh"] {
            XCTAssertTrue(supported.contains(ext), ext)
        }
        XCTAssertFalse(supported.contains("mp4"))
        XCTAssertFalse(supported.contains("png"))   // hors reglage extract.images
    }

    /// Le crawler recopie cette liste (Package.swift est gelé : FouineCrawl n'a
    /// pas FouineExtract dans ses dépendances). Les deux doivent coïncider.
    func testRegistryCoversEveryExtension() {
        let registry = DefaultExtractorRegistry()
        for ext in DefaultExtractorRegistry.supportedExtensions {
            XCTAssertNotNil(registry.extractor(for: ext), ext)
            XCTAssertNotNil(registry.extractor(for: ext.uppercased()), ext)
        }
        XCTAssertNil(registry.extractor(for: "mp4"))
        XCTAssertNil(registry.extractor(for: "hsc"))
    }
}

final class PlainAndRichTextTests: XCTestCase {

    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("extract")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func testPlainTextIsSplitOnParagraphBoundaries() throws {
        let paragraph = String(repeating: "azote ", count: 200)   // 1 200 caractères
        let text = Array(repeating: paragraph, count: 10).joined(separator: "\n\n")
        let url = file("notes.txt")
        try Data(text.utf8).write(to: url)

        let result = try PlainTextExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertGreaterThan(result.pageCount, 1)
        XCTAssertEqual(result.pages.count, result.pageCount)
        XCTAssertEqual(result.pages.map(\.page), Array(1...result.pageCount))
        XCTAssertTrue(result.ocrCandidates.isEmpty)   // rien à rendre en image
        for page in result.pages {
            XCTAssertLessThanOrEqual(page.text.count, 4_000)
            XCTAssertEqual(page.source, .native)
        }
        XCTAssertEqual(result.pages.map(\.text).joined(), text)
    }

    func testFallsBackFromUTF8ToLatin1() throws {
        let url = file("vieux.log")
        try XCTUnwrap("Équilibre à 25 °C".data(using: .isoLatin1)).write(to: url)
        let result = try PlainTextExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pages.first?.text, "Équilibre à 25 °C")
    }

    func testTSVFile() throws {
        let url = file("mesures.tsv")
        let tsvContent = "temps\ttemperature\tpression\n0\t20.5\t1013\n10\t25.0\t1015"
        try Data(tsvContent.utf8).write(to: url)
        let result = try PlainTextExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertEqual(result.pages.first?.text, tsvContent)
    }

    func testFileTooLargeIsRefused() throws {
        let url = file("gros.txt")
        try Data(String(repeating: "x", count: 4_096).utf8).write(to: url)
        var limits = ExtractLimits()
        limits.maxFileBytes = 1_024
        XCTAssertThrowsError(try PlainTextExtractor().extract(url: url, limits: limits)) {
            guard case let FouineError.fileTooLarge(bytes) = $0 else {
                return XCTFail("attendu fileTooLarge, obtenu \($0)")
            }
            XCTAssertEqual(bytes, 4_096)
        }
    }

    func testMaxTextBytesCapsTheDocument() throws {
        let url = file("enorme.txt")
        // Des MOTS : 50 000 « y » d'un seul tenant sont refusés comme suite de
        // données depuis EX2, et c'est le plafond d'octets qu'on prouve ici.
        try Data(String(repeating: "yyyy ", count: 10_000).utf8).write(to: url)
        var limits = ExtractLimits()
        limits.maxTextBytes = 5_000
        let result = try PlainTextExtractor().extract(url: url, limits: limits)
        XCTAssertEqual(result.pages.map(\.text.count).reduce(0, +), 5_000)
    }

    func testRTFIsReadWithItsAccents() throws {
        let url = file("lettre.rtf")
        try Data("{\\rtf1\\ansi\\ansicpg1252 Bonjour \\'e9quilibre chimique.}".utf8)
            .write(to: url)
        let result = try RichTextExtractor().extract(url: url, limits: ExtractLimits())
        let text = result.pages.map(\.text).joined()
        XCTAssertTrue(text.contains("équilibre"), text)
    }

    /// Un `.rtfd` est un PAQUET (un dossier) : le crawler l'enregistre comme un
    /// fichier, l'extracteur le lit comme un document.
    func testRTFDBundleIsReadAsADocument() throws {
        let bundle = file("note.rtfd")
        try FileManager.default.createDirectory(at: bundle,
                                                withIntermediateDirectories: true)
        try Data("{\\rtf1\\ansi Titrage acido-basique r\\'e9ussi.}".utf8)
            .write(to: bundle.appendingPathComponent("TXT.rtf"))
        let result = try RichTextExtractor().extract(url: bundle,
                                                     limits: ExtractLimits())
        XCTAssertTrue(result.pages.map(\.text).joined().contains("Titrage"))
    }

    /// Contrôle de plausibilité (§5.3) : des octets binaires déguisés en .rtf ne
    /// doivent JAMAIS entrer dans l'index, ni en erreur, ni en mojibake.
    func testBinaryDisguisedAsRTFIsRejected() throws {
        let url = file("piege.rtf")
        var bytes = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        for value in 0..<2_000 { bytes.append(UInt8(128 + value % 128)) }
        try bytes.write(to: url)

        XCTAssertThrowsError(try RichTextExtractor().extract(url: url,
                                                            limits: ExtractLimits())) {
            guard case FouineError.extraction = $0 else {
                return XCTFail("attendu extraction, obtenu \($0)")
            }
        }
    }

    /// xls / ppt : ils ne sont PLUS refuses d'office (INT-F1). Un OLE tronque
    /// reste refuse, mais sur ce qu'il est — un conteneur illisible —, et le
    /// libelle « unsupported binary OLE format » ne sort plus jamais.
    func testBinaryOfficeIsParsedNotRefusedOutright() throws {
        for ext in ["xls", "ppt"] {
            let url = file("cours.\(ext)")
            try Data([0xD0, 0xCF, 0x11, 0xE0]).write(to: url)
            XCTAssertThrowsError(try DefaultExtractorRegistry().extract(url: url)) {
                guard case let FouineError.extraction(message) = $0 else {
                    return XCTFail("attendu extraction, obtenu \($0)")
                }
                XCTAssertTrue(message.contains("unreadable OLE container"), message)
                XCTAssertFalse(message.contains("unsupported binary OLE format"),
                               message)
            }
            XCTAssertEqual(ExtractOutcome.skipReason(ext: ext), "unsupported format")
        }
    }

    func testDjvuWithoutDjvulibreIsUnsupported() throws {
        try XCTSkipIf(DjvuExtractor.tool() != nil, "djvulibre est installé ici")
        let url = file("scan.djvu")
        try Data("AT&TFORM".utf8).write(to: url)
        XCTAssertThrowsError(try DjvuExtractor().extract(url: url,
                                                         limits: ExtractLimits())) {
            guard case let FouineError.unsupported(ext) = $0 else {
                return XCTFail("attendu unsupported, obtenu \($0)")
            }
            XCTAssertEqual(ext, "djvu")
        }
        XCTAssertEqual(DjvuExtractor.reason,
                       "djvu: djvulibre is missing (missing-tool:djvused)")
    }

    /// A3-05 : le motif porte un JETON que le crawl sait relire, sinon un
    /// `.djvu` sauté avant `brew install djvulibre` le reste à vie (installer
    /// l'outil ne change ni la taille ni le mtime du fichier). C'est ce test qui
    /// tient l'autre bout du littéral recopié dans `CrawlTests`.
    func testDjvuSkipReasonCarriesTheToolToken() {
        XCTAssertEqual(ExternalTool.missingTool(inSkipReason: DjvuExtractor.reason),
                       DjvuExtractor.executable)
        XCTAssertEqual(DjvuExtractor.executable, "djvused")
        XCTAssertEqual(DjvuExtractor.overrideVariable, "FOUINE_DJVUSED")
        // Et la phrase reste lisible : le jeton s'ajoute, il ne remplace pas.
        XCTAssertTrue(DjvuExtractor.reason.hasPrefix("djvu: djvulibre is missing"))
    }

    /// C4.1 : N pages réelles donnent N emplacements AUX BONS NUMÉROS. Deux
    /// pièges cumulés sur ce fixture, chacun décalant tout ce qui suit :
    ///   · la page 2 dépasse pageSplitChars — la re-paginer la comptait double ;
    ///   · la page 3 n'a pas de couche texte — djvutxt l'omettait sans même
    ///     émettre son saut de page (d'où la lecture par djvused, page par page).
    func testDjvuPageNumbersSurviveDensePagesAndGaps() throws {
        try XCTSkipIf(DjvuExtractor.tool() == nil, "djvulibre absent")
        let url = file("livre.djvu")
        let dense = "PAGEDEUX " + String(repeating: "x", count: 5_000)
        try XCTSkipUnless(try Fixtures.makeDjvu(
            pages: ["PAGEUNE alpha", dense, "", "PAGEQUATRE delta", "PAGECINQ eta"],
            at: url), "cjb2/djvm/djvused indisponibles")

        let result = try DjvuExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 5)
        // La page 3 est blanche : pas de PageText, mais son emplacement est compté.
        XCTAssertEqual(result.pages.map(\.page), [1, 2, 4, 5])
        XCTAssertTrue(result.pages[0].text.contains("PAGEUNE"), result.pages[0].text)
        XCTAssertGreaterThan(result.pages[1].text.count, 4_000)
        XCTAssertTrue(result.pages[2].text.contains("PAGEQUATRE"),
                      String(result.pages[2].text.prefix(40)))
        XCTAssertTrue(result.pages[3].text.contains("PAGECINQ"),
                      String(result.pages[3].text.prefix(40)))
        XCTAssertTrue(result.ocrCandidates.isEmpty)   // pas de rendu djvu (C4.3)
        // djvused pose un octet NUL devant ses sauts de page (mesuré : 1 048 pour
        // les 1 049 pages de Huheey 1997). Il ne doit pas entrer dans page_fts.
        XCTAssertFalse(result.pages.contains { $0.text.contains("\0") })
    }

    /// C4.2 : un djvu SANS couche texte ne doit pas entrer `.extracted` à zéro
    /// page en silence — aucun OCR ne le rattraperait.
    func testDjvuWithoutTextLayerIsReported() throws {
        try XCTSkipIf(DjvuExtractor.tool() == nil, "djvulibre absent")
        let url = file("scan-nu.djvu")
        try XCTSkipUnless(try Fixtures.makeDjvu(pages: ["", ""], at: url),
                          "cjb2/djvm/djvused indisponibles")

        XCTAssertThrowsError(try DjvuExtractor().extract(url: url,
                                                         limits: ExtractLimits())) {
            guard case let FouineError.extraction(message) = $0 else {
                return XCTFail("attendu extraction, obtenu \($0)")
            }
            XCTAssertTrue(message.contains("no text layer"), message)
        }
    }

    func testHTMLFile() throws {
        let url = file("page.html")
        try Data("""
        <html><head><title>Cours</title><style>p{}</style></head>
        <body><p>Enthalpie &amp; entropie</p><script>alert(1)</script></body></html>
        """.utf8).write(to: url)
        let result = try HTMLExtractor().extract(url: url, limits: ExtractLimits())
        let text = result.pages.map(\.text).joined()
        XCTAssertTrue(text.contains("Enthalpie & entropie"), text)
        XCTAssertFalse(text.contains("alert"), text)
        XCTAssertEqual(result.meta["title"], "Cours")
    }

    func testWebArchive() throws {
        let url = file("page.webarchive")
        let html = "<html><body><p>Chromatographie sur couche mince</p></body></html>"
        let plist: [String: Any] = [
            "WebMainResource": [
                "WebResourceData": Data(html.utf8),
                "WebResourceMIMEType": "text/html",
                "WebResourceTextEncodingName": "UTF-8",
                "WebResourceURL": "https://example.invalid/",
            ] as [String: Any],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .binary, options: 0)
        try data.write(to: url)
        let result = try HTMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertTrue(result.pages.map(\.text).joined().contains("Chromatographie"))
    }
}

final class IWorkExtractorTests: XCTestCase {

    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("iwork")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func testPagesZipWithQuickLookPreview() throws {
        let pdfURL = file("temp_preview.pdf")
        let page1 = ["Rapport Pages Page 1 turbidite"] + Fixtures.filler(marker: "turbidite")
        let page2 = ["Rapport Pages Page 2 barometrique"] + Fixtures.filler(marker: "barometrique")
        try Fixtures.makePDF(pages: [page1, page2], at: pdfURL)
        let pdfData = try Data(contentsOf: pdfURL)

        let pagesURL = file("Rapport.pages")
        try Fixtures.makeArchive([
            ("Index/Document.iwa", Data("protobuf".utf8)),
            ("QuickLook/Preview.pdf", pdfData),
        ], at: pagesURL)

        let result = try IWorkExtractor().extract(url: pagesURL, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(result.pages.count, 2)
        XCTAssertTrue(result.pages[0].text.contains("turbidite"), result.pages[0].text)
        XCTAssertTrue(result.pages[1].text.contains("barometrique"), result.pages[1].text)
        XCTAssertEqual(result.pages[0].source, .native)
        XCTAssertEqual(result.pages[1].source, .native)
    }

    func testNumbersPackageWithQuickLookPreview() throws {
        let packageURL = file("Bilan.numbers")
        let qlDir = packageURL.appendingPathComponent("QuickLook", isDirectory: true)
        try FileManager.default.createDirectory(at: qlDir, withIntermediateDirectories: true)
        let pdfURL = qlDir.appendingPathComponent("Preview.pdf")
        let lines = ["Tableau Numbers pyrometrie"] + Fixtures.filler(marker: "pyrometrie")
        try Fixtures.makePDF(pages: [lines], at: pdfURL)

        let result = try IWorkExtractor().extract(url: packageURL, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertEqual(result.pages.count, 1)
        XCTAssertTrue(result.pages[0].text.contains("pyrometrie"), result.pages[0].text)
        XCTAssertEqual(result.pages[0].source, .native)
    }

    func testKeynoteZipWithoutPreviewThrowsExplicitError() throws {
        let keyURL = file("Presentation.key")
        try Fixtures.makeArchive([
            ("Index/Document.iwa", Data("keynote protobuf".utf8)),
        ], at: keyURL)

        XCTAssertThrowsError(try IWorkExtractor().extract(url: keyURL, limits: ExtractLimits())) { error in
            guard let f = error as? FouineError, case .extraction(let msg) = f else {
                XCTFail("attendu FouineError.extraction, obtenu: \(error)")
                return
            }
            XCTAssertEqual(msg, "iWork document without a QuickLook preview — open it once in Pages to generate one")
        }
    }

    func testPackageWithoutPreviewThrowsExplicitError() throws {
        let packageURL = file("Vide.pages")
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try IWorkExtractor().extract(url: packageURL, limits: ExtractLimits())) { error in
            guard let f = error as? FouineError, case .extraction(let msg) = f else {
                XCTFail("attendu FouineError.extraction, obtenu: \(error)")
                return
            }
            XCTAssertEqual(msg, "iWork document without a QuickLook preview — open it once in Pages to generate one")
        }
    }
}

final class EMLExtractorTests: XCTestCase {

    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("eml")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func testSimplePlainTextEmail() throws {
        let eml = """
        From: alice@example.com
        To: bob@example.com
        Subject: Test simple
        Date: Fri, 04 Sep 2026 10:00:00 +0200

        Bonjour Bob, ceci est un test de courriel.
        """
        let url = file("simple.eml")
        try Data(eml.utf8).write(to: url)

        let result = try EMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertEqual(result.meta["subject"], "Test simple")
        XCTAssertEqual(result.meta["from"], "alice@example.com")
        XCTAssertEqual(result.meta["to"], "bob@example.com")
        let text = result.pages.first?.text ?? ""
        XCTAssertTrue(text.contains("Subject: Test simple"), text)
        XCTAssertTrue(text.contains("Bonjour Bob, ceci est un test de courriel."), text)
    }

    func testMIMEEncodedWordsInHeaders() throws {
        let eml = """
        From: =?UTF-8?B?QWxpY2UgRHVwb250?= <alice@example.com>
        To: =?ISO-8859-1?Q?Beno=EEt_Martin?= <benoit@example.com>
        Subject: =?UTF-8?B?UmXDp3UgZGUgY29tbWFuZGUg?= =?UTF-8?Q?d'=C3=A9t=C3=A9?=
        Date: Fri, 04 Sep 2026 10:00:00 +0200

        Contenu du message.
        """
        let url = file("mime_headers.eml")
        try Data(eml.utf8).write(to: url)

        let result = try EMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.meta["from"], "Alice Dupont <alice@example.com>")
        XCTAssertEqual(result.meta["to"], "Benoît Martin <benoit@example.com>")
        XCTAssertEqual(result.meta["subject"], "Reçu de commande d'été")
    }

    func testQuotedPrintableBodyWithSoftBreaks() throws {
        let eml = """
        From: alice@example.com
        Subject: Quoted-Printable
        Content-Type: text/plain; charset="utf-8"
        Content-Transfer-Encoding: quoted-printable

        Voici un texte tr=C3=A8s long qui comporte une coupure=
         douce et des accents comme le caf=C3=A9.
        """
        let url = file("qp.eml")
        try Data(eml.utf8).write(to: url)

        let result = try EMLExtractor().extract(url: url, limits: ExtractLimits())
        let text = result.pages.first?.text ?? ""
        XCTAssertTrue(text.contains("Voici un texte très long qui comporte une coupure douce et des accents comme le café."), text)
    }

    func testMultipartAlternativePrefersPlainText() throws {
        let eml = """
        From: alice@example.com
        Subject: Multipart
        Content-Type: multipart/alternative; boundary="bound42"

        --bound42
        Content-Type: text/plain; charset="utf-8"

        Texte brut prioritaire.

        --bound42
        Content-Type: text/html; charset="utf-8"

        <p>Texte HTML alternatif.</p>

        --bound42--
        """
        let url = file("multi_alt.eml")
        try Data(eml.utf8).write(to: url)

        let result = try EMLExtractor().extract(url: url, limits: ExtractLimits())
        let text = result.pages.first?.text ?? ""
        XCTAssertTrue(text.contains("Texte brut prioritaire."), text)
        XCTAssertFalse(text.contains("Texte HTML alternatif."), text)
    }

    func testMultipartHTMLFallbackWhenNoPlainText() throws {
        let eml = """
        From: alice@example.com
        Subject: HTML Only
        Content-Type: multipart/related; boundary="bound99"

        --bound99
        Content-Type: text/html; charset="utf-8"

        <html><body><h1>Titre Important</h1><p>Paragraphe &amp; information.</p></body></html>

        --bound99--
        """
        let url = file("html_only.eml")
        try Data(eml.utf8).write(to: url)

        let result = try EMLExtractor().extract(url: url, limits: ExtractLimits())
        let text = result.pages.first?.text ?? ""
        XCTAssertTrue(text.contains("Titre Important"), text)
        XCTAssertTrue(text.contains("Paragraphe & information."), text)
        XCTAssertFalse(text.contains("<html>"), text)
    }

    func testBase64Body() throws {
        let rawBody = "Corps en base64 avec caractères accentués éèà."
        let base64 = Data(rawBody.utf8).base64EncodedString()
        let eml = """
        From: alice@example.com
        Subject: Base64
        Content-Type: text/plain; charset="utf-8"
        Content-Transfer-Encoding: base64

        \(base64)
        """
        let url = file("base64.eml")
        try Data(eml.utf8).write(to: url)

        let result = try EMLExtractor().extract(url: url, limits: ExtractLimits())
        let text = result.pages.first?.text ?? ""
        XCTAssertTrue(text.contains(rawBody), text)
    }
}

// MARK: - Tableurs : la valeur affichée autant que la valeur stockée (C2-07)

/// Un `.xlsx` bout en bout, avec ses formats de cellule.
///
/// Le constat C2-07 en une ligne : la cellule qui AFFICHE « 05/01/2026 »
/// contient `46027`, celle qui affiche « 1 512,50 € » contient `1512.5`, et
/// Fouine n'indexait que la seconde forme. Chercher une date ou un montant dans
/// un tableur — c'est-à-dire la seule chose qu'on y cherche — ne marchait pas.
final class SpreadsheetExtractionTests: XCTestCase {

    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("xlsx-format")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testXlsxIndexesBothTheShownAndTheStoredValue() throws {
        let url = directory.appendingPathComponent("echeancier.xlsx")
        let styles = Fixtures.xml("""
        <styleSheet xmlns="s">
          <numFmts count="1">
            <numFmt numFmtId="164" formatCode="#,##0.00\\ &quot;€&quot;"/>
          </numFmts>
          <cellXfs count="3">
            <xf numFmtId="0"/><xf numFmtId="14" applyNumberFormat="1"/>
            <xf numFmtId="164" applyNumberFormat="1"/>
          </cellXfs>
        </styleSheet>
        """)
        let sheet = Fixtures.xml("""
        <worksheet xmlns="s"><sheetData>
        <row r="1"><c r="A1" s="1"><v>46027</v></c><c r="B1" s="2"><v>1512.5</v></c><c r="C1"><v>775</v></c></row>
        <row r="2"><c r="A2" s="1"><v>46086</v></c><c r="B2" s="2"><v>775</v></c></row>
        </sheetData></worksheet>
        """)
        try Fixtures.makeArchive([
            ("xl/workbook.xml",
             Fixtures.xml("<workbook xmlns=\"s\"><workbookPr/></workbook>")),
            ("xl/styles.xml", styles),
            ("xl/worksheets/sheet1.xml", sheet),
        ], at: url)

        let result = try OOXMLExtractor().extract(url: url, limits: ExtractLimits())
        let rows = (result.pages.first?.text ?? "").components(separatedBy: "\n")
        XCTAssertEqual(rows.first, "05/01/2026 46027\t1 512,50 1512.5\t775",
                       "les deux formes, et la cellule SANS format inchangée")
        XCTAssertEqual(rows.count > 1 ? rows[1] : "", "05/03/2026 46086\t775,00 775")
    }

    /// Un classeur sans `xl/styles.xml` — un export d'outil minimal — se
    /// comporte exactement comme avant le correctif.
    func testXlsxWithoutStylesIsUnchanged() throws {
        let url = directory.appendingPathComponent("brut.xlsx")
        try Fixtures.makeArchive([
            ("xl/worksheets/sheet1.xml", Fixtures.xml("""
            <worksheet xmlns="s"><sheetData>
            <row r="1"><c r="A1"><v>46027</v></c></row>
            </sheetData></worksheet>
            """)),
        ], at: url)

        let result = try OOXMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pages.first?.text, "46027")
    }
}


