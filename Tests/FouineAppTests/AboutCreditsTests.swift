// AboutCreditsTests.swift — « À propos » mène quelque part (BU-28).
// Propriété : A-App.
//
// La licence de Fouine promet un code lisible ; MIT et Apache-2.0 demandent que
// leurs notices accompagnent le logiciel. Trois liens le tiennent, et l'ordre compte :
// la licence de Fouine d'abord, les composants tiers ensuite, le code source
// enfin. Le test lit les liens du texte attribué, pas son apparence.

import XCTest
import AppKit
@testable import FouineApp

final class AboutCreditsTests: XCTestCase {

    private func links(_ credits: NSAttributedString) -> [URL] {
        var found: [URL] = []
        credits.enumerateAttribute(.link,
                                   in: NSRange(location: 0, length: credits.length)) { value, _, _ in
            if let url = value as? URL { found.append(url) }
        }
        return found
    }

    func testThreeLinksInOrder() throws {
        let licence = URL(fileURLWithPath: "/Applications/Fouine.app/Contents/Resources/LICENSE")
        let thirdParty = URL(fileURLWithPath:
            "/Applications/Fouine.app/Contents/Resources/THIRD_PARTY_LICENSES.md")
        let source = try XCTUnwrap(URL(string: "https://github.com/basedpolymer/fouine"))

        let credits = AboutCredits.attributed(licenseURL: licence,
                                              thirdPartyURL: thirdParty,
                                              sourceURL: source)
        XCTAssertEqual(links(credits), [licence, thirdParty, source])
    }

    func testTheLinesAreThereAndSayWhereTheDocumentsStay() {
        let credits = AboutCredits.attributed(
            licenseURL: nil, thirdPartyURL: nil, sourceURL: AboutCredits.sourceRepository)
        let text = credits.string
        // LI1 : « source-available », et surtout pas un nom de licence libre —
        // le panneau est la seule surface où l'utilisateur lit ce qu'il a acheté.
        XCTAssertTrue(text.contains("Source-available licence"), text)
        XCTAssertFalse(text.contains("AGPL"), text)
        XCTAssertTrue(text.contains("Read the licence"), text)
        XCTAssertTrue(text.contains("Third-party components"), text)
        XCTAssertTrue(text.contains("Source code"), text)
        XCTAssertTrue(text.contains("nothing leaves it"), text)
    }

    /// Hors bundle, les deux fichiers n'existent pas : les lignes restent du
    /// texte. Un lien mort dans « À propos » serait pire que pas de lien.
    func testWithoutTheBundledFilesOnlyTheSourceLinkRemains() {
        let credits = AboutCredits.attributed(
            licenseURL: nil, thirdPartyURL: nil, sourceURL: AboutCredits.sourceRepository)
        XCTAssertEqual(links(credits), [AboutCredits.sourceRepository])
    }

    func testTheSourceRepositoryIsThePublicOne() {
        XCTAssertEqual(AboutCredits.sourceRepository.absoluteString,
                       "https://github.com/basedpolymer/fouine")
    }
}
