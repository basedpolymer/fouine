// CitationTests.swift — la référence à coller (lot INT-L1). Propriété : A-App.

import XCTest
import FouineCore
@testable import FouineApp

final class CitationTests: XCTestCase {

    private let link = DeepLink.page(absolutePath: "/Users/moi/Cours/chimie.pdf",
                                     page: 87)

    /// DEUX lignes, et le lien SEUL sur la seconde : Mail, Notes et Word ne
    /// rendent cliquable une URL que lorsqu'elle n'a rien après elle.
    func testTheReferenceIsTwoLinesWithTheLinkAlone() {
        let text = Citation.reference(fileName: "chimie.pdf", page: 87, link: link)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("chimie.pdf"))
        XCTAssertTrue(lines[0].contains("87"))
        XCTAssertEqual(lines[1], link.absoluteString)
    }

    /// « page » est traduit — c'est le seul mot de la référence, et il est vu
    /// par quelqu'un qui lit dans sa langue. Le lien, lui, ne l'est jamais :
    /// c'est une adresse.
    func testTheWordPageComesFromTheCatalogue() {
        let text = Citation.reference(fileName: "a.pdf", page: 3, link: link)
        XCTAssertEqual(text.components(separatedBy: "\n").first,
                       String(localized: "\("a.pdf"), page \(3)"))
    }

    /// UNE PAGE D'ENREGISTREMENT SE CITE PAR SON MOMENT (lot PV1) : « page 2 »
    /// d'un cours de deux heures ne renvoie personne nulle part, et le lien qui
    /// suit porte le même moment.
    func testARecordingIsCitedByItsMomentAndNotByItsPage() {
        let link = DeepLink.page(absolutePath: "/Users/moi/Cours/chimie.m4a",
                                 page: 2, time: 760)
        let text = Citation.reference(fileName: "chimie.m4a", timestamp: "12:40",
                                      link: link)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("12:40"), lines[0])
        XCTAssertFalse(lines[0].lowercased().contains("page"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("t=760"), lines[1])
    }

    func testTheLinkAloneIsJustTheURL() {
        XCTAssertEqual(Citation.linkOnly(link), link.absoluteString)
        XCTAssertTrue(Citation.linkOnly(link).hasPrefix("fouine://open?path="))
    }

    // MARK: - AP-26 : les parenthèses d'un titre d'ouvrage

    /// Un ouvrage universitaire sur deux range son année entre parenthèses.
    /// `urlQueryAllowed` les laisse passer telles quelles, et les détecteurs
    /// d'adresses de Mail, Notes, Pages et Word coupent une URL sur une
    /// parenthèse fermante — le lien collé cessait d'être cliquable.
    func testParenthesesAreEscapedInTheCopiedLink() {
        let link = DeepLink.page(
            absolutePath: "/Users/moi/Livres/Guymont - cristallographie (2003).pdf",
            page: 25)
        let copied = Citation.linkOnly(link)
        XCTAssertFalse(copied.contains("("))
        XCTAssertFalse(copied.contains(")"))
        XCTAssertTrue(copied.contains("%282003%29"))
    }

    /// Et l'aller-retour tient : `URLComponents` relit `%28`/`%29` comme des
    /// parenthèses, la page rouvre au bon endroit.
    func testTheEscapedLinkStillReopensTheSamePage() throws {
        let path = "/Users/moi/Livres/Guymont - cristallographie (2003).pdf"
        let copied = Citation.linkOnly(DeepLink.page(absolutePath: path, page: 25))
        let read = try XCTUnwrap(DeepLink(url: try XCTUnwrap(URL(string: copied))))
        XCTAssertEqual(read, .open(target: .path(path), page: 25, query: nil))
    }

    /// Ce qui est collé doit se relire : c'est tout le contrat du lot.
    func testTheCopiedLinkReopensTheSamePage() throws {
        let text = Citation.reference(fileName: "chimie.pdf", page: 87, link: link)
        let last = try XCTUnwrap(text.components(separatedBy: "\n").last)
        let read = try XCTUnwrap(DeepLink(url: try XCTUnwrap(URL(string: last))))
        XCTAssertEqual(read, .open(target: .path("/Users/moi/Cours/chimie.pdf"),
                                   page: 87, query: nil))
    }
}
