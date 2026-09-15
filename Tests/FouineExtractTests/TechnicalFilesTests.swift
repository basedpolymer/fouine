// TechnicalFilesTests.swift — code source, XML, listes de propriétés
// (lot INT-F1, SPEC §5.3). Propriété : A-Ingest.

import XCTest
import FouineCore
@testable import FouineExtract

final class SourceFileTests: XCTestCase {

    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("sources")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Une source est du texte : elle s'indexe par le chemin du texte brut, avec
    /// ses accents et ses commentaires.
    func testSourceFilesAreIndexedAsText() throws {
        let cases: [(String, String)] = [
            ("mesure.py", "# calcul de la polarimétrie\ndef mesurer():\n    return 42\n"),
            ("Composant.tsx", "export const Titre = () => <h1>Tensiométrie</h1>;\n"),
            ("reglages.yaml", "titre: néphélométrie\nvaleur: 3\n"),
            ("requete.sql", "SELECT sonometrie FROM mesures;\n"),
            ("script.sh", "#!/bin/sh\necho \"gravimétrie\"\n"),
        ]
        for (name, body) in cases {
            let url = file(name)
            try Data(body.utf8).write(to: url)
            let result = try DefaultExtractorRegistry().extract(url: url)
            let text = result.pages.map(\.text).joined()
            XCTAssertEqual(result.pages.count, 1, name)
            XCTAssertTrue(text.contains(body.trimmingCharacters(in: .newlines)
                                            .components(separatedBy: "\n")[0]),
                          "\(name) : \(text)")
        }
    }

    /// Une source MINIFIÉE est refusée NOMMÉMENT, et le refus se classe
    /// `.skipped` : le fichier n'est pas cassé, il n'a simplement rien à
    /// indexer qu'un humain relise.
    func testMinifiedSourcesAreSkippedByName() throws {
        let url = file("bibliotheque.min.js")
        try Data("var a=1;\nvar b=2;\n".utf8).write(to: url)
        XCTAssertThrowsError(try DefaultExtractorRegistry().extract(url: url)) {
            guard case FouineError.extraction(let message) = $0 else {
                return XCTFail("attendu extraction, obtenu \($0)")
            }
            XCTAssertEqual(message, PlainTextExtractor.minifiedReason)
            XCTAssertEqual(ExtractOutcome.skipReason(for: .extraction(message)),
                           PlainTextExtractor.minifiedReason)
        }
    }

    /// Le second critère : une seule ligne interminable, quel que soit le nom.
    func testMinifiedSourcesAreSkippedByShape() throws {
        let url = file("paquet.js")
        try Data(("var x=" + String(repeating: "a", count: 4_000) + ";").utf8)
            .write(to: url)
        XCTAssertThrowsError(try PlainTextExtractor().extract(url: url,
                                                             limits: ExtractLimits()))

        // CONTRE-ÉPREUVE : le même critère ne doit PAS s'appliquer aux formats
        // « document ». Un journal ou un LaTeX tient légitimement sur une ligne
        // — une ligne de MOTS : une suite sans blanc est refusée par un autre
        // motif depuis EX2 (`TextEncodingTests`).
        let log = file("journal.log")
        try Data(("date " + String(repeating: "bb ", count: 1_400)).utf8).write(to: log)
        XCTAssertNoThrow(try PlainTextExtractor().extract(url: log,
                                                          limits: ExtractLimits()))
    }

    func testMinifiedDecisionIsPure() {
        XCTAssertTrue(PlainTextExtractor.isMinified(name: "jquery.min.js", text: "a"))
        XCTAssertTrue(PlainTextExtractor.isMinified(name: "style.MIN.CSS", text: "a"))
        XCTAssertFalse(PlainTextExtractor.isMinified(name: "index.js",
                                                     text: "let a = 1;\nlet b = 2;\n"))
        XCTAssertFalse(PlainTextExtractor.isMinified(name: "vide.js", text: ""))
    }
}

final class XMLDocumentExtractorTests: XCTestCase {

    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("xml")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Le texte des NŒUDS, jamais les attributs — et un document sur une seule
    /// ligne ne doit pas rendre ses mots collés.
    func testNodeTextIsKeptAndAttributesAreNot() throws {
        let url = file("configuration.xml")
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <reglages identifiant="ne-doit-pas-entrer"><titre>Néphélométrie</titre>\
        <valeur unite="mg">12</valeur></reglages>
        """.utf8).write(to: url)

        let result = try DefaultExtractorRegistry().extract(url: url)
        let text = result.pages.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("Néphélométrie"), text)
        XCTAssertTrue(text.contains("12"), text)
        XCTAssertFalse(text.contains("ne-doit-pas-entrer"), text)
        XCTAssertFalse(text.contains("Néphélométrie12"), "les nœuds sont collés : \(text)")
    }

    /// Un XML mal formé reste lisible : on retombe sur le texte brut plutôt que
    /// de perdre le document.
    func testMalformedXMLFallsBackToPlainText() throws {
        let url = file("casse.xml")
        try Data("<notes><note>Ellipsométrie & mesure</note>".utf8).write(to: url)
        let result = try XMLDocumentExtractor().extract(url: url,
                                                        limits: ExtractLimits())
        XCTAssertTrue(result.pages.map(\.text).joined().contains("Ellipsométrie"))
    }

    /// Un `.svg` de tracés purs n'a rien à indexer : refus nommé, classé
    /// `.skipped`.
    func testSVGWithoutTextIsSkipped() throws {
        let url = file("schema.svg")
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M0 0\"/></svg>".utf8)
            .write(to: url)
        XCTAssertThrowsError(try DefaultExtractorRegistry().extract(url: url)) {
            guard case FouineError.extraction(let message) = $0 else {
                return XCTFail("attendu extraction, obtenu \($0)")
            }
            XCTAssertEqual(message, XMLDocumentExtractor.noTextReason)
            XCTAssertEqual(ExtractOutcome.skipReason(for: .extraction(message)),
                           XMLDocumentExtractor.noTextReason)
        }

        // …et un `.svg` qui porte un `<text>` s'indexe, lui.
        let titled = file("courbe.svg")
        try Data("<svg><text>Conductimétrie</text></svg>".utf8).write(to: titled)
        let result = try DefaultExtractorRegistry().extract(url: titled)
        XCTAssertTrue(result.pages.map(\.text).joined().contains("Conductimétrie"))
    }

    /// Une liste de propriétés BINAIRE (`bplist00`) se lit en « clé : valeur ».
    /// C'est le seul format de ce lot qu'un lecteur de texte ne peut pas
    /// approcher : sans `PropertyListSerialization`, ce sont des octets.
    func testBinaryPropertyListIsReadAsKeyValues() throws {
        let url = file("reglages.plist")
        let object: [String: Any] = ["titre": "Sonométrie", "seuil": 3]
        let data = try PropertyListSerialization.data(fromPropertyList: object,
                                                      format: .binary, options: 0)
        try data.write(to: url)
        XCTAssertTrue(data.starts(with: Array("bplist00".utf8)))

        let result = try DefaultExtractorRegistry().extract(url: url)
        let text = result.pages.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("titre : Sonométrie"), text)
        XCTAssertTrue(text.contains("seuil"), text)
    }

    func testXMLPropertyListIsAlsoRead() throws {
        let url = file("reglages-xml.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["auteur": "Colorimétrie"], format: .xml, options: 0)
        try data.write(to: url)
        let result = try DefaultExtractorRegistry().extract(url: url)
        XCTAssertTrue(result.pages.map(\.text).joined().contains("Colorimétrie"))
    }
}
