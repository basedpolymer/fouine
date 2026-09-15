// TextTests.swift — pagination, budget, plausibilité, HTML (SPEC §5.3, §7.2 n°3).
// Propriété : A-Ingest.

import XCTest
import FouineCore
@testable import FouineExtract

final class TextPaginationTests: XCTestCase {

    func testCutsOnParagraphBoundary() {
        let paragraph = String(repeating: "a", count: 1_000)
        let text = Array(repeating: paragraph, count: 10).joined(separator: "\n\n")
        let pages = TextPagination.paginate(text, limit: 4_000)

        XCTAssertGreaterThan(pages.count, 1)
        for page in pages {
            XCTAssertLessThanOrEqual(page.count, 4_000)
        }
        // Chaque page sauf la dernière se termine sur la frontière de paragraphe.
        for page in pages.dropLast() {
            XCTAssertTrue(page.hasSuffix("\n\n"), String(page.suffix(8)))
        }
        XCTAssertEqual(pages.joined(), text)   // découpage sans perte
    }

    func testFallsBackToLineThenHardCut() {
        let lines = Array(repeating: String(repeating: "b", count: 100),
                          count: 100).joined(separator: "\n")
        let onLines = TextPagination.paginate(lines, limit: 4_000)
        for page in onLines.dropLast() { XCTAssertTrue(page.hasSuffix("\n")) }
        XCTAssertEqual(onLines.joined(), lines)

        let solid = String(repeating: "c", count: 9_000)
        let hard = TextPagination.paginate(solid, limit: 4_000)
        XCTAssertEqual(hard.map(\.count), [4_000, 4_000, 1_000])
        XCTAssertEqual(hard.joined(), solid)
    }

    /// C2-06, LE CAS RÉEL. *Guerre et Paix* du Projet Gutenberg est un fichier
    /// CRLF : `\r\n` est UN `Character` en Swift, et la recherche de « \n\n »
    /// n'en voyait aucun — 806 coupes en plein milieu d'un mot (« Na |
    /// tásha »), 806 mots disparus de l'index.
    func testCRLFTextIsCutOnALineBoundaryNotInsideAWord() {
        let line = String(repeating: "mot ", count: 750)   // 3 000 caractères
        let text = Array(repeating: line, count: 3).joined(separator: "\r\n")
        let pages = TextPagination.paginate(text, limit: 4_000)

        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.joined(), text, "découpage sans perte")
        for page in pages.dropFirst() {
            XCTAssertTrue(page.hasPrefix("mot") || page.hasPrefix("\r\n"),
                          "une page commence au milieu d'un mot : "
                          + String(page.prefix(12)))
        }
        for page in pages.dropLast() {
            XCTAssertTrue(page.hasSuffix("\r\n") || page.hasSuffix(" "),
                          String(page.suffix(8)))
        }
    }

    /// Ni paragraphe ni ligne : on coupe au dernier BLANC du tronçon, jamais au
    /// milieu d'un mot.
    func testWithoutAnyNewlineTheCutFallsOnAWordBoundary() {
        let text = String(repeating: "azote ", count: 2_000)   // 12 000 car.
        let pages = TextPagination.paginate(text, limit: 4_000)

        XCTAssertEqual(pages.joined(), text)
        for page in pages.dropLast() {
            XCTAssertTrue(page.hasSuffix(" "), String(page.suffix(8)))
            XCTAssertLessThanOrEqual(page.count, 4_000)
        }
        for page in pages.dropFirst() {
            XCTAssertTrue(page.hasPrefix("azote"), String(page.prefix(10)))
        }
    }

    /// Le découpage doit être DÉTERMINISTE : OOXMLMedia.mediaMap en dépend pour
    /// renumérote les médias comme l'extraction (§5.3).
    func testIsDeterministic() {
        let text = (0..<50).map { "paragraphe \($0) " + String(repeating: "x", count: 300) }
            .joined(separator: "\n\n")
        let first = TextPagination.paginate(text, limit: 4_000)
        let second = TextPagination.paginate(text, limit: 4_000)
        XCTAssertEqual(first, second)
    }

    func testEmptyAndShortTexts() {
        XCTAssertEqual(TextPagination.paginate("", limit: 4_000), [])
        XCTAssertEqual(TextPagination.paginate("court", limit: 4_000), ["court"])
    }

    func testBudgetTruncatesOnCharacterBoundary() {
        var budget = TextBudget(maxBytes: 5)
        // « é » vaut 2 octets : la troncature ne coupe jamais un scalaire en deux.
        let kept = budget.take("ééé")
        XCTAssertEqual(kept, "éé")
        XCTAssertEqual(budget.remaining, 1)
        XCTAssertEqual(budget.take("é"), "")
    }

    /// A11.9 : une troncature épuise le budget. Sinon un reliquat trop petit pour
    /// le caractère suivant laissait `isExhausted` faux à jamais et les `break`
    /// des extracteurs paginés ne se déclenchaient plus.
    func testBudgetIsExhaustedAsSoonAsItTruncates() {
        var budget = TextBudget(maxBytes: 3)
        XCTAssertEqual(budget.take("éé"), "é")
        XCTAssertEqual(budget.remaining, 1)
        XCTAssertTrue(budget.isExhausted)
        XCTAssertEqual(budget.take("🙂"), "")
        XCTAssertTrue(budget.isExhausted)
    }

    func testBudgetThatNeverTruncatesStaysOpen() {
        var budget = TextBudget(maxBytes: 10)
        XCTAssertEqual(budget.take("abc"), "abc")
        XCTAssertFalse(budget.isExhausted)
        XCTAssertEqual(budget.take("def"), "def")
        XCTAssertFalse(budget.isExhausted)
    }
}

