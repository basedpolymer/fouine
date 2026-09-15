// AnkiSourceTests.swift — les cartes d'Anki, d'une collection FABRIQUÉE au
// schéma réel jusqu'au résultat de recherche (lot AN1). Propriété : A-Ingest.
//
// La collection est fabriquée comme Anki la tient ouverte : WAL, verrouillage
// exclusif, aucun point de contrôle — les notes n'existent alors QUE dans le
// `-wal`, exactement l'état mesuré sur la collection du propriétaire le
// 14/09/2026 (124 notes). Les noms de paquets sont indexés sous la collation
// `unicase`, que la connexion d'écriture déclare comme le fait Anki.
//
// Aucun test ne lit la collection réelle de ce Mac : `AnkiSource` reçoit
// toujours un dossier `Anki2` temporaire.

import Foundation
import SQLite3
import XCTest
import FouineCore
@testable import FouineIndex

/// Une collection Anki écrite par une connexion qui RESTE OUVERTE, comme Anki.
final class AnkiCollectionFixture {

    private var handle: OpaquePointer?
    let url: URL

    /// - Parameter live: WAL + verrouillage exclusif, sans point de contrôle
    ///   (Anki ouvert). Sinon : journal ordinaire, fichier fermé (Anki quitté).
    init(at url: URL, live: Bool, legacy: Bool = false) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            throw NSError(domain: "anki-fixture", code: 1)
        }
        sqlite3_create_collation_v2(handle, "unicase", SQLITE_UTF8, nil,
            { _, leftLength, left, rightLength, right in
                let lhs = String(decoding: UnsafeRawBufferPointer(
                    start: left, count: Int(leftLength)), as: UTF8.self)
                let rhs = String(decoding: UnsafeRawBufferPointer(
                    start: right, count: Int(rightLength)), as: UTF8.self)
                let order = lhs.caseInsensitiveCompare(rhs)
                return order == .orderedAscending ? -1 : order == .orderedSame ? 0 : 1
            }, nil)
        if live {
            // L'ordre est celui d'Anki : exclusif AVANT le WAL, d'où un index de
            // WAL en mémoire et aucun `-shm` sur le disque.
            try exec("PRAGMA locking_mode = EXCLUSIVE")
            try exec("PRAGMA journal_mode = WAL")
            try exec("PRAGMA wal_autocheckpoint = 0")
        }
        try exec("""
            CREATE TABLE col (id integer primary key, crt integer not null,
              mod integer not null, scm integer not null, ver integer not null,
              dty integer not null, usn integer not null, ls integer not null,
              conf text not null, models text not null, decks text not null,
              dconf text not null, tags text not null)
            """)
        try exec("""
            CREATE TABLE notes (id integer primary key, guid text not null,
              mid integer not null, mod integer not null, usn integer not null,
              tags text not null, flds text not null, sfld integer not null,
              csum integer not null, flags integer not null, data text not null)
            """)
        try exec("""
            CREATE TABLE cards (id integer primary key, nid integer not null,
              did integer not null, ord integer not null, mod integer not null,
              usn integer not null, type integer not null, queue integer not null,
              due integer not null, ivl integer not null, factor integer not null,
              reps integer not null, lapses integer not null, left integer not null,
              odue integer not null, odid integer not null, flags integer not null,
              data text not null)
            """)
        if !legacy {
            try exec("""
                CREATE TABLE decks (id integer PRIMARY KEY NOT NULL,
                  name text NOT NULL COLLATE unicase, mtime_secs integer NOT NULL,
                  usn integer NOT NULL, common blob NOT NULL, kind blob NOT NULL)
                """)
            try exec("CREATE UNIQUE INDEX idx_decks_name ON decks (name)")
        }
    }

    deinit { close() }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "?"
            sqlite3_free(error)
            throw NSError(domain: "anki-fixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: sql + " → " + message])
        }
    }

    private func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }

    func deck(_ id: Int64, _ levels: [String]) throws {
        try exec("INSERT INTO decks VALUES (\(id), "
                 + quoted(levels.joined(separator: "\u{1F}")) + ", 0, 0, x'', x'')")
    }

    func legacyDecks(_ decks: [Int64: String]) throws {
        let json = decks.map { "\"\($0.key)\": {\"id\": \($0.key), \"name\": \"\($0.value)\"}" }
            .joined(separator: ", ")
        try exec("INSERT INTO col VALUES (1, 0, 0, 0, 11, 0, 0, 0, '{}', '{}', "
                 + quoted("{\(json)}") + ", '{}', '{}')")
    }

    func note(_ id: Int64, modified: Int64, fields: [String]) throws {
        try exec("INSERT INTO notes VALUES (\(id), 'g\(id)', 1, \(modified), 0, "
                 + "' outil::lot ', " + quoted(fields.joined(separator: "\u{1F}"))
                 + ", 0, 0, 0, '')")
    }

    func card(_ id: Int64, note: Int64, deck: Int64, ord: Int = 0,
              originalDeck: Int64 = 0) throws {
        try exec("INSERT INTO cards VALUES (\(id), \(note), \(deck), \(ord), 0, 0, "
                 + "0, 0, 0, 0, 0, 0, 0, 0, 0, \(originalDeck), 0, '')")
    }
}

