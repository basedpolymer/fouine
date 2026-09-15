// AppSourcesTests.swift — protobuf, gzip, matérialisation, synchronisation
// (lot INT-F4). Propriété : A-Ingest.
//
// Rien ici ne touche à une vraie application : les blobs sont fabriqués à la
// main, les notes sont des valeurs, et le dossier d'écriture est temporaire.
// C'est la seule façon d'éprouver ce lot — la base d'Apple Notes est protégée
// par TCC, et Bear n'est pas installé sur la machine de développement.

import Foundation
import Compression
import XCTest
import FouineCore
@testable import FouineIndex
@testable import FouineCrawl

// MARK: - Fabrique de protobuf et de gzip

enum ProtoFixture {

    static func varint(_ value: UInt64) -> Data {
        var out = Data()
        var v = value
        repeat {
            var byte = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    /// Un champ `length-delimited` (wire 2).
    static func message(_ field: Int, _ payload: Data) -> Data {
        varint(UInt64(field) << 3 | 2) + varint(UInt64(payload.count)) + payload
    }

    /// Un champ varint (wire 0).
    static func number(_ field: Int, _ value: UInt64) -> Data {
        varint(UInt64(field) << 3) + varint(value)
    }

    static func string(_ field: Int, _ text: String) -> Data {
        message(field, Data(text.utf8))
    }

    /// Le blob d'une note, au schéma réel :
    /// NoteStoreProto.document (2) → Document.note (3) → Note.note_text (2),
    /// avec le `version` (Document, champ 2, varint) qu'il faut savoir sauter.
    static func noteStore(text: String) -> Data {
        let note = string(2, text) + message(5, Data([0x08, 0x01]))
        let document = number(2, 12) + message(3, note)
        return message(2, document)
    }

    /// gzip minimal : en-tête de dix octets, DEFLATE nu, pied ignoré par le
    /// lecteur (qui ne vérifie ni le CRC ni la taille).
    static func gzip(_ data: Data) -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        out.append(deflate(data))
        out.append(Data(repeating: 0, count: 8))
        return out
    }

    static func deflate(_ input: Data) -> Data {
        let bufferSize = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, COMPRESSION_STREAM_ENCODE,
                                      COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        else { return Data() }
        defer { compression_stream_destroy(streamPtr) }
        var output = Data()
        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            streamPtr.pointee.src_ptr = base
            streamPtr.pointee.src_size = raw.count
            streamPtr.pointee.dst_ptr = destination
            streamPtr.pointee.dst_size = bufferSize
            var status = COMPRESSION_STATUS_OK
            repeat {
                status = compression_stream_process(
                    streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - streamPtr.pointee.dst_size
                if produced > 0 { output.append(destination, count: produced) }
                streamPtr.pointee.dst_ptr = destination
                streamPtr.pointee.dst_size = bufferSize
            } while status == COMPRESSION_STATUS_OK
        }
        return output
    }
}

// MARK: - Le lecteur de protobuf

final class NotesProtobufTests: XCTestCase {

    /// Le chemin documenté (2 → 3 → 2), varint de `version` compris.
    func testReadsTheNoteTextAtTheDocumentedPath() {
        let blob = ProtoFixture.noteStore(text: "Rendez-vous chez le notaire\nle 12 mars")
        XCTAssertEqual(NotesProtobuf.noteText(inProtobuf: blob),
                       "Rendez-vous chez le notaire\nle 12 mars")
    }

    /// Le même blob, gzippé, tel qu'il est dans `ZICNOTEDATA.ZDATA`.
    func testReadsThroughGzip() {
        let blob = ProtoFixture.gzip(ProtoFixture.noteStore(text: "azote et catalyseur"))
        XCTAssertEqual(NotesProtobuf.noteText(inCompressed: blob),
                       "azote et catalyseur")
    }