final class PlausibilityTests: XCTestCase {

    /// L'étalon du §7.2 n°3 : ce que NSAttributedString rend sur un .ppt binaire.
    func testMojibakeIsRejected() {
        let mojibake = "–œ‡°±· ˛ˇ ˛ˇˇˇ ^ _ a"
        XCTAssertGreaterThan(Plausibility.suspiciousRatio(mojibake),
                             Plausibility.maxSuspiciousRatio)
        XCTAssertThrowsError(try Plausibility.check(mojibake, ext: "ppt"))
    }

    func testRealFrenchTextPasses() {
        let text = """
        L'enthalpie libre G = H − TS gouverne l'équilibre chimique à 25 °C.
        La chromatographie sur papier sépare les colorants ; voir § 3.2, p. 47.
        Rendement : 92 % (± 3), coût 12 € — « très correct », d'après Arnaud.
        """
        XCTAssertLessThan(Plausibility.suspiciousRatio(text),
                          Plausibility.maxSuspiciousRatio)
        XCTAssertNoThrow(try Plausibility.check(text, ext: "rtf"))
    }

    func testCJKAndReplacementCharactersAreSuspiciousInALatinCorpus() {
        XCTAssertGreaterThan(Plausibility.suspiciousRatio("\u{FFFD}\u{FFFD}\u{FFFD}ab"),
                             Plausibility.maxSuspiciousRatio)
    }

    func testEmptyTextIsNotRejected() {
        XCTAssertEqual(Plausibility.suspiciousRatio(""), 0)
        XCTAssertNoThrow(try Plausibility.check("", ext: "doc"))
    }
}

final class HTMLTextTests: XCTestCase {

    func testStripsScriptAndStyleAndDecodesEntities() {
        let html = """
        <!DOCTYPE html><html><head><title>Ma page</title>
        <style>body { color: red; }</style>
        <script>var x = 1 < 2 && 3 > 2;</script>
        </head><body><!-- commentaire -->
        <h1>Chimie &amp; Physique</h1>
        <p>L'enthalpie &eacute;quilibre &#233; &#xE9; &nbsp;fin.</p>
        </body></html>
        """
        let text = HTMLText.plainText(from: html)
        XCTAssertTrue(text.contains("Chimie & Physique"), text)
        XCTAssertTrue(text.contains("L'enthalpie équilibre é é"), text)
        XCTAssertFalse(text.contains("color: red"), text)
        XCTAssertFalse(text.contains("var x"), text)
        XCTAssertFalse(text.contains("commentaire"), text)
        // Les balises, la déclaration DOCTYPE et l'instruction de traitement
        // disparaissent — mais SURTOUT PAS un « < » de texte (voir ci-dessous) :
        // l'ancienne assertion « aucun < dans la sortie » masquait A11.1.
        XCTAssertFalse(text.contains("DOCTYPE"), text)
        XCTAssertFalse(text.contains("<h1"), text)
        XCTAssertFalse(text.contains("<p"), text)
    }

