// GuardTests.swift — garde-fous de la couche d'extraction : bornes mémoire
// (A11.2), plausibilité du décodage (A11.4), passage unique sur les archives
// (A11.6), délai de garde des sous-processus (A11.7) et plafond de taille des
// paquets-dossiers (A11.8). Propriété : A-Ingest.
//
// Toutes les fixtures sont fabriquées par le test : aucun fichier du corpus
// personnel n'est nécessaire, et aucune donnée volumineuse n'entre au dépôt.

import XCTest
import FouineCore
@testable import FouineExtract

final class ExtractionGuardTests: XCTestCase {

    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("gardes")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    // MARK: - A11.7 · délai de garde sur les sous-processus

    func testSubprocessKillsAToolThatNeverReturns() throws {
        let started = Date()
        XCTAssertThrowsError(
            try Subprocess.run("/bin/sleep", ["120"], what: "essai", timeout: 1)
        ) { error in
            guard case let FouineError.extraction(message) = error else {
                return XCTFail("attendu extraction, obtenu \(error)")
            }
            XCTAssertTrue(message.contains("did not return within"), message)
        }
        // Sans délai de garde, l'appel ne rendait la main qu'au bout de 120 s.
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    /// SIGTERM ignoré : seul le SIGKILL de la grâce peut mettre fin au processus.
    func testSubprocessKillsATooToughToTerminate() throws {
        let script = file("sourd.sh")
        try Data("#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n".utf8)
            .write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        let started = Date()
        XCTAssertThrowsError(
            try Subprocess.run("/bin/sh", [script.path], what: "essai",
                               timeout: 1, grace: 0.5)
        ) { error in
            guard case let FouineError.extraction(message) = error else {
                return XCTFail("attendu extraction, obtenu \(error)")
            }
            XCTAssertTrue(message.contains("did not return within"), message)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }

    // MARK: - A11.2 · plafond d'octets sur la sortie d'un sous-processus

    func testSubprocessKillsAToolThatFloodsStdout() throws {
        let started = Date()
        XCTAssertThrowsError(
            try Subprocess.run("/bin/cat", ["/dev/zero"], what: "essai",
                               maxOutputBytes: 1 << 20, timeout: 30)
        ) { error in
            guard case let FouineError.extraction(message) = error else {
                return XCTFail("attendu extraction, obtenu \(error)")
            }
            XCTAssertTrue(message.contains("output too large"), message)
        }
        // /dev/zero est infini : sans plafond, la lecture ne finissait jamais.
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }

    /// Le plafond ne doit pas mordre sur une sortie qui l'atteint exactement.
    func testSubprocessKeepsOutputThatFitsExactly() throws {
        let payload = file("charge.bin")
        try Data(repeating: 0x41, count: 4_096).write(to: payload)
        let data = try Subprocess.run("/bin/cat", [payload.path], what: "essai",
                                      maxOutputBytes: 4_096)
        XCTAssertEqual(data.count, 4_096)
    }

    // MARK: - A11.2 · bombe de décompression

    /// Archive dont une entrée pèse `bytes` une fois décompressée, pour quelques
    /// kilo-octets sur disque (des zéros se compressent au millième).
    func makeBomb(bytes: Int) throws -> URL {
        let url = file("bombe.zip")
        try Fixtures.makeArchive([
            ("charge.bin", Data(repeating: 0, count: bytes)),
            ("lisezmoi.txt", Data("innocent".utf8)),
        ], at: url)
        return url
    }

    func testDecompressionBombIsRefusedBeforeBeingRead() throws {
        let url = try makeBomb(bytes: 8 << 20)
        XCTAssertLessThan(try FileGuard.size(of: url), Int64(64 << 10))  // ~8 Ko

        // Le plafond de service vaut 128 Mio ; le test le rabaisse pour ne pas
        // fabriquer 645 Mo de zéros.
        XCTAssertThrowsError(
            try Bsdtar.extract(archive: url, entries: ["charge.bin", "lisezmoi.txt"],
                               maxBytes: 1 << 20)
        ) { error in
            guard case let FouineError.extraction(message) = error else {
                return XCTFail("attendu extraction, obtenu \(error)")
            }
            XCTAssertTrue(message.contains("uncompressed entry too large"),
                          message)
        }
    }

    func testSingleEntryExtractionIsCappedToo() throws {
        let url = try makeBomb(bytes: 8 << 20)
        XCTAssertThrowsError(
            try Bsdtar.extract(archive: url, entry: "charge.bin", maxBytes: 1 << 20)
        ) { error in
            guard case let FouineError.extraction(message) = error else {
                return XCTFail("attendu extraction, obtenu \(error)")
            }
            XCTAssertTrue(message.contains("output too large"), message)
        }
    }

    /// Un .docx dont word/document.xml se décompresse au-delà du plafond doit
    /// échouer avec un motif lisible dans `docs.err`, pas remplir la mémoire.
    func testOversizedDocxEntryFailsWithAnActionableMessage() throws {
        let url = file("bombe.docx")
        let filler = String(repeating: "a", count: 8 << 20)
        try Fixtures.makeArchive([
            ("word/document.xml",
             Fixtures.xml("<w:document xmlns:w=\"x\"><w:body><w:p><w:r><w:t>"
                          + filler + "</w:t></w:r></w:p></w:body></w:document>")),
        ], at: url)

        // Une seule entrée : c'est le plafond du sous-processus qui tranche.
        XCTAssertThrowsError(
            try Bsdtar.extract(archive: url, entry: "word/document.xml",
                               maxBytes: 1 << 20)
        ) { error in
            guard case let FouineError.extraction(message) = error else {
                return XCTFail("attendu extraction, obtenu \(error)")
            }
            XCTAssertTrue(message.contains("too large"), message)
        }
    }

    // MARK: - A11.2 · budget appliqué AU FIL de l'analyse XML

    func testXMLCollectorStopsAccumulatingAtItsLimit() throws {
        let paragraphs = (0..<2_000).map {
            "<w:p><w:r><w:t>paragraphe \($0) chromatographie enthalpie</w:t></w:r></w:p>"
        }.joined()
        let data = Fixtures.xml("<w:document xmlns:w=\"x\"><w:body>"
                                + paragraphs + "</w:body></w:document>")

        let whole = try XMLTextCollector(textElements: ["w:t"],
                                         breakElements: ["w:p"]).parse(data, what: "essai")
        let capped = try XMLTextCollector(textElements: ["w:t"],
                                          breakElements: ["w:p"],
                                          limitBytes: 1_000).parse(data, what: "essai")
        XCTAssertGreaterThan(whole.utf8.count, 60_000)
        // On garde le morceau en cours, donc un léger dépassement, mais on
        // n'accumule pas les 60 Ko : l'analyse s'arrête.
        XCTAssertLessThan(capped.utf8.count, 1_200)
        // Le texte retenu est bien un PRÉFIXE de ce que rendait l'ancien code :
        // `TextBudget.take` tronquait exactement là.
        XCTAssertTrue(whole.hasPrefix(capped), capped)
    }

    func testDocxTextNeverExceedsMaxTextBytes() throws {
        let url = file("long.docx")
        let paragraphs = (0..<2_000).map {
            "<w:p><w:r><w:t>paragraphe \($0) chromatographie enthalpie</w:t></w:r></w:p>"
        }.joined()
        try Fixtures.makeArchive([
            ("word/document.xml",
             Fixtures.xml("<w:document xmlns:w=\"x\"><w:body>"
                          + paragraphs + "</w:body></w:document>")),
        ], at: url)

        var limits = ExtractLimits()
        limits.maxTextBytes = 5_000
        let result = try OOXMLExtractor().extract(url: url, limits: limits)
        let total = result.pages.map(\.text).joined().utf8.count
        XCTAssertLessThanOrEqual(total, limits.maxTextBytes)
        XCTAssertGreaterThan(total, 4_000)

        // Déterminisme : mediaMap doit renumeroter comme l'extraction (§5.3).
        let map = try OOXMLMedia.mediaMap(url: url, limits: limits)
        XCTAssertEqual(map.textPages, result.pageCount)
    }

    // MARK: - A11.4 · un binaire renommé .txt ne doit pas s'indexer

    func testDecodeRefusesBinaryContent() throws {
        // PNG : en-tête à octets NUL, comme tout format binaire courant.
        var png = Fixtures.pngBytes(1)
        png.append(Data(repeating: 0x00, count: 64))
        XCTAssertNil(PlainTextExtractor.decode(png))

        // UTF-16 : un octet sur deux est NUL. Il entrait en mojibake par le
        // repli ISO-8859-1, qui ne peut pas échouer.
        let utf16 = try XCTUnwrap("Chimie organique".data(using: .utf16LittleEndian))
        XCTAssertNil(PlainTextExtractor.decode(utf16))

        // Binaire SANS octet NUL : c'est la proportion de caractères hors plages
        // lisibles qui tranche.
        var noise = Data()
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<4_096 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let byte = UInt8(truncatingIfNeeded: seed >> 33)
            noise.append(byte == 0 ? 0x7F : byte)   // sans NUL : c'est le ratio
        }                                           // de mojibake qui tranche
        XCTAssertNil(PlainTextExtractor.decode(noise))
    }

    func testDecodeStillAcceptsRealText() throws {
        let utf8 = Data("Chromatographie sur couche mince — 25 °C".utf8)
        XCTAssertEqual(PlainTextExtractor.decode(utf8),
                       "Chromatographie sur couche mince — 25 °C")

        let latin1 = try XCTUnwrap(
            "Été 1998 : cinétique du premier ordre, à 25 °C".data(using: .isoLatin1))
        XCTAssertEqual(PlainTextExtractor.decode(latin1),
                       "Été 1998 : cinétique du premier ordre, à 25 °C")

        XCTAssertEqual(PlainTextExtractor.decode(Data()), "")
    }

    /// Prise en charge des BOMs UTF-16 LE/BE et UTF-8 avec BOM (a3-04, lot K3).
    func testDecodeAndExtractWithBOMs() throws {
        let expected = "Synthèse d'un polymère à 25 °C — caractères accentués : été, fête, naïf."
        let limits = ExtractLimits()

        // 1. UTF-8 standard (référence)
        let utf8Data = Data(expected.utf8)
        let urlUTF8 = file("texte_utf8.txt")
        try utf8Data.write(to: urlUTF8)
        let resUTF8 = try PlainTextExtractor().extract(url: urlUTF8, limits: limits)
        XCTAssertEqual(resUTF8.pages.map(\.text).joined(separator: "\n\n"), expected)

        // 2. UTF-8 avec BOM (EF BB BF)
        let utf8BOMData = Data([0xEF, 0xBB, 0xBF]) + utf8Data
        let urlUTF8BOM = file("texte_utf8_bom.txt")
        try utf8BOMData.write(to: urlUTF8BOM)
        let resUTF8BOM = try PlainTextExtractor().extract(url: urlUTF8BOM, limits: limits)
        XCTAssertEqual(resUTF8BOM.pages.map(\.text).joined(separator: "\n\n"), expected)
        XCTAssertEqual(PlainTextExtractor.decode(utf8BOMData), expected)

        // 3. UTF-16 Little Endian avec BOM (FF FE)
        let utf16LEData = Data([0xFF, 0xFE]) + expected.data(using: .utf16LittleEndian)!
        let urlUTF16LE = file("texte_utf16_le.txt")
        try utf16LEData.write(to: urlUTF16LE)
        let resUTF16LE = try PlainTextExtractor().extract(url: urlUTF16LE, limits: limits)
        XCTAssertEqual(resUTF16LE.pages.map(\.text).joined(separator: "\n\n"), expected)
        XCTAssertEqual(PlainTextExtractor.decode(utf16LEData), expected)

        // 4. UTF-16 Big Endian avec BOM (FE FF)
        let utf16BEData = Data([0xFE, 0xFF]) + expected.data(using: .utf16BigEndian)!
        let urlUTF16BE = file("texte_utf16_be.txt")
        try utf16BEData.write(to: urlUTF16BE)
        let resUTF16BE = try PlainTextExtractor().extract(url: urlUTF16BE, limits: limits)
        XCTAssertEqual(resUTF16BE.pages.map(\.text).joined(separator: "\n\n"), expected)
        XCTAssertEqual(PlainTextExtractor.decode(utf16BEData), expected)

        // 5. Un vrai binaire reste rejeté
        var realBinary = Fixtures.pngBytes(1)
        realBinary.append(Data(repeating: 0x00, count: 128))
        XCTAssertTrue(Plausibility.looksBinary(realBinary))
        XCTAssertNil(PlainTextExtractor.decode(realBinary))
    }

    func testBinaryRenamedAsTextFailsWithAnActionableMessage() throws {
        let url = file("piege.txt")
        var payload = Fixtures.pngBytes(1)
        payload.append(Data(repeating: 0x00, count: 4_096))
        try payload.write(to: url)

        XCTAssertThrowsError(
            try PlainTextExtractor().extract(url: url, limits: ExtractLimits())
        ) { error in
            guard case let FouineError.extraction(message) = error else {
                return XCTFail("attendu extraction, obtenu \(error)")
            }
            XCTAssertTrue(message.contains("non-text content"), message)
        }
    }

    func testBinaryRenamedAsHTMLFailsToo() throws {
        let url = file("piege.html")
        var payload = Data("<html>".utf8)
        payload.append(Data(repeating: 0x00, count: 4_096))
        try payload.write(to: url)
        XCTAssertThrowsError(
            try HTMLExtractor().extract(url: url, limits: ExtractLimits())
        ) { error in
            guard case let FouineError.extraction(message) = error else {
                return XCTFail("attendu extraction, obtenu \(error)")
            }
            XCTAssertTrue(message.contains("non-text content"), message)
        }
    }

    // MARK: - A11.6 · une seule invocation de bsdtar par archive

    func testBatchExtractionRendersExactlyWhatEntryByEntryRendered() throws {
        let url = file("melange.zip")
        let entries: [(name: String, data: Data)] = [
            ("dossier/premier.xml", Fixtures.xml("<a>premier</a>")),
            ("nom avec espaces.txt", Data("espaces".utf8)),
            ("img[1].png", Fixtures.pngBytes(7)),
            ("vide.txt", Data()),
            ("dossier/second.xml", Fixtures.xml("<a>second</a>")),
        ]
        try Fixtures.makeArchive(entries, at: url)

        let names = entries.map(\.name)
        let batch = try Bsdtar.extract(archive: url, entries: names)
        XCTAssertEqual(batch.count, names.count)
        for entry in entries {
            XCTAssertEqual(batch[entry.name], entry.data, entry.name)
            // Et rigoureusement ce que rendait l'appel entrée par entrée.
            XCTAssertEqual(batch[entry.name],
                           try Bsdtar.extract(archive: url, entry: entry.name),
                           entry.name)
        }
    }

    /// Le découpage du flux repose sur les tailles déclarées par `bsdtar -tvf` :
    /// elles doivent être lisibles y compris pour un nom à espaces ou à crochets.
    func testDeclaredSizesAreParsedForAwkwardEntryNames() throws {
        let url = file("noms.zip")
        try Fixtures.makeArchive([
            ("nom avec espaces.txt", Data(repeating: 0x41, count: 11)),
            ("img[1].png", Fixtures.pngBytes(7)),
        ], at: url)
        let sizes = try XCTUnwrap(
            Bsdtar.declaredSizes(archive: url,
                                 wanted: ["nom avec espaces.txt", "img[1].png"]))
        XCTAssertEqual(sizes.map(\.name), ["nom avec espaces.txt", "img[1].png"])
        XCTAssertEqual(sizes.map(\.size), [11, 9])
    }

    /// L'EPUB de l'audit : 300 entrées, une invocation de bsdtar par entrée
    /// coûtait 3,44 s contre 0,026 s pour un listage unique.
    func testEpubWithThreeHundredEntriesIsReadInOnePass() throws {
        let url = file("gros.epub")
        var entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Fixtures.xml("""
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf"
            media-type="application/oebps-package+xml"/></rootfiles></container>
            """)),
        ]
        var manifest = "", spine = ""
        for index in 1...300 {
            let page = "<html><body><p>chapitre \(index) enthalpie</p></body></html>"
            entries.append(("OEBPS/ch\(index).xhtml", Data(page.utf8)))
            manifest += "<item id=\"c\(index)\" href=\"ch\(index).xhtml\" "
                + "media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"c\(index)\"/>"
        }
        entries.append(("OEBPS/content.opf", Fixtures.xml("""
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>Recueil</dc:title></metadata>
        <manifest>\(manifest)</manifest><spine>\(spine)</spine></package>
        """)))
        try Fixtures.makeArchive(entries, at: url)

