// TranscriptMarkersTests.swift — lire les horodatages d'une transcription
// (lot PV1). Propriété : A-App.
//
// Ce que ces tests protègent : le format écrit par `SpeechTranscriber` (des
// repères ABSOLUS en tête de chaque paragraphe) et la règle qui décide où poser
// la tête de lecture. Une erreur ici ne se voit pas — elle fait écouter le
// mauvais passage.

import XCTest
@testable import FouineApp

final class TranscriptMarkersTests: XCTestCase {

    private func offsets(_ text: String,
                         _ marker: TranscriptMarkers.Marker) -> Range<Int> {
        text.distance(from: text.startIndex, to: marker.range.lowerBound)
            ..< text.distance(from: text.startIndex, to: marker.range.upperBound)
    }

    private func term(_ text: String) -> HighlightTerm {
        HighlightTerm(text: text, folded: text.lowercased(), kind: .word,
                      colorIndex: 0)
    }

    /// Les deux écritures — « mm:ss » sous l'heure, « h:mm:ss » au-delà — et la
    /// plage exacte du repère, crochets compris.
    func testParseReadsBothFormatsAndTheirExactRanges() {
        let text = "[00:41] la réticulation\n\n[1:02:40] et la suite"
        let markers = TranscriptMarkers.parse(text)
        XCTAssertEqual(markers.map(\.seconds), [41, 3_760])
        XCTAssertEqual(offsets(text, markers[0]), 0..<7)
        XCTAssertEqual(String(text[markers[1].range]), "[1:02:40]")
    }

    /// CE QUI N'EST PAS UN REPÈRE, et c'est tout l'enjeu : un renvoi de note,
    /// une année, un mot entre crochets, un moment mal formé.
    func testWhatIsNotAMarker() {
        let text = "[12] voir plus haut, [1990] l'article, [voir] ceci, "
            + "[3:1] et [12:99] et [] et [00:41:] rien"
        XCTAssertEqual(TranscriptMarkers.parse(text).map(\.seconds), [])
    }

    /// Un repère au milieu d'une phrase compte aussi : l'extrait d'un résultat
    /// coupe où il veut.
    func testAMarkerIsFoundAnywhereInTheText() {
        let text = "…le mélange [08:20] refroidit lentement…"
        XCTAssertEqual(TranscriptMarkers.parse(text).map(\.seconds), [500])
    }

    /// La page se découpe en paragraphes, repère retiré du texte : il devient
    /// le bouton qui le porte.
    func testBlocksCarryTheirMomentAndDropTheMarker() {
        let blocks = TranscriptMarkers.blocks("[00:00] bonjour\n\n[00:41] la suite")
        XCTAssertEqual(blocks.map(\.seconds), [0, 41])
        XCTAssertEqual(blocks.map(\.text), ["bonjour", "la suite"])
        XCTAssertEqual(blocks.map(\.id), [0, 1])
    }

    /// Une page sans repère — celle des balises d'un enregistrement — reste un
    /// bloc, sans moment.
    func testAPageWithoutMarkersIsOneBlockWithoutAMoment() {
        let blocks = TranscriptMarkers.blocks("Title: Cours de chimie\nDuration: 01:12:00")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertNil(blocks[0].seconds)
    }

    /// La numérotation est compacte : la première fenêtre transcrite est la
    /// page 1 sans balises, la page 2 avec.
    func testStartSecondsFollowsTheCompactNumbering() {
        XCTAssertEqual(TranscriptMarkers.startSeconds(page: 1, firstWindowPage: 1), 0)
        XCTAssertEqual(TranscriptMarkers.startSeconds(page: 3, firstWindowPage: 1), 1_200)
        XCTAssertEqual(TranscriptMarkers.startSeconds(page: 3, firstWindowPage: 2), 600)
        // La page de balises précède la première fenêtre : jamais de négatif.
        XCTAssertEqual(TranscriptMarkers.startSeconds(page: 1, firstWindowPage: 2), 0)
    }

    /// La tête de lecture remonte au repère qui OUVRE le paragraphe où le mot
    /// cherché se trouve — pas au début de la page, pas au mot lui-même.
    func testThePlayheadOpensTheParagraphOfTheFirstOccurrence() {
        let text = "[00:00] bonjour à tous\n\n[00:41] la réticulation se mesure\n\n"
            + "[01:22] et la réticulation encore"
        XCTAssertEqual(
            TranscriptMarkers.playhead(text: text, terms: [term("réticulation")],
                                       pageStart: 0),
            41)
    }

    /// Sans terme trouvé, c'est le début de la page — et sans repère du tout,
    /// le début qu'on lui donne.
    func testThePlayheadFallsBackOnTheFirstMarkerThenOnThePageStart() {
        let text = "[05:00] bonjour à tous"
        XCTAssertEqual(
            TranscriptMarkers.playhead(text: text, terms: [term("absent")],
                                       pageStart: 0),
            300)
        XCTAssertEqual(
            TranscriptMarkers.playhead(text: "Title: Cours", terms: [], pageStart: 42),
            42)
    }

    /// Une ligne de résultat annonce le repère de son extrait, ou le début de
    /// sa page.
    func testExtractStartPrefersTheMarkerOfTheSnippet() {
        XCTAssertEqual(
            TranscriptMarkers.extractStart(snippet: "…[12:40] la réticulation…",
                                           pageStart: 600),
            760)
        XCTAssertEqual(
            TranscriptMarkers.extractStart(snippet: "…la réticulation…",
                                           pageStart: 600),
            600)
    }

    /// Un moment estimé par une ligne de résultat ne vaut que s'il tombe dans
    /// la page affichée : c'est ce qui rattrape l'écart d'une fenêtre quand
    /// l'extrait ne portait aucun repère.
    func testCoversAcceptsOnlyAMomentInsideThePage() {
        let page = "[10:00] bonjour\n\n[10:41] la suite"
        XCTAssertTrue(TranscriptMarkers.covers(text: page, seconds: 600))
        XCTAssertTrue(TranscriptMarkers.covers(text: page, seconds: 1_100))
        XCTAssertFalse(TranscriptMarkers.covers(text: page, seconds: 1_200))
        XCTAssertFalse(TranscriptMarkers.covers(text: page, seconds: 0))
        XCTAssertFalse(TranscriptMarkers.covers(text: "sans repère", seconds: 0))
    }

    /// La pastille écrit le moment comme le texte de la page : sans quoi deux
    /// écritures du même instant se liraient comme deux instants.
    func testTimestampIsWrittenLikeTheTranscript() {
        XCTAssertEqual(TranscriptMarkers.timestamp(0), "00:00")
        XCTAssertEqual(TranscriptMarkers.timestamp(760), "12:40")
        XCTAssertEqual(TranscriptMarkers.timestamp(3_760), "1:02:40")
        XCTAssertEqual(TranscriptMarkers.timestamp(-5), "00:00")
    }
}
