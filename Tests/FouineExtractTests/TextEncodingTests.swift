// TextEncodingTests.swift — encodage des textes, cibles des liens, suites sans
// blanc (EX2). Propriété : A-Ingest.

import XCTest
import FouineCore
@testable import FouineExtract

final class TextEncodingTests: XCTestCase {

    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("encodage")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func setTextEncoding(_ value: String, on url: URL) throws {
        let bytes = Array(value.utf8)
        let status = url.withUnsafeFileSystemRepresentation { path in
            setxattr(path!, PlainTextExtractor.textEncodingAttribute,
                     bytes, bytes.count, 0, 0)
        }
        XCTAssertEqual(status, 0, "setxattr : errno \(errno)")
    }

    // MARK: - Windows-1252

    /// Les octets 0x80–0x9F d'un fichier de PC occidental sont € œ ’, pas des
    /// commandes C1.
    func testWindows1252BytesDecodeExactly() {
        // « Prix : 12 € — l’œuvre »
        var bytes: [UInt8] = Array("Prix : 12 ".utf8)
        bytes += [0x80, 0x20, 0x97, 0x20]           // € —
        // UNE SUITE D'AJOUTS, et non une chaîne de `+`. Mesuré le 14/09/2026
        // (lot BT1) : `Array("l".utf8) + [0x92] + [0x9C] + Array("uvre".utf8)`
        // demandait 34,5 s de type-checking — la moitié du temps de
        // compilation de FouineExtractTests pour une ligne, parce que le
        // vérificateur essaie toutes les surcharges de `+` sur des littéraux
        // d'entier sans type. Les octets sont les mêmes.
        bytes += Array("l".utf8)
        bytes += [0x92, 0x9C]                       // ’ œ
        bytes += Array("uvre".utf8)
        let text = PlainTextExtractor.decode(Data(bytes))
        XCTAssertEqual(text, "Prix : 12 € — l’œuvre")
    }

    /// Le contrôle de plausibilité ne départageait PAS : décodé en Latin-1, le
    /// même texte passait, ses guillemets changés en commandes C1.
    func testLatin1ReadingOfWindows1252WasPlausible() throws {
        var bytes: [UInt8] = Array("Une phrase ordinaire ".utf8)
        bytes += [0x93]                             // “
        bytes += Array("citée".data(using: .isoLatin1)!)
        bytes += [0x94]                             // ”
        let latin1 = try XCTUnwrap(String(data: Data(bytes), encoding: .isoLatin1))
        XCTAssertTrue(Plausibility.isPlausible(latin1),
                      "sans CP1252 devant, ce mojibake entrait dans l'index")
        XCTAssertEqual(PlainTextExtractor.decode(Data(bytes)),
                       "Une phrase ordinaire “citée”")
    }

    /// Un fichier Latin-1 sans octet 0x80–0x9F ressort à l'identique.
    func testPureLatin1IsUnchanged() throws {
        let original = "Été 1998 : « cinétique », à 25 °C — ½ litre, ÿ, ß"
            .replacingOccurrences(of: "—", with: "-")
        let data = try XCTUnwrap(original.data(using: .isoLatin1))
        XCTAssertFalse(data.contains { (0x80...0x9F).contains($0) })
        XCTAssertEqual(PlainTextExtractor.decode(data), original)
    }

    // MARK: - com.apple.TextEncoding

