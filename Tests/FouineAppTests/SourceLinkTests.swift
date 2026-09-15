// SourceLinkTests.swift — quel bouton l'aperçu propose, et vers quoi
// (lot INT-F4). Propriété : A-App.
//
// Une vue ne se teste pas ; le CHOIX qu’elle affiche, si. `SourceOpenTarget`
// est ce choix, sous forme de fonction pure : le document recopié que désigne
// l'emplacement (lot AN2), le nom du fichier, sa tête, un cas en sortie.

import Foundation
import XCTest
import FouineIndex
@testable import FouineApp

final class SourceLinkTests: XCTestCase {

    private let materialized = """
        <!-- fouine-source: notes -->
        <!-- fouine-open: notes://showNote?identifier=A1B2 -->
        # Rendez-vous

        chez maître Dupont
        """

    // MARK: - L'en-tête d'une note recopiée

    func testHeaderCarriesTheSourceAndTheLink() {
        XCTAssertEqual(SourceLinks.sourceID(inMarkdown: materialized), "notes")
        XCTAssertEqual(SourceLinks.openURL(inMarkdown: materialized)?.absoluteString,
                       "notes://showNote?identifier=A1B2")
    }

    /// Un document ordinaire qui parlerait de `fouine-open:` au milieu de sa
    /// prose ne doit pas se faire passer pour une note.
    func testMarkerIsOnlyReadInTheFirstLines() {
        let text = String(repeating: "du texte ordinaire\n", count: 10)
            + "<!-- fouine-open: notes://showNote?identifier=X -->"
        XCTAssertNil(SourceLinks.openURL(inMarkdown: text))
        XCTAssertNil(SourceLinks.sourceID(inMarkdown: "une note sans en-tête"))
    }

    /// Les deux commentaires techniques disparaissent À L'AFFICHAGE ; un texte
    /// ordinaire, lui, n'est pas touché.
    func testHeaderIsStrippedForDisplayOnly() {
        let visible = SourceLinks.strippingHeader(materialized)
        XCTAssertTrue(visible.hasPrefix("# Rendez-vous"))
        XCTAssertFalse(visible.contains("fouine-open"))
        let ordinary = "# Un titre\n\ndu texte"
        XCTAssertEqual(SourceLinks.strippingHeader(ordinary), ordinary)
    }

    // MARK: - Les exports de Notion

    func testNotionIdentifierComesFromTheFileName() {
        let name = "Compte rendu de réunion 1a2b3c4d5e6f7890abcdef1234567890.md"
        XCTAssertEqual(SourceLinks.notionPageID(forFileName: name),
                       "1a2b3c4d5e6f7890abcdef1234567890")
        XCTAssertEqual(SourceLinks.notionURL(forFileName: name)?.absoluteString,
                       "notion://www.notion.so/1a2b3c4d5e6f7890abcdef1234567890")
        // Ni 32 caractères, ni hexadécimal : ce n'est pas un export Notion, et
        // proposer « Ouvrir dans Notion » ouvrirait une page inexistante.
        XCTAssertNil(SourceLinks.notionPageID(forFileName: "Cours de chimie.md"))
        XCTAssertNil(SourceLinks.notionPageID(forFileName: "Notes 1a2b3c4d.md"))
    }

    // MARK: - Le bouton de l'aperçu

    private let notesCopy = SourceDocument(sourceID: "notes", rootLabel: "Notes",
                                           title: "Rendez-vous", folders: [])
    private let ankiCopy = SourceDocument(sourceID: "anki", rootLabel: "Anki",
                                          title: "Organique", folders: ["Chimie"])

    /// Une note recopiée : le lien vient de l'en-tête de SON fichier.
    func testACopiedNoteOpensItsOwnLink() {
        let target = SourceOpenTarget.from(document: notesCopy,
                                           fileName: "Rendez-vous-A1B2.md",
                                           fileHead: materialized)
        XCTAssertEqual(target, .notes(URL(string: "notes://showNote?identifier=A1B2")!))
        XCTAssertEqual(target?.label, "Open in Notes")

        let bear = materialized
            .replacingOccurrences(of: "fouine-source: notes",
                                  with: "fouine-source: bear")
            .replacingOccurrences(of: "notes://showNote?identifier=A1B2",
                                  with: "bear://x-callback-url/open-note?id=B1")
        let bearCopy = SourceDocument(sourceID: "bear", rootLabel: "Bear",
                                      title: "n", folders: [])
        XCTAssertEqual(SourceOpenTarget.from(document: bearCopy, fileName: "n.md",
                                             fileHead: bear),
                       .bear(URL(string: "bear://x-callback-url/open-note?id=B1")!))
    }

    /// L'EMPLACEMENT DÉCIDE (lot AN2). Un `.md` hors du dossier des copies qui
    /// se déclare « notes » n'a pas de bouton ; une copie dont le lien n'est pas
    /// du schéma de son application non plus ; ni un en-tête d'une autre source.
    func testAForgedHeaderGetsNoButton() {
        let forged = materialized.replacingOccurrences(
            of: "notes://showNote?identifier=A1B2", with: "file:///tmp/autre.app")
        XCTAssertNil(SourceOpenTarget.from(document: nil, fileName: "Rendez-vous.md",
                                           fileHead: materialized),
                     "un fichier d'une racine ordinaire n'est pas une note recopiée")
        XCTAssertNil(SourceOpenTarget.from(document: notesCopy, fileName: "x.md",
                                           fileHead: forged))
        let otherSource = materialized.replacingOccurrences(
            of: "fouine-source: notes", with: "fouine-source: bear")
        XCTAssertNil(SourceOpenTarget.from(document: notesCopy, fileName: "x.md",
                                           fileHead: otherSource))
        XCTAssertNil(SourceOpenTarget.from(document: notesCopy, fileName: "x.md",
                                           fileHead: nil))
    }

