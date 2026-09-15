// AppSourcesStoreTests.swift — lire une base d'Apple Notes et une base de Bear
// FABRIQUÉES au schéma réel (lot INT-F4). Propriété : A-Ingest.
//
// POURQUOI DES BASES FABRIQUÉES. `NoteStore.sqlite` est protégé par « Accès
// complet au disque » : mesuré le 08/09/2026, même le Terminal du propriétaire
// reçoit « authorization denied ». Bear, lui, n'est pas installé sur la machine
// de développement. Les tests reproduisent donc les tables, les colonnes et les
// types réels — le blob gzippé compris — et prouvent la LECTURE, pas la
// présence des applications. Ce qui reste à vérifier sur une vraie base est
// écrit dans le rapport du lot.

import Foundation
import SQLite3
import XCTest
import FouineCore
@testable import FouineIndex

/// Écrit une base SQLite de toutes pièces. En LECTURE-ÉCRITURE, contrairement à
/// `SQLiteReader` : c'est le seul endroit du dépôt qui écrive dans une base
/// d'application, et c'est une base à nous, dans un dossier temporaire.
enum FixtureDatabase {

    static func make(at url: URL, statements: [String]) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            throw NSError(domain: "fixture", code: 1)
        }
        defer { sqlite3_close_v2(handle) }
        for sql in statements {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "?"
                sqlite3_free(error)
                throw NSError(domain: "fixture", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: sql + " → " + message])
            }
        }
    }

    /// Un blob en littéral hexadécimal SQL (`X'1f8b…'`).
    static func hex(_ data: Data) -> String {
        "X'" + data.map { String(format: "%02x", $0) }.joined() + "'"
    }
}

