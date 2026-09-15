// SourceDocumentTests.swift — un fichier recopié se reconnaît à son
// emplacement, et se nomme comme dans son application (lot AN2).
// Propriété : A-Ingest.

import Foundation
import XCTest
import FouineCore
@testable import FouineIndex

final class SourceDocumentTests: XCTestCase {

    private let locator = SourceDocumentLocator(
        sourcesRelPath: "/Users/léa/Library/Application Support/Fouine/Sources/")
    private let base = "Users/léa/Library/Application Support/Fouine/Sources"

    /// Un paquet Anki : le nom du paquet, et ses paquets parents pour fil
    /// d'Ariane — ce que la liste montre à la place du fichier et du chemin.
    func testAnAnkiDeckIsNamedAndPlacedLikeInAnki() throws {
        let deck = try XCTUnwrap(locator.document(
            relPath: base + "/Anki/M2SU 2026/625 Physico-chimie macromoléculaire.md"))
        XCTAssertEqual(deck.sourceID, "anki")
        XCTAssertEqual(deck.title, "625 Physico-chimie macromoléculaire")
        XCTAssertEqual(deck.folders, ["M2SU 2026"])
        XCTAssertEqual(deck.breadcrumb, "Anki › M2SU 2026")
        XCTAssertTrue(deck.isAnkiDeck)
        XCTAssertEqual(deck.source?.displayName, "Anki")

        let top = try XCTUnwrap(locator.document(relPath: base + "/Anki/Default.md"))
        XCTAssertEqual(top.breadcrumb, "Anki")
        // Un volume et un tiret gardent leur nom : Anki n'a pas de suffixe.
        XCTAssertEqual(locator.document(relPath: base + "/Anki/A/Step 1 (2).md")?.title,
                       "Step 1 (2)")
        XCTAssertEqual(locator.document(relPath: base + "/Anki/Bio-chimie-2026.md")?.title,
                       "Bio-chimie-2026")
    }

    /// Notes et Bear : le suffixe d'identifiant du nom de fichier s'en va, un
    /// tiret du titre reste.
    func testANoteLosesItsIdentifierSuffixOnly() throws {
        let note = try XCTUnwrap(locator.document(
            relPath: base + "/Notes/Rendez-vous chez le notaire-8C3F1A2B.md"))
        XCTAssertEqual(note.title, "Rendez-vous chez le notaire")
        XCTAssertEqual(note.breadcrumb, "Notes")
        XCTAssertFalse(note.isAnkiDeck)
        XCTAssertEqual(locator.document(relPath: base + "/Bear/Idées-B1.md")?.title, "Idées")
        XCTAssertEqual(locator.document(relPath: base + "/Bear/Rendez-vous-9F2E77A0.md")?.title,
                       "Rendez-vous")
        XCTAssertEqual(locator.document(relPath: base + "/Notes/Plan-2026-09.md")?.title,
                       "Plan-2026", "le dernier segment seul")
        XCTAssertEqual(locator.document(relPath: base + "/Notes/Bilan -é.md")?.title,
                       "Bilan", "une lettre accentuée est une lettre")
        XCTAssertEqual(locator.document(relPath: base + "/Notes/Mot-trèslongsuffixe.md")?.title,
                       "Mot-trèslongsuffixe", "plus long qu'un suffixe : c'est le titre")
    }

    /// Ce qui n'est PAS une copie de Fouine reste un document ordinaire, même
    /// quand il y ressemble — c'est tout l'objet de décider par l'emplacement.
    func testOnlyFilesInsideASourceFolderAreCopies() {
        let refused = [
            "Users/léa/Documents/Anki/Organique.md",             // un export à soi
            base + "/Anki.md",                                     // pas dans un dossier de source
            base + "/Anki/Organique.pdf",                          // pas un fichier recopié
            base + "/Autre/Organique.md",                          // source inconnue
            base + "/anki/Organique.md",                           // la casse compte
            base + "/Anki/.md",
            "Users/léa/Library/Application Support/Fouine/SourcesX/Anki/a.md",
            base,
        ]
        for path in refused {
            XCTAssertNil(locator.document(relPath: path), path)
        }
    }

    /// Les chemins de la base sont en NFC ; un chemin décomposé (celui d'un
    /// système de fichiers) se reconnaît pareil, et le localisateur accepte
    /// un chemin absolu.
    func testNormalizationAndAbsolutePrefix() throws {
        let decomposed = (base + "/Anki/Géo.md").decomposedStringWithCanonicalMapping
        XCTAssertEqual(locator.document(relPath: decomposed)?.title,
                       "Géo".precomposedStringWithCanonicalMapping)
        XCTAssertEqual(locator.sourcesRelPath, base)
    }

    /// La racine d'une source se reconnaît à son chemin, pas à son étiquette :
    /// un dossier à soi nommé « Anki » n'en est pas une.
    func testTheRootOfASourceIsItsFolder() {
        XCTAssertEqual(locator.source(rootRelPath: base + "/Anki")?.id, "anki")
        XCTAssertEqual(locator.source(rootRelPath: base + "/Notes")?.id, "notes")
        XCTAssertEqual(locator.source(rootRelPath: base + "/Bear")?.id, "bear")
        XCTAssertNil(locator.source(rootRelPath: "Users/léa/Anki"))
        XCTAssertNil(locator.source(rootRelPath: base))
        XCTAssertNil(locator.source(rootRelPath: base + "/Anki/M2SU 2026"))
    }

    /// Chaque source nomme son application : l'icône et le bouton en dépendent.
    func testEverySourceNamesItsApplication() {
        for source in AppSources.all {
            XCTAssertFalse(source.bundleIdentifiers.isEmpty, source.id)
        }
        XCTAssertEqual(AnkiSource().bundleIdentifiers, AnkiSource.bundleIdentifiers)
        // Par l'existentiel : la version d'Anki, pas celle par défaut (le piège
        // de répartition statique du lot AN1).
        let anki: any AppSource = AnkiSource()
        XCTAssertEqual(anki.documentTitle(fileStem: "Bio-chimie"), "Bio-chimie")
        let notes: any AppSource = AppleNotesSource()
        XCTAssertEqual(notes.documentTitle(fileStem: "Bio-chimie"), "Bio")
    }
}