    /// A11.11 — `&#0;` posait un NUL dans page_fts : exactement l'octet sur
    /// lequel `PlainTextExtractor.decode` refuse un binaire renommé (A11.4).
    func testNumericEntitiesNeverProduceControlCharacters() {
        let text = HTMLText.plainText(
            from: "<p>avant&#0;apr&egrave;s&#x1;&#8;fin</p>")
        XCTAssertFalse(text.unicodeScalars.contains { $0.value == 0 }, text)
        XCTAssertFalse(text.unicodeScalars.contains { $0.value == 1 }, text)
        XCTAssertFalse(text.unicodeScalars.contains { $0.value == 8 }, text)
        XCTAssertTrue(text.contains("avant\u{FFFD}après"), text)
        XCTAssertTrue(text.contains("fin"), text)

        // Le blanc légitime, lui, reste du blanc : `&#10;` n'est pas une
        // commande à remplacer, et `normalizeWhitespace` doit pouvoir le voir.
        XCTAssertEqual(HTMLText.decodeEntities("a&#9;b&#10;c"), "a\tb\nc")
    }

    func testAttributesWithAngleBracketsDoNotLeak() {
        let html = "<p title=\"a > b\">visible</p>"
        XCTAssertEqual(HTMLText.plainText(from: html).trimmingCharacters(
            in: .whitespacesAndNewlines), "visible")
    }

    /// A11.1 : un « < » qui n'ouvre pas de balise est du TEXTE. Il avalait tout
    /// jusqu'au « > » suivant — ou jusqu'à la fin du document s'il n'y en avait
    /// plus. Perte silencieuse et non bornée sur un corpus scientifique.
    func testUnescapedLessThanKeepsTheTextThatFollows() {
        let text = HTMLText.plainText(from: "<p>si a < b alors c</p><p>SUITE</p>")
        XCTAssertTrue(text.contains("si a < b alors c"), text)
        XCTAssertTrue(text.contains("SUITE"), text)
    }

    func testUnescapedLessThanWithoutAnyLaterTagKeepsTheTail() {
        let text = HTMLText.plainText(
            from: "<body>Pour tout x, x < 10 et y > 3. Fin.</body>")
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines),
                       "Pour tout x, x < 10 et y > 3. Fin.")
    }

    /// Cas limite : « < » en toute fin de document, sans rien derrière.
    func testTrailingLessThanIsKept() {
        XCTAssertEqual(HTMLText.plainText(from: "<p>seuil <").trimmingCharacters(
            in: .whitespacesAndNewlines), "seuil <")
    }

    /// Le contenu d'une section CDATA est du texte (XHTML d'epub).
    func testCDATAContentIsKept() {
        let text = HTMLText.plainText(from: "<p><![CDATA[texte protégé]]></p>")
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines),
                       "texte protégé")
    }

    /// L'entête XML des XHTML d'epub (EPUBExtractor:32) reste dépouillé.
    func testXMLDeclarationIsStripped() {
        let text = HTMLText.plainText(from: """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml">
        <body><p>ΔG < 0 donc la réaction est spontanée.</p></body></html>
        """)
        XCTAssertFalse(text.contains("xml version"), text)
        XCTAssertFalse(text.contains("DOCTYPE"), text)
        XCTAssertTrue(text.contains("ΔG < 0 donc la réaction est spontanée."), text)
    }
}

/// MO-01 : le plafond de pages des formats re-paginés. Un `.docx` de 80 Kio
/// dont le corps est 80 Mio de « A » produisait 13 108 pages et ~26 000
/// vecteurs identiques.
final class PageCapTests: XCTestCase {

    private func result(pages: Int) -> ExtractionResult {
        ExtractionResult(
            pages: (1...pages).map { PageText(page: $0, text: "page \($0)",
                                              source: .native) },
            pageCount: pages, ocrCandidates: [1, pages], meta: ["title": "essai"])
    }