final class AppleNotesSourceTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fouine-f4-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// La base réelle, en réduction : `ZICCLOUDSYNCINGOBJECT` porte les notes
    /// ET les dossiers, `ZICNOTEDATA` porte les blobs.
    private func makeStore(url: URL) throws {
        let visible = FixtureDatabase.hex(
            ProtoFixture.gzip(ProtoFixture.noteStore(text: "chez maître Dupont, le 12 mars")))
        let trashed = FixtureDatabase.hex(
            ProtoFixture.gzip(ProtoFixture.noteStore(text: "à jeter")))
        try FixtureDatabase.make(at: url, statements: [
            """
            CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZNOTE INTEGER,
                                      ZDATA BLOB)
            """,
            """
            CREATE TABLE ZICCLOUDSYNCINGOBJECT (
                Z_PK INTEGER PRIMARY KEY, ZNOTEDATA INTEGER, ZFOLDER INTEGER,
                ZMARKEDFORDELETION INTEGER, ZISPASSWORDPROTECTED INTEGER,
                ZIDENTIFIER VARCHAR, ZTITLE1 VARCHAR, ZTITLE2 VARCHAR,
                ZMODIFICATIONDATE1 TIMESTAMP)
            """,
            "INSERT INTO ZICNOTEDATA VALUES (1, 10, \(visible))",
            "INSERT INTO ZICNOTEDATA VALUES (2, 11, \(trashed))",
            "INSERT INTO ZICNOTEDATA VALUES (3, 12, NULL)",
            // Le dossier : même table, titre dans ZTITLE2, pas de ZNOTEDATA.
            """
            INSERT INTO ZICCLOUDSYNCINGOBJECT VALUES
                (5, NULL, NULL, 0, 0, 'FOLDER-1', NULL, 'Notaire', NULL)
            """,
            """
            INSERT INTO ZICCLOUDSYNCINGOBJECT VALUES
                (10, 1, 5, 0, 0, 'A1B2', 'Rendez-vous', NULL, 748000000.0)
            """,
            """
            INSERT INTO ZICCLOUDSYNCINGOBJECT VALUES
                (11, 2, 5, 1, 0, 'C3D4', 'Ancienne', NULL, 748000001.0)
            """,
            """
            INSERT INTO ZICCLOUDSYNCINGOBJECT VALUES
                (12, 3, 5, 0, 1, 'E5F6', 'Secrète', NULL, 748000002.0)
            """,
        ])
    }

    func testReadsNotesFoldersTrashAndLockedNotes() throws {
        let url = directory.appendingPathComponent("NoteStore.sqlite")
        try makeStore(url: url)
        let source = AppleNotesSource(storeURL: url)
        XCTAssertTrue(source.isPresent())
        XCTAssertEqual(source.probe(), .ready)

        let notes = try source.notes().sorted { $0.id < $1.id }
        XCTAssertEqual(notes.count, 3, "les DOSSIERS ne sont pas des notes")

        let visible = try XCTUnwrap(notes.first { $0.id == "A1B2" })
        XCTAssertEqual(visible.title, "Rendez-vous")
        XCTAssertEqual(visible.text, "chez maître Dupont, le 12 mars")
        XCTAssertEqual(visible.folder, "Notaire")
        XCTAssertFalse(visible.deleted)
        XCTAssertFalse(visible.locked)
        XCTAssertEqual(visible.openURL?.absoluteString,
                       "notes://showNote?identifier=A1B2")
        // Date Core Data : secondes depuis le 01/01/2001.
        XCTAssertEqual(visible.modified.timeIntervalSinceReferenceDate,
                       748_000_000, accuracy: 1)

        XCTAssertTrue(try XCTUnwrap(notes.first { $0.id == "C3D4" }).deleted)
        let locked = try XCTUnwrap(notes.first { $0.id == "E5F6" })
        XCTAssertTrue(locked.locked)
        XCTAssertEqual(locked.text, "", "une note chiffrée ne se lit pas")

        // Ce qui compte au bout : deux fichiers, ni la corbeille ni la note
        // verrouillée.
        let folder = directory.appendingPathComponent("Notes")
        let report = SourceMaterializer.write(notes: notes, sourceID: source.id,
                                              into: folder)
        XCTAssertEqual(report.written, 1)
        XCTAssertEqual(report.skipped, 2)
    }

    /// Une base d'une version de macOS qui ne porte pas `ZISPASSWORDPROTECTED`
    /// ni `ZFOLDER` doit se lire quand même : la requête est construite depuis
    /// les colonnes RÉELLES.
    func testOlderSchemaWithoutOptionalColumnsStillReads() throws {
        let url = directory.appendingPathComponent("NoteStore.sqlite")
        let blob = FixtureDatabase.hex(
            ProtoFixture.gzip(ProtoFixture.noteStore(text: "une note ancienne")))
        try FixtureDatabase.make(at: url, statements: [
            "CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZDATA BLOB)",
            """
            CREATE TABLE ZICCLOUDSYNCINGOBJECT (
                Z_PK INTEGER PRIMARY KEY, ZNOTEDATA INTEGER,
                ZIDENTIFIER VARCHAR, ZTITLE1 VARCHAR,
                ZMODIFICATIONDATE1 TIMESTAMP)
            """,
            "INSERT INTO ZICNOTEDATA VALUES (1, \(blob))",
            "INSERT INTO ZICCLOUDSYNCINGOBJECT VALUES (10, 1, 'A1B2', 'Vieux', 0.0)",
        ])
        let notes = try AppleNotesSource(storeURL: url).notes()
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.text, "une note ancienne")
        XCTAssertNil(notes.first?.folder)
    }

    /// Application absente : `.missing`, jamais `.accessDenied` — les deux
    /// appellent des phrases opposées.
    func testAbsentStoreIsMissingNotDenied() {
        let source = AppleNotesSource(
            storeURL: directory.appendingPathComponent("nulle-part.sqlite"))
        XCTAssertFalse(source.isPresent())
        XCTAssertEqual(source.probe(), .absent)
        XCTAssertThrowsError(try source.notes()) { error in
            XCTAssertEqual(error as? SourceError,
                           .missing(source: "Apple Notes"))
        }
    }

    /// Le refus TCC se reconnaît au message autant qu'au code : SQLite rend
    /// `SQLITE_CANTOPEN` aussi bien pour un fichier absent que pour un fichier
    /// interdit.
    func testAuthorizationDeniedIsClassifiedApart() {
        XCTAssertEqual(
            SQLiteReader.classify(status: SQLITE_CANTOPEN,
                                  message: "authorization denied",
                                  source: "Apple Notes"),
            .accessDenied(source: "Apple Notes"))
        XCTAssertEqual(
            SQLiteReader.classify(status: SQLITE_CORRUPT,
                                  message: "database disk image is malformed",
                                  source: "Apple Notes"),
            .unreadable(source: "Apple Notes",
                        detail: "database disk image is malformed"))
    }

    /// Une base au schéma inconnu ne rend pas des notes vides : elle le dit.
    func testUnknownSchemaIsRefusedWithAReason() throws {
        let url = directory.appendingPathComponent("NoteStore.sqlite")
        try FixtureDatabase.make(at: url, statements: [
            "CREATE TABLE AUTRE (x INTEGER)",
        ])
        XCTAssertThrowsError(try AppleNotesSource(storeURL: url).notes()) { error in
            guard case .unreadable(_, let detail)? = error as? SourceError else {
                return XCTFail("motif attendu : schéma inconnu, reçu \(error)")
            }
            XCTAssertTrue(detail.contains("schema"))
        }
    }
}

