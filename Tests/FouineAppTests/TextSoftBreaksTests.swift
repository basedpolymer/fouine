// TextSoftBreaksTests.swift — coupures invisibles de l'aperçu texte (EX2).

import XCTest
@testable import FouineApp

final class TextSoftBreaksTests: XCTestCase {

    private func storage(_ s: String) -> UnsafeRawPointer? {
        s.utf8.withContiguousStorageIfAvailable { UnsafeRawPointer($0.baseAddress) } ?? nil
    }

    /// Sans suite de 500 caractères, le texte ressort tel quel — le même
    /// tampon, pas une copie.
    func testTextWithoutLongRunIsReturnedAsIs() {
        let text = "Une page ordinaire, " + String(repeating: "x", count: 499)
            + " et une suite de 499 caractères."
        let out = TextSoftBreaks.insert(text)
        XCTAssertEqual(out, text)
        XCTAssertNotNil(storage(text))
        XCTAssertEqual(storage(out), storage(text))
        XCTAssertEqual(TextSoftBreaks.insert(""), "")
    }

    /// Une suite de lettres d'un seul tenant : une coupure tous les 120.
    func testBreaksEvery120InAPlainRun() {
        let run = String(repeating: "A", count: 500)
        let out = TextSoftBreaks.insert("début " + run + " fin")
        let pieces = out.dropFirst(6).dropLast(4)
            .split(separator: TextSoftBreaks.breakCharacter,
                   omittingEmptySubsequences: false)
        XCTAssertEqual(pieces.map(\.count), [120, 120, 120, 120, 20])
        XCTAssertEqual(out.replacingOccurrences(of: "\u{200B}", with: ""),
                       "début " + run + " fin", "rien d'autre n'a changé")
    }

    /// Une suite qui porte de la ponctuation : la coupure suit une frontière
    /// de jeton, et l'écart ne dépasse jamais 120.
    func testBreaksFollowPunctuationWhenPresent() {
        let run = Array(repeating: "abcdefghi,", count: 60).joined()   // 600
        let out = TextSoftBreaks.insert(run)
        let pieces = out.split(separator: TextSoftBreaks.breakCharacter)
        XCTAssertGreaterThan(pieces.count, 4)
        for piece in pieces.dropLast() {
            XCTAssertLessThanOrEqual(piece.count, 120)
            XCTAssertEqual(piece.last, ",")
        }
        XCTAssertEqual(pieces.joined(), run)
    }

    /// Le surlignage d'un mot dans une page qui contient une suite géante :
    /// intact, y compris pour un terme DANS la suite, à cheval sur le 120e
    /// caractère.
    func testHighlightingSurvivesSoftBreaks() {
        // « spectro » occupe les caractères 116 à 122 de la suite.
        let head = Array(repeating: "x", count: 115).joined() + ","
        let run = head + "spectro," + String(repeating: "y", count: 600)
        let page = "La spectroscopie infrarouge. " + run + " Fin de la spectro."
        let terms = QueryTerms.extract(from: "spectro")
        let before = TextHighlighter.attributed(page, terms: terms, monospaced: false)
        let softened = TextSoftBreaks.insert(page)
        XCTAssertNotEqual(softened, page)
        let after = TextHighlighter.attributed(softened, terms: terms, monospaced: false)
        XCTAssertEqual(before.occurrences, 2)
        XCTAssertEqual(after.occurrences, before.occurrences)
        let marked = after.text.runs.filter { $0.backgroundColor != nil }
        XCTAssertEqual(marked.map { String(after.text[$0.range].characters) },
                       ["spectro", "spectro"])
    }
}
