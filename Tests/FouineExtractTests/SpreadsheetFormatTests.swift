// SpreadsheetFormatTests.swift — la valeur affichée d'une cellule (C2-07).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Ingest, cible de test uniquement.
//
// La table de rendu, sans archive ni bsdtar : ce sont ces quelques lignes qui
// décident si « 05/03/2026 » se cherche ou pas.

import XCTest
@testable import FouineExtract

final class SpreadsheetFormatTests: XCTestCase {

    /// `xl/styles.xml` tel qu'openpyxl l'écrit : un format personnalisé (164)
    /// et deux prédéfinis.
    private let styles = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <numFmts count="1">
            <numFmt numFmtId="164" formatCode="#,##0.00\\ &quot;€&quot;"/>
          </numFmts>
          <cellXfs count="4">
            <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
            <xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
            <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
            <xf numFmtId="22" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
          </cellXfs>
        </styleSheet>
        """.utf8)

    private func format(date1904: Bool = false) -> SpreadsheetFormat {
        let workbook = Data("""
            <workbook><workbookPr date1904="\(date1904 ? "1" : "0")"/></workbook>
            """.utf8)
        return SpreadsheetFormat.parse(styles: styles, workbook: workbook)
    }

    // MARK: - Ce que l'utilisateur voit dans Excel

    func testTheThreeCasesOfTheAudit() {
        let format = self.format()
        // Une date : la cellule affiche 05/01/2026, le fichier porte 46027.
        XCTAssertEqual(format.rendered("46027", styleIndex: 1), "05/01/2026")
        XCTAssertEqual(format.rendered("46086", styleIndex: 1), "05/03/2026")
        // Un montant au format monétaire français.
        XCTAssertEqual(format.rendered("1512.5", styleIndex: 2), "1 512,50")
        XCTAssertEqual(format.rendered("775", styleIndex: 2), "775,00")
        // Une cellule SANS format : rien à rendre, la valeur brute suffit.
        XCTAssertNil(format.rendered("775", styleIndex: 0))
        XCTAssertNil(format.rendered("775", styleIndex: nil))
        // Un style hors table (fichier abîmé) ne fabrique rien.
        XCTAssertNil(format.rendered("775", styleIndex: 99))
        // Une valeur non numérique non plus.
        XCTAssertNil(format.rendered("Échantillon", styleIndex: 1))
    }

    func testDateAndTimeTogether() {
        // numFmtId 22 = « m/d/yy h:mm » : date ET heure.
        XCTAssertEqual(format().rendered("46027.5", styleIndex: 3),
                       "05/01/2026 12:00")
    }

    /// La convention Mac (1904) décale tout de quatre ans : un classeur écrit
    /// sur un vieux Excel Mac ne doit pas dater ses factures de 2022.
    func testTheNineteenOhFourConvention() {
        XCTAssertEqual(format(date1904: true).rendered("44565", styleIndex: 1),
                       "05/01/2026")
    }

    // MARK: - La famille d'un format

    func testWhichFormatsAreRendered() {
        XCTAssertEqual(SpreadsheetFormat.kind(formatCode: "dd/mm/yyyy"),
                       .dateTime(date: true, hours: false))
        XCTAssertEqual(SpreadsheetFormat.kind(formatCode: "hh:mm"),
                       .dateTime(date: true, hours: true),
                       "« mm » sans « yy » reste de la famille date/heure")
        XCTAssertEqual(SpreadsheetFormat.kind(formatCode: "#,##0.00"),
                       .decimal(places: 2, grouped: true))
        XCTAssertEqual(SpreadsheetFormat.kind(formatCode: "0.000"),
                       .decimal(places: 3, grouped: false))
        // Un littéral entre guillemets n'est pas un motif : le « m » de
        // « 0.00" m" » est un mètre, pas un mois.
        XCTAssertEqual(SpreadsheetFormat.kind(formatCode: "0.00\" m\""),
                       .decimal(places: 2, grouped: false))
        // Hors périmètre, assumé : pourcentages, fractions, scientifique.
        XCTAssertNil(SpreadsheetFormat.kind(formatCode: "0.00%"))
        XCTAssertNil(SpreadsheetFormat.kind(formatCode: "@"))
        XCTAssertNil(SpreadsheetFormat.kind(formatCode: "General"))
    }

    func testPredefinedFormats() {
        XCTAssertEqual(SpreadsheetFormat.kind(numFmtId: 14, custom: nil),
                       .dateTime(date: true, hours: false))
        XCTAssertEqual(SpreadsheetFormat.kind(numFmtId: 4, custom: nil),
                       .decimal(places: 2, grouped: true))
        XCTAssertNil(SpreadsheetFormat.kind(numFmtId: 0, custom: nil))
        XCTAssertNil(SpreadsheetFormat.kind(numFmtId: 9, custom: nil))
    }

    /// Sans `styles.xml`, le comportement est celui d'avant le correctif : la
    /// valeur brute, et rien d'autre.
    func testAWorkbookWithoutStylesRendersNothing() {
        let empty = SpreadsheetFormat.parse(styles: nil, workbook: nil)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(empty.rendered("46027", styleIndex: 1))
    }

    // MARK: - Les briques

    func testDecimalText() {
        XCTAssertEqual(SpreadsheetFormat.decimalText(1512.5, places: 2,
                                                     grouped: true), "1 512,50")
        XCTAssertEqual(SpreadsheetFormat.decimalText(1_234_567.0, places: 0,
                                                     grouped: true), "1 234 567")
        XCTAssertEqual(SpreadsheetFormat.decimalText(-98.4, places: 2,
                                                     grouped: false), "-98,40")
        XCTAssertEqual(SpreadsheetFormat.decimalText(775, places: 0,
                                                     grouped: false), "775")
    }

    func testCivilCalendar() {
        let day = SpreadsheetFormat.civil(fromDays: 0)
        XCTAssertEqual(day.year, 1970)
        XCTAssertEqual(day.month, 1)
        XCTAssertEqual(day.day, 1)
        let leap = SpreadsheetFormat.civil(fromDays: 19_782)   // 29/02/2024
        XCTAssertEqual([leap.day, leap.month, leap.year], [29, 2, 2024])
    }
}
