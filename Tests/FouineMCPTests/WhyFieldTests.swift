// WhyFieldTests.swift — le champ `why` et la note « aucun de vos mots » (lot U1).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// Les transcriptions golden figent `why` sur la base jetable ; ce fichier
// éprouve les deux règles qu'une séance ne montre pas : la valeur `null` quand
// il n'y a rien d'honnête à dire, et le CUMUL de la note avec les autres.

import XCTest
import FouineCore
@testable import FouineMCP

final class WhyFieldTests: XCTestCase {

    func testWhyIsAnObjectWhenTheSnippetCarriesTheWords() throws {
        let why = SearchTool.why(HitExplanation.words(ofQuery: "electrolyse"),
                                 text: "«electrolyse» enthalpie page 1",
                                 fuzzyDistance: 0)
        let object = try XCTUnwrap(why as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "exact")
        XCTAssertEqual(object["terms_found"] as? [String], ["electrolyse"])
    }

    func testTheSnippetNeverClaimsAWordIsMissing() throws {
        // L'extrait ne montre qu'un mot sur deux, mais FTS5 a apparié la page
        // sur les DEUX : `terms_missing` serait un mensonge, et ferait conclure
        // au modèle que le corpus ne traite qu'à moitié du sujet.
        let why = SearchTool.why(
            HitExplanation.words(ofQuery: "electrolyse enthalpie"),
            text: "…«electrolyse» du sel fondu…", fuzzyDistance: 0)
        let object = try XCTUnwrap(why as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "exact")
        XCTAssertEqual(object["terms_found"] as? [String],
                       ["electrolyse", "enthalpie"])
        XCTAssertNil(object["terms_missing"])
    }

    func testWhyIsNullRatherThanAbsentWhenThereIsNothingToSay() {
        // Un champ ABSENT n'apprend rien à un modèle : c'est la règle de tout
        // `SearchTool`, et elle vaut aussi pour `why`. Ici la page a été
        // appariée par une VARIANTE que l'extrait ne montre pas : impossible de
        // dire laquelle, donc on se tait.
        let why = SearchTool.why(HitExplanation.words(ofQuery: "catalyseur"),
                                 text: "…suite du paragraphe…", fuzzyDistance: 1)
        XCTAssertTrue(why is NSNull)
    }

    func testSemanticOnlyHitSaysSo() throws {
        let why = SearchTool.why(HitExplanation.words(ofQuery: "tarte aux pommes"),
                                 text: "Chapitre 3 — thermodynamique.",
                                 fuzzyDistance: 0, lexRank: nil, vecRank: 2)
        let object = try XCTUnwrap(why as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "semantic")
    }

    // MARK: - La note honnête (R-04)

    func testNoteAppearsWhenNoPageCarriesTheWords() {
        XCTAssertEqual(SearchTool.noLexicalMatchNote(lexTotalPages: 0, hits: 3),
                       SearchAdvice.noLexicalMatch)
    }

    func testNoteIsSilentWhenTheLexicalChannelFoundSomething() {
        XCTAssertNil(SearchTool.noLexicalMatchNote(lexTotalPages: 12, hits: 3))
    }

    func testNoteIsSilentWhenThereIsNoResultAtAll() {
        // Zéro résultat n'a pas besoin d'être expliqué par le canal sémantique :
        // il n'y a rien à lire.
        XCTAssertNil(SearchTool.noLexicalMatchNote(lexTotalPages: 0, hits: 0))
    }

    func testNotesCumulate() {
        let note = SearchTool.notes(
            "only 3.0 % of pages are vectorised",
            SearchTool.veryCommonWordNote(true),
            SearchTool.noLexicalMatchNote(lexTotalPages: 0, hits: 1))
        let text = try? XCTUnwrap(note)
        XCTAssertTrue(text?.contains(SearchAdvice.veryCommonWord) == true)
        XCTAssertTrue(text?.contains(SearchAdvice.noLexicalMatch) == true)
        XCTAssertEqual(text?.components(separatedBy: " · ").count, 3)
    }
}
