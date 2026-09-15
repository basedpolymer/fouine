// TestSupport.swift — base SQLite temporaire par test. Propriété : A-Core.

import Foundation
import XCTest
@testable import FouineCore

/// Une base neuve, dans son propre dossier (donc son propre `fouine.lock`).
///
/// `lockTimeout` : les tests qui prouvent qu'un verrou TENU est refusé n'ont
/// pas à attendre les cinq secondes de production pour lire le même
/// `fouine-lock-busy` — 0,3 s suffit à traverser la boucle de `flock` (pas de
/// 50 ms) et à lire le détenteur à l'échéance.
final class TempDB {
    let directory: URL
    let store: GRDBStore

    init(lockTimeout: TimeInterval = 5) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        store = GRDBStore(lockTimeout: lockTimeout)
        try store.open(at: directory.appendingPathComponent("fouine.db"))
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

extension XCTestCase {
    func makeDB(lockTimeout: TimeInterval = 5) throws -> TempDB {
        try TempDB(lockTimeout: lockTimeout)
    }

    @discardableResult
    func addDoc(_ db: TempDB, relPath: String, ext: String = "pdf",
                folder: String = "Livres", size: Int64 = 1_000,
                mtime: Double = 1_700_000_000, lang: String? = nil) throws -> Int64 {
        try db.store.upsertDoc(DocRecord(
            volUUID: "TEST-VOL", relPath: relPath, ext: ext, topFolder: folder,
            size: size, mtime: mtime, lang: lang))
    }

    func page(_ n: Int, _ text: String, _ source: PageSource = .native) -> PageText {
        PageText(page: n, text: text, source: source)
    }

    func ocrPage(_ text: String, lines: [OCRLine]? = nil,
                 confidence: Double = 0.9) -> OCRPage {
        let effective = lines ?? [OCRLine(text: text, x: 0.1, y: 0.8, w: 0.6, h: 0.02,
                                          confidence: confidence)]
        return OCRPage(text: text, lines: effective, level: .accurate, seconds: 1,
                       engine: .vision, engineRev: "vision-rev3",
                       meanConfidence: confidence)
    }

    func query(_ input: String, limit: Int = 50, fuzzy: FuzzyMode = .off,
               scope: FuzzyScope = .ocrOnly, inDocIDs: [Int64] = []) throws -> SearchQuery {
        try QueryParser.searchQuery(input, limit: limit, inDocIDs: inDocIDs,
                                    fuzzy: fuzzy, fuzzyScope: scope)
    }
}
