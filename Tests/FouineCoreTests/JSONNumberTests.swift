// JSONNumberTests.swift — tests des nombres JSON propres (audit H4, palier 5).
// Propriété : A-Core. SPEC §4.3.

import XCTest
import FouineCore

final class JSONNumberTests: XCTestCase {

    func testDecimalSerializationRendersExactDecimalsWithoutBinaryFloatArtifacts() throws {
        // En Double IEEE 754, 16.63 produit 16.629999999999999
        let problematicDouble: Double = 16.63
        let roundedDecimal = JSONNumber.rounded(problematicDouble, places: 2)

        let payload: [String: Any] = [
            "semantic_coverage_pct": roundedDecimal,
            "cosine": JSONNumber.rounded(0.8567, places: 3),
            "rrf": JSONNumber.rounded(0.016393, places: 6),
            "elapsed_ms": JSONNumber.rounded(42.10, places: 2)
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let jsonString = String(decoding: data, as: UTF8.self)

        // 16.63 doit être présent exactement, et 16.629999 doit être totalement absent des octets
        XCTAssertTrue(jsonString.contains("\"semantic_coverage_pct\":16.63"),
                      "Attendu 16.63 dans la sortie JSON, obtenu: \(jsonString)")
        XCTAssertFalse(jsonString.contains("16.629999"),
                       "16.629999 ne doit jamais transparaître dans le JSON: \(jsonString)")

        // Autres nombres
        XCTAssertTrue(jsonString.contains("\"cosine\":0.857"))
        XCTAssertTrue(jsonString.contains("\"rrf\":0.016393"))
        XCTAssertTrue(jsonString.contains("\"elapsed_ms\":42.1"))
    }

    func testSpecialCases() {
        XCTAssertEqual(JSONNumber.rounded(Double.nan), NSDecimalNumber.zero)
        XCTAssertEqual(JSONNumber.rounded(Double.infinity), NSDecimalNumber.zero)
        XCTAssertEqual(JSONNumber.rounded(-Double.infinity), NSDecimalNumber.zero)
    }
}
