// IndexScratch.swift — base et racine JETABLES, en processus. Propriété : A-Core.
//
// Même règle que la recette (audit S3) : AUCUN test ne lit ni n'écrit la base de
// production ni les racines réelles. La différence avec `Tests/Integration` est
// qu'ici tout se passe DANS le processus de test — pas de binaire à construire,
// pas de `Process` : `IndexPass` est une bibliothèque, on l'appelle.
//
// Le fichier fournit aussi `FailingStore`, le mandataire qui fait échouer la
// Nième écriture : c'est le seul moyen d'éprouver le chemin « erreur fatale »
// sans débrancher un disque à la main.

import Foundation
import XCTest
import FouineCore
@testable import FouineIndex

/// Une racine et une base temporaires, détruites en fin de test.
final class IndexScratch {

    let directory: URL
    let root: URL
    let database: URL
    let store: GRDBStore
    let rootRecord: RootRecord

    /// - Parameter documents: fiches `.txt` déposées sous la racine.
    /// - Parameter brokenPDFs: fichiers `.pdf` au contenu illisible. PDFKit
    ///   rend `nil` sur `PDFDocument(url:)` (décision D2) : l'extracteur lève
    ///   `.extraction`, qui est l'archétype de l'erreur PAR DOCUMENT — le lot
    ///   doit continuer.
    init(_ name: String, documents: Int = 5, brokenPDFs: Int = 0) throws {
        let fm = FileManager.default
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fouine-index-\(name)-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        root = directory.appendingPathComponent("racine", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        for index in 0..<documents {
            let body = """
                Fiche \(index) du corpus jetable de FouineIndexTests.
                \(String(repeating: "azote reduction catalyseur oxydation. ", count: 4))
                """
            try body.write(to: root.appendingPathComponent("fiche-\(index).txt"),
                           atomically: true, encoding: .utf8)
        }
        for index in 0..<brokenPDFs {
            try Data("ceci n'est pas un PDF".utf8)
                .write(to: root.appendingPathComponent("casse-\(index).pdf"))
        }

        database = directory.appendingPathComponent("index.db")
        store = GRDBStore()
        try store.open(at: database)
        let id = try store.addRoot(path: root, label: "Jetable")
        rootRecord = try XCTUnwrap(store.roots().first { $0.id == id })
        // `addRoot` écrit, donc prend `fouine.lock` PARESSEUSEMENT. On le rend :
        // un processus qui vient d'enregistrer une racine et s'arrête là — la
        // CLI de `fouine root add` — le rend en sortant. Les tests partent donc
        // d'un verrou LIBRE, comme la réalité.
        store.releaseWriteLock()
    }

    deinit {
        store.releaseWriteLock()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Le verrou porte le nom de la base (BU-30) : ici `index.lock`.
    var lockURL: URL { FouinePaths.lockURL(for: database) }

    /// Le contenu de `fouine.lock`. Vide = verrou libre.
    func lockContents() -> String {
        (try? String(contentsOf: lockURL, encoding: .utf8)) ?? ""
    }

    func state(ofDocumentAt relPathSuffix: String) throws -> (DocState, String?) {
        let rows = try store.docs(underRoot: rootRecord.id)
        let row = try XCTUnwrap(rows.first { $0.record.relPath.hasSuffix(relPathSuffix) })
        return (row.record.state, row.record.err)
    }

    func documents() throws -> [DocRow] { try store.docs(underRoot: rootRecord.id) }
}

// MARK: - Observateur d'essai

/// Enregistre tout ce que la passe raconte, et sait déclencher une annulation.
final class RecordingObserver: IndexPassObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [IndexPassEvent] = []
    /// Appelée après chaque `.document`, avec le rang du document (1, 2, 3…).
    var onDocument: (@Sendable (Int) -> Void)?

    func indexPass(_ event: IndexPassEvent) {
        lock.lock()
        events.append(event)
        let rank = events.filter { if case .document = $0 { return true }; return false }
            .count
        let hook = onDocument
        lock.unlock()
        if case .document = event { hook?(rank) }
    }

    func all() -> [IndexPassEvent] {
        lock.lock(); defer { lock.unlock() }; return events
    }

    var documents: [DocumentOutcome] {
        all().compactMap { if case .document(let d) = $0 { return d }; return nil }
    }

    var notes: [String] {
        all().compactMap { if case .note(let n) = $0 { return n }; return nil }
    }

    /// Les documents dont la lecture a COMMENCÉ (ST1).
    var started: [String] {
        all().compactMap { if case .willExtract(let d) = $0 { return d }; return nil }
    }

    /// Ceux qui en sont sortis sans être comptés : l'arrêt est arrivé pendant
    /// leur lecture (ST1).
    var abandoned: [String] {
        all().compactMap { if case .abandoned(let d) = $0 { return d }; return nil }
    }

    var crawled: [(root: String, summary: CrawlSummary)] {
        all().compactMap {
            if case .crawled(let r, let s) = $0 { return (r, s) }
            return nil
        }
    }

    var finishedSummaries: [IndexPassSummary] {
        all().compactMap { if case .finished(let s) = $0 { return s }; return nil }
    }
}

// MARK: - Injection d'une panne de base

/// Mandataire qui laisse tout passer vers un vrai `GRDBStore`, sauf `failing`,
/// qui lève une `databaseFailure` à partir du Nième appel.
///
/// Ce n'est PAS un bouchon : le crawl, les racines, les pages, la file OCR
/// travaillent sur la vraie base. Seule l'écriture visée ment — c'est ce qui
/// rend le test représentatif d'un disque plein ou d'une base corrompue en
/// cours de passe.
final class FailingStore: IndexPassStore, @unchecked Sendable {