    func testSixThousandPagesAreCutToFiveThousandWithANote() {
        let capped = PageCap.apply(result(pages: 6_000), limit: 5_000)
        XCTAssertEqual(capped.pageCount, 5_000)
        XCTAssertEqual(capped.pages.count, 5_000)
        XCTAssertEqual(capped.pages.last?.page, 5_000)
        XCTAssertEqual(capped.meta["truncated"],
                       "pages beyond 5000 dropped (6000 pages)")
        XCTAssertEqual(capped.meta["title"], "essai", "le reste des méta reste")
        XCTAssertEqual(capped.ocrCandidates, [1], "la page 6 000 ne part pas en OCR")
    }

    func testATenPageDocumentIsUntouched() {
        let capped = PageCap.apply(result(pages: 10), limit: 5_000)
        XCTAssertEqual(capped.pageCount, 10)
        XCTAssertEqual(capped.pages.count, 10)
        XCTAssertNil(capped.meta["truncated"])
    }

    /// Le plafond doit être posé sur le chemin RÉELLEMENT emprunté par
    /// l'indexation : `registry.extractor(for:)`, et non le seul raccourci
    /// `registry.extract(url:)` — `IndexPass` n'appelle que le premier.
    func testTheRegistryCapsARepaginatedFormatOnBothPaths() throws {
        let directory = try Fixtures.temporaryDirectory("cap")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("gros.txt")
        // 12 « pages » de 100 caractères, plafonnées à 5.
        try Data(String(repeating: "a", count: 1_200).utf8).write(to: url)

        var limits = ExtractLimits()
        limits.pageSplitChars = 100
        limits.maxSplitPages = 5

        let registry = DefaultExtractorRegistry()
        let direct = try registry.extract(url: url, limits: limits)
        XCTAssertEqual(direct.pageCount, 5)
        XCTAssertEqual(direct.meta["truncated"],
                       "pages beyond 5 dropped (12 pages)")

        let viaExtractor = try XCTUnwrap(registry.extractor(for: "txt"))
            .extract(url: url, limits: limits)
        XCTAssertEqual(viaExtractor.pageCount, 5)
        XCTAssertEqual(viaExtractor.pages.count, 5)
    }

    /// Le PDF, le DjVu, le CBZ, les images et les médias ont déjà leur plafond
    /// (`Schema.maxPage`) : ils ne passent pas par celui-ci.
    func testNativelyPaginatedFormatsAreNotInTheCappedSet() {
        for ext in ["pdf", "djvu", "cbz", "cbr", "pages", "ai", "sketch"] {
            XCTAssertFalse(
                DefaultExtractorRegistry.repaginatedExtensions.contains(ext), ext)
        }
        for ext in ["txt", "docx", "epub", "html", "rtf", "xls", "eml", "mbox"] {
            XCTAssertTrue(
                DefaultExtractorRegistry.repaginatedExtensions.contains(ext), ext)
        }
    }
}

/// A7 / A11.3 : règle UNIQUE de classement d'un refus, appelée par les trois
/// pipelines (CLI, agent, app).
final class ExtractOutcomeTests: XCTestCase {

    func testDjvuKeepsItsActionableReason() {
        XCTAssertEqual(ExtractOutcome.skipReason(ext: "djvu"),
                       "djvu: djvulibre is missing (missing-tool:djvused)")
        XCTAssertEqual(ExtractOutcome.skipReason(ext: "DJVU"),
                       "djvu: djvulibre is missing (missing-tool:djvused)")
        // `.xls` n'est plus un refus d'office (INT-F1) : il n'a donc plus de
        // motif à lui, et le libellé « unsupported binary OLE format » a disparu
        // du produit. Ses refus PROPRES (classeur chiffré, conteneur sans flux)
        // passent désormais par `skipReason(for:)`.
        XCTAssertEqual(ExtractOutcome.skipReason(ext: "xls"), "unsupported format")
        XCTAssertEqual(ExtractOutcome.skipReason(ext: "mp4"), "unsupported format")
        XCTAssertEqual(
            ExtractOutcome.skipReason(
                for: .extraction(LegacyExcelExtractor.passwordReason)),
            LegacyExcelExtractor.passwordReason)
    }