// MARK: - Le texte d'une carte

final class AnkiTextTests: XCTestCase {

    func testClozeKeepsTheAnswerAndDropsTheHint() {
        XCTAssertEqual(AnkiText.fieldText("L'{{c1::éthanol::un alcool}} bout à {{c2::78 °C}}"),
                       "L'éthanol bout à 78 °C")
        // Imbriqués (Anki 23.10) : de l'intérieur vers l'extérieur.
        XCTAssertEqual(AnkiText.fieldText("{{c1::le {{c2::benzène}} est aromatique}}"),
                       "le benzène est aromatique")
        // Malformé : laissé tel quel, sans boucler.
        XCTAssertEqual(AnkiText.fieldText("{{c1::sans fin"), "{{c1::sans fin")
    }

    func testImageOcclusionSoundsAndMathMarkersAreNotText() {
        XCTAssertEqual(
            AnkiText.fieldText("{{c1::image-occlusion:rect:left=.1:top=.2:width=.3:height=.4:oi=1}}"),
            "")
        XCTAssertEqual(AnkiText.fieldText("Écoutez [sound:rec-123.mp3] bien"),
                       "Écoutez bien")
        XCTAssertEqual(AnkiText.fieldText("[latex]\\ce{H2O}[/latex] et [$]x^2[/$]"),
                       "\\ce{H2O} et x^2")
    }

    /// Le HTML de l'éditeur d'Anki : les images partent, les retours font des
    /// lignes, les entités se décodent — et la mention de source reste, c'est
    /// elle qui dit de quel cours vient la carte.
    func testHTMLBecomesReadableText() {
        let html = "Réponse&nbsp;:<br><br>{{c1::0,001}}<div><img src=\"p139.png\"></div>"
            + "<span style=\"color:#888\">Source : Cours.pdf, p. 139</span>"
        let text = AnkiText.fieldText(html)
        XCTAssertFalse(text.contains("<"), text)
        XCTAssertFalse(text.contains("p139.png"), text)
        XCTAssertTrue(text.contains("0,001"), text)
        XCTAssertTrue(text.contains("Source : Cours.pdf, p. 139"), text)
    }

    /// Les images : le `src` de chaque `<img>`, sans doublon, et seulement un nom
    /// du dossier de médias — ni adresse, ni chemin, ni nom caché.
    func testImageNamesAreMediaFileNamesOnly() {
        let fields = "<img src=\"p139.png\"> et <IMG class=x src='oh &amp; ah.png'>"
            + "\u{1F}<img src=p139.png><img src=\"https://exemple.org/a.png\">"
            + "<img src=\"data:image/png;base64,AAAA\"><img src=\"../../etc/x.png\">"
            + "<img src=\".cachée.png\"><img alt=\"sans source\">"
        XCTAssertEqual(AnkiText.imageNames(fields: fields), ["p139.png", "oh & ah.png"])
        XCTAssertEqual(AnkiText.imageNames(fields: "pas d'image"), [])
    }

