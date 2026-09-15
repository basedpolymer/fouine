// SubtitleAndNotebookTests.swift — srt, vtt, ipynb (SPEC §5.3, R-14).
// Propriété : A-Ingest.

import XCTest
import FouineCore
@testable import FouineExtract

final class SubtitleExtractorTests: XCTestCase {

    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("subtitles")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func testSRTExtraction() throws {
        let srtContent = """
        1
        00:01:02,345 --> 00:01:05,678
        <i>Première</i> réplique &amp; sous-titre

        2
        00:01:06,000 --> 00:01:08,500
        Deuxième réplique
        sur deux lignes

        3
        00:01:09,000 --> 00:01:10,000
        {\\an8}Troisième réplique
        """
        let url = file("film.srt")
        try Data(srtContent.utf8).write(to: url)

        let result = try SubtitleExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pages.count, 1)
        let text = try XCTUnwrap(result.pages.first).text

        // Les chiffres d'horodatage doivent être ABSENTS du texte
        XCTAssertFalse(text.contains("00:01:02"), text)
        XCTAssertFalse(text.contains("345"), text)
        XCTAssertFalse(text.contains("00:01:05"), text)
        XCTAssertFalse(text.contains("678"), text)
        XCTAssertFalse(text.contains("-->"), text)

        // Les balises doivent être retirées
        XCTAssertFalse(text.contains("<i>"), text)
        XCTAssertFalse(text.contains("</i>"), text)
        XCTAssertFalse(text.contains("{\\an8}"), text)

        // L'entité HTML doit être décodée
        XCTAssertTrue(text.contains("Première réplique & sous-titre"), text)

        // Une réplique sur plusieurs lignes est assemblée en une seule ligne
        XCTAssertTrue(text.contains("Deuxième réplique sur deux lignes"), text)
        XCTAssertTrue(text.contains("Troisième réplique"), text)

        // Ordre des répliques préservé
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "Première réplique & sous-titre")
        XCTAssertEqual(lines[1], "Deuxième réplique sur deux lignes")
        XCTAssertEqual(lines[2], "Troisième réplique")
    }

    func testVTTExtractionWithHeaderNotesPositionAndDuplicates() throws {
        let vttContent = """
        WEBVTT - Transcription de cours

        NOTE
        Commentaire technique
        sur plusieurs lignes à ignorer

        cue-intro
        00:00:01.000 --> 00:00:03.000 align:start line:0%
        <c.yellow>Introduction au cours</c>

        00:00:03.000 --> 00:00:05.000
        Introduction au cours

        00:00:05.000 --> 00:00:08.000
        Partie suivante &lt;suite&gt;
        """
        let url = file("cours.vtt")
        try Data(vttContent.utf8).write(to: url)

        let result = try SubtitleExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pages.count, 1)
        let text = try XCTUnwrap(result.pages.first).text

        // WEBVTT et NOTE absents
        XCTAssertFalse(text.contains("WEBVTT"), text)
        XCTAssertFalse(text.contains("Commentaire technique"), text)

        // Horodatages et réglages de position absents
        XCTAssertFalse(text.contains("00:00:01"), text)
        XCTAssertFalse(text.contains("-->"), text)
        XCTAssertFalse(text.contains("align:start"), text)
        XCTAssertFalse(text.contains("line:0%"), text)
        XCTAssertFalse(text.contains("cue-intro"), text)

        // Balise <c.yellow> nettoyée et entités décodées
        XCTAssertFalse(text.contains("<c.yellow>"), text)
        XCTAssertTrue(text.contains("Partie suivante <suite>"), text)

        // Les répliques consécutives identiques doivent être fusionnées
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "Introduction au cours")
        XCTAssertEqual(lines[1], "Partie suivante <suite>")
    }

    func testEmptySubtitleFileThrowsNamedError() throws {
        let emptySRT = file("empty.srt")
        try Data().write(to: emptySRT)
        XCTAssertThrowsError(try SubtitleExtractor().extract(url: emptySRT, limits: ExtractLimits())) { error in
            guard case let FouineError.extraction(msg) = error else {
                return XCTFail("Attendu FouineError.extraction, obtenu \(error)")
            }
            XCTAssertTrue(msg.contains("empty subtitle file"), msg)
        }

        let emptyVTT = file("empty.vtt")
        try Data("WEBVTT\n\nNOTE commentaire seulement\n".utf8).write(to: emptyVTT)
        XCTAssertThrowsError(try SubtitleExtractor().extract(url: emptyVTT, limits: ExtractLimits())) { error in
            guard case let FouineError.extraction(msg) = error else {
                return XCTFail("Attendu FouineError.extraction, obtenu \(error)")
            }
            XCTAssertTrue(msg.contains("empty subtitle file"), msg)
        }
    }
}

final class NotebookExtractorTests: XCTestCase {

    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("notebooks")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func testThreeCellNotebookWithCodeAndIgnoredOutputs() throws {
        let json: [String: Any] = [
            "nbformat": 4,
            "nbformat_minor": 2,
            "metadata": ["language": "python"],
            "cells": [
                [
                    "cell_type": "markdown",
                    "source": "# Analyse de Fourier\nIntroduction aux séries de Fourier.",
                ],
                [
                    "cell_type": "code",
                    "execution_count": 1,
                    "source": [
                        "import numpy as np\n",
                        "x = np.linspace(0, 1, 100)\n",
                        "print(x.shape)",
                    ],
                    "outputs": [
                        [
                            "output_type": "stream",
                            "name": "stdout",
                            "text": ["(100,)\nSortie volumineuse rejetee"],
                        ],
                    ],
                ],
                [
                    "cell_type": "raw",
                    "source": [
                        "Donnees brutes experimentales",
                        "Deuxieme ligne brute",
                    ],
                ],
            ],
        ]

        let url = file("analyse.ipynb")
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: url)

        let result = try NotebookExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pages.count, 1)
        let text = try XCTUnwrap(result.pages.first).text

        // Markdown et source du code conservés
        XCTAssertTrue(text.contains("Analyse de Fourier"), text)
        XCTAssertTrue(text.contains("import numpy as np"), text)
        XCTAssertTrue(text.contains("print(x.shape)"), text)
        XCTAssertTrue(text.contains("Donnees brutes experimentales"), text)

        // Les sorties (outputs) sont délibérément ignorées
        XCTAssertFalse(text.contains("Sortie volumineuse rejetee"), text)
        XCTAssertFalse(text.contains("(100,)"), text)
    }

    func testNotebookWithoutCellsThrowsNamedError() throws {
        let json: [String: Any] = [
            "metadata": ["kernelspec": ["name": "python3"]],
        ]
        let url = file("no_cells.ipynb")
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: url)

        XCTAssertThrowsError(try NotebookExtractor().extract(url: url, limits: ExtractLimits())) { error in
            guard case let FouineError.extraction(msg) = error else {
                return XCTFail("Attendu FouineError.extraction, obtenu \(error)")
            }
            XCTAssertTrue(msg.contains("not a Jupyter notebook"), msg)
        }
    }

    func testInvalidJSONThrowsNamedError() throws {
        let url = file("invalide.ipynb")
        try Data("ceci n'est pas du json".utf8).write(to: url)

        XCTAssertThrowsError(try NotebookExtractor().extract(url: url, limits: ExtractLimits())) { error in
            guard case let FouineError.extraction(msg) = error else {
                return XCTFail("Attendu FouineError.extraction, obtenu \(error)")
            }
            XCTAssertTrue(msg.contains("not a Jupyter notebook"), msg)
        }
    }
}