        let started = Date()
        let result = try EPUBExtractor().extract(url: url, limits: ExtractLimits())
        let seconds = Date().timeIntervalSince(started)

        XCTAssertEqual(result.meta["title"], "Recueil")
        XCTAssertEqual(result.pageCount, 300)
        XCTAssertTrue(result.pages[0].text.contains("chapitre 1 enthalpie"),
                      result.pages[0].text)
        XCTAssertTrue(try XCTUnwrap(result.pages.last).text.contains("chapitre 300"))
        // Mesuré sur cette fixture : 2,76 s avant (une invocation par entrée),
        // 0,10 s après (listage + extraction groupée). Marge très large pour ne
        // pas dépendre de la charge de la machine.
        XCTAssertLessThan(seconds, 1.5, "extraction en \(seconds) s")
    }

    // MARK: - S1 · une entrée d'archive est un OPÉRANDE, jamais une option

    /// Nom d'entrée qui, sans le `--` de `Bsdtar`, faisait EXÉCUTER une commande
    /// par bsdtar au moment de l'indexation (audit S1, reproduit sur
    /// bsdtar 3.5.3 / libarchive 3.7.4).
    func trapEntryName(marker: URL) -> String {
        "--use-compress-program=/usr/bin/touch \(marker.path)"
    }

    func testTrappedArchiveEntryIsListedExtractedAndNeverExecuted() throws {
        let marker = file("MARQUEUR_JAMAIS_CREE")
        let trap = trapEntryName(marker: marker)
        let url = file("piege.cbz")
        try Fixtures.makeArchive([
            ("001.jpg", Fixtures.pngBytes(1)),
            (trap, Data("charge utile".utf8)),
            ("--exclude=001.jpg", Data("exclusion".utf8)),
        ], at: url)

        // (a) le listage voit les deux pièges comme des entrées ORDINAIRES.
        let entries = try Bsdtar.list(archive: url)
        XCTAssertTrue(entries.contains(trap), "\(entries)")
        XCTAssertTrue(entries.contains("--exclude=001.jpg"), "\(entries)")
        XCTAssertEqual(entries.count, 3)

        // (b) l'extraction rend leur CONTENU, et non celui d'une autre entrée.
        XCTAssertEqual(try Bsdtar.extract(archive: url, entry: trap),
                       Data("charge utile".utf8))
        XCTAssertEqual(try Bsdtar.extract(archive: url, entry: "--exclude=001.jpg"),
                       Data("exclusion".utf8))
        // Sans `--`, « --exclude=001.jpg » retirait 001.jpg de la sortie : la
        // voie groupée doit rendre les trois entrées, chacune la sienne.
        let batch = try Bsdtar.extract(archive: url,
                                       entries: ["001.jpg", trap, "--exclude=001.jpg"])
        XCTAssertEqual(batch.count, 3)
        XCTAssertEqual(batch["001.jpg"], Fixtures.pngBytes(1))
        XCTAssertEqual(batch[trap], Data("charge utile".utf8))
        XCTAssertEqual(batch["--exclude=001.jpg"], Data("exclusion".utf8))

        // (c) AUCUN marqueur : `--use-compress-program` n'a pas été honoré.
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "bsdtar a exécuté /usr/bin/touch : l'injection d'options "
                       + "est de retour")
    }

    /// Le même piège, mais par le chemin que suit VRAIMENT un .cbz à l'indexation :
    /// listage des images puis rendu page par page.
    func testTrappedComicArchiveExtractsWithoutExecutingAnything() throws {
        let marker = file("MARQUEUR_CBZ")
        let trap = trapEntryName(marker: marker) + ".jpg"   // passe le filtre d'extension
        let url = file("bd.cbz")
        try Fixtures.makeArchive([
            ("002.png", Fixtures.pngBytes(2)),
            (trap, Fixtures.pngBytes(3)),
        ], at: url)

        let images = try ArchiveImages.imageEntries(archiveURL: url)
        XCTAssertEqual(images.count, 2, "\(images)")
        XCTAssertTrue(images.contains(trap), "\(images)")
        XCTAssertEqual(try ArchiveImages.extractEntry(archiveURL: url, entry: trap),
                       Fixtures.pngBytes(3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: - S1 / D8 · environnement figé des sous-processus

    func testChildEnvironmentIsFrozenAndDoesNotLeakThePATH() throws {
        let data = try Subprocess.run("/usr/bin/env", [], what: "essai")
        var seen: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            seen[String(line[line.startIndex..<equals])]
                = String(line[line.index(after: equals)...])
        }
        XCTAssertEqual(seen["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(seen["LANG"], "C.UTF-8")
        XCTAssertEqual(seen["LC_ALL"], "C.UTF-8")
        // RIEN d'autre : ni HOME, ni TMPDIR, ni les variables du terminal.
        XCTAssertEqual(Set(seen.keys), Set(Subprocess.childEnvironment.keys),
                       "\(seen.keys.sorted())")
    }

    /// La locale figée n'est pas cosmétique : sans elle, un nom d'entrée accentué
    /// revenait de `bsdtar -tf` en octal et l'extraction suivante le refusait.
    func testAccentedArchiveEntriesSurviveTheListingAndTheExtraction() throws {
        let url = file("accents.zip")
        let name = "café/élève-œuvre.txt"
        try Fixtures.makeArchive([(name, Data("accents".utf8))], at: url)

        let entries = try Bsdtar.list(archive: url)
        XCTAssertEqual(entries.count, 1)
        let listed = try XCTUnwrap(entries.first)
        XCTAssertFalse(listed.contains("\\3"), "nom échappé en octal : \(listed)")
        // Aller-retour complet : le nom rendu par le listage doit désigner
        // l'entrée pour bsdtar lui-même.
        XCTAssertEqual(try Bsdtar.extract(archive: url, entry: listed),
                       Data("accents".utf8))
    }

    /// L'autre outil externe passe par le même environnement figé et par la même
    /// résolution par chemins explicites : bout en bout, avec accents. Mesuré :
    /// le `-u` de djvused rend de l'UTF-8 quelle que soit la locale (environnement
    /// vide, `LC_ALL=C` ou `C.UTF-8` donnent les mêmes octets), donc c'est bien
    /// la résolution de l'outil et le lancement qui sont sous test ici.
    func testDjvuIsStillExtractedUnderTheFrozenEnvironment() throws {
        try XCTSkipIf(DjvuExtractor.tool() == nil, "djvulibre absent")
        let url = file("accents.djvu")
        try XCTSkipUnless(try Fixtures.makeDjvu(
            pages: ["Cinétique à 25 °C — œuvre", "Équilibre et enthalpie libre"],
            at: url), "cjb2/djvm/djvused indisponibles")
        let result = try DjvuExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertTrue(result.pages[0].text.contains("Cinétique à 25 °C — œuvre"),
                      result.pages[0].text)
        XCTAssertTrue(result.pages[1].text.contains("Équilibre"),
                      result.pages[1].text)
    }

    // MARK: - D8 · résolution d'un outil externe par chemins explicites

    func testToolIsResolvedByExplicitPathsInOrderAndNotByPATH() throws {
        let brew = directory.appendingPathComponent("homebrew-bin")
        let macports = directory.appendingPathComponent("macports-bin")
        let ailleurs = directory.appendingPathComponent("ailleurs")
        for dir in [brew, macports, ailleurs] {
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true)
        }
        func makeExecutable(_ url: URL) throws {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: url.path)
        }
        let inBrew = brew.appendingPathComponent("djvused")
        let inMacports = macports.appendingPathComponent("djvused")
        let inAilleurs = ailleurs.appendingPathComponent("djvused")
        try makeExecutable(inMacports)
        try makeExecutable(inAilleurs)

        let directories = [brew.path, macports.path]
        let override = [DjvuExtractor.overrideVariable: inAilleurs.path]

        // Absent des deux répertoires standard mais présent dans MacPorts.
        XCTAssertEqual(Subprocess.tool("djvused", directories: directories),
                       inMacports.path)
        // L'ORDRE compte : Homebrew passe devant MacPorts dès qu'il existe.
        try makeExecutable(inBrew)
        XCTAssertEqual(Subprocess.tool("djvused", directories: directories),
                       inBrew.path)
        // L'override ne DÉTOURNE pas un outil correctement installé…
        XCTAssertEqual(
            Subprocess.tool("djvused",
                            overrideVariable: DjvuExtractor.overrideVariable,
                            directories: directories, environment: override),
            inBrew.path)
        // …mais il dépanne une installation hors des répertoires standard.
        XCTAssertEqual(
            Subprocess.tool("djvused",
                            overrideVariable: DjvuExtractor.overrideVariable,
                            directories: [], environment: override),
            inAilleurs.path)
        // Introuvable partout -> nil, et surtout PAS de repli sur PATH : le
        // djvused réellement installé sur la machine ne doit pas être trouvé ici.
        XCTAssertNil(Subprocess.tool("djvused", directories: []))
        // Un override qui ne désigne pas un exécutable est ignoré, pas suivi —
        // un fichier ordinaire comme un DOSSIER (dont le bit x ne veut dire que
        // « traversable », et que `isExecutableFile` accepte pourtant).
        let ordinaire = file("pas-un-outil")
        try Data("texte".utf8).write(to: ordinaire)
        for chemin in [ordinaire.path, directory.path] {
            XCTAssertNil(Subprocess.tool(
                "djvused", overrideVariable: DjvuExtractor.overrideVariable,
                directories: [],
                environment: [DjvuExtractor.overrideVariable: chemin]), chemin)
        }
    }

    // MARK: - A11.11 · stderr conservé quand le code retour vaut 0

    func testStderrIsKeptWhenTheToolSucceeds() throws {
        let script = file("bavard.sh")
        try Data("#!/bin/sh\necho utile\necho 'avertissement' >&2\nexit 0\n".utf8)
            .write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        let out = try Subprocess.capture("/bin/sh", [script.path], what: "essai")
        XCTAssertEqual(String(decoding: out.stdout, as: UTF8.self), "utile\n")
        // Jeté jusqu'ici : le message d'un outil qui avertit PUIS réussit ne
        // laissait aucune trace exploitable dans `docs.err`.
        XCTAssertEqual(out.stderr, "avertissement")
    }

    // MARK: - A11.8 · plafond de taille sur un paquet-dossier (.rtfd)

    func testFileGuardSumsTheContentOfAPackageDirectory() throws {
        let package = file("note.rtfd")
        try FileManager.default.createDirectory(at: package,
                                                withIntermediateDirectories: true)
        try Data("{\\rtf1 texte}".utf8)
            .write(to: package.appendingPathComponent("TXT.rtf"))
        for index in 1...3 {
            try Data(repeating: 0x42, count: 400_000)
                .write(to: package.appendingPathComponent("image\(index).png"))
        }

        // stat() rend 128 sur le dossier lui-même : c'est ce qui rendait le
        // plafond inopérant.
        var st = stat()
        XCTAssertEqual(stat(package.path, &st), 0)
        XCTAssertLessThan(Int64(st.st_size), 4_096)

        let bytes = try FileGuard.size(of: package)
        XCTAssertGreaterThan(bytes, 1_200_000)
        XCTAssertLessThan(bytes, 1_300_000)

        var limits = ExtractLimits()
        limits.maxFileBytes = 1 << 20                 // 1 Mio : le paquet dépasse
        XCTAssertThrowsError(try FileGuard.check(package, limits)) { error in
            guard case let FouineError.fileTooLarge(bytes) = error else {
                return XCTFail("attendu fileTooLarge, obtenu \(error)")
            }
            XCTAssertGreaterThan(bytes, Int64(limits.maxFileBytes))
        }
        // Et il passe sous le plafond de service.
        XCTAssertNoThrow(try FileGuard.check(package, ExtractLimits()))
    }

    /// Bout en bout : le plafond doit s'appliquer à un vrai .rtfd, qui est le seul
    /// « fichier » du §5.3 que le crawler indexe alors que c'est un dossier.
    func testRichTextExtractorHonoursTheCapOnRtfdPackages() throws {
        let package = file("cours.rtfd")
        try FileManager.default.createDirectory(at: package,
                                                withIntermediateDirectories: true)
        let rtf = "{\\rtf1\\ansi\\ansicpg1252 Chromatographie sur couche mince "
            + "\\'e0 25 \\'b0C.}"
        try Data(rtf.utf8).write(to: package.appendingPathComponent("TXT.rtf"))
        try Data(repeating: 0x42, count: 2 << 20)
            .write(to: package.appendingPathComponent("figure.png"))

        // Sous le plafond : le paquet s'extrait normalement.
        let result = try RichTextExtractor().extract(url: package,
                                                     limits: ExtractLimits())
        XCTAssertTrue(try XCTUnwrap(result.pages.first).text
            .contains("Chromatographie sur couche mince"))

        // Au-dessus : .fileTooLarge, alors que `st_size` du dossier vaut 128.
        var limits = ExtractLimits()
        limits.maxFileBytes = 1 << 20
        XCTAssertThrowsError(
            try RichTextExtractor().extract(url: package, limits: limits)
        ) { error in
            guard case FouineError.fileTooLarge = error else {
                return XCTFail("attendu fileTooLarge, obtenu \(error)")
            }
        }
    }

    func testFileGuardStillMeasuresPlainFiles() throws {
        let url = file("plat.txt")
        try Data(repeating: 0x41, count: 12_345).write(to: url)
        XCTAssertEqual(try FileGuard.size(of: url), 12_345)
        var limits = ExtractLimits()
        limits.maxFileBytes = 1_000
        XCTAssertThrowsError(try FileGuard.check(url, limits))
    }
}
