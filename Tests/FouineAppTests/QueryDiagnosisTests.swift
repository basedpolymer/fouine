// QueryDiagnosisTests.swift — ce qui se dit sous le champ (BU-33).
// Propriété : A-App.
//
// Les quatre requêtes du constat, mesurées le 09/09/2026 : trois rendaient
// « 0 page trouvée dans 0 document » ou un résultat trompeur sans un mot, la
// quatrième est une requête ordinaire qui ne doit RIEN déclencher.

import XCTest
@testable import FouineApp

final class QueryDiagnosisTests: XCTestCase {

    func testAnUnclosedQuoteIsNamed() {
        XCTAssertEqual(QueryDiagnosis.describe(text: "\"energie"),
                       String(localized: "A quote is not closed."))
    }

    /// Les guillemets que macOS écrit à la place des guillemets droits (lot
    /// QP1) se comptent de la même façon ; `nom:` et `texte:` sont des préfixes
    /// connus, rien à dire.
    func testTypographicQuotesAndTheNewPrefixesAreRead() {
        XCTAssertEqual(QueryDiagnosis.describe(text: "\u{00AB} energie"),
                       String(localized: "A quote is not closed."))
        XCTAssertNil(QueryDiagnosis.describe(text: "\u{00AB} energie libre \u{00BB}"))
        XCTAssertNil(QueryDiagnosis.describe(text: "\u{201C}energie libre\u{201D}"))
        XCTAssertNil(QueryDiagnosis.describe(text: "nom:rapport texte:azote"))
    }

    /// Le guillemet FERMÉ ne dit rien : c'est une phrase exacte, elle marche.
    func testAClosedQuoteSaysNothing() {
        XCTAssertNil(QueryDiagnosis.describe(text: "\"energie libre\""))
    }

    func testProximityWithoutItsTwoWordsIsNamed() {
        let expected = String(localized: "`near:` expects two words.")
        XCTAssertEqual(QueryDiagnosis.describe(text: "pres:"), expected)
        XCTAssertEqual(QueryDiagnosis.describe(text: "pres: azote"), expected)
        // L'aide du champ annonce `near:` en anglais ; le parseur ne connaît
        // que `pres:`. Les deux se diagnostiquent, sans quoi la moitié des
        // lecteurs de l'aide n'auraient rien en retour.
        XCTAssertEqual(QueryDiagnosis.describe(text: "near:"), expected)
    }

    func testProximityWithItsTwoWordsSaysNothing() {
        XCTAssertNil(QueryDiagnosis.describe(text: "pres:5 azote carbone"))
        XCTAssertNil(QueryDiagnosis.describe(text: "pres: azote carbone"))
    }

    func testAQueryThatOnlyExcludesIsNamed() {
        XCTAssertEqual(QueryDiagnosis.describe(text: "-energie"),
                       String(localized: "A search that only excludes finds nothing."))
        XCTAssertEqual(QueryDiagnosis.describe(text: "-energie -chaleur"),
                       String(localized: "A search that only excludes finds nothing."))
    }

    func testAnExclusionNextToATermSaysNothing() {
        XCTAssertNil(QueryDiagnosis.describe(text: "energie -nucleaire"))
    }

    /// La quatrième requête du constat : une seule lettre. Elle ne trouve rien
    /// et n'a rien de fautif — la ligne ne doit pas se transformer en reproche
    /// permanent pendant la frappe.
    func testAnOrdinaryQuerySaysNothing() {
        XCTAssertNil(QueryDiagnosis.describe(text: "a"))
        XCTAssertNil(QueryDiagnosis.describe(text: ""))
        XCTAssertNil(QueryDiagnosis.describe(text: "   "))
        XCTAssertNil(QueryDiagnosis.describe(text: "energie libre"))
    }
}
