// LegacyOfficeTests.swift — conteneur OLE, xls (BIFF) et ppt
// (lot INT-F1, SPEC §5.3 amendé le 08/09/2026). Propriété : A-Ingest.

import XCTest
import FouineCore
@testable import FouineExtract

final class CompoundFileTests: XCTestCase {

    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("ole")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Les DEUX chemins du lecteur : le mini-flux (moins de 4 096 octets) et la
    /// FAT ordinaire. Ce sont deux codes différents, et un `.ppt` réel emprunte
    /// les deux dans le même fichier.
    func testReadsBothMiniAndRegularStreams() throws {
        let small = Data("Colorimétrie".utf8)
        let big = Data(repeating: 0x41, count: 5_000)
        let bytes = OLEWriter.compoundFile(streams: [("Petit", small),
                                                     ("Grand", big)])
        let container = try CompoundFile(data: bytes, label: "essai")
        XCTAssertEqual(try container.stream(named: "Petit"), small)
        XCTAssertEqual(try container.stream(named: "Grand"), big)
        // Les producteurs n'ont jamais été d'accord sur la casse des noms.
        XCTAssertEqual(try container.stream(named: "petit"), small)
        XCTAssertNil(try container.stream(named: "Absent"))
    }

    func testRefusesAFileWithoutTheOLESignature() {
        XCTAssertThrowsError(try CompoundFile(data: Data(repeating: 0, count: 1_024),
                                              label: "faux")) {
            guard case FouineError.extraction(let message) = $0 else {
                return XCTFail("attendu extraction, obtenu \($0)")
            }
            XCTAssertTrue(message.contains("no OLE signature"), message)
        }
    }

    /// MO-06 : un fichier de 208 octets qui PORTE la signature OLE est tronqué,
    /// pas dépourvu de signature. Le motif finit dans `docs.err` et il mentait
    /// sur la cause ; il doit aussi porter « OLE container without », que la
    /// carte « documents illisibles » range en « fichier endommagé ».
    func testATruncatedOLEFileIsNamedTruncatedNotUnsigned() {
        var bytes = Data(CompoundFile.signature)
        bytes.append(Data(repeating: 0, count: 200))          // 208 octets
        XCTAssertThrowsError(try CompoundFile(data: bytes, label: "trunc.xls")) {
            guard case FouineError.extraction(let message) = $0 else {
                return XCTFail("attendu extraction, obtenu \($0)")
            }
            XCTAssertTrue(message.contains("OLE container without"), message)
            XCTAssertTrue(message.contains("truncated: 208 bytes"), message)
            XCTAssertFalse(message.contains("no OLE signature"),
                           "la signature EST là : \(message)")
        }
    }