    /// Un blob dont l'arborescence a changé : le repli rend tout de même le
    /// texte le plus long, plutôt qu'un fichier vide sans un mot.
    func testFallsBackToTheLongestStringWhenTheTreeChanged() {
        let inner = ProtoFixture.string(7, "Helvetica")
            + ProtoFixture.string(9, "un paragraphe entier de la note, bien plus long")
        let blob = ProtoFixture.message(4, inner)
        XCTAssertEqual(NotesProtobuf.noteText(inProtobuf: blob),
                       "un paragraphe entier de la note, bien plus long")
    }

    /// Des octets qui ne sont pas un protobuf ne doivent rien rendre — et
    /// surtout rien faire tomber.
    func testGarbageYieldsNothing() {
        XCTAssertNil(NotesProtobuf.noteText(inCompressed: Data([0x00, 0x01, 0x02])))
        XCTAssertNil(NotesProtobuf.noteText(inCompressed: Data()))
    }

    /// L'en-tête gzip porte des champs optionnels (nom du fichier) qu'il faut
    /// sauter : les compter mal décalerait tout le flux.
    /// CM-14 : `ZDATA` est un blob qui vient d'ailleurs (une base d'Apple Notes,
    /// une base Bear, une note partagée par iCloud) et rien ne bornait sa
    /// décompression — 1 Mio de gzip rend 1 Gio de zéros. Le processus qui
    /// décompresse est l'application ou l'agent.
    func testAnOversizedNoteIsRefusedBeforeItIsAllocated() throws {
        let blob = ProtoFixture.gzip(Data(repeating: 0, count: 4 << 20))
        let limit = 1 << 20
        XCTAssertThrowsError(try SourceGzip.inflate(blob, maxBytes: limit)) {
            XCTAssertEqual($0 as? SourceGzip.Failure,
                           SourceGzip.Failure.tooLarge(limit: limit))
        }
        // La garde est posée AVANT l'ajout : ce qui a été alloué ne dépasse
        // jamais le plafond d'un tampon de sortie (64 Kio).
        XCTAssertLessThan(blob.count, limit, "le blob COMPRESSÉ, lui, est minuscule")

        // Sans plafond serré, le même flux se lit normalement.
        XCTAssertEqual(try SourceGzip.inflate(blob).count, 4 << 20)
        // Le plafond par défaut est celui de bsdtar, et le motif est lisible.
        XCTAssertEqual(SourceGzip.maxDecompressedBytes, 128 << 20)
        XCTAssertEqual(SourceGzip.tooLargeReason(limit: 128 << 20),
                       "note too large after decompression (limit 128 MiB)")
    }

    /// Le motif remonte là où la matérialisation rapporte une note illisible,
    /// et les autres notes s'écrivent quand même.
    func testAnOversizedNoteIsReportedAndTheOthersAreStillWritten() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let broken = SourceNote(
            id: "A", title: "Note énorme", text: "",
            modified: Date(timeIntervalSince1970: 1_700_000_000),
            openURL: URL(string: "applenotes://x/A")!,
            problem: SourceGzip.tooLargeReason(limit: 128 << 20))
        let fine = SourceNote(
            id: "B", title: "Notaire", text: "Rendez-vous le 12 mars",
            modified: Date(timeIntervalSince1970: 1_700_000_000),
            openURL: URL(string: "applenotes://x/B")!)

        let report = SourceMaterializer.write(notes: [broken, fine],
                                              sourceID: "notes", into: directory)
        XCTAssertEqual(report.written, 1)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(report.errors[0].contains("note too large after decompression"),
                      report.errors[0])
        XCTAssertTrue(report.errors[0].contains("Note énorme"), report.errors[0])
    }

    func testGzipHeaderWithAFileNameIsSkipped() throws {
        let payload = Data("note".utf8)
        var blob = Data([0x1f, 0x8b, 0x08, 0x08, 0, 0, 0, 0, 0x00, 0x03])
        blob.append(Data("note.txt\0".utf8))
        blob.append(ProtoFixture.deflate(payload))
        XCTAssertEqual(try SourceGzip.inflate(blob), payload)
    }
}