    /// Les champs vides ne laissent pas de lignes blanches, et ni leurs noms ni
    /// les étiquettes ne sont écrits.
    func testNoteTextJoinsTheNonEmptyFields() {
        XCTAssertEqual(AnkiText.noteText(fields: "Capitale du Pérou\u{1F}\u{1F}<b>Lima</b>"),
                       "Capitale du Pérou\n\nLima")
        XCTAssertEqual(AnkiText.noteText(fields: "<img src=\"drapeau.svg\">\u{1F}"), "")
    }
}

// MARK: - La collection

final class AnkiSourceTests: XCTestCase {

    private var directory: URL!
    private var anki2: URL { directory.appendingPathComponent("Anki2", isDirectory: true) }
    private var scratch: URL { directory.appendingPathComponent("tmp", isDirectory: true) }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fouine-an1-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func source() -> AnkiSource {
        AnkiSource(storeURL: anki2, temporaryDirectory: scratch)
    }

    /// Une collection au schéma 18, Anki ouvert.
    private func makeLiveCollection(profile: String = "Matisse") throws -> AnkiCollectionFixture {
        let url = anki2.appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent("collection.anki2")
        let fixture = try AnkiCollectionFixture(at: url, live: true)
        try fixture.deck(1, ["Default"])
        try fixture.deck(10, ["Chimie", "Organique"])
        try fixture.deck(11, [".📚", "Géographie"])
        try fixture.deck(12, ["Révision du jour"])     // paquet filtré
        try fixture.note(100, modified: 1_789_000_000,
                         fields: ["L'{{c1::éthanol::alcool}} bout à 78 °C", ""])
        try fixture.note(101, modified: 1_789_000_500,
                         fields: ["Nom du groupe –OH ?<br>[sound:oh.mp3]",
                                  "hydroxyle<img src=\"oh.png\">"])
        try fixture.note(102, modified: 1_789_000_100,
                         fields: ["Capitale du Pérou", "Lima"])
        try fixture.note(103, modified: 1_789_000_200,
                         fields: ["Capitale de la Bolivie", "Sucre"])
        try fixture.note(104, modified: 1_789_000_300,
                         fields: ["<img src=\"drapeau.svg\">", ""])
        try fixture.note(105, modified: 1_789_000_400,
                         fields: ["note orpheline, sans carte", ""])
        try fixture.card(1000, note: 100, deck: 10)
        try fixture.card(1010, note: 101, deck: 10)
        // Deux cartes, deux paquets : la note va avec sa PREMIÈRE carte.
        try fixture.card(1011, note: 101, deck: 11, ord: 1)
        try fixture.card(1020, note: 102, deck: 11)
        // Prêtée au paquet filtré : elle reste dans son paquet d'origine.
        try fixture.card(1030, note: 103, deck: 12, originalDeck: 11)
        try fixture.card(1040, note: 104, deck: 10)
        return fixture
    }

