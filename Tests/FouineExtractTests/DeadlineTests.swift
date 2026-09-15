// DeadlineTests.swift — délais de garde sur les appels bloquants (audit F6).
// Propriété : A-Ingest (palier 3, 02/09/2026).
//
// Trois choses à tenir, et rien d'autre :
//   · `Deadline.run` rend la main à l'échéance, même si le corps ne revient
//     jamais — c'est le point entier ;
//   · un dépassement d'extraction devient `.extraction`, pas un gel ni un
//     document silencieusement absent de l'index ;
//   · `BoundedTool` (donc `pmset`) rend `nil` dans son délai au lieu d'attendre
//     indéfiniment un outil qui ne répond pas.

import XCTest
import FouineCore
@testable import FouineExtract

final class DeadlineTests: XCTestCase {

    // MARK: - Mécanique

    func testReturnsTheValueWhenTheBodyIsFastEnough() throws {
        let value = try Deadline.run(seconds: 10, label: "calcul court") { 6 * 7 }
        XCTAssertEqual(value, 42)
    }

    func testPropagatesTheBodyError() {
        struct Boom: Error {}
        XCTAssertThrowsError(
            try Deadline.run(seconds: 10, label: "corps fautif") { throw Boom() }) {
            XCTAssertTrue($0 is Boom, "l'erreur du corps doit passer telle quelle")
        }
    }

    /// L'échéance tombe alors que le corps dort : c'est le cas que tout le
    /// fichier existe pour couvrir.
    func testGivesUpAtTheDeadline() {
        let started = Date()
        XCTAssertThrowsError(
            try Deadline.run(seconds: 0.2, label: "corps qui ne revient pas") {
                Thread.sleep(forTimeInterval: 30)
            }) { error in
            guard let expired = error as? DeadlineExceeded else {
                return XCTFail("attendu DeadlineExceeded, obtenu \(error)")
            }
            XCTAssertTrue(expired.description.contains("deadline exceeded"),
                          expired.description)
        }
        // Rendu SANS attendre les 30 s du corps. Le fil, lui, continue et fuit :
        // c'est documenté dans l'en-tête de Deadline.swift.
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// `onExpiry` est ce par quoi Vision reçoit son `request.cancel()`.
    func testCallsOnExpiryWhenTheDeadlineFalls() {
        let called = Flag()
        XCTAssertThrowsError(
            try Deadline.run(seconds: 0.2, label: "corps lent",
                             onExpiry: { called.raise() }) {
                Thread.sleep(forTimeInterval: 5)
            })
        XCTAssertTrue(called.isRaised)
    }

    func testExtractionTranslatesTheOverrunIntoAFouineError() {
        XCTAssertThrowsError(
            try Deadline.extraction(seconds: 0.2, label: "PDF qui ne revient pas") {
                Thread.sleep(forTimeInterval: 5)
            }) { error in
            guard case FouineError.extraction(let message)? = error as? FouineError
            else { return XCTFail("attendu .extraction, obtenu \(error)") }
            XCTAssertTrue(message.contains("deadline exceeded"), message)
        }
    }

    func testOCRTranslatesTheOverrunIntoAFouineError() {
        XCTAssertThrowsError(
            try Deadline.ocr(seconds: 0.2, label: "rendu qui ne revient pas") {
                Thread.sleep(forTimeInterval: 5)
            }) { error in
            guard case FouineError.ocr(let message)? = error as? FouineError
            else { return XCTFail("attendu .ocr, obtenu \(error)") }
            XCTAssertTrue(message.contains("deadline exceeded"), message)
        }
    }

    // MARK: - Budgets lus dans l'environnement

    func testBudgetsReadTheEnvironmentAndIgnoreNonsense() {
        XCTAssertEqual(
            Deadline.seconds(from: "X", environment: ["X": "12.5"]), 12.5)
        // Une valeur illisible, vide ou négative ne DÉSARME PAS le garde-fou :
        // elle est ignorée et le défaut s'applique.
        for bad in ["", "beaucoup", "0", "-3"] {
            XCTAssertNil(Deadline.seconds(from: "X", environment: ["X": bad]),
                         "« \(bad) » ne doit pas passer pour un budget")
        }
        XCTAssertNil(Deadline.seconds(from: "X", environment: [:]))
    }

    /// Le budget d'un PDF suit sa taille, et reste plafonné.
    func testPDFBudgetGrowsWithPageCountAndIsCapped() {
        let short = Deadline.pdfPagesSeconds(pageCount: 1)
        let long = Deadline.pdfPagesSeconds(pageCount: 1_315)
        XCTAssertGreaterThan(long, short)
        XCTAssertLessThanOrEqual(Deadline.pdfPagesSeconds(pageCount: 100_000), 1_800)
    }

    // MARK: - PDFExtractor, échéance injectée

    /// De bout en bout : `FOUINE_PDF_TIMEOUT` minuscule, un vrai PDF, et
    /// l'extraction rend `.extraction` — donc `docs.err` et un document
    /// `.failed`, la passe continuant (`IndexFault.perDocument`). Ce que le
    /// test tient VRAIMENT, c'est que le dépassement ne remonte pas en erreur
    /// anonyme et ne gèle rien.
    func testPDFExtractionOverrunBecomesAnExtractionError() throws {
        let directory = try Fixtures.temporaryDirectory("pdf-deadline")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("lent.pdf")
        try Fixtures.makePDF(pages: (0..<40).map { Fixtures.filler(marker: "P\($0)") },
                             at: url)

        setenv("FOUINE_PDF_TIMEOUT", "0.001", 1)
        defer { unsetenv("FOUINE_PDF_TIMEOUT") }

        XCTAssertThrowsError(
            try PDFExtractor().extract(url: url, limits: ExtractLimits())) { error in
            guard case FouineError.extraction(let message)? = error as? FouineError
            else { return XCTFail("attendu .extraction, obtenu \(error)") }
            XCTAssertTrue(message.contains("deadline exceeded"), message)
        }
    }

    /// Sans variable, le même PDF s'extrait normalement : le garde-fou ne doit
    /// pas se déclencher sur un document ordinaire.
    func testTheSamePDFExtractsFineWithTheDefaultBudget() throws {
        let directory = try Fixtures.temporaryDirectory("pdf-deadline-ok")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("normal.pdf")
        try Fixtures.makePDF(pages: (0..<40).map { Fixtures.filler(marker: "P\($0)") },
                             at: url)
        let result = try PDFExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 40)
        XCTAssertEqual(result.pages.count, 40)
    }