    /// TextEdit a écrit « macintosh;0 » : c'est lui qui départage, là où la
    /// chaîne s'arrête à ISO-8859-1 (plausible) et rend d'autres lettres.
    func testDeclaredMacRomanIsHonoured() throws {
        let original = "Café crème — naïveté, œuvre"
        let data = try XCTUnwrap(original.data(using: .macOSRoman))
        XCTAssertNotEqual(PlainTextExtractor.decode(data), original,
                          "sans l'attribut, la chaîne ne retrouve pas le MacRoman")
        let url = file("note.txt")
        try data.write(to: url)
        try setTextEncoding("macintosh;0", on: url)
        XCTAssertEqual(PlainTextExtractor.decode(data, url: url), original)
        let result = try PlainTextExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pages.map(\.text).joined(), original)
    }

    /// Un nom inconnu est ignoré, le nombre qui suit ne le rattrape pas.
    func testUnknownDeclaredEncodingIsIgnored() throws {
        let original = "Café crème — naïveté, œuvre"
        let data = try XCTUnwrap(original.data(using: .macOSRoman))
        let url = file("faux.txt")
        try data.write(to: url)
        try setTextEncoding("x-inexistant;0", on: url)
        XCTAssertNil(PlainTextExtractor.declaredEncoding(of: url))
        XCTAssertEqual(PlainTextExtractor.decode(data, url: url),
                       PlainTextExtractor.decode(data))
    }

    /// Un attribut resté faux (« utf-8 » sur du Latin-1) : l'UTF-8 échoue, la
    /// chaîne reprend.
    func testWrongDeclaredEncodingFallsBackToChain() throws {
        let original = "Été à 25 °C"
        let data = try XCTUnwrap(original.data(using: .isoLatin1))
        let url = file("menteur.txt")
        try data.write(to: url)
        try setTextEncoding("utf-8;134217984", on: url)
        XCTAssertEqual(PlainTextExtractor.decode(data, url: url), original)
    }

    /// Les sous-titres passent par le même décodage, attribut compris.
    func testSubtitleHonoursDeclaredEncoding() throws {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nCafé crème — naïveté\n"
        let data = try XCTUnwrap(srt.data(using: .macOSRoman))
        let url = file("film.srt")
        try data.write(to: url)
        try setTextEncoding("macintosh;0", on: url)
        let result = try SubtitleExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertTrue(result.pages.map(\.text).joined().contains("Café crème — naïveté"))
    }

    // MARK: - Suites sans blanc

    /// LE CONTENU A CHANGÉ AU LOT MN1, pas la règle : il était
    /// `{"d":"AAA…"}`, c'est-à-dire du JSON BIEN FORMÉ, ce qui est désormais
    /// une preuve de plausibilité (voir plus bas). Un vidage qui ne se parse
    /// pas — une colonne de base 64, un JSON tronqué — reste refusé, et c'est
    /// ce que ce test garde.
    func testRunOf2000CharactersIsSkippedByName() throws {
        let url = file("export.json")
        try Data(String(repeating: "A", count: 2_000).utf8)
            .write(to: url)   // 2 000 caractères, pas un blanc, pas du JSON
        XCTAssertThrowsError(try DefaultExtractorRegistry().extract(url: url)) {
            guard case FouineError.extraction(let message) = $0 else {
                return XCTFail("attendu extraction, obtenu \($0)")
            }
            XCTAssertEqual(message,
                           "no readable text: 2000-character run without a space — data dump?")
            XCTAssertEqual(ExtractOutcome.skipReason(for: .extraction(message)), message,
                           "classé .skipped, comme la source minifiée")
        }
    }

    func testRunOf1999CharactersIsAccepted() throws {
        let url = file("presque.txt")
        try Data(("début " + String(repeating: "b", count: 1_999) + " fin").utf8)
            .write(to: url)
        let result = try PlainTextExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertFalse(result.pages.isEmpty)
    }

    /// Les sources gardent leur propre garde-fou : `isMinified`, inchangé.
    func testSourcesKeepTheMinifiedRule() throws {
        let url = file("paquet.js")
        try Data(("var x=" + String(repeating: "a", count: 4_000) + ";").utf8)
            .write(to: url)
        XCTAssertThrowsError(try PlainTextExtractor().extract(url: url,
                                                             limits: ExtractLimits())) {
            guard case FouineError.extraction(let message) = $0 else {
                return XCTFail("attendu extraction, obtenu \($0)")
            }
            XCTAssertEqual(message, PlainTextExtractor.minifiedReason)
        }
    }

    func testLongestRunIsMeasured() {
        XCTAssertEqual(Plausibility.longestRunWithoutWhitespace(in: ""), 0)
        XCTAssertEqual(Plausibility.longestRunWithoutWhitespace(in: "ab cde\tf\ngh"), 3)
        XCTAssertEqual(Plausibility.longestRunWithoutWhitespace(in: "x\u{00A0}yy"), 2,
                       "l'espace insécable est un blanc")
    }

    // MARK: - Les deux faux refus levés (lot MN1)

    /// UNE IMAGE EMBARQUÉE N'EST PAS UN VIDAGE DE DONNÉES. Un `.md` exporté par
    /// Typora ou Obsidian porte ses illustrations en `data:image/png;base64,…` :
    /// mesuré le 14/09/2026, un compte rendu de deux paragraphes était refusé
    /// en entier sur une « suite de 12 033 caractères ».
    func testAnEmbeddedImageIsNotADataDump() throws {
        let url = file("reunion.md")
        let blob = String(repeating: "iVBORw0KGgoAAAANSUhEUg", count: 500)
        try Data(("# Compte rendu\n\nLe reacteur a piston a tourne trois heures.\n\n"
                  + "![courbe](data:image/png;base64,\(blob))\n\nFin.\n").utf8)
            .write(to: url)
        XCTAssertGreaterThan(blob.count, PlainTextExtractor.maxRunWithoutWhitespace)

        let result = try PlainTextExtractor().extract(url: url, limits: ExtractLimits())
        let text = result.pages.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("reacteur"), text.prefix(120).description)
        // L'image reste dans le texte indexé — la retirer serait un autre
        // chantier (elle ne coûte qu'un « mot » que personne ne tape) ; ce qui
        // compte est que le DOCUMENT entre.
        XCTAssertEqual(Plausibility.longestRunWithoutWhitespace(
            in: "avant data:image/png;base64,\(blob) apres"), 5,
                       "l'adresse `data:` ne compte pas dans la suite mesurée")
    }

    /// UN JSON COMPACTÉ NON PLUS : il a une syntaxe, elle se vérifie, et ses
    /// valeurs sont ce que l'on cherchera dedans. Mesuré le 14/09/2026 : un
    /// export d'API de 36 417 caractères sans un blanc, refusé en entier.
    func testCompactedJSONIsPlausibleWhateverItsLines() throws {
        let url = file("commandes.json")
        let rows = (0..<600).map {
            "{\"id\":\($0),\"sku\":\"REF-\($0)-XY\",\"etat\":\"livre\"}"
        }.joined(separator: ",")
        let text = "{\"commandes\":[\(rows)]}"
        try Data(text.utf8).write(to: url)
        XCTAssertFalse(text.contains(" "))
        XCTAssertGreaterThan(Plausibility.longestRunWithoutWhitespace(in: text),
                             PlainTextExtractor.maxRunWithoutWhitespace)
        XCTAssertTrue(PlainTextExtractor.parsesAsJSON(Data(text.utf8)))

        let result = try PlainTextExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertTrue(result.pages.map(\.text).joined().contains("REF-42-XY"))
    }

    /// LE CONTRE-TEST : une vraie suite sans introducteur ni syntaxe reste
    /// refusée. C'est le cas que le garde-fou d'EX2 visait — une colonne de
    /// base 64 dans un `.txt` de sauvegarde.
    func testANakedBase64RunIsStillRefused() throws {
        let url = file("sauvegarde.txt")
        let blob = String(repeating: "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=", count: 400)
        try Data(("SAUVEGARDE\n" + blob + "\n").utf8).write(to: url)
        XCTAssertFalse(PlainTextExtractor.parsesAsJSON(Data(blob.utf8)))
        XCTAssertThrowsError(try PlainTextExtractor().extract(
            url: url, limits: ExtractLimits())) {
            guard case FouineError.extraction(let message) = $0 else {
                return XCTFail("attendu extraction, obtenu \($0)")
            }
            XCTAssertTrue(PlainTextExtractor.isDataDump(message), message)
            XCTAssertEqual(message, PlainTextExtractor.dataDumpReason(run: blob.count))
        }
    }

    /// La sonde JSON ne tourne que sur le chemin du REFUS, et sous un plafond
    /// de taille : au-delà, un vidage reste un vidage.
    func testTheJSONProbeHasACeiling() {
        let big = Data(("[" + String(repeating: "1,", count: 3_000_000) + "1]").utf8)
        XCTAssertGreaterThan(big.count, PlainTextExtractor.jsonProbeMaxBytes)
        XCTAssertFalse(PlainTextExtractor.parsesAsJSON(big),
                       "au-delà du plafond, on ne parse même pas")
    }
}

