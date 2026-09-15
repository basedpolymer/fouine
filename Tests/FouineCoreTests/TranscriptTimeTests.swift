// TranscriptTimeTests.swift — le moment d'un extrait de transcription (lot MC2,
// constat PM-22). Propriété : A-Core.
//
// Ce qui est prouvé : le marqueur retenu est le DERNIER qui précède le mot
// trouvé (celui du paragraphe qui le porte), le texte de la page prend le
// relais quand l'extrait n'en a pas, et ce qui n'est pas un horodatage n'en
// devient pas un — un `[voir p. 12]` ne doit pas citer une vidéo à la douzième
// seconde.

import XCTest
@testable import FouineCore

final class TranscriptTimeTests: XCTestCase {

    func testLeMarqueurRetenuEstLeDernierAvantLeMotTrouve() throws {
        let snippet = "[00:10] du solveur [12:40] charger la «commande» soldeur"
        XCTAssertEqual(TranscriptTime.seconds(inSnippet: snippet, opening: "«"),
                       12 * 60 + 40)
    }

    func testUnMarqueurApresLeMotNeCompteJamais() throws {
        let snippet = "[00:10] la «commande» [12:40] plus tard"
        XCTAssertEqual(TranscriptTime.seconds(inSnippet: snippet, opening: "«"), 10)
    }

    /// `marks: "none"` : sans marqueur de surlignage, on lit le dernier
    /// horodatage de l'extrait — c'est tout ce qu'on peut honnêtement dire.
    func testSansMarqueurDeSurlignageOnLitLeDernierDeLExtrait() throws {
        let snippet = "[00:10] un [01:00] deux"
        XCTAssertEqual(TranscriptTime.seconds(inSnippet: snippet, opening: ""), 60)
    }

    func testUnExtraitSansHorodatageNeRendRien() throws {
        XCTAssertNil(TranscriptTime.seconds(inSnippet: "la «commande» soldeur",
                                            opening: "«"))
    }

    func testLeDebutDeLaPagePrendLeRelais() throws {
        XCTAssertEqual(TranscriptTime.first(in: "[00:01] Dans cette video je vais"), 1)
        XCTAssertNil(TranscriptTime.first(in: "une page sans horodatage"))
    }

    /// La forme exacte de `MediaMetadata.timestamp` : `MM:SS`, et `H:MM:SS`
    /// au-delà d'une heure (l'heure n'est pas complétée à deux chiffres).
    func testLesDeuxFormesDeLHorodatage() throws {
        XCTAssertEqual(TranscriptTime.parse("00:00"), 0)
        XCTAssertEqual(TranscriptTime.parse("09:05"), 545)
        XCTAssertEqual(TranscriptTime.parse("1:02:03"), 3_723)
        XCTAssertEqual(TranscriptTime.parse("10:59:59"), 39_599)
    }

    func testCeQuiNEstPasUnHorodatageNEnDevientPasUn() throws {
        for token in ["voir p. 12", "1", "99:99", "1:2:3", "12:345", "ab:cd", ""] {
            XCTAssertNil(TranscriptTime.parse(token), token)
        }
        XCTAssertNil(TranscriptTime.seconds(inSnippet: "[voir p. 12] la «loi»",
                                            opening: "«"))
    }
}