    // MARK: - BoundedTool (pmset, audit F6)

    /// Le cas exact du correctif : un outil qui ne rend JAMAIS la main. Avant,
    /// `readDataToEndOfFile()` puis `waitUntilExit()` attendaient sans borne.
    func testBoundedToolGivesUpOnAToolThatNeverReturns() {
        // 0,3 s de délai et non 2 : le sémaphore de `Subprocess.run` expire à
        // l'instant demandé et `sleep` meurt au premier SIGTERM — le test
        // prouve la coupure, pas la durée (lot I2).
        let started = Date()
        let output = BoundedTool.text("/bin/sleep", ["100"],
                                      what: "outil factice", timeout: 0.3)
        XCTAssertNil(output, "un outil qui dépasse son délai doit rendre nil")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "le délai de garde n'a pas coupé le processus")
    }

    func testBoundedToolReturnsNilForAMissingTool() {
        XCTAssertNil(BoundedTool.text("/usr/bin/outil-qui-nexiste-pas", [],
                                      what: "outil absent"))
    }

    func testBoundedToolReturnsTheOutputOfARealTool() throws {
        let output = try XCTUnwrap(
            BoundedTool.text("/bin/echo", ["fouine"], what: "écho"))
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines),
                       "fouine")
    }

    /// `pmset -g therm` sur CETTE machine : il répond, et vite. Le test ne juge
    /// pas la valeur (elle dépend de la charge) — seulement qu'on ne reste pas
    /// pendu à l'attendre.
    func testPMSetAnswersWellWithinItsProbeBudget() {
        let started = Date()
        _ = BoundedTool.text("/usr/bin/pmset", ["-g", "therm"],
                             what: "CPU_Speed_Limit")
        XCTAssertLessThan(Date().timeIntervalSince(started),
                          BoundedTool.probeTimeout)
    }

    /// Petit drapeau verrouillé : `onExpiry` est appelé depuis le fil appelant,
    /// mais rien ne l'impose dans le contrat.
    private final class Flag: @unchecked Sendable {
        private let mutex = NSLock()
        private var raised = false
        func raise() { mutex.lock(); raised = true; mutex.unlock() }
        var isRaised: Bool { mutex.lock(); defer { mutex.unlock() }; return raised }
    }
}
