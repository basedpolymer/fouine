// JobsCapTests.swift — plafond de `--jobs` (audit X1). Propriété : A-Core.

import XCTest
@testable import FouineCore

final class JobsCapTests: XCTestCase {

    /// Une demande hors plafond est TRONQUÉE, jamais refusée — et l'utilisateur
    /// apprend pourquoi, sans quoi il croit à une limitation arbitraire.
    func testExtractJobsAreCappedWithAnExplanation() {
        var messages: [String] = []
        XCTAssertEqual(JobsCap.clampExtract(16, log: { messages.append($0) }), 4)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("--jobs 16 capped to 4"), messages[0])
        XCTAssertTrue(messages[0].contains("PDFKit"), messages[0])
        XCTAssertTrue(messages[0].contains("bsdtar"), messages[0])
    }

    /// Dans le plafond : rien n'est dit, rien n'est changé.
    func testJobsInsideTheCapAreLeftAloneAndSilent() {
        var messages: [String] = []
        for jobs in 1...JobsCap.extractMaxJobs {
            XCTAssertEqual(JobsCap.clampExtract(jobs, log: { messages.append($0) }),
                           jobs)
        }
        XCTAssertTrue(messages.isEmpty, "\(messages)")
    }

    /// `--jobs 0` et les négatifs remontent à 1 : une file de concurrence 0 ne
    /// traiterait rien du tout.
    func testNonPositiveJobsBecomeOne() {
        var messages: [String] = []
        XCTAssertEqual(JobsCap.clampExtract(0, log: { messages.append($0) }), 1)
        XCTAssertEqual(JobsCap.clampExtract(-3, log: { messages.append($0) }), 1)
        XCTAssertEqual(messages.count, 2)
    }

    func testExtractCapIsFour() {
        XCTAssertEqual(JobsCap.extractMaxJobs, 4)
    }
}
