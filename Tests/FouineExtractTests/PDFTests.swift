// PDFTests.swift — PDFKit, décision D2 (SPEC §5.3, §6.1, §7.2 n°1-2).
// Propriété : A-Ingest.

import XCTest
import PDFKit
import FouineCore
@testable import FouineExtract

final class PDFExtractorTests: XCTestCase {

    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("pdf")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// §6.1 : sous 100 caractères natifs -> file OCR ; au-dessus -> page native,
    /// et JAMAIS en file. « Ne jamais mettre en file une page qui a déjà du
    /// texte natif. »
    func testPagesUnderTheThresholdBecomeOCRCandidates() throws {
        let url = file("mixte.pdf")
        try Fixtures.makePDF(pages: [Fixtures.filler(marker: "PAGEUNE"),
                                     ["ab"],
                                     Fixtures.filler(marker: "PAGETROIS")],
                             at: url)

        let result = try PDFExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertEqual(result.pages.map(\.page), [1, 3])
        XCTAssertEqual(result.ocrCandidates, [2])
        XCTAssertTrue(result.pages[0].text.contains("PAGEUNE"), result.pages[0].text)
        XCTAssertEqual(result.pages[0].source, .native)
        for page in result.pages {
            XCTAssertGreaterThanOrEqual(
                page.text.trimmingCharacters(in: .whitespacesAndNewlines).count, 100)
        }
    }

    func testThresholdIsConfigurable() throws {
        let url = file("court.pdf")
        try Fixtures.makePDF(pages: [["une ligne courte mais présente"]], at: url)
        var limits = ExtractLimits()
        limits.ocrThresholdChars = 5
        let result = try PDFExtractor().extract(url: url, limits: limits)
        XCTAssertEqual(result.pages.count, 1)
        XCTAssertTrue(result.ocrCandidates.isEmpty)
    }