// MARK: - La matérialisation

final class SourceMaterializerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fouine-f4-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func note(_ id: String, _ title: String, _ text: String,
                      modified: Date = Date(timeIntervalSince1970: 1_700_000_000),
                      deleted: Bool = false, locked: Bool = false) -> SourceNote {
        SourceNote(id: id, title: title, text: text, modified: modified,
                   openURL: URL(string: "notes://showNote?identifier=\(id)")!,
                   deleted: deleted, locked: locked)
    }

    /// Le nom : titre nettoyé, borné, suffixé par l'identifiant. Un titre qui
    /// commence par un point ferait un fichier CACHÉ, que le crawl saute.
    func testFileNameIsCleanedBoundedAndSuffixed() {
        XCTAssertEqual(SourceMaterializer.fileName(title: "Courses/urgent : lundi",
                                                   id: "ABCDEF0123456789"),
                       "Courses urgent   lundi-ABCDEF01.md")
        XCTAssertEqual(SourceMaterializer.fileName(title: ".cachée", id: "XY"),
                       "cachée-XY.md")
        XCTAssertEqual(SourceMaterializer.fileName(title: "   ", id: "XY"),
                       "Untitled-XY.md")
        let long = SourceMaterializer.fileName(
            title: String(repeating: "a", count: 200), id: "12345678")
        XCTAssertEqual(long.count, SourceMaterializer.titleLimit + "-12345678.md".count)
    }

    /// Le titre est dans le CORPS : Fouine n'indexe pas les noms de fichiers,
    /// un titre qui n'y serait pas ne serait pas cherchable (SPEC §5.3 (e)).
    func testContentsCarryTheTitleAndTheReopeningLink() {
        let body = SourceMaterializer.contents(sourceID: "notes",
                                               note: note("A1", "Notaire", "corps"))
        XCTAssertTrue(body.contains("# Notaire"))
        XCTAssertEqual(SourceLinks.sourceID(inMarkdown: body), "notes")
        XCTAssertEqual(SourceLinks.openURL(inMarkdown: body)?.absoluteString,
                       "notes://showNote?identifier=A1")
        XCTAssertTrue(body.hasSuffix("\n"))
    }

    /// Écriture, `mtime` de la note, effacement de ce qui a disparu, et rien à
    /// réécrire au second passage.
    func testWriteThenSecondPassChangesNothing() throws {
        let notes = [note("A1", "Notaire", "chez maître Dupont"),
                     note("B2", "Courses", "pain, lait"),
                     note("C3", "Vieille", "jetée", deleted: true),
                     note("D4", "Secrète", "", locked: true)]
        var report = SourceMaterializer.write(notes: notes, sourceID: "notes",
                                              into: directory)
        XCTAssertEqual(report.written, 2)
        XCTAssertEqual(report.skipped, 2, "corbeille et note verrouillée")
        XCTAssertTrue(report.errors.isEmpty)

        let file = directory.appendingPathComponent("Notaire-A1.md")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let modified = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertEqual(modified.timeIntervalSince1970, 1_700_000_000, accuracy: 1,
                       "le mtime doit être celui de la note (crawl delta)")

        // Second passage : rien n'a changé, donc rien n'est réécrit.
        report = SourceMaterializer.write(notes: notes, sourceID: "notes",
                                          into: directory)
        XCTAssertEqual(report.written, 0)
        XCTAssertEqual(report.unchanged, 2)

        // La note passe à la corbeille : son fichier s'en va.
        let trashed = [note("A1", "Notaire", "chez maître Dupont"),
                       note("B2", "Courses", "pain, lait", deleted: true)]
        report = SourceMaterializer.write(notes: trashed, sourceID: "notes",
                                          into: directory)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Courses-B2.md").path))
    }

    /// Une note modifiée est réécrite, avec le nouveau `mtime`.
    func testEditedNoteIsRewritten() throws {
        _ = SourceMaterializer.write(notes: [note("A1", "Notaire", "v1")],
                                     sourceID: "notes", into: directory)
        let later = Date(timeIntervalSince1970: 1_700_009_999)
        let report = SourceMaterializer.write(
            notes: [note("A1", "Notaire", "version deux, plus longue", modified: later)],
            sourceID: "notes", into: directory)
        XCTAssertEqual(report.written, 1)
        let text = try String(contentsOf: directory.appendingPathComponent("Notaire-A1.md"),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("version deux"))
    }
}