    func testFileTooLargeIsSkippedNotFailed() {
        XCTAssertEqual(ExtractOutcome.skipReason(for: .fileTooLarge(bytes: 4_096)),
                       "file too large (4096 B)")
        XCTAssertEqual(ExtractOutcome.skipReason(for: .unsupported(ext: "djvu")),
                       "djvu: djvulibre is missing (missing-tool:djvused)")
        // Tout le reste reste un échec.
        XCTAssertNil(ExtractOutcome.skipReason(for: .extraction("PDF illisible")))
        XCTAssertNil(ExtractOutcome.skipReason(for: .databaseFailure("disque plein")))
    }
}

final class EntrySortTests: XCTestCase {

    /// L'ordre des entrées EST la numérotation des pages d'une BD (§5.3).
    func testNaturalOrder() {
        let entries = ["img10.png", "img2.png", "img1.png", "img20.png", "img3.png"]
        XCTAssertEqual(EntrySort.sortedNaturally(entries),
                       ["img1.png", "img2.png", "img3.png", "img10.png", "img20.png"])
    }

    func testNaturalOrderWithPadding() {
        XCTAssertEqual(EntrySort.sortedNaturally(["p-010.jpg", "p-9.jpg", "p-100.jpg"]),
                       ["p-9.jpg", "p-010.jpg", "p-100.jpg"])
    }

    /// A11.11 — le départage final portait sur la longueur TOTALE des deux noms
    /// alors que les curseurs ont divergé : une suite de chiffres égale en
    /// valeur peut être plus longue d'un côté (« 007 » contre « 7 »).
    func testTieBreakUsesTheRemainderNotTheWholeLength() {
        // « page007 » est épuisé, « page7x » a encore une lettre : le préfixe
        // vient en premier. L'ancien code comparait 7 à 6 et l'inversait.
        XCTAssertTrue(EntrySort.naturalLess("page007", "page7x"))
        XCTAssertFalse(EntrySort.naturalLess("page7x", "page007"))
        XCTAssertEqual(EntrySort.sortedNaturally(["page7x", "page007"]),
                       ["page007", "page7x"])
        // Et l'ordre reste STRICT et total : aucun couple ne se dit inférieur
        // dans les deux sens, sans quoi `sorted(by:)` est indéfini.
        let noms = ["p007a", "p7ab", "p7", "p007", "p0007b", "p7b", "img10", "img2"]
        for a in noms {
            XCTAssertFalse(EntrySort.naturalLess(a, a), a)
            for b in noms where a != b {
                XCTAssertNotEqual(EntrySort.naturalLess(a, b),
                                  EntrySort.naturalLess(b, a), "\(a) / \(b)")
            }
        }
    }

    /// Le média webp manquait aux OOXML alors que les BD l'acceptaient déjà, et
    /// qu'ImageIO — donc `GrayRaster` — sait le décoder (A11.11).
    func testOOXMLImageExtensionsAcceptWebPButNotVectorFormats() {
        XCTAssertTrue(EntrySort.ooxmlImageExtensions.contains("webp"))
        for vectoriel in ["emf", "wmf", "svg"] {
            XCTAssertFalse(EntrySort.ooxmlImageExtensions.contains(vectoriel),
                           vectoriel)
        }
        let entries = ["word/media/image1.webp", "word/media/image2.emf",
                       "word/media/image3.svg", "word/media/image4.png"]
        XCTAssertEqual(
            EntrySort.imageEntries(entries, allowed: EntrySort.ooxmlImageExtensions),
            ["word/media/image1.webp", "word/media/image4.png"])
    }

    func testFiltersDirectoriesAndAppleDoubles() {
        let entries = ["dossier/", "__MACOSX/._img1.png", "._img1.png",
                       ".DS_Store", "img1.png", "notes.txt", "img2.JPG"]
        XCTAssertEqual(
            EntrySort.imageEntries(entries, allowed: EntrySort.comicImageExtensions),
            ["img1.png", "img2.JPG"])
    }
}
