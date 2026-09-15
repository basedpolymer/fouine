// InMemoryStore.swift — double de test d'IndexStore (A-Core code le vrai store
// GRDB en parallèle, vague 1). Propriété : A-Ingest, cible de test uniquement.
//
// Reproduit les deux comportements dont le crawl dépend :
//   · `upsertDoc` est un NO-OP quand (size, mtime) sont inchangés — c'est ce qui
//     rend `fouine index` idempotent (T10) : l'état du document n'est PAS remis
//     à `.discovered`, sinon tout serait ré-extrait à chaque passe ;
//   · `docs(underRoot:)` liste les documents connus d'une racine, et `removeDoc`
//     les purge (§5.2).
// Le reste du protocole n'est pas exercé ici : `fatalError` documente que ces
// méthodes appartiennent à A-Core.

import Foundation
import FouineCore
import FouineCrawl

final class InMemoryStore: IndexStore, @unchecked Sendable {
    private let lock = NSLock()

    private var rootList: [RootRecord] = []
    private var byPath: [String: (id: Int64, record: DocRecord)] = [:]
    private var nextID: Int64 = 1
    private var fsEventIDs: [String: UInt64] = [:]

    // Compteurs d'observation, pour les tests.
    private(set) var upsertCount = 0
    private(set) var noopUpsertCount = 0
    private(set) var removedIDs: [Int64] = []
    /// Nombre d'appels NON VIDES à `relocateDocs` : un déplacement de dossier
    /// doit en coûter UN, pas un par document.
    private(set) var relocateCount = 0

    // MARK: - Mise en place

    func addRoot(_ root: RootRecord) {
        lock.lock(); defer { lock.unlock() }
        rootList.append(root)
    }

    var allDocs: [(id: Int64, record: DocRecord)] {
        lock.lock(); defer { lock.unlock() }
        return byPath.values.sorted { $0.record.relPath < $1.record.relPath }
    }

    func doc(relPath: String) -> DocRecord? {
        lock.lock(); defer { lock.unlock() }
        return byPath[relPath]?.record
    }

    /// Force l'inode d'une ligne — le seul moyen de simuler une base migrée
    /// depuis le schéma v5, où toutes les lignes valent 0.
    func forceInode(_ inode: Int64, on id: Int64) {
        lock.lock(); defer { lock.unlock() }
        if let key = byPath.first(where: { $0.value.id == id })?.key {
            byPath[key]?.record.inode = inode
        }
    }

    func resetCounters() {
        lock.lock(); defer { lock.unlock() }
        upsertCount = 0
        noopUpsertCount = 0
        removedIDs = []
        relocateCount = 0
    }

    // MARK: - IndexStore

    func open(at url: URL) throws {}

    func addRoot(path: URL, label: String?) throws -> Int64 {
        let resolved = try VolumeResolver.resolve(path: path)
        lock.lock(); defer { lock.unlock() }
        let id = nextID
        nextID += 1
        rootList.append(RootRecord(id: id, volUUID: resolved.volUUID,
                                   relPath: resolved.relPath,
                                   label: label ?? path.lastPathComponent,
                                   enabled: true))
        return id
    }

    func roots() throws -> [RootRecord] {
        lock.lock(); defer { lock.unlock() }
        return rootList
    }

    func removeRoot(id: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        rootList.removeAll { $0.id == id }
    }

    func volumes() throws -> [(uuid: String, label: String, lastSeen: Double?)] {
        lock.lock(); defer { lock.unlock() }
        return rootList.map { ($0.volUUID, $0.label, nil) }
    }

    func docs(underRoot rootID: Int64) throws -> [DocRow] {
        lock.lock(); defer { lock.unlock() }
        guard let root = rootList.first(where: { $0.id == rootID }) else { return [] }
        let prefix = root.relPath.isEmpty ? "" : root.relPath + "/"
        return byPath.values
            .filter { $0.record.volUUID == root.volUUID
                && (prefix.isEmpty || $0.record.relPath.hasPrefix(prefix)) }
            .map { DocRow(id: $0.id, record: $0.record) }
            .sorted { $0.record.relPath < $1.record.relPath }
    }

    func removeDoc(id: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        removedIDs.append(id)
        if let key = byPath.first(where: { $0.value.id == id })?.key {
            byPath.removeValue(forKey: key)
        }
    }