    /// LE test de la lecture : les notes qui ne sont QUE dans le WAL d'une
    /// collection ouverte sont lues, et le dossier du profil n'a rien reçu.
    func testReadsTheWALOfAnOpenCollectionWithoutWritingBesideIt() throws {
        let fixture = try makeLiveCollection()
        defer { fixture.close() }
        let profile = fixture.url.deletingLastPathComponent()
        let wal = URL(fileURLWithPath: fixture.url.path + "-wal")
        XCTAssertGreaterThan(
            (try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int) ?? 0,
            0, "la fabrique doit laisser les notes dans le WAL")
        // Ce que lirait `immutable=1`, la lecture d'Apple Notes et de Bear : rien.
        let frozen = try SQLiteReader(url: fixture.url, source: "Anki")
        XCTAssertFalse(frozen.hasTable("notes"), "le fichier principal ne porte encore rien")
        frozen.close()
        let before = try FileManager.default.contentsOfDirectory(atPath: profile.path).sorted()

        let anki = source()
        XCTAssertEqual(anki.probe(), .ready)
        let documents = try anki.notes().sorted { $0.relativePath ?? "" < $1.relativePath ?? "" }

        XCTAssertEqual(documents.map(\.relativePath),
                       ["Chimie/Organique.md", "📚/Géographie.md"],
                       "un fichier par paquet, l'arborescence en dossiers, pas de point en tête")
        let organique = documents[0]
        XCTAssertEqual(organique.title, "Organique")
        XCTAssertNil(organique.openURL)
        XCTAssertEqual(organique.text.components(separatedBy: "\u{0C}"),
                       ["L'éthanol bout à 78 °C\n",
                        "Nom du groupe –OH ?\n\nhydroxyle\n<!-- fouine-image: oh.png -->\n"],
                       "une note par page, dans l'ordre de création ; l'image seule est sautée")
        XCTAssertEqual(organique.modified.timeIntervalSince1970, 1_789_000_500)

        let geographie = documents[1]
        XCTAssertEqual(geographie.text.components(separatedBy: "\u{0C}").count, 2,
                       "la carte prêtée au paquet filtré reste chez elle")
        XCTAssertTrue(geographie.text.contains("Sucre"))
        XCTAssertFalse(documents.contains { $0.text.contains("orpheline") })

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: profile.path).sorted(),
                       before, "aucun fichier créé à côté de la collection")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [],
                       "la copie de travail est effacée")
    }

    /// Anki 2.1.27 et plus ancien : pas de table `decks`, un JSON dans `col`.
    func testLegacySchemaReadsDecksFromTheCollectionJSON() throws {
        let url = anki2.appendingPathComponent("User 1/collection.anki2")
        let fixture = try AnkiCollectionFixture(at: url, live: false, legacy: true)
        try fixture.legacyDecks([1: "Default", 20: "Langues::Allemand"])
        try fixture.note(200, modified: 1_600_000_000, fields: ["der Hund", "le chien"])
        try fixture.card(2000, note: 200, deck: 20)
        fixture.close()

        let documents = try source().notes()
        XCTAssertEqual(documents.map(\.relativePath), ["Langues/Allemand.md"])
        XCTAssertEqual(documents.first?.text, "der Hund\n\nle chien\n")
    }

    /// Plusieurs profils : un dossier chacun. Un seul : pas de niveau inutile.
    func testSeveralProfilesGetAFolderEach() throws {
        for profile in ["Matisse", "Léa"] {
            let fixture = try AnkiCollectionFixture(
                at: anki2.appendingPathComponent("\(profile)/collection.anki2"), live: false)
            try fixture.deck(30, ["Anglais"])
            try fixture.note(300, modified: 1, fields: ["dog", "chien"])
            try fixture.card(3000, note: 300, deck: 30)
            fixture.close()
        }
        try FileManager.default.createDirectory(
            at: anki2.appendingPathComponent("addons21/1234"), withIntermediateDirectories: true)
        XCTAssertEqual(try source().notes().compactMap(\.relativePath).sorted(),
                       ["Léa/Anglais.md", "Matisse/Anglais.md"])
    }

    func testNoProfileMeansAbsentNotDenied() {
        XCTAssertEqual(source().probe(), .absent)
        XCTAssertFalse(source().isPresent())
        XCTAssertThrowsError(try source().notes()) { error in
            XCTAssertEqual(error as? SourceError, .missing(source: "Anki"))
        }
    }

    /// Une base qui n'est pas une collection le dit, sans rien écrire.
    func testAnUnknownDatabaseIsRefusedWithAReason() throws {
        let url = anki2.appendingPathComponent("Matisse/collection.anki2")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FixtureDatabase.make(at: url, statements: ["CREATE TABLE autre (x)"])
        XCTAssertThrowsError(try source().notes()) { error in
            guard case .unreadable(_, let detail)? = error as? SourceError else {
                return XCTFail("motif attendu : schéma inconnu, reçu \(error)")
            }
            XCTAssertTrue(detail.contains("schema"), detail)
        }
        // Et un fichier qui n'est pas du SQLite du tout.
        try Data("pas une base".utf8).write(to: url)
        XCTAssertThrowsError(try source().notes())
    }

    /// Le dossier des médias d'un paquet recopié : le seul profil, ou celui que
    /// nomme le premier dossier quand il y en a plusieurs ; et un nom lu dans
    /// un fichier ne sort jamais de ce dossier.
    func testMediaOfACopiedDeckIsFoundInItsProfileOnly() throws {
        let fm = FileManager.default
        for profile in ["Matisse", "Léa"] {
            let media = anki2.appendingPathComponent("\(profile)/collection.media")
            try fm.createDirectory(at: media, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: anki2.appendingPathComponent("\(profile)/collection.anki2"))
            try Data("png".utf8).write(to: media.appendingPathComponent("p139 \(profile).png"))
        }
        try Data("secret".utf8).write(to: anki2.appendingPathComponent("Matisse/collection.anki2-wal"))

        let lea = try XCTUnwrap(source().mediaFolder(forCopiedDeck: "Léa/Chimie/Organique.md"))
        XCTAssertEqual(lea.lastPathComponent, "collection.media")
        XCTAssertEqual(lea.deletingLastPathComponent().lastPathComponent, "Léa")
        XCTAssertNil(source().mediaFolder(forCopiedDeck: "Inconnu/Organique.md"))

        XCTAssertNotNil(AnkiSource.mediaFile(named: "p139 Léa.png", in: lea))
        XCTAssertNotNil(AnkiSource.mediaFile(named: "p139%20L%C3%A9a.png", in: lea),
                        "un nom resté encodé est essayé décodé")
        for hostile in ["../collection.anki2", "../../Matisse/collection.anki2-wal",
                        "/etc/hosts", ".DS_Store", "absent.png", ""] {
            XCTAssertNil(AnkiSource.mediaFile(named: hostile, in: lea), hostile)
        }

        try fm.removeItem(at: anki2.appendingPathComponent("Léa"))
        XCTAssertEqual(source().mediaFolder(forCopiedDeck: "Chimie/Organique.md")?
                        .deletingLastPathComponent().lastPathComponent, "Matisse",
                       "un seul profil : pas de dossier de profil dans le chemin")
    }

    // MARK: - Mise en fichiers (pure)

    private func deck(_ id: Int64, _ path: [String], notes count: Int,
                      modified: Int64 = 10) -> AnkiSource.Deck {
        AnkiSource.Deck(id: id, path: path, notes: (0..<count).map {
            AnkiSource.Note(id: Int64($0), modified: modified + Int64($0), text: "carte \($0)")
        })
    }

    /// Au-delà de `notesPerFile`, un paquet se découpe en volumes : le plafond
    /// de pages d'un document ne tronque rien.
    func testALargeDeckIsSplitIntoVolumes() {
        let big = deck(1, ["AnKing", "Step 1"], notes: AnkiSource.notesPerFile + 1)
        let files = AnkiSource.documents(decks: [big], profileFolder: nil)
        XCTAssertEqual(files.map(\.relativePath), ["AnKing/Step 1.md", "AnKing/Step 1 (2).md"])
        XCTAssertEqual(files.map(\.id), ["1", "1-2"])
        XCTAssertEqual(files[0].text.components(separatedBy: "\u{0C}").count,
                       AnkiSource.notesPerFile)
        XCTAssertEqual(files[1].text, "carte \(AnkiSource.notesPerFile)\n")
        XCTAssertEqual(files[1].modified.timeIntervalSince1970,
                       TimeInterval(10 + AnkiSource.notesPerFile),
                       "la date d'un volume est celle de sa note la plus récente")
    }

    /// Deux paquets que le nettoyage rend homonymes ne s'écrasent pas, casse
    /// comprise (le disque d'un Mac l'ignore).
    func testDecksThatCleanToTheSameNameDoNotOverwriteEachOther() {
        let files = AnkiSource.documents(
            decks: [deck(5, ["Cours/TD"], notes: 1), deck(7, ["cours:td"], notes: 1),
                    deck(9, ["Vide"], notes: 0)],
            profileFolder: "Léa")
        XCTAssertEqual(files.map(\.relativePath), ["Léa/Cours TD.md", "Léa/cours td 7.md"])
    }

    // MARK: - Écriture, synchronisation, recherche

    func testMaterializedDecksLiveInSubfoldersAndGoAwayWithTheirDeck() throws {
        let folder = directory.appendingPathComponent("Sources/Anki", isDirectory: true)
        let both = AnkiSource.documents(
            decks: [deck(1, ["Chimie", "Organique"], notes: 3),
                    deck(2, ["Chimie", "Minérale", "TP"], notes: 2)],
            profileFolder: nil)
        var report = SourceMaterializer.write(notes: both, sourceID: "anki", into: folder)
        XCTAssertEqual(report.written, 2)
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        let written = try String(contentsOf: folder.appendingPathComponent("Chimie/Organique.md"),
                                 encoding: .utf8)
        // Pas de « # Organique » en tête : le nom du paquet n'est d'aucune carte
        // (lot AN2), et la première carte ne doit pas répondre à ses mots.
        XCTAssertTrue(written.hasPrefix("<!-- fouine-source: anki -->\ncarte 0\n\u{0C}"),
                      written)
        XCTAssertFalse(written.contains("fouine-open"), "Anki n'a pas de lien vers une note")
        XCTAssertEqual(source().copiedNoteCount(in: folder), 5)

        report = SourceMaterializer.write(notes: both, sourceID: "anki", into: folder)
        XCTAssertEqual(report.unchanged, 2)
        XCTAssertEqual(report.written, 0)

        // Le paquet « TP » disparaît : son fichier, puis ses dossiers vides.
        report = SourceMaterializer.write(notes: [both[0]], sourceID: "anki", into: folder)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("Chimie/Minérale").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    /// Un paquet renommé à la casse près (« chimie » → « Chimie ») garde son
    /// fichier : le disque ignore la casse, le nettoyage aussi.
    func testADeckRenamedOnlyByCaseKeepsItsFile() throws {
        let folder = directory.appendingPathComponent("Sources/Anki", isDirectory: true)
        _ = SourceMaterializer.write(
            notes: AnkiSource.documents(decks: [deck(1, ["chimie"], notes: 2)],
                                        profileFolder: nil),
            sourceID: "anki", into: folder)
        let renamed = AnkiSource.documents(decks: [deck(1, ["Chimie"], notes: 3)],
                                           profileFolder: nil)
        let report = SourceMaterializer.write(notes: renamed, sourceID: "anki", into: folder)
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(SourceMaterializer.markdownFiles(in: folder).count, 1)
        XCTAssertEqual(source().copiedNoteCount(in: folder), 3)
    }

    /// Un chemin fourni par une source ne sort jamais du dossier de la source.
    func testAnUnsafeRelativePathIsRefused() throws {
        let folder = directory.appendingPathComponent("Sources/Anki", isDirectory: true)
        for path in ["../évadé.md", "/etc/évadé.md", "a//b.md", "a/.caché.md", "sans-extension"] {
            let note = SourceNote(id: "1", title: "x", text: "y", modified: Date(),
                                  openURL: nil, relativePath: path)
            let report = SourceMaterializer.write(notes: [note], sourceID: "anki", into: folder)
            XCTAssertEqual(report.written, 0, path)
            XCTAssertEqual(report.errors.count, 1, path)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Sources/évadé.md").path))
    }

    /// Le bilan compte des PAQUETS, l'extinction efface des NOTES : chaque
    /// nombre dit ce qu'il compte.
    func testSyncCountsDecksAndDisableCountsNotes() throws {
        let fixture = try makeLiveCollection()
        defer { fixture.close() }
        let store = FakeRootStore()
        let sources = directory.appendingPathComponent("Sources", isDirectory: true)
        let report = SourceSync.run(store: store, sources: [source()], directory: sources)
        let entry = try XCTUnwrap(report.entries.first)
        XCTAssertNil(entry.error)
        XCTAssertEqual(entry.summary, "Anki: 2 deck(s) copied (2 written, 0 removed, 0 skipped)")
        XCTAssertEqual(store.records.first?.label, "Anki")

        let disabled = SourceSync.disable(source: source(), store: store, directory: sources)
        XCTAssertEqual(disabled.removed, 4, "quatre notes cherchables, deux paquets")
        XCTAssertTrue(store.records.isEmpty)
    }

    /// De la collection au résultat : chaque carte est une page, et la page
    /// trouvée est celle de la carte.
    func testACardIsFoundOnItsOwnPage() throws {
        let fixture = try makeLiveCollection()
        defer { fixture.close() }
        let scratchIndex = try IndexScratch("anki-index", documents: 0)
        let sources = scratchIndex.directory.appendingPathComponent("Sources", isDirectory: true)
        let report = SourceSync.run(store: scratchIndex.store, sources: [source()],
                                    directory: sources)
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")

        try IndexPass(store: scratchIndex.store)
            .run(roots: try scratchIndex.store.roots(),
                 options: IndexPassOptions(crawl: .full, warmVocabulary: false))

        let hydroxyle = try scratchIndex.store.search(SearchQuery(fts: "hydroxyle"))
        XCTAssertEqual(hydroxyle.hits.count, 1)
        XCTAssertEqual(hydroxyle.hits.first?.page, 2, "deuxième carte, deuxième page")
        XCTAssertTrue(hydroxyle.hits.first?.path.hasSuffix("Anki/Chimie/Organique.md") ?? false)

        let lima = try scratchIndex.store.search(SearchQuery(fts: "Lima"))
        XCTAssertEqual(lima.hits.first?.page, 1)
        // L'indice d'un trou et le nom d'un son ne sont pas cherchables.
        XCTAssertEqual(try scratchIndex.store.search(SearchQuery(fts: "alcool")).hits.count, 0)
        XCTAssertEqual(try scratchIndex.store.search(SearchQuery(fts: "mp3")).hits.count, 0)
        // Ni le nom d'une image, que seul l'aperçu relit dans le fichier.
        XCTAssertEqual(try scratchIndex.store.search(SearchQuery(fts: "png")).hits.count, 0)
        XCTAssertEqual(try scratchIndex.store.search(SearchQuery(fts: "\"fouine image\"")).hits.count, 0)
        // Ni l'en-tête technique, ni le nom du paquet (lot AN2) : « anki » et
        // « Organique » ne font plus répondre la première carte.
        XCTAssertEqual(try scratchIndex.store.search(SearchQuery(fts: "anki")).hits.count, 0)
        XCTAssertEqual(try scratchIndex.store.search(SearchQuery(fts: "fouine")).hits.count, 0)
        XCTAssertEqual(try scratchIndex.store.search(SearchQuery(fts: "Organique")).hits.count, 0)

        // Le chemin rendu par la recherche se reconnaît comme une carte de SON
        // paquet, par le même localisateur que l'app.
        let locator = SourceDocumentLocator.resolving(sources)
        let found = try XCTUnwrap(hydroxyle.hits.first)
        XCTAssertEqual(locator.document(relPath: found.path),
                       SourceDocument(sourceID: "anki", rootLabel: "Anki",
                                      title: "Organique", folders: ["Chimie"]))
        let roots = try scratchIndex.store.roots()
        let root = try XCTUnwrap(roots.first { $0.label == "Anki" })
        XCTAssertEqual(locator.source(rootRelPath: root.relPath)?.id, "anki")
        // La racine « Jetable » du bac à sable, elle, n'est d'aucune source.
        XCTAssertEqual(roots.filter { locator.source(rootRelPath: $0.relPath) != nil }.count, 1)
    }
}
