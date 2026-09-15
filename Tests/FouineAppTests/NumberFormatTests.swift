// NumberFormatTests.swift — les nombres affichés se groupent tous pareil
// (BU-07). Propriété : A-App.
//
// Le pied de la carte « Index » a été photographié le 09/09/2026 affichant
// « 1527 documents · 408 951 pages » : deux comptes sur la même ligne, l'un
// groupé et l'autre non, se lisent comme une coquille. Le formateur exige
// désormais le groupement dès quatre chiffres — un compte de documents en a
// presque toujours quatre, un compte de pages presque jamais.
//
// Le séparateur, lui, reste celui de la LOCALE (audit B1-13) : espace fine
// insécable en français, virgule en anglais. C'est pour cela que le test
// compare au séparateur du formateur et non à un caractère écrit en dur.

import XCTest
@testable import FouineApp

final class NumberFormatTests: XCTestCase {

    private func grouped(_ n: Int, _ identifier: String) -> String {
        let f = Format.makeIntegerFormatter(locale: Locale(identifier: identifier))
        return f.string(from: NSNumber(value: n)) ?? "?"
    }

    private func separator(_ identifier: String) -> String {
        Format.makeIntegerFormatter(locale: Locale(identifier: identifier))
            .groupingSeparator ?? "?"
    }

    /// Quatre chiffres et six chiffres se groupent de la MÊME façon, dans les
    /// deux langues de l'application.
    func testFourAndSixDigitsAreGroupedTheSameWay() {
        for identifier in ["fr_FR", "fr_US", "en_US"] {
            let sep = separator(identifier)
            XCTAssertEqual(grouped(1527, identifier), "1\(sep)527", identifier)
            XCTAssertEqual(grouped(408_951, identifier), "408\(sep)951", identifier)
        }
    }

    /// Le séparateur vient de la locale et n'est jamais forcé : un anglophone
    /// lisait « 1 486 739 pages » quand l'espace fine était posée en dur.
    func testTheSeparatorComesFromTheLocale() {
        XCTAssertEqual(separator("en_US"), ",")
        XCTAssertEqual(grouped(1527, "en_US"), "1,527")
        // Français : une espace, fine ou insécable selon la version du système.
        let french = separator("fr_FR")
        XCTAssertTrue(["\u{202F}", "\u{00A0}", "\u{2009}", " "].contains(french),
                      "séparateur français inattendu : \(french.unicodeScalars.map { $0.value })")
    }

    /// Sous mille, aucun séparateur : « 1 » et non « 1 » suivi de rien.
    func testNoSeparatorBelowAThousand() {
        XCTAssertEqual(grouped(999, "fr_FR"), "999")
        XCTAssertEqual(grouped(0, "en_US"), "0")
    }
}
