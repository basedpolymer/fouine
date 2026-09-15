// OCRLanguageNamesTests.swift — les noms des langues de reconnaissance
// (audit AP-23, BU-08, BU-09 ; lot UX3). Propriété : A-App.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// Trois défauts relevés dans la même liste, et un test par défaut : un
// identifiant que `Locale` ne connaît pas (« vi-VT », que Vision rend tel
// quel), une capitalisation mot à mot (« Corée Du Sud »), et un tri par code
// qui donnait « Arabe, Arabe najdi, Allemand, Anglais… ».

import XCTest
@testable import FouineApp

final class OCRLanguageNamesTests: XCTestCase {

    private let french = Locale(identifier: "fr")
    private let english = Locale(identifier: "en")

    /// « vi-VT » : le code du Viêt Nam est `VN`, `VT` n'existe pas.
    /// `Locale.localizedString(forIdentifier:)` rend alors `nil`, et la liste
    /// affichait l'identifiant brut, deux fois. La langue seule est vraie.
    func testAnUnknownRegionFallsBackToTheLanguageAlone() {
        XCTAssertEqual(OCRLanguageNames.display(identifier: "vi-VT",
                                                locale: french),
                       "Vietnamien")
        XCTAssertEqual(OCRLanguageNames.display(identifier: "vi-VT",
                                                locale: english),
                       "Vietnamese")
    }

    /// « Corée Du Sud » : seule la PREMIÈRE lettre prend la capitale.
    func testOnlyTheFirstLetterIsCapitalised() {
        XCTAssertEqual(OCRLanguageNames.display(identifier: "ko-KR",
                                                locale: french),
                       "Coréen (Corée du Sud)")
        XCTAssertEqual(OCRLanguageNames.display(identifier: "zh-Hans",
                                                locale: french),
                       "Chinois simplifié")
        XCTAssertEqual(OCRLanguageNames.display(identifier: "ar-SA",
                                                locale: french),
                       "Arabe (Arabie saoudite)")
    }

    func testTheEnglishNamesAreTheSystemOnes() {
        XCTAssertEqual(OCRLanguageNames.display(identifier: "ko-KR",
                                                locale: english),
                       "Korean (South Korea)")
        XCTAssertEqual(OCRLanguageNames.display(identifier: "zh-Hans",
                                                locale: english),
                       "Chinese, Simplified")
    }

    /// Une langue que le système ne connaît pas du tout garde son identifiant :
    /// mieux vaut une ligne obscure qu'une ligne vide.
    func testACompletelyUnknownIdentifierIsKept() {
        XCTAssertEqual(OCRLanguageNames.display(identifier: "xx-YY",
                                                locale: french),
                       "xx-YY")
    }

    /// L'ordre affiché est celui des NOMS, pas celui des codes : par code, le
    /// français donnait « Arabe, Arabe najdi, Allemand, Anglais… ».
    func testTheListIsSortedByDisplayedName() {
        let codes = ["ar-SA", "de-DE", "en-US", "vi-VT", "zh-Hans", "ko-KR"]
        let names = codes
            .map { OCRLanguageNames.display(identifier: $0, locale: french) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        XCTAssertEqual(names.first, "Allemand (Allemagne)")
        XCTAssertEqual(names.dropFirst().first, "Anglais (États-Unis)")
        XCTAssertEqual(names.last, "Vietnamien")
    }
}