final class HTMLLinkTargetTests: XCTestCase {

    func text(_ html: String) -> String { HTMLText.plainText(from: html) }

    func testSearchableSchemesAreKept() {
        XCTAssertEqual(text("<p>Voir <a href=\"https://doi.org/10.1000/xyz\">Article</a>.</p>"),
                       "Voir Article (https://doi.org/10.1000/xyz).")
        XCTAssertEqual(text("<a href='http://exemple.org/depot'>le dépôt</a>"),
                       "le dépôt (http://exemple.org/depot)")
        XCTAssertEqual(text("<a class=x href=mailto:marie@exemple.fr>Écrire</a>"),
                       "Écrire (mailto:marie@exemple.fr)")
        XCTAssertEqual(text("<A HREF=\"doi:10.1000/182\">manuel</A>"),
                       "manuel (doi:10.1000/182)")
    }

    func testEntitiesInTargetAreDecoded() {
        XCTAssertEqual(text("<a href=\"https://ex.org/?a=1&amp;b=2\">requête</a>"),
                       "requête (https://ex.org/?a=1&b=2)")
    }

    func testInternalAndScriptTargetsAreDropped() {
        XCTAssertEqual(text("<a href=\"#section-2\">plus bas</a>"), "plus bas")
        XCTAssertEqual(text("<a href=\"chapitre2.xhtml#p3\">chapitre 2</a>"), "chapitre 2")
        XCTAssertEqual(text("<a href=\"javascript:void(0)\">ouvrir</a>"), "ouvrir")
        XCTAssertEqual(text("<a data-href=\"https://ex.org\">rien</a>"), "rien",
                       "data-href n'est pas href")
    }

