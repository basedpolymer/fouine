// PreviewRoutingTests.swift — par quelle voie chaque format se montre
// (lot PV1). Propriété : A-App.
//
// La décision vivait dans `PreviewModel.resolveFile`, en six conditions
// imbriquées qu'aucun test ne pouvait interroger sans base ni fichier. Elle est
// pure depuis ce lot, et c'est ce fichier qui l'éprouve.

import XCTest
@testable import FouineApp

final class PreviewRoutingTests: XCTestCase {

    /// Les cinq voies, une par famille.
    func testEachFamilyTakesItsOwnRoute() {
        XCTAssertEqual(PreviewRouting.route(ext: "pdf"), .pdf)
        // Page rendue en image : archives de bandes dessinées, Office, images,
        // maquettes.
        for ext in ["cbz", "docx", "xlsx", "png", "fig"] {
            XCTAssertEqual(PreviewRouting.route(ext: ext), .image, ext)
        }
        for ext in ["mp3", "m4a", "mp4", "mkv"] {
            XCTAssertEqual(PreviewRouting.route(ext: ext), .media, ext)
        }
        // Le système DESSINE ces formats : le document d'abord.
        for ext in ["rtf", "doc", "pages", "key", "html", "csv", "odt", "svg"] {
            XCTAssertEqual(PreviewRouting.route(ext: ext), .quickLook, ext)
        }
        // Il n'en montrerait que l'icône, ou que les mêmes caractères : le
        // texte indexé d'abord.
        for ext in ["epub", "djvu", "txt", "md", "ipynb", "srt", "mbox", "tex"] {
            XCTAssertEqual(PreviewRouting.route(ext: ext), .text, ext)
        }
    }

    /// Une extension arrive telle que le système l'a écrite.
    func testTheExtensionIsComparedInLowercase() {
        XCTAssertEqual(PreviewRouting.route(ext: "PDF"), .pdf)
        XCTAssertEqual(PreviewRouting.route(ext: "RTF"), .quickLook)
        XCTAssertEqual(PreviewRouting.route(ext: "MP3"), .media)
    }

    /// Un format inconnu de Fouine ne se montre pas par le Coup d'œil : rien
    /// ne dit que le système saurait le dessiner.
    func testAnUnknownExtensionShowsTheIndexedText() {
        XCTAssertEqual(PreviewRouting.route(ext: "xyz"), .text)
        XCTAssertEqual(PreviewRouting.route(ext: ""), .text)
    }

    /// Le mode proposé d'emblée suit le format — jusqu'à ce que quelqu'un
    /// choisisse, et ce choix vaut alors pour tous.
    @MainActor
    func testTheChosenModeWinsOverTheFormatDefault() {
        let memory = PreviewModeMemory()
        XCTAssertEqual(memory.mode(for: .quickLook), .document)
        XCTAssertEqual(memory.mode(for: .text), .text)
        memory.choice = .text
        XCTAssertEqual(memory.mode(for: .quickLook), .text)
        memory.choice = .document
        XCTAssertEqual(memory.mode(for: .text), .document)
    }
}
