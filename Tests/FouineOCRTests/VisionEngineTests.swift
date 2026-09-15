// VisionEngineTests.swift — VisionOCREngine (SPEC §6.2). Propriété : A-OCR.
//
// Aucune fixture réelle ici : le texte est DESSINÉ en mémoire par CoreText, ce qui
// rend le test reproductible sur n'importe quelle machine et n'ouvre rien du corpus.

import XCTest
import CoreGraphics
import FouineCore
@testable import FouineOCR

final class VisionEngineTests: XCTestCase {

    private static let engine = VisionOCREngine()
    /// Préchauffage UNE fois pour toute la classe : 8,5 s mesurées au premier
    /// `.accurate` d'un processus (§2.6), inutile de les payer par test.
    private static var warmed = false

    private func warmEngine() throws -> VisionOCREngine {
        if !Self.warmed {
            try Self.engine.prewarm()
            Self.warmed = true
        }
        return Self.engine
    }

    // MARK: - Identité

    func testEngineIdentity() {
        let engine = VisionOCREngine()
        XCTAssertEqual(engine.id, .vision)
        XCTAssertEqual(engine.revision, "vision-rev3")
        XCTAssertEqual(VisionOCREngine.defaultLanguages, ["fr-FR", "en-US"])
    }

    // MARK: - Reconnaissance

    /// Le test de fond : du texte synthétique doit ressortir, avec une confiance
    /// utilisable et des boîtes normalisées.
    func testRecognizesSyntheticText() throws {
        let engine = try warmEngine()
        let image = try OCRTestSupport.textImage(
            width: 900, height: 1200,
            lines: [("CHIMIE ORGANIQUE tellurium equilibre", CGPoint(x: 40, y: 600))])

        let page = try engine.recognize(image, level: .accurate,
                                        languages: VisionOCREngine.defaultLanguages,
                                        customWords: ["tellurium", "equilibre"])
        let text = page.text.lowercased()
        XCTAssertTrue(text.contains("chimie"), "texte reconnu : \(page.text)")
        XCTAssertTrue(text.contains("organique"), "texte reconnu : \(page.text)")
        XCTAssertTrue(text.contains("tellurium"), "texte reconnu : \(page.text)")
        XCTAssertTrue(text.contains("equilibre") || text.contains("équilibre"),
                      "texte reconnu : \(page.text)")

        XCTAssertGreaterThan(page.meanConfidence, 0.5)
        XCTAssertEqual(page.level, .accurate)
        XCTAssertEqual(page.engine, .vision)
        XCTAssertEqual(page.engineRev, "vision-rev3")
        XCTAssertGreaterThan(page.seconds, 0)
        XCTAssertFalse(page.lines.isEmpty)

        for line in page.lines {
            XCTAssertTrue((0...1).contains(line.x), "x hors [0,1] : \(line.x)")
            XCTAssertTrue((0...1).contains(line.y), "y hors [0,1] : \(line.y)")
            XCTAssertTrue((0...1).contains(line.w), "w hors [0,1] : \(line.w)")
            XCTAssertTrue((0...1).contains(line.h), "h hors [0,1] : \(line.h)")
            XCTAssertTrue((0...1).contains(line.confidence))
            XCTAssertLessThanOrEqual(line.x + line.w, 1.001)
            XCTAssertLessThanOrEqual(line.y + line.h, 1.001)
        }
    }

    /// Convention de coordonnées : origine EN BAS À GAUCHE (§4.1, annexe B).
    /// Le mot dessiné en HAUT de l'image doit avoir le y le PLUS ÉLEVÉ. Si cette
    /// assertion tombe, `ocr_layout` surligne la mauvaise moitié de la page et le
    /// JSONL de l'annexe B est incompatible avec ce qu'il annonce.
    func testBoundingBoxOriginIsBottomLeft() throws {
        let engine = try warmEngine()
        // Contexte CoreGraphics : y croît vers le HAUT. « SOMMET » est donc en haut.
        let image = try OCRTestSupport.textImage(
            width: 900, height: 1200,
            lines: [("SOMMET", CGPoint(x: 60, y: 1080)),
                    ("PLANCHER", CGPoint(x: 60, y: 90))])

        let page = try engine.recognize(image, level: .accurate,
                                        languages: VisionOCREngine.defaultLanguages,
                                        customWords: [])
        let summit = page.lines.first { $0.text.uppercased().contains("SOMMET") }
        let floor = page.lines.first { $0.text.uppercased().contains("PLANCHER") }
        let recognized = page.lines.map(\.text).joined(separator: " / ")
        XCTAssertNotNil(summit, "« SOMMET » non reconnu : \(recognized)")
        XCTAssertNotNil(floor, "« PLANCHER » non reconnu : \(recognized)")
        guard let summit, let floor else { return }

        XCTAssertGreaterThan(summit.y, 0.7,
                             "la ligne du haut doit avoir un y ÉLEVÉ : \(summit.y)")
        XCTAssertLessThan(floor.y, 0.3,
                          "la ligne du bas doit avoir un y FAIBLE : \(floor.y)")
        XCTAssertGreaterThan(summit.y, floor.y)
    }

    /// Le seuil de confiance ne retient QUE les lignes au-dessus, mais `lines`
    /// porte TOUTES les lignes — sinon le surlignage devient partiel (§6.2).
    func testConfidenceThresholdFiltersTextButNotLayout() throws {
        let engine = try warmEngine()
        let image = try OCRTestSupport.textImage(
            width: 700, height: 300,
            lines: [("Markovnikov", CGPoint(x: 40, y: 140))])

        let previous = VisionOCREngine.confidenceThreshold
        defer { VisionOCREngine.confidenceThreshold = previous }

        // Seuil impossible : plus aucune ligne ne peut entrer dans page_fts.
        VisionOCREngine.confidenceThreshold = 1.5
        let filtered = try engine.recognize(image, level: .accurate,
                                            languages: VisionOCREngine.defaultLanguages,
                                            customWords: [])
        XCTAssertFalse(filtered.lines.isEmpty, "ocr_layout doit rester complet")
        XCTAssertEqual(filtered.text, "")
        XCTAssertEqual(filtered.meanConfidence, 0,
                       "aucune ligne retenue -> conf moyenne nulle (§6.2)")

        // Seuil nominal : la ligne repasse.
        VisionOCREngine.confidenceThreshold = previous
        let kept = try engine.recognize(image, level: .accurate,
                                        languages: VisionOCREngine.defaultLanguages,
                                        customWords: [])
        XCTAssertTrue(kept.text.lowercased().contains("markovnikov"),
                      "texte reconnu : \(kept.text)")
        XCTAssertGreaterThan(kept.meanConfidence, 0)
    }

    /// Le préchauffage doit être idempotent et silencieux : il est appelé une fois
    /// par processus, mais un appel de trop ne doit rien casser.
    func testPrewarmIsRepeatable() throws {
        let engine = try warmEngine()
        XCTAssertNoThrow(try engine.prewarm())
    }

    func testPrewarmImageIsGray() {
        let image = VisionOCREngine.prewarmImage()
        XCTAssertEqual(image.colorSpace?.model, .monochrome)
        XCTAssertLessThanOrEqual(image.width * image.height, 64 * 64)
    }
}