    func testLabelEqualToTargetIsNotRepeated() {
        XCTAssertEqual(text("<a href=\"https://exemple.org/\">https://exemple.org/</a>"),
                       "https://exemple.org/")
        XCTAssertEqual(text("<a href=\"https://exemple.org/\">exemple.org</a>"),
                       "exemple.org")
        XCTAssertEqual(text("<a href=\"mailto:a@b.fr\">a@b.fr</a>"), "a@b.fr")
    }

    func testEmptyLinkGivesTargetOnly() {
        XCTAssertEqual(text("<p>avant<a href=\"https://ex.org/x\"></a>après</p>"),
                       "avant https://ex.org/x après")
        XCTAssertEqual(text("<a href=\"https://ex.org/x\"><img src=\"logo.png\"></a>"),
                       "https://ex.org/x")
    }

    /// Entrées hostiles : lien jamais fermé, attribut sans guillemet de fin,
    /// liens enchaînés sans `</a>`. Un résultat, jamais un piège.
    func testMalformedLinksDoNotTrap() {
        XCTAssertEqual(text("<a href=\"https://ex.org\">sans fin"), "sans fin (https://ex.org)")
        XCTAssertEqual(text("<a href=\"https://a.org\">un<a href=\"https://b.org\">deux</a>"),
                       "un (https://a.org)deux (https://b.org)")
        _ = text("<a href=\"https://ex.org>jamais fermé")
        _ = text("<a href=")
        _ = text("<a =x href>")
        XCTAssertEqual(text("<a href=\"https://\">vide</a>"), "vide")
    }
}