    enum Operation: Sendable { case replacePages, setDocState, upsertDoc }

    private let inner: GRDBStore
    private let failing: Operation
    private let afterCalls: Int
    private let lock = NSLock()
    private var calls = 0

    init(_ inner: GRDBStore, fail operation: Operation, after calls: Int) {
        self.inner = inner
        self.failing = operation
        self.afterCalls = calls
    }

    private func check(_ operation: Operation) throws {
        guard operation == failing else { return }
        lock.lock()
        calls += 1
        let now = calls
        lock.unlock()
        guard now > afterCalls else { return }
        throw FouineError.databaseFailure("disque plein (simulé par FailingStore)")
    }

    // MARK: IndexPassStore

    func setPageCount(_ id: Int64, _ n: Int) throws {
        try inner.setPageCount(id, n)
    }
    func setDocLanguage(_ id: Int64, _ lang: String?) throws {
        try inner.setDocLanguage(id, lang)
    }
    func setDocDate(_ id: Int64, _ date: Double?) throws {
        try inner.setDocDate(id, date)
    }
    /// Transmis : le rattrapage de langue lit et écrit la VRAIE base, c'est ce
    /// que les tests de fin de passe vérifient (lot U3).
    func backfillLanguages(limit: Int, sampleCharacters: Int, chunk: Int,
                           detect: ([PageText]) -> String?)
        throws -> LanguageBackfillReport {
        try inner.backfillLanguages(limit: limit,
                                    sampleCharacters: sampleCharacters,
                                    chunk: chunk, detect: detect)
    }
    /// Transmise : la passe lit les racines épinglées au démarrage (audit U2),
    /// et les tests de priorité s'appuient sur la vraie table.
    func settingsRows() throws -> [String: String] { try inner.settingsRows() }
    func optimize() throws { try inner.optimize() }
    func warmVocabulary() throws { try inner.warmVocabulary() }
    func acquireWriteLock(as role: LockRole) throws {
        try inner.acquireWriteLock(as: role)
    }
    func releaseWriteLock() { inner.releaseWriteLock() }
    func setWriteLockLog(_ log: @escaping @Sendable (String) -> Void) {
        inner.setWriteLockLog(log)
    }

    // MARK: IndexStore — tout est transmis

    func open(at url: URL) throws { try inner.open(at: url) }
    func addRoot(path: URL, label: String?) throws -> Int64 {
        try inner.addRoot(path: path, label: label)
    }
    func roots() throws -> [RootRecord] { try inner.roots() }
    func removeRoot(id: Int64) throws { try inner.removeRoot(id: id) }
    func volumes() throws -> [(uuid: String, label: String, lastSeen: Double?)] {
        try inner.volumes()
    }
    func docs(underRoot rootID: Int64) throws -> [DocRow] {
        try inner.docs(underRoot: rootID)
    }
    func removeDoc(id: Int64) throws { try inner.removeDoc(id: id) }
    func fseventID(volUUID: String) throws -> UInt64 {
        try inner.fseventID(volUUID: volUUID)
    }
    func setFSEventID(volUUID: String, _ id: UInt64) throws {
        try inner.setFSEventID(volUUID: volUUID, id)
    }
    func upsertDoc(_ d: DocRecord) throws -> Int64 {
        try check(.upsertDoc)
        return try inner.upsertDoc(d)
    }
    func relocateDocs(_ moves: [DocRelocation]) throws {
        try inner.relocateDocs(moves)
    }
    func replacePages(docID: Int64, pages: [PageText]) throws {
        try check(.replacePages)
        try inner.replacePages(docID: docID, pages: pages)
    }
    func setDocState(_ id: Int64, _ s: DocState, err: String?) throws {
        try check(.setDocState)
        try inner.setDocState(id, s, err: err)
    }
    func enqueueOCR(docID: Int64, pages: [Int], priority: Int) throws {
        try inner.enqueueOCR(docID: docID, pages: pages, priority: priority)
    }
    func nextOCRBatch(limit: Int) throws -> [(docID: Int64, page: Int, path: String)] {
        try inner.nextOCRBatch(limit: limit)
    }
    func completeOCR(docID: Int64, page: Int, result: OCRPage) throws {
        try inner.completeOCR(docID: docID, page: page, result: result)
    }
    func failOCR(docID: Int64, page: Int) throws {
        try inner.failOCR(docID: docID, page: page)
    }
    func search(_ q: SearchQuery) throws -> SearchResults { try inner.search(q) }
    func facets(_ q: SearchQuery, by key: FacetKey) throws -> [(String, Int)] {
        try inner.facets(q, by: key)
    }
    func stats() throws -> [String: Int] { try inner.stats() }
    func topVocabulary(limit: Int, minLength: Int) throws -> [String] {
        try inner.topVocabulary(limit: limit, minLength: minLength)
    }
}
