// MediaTranscriptionRequeueTests.swift — relire les enregistrements quand la
// transcription s'allume ou change de révision (lot TR1).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// Les motifs sont RECOPIÉS de FouineExtract (`MediaExtractor`,
// `SpeechTranscriber`), que cette cible n'importe pas. Le test de passe
// (`FouineIndexTests/TranscriptionRevisionPassTests`) éprouve les vraies
// constantes et la forme sous laquelle la passe les écrit dans `docs.err`.

import Foundation
import XCTest
import GRDB
@testable import FouineCore

final class MediaTranscriptionRequeueTests: XCTestCase {

    private let media: Set<String> = ["m4a", "mp3", "mp4", "wav", "opus"]
    private let exactReasons = [
        "no metadata",
        "speech recognition not authorised — System Settings ▸ Privacy & "
            + "Security ▸ Speech Recognition",
    ]
    private let reasonPrefixes = ["speech: on-device recognition is not installed"]
    private let failedSubstrings = ["speech recognition returned nothing — try again"]

    private func doc(_ db: TempDB, _ relPath: String, ext: String,
                     _ state: DocState, err: String? = nil) throws -> Int64 {
        let id = try addDoc(db, relPath: relPath, ext: ext)
        try db.store.setDocState(id, state, err: err)
        return id
    }

    private func stateAndReason(_ db: TempDB, _ id: Int64) throws -> (DocState?, String?) {
        try db.store.read { raw in
            guard let row = try Row.fetchOne(
                raw, sql: "SELECT state, err FROM docs WHERE id = ?", arguments: [id])
            else { return (nil, nil) }
            let state: Int = row["state"]
            return (DocState(rawValue: state), row["err"])
        }
    }

    /// Les médias `extracted`, « no metadata » EXACT, les deux refus de la
    /// reconnaissance et les `failed` « returned nothing » repartent en
    /// `discovered`, motif effacé ; tout le reste est intact. Le nombre rendu
    /// les compte, et la marque est écrite.
    func testRequeueTakesOnlyWhatTranscriptionCanChange() throws {
        let db = try makeDB()
        let extracted = try doc(db, "Cours/partie1.m4a", ext: "m4a", .extracted)
        let upperCase = try doc(db, "Cours/PARTIE2.MP4", ext: "MP4", .extracted)
        let untagged = try doc(db, "Cours/partie4.mp3", ext: "mp3", .skipped,
                                err: "no metadata")
        let denied = try doc(db, "Dictaphone/a.m4a", ext: "m4a", .skipped,
                             err: exactReasons[1])
        let notInstalled = try doc(
            db, "Dictaphone/b.m4a", ext: "m4a", .skipped,
            err: "speech: on-device recognition is not installed for fr-FR, en-US "
                + "— add the language under System Settings ▸ Keyboard ▸ Dictation")
        let failedReturnedNothing = try doc(
            db, "Cours/partie3.wav", ext: "wav", .failed,
            err: "extraction: speech recognition returned nothing — try again")
        let failedBareReason = try doc(
            db, "Cours/partie4-bare.m4a", ext: "m4a", .failed,
            err: "speech recognition returned nothing — try again")

        let noTrack = try doc(db, "Videos/muette.mp4", ext: "mp4", .skipped,
                              err: "no metadata (no audio track)")
        let tooLong = try doc(db, "Videos/film.mp4", ext: "mp4", .skipped,
                              err: "no metadata (longer than 120 min)")
        let otherFailed = try doc(db, "Cours/corrompu.wav", ext: "wav", .failed,
                                  err: "extraction: corrupt audio stream")
        let pdf = try doc(db, "Livres/cours.pdf", ext: "pdf", .extracted)
        let notMedia = try doc(db, "Notes/fiche.txt", ext: "txt", .skipped,
                                err: "no metadata")
        let lookalike = try doc(db, "Cours/c.opus", ext: "opus", .skipped,
                                err: "No Metadata")

        XCTAssertNil(try db.store.transcriptionRevision(),
                     "une base d'avant TR1 ne porte aucune marque")
        let queued = try db.store.requeueMediaForTranscription(
            extensions: media, skipReasons: exactReasons,
            skipReasonPrefixes: reasonPrefixes,
            failedReasonSubstrings: failedSubstrings,
            revision: "speech-rev2")

        XCTAssertEqual(queued, 7)
        for id in [extracted, upperCase, untagged, denied, notInstalled,
                   failedReturnedNothing, failedBareReason] {
            let (state, reason) = try stateAndReason(db, id)
            XCTAssertEqual(state, .discovered, "document \(id)")
            XCTAssertNil(reason, "document \(id)")
        }
        let untouched: [(Int64, DocState, String?)] = [
            (noTrack, .skipped, "no metadata (no audio track)"),
            (tooLong, .skipped, "no metadata (longer than 120 min)"),
            (otherFailed, .failed, "extraction: corrupt audio stream"),
            (pdf, .extracted, nil),
            (notMedia, .skipped, "no metadata"),
            (lookalike, .skipped, "No Metadata"),
        ]
        for (id, state, reason) in untouched {
            let now = try stateAndReason(db, id)
            XCTAssertEqual(now.0, state, "document \(id)")
            XCTAssertEqual(now.1, reason, "document \(id)")
        }
        XCTAssertEqual(try db.store.transcriptionRevision(), "speech-rev2")
    }

    /// Écrire la marque SEULE — la transcription s'éteint — ne relit rien.
    func testWritingTheMarkAloneRequeuesNothing() throws {
        let db = try makeDB()
        let id = try doc(db, "Cours/partie1.m4a", ext: "m4a", .extracted)
        try db.store.setTranscriptionRevision(GRDBStore.transcriptionRevisionOff)
        XCTAssertEqual(try db.store.transcriptionRevision(), "off")
        XCTAssertEqual(try stateAndReason(db, id).0, .extracted)
    }
}