    func fseventID(volUUID: String) throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return fsEventIDs[volUUID] ?? 0
    }

    func setFSEventID(volUUID: String, _ id: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        fsEventIDs[volUUID] = id
    }

    func upsertDoc(_ d: DocRecord) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        upsertCount += 1
        if let existing = byPath[d.relPath] {
            if existing.record.size == d.size && existing.record.mtime == d.mtime {
                noopUpsertCount += 1        // delta no-op : on ne touche à RIEN
                return existing.id
            }
            var updated = d
            updated.nPages = 0
            byPath[d.relPath] = (existing.id, updated)
            return existing.id
        }
        let id = nextID
        nextID += 1
        byPath[d.relPath] = (id, d)
        return id
    }

    /// Déplacements (schéma v6, A3-02) : on ne touche QUE le chemin, l'étiquette,
    /// l'extension et l'inode — c'est justement ce que le test doit pouvoir
    /// vérifier, à côté de ce qui ne bouge pas (l'identifiant du document).
    func relocateDocs(_ moves: [DocRelocation]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !moves.isEmpty else { return }
        relocateCount += 1
        for move in moves {
            guard let key = byPath.first(where: { $0.value.id == move.id })?.key
            else { continue }
            var entry = byPath.removeValue(forKey: key)!
            entry.record.relPath = move.relPath
            entry.record.topFolder = move.topFolder
            entry.record.ext = move.ext
            entry.record.inode = move.inode
            byPath[move.relPath] = entry
        }
    }

    func replacePages(docID: Int64, pages: [PageText]) throws {
        fatalError("hors périmètre A-Ingest")
    }
    func setDocState(_ id: Int64, _ s: DocState, err: String?) throws {
        lock.lock(); defer { lock.unlock() }
        if let key = byPath.first(where: { $0.value.id == id })?.key {
            byPath[key]?.record.state = s
            byPath[key]?.record.err = err
        }
    }
    func enqueueOCR(docID: Int64, pages: [Int], priority: Int) throws {
        fatalError("hors périmètre A-Ingest")
    }
    func nextOCRBatch(limit: Int) throws -> [(docID: Int64, page: Int, path: String)] {
        fatalError("hors périmètre A-Ingest")
    }
    func completeOCR(docID: Int64, page: Int, result: OCRPage) throws {
        fatalError("hors périmètre A-Ingest")
    }
    func failOCR(docID: Int64, page: Int) throws {
        fatalError("hors périmètre A-Ingest")
    }
    func search(_ q: SearchQuery) throws -> SearchResults {
        fatalError("hors périmètre A-Ingest")
    }
    func facets(_ q: SearchQuery, by: FacetKey) throws -> [(String, Int)] {
        fatalError("hors périmètre A-Ingest")
    }
    func stats() throws -> [String: Int] {
        fatalError("hors périmètre A-Ingest")
    }
    func topVocabulary(limit: Int, minLength: Int) throws -> [String] {
        fatalError("hors périmètre A-Ingest")
    }
}

// MARK: - Règles gardées (lot IG2)

/// Les règles gardées d'une racine, par un double à part : le crawl ne les
/// demande qu'à un store qui porte `StoredIgnoreRulesStore`, et les tests
/// d'avant IG2 doivent continuer d'éprouver le crawl SANS elles.
final class KeepingStore: IndexStore, StoredIgnoreRulesStore, @unchecked Sendable {
    let inner = InMemoryStore()
    private let lock = NSLock()
    private var kept: [Int64: String] = [:]

    func keep(_ json: String?, rootID: Int64) {
        lock.lock(); defer { lock.unlock() }
        kept[rootID] = json
    }

    func ignoreRulesJSON(rootID: Int64) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return kept[rootID]
    }

    func open(at url: URL) throws {}
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
    func fseventID(volUUID: String) throws -> UInt64 { try inner.fseventID(volUUID: volUUID) }
    func setFSEventID(volUUID: String, _ id: UInt64) throws {
        try inner.setFSEventID(volUUID: volUUID, id)
    }
    func upsertDoc(_ d: DocRecord) throws -> Int64 { try inner.upsertDoc(d) }
    func relocateDocs(_ moves: [DocRelocation]) throws { try inner.relocateDocs(moves) }
    func replacePages(docID: Int64, pages: [PageText]) throws {
        try inner.replacePages(docID: docID, pages: pages)
    }
    func setDocState(_ id: Int64, _ s: DocState, err: String?) throws {
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
    func failOCR(docID: Int64, page: Int) throws { try inner.failOCR(docID: docID, page: page) }
    func search(_ q: SearchQuery) throws -> SearchResults { try inner.search(q) }
    func facets(_ q: SearchQuery, by: FacetKey) throws -> [(String, Int)] {
        try inner.facets(q, by: by)
    }
    func stats() throws -> [String: Int] { try inner.stats() }
    func topVocabulary(limit: Int, minLength: Int) throws -> [String] {
        try inner.topVocabulary(limit: limit, minLength: minLength)
    }
}