    /// Une chaîne de secteurs qui BOUCLE doit s'arrêter sur un refus nommé, pas
    /// faire tourner l'indexation jusqu'à la fin des temps.
    func testALoopingSectorChainIsRefusedNotFollowed() throws {
        var bytes = OLEWriter.compoundFile(streams: [
            ("Grand", Data(repeating: 0x42, count: 5_000)),
        ])
        // Le secteur 0 porte la FAT : on fait pointer chaque entrée du flux sur
        // elle-même. La lecture doit lever, et vite.
        for slot in 0..<(512 / 4) {
            let offset = 512 + slot * 4
            let value = OLEWriter.u32(UInt32(slot))
            bytes.replaceSubrange(offset..<(offset + 4), with: value)
        }
        let started = Date()
        XCTAssertThrowsError(try CompoundFile(data: bytes, label: "boucle")) {
            guard case FouineError.extraction(let message) = $0 else {
                return XCTFail("attendu extraction, obtenu \($0)")
            }
            XCTAssertTrue(message.contains("looping"), message)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}

final class LegacyExcelTests: XCTestCase {

    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("xls")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func write(_ workbook: Data, to name: String) throws -> URL {
        let url = file(name)
        try OLEWriter.compoundFile(streams: [("Workbook", workbook)]).write(to: url)
        return url
    }

    /// UNE PAGE PAR FEUILLE, cellules en ordre ligne puis colonne — et les deux
    /// formes de chaîne partagée, compressée et UTF-16.
    func testOneSheetIsOnePageWithBothStringForms() throws {
        let workbook = BIFFBuilder.workbook([
            BIFFBuilder.Sheet(name: "Mesures", cells: [
                (0, 0, .text("Ébulliométrie", wide: false)),
                (0, 1, .number(12.5)),
                (1, 0, .integer(42)),
            ]),
            BIFFBuilder.Sheet(name: "Calculs", cells: [
                (0, 0, .text("Granulométrie μm", wide: true)),
            ]),
        ])
        let url = try write(workbook, to: "feuille.xls")

        let result = try DefaultExtractorRegistry().extract(url: url)
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(result.pages.count, 2)
        XCTAssertTrue(result.pages[0].text.contains("Ébulliométrie"),
                      result.pages[0].text)
        // Nombre rendu court : « 12.5 », pas « 12.500000 ».
        XCTAssertTrue(result.pages[0].text.contains("12.5"), result.pages[0].text)
        XCTAssertTrue(result.pages[0].text.contains("42"), result.pages[0].text)
        // Ligne puis colonne : la tabulation sépare les cellules d'une ligne.
        XCTAssertTrue(result.pages[0].text.contains("Ébulliométrie\t12.5"),
                      result.pages[0].text)
        XCTAssertTrue(result.pages[1].text.contains("Granulométrie μm"),
                      result.pages[1].text)
        XCTAssertFalse(result.pages[1].text.contains("Ébulliométrie"))
    }

    /// Un classeur CHIFFRÉ n'est pas un classeur cassé : refus nommé, classé
    /// `.skipped`.
    func testEncryptedWorkbookIsSkippedByName() throws {
        let url = try write(BIFFBuilder.encryptedWorkbook(), to: "protege.xls")
        XCTAssertThrowsError(try DefaultExtractorRegistry().extract(url: url)) {
            guard case FouineError.extraction(let message) = $0 else {
                return XCTFail("attendu extraction, obtenu \($0)")
            }
            XCTAssertEqual(message, LegacyExcelExtractor.passwordReason)
            XCTAssertEqual(ExtractOutcome.skipReason(for: .extraction(message)),
                           LegacyExcelExtractor.passwordReason)
        }
    }

    /// Un conteneur OLE sans flux de classeur — un `.doc` renommé `.xls`, par
    /// exemple — est refusé en le DISANT.
    func testOLEContainerWithoutAWorkbookStreamIsSkippedByName() throws {
        let url = file("faux.xls")
        try OLEWriter.compoundFile(streams: [("WordDocument", Data("x".utf8))])
            .write(to: url)
        XCTAssertThrowsError(try DefaultExtractorRegistry().extract(url: url)) {
            guard case FouineError.extraction(let message) = $0 else {
                return XCTFail("attendu extraction, obtenu \($0)")
            }
            XCTAssertEqual(message, LegacyExcelExtractor.noWorkbookReason)
            XCTAssertEqual(ExtractOutcome.skipReason(for: .extraction(message)),
                           LegacyExcelExtractor.noWorkbookReason)
        }
    }

    /// LE piège du format : une chaîne partagée coupée par un `CONTINUE`, dont
    /// la suite REDÉCLARE si elle est compressée. Un lecteur qui l'ignore rend
    /// du mojibake — c'est-à-dire exactement ce que le §7.2 n°3 interdit.
    func testSharedStringsSurviveAContinueRecord() {
        // Un seul texte, « ABCDEF », coupé après trois caractères : le premier
        // bloc est en UTF-16, la continuation passe en compressé.
        var first = OLEWriter.u32(1)
        first.append(OLEWriter.u32(1))
        first.append(OLEWriter.u16(6))                 // six caractères
        first.append(UInt8(0x01))                      // UTF-16
        for unit in Array("ABC".utf16) { first.append(OLEWriter.u16(unit)) }

        var second = Data([0x00])                      // la suite est compressée
        for unit in Array("DEF".utf16) { second.append(UInt8(unit & 0xFF)) }

        XCTAssertEqual(SSTReader.strings(in: [first, second]), ["ABCDEF"])
    }

    /// Les `RK` : entier signé sur 30 bits, flottant tronqué, et la division
    /// par cent que le drapeau de poids faible commande.
    func testRKValuesDecodeBothForms() {
        XCTAssertEqual(BIFFWorkbook.rkValue(UInt32(bitPattern: (42 << 2) | 0x02)), 42)
        XCTAssertEqual(BIFFWorkbook.rkValue(UInt32(bitPattern: (1_250 << 2) | 0x03)),
                       12.5)
        XCTAssertEqual(BIFFWorkbook.format(12.5), "12.5")
        XCTAssertEqual(BIFFWorkbook.format(42), "42")
    }
}

final class LegacyPowerPointTests: XCTestCase {

    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("ppt")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func write(_ document: Data, to name: String) throws -> URL {
        let url = file(name)
        try OLEWriter.compoundFile(streams: [("PowerPoint Document", document)])
            .write(to: url)
        return url
    }

    /// UNE PAGE PAR DIAPOSITIVE, dans l'ordre, et les deux formes d'atome de
    /// texte : UTF-16 (`TextCharsAtom`) et un octet par caractère
    /// (`TextBytesAtom`).
    func testOneSlideIsOnePage() throws {
        let document = PPTBuilder.document(slides: [
            [.chars("Thermoluminescence")],
            [.bytes("Anémométrie")],
            [.chars("Tribologie")],
        ])
        let url = try write(document, to: "expose.ppt")

        let result = try DefaultExtractorRegistry().extract(url: url)
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertTrue(result.pages[0].text.contains("Thermoluminescence"))
        XCTAssertTrue(result.pages[1].text.contains("Anémométrie"),
                      result.pages[1].text)
        XCTAssertTrue(result.pages[2].text.contains("Tribologie"))
        XCTAssertFalse(result.pages[0].text.contains("Tribologie"))
    }

    /// Les notes du présentateur rejoignent la page de LEUR diapositive : ce
    /// sont les mêmes idées, dites autrement.
    func testSpeakerNotesJoinTheirSlide() throws {
        let document = PPTBuilder.document(
            slides: [[.chars("Thermoluminescence")], [.chars("Tribologie")]],
            notes: [[.chars("Rappeler la mesure")], []])
        let url = try write(document, to: "notes.ppt")

        let result = try DefaultExtractorRegistry().extract(url: url)
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertTrue(result.pages[0].text.contains("Rappeler la mesure"),
                      result.pages[0].text)
        XCTAssertFalse(result.pages[1].text.contains("Rappeler la mesure"))
    }

    func testEncryptedPresentationIsSkippedByName() throws {
        let url = try write(PPTBuilder.encryptedDocument(), to: "protege.ppt")
        XCTAssertThrowsError(try DefaultExtractorRegistry().extract(url: url)) {
            guard case FouineError.extraction(let message) = $0 else {
                return XCTFail("attendu extraction, obtenu \($0)")
            }
            XCTAssertEqual(message, LegacyPowerPointExtractor.passwordReason)
            XCTAssertEqual(ExtractOutcome.skipReason(for: .extraction(message)),
                           LegacyPowerPointExtractor.passwordReason)
        }
    }

    func testOLEContainerWithoutADocumentStreamIsSkippedByName() throws {
        let url = file("faux.ppt")
        try OLEWriter.compoundFile(streams: [("Workbook", Data("x".utf8))])
            .write(to: url)
        XCTAssertThrowsError(try DefaultExtractorRegistry().extract(url: url)) {
            guard case FouineError.extraction(let message) = $0 else {
                return XCTFail("attendu extraction, obtenu \($0)")
            }
            XCTAssertEqual(message,
                           LegacyPowerPointExtractor.noDocumentStreamReason)
            XCTAssertEqual(ExtractOutcome.skipReason(for: .extraction(message)),
                           LegacyPowerPointExtractor.noDocumentStreamReason)
        }
    }
}
