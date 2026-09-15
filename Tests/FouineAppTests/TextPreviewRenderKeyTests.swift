// TextPreviewRenderKeyTests.swift — l'aperçu Texte relance son surlignage
// quand la page change, même à longueur égale (lot MN2). Propriété : A-App.
//
// Le défaut : la clé ne portait que la longueur du texte et les termes. Deux
// cartes Anki jumelles, deux feuilles de tableur de même longueur gardaient à
// l'écran le texte surligné de la page d'avant.

import XCTest
@testable import FouineApp

final class TextPreviewRenderKeyTests: XCTestCase {

    private let terms = [HighlightTerm(text: "azote", folded: "azote", kind: .word,
                                       colorIndex: 0)]

    private func content(_ text: String, monospaced: Bool = false) -> PageTextContent {
        PageTextContent(text: text, pages: [1, 2], fromOCR: false,
                        monospaced: monospaced)
    }

    func testTwinPagesOfTheSameLengthGetDifferentKeys() {
        let a = content("azote : réponse A")
        let b = content("azote : réponse B")
        XCTAssertEqual(a.text.count, b.text.count)
        let shown = HitKey(docID: 7, page: 1)
        XCTAssertNotEqual(a.renderKey(identity: shown, terms: terms),
                          b.renderKey(identity: shown, terms: terms))
        // Sans page connue, l'empreinte du texte suffit à les distinguer.
        XCTAssertNotEqual(a.renderKey(identity: nil, terms: terms),
                          b.renderKey(identity: nil, terms: terms))
    }

    func testTheSameTextOnAnotherPageGetsItsOwnKey() {
        let card = content("azote")
        XCTAssertNotEqual(card.renderKey(identity: HitKey(docID: 7, page: 1), terms: terms),
                          card.renderKey(identity: HitKey(docID: 7, page: 2), terms: terms))
        XCTAssertNotEqual(card.renderKey(identity: HitKey(docID: 7, page: 1), terms: terms),
                          card.renderKey(identity: HitKey(docID: 8, page: 1), terms: terms))
    }

    /// Stable pour la même page, et sensible aux termes et à la chasse fixe,
    /// comme avant.
    func testTheKeyIsStableAndStillFollowsTermsAndLayout() {
        let shown = HitKey(docID: 7, page: 1)
        let key = content("azote").renderKey(identity: shown, terms: terms)
        XCTAssertEqual(key, content("azote").renderKey(identity: shown, terms: terms))
        XCTAssertNotEqual(key, content("azote").renderKey(identity: shown, terms: []))
        XCTAssertNotEqual(key, content("azote", monospaced: true)
                            .renderKey(identity: shown, terms: terms))
    }
}
