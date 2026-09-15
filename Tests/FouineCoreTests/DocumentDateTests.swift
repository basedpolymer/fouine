// DocumentDateTests.swift — l'analyse d'une date de métadonnée (lot DD1,
// constat PR-07). Propriété : A-Core.
//
// Ce qui est prouvé ici : chaque format que les extracteurs rencontrent, les
// bornes qui écartent les valeurs de remplissage des producteurs de PDF, et le
// REFUS de deviner — « 12/04/2003 » n'est analysé par personne.

import XCTest
@testable import FouineCore

final class DocumentDateTests: XCTestCase {

    /// Une date de référence : rien dans ces tests ne doit dépendre de l'heure
    /// qu'il est ni du fuseau de la machine.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15

    private func civil(_ raw: String) -> String? {
        guard let seconds = DocumentDate.parse(raw, now: now) else { return nil }
        let c = DocumentDate.civil(seconds)
        return String(format: "%04d-%02d-%02d", c.year, c.month, c.day)
    }

    // MARK: - Un format, un test

    func testISO8601InItsFourWidths() {
        XCTAssertEqual(civil("2003-04-12"), "2003-04-12")
        XCTAssertEqual(civil("2003-04-12T10:30:00Z"), "2003-04-12")
        XCTAssertEqual(civil("2003-04-12T23:59:59+02:00"), "2003-04-12")
        // Une année ou un mois seuls désignent leur PREMIER jour : c'est la
        // seule lecture qui n'invente rien (voir `PreviewModel.dateNote`).
        XCTAssertEqual(civil("2003-04"), "2003-04-01")
        XCTAssertEqual(civil("2003"), "2003-01-01")
    }

    func testPDFCreationDate() {
        XCTAssertEqual(civil("D:20030412103000+02'00'"), "2003-04-12")
        XCTAssertEqual(civil("D:20030412"), "2003-04-12")
        // Sans le préfixe `D:`, tel que certains producteurs l'écrivent.
        XCTAssertEqual(civil("20030412103000"), "2003-04-12")
    }

    func testRFC5322EmailHeader() {
        XCTAssertEqual(civil("Sat, 12 Apr 2003 10:30:00 +0200"), "2003-04-12")
        XCTAssertEqual(civil("12 Apr 2003 10:30:00 -0700"), "2003-04-12")
        // Année à deux chiffres de la RFC 822, encore émise par de vieux
        // clients : la fenêtre [1950, 2049] est celle de la norme.
        XCTAssertEqual(civil("Mon, 3 Jan 94 09:00:00 +0000"), "1994-01-03")
    }

    func testEXIFDateTimeOriginal() {
        XCTAssertEqual(civil("2003:04:12 10:30:00"), "2003-04-12")
    }

    // MARK: - Ce qui est refusé

    /// LE refus qui compte : rien ne dit si « 12/04/2003 » est le 12 avril ou
    /// le 4 décembre, et une date fausse range le document sous une année qui
    /// n'est pas la sienne sans que personne puisse s'en apercevoir.
    func testAnAmbiguousDayFirstDateIsRefused() {
        XCTAssertNil(DocumentDate.parse("12/04/2003", now: now))
        XCTAssertNil(DocumentDate.parse("04/12/2003", now: now))
        XCTAssertNil(DocumentDate.parse("12.04.2003", now: now))
        XCTAssertNil(DocumentDate.parse("12 avril 2003", now: now))
    }

    func testTheBoundsRejectFillerValues() {
        // La valeur de remplissage la plus répandue des producteurs de PDF.
        XCTAssertNil(DocumentDate.parse("D:19000101000000", now: now))
        XCTAssertNil(DocumentDate.parse("1899-12-31", now: now))
        XCTAssertNil(DocumentDate.parse("1900-01-01", now: now),
                     "le 1ᵉʳ janvier 1900 EST la valeur de remplissage")
        XCTAssertEqual(civil("1900-01-02"), "1900-01-02", "le lendemain passe")
        // Une horloge fausse au moment de la production.
        XCTAssertNil(DocumentDate.parse("2099-01-01", now: now))
        // Demain reste plausible (fuseau en avance), après-demain non.
        XCTAssertNotNil(DocumentDate.parse("2027-01-16", now: now))
        XCTAssertNil(DocumentDate.parse("2027-01-17", now: now))
    }

    func testMalformedStringsAreRefused() {
        for raw in ["", "   ", "unknown", "D:", "0000-00-00", "2003-13-01",
                    "2003-02-30", "2003-04-1", "203-04-12", "٢٠٠٣-٠٤-١٢"] {
            XCTAssertNil(DocumentDate.parse(raw, now: now), raw)
        }
    }

    // MARK: - Un jour, pas un instant

    /// La valeur écrite est MIDI UTC, et c'est ce qui garantit que l'année
    /// rendue par `strftime('%Y', …, 'unixepoch')` — sans `'localtime'` — est
    /// la même à Honolulu qu'à Auckland.
    func testTheValueIsNoonUTC() throws {
        let seconds = try XCTUnwrap(DocumentDate.parse("2003-04-12", now: now))
        XCTAssertEqual(seconds.truncatingRemainder(dividingBy: 86_400), 43_200)
        XCTAssertEqual(DocumentDate.year(seconds), 2003)
        // Un fuseau à ±12 h ne fait pas changer le jour.
        let day = 86_400.0
        XCTAssertEqual(DocumentDate.civil(seconds + day / 2 - 1).day, 12)
        XCTAssertEqual(DocumentDate.civil(seconds - day / 2 + 1).day, 12)
    }

    func testLeapYearsAndCenturies() {
        XCTAssertEqual(civil("2000-02-29"), "2000-02-29")
        XCTAssertNil(DocumentDate.parse("1900-02-29", now: now), "1900 n'est pas bissextile")
        XCTAssertNil(DocumentDate.parse("2003-02-29", now: now))
    }

    /// `isoDay` sert aux extracteurs dont l'API rend un `Date` (PDFKit).
    func testISODayOfAnInstant() {
        let utc = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(DocumentDate.isoDay(Date(timeIntervalSince1970: 1_050_148_800),
                                           timeZone: utc), "2003-04-12")
        // Et la boucle se referme : ce que `isoDay` écrit, `parse` le relit.
        let raw = DocumentDate.isoDay(Date(timeIntervalSince1970: 1_050_148_800),
                                      timeZone: utc)
        XCTAssertEqual(civil(raw), "2003-04-12")
    }
}
