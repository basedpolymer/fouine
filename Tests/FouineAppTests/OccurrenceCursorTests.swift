// OccurrenceCursorTests.swift — d'une occurrence à la suivante (PN1).
// Propriété : A-App.
//
// Ce que ces tests protègent : ⌘G parcourt les occurrences de la page DANS
// L'ORDRE OÙ ON LES LIT (y décroissant en coordonnées PDF, puis x croissant),
// boucle au bout, et les pastilles de l'en-tête comptent avec la règle du
// surlignage — sans quoi le nombre annoncé et les couleurs à l'écran
// divergeraient.

import XCTest
import CoreGraphics
@testable import FouineApp

final class OccurrenceCursorTests: XCTestCase {

    private func occurrence(_ id: Int, x: CGFloat, y: CGFloat,
                            height: CGFloat = 12, termIndex: Int = 0)
        -> OccurrenceCursor.Occurrence {
        .init(term: "azote", termIndex: termIndex,
              rect: CGRect(x: x, y: y, width: 40, height: height), id: id)
    }

    // MARK: - L'ordre de lecture

    /// Deux lignes, trois colonnes, données dans le désordre : haut vers bas
    /// puis gauche vers droite. Sur la première ligne, un mot en capitales
    /// monte plus haut que ses voisins sans passer devant celui de gauche.
    func testReadingOrderTwoLinesThreeColumns() {
        let unordered = [
            occurrence(5, x: 450, y: 680),
            occurrence(1, x: 250, y: 700, height: 15),   // « AZOTE », plus haut
            occurrence(3, x: 50, y: 680),
            occurrence(2, x: 450, y: 700),
            occurrence(0, x: 50, y: 700),
            occurrence(4, x: 250, y: 681),
        ]
        let cursor = OccurrenceCursor(unordered)
        XCTAssertEqual(cursor.occurrences.map(\.id), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(cursor.position, 1, "le curseur part de la première")
        XCTAssertEqual(cursor.current?.id, 0)
    }

    /// Une page TOURNÉE se lit dans son sens d'affichage (lot MN2). Mêmes
    /// quatre rectangles, en coordonnées de page non tournée — 0 : (50, 700),
    /// 1 : (300, 700), 2 : (50, 400), 3 : (300, 400) —, et l'ordre attendu
    /// écrit à la main pour chaque rotation horaire :
    ///   · 90° : le bord gauche monte en haut, le bas passe à gauche ;
    ///   · 180° : tout s'inverse ;
    ///   · 270° : le bord droit monte en haut, le haut passe à gauche.
    func testReadingOrderFollowsThePageRotation() {
        let rects = [
            occurrence(0, x: 50, y: 700, height: 20),
            occurrence(1, x: 300, y: 700, height: 20),
            occurrence(2, x: 50, y: 400, height: 20),
            occurrence(3, x: 300, y: 400, height: 20),
        ]
        let expected: [(rotation: Int, order: [Int])] = [
            (0, [0, 1, 2, 3]),
            (90, [2, 0, 3, 1]),
            (180, [3, 2, 1, 0]),
            (270, [1, 3, 0, 2]),
            (-90, [1, 3, 0, 2]),     // PDFKit peut rendre un angle négatif
            (450, [2, 0, 3, 1]),
        ]
        for (rotation, order) in expected {
            XCTAssertEqual(OccurrenceCursor(rects.shuffled(), rotation: rotation)
                            .occurrences.map(\.id), order, "rotation \(rotation)")
        }
    }

    // MARK: - Le parcours

    func testNextAndPreviousWrapWithinThePage() {
        var cursor = OccurrenceCursor([
            occurrence(0, x: 50, y: 700),
            occurrence(1, x: 50, y: 600),
            occurrence(2, x: 50, y: 500),
        ])
        XCTAssertEqual(cursor.next()?.id, 1)
        XCTAssertEqual(cursor.next()?.id, 2)
        XCTAssertEqual(cursor.next()?.id, 0, "après la dernière, la première")
        XCTAssertEqual(cursor.position, 1)
        XCTAssertEqual(cursor.previous()?.id, 2, "avant la première, la dernière")
        XCTAssertEqual(cursor.position, 3)
        XCTAssertEqual(cursor.previous()?.id, 1)
        XCTAssertEqual(cursor.count, 3)
    }

    func testEmptyCursorOffersNothing() {
        var cursor = OccurrenceCursor()
        XCTAssertTrue(cursor.isEmpty)
        XCTAssertNil(cursor.current)
        XCTAssertNil(cursor.position)
        XCTAssertNil(cursor.next())
        XCTAssertNil(cursor.previous())
        XCTAssertNil(cursor.currentIndex)
        XCTAssertEqual(cursor.countsByTerm, [:])
    }

    func testCountsByTerm() {
        let cursor = OccurrenceCursor([
            occurrence(0, x: 50, y: 700, termIndex: 0),
            occurrence(1, x: 50, y: 600, termIndex: 1),
            occurrence(2, x: 50, y: 500, termIndex: 0),
            occurrence(3, x: 50, y: 400, termIndex: 2),
            occurrence(4, x: 50, y: 300, termIndex: 0),
        ])
        XCTAssertEqual(cursor.countsByTerm, [0: 3, 1: 1, 2: 1])
    }

    // MARK: - Les comptes de l'aperçu texte

    /// Deux termes et des frontières de mot : « azote » ne compte ni
    /// « azotée » ni « azotés » — l'apostrophe, elle, est une frontière
    /// (« l'azote »). La casse ne compte pas. `azote*`, préfixe, les prend tous.
    ///
    /// « azoté » compterait, lui : la règle est celle du tokenizer
    /// (`remove_diacritics 2`), qui ne distingue pas é de e.
    ///
    /// Termes construits à la main : `QueryTerms.extract` ajouterait les
    /// pluriels (« azotes », « nitrates », lot R1), et le test ne prouverait
    /// plus la frontière de mot.
    func testTextCountsHonourTokenBoundaries() {
        let text = "L'azote, l'azotée et les azotés. AZOTE et nitrate ; nitrates."
        let terms = [
            HighlightTerm(text: "azote", folded: "azote", kind: .word, colorIndex: 0),
            HighlightTerm(text: "nitrate", folded: "nitrate", kind: .word, colorIndex: 1),
        ]
        let counts = OccurrenceTally.counts(in: text, terms: terms)
        XCTAssertEqual(counts.byTerm, [0: 2, 1: 1])
        XCTAssertEqual(counts.capped, [])

        let prefix = [HighlightTerm(text: "azote", folded: "azote", kind: .prefix,
                                    colorIndex: 0)]
        XCTAssertEqual(OccurrenceTally.counts(in: text, terms: prefix).byTerm, [0: 4])
    }

    /// Le plafond borne le parcours et se DIT : la pastille annonce « 3+ ».
    func testTextCountsStopAtTheLimitAndSaySo() {
        let terms = [HighlightTerm(text: "azote", folded: "azote", kind: .word,
                                   colorIndex: 0)]
        let counts = OccurrenceTally.counts(in: "azote azote azote azote",
                                            terms: terms, limit: 3)
        XCTAssertEqual(counts.byTerm, [0: 3])
        XCTAssertEqual(counts.capped, [0])
        let chips = OccurrenceTally.chips(terms: terms, counts: counts)
        XCTAssertEqual(chips.map(\.atLeast), [true])
    }

    // MARK: - Les pastilles

    /// Une pastille par couleur, sous le mot tapé ; un terme absent de la page
    /// n'en a pas.
    func testChipsGroupByColourAndSkipAbsentTerms() {
        let terms = [
            HighlightTerm(text: "polymere", folded: "polymere", kind: .word, colorIndex: 0),
            HighlightTerm(text: "polymeres", folded: "polymeres", kind: .word, colorIndex: 0),
            HighlightTerm(text: "azote", folded: "azote", kind: .word, colorIndex: 1),
            HighlightTerm(text: "urée", folded: "uree", kind: .word, colorIndex: 2),
        ]
        let chips = OccurrenceTally.chips(
            terms: terms, counts: .init(byTerm: [0: 2, 1: 3, 3: 1]))
        XCTAssertEqual(chips, [
            .init(label: "polymere", colorIndex: 0, count: 5, atLeast: false),
            .init(label: "urée", colorIndex: 2, count: 1, atLeast: false),
        ])
    }
}