    /// §7.2 n°1 : le PDFDocument est rouvert toutes les 100 pages. Le texte doit
    /// être identique de part et d'autre de la fenêtre — c'est la propriété que
    /// la mesure garantit (« texte identique au caractère près »).
    func testReopeningEveryHundredPagesKeepsTheText() throws {
        XCTAssertEqual(PDFExtractor.reopenEveryPages, 100)
        let url = file("long.pdf")
        let pages = (1...120).map { ["MARQUEUR\($0)"] + Fixtures.filler(marker: "p\($0)") }
        try Fixtures.makePDF(pages: pages, at: url)

        let result = try PDFExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 120)
        XCTAssertEqual(result.pages.count, 120)
        // Pages de part et d'autre de la réouverture (99, 100, 101) et bien après.
        for number in [1, 99, 100, 101, 120] {
            let page = try XCTUnwrap(result.pages.first { $0.page == number })
            XCTAssertTrue(page.text.contains("MARQUEUR\(number)"),
                          "page \(number) : \(page.text.prefix(40))")
        }
    }

    /// A11.5 : une fois `maxTextBytes` atteint, la boucle continuait à payer
    /// `PDFPage.string` sur toutes les pages restantes pour n'en rien tirer.
    /// Elle doit s'arrêter, comme les autres extracteurs paginés.
    func testStopsAsSoonAsTheTextBudgetIsExhausted() throws {
        let url = file("budget.pdf")
        let pages = (1...40).map { ["MARQUEUR\($0)"] + Fixtures.filler(marker: "p\($0)") }
        try Fixtures.makePDF(pages: pages, at: url)

        var limits = ExtractLimits()
        limits.maxTextBytes = 600          // quelques pages, pas 40
        let result = try PDFExtractor().extract(url: url, limits: limits)
        XCTAssertEqual(result.pageCount, 40)          // le total reste celui du PDF
        XCTAssertLessThan(result.pages.count, 10)
        XCTAssertGreaterThan(result.pages.count, 0)
        // Numérotation intacte : les pages retenues sont les premières, dans l'ordre.
        XCTAssertEqual(result.pages.map(\.page), Array(1...result.pages.count))
        XCTAssertLessThanOrEqual(
            result.pages.map(\.text.utf8.count).reduce(0, +), 600)
    }

    /// ST1 : « Stop » se voit ENTRE DEUX PAGES. Un document de vingt pages dont
    /// l'arrêt est demandé dès la deuxième doit lever le cas NOMMÉ et n'avoir
    /// lu que ce qu'il avait commencé — pas les dix-huit qui restaient.
    func testStopBetweenTwoPagesRaisesTheNamedCase() throws {
        let url = file("arret.pdf")
        let pages = (1...20).map { ["MARQUEUR\($0)"] + Fixtures.filler(marker: "p\($0)") }
        try Fixtures.makePDF(pages: pages, at: url)

        // La question est posée une fois par page, en tête de boucle : vraie au
        // DEUXIÈME appel, elle laisse lire la page 1 et rien de plus.
        let asked = CallCounter()
        var limits = ExtractLimits()
        limits.shouldStop = { asked.bump() >= 2 }

        XCTAssertThrowsError(try PDFExtractor().extract(url: url, limits: limits)) {
            guard case FouineError.cancelled = $0 else {
                return XCTFail("attendu cancelled, obtenu \($0)")
            }
        }
        XCTAssertEqual(asked.value, 2, "la boucle a continué après l'arrêt")
    }

    /// §7.2 n°2 : PDFDocument(url:) == nil est un échec SILENCIEUX. Il doit
    /// devenir une erreur explicite, jamais un document qui disparaît sans trace.
    func testCorruptPDFRaisesExtractionError() throws {
        let url = file("corrompu.pdf")
        try Data("ceci n'est pas un PDF".utf8).write(to: url)
        XCTAssertNil(PDFDocument(url: url))
        XCTAssertThrowsError(try PDFExtractor().extract(url: url,
                                                        limits: ExtractLimits())) {
            guard case let FouineError.extraction(message) = $0 else {
                return XCTFail("attendu extraction, obtenu \($0)")
            }
            XCTAssertTrue(message.contains("unreadable PDF"), message)
        }
    }

    /// Un PDF protégé par mot de passe (document.isLocked == true) doit échouer
    /// immédiatement en extraction au lieu d'enfiler toutes ses pages vides à l'OCR.
    func testLockedPDFRaisesExtractionError() throws {
        let url = file("verrouille.pdf")
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            return XCTFail("CGDataConsumer failed")
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let options: [CFString: Any] = [
            kCGPDFContextUserPassword: "secret" as CFString,
            kCGPDFContextOwnerPassword: "master" as CFString,
        ]
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, options as CFDictionary) else {
            return XCTFail("CGContext failed")
        }
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        try data.write(to: url)

        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(document.isLocked)

        XCTAssertThrowsError(try PDFExtractor().extract(url: url,
                                                        limits: ExtractLimits())) {
            guard case let FouineError.extraction(message) = $0 else {
                return XCTFail("attendu extraction, obtenu \($0)")
            }
            XCTAssertTrue(message.contains("password-protected PDF"), message)
        }
    }

    func testExtractionDoesNotTouchTheSourceFile() throws {
        let url = file("intact.pdf")
        try Fixtures.makePDF(pages: [Fixtures.filler(marker: "X")], at: url)
        var before = stat()
        XCTAssertEqual(stat(url.path, &before), 0)

        _ = try PDFExtractor().extract(url: url, limits: ExtractLimits())

        var after = stat()
        XCTAssertEqual(stat(url.path, &after), 0)
        XCTAssertEqual(before.st_size, after.st_size)
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
    }

    /// T1 du §8.1, réduit à ce qu'un test unitaire peut porter : sur le livre de
    /// référence, « règle de Markovnikov » n'apparaît QUE sur les pages 247 et
    /// 265. Corpus PERSONNEL : il exige `Tests/Fixtures/paths.json` (§9.3) ET
    /// l'opt-in `FOUINE_TEST_DB` des tests de corpus (docs/tests.md), comme la
    /// recette d'intégration — dix secondes d'extraction d'un livre de 600
    /// pages ne tournaient dans chaque `make ci-unit` du mainteneur que parce
    /// que le fichier existe sur sa machine (lot I2).
    func testRealCorpusBookIfPresent() throws {
        guard ProcessInfo.processInfo.environment["FOUINE_TEST_DB"] != nil else {
            throw XCTSkip("corpus personnel : opt-in FOUINE_TEST_DB absent "
                          + "(docs/tests.md, régime 2)")
        }
        guard let path = Fixtures.corpusPath(fixture: "T1") else {
            throw XCTSkip("Tests/Fixtures/paths.json absent : fixture locale")
        }
        let result = try PDFExtractor().extract(url: URL(fileURLWithPath: path),
                                                limits: ExtractLimits())
        XCTAssertGreaterThan(result.pageCount, 600)
        let hits = result.pages
            .filter { $0.text.lowercased().contains("règle de markovnikov") }
            .map(\.page)
        XCTAssertEqual(hits, [247, 265])
        // Livre nativement textuel : la couche texte porte l'essentiel des pages.
        XCTAssertGreaterThan(result.pages.count, result.pageCount * 9 / 10)
    }
}

/// Compteur d'appels, sûr en concurrence : la boucle de pages tourne sur le fil
/// dédié que `Deadline` lui donne, pas sur celui du test.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    /// Incrémente et rend la NOUVELLE valeur.
    func bump() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
