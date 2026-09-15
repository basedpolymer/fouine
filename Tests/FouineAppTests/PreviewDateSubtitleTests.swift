// PreviewDateSubtitleTests.swift — « · daté du 12 avril 2003 » sous le titre de
// l'aperçu (lot DD1, constat PR-07). Propriété : A-App.
//
// Ce qui est protégé ici : la règle du 1ᵉʳ janvier. Une année seule lue dans un
// EPUB (« 2003 ») est écrite en base au 1ᵉʳ janvier ; l'afficher comme « daté du
// 1ᵉʳ janvier 2003 » inventerait une précision que le document ne porte pas, et
// c'est le genre de détail qu'on recopie ensuite de bonne foi dans une
// référence.

import XCTest
import FouineCore
@testable import FouineApp

@MainActor
final class PreviewDateSubtitleTests: XCTestCase {

    private func date(_ raw: String) throws -> Double {
        try XCTUnwrap(DocumentDate.parse(raw))
    }

    func testADocumentWithoutADateKeepsThePathAlone() {
        XCTAssertEqual(PreviewModel.subtitle(path: "Livres/Chimie", docDate: nil),
                       "Livres/Chimie")
    }

    func testAFullDateIsSpelledOut() throws {
        let subtitle = PreviewModel.subtitle(path: "Livres/Chimie",
                                             docDate: try date("2003-04-12"))
        XCTAssertTrue(subtitle.hasPrefix("Livres/Chimie · "), subtitle)
        // Le jour est cité en toutes lettres, dans la langue de l'utilisateur :
        // on vérifie l'année et le jour, pas le nom du mois (qui change avec la
        // langue du système où tourne le test).
        XCTAssertTrue(subtitle.contains("2003"), subtitle)
        XCTAssertTrue(subtitle.contains("12"), subtitle)
    }

    /// LE test de la règle : « 2003 » nu ne devient pas « 1ᵉʳ janvier 2003 ».
    func testAYearOnlyDateIsShownAsAYear() throws {
        let subtitle = PreviewModel.subtitle(path: "Livres", docDate: try date("2003"))
        XCTAssertTrue(subtitle.contains("2003"), subtitle)
        XCTAssertFalse(subtitle.contains("1"), subtitle)
    }

    /// Un mois sans jour tombe au premier du mois, qui n'est PAS le 1ᵉʳ janvier :
    /// la date se dit alors en entier, jour compris. C'est assumé — la colonne
    /// ne porte pas la précision d'origine, et seule l'ambiguïté de l'année
    /// méritait une règle.
    func testAMonthOnlyDateKeepsItsDay() throws {
        let subtitle = PreviewModel.subtitle(path: "Livres", docDate: try date("2003-04"))
        XCTAssertTrue(subtitle.contains("2003"), subtitle)
        XCTAssertNotEqual(subtitle, "Livres")
    }
}