// MARK: - La synchronisation

/// Une base réduite aux trois méthodes des racines.
final class FakeRootStore: SourceRootStore, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var records: [RootRecord] = []
    private(set) var addCalls = 0
    private var next: Int64 = 1
    var failure: Error?

    func roots() throws -> [RootRecord] {
        if let failure { throw failure }
        lock.lock(); defer { lock.unlock() }
        return records
    }

    func addRoot(path: URL, label: String?) throws -> Int64 {
        if let failure { throw failure }
        lock.lock(); defer { lock.unlock() }
        addCalls += 1
        let id = next
        next += 1
        records.append(RootRecord(id: id, volUUID: "TEST", relPath: path.path,
                                  label: label ?? path.lastPathComponent,
                                  enabled: true))
        return id
    }

    func removeRoot(id: Int64) throws {
        if let failure { throw failure }
        lock.lock(); records.removeAll { $0.id == id }; lock.unlock()
    }
}

/// Une source d'essai : ni base, ni application, seulement des notes.
struct FakeSource: AppSource {
    let id = "notes"
    let displayName = "Apple Notes"
    let rootLabel = "Notes"
    let openURLTemplate = "notes://showNote?identifier=%@"
    let bundleIdentifiers: [String] = []
    let storeURL = URL(fileURLWithPath: "/dev/null")
    var stored: [SourceNote] = []
    var error: SourceError?

    func isPresent(fileManager: FileManager) -> Bool { error == nil }
    func probe(fileManager: FileManager) -> SourcePresence {
        error == nil ? .ready : .accessDenied
    }
    func notes() throws -> [SourceNote] {
        if let error { throw error }
        return stored
    }
}

final class SourceSyncTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fouine-f4-sync-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func note(_ id: String, _ title: String) -> SourceNote {
        SourceNote(id: id, title: title, text: "corps de \(title)",
                   modified: Date(timeIntervalSince1970: 1_700_000_000),
                   openURL: URL(string: "notes://showNote?identifier=\(id)")!)
    }

    /// La racine est créée UNE fois : deux passes ne doivent pas laisser deux
    /// racines « Notes » dans la base.
    func testRootIsCreatedOnceAndTheReportCounts() {
        let store = FakeRootStore()
        let source = FakeSource(stored: [note("A1", "Notaire"), note("B2", "Courses")])

        var report = SourceSync.run(store: store, sources: [source],
                                    directory: directory)
        XCTAssertEqual(report.written, 2)
        XCTAssertEqual(report.files, 2)
        XCTAssertEqual(store.addCalls, 1)
        XCTAssertEqual(store.records.first?.label, "Notes")
        XCTAssertTrue(report.errors.isEmpty)

        report = SourceSync.run(store: store, sources: [source], directory: directory)
        XCTAssertEqual(store.addCalls, 1, "la racine existe déjà")
        XCTAssertEqual(report.written, 0)
        XCTAssertEqual(report.files, 2)
    }

    /// Un refus TCC ne fait rien tomber : il devient une phrase de bilan, celle
    /// qui nomme le geste.
    func testAccessDeniedBecomesAReportEntryNotAThrow() {
        let store = FakeRootStore()
        let source = FakeSource(error: .accessDenied(source: "Apple Notes"))
        var logged: [String] = []
        let report = SourceSync.run(store: store, sources: [source],
                                    directory: directory) { logged.append($0) }
        XCTAssertEqual(report.entries.count, 1)
        let message = try? XCTUnwrap(report.entries.first?.error)
        XCTAssertTrue((message ?? "").contains("Full Disk Access"),
                      "le motif doit nommer le geste : \(message ?? "nil")")
        XCTAssertEqual(store.addCalls, 0, "aucune racine pour une source illisible")
        XCTAssertFalse(logged.isEmpty)
    }

    /// Éteindre efface les copies ET la racine : laisser l'un des deux ferait
    /// de la désactivation un demi-geste.
    func testDisableRemovesTheFolderAndTheRoot() throws {
        let store = FakeRootStore()
        let source = FakeSource(stored: [note("A1", "Notaire")])
        _ = SourceSync.run(store: store, sources: [source], directory: directory)
        XCTAssertEqual(store.records.count, 1)

        let entry = SourceSync.disable(source: source, store: store,
                                       directory: directory)
        XCTAssertEqual(entry.removed, 1)
        XCTAssertNil(entry.error)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Notes").path))
    }
}