final class BearSourceTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fouine-f4-bear-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Le texte est en clair dans `ZTEXT` : ni protobuf ni décompression. Une
    /// note ARCHIVÉE reste une note qu'on cherche ; une note à la corbeille,
    /// non.
    func testReadsTextTrashAndArchivedNotes() throws {
        let url = directory.appendingPathComponent("database.sqlite")
        try FixtureDatabase.make(at: url, statements: [
            """
            CREATE TABLE ZSFNOTE (
                Z_PK INTEGER PRIMARY KEY, ZARCHIVED INTEGER, ZENCRYPTED INTEGER,
                ZTRASHED INTEGER, ZUNIQUEIDENTIFIER VARCHAR, ZTITLE VARCHAR,
                ZTEXT VARCHAR, ZMODIFICATIONDATE TIMESTAMP)
            """,
            """
            INSERT INTO ZSFNOTE VALUES
                (1, 0, 0, 0, 'BEAR-1', 'Réunion', '# Réunion\n azote et #projet',
                 748000000.0)
            """,
            """
            INSERT INTO ZSFNOTE VALUES
                (2, 1, 0, 0, 'BEAR-2', 'Rangée', 'archivée mais cherchable',
                 748000001.0)
            """,
            """
            INSERT INTO ZSFNOTE VALUES
                (3, 0, 0, 1, 'BEAR-3', 'Jetée', 'à la corbeille', 748000002.0)
            """,
            """
            INSERT INTO ZSFNOTE VALUES
                (4, 0, 1, 0, 'BEAR-4', 'Chiffrée', 'illisible', 748000003.0)
            """,
        ])
        let source = BearSource(storeURL: url)
        XCTAssertEqual(source.probe(), .ready)
        let notes = try source.notes().sorted { $0.id < $1.id }
        XCTAssertEqual(notes.count, 4)
        XCTAssertEqual(notes[0].openURL?.absoluteString,
                       "bear://x-callback-url/open-note?id=BEAR-1")
        XCTAssertTrue(notes[0].text.contains("azote"))
        XCTAssertFalse(notes[1].deleted, "archivée n'est pas jetée")
        XCTAssertTrue(notes[2].deleted)
        XCTAssertTrue(notes[3].locked)

        let report = SourceMaterializer.write(notes: notes, sourceID: source.id,
                                              into: directory.appendingPathComponent("Bear"))
        XCTAssertEqual(report.written, 2)
        XCTAssertEqual(report.skipped, 2)
    }
}