    /// Un paquet Anki recopié n'a pas de lien (Anki pour Mac n'en offre pas) :
    /// le bouton ouvre l'application INSTALLÉE, retrouvée par son identifiant,
    /// et disparaît quand Anki n'est pas là — sans repli vers le Finder.
    func testAnkiDeckOpensTheInstalledApplication() {
        let app = URL(fileURLWithPath: "/Applications/Anki.app")
        let target = SourceOpenTarget.from(document: ankiCopy, fileName: "Organique.md",
                                           fileHead: nil, ankiApplication: { app })
        XCTAssertEqual(target, .anki(app))
        XCTAssertEqual(target?.label, "Open in Anki")
        XCTAssertEqual(SourceOpenTarget.label(forSource: "anki"), "Open in Anki")
        XCTAssertNil(SourceOpenTarget.from(document: ankiCopy, fileName: "Organique.md",
                                           fileHead: nil, ankiApplication: { nil }))
        // Le lien éventuel d'un fichier qui se dit « anki » n'est pas suivi.
        let forged = "<!-- fouine-source: anki -->\n<!-- fouine-open: file:///tmp/autre.app -->\n"
        XCTAssertEqual(SourceOpenTarget.from(document: ankiCopy, fileName: "x.md",
                                             fileHead: forged,
                                             ankiApplication: { app }), .anki(app))
        // Hors du dossier des copies, « anki » en tête ne donne rien.
        XCTAssertNil(SourceOpenTarget.from(document: nil, fileName: "x.md",
                                           fileHead: forged, ankiApplication: { app }))
    }

    func testNotionExportGetsItsButtonAndAnythingElseGetsNone() {
        let name = "Réunion 1a2b3c4d5e6f7890abcdef1234567890.md"
        XCTAssertEqual(
            SourceOpenTarget.from(document: nil, fileName: name, fileHead: "du texte"),
            .notion(URL(string: "notion://www.notion.so/1a2b3c4d5e6f7890abcdef1234567890")!))
        // Un PDF qui porterait par hasard trente-deux hexadécimaux reste un PDF.
        XCTAssertNil(SourceOpenTarget.from(
            document: nil, fileName: "Rapport 1a2b3c4d5e6f7890abcdef1234567890.pdf",
            fileHead: nil))
        XCTAssertNil(SourceOpenTarget.from(document: nil, fileName: "Cours.md",
                                           fileHead: "du texte"))
    }

    // MARK: - Le nom, le fil d'Ariane, l'unité (lot AN2)

    /// Une carte se compte, se cite et se feuillette en cartes ; tout autre
    /// document garde ses pages, au caractère près.
    func testCardsAreCountedAndCitedAsCards() {
        XCTAssertEqual(PageUnit.page.short(12), "p. 12")
        XCTAssertEqual(PageUnit.card.short(12), "card 12")
        XCTAssertEqual(PageUnit.card.position(3, of: 642), "card 3 of 642")
        XCTAssertEqual(PageUnit.page.position(3, of: 642), "page 3 of 642")
        XCTAssertEqual(PageUnit.card.single(1), "card 1")
        XCTAssertEqual(Citation.label(fileName: "Organique", page: 12, unit: .card),
                       "Organique, card 12")
        XCTAssertEqual(Citation.label(fileName: "chimie.pdf", page: 87),
                       "chimie.pdf, page 87")

        let complete = PageCountAffordance.decide(loaded: 1, matched: 1,
                                                  scopedToThisDocument: false)
        // Les clés à pluriel ne passent pas par le catalogue dans le bundle de
        // tests : on vérifie la clé, pas son accord.
        XCTAssertEqual(complete.label(unit: .card), "1 card(s)")
        XCTAssertEqual(complete.label, complete.label(unit: .page))
        let gesture = PageCountAffordance.decide(loaded: 3, matched: 74,
                                                 scopedToThisDocument: false)
        XCTAssertEqual(gesture.label(unit: .card), "3 of 74 cards · See them all")
        XCTAssertEqual(PageCountAffordance.decide(loaded: 74, matched: nil,
                                                  scopedToThisDocument: false)
                        .label(unit: .card), "74 card(s) loaded")
    }

    /// Un document ordinaire garde son nom de fichier et son chemin abrégé ;
    /// l'abréviation d'un chemin hors des copies est celle d'avant.
    func testOrdinaryDocumentsKeepTheirFileName() {
        XCTAssertEqual(DocumentDisplay.name("Users/léa/Livres/Chimie/cours.pdf"), "cours.pdf")
        XCTAssertEqual(DocumentDisplay.unit("Users/léa/Livres/Chimie/cours.pdf"), .page)
        XCTAssertNil(DocumentDisplay.source("Users/léa/Documents/Anki/Organique.md"))
    }
}