// MARK: - De la note au résultat de recherche

/// LE test qui compte : une note recopiée est-elle trouvable ?
///
/// Il passe par la vraie base, le vrai crawl et la vraie extraction — c'est
/// tout l'intérêt du parti pris de ce lot : une note n'est qu'un fichier, et
/// rien du chemin d'indexation n'a été modifié pour elle.
final class SourceIndexingTests: XCTestCase {

    func testAMaterializedNoteBecomesSearchable() throws {
        let scratch = try IndexScratch("sources-index", documents: 0)
        let directory = scratch.directory.appendingPathComponent("Sources",
                                                                 isDirectory: true)
        let source = FakeSource(stored: [
            SourceNote(id: "A1B2", title: "Rendez-vous chez le notaire",
                       text: "signature de l'acte, apporter le chromatogramme",
                       modified: Date(timeIntervalSince1970: 1_700_000_000),
                       openURL: URL(string: "notes://showNote?identifier=A1B2")!),
        ])
        let report = SourceSync.run(store: scratch.store, sources: [source],
                                    directory: directory)
        XCTAssertEqual(report.written, 1)

        // Les racines sont relues APRÈS la synchronisation : c'est ce que fait
        // la commande `sources enable`, et c'est pourquoi elle synchronise
        // elle-même au lieu de laisser la passe créer une racine qu'elle ne
        // parcourrait qu'au tour suivant.
        let roots = try scratch.store.roots()
        XCTAssertTrue(roots.contains { $0.label == "Notes" })
        try IndexPass(store: scratch.store)
            .run(roots: roots,
                 options: IndexPassOptions(crawl: .full, warmVocabulary: false))

        // Le CORPS de la note, et son TITRE : Fouine n'indexe pas les noms de
        // fichiers, le titre ne serait donc pas trouvable s'il n'était pas
        // recopié dans le corps du document.
        for term in ["chromatogramme", "notaire"] {
            let results = try scratch.store.search(SearchQuery(fts: term))
            XCTAssertEqual(results.hits.count, 1, "« \(term) » devrait trouver la note")
            XCTAssertEqual((results.hits.first?.path as NSString?)?.lastPathComponent,
                           "Rendez-vous chez le notaire-A1B2.md")
        }
    }

    /// `RootPolicy` (FouineCrawl) tient sa propre liste des applications, pour
    /// refuser leur dossier avec la case à cocher plutôt qu'avec « dossier
    /// système ». FouineCrawl ne voit pas FouineIndex : c'est ICI que les deux
    /// listes se comparent — une quatrième source oubliée dans `RootPolicy`
    /// retomberait sinon sur la phrase fausse sans que rien ne rougisse.
    func testRootPolicyKnowsEveryApplicationStore() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        XCTAssertEqual(Set(AppSources.all.map(\.id)),
                       Set(RootPolicy.Application.allCases.map(\.rawValue)))
        for source in AppSources.all {
            let store = source.storeURL.standardizedFileURL.path
            XCTAssertEqual(RootPolicy.application(owning: store, home: home)?.rawValue,
                           source.id, "\(source.id) : \(store)")
        }
    }
}
