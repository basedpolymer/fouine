// LicenseTermsTests.swift — le relais de rechange des essais (lot LC2).
//
// `FOUINE_LICENSE_RELAY` remplace l'adresse contactée : une clé achetée voyage
// dans ce corps, d'où la règle — `https://`, ou `http://127.0.0.1:<port>`.

import XCTest
@testable import FouineLicense

final class LicenseTermsTests: XCTestCase {

    private func resolved(_ value: String?) -> URL {
        LicenseTerms.resolvedRelayURL(
            environment: value.map { [LicenseTerms.relayVariable: $0] } ?? [:])
    }

    func testWithoutTheVariableTheRealRelayIsContacted() {
        XCTAssertEqual(resolved(nil), LicenseTerms.defaultRelayURL)
        XCTAssertEqual(resolved(""), LicenseTerms.defaultRelayURL)
        XCTAssertEqual(LicenseTerms.defaultRelayURL.absoluteString,
                       "https://basedpolymer.eu/api/fouine/license")
    }

    func testAnHTTPSRelayAndTheLocalLoopbackWithAPortAreAccepted() {
        XCTAssertEqual(resolved("https://preview.example.test/api/fouine/license").absoluteString,
                       "https://preview.example.test/api/fouine/license")
        XCTAssertEqual(resolved("http://127.0.0.1:8790").absoluteString,
                       "http://127.0.0.1:8790")
        XCTAssertEqual(resolved("http://127.0.0.1:8790/api/fouine/license").absoluteString,
                       "http://127.0.0.1:8790/api/fouine/license")
    }

    /// Tout le reste retombe sur le vrai relais : une clé ne part pas en clair
    /// vers une autre machine.
    func testEverythingElseIsRefused() {
        for refused in ["http://example.com/license",       // en clair, ailleurs
                        "http://localhost:8790",            // un `hosts` peut mentir
                        "http://127.0.0.1",                 // sans port
                        "http://127.0.0.2:8790",
                        "file:///tmp/license.json",
                        "ftp://127.0.0.1:21",
                        "127.0.0.1:8790",
                        "not a url at all"] {
            XCTAssertNil(LicenseTerms.acceptedRelayURL(refused), refused)
            XCTAssertEqual(resolved(refused), LicenseTerms.defaultRelayURL, refused)
        }
    }
}
