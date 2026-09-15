// WindowingTests.swift — fenêtrage sémantique (schéma v5, constat C2-05).
// Propriété : A-Embed (03/09/2026).
//
// Trois choses à vérifier, et elles se tiennent : le DÉCOUPAGE (combien de
// fenêtres pour quelle longueur, et lesquelles), l'ÉCONOMIE (une fenêtre déjà
// en base n'est jamais ré-inférée, et la sentinelle de complétude est ce qui
// rend la sélection de lot possible) et le REPLI (l'index rend des pages, pas
// des fenêtres). Les aides communes — `makeDB`, `addDoc`, `page`,
// `text(ofLength:)`, `FakeEngine`, `RecordingEngine` — vivent dans
// EmbedTests.swift, même cible.

import Foundation
import XCTest
@testable import FouineEmbed
@testable import FouineCore

final class WindowingTests: XCTestCase {

    // MARK: · Découpage

    /// La table de référence de la conception, longueur par longueur. Elle est
    /// ici plutôt que dans un commentaire parce que c'est elle qui décide du
    /// coût d'une campagne : 2,13 fenêtres par page en moyenne sur le corpus
    /// de production (C2-05).
    func testWindowCountPerPageLength() {
        let expected: [(length: Int, windows: Int)] = [
            (0, 1), (99, 1), (100, 1), (1_400, 1), (1_401, 2),
            (2_700, 2), (2_701, 3), (4_000, 3), (10_000, 3),
        ]
        for row in expected {
            XCTAssertEqual(Schema.vecWindowCount(forLength: row.length),
                           row.windows, "\(row.length) caractère(s)")
            XCTAssertEqual(EmbedRun.windows(for: text(ofLength: row.length)).count,
                           row.windows,
                           "\(row.length) caractère(s), découpage réel")
        }
    }

    /// La fenêtre 0 est EXACTEMENT le `prefix(1400)` du schéma v3 — c'est ce
    /// qui autorise à reprendre les 64 872 vecteurs de la production sans
    /// ré-inférence — et les suivantes se recouvrent de 100 caractères.
    func testWindowsCoverTheTextWithTheAnnouncedOverlap() {
        let body = (0..<4_000).map { String(UnicodeScalar(97 + $0 % 26)!) }
            .joined()
        let windows = EmbedRun.windows(for: body)
        XCTAssertEqual(windows.map(\.chunk), [0, 1, 2])
        XCTAssertEqual(windows[0].text, String(body.prefix(1_400)),
                       "la fenêtre 0 doit être le prefix(1400) du schéma v3")
        XCTAssertEqual(windows.map { $0.text.count }, [1_400, 1_400, 1_400])
        // Recouvrement : la fin de la fenêtre k est le début de la k+1.
        let chars = Array(body)
        XCTAssertEqual(windows[1].text, String(chars[1_300..<2_700]))
        XCTAssertEqual(windows[2].text, String(chars[2_600..<4_000]))
        // Au-delà de 4 000 caractères, on tronque (4,9 % des pages).
        let long = EmbedRun.windows(for: text(ofLength: 10_000))
        XCTAssertEqual(long.count, 3)
        XCTAssertEqual(long[2].text.count, 1_400)
    }

    // MARK: · Ce que la pompe écrit

    func testPumpWritesOneRowPerWindowPlusTheSentinel() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Livres/long.pdf")
        let lengths = [0, 99, 100, 1_400, 1_401, 2_700, 2_701, 4_000, 10_000]
        try db.store.replacePages(docID: doc, pages: lengths.enumerated().map {
            page($0.offset + 1, text(ofLength: $0.element))
        })

        let engine = RecordingEngine()
        let summary = try EmbedRun.run(store: db.store, engine: engine,
                                       config: silentConfig())

        // 1+1+1+1+2+2+3+3+3 = 17 fenêtres, dont une VIDE (la page de 0
        // caractère) qui ne coûte aucune inférence.
        XCTAssertEqual(engine.seen.count, 16, "fenêtres inférées")
        XCTAssertEqual(summary.embedded, lengths.count)
        XCTAssertEqual(try db.store.vectorisedPageCount(), lengths.count)
        XCTAssertEqual(try db.store.completeVectorPageCount(), lengths.count)
        // 17 fenêtres + 6 sentinelles (les six pages de moins de 3 fenêtres).
        XCTAssertEqual(try db.store.vectorCount(), 23)
        XCTAssertEqual(summary.windows, 23)

        // Créneaux exacts, page par page.
        for (i, length) in lengths.enumerated() {
            let pageRowID = Schema.ftsRowID(docID: doc, page: i + 1)
            let chunks = try db.store.existingVectorChunks(pageRowIDs: [pageRowID])
                .map { Int($0 - pageRowID * Schema.vecChunksPerPage) }
                .sorted()
            let windows = Schema.vecWindowCount(forLength: length)
            let expected = windows == Schema.vecWindowMax
                ? Array(0..<windows)
                : Array(0..<windows) + [Schema.vecWindowMax - 1]
            XCTAssertEqual(chunks, expected, "page de \(length) caractère(s)")
        }

        // La sentinelle est un blob VIDE, et l'index ne la charge pas.
        let sentinel = Schema.vecRowID(
            pageRowID: Schema.ftsRowID(docID: doc, page: 1),
            chunk: Schema.vecWindowMax - 1)
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT length(vec) FROM page_vec WHERE rowid = \(sentinel)"), [0])
        let index = try VectorIndex(store: db.store, dim: engine.dimension)
        XCTAssertEqual(index.chunkCount, 17, "les sentinelles ne se chargent pas")
        XCTAssertEqual(index.pageCount, lengths.count)
    }

    /// Une page sous `minChars` reçoit un vecteur NUL en fenêtre 0 et sa
    /// sentinelle — donc aucune inférence, et elle ne revient jamais.
    func testShortPageGetsAZeroVectorAndItsSentinel() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Livres/court.pdf")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "Page blanche volontairement.")])

        let engine = RecordingEngine()
        _ = try EmbedRun.run(store: db.store, engine: engine,
                             config: silentConfig(minChars: 100))
        XCTAssertTrue(engine.seen.isEmpty, "aucune inférence pour une page vide")

        let pageRowID = Schema.ftsRowID(docID: doc, page: 1)
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT length(vec) FROM page_vec ORDER BY rowid"), [64, 0],
                       "fenêtre 0 nulle (64 octets à zéro) puis sentinelle vide")
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT total(abs(vec)) FROM page_vec WHERE rowid = "
            + "\(Schema.vecRowID(pageRowID: pageRowID, chunk: 0))"), [0])
        XCTAssertEqual(try db.store.completeVectorPageCount(), 1)
    }

    /// Le point qui vaut treize heures de GPU : une campagne interrompue laisse
    /// des pages qui portent leur fenêtre 0 et pas les suivantes. La campagne
    /// d'après doit les revisiter ET n'inférer QUE les fenêtres manquantes.
    func testExistingWindowZeroIsNeverInferredAgain() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Livres/repris.pdf")
        let body = text(ofLength: 4_000)
        try db.store.replacePages(docID: doc, pages: [page(1, body)])

        // Ce qu'une campagne interrompue laisse : la fenêtre 0, rien d'autre.
        let pageRowID = Schema.ftsRowID(docID: doc, page: 1)
        try db.store.upsertVectors([
            (Schema.vecRowID(pageRowID: pageRowID, chunk: 0),
             Data(repeating: 42, count: 64))])

        let engine = RecordingEngine()
        let summary = try EmbedRun.run(store: db.store, engine: engine,
                                       config: silentConfig())

        XCTAssertEqual(engine.seen.count, 2,
                       "seules les fenêtres 1 et 2 devaient être inférées")
        XCTAssertEqual(Set(engine.seen),
                       Set(EmbedRun.windows(for: body).dropFirst().map(\.text)))
        XCTAssertEqual(summary.embedded, 1)
        XCTAssertEqual(try db.store.vectorCount(), 3)
        // Le vecteur repris est INTACT.
        let all = try db.store.allVectors(dim: 64)
        let position = try XCTUnwrap(all.rowids.firstIndex(
            of: Schema.vecRowID(pageRowID: pageRowID, chunk: 0)))
        XCTAssertTrue(all.data[position * 64..<(position + 1) * 64]
                        .allSatisfy { $0 == 42 })
    }

    /// Un rowid dont le créneau sort de `[0, vecWindowMax)` n'a pas été écrit
    /// par ce schéma : c'est un rowid de PAGE du schéma v3, laissé par un
    /// binaire antérieur (audit A1m-05 — 12 336 lignes dans ce cas sur la base
    /// de production du 04/09/2026, dont 1 327 se repliaient sur une page
    /// RÉELLE mais fausse). `allVectors` ne le charge pas : un vecteur qu'on ne
    /// sait pas situer ne doit jamais devenir un résultat.
    func testForeignChunkSlotsAreNotLoaded() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Livres/etranger.pdf")
        try db.store.replacePages(docID: doc, pages: [page(1, text(ofLength: 500))])
        let pageRowID = Schema.ftsRowID(docID: doc, page: 1)

        try db.store.upsertVectors([
            // Légitime : créneau 0.
            (Schema.vecRowID(pageRowID: pageRowID, chunk: 0),
             Data(repeating: 7, count: 64)),
            // Étrangers : créneaux 3 et 7, que la pompe n'écrit jamais.
            (pageRowID * Schema.vecChunksPerPage + 3, Data(repeating: 9, count: 64)),
            (pageRowID * Schema.vecChunksPerPage + 7, Data(repeating: 9, count: 64)),
        ])

        XCTAssertEqual(try db.store.vectorCount(), 3, "les trois lignes sont EN BASE")
        let all = try db.store.allVectors(dim: 64)
        XCTAssertEqual(all.rowids,
                       [Schema.vecRowID(pageRowID: pageRowID, chunk: 0)],
                       "seul le créneau valide est chargé")
        XCTAssertEqual(all.data.count, 64)
        XCTAssertTrue(all.data.allSatisfy { $0 == 7 })
    }

    /// L'invalidation emporte la page ENTIÈRE — fenêtres et sentinelle.
    func testRewritingAPageInvalidatesEveryWindow() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Livres/reecrit.pdf")
        let pages = [page(1, text(ofLength: 4_000)), page(2, text(ofLength: 200))]
        try db.store.replacePages(docID: doc, pages: pages)
        _ = try EmbedRun.run(store: db.store, engine: FakeEngine(),
                             config: silentConfig())
        XCTAssertEqual(try db.store.vectorCount(), 5,
                       "3 fenêtres + 1 fenêtre + 1 sentinelle")

        try db.store.replacePages(docID: doc, pages: pages)
        XCTAssertEqual(try db.store.vectorCount(), 0)
        XCTAssertEqual(try db.store.completeVectorPageCount(), 0)
    }

    // MARK: · Sélection de lot

    /// Le plan d'exécution est celui du schéma v3, vérifié sur la requête
    /// RÉELLE (et non sur une copie qui dériverait) : une sonde de clé
    /// primaire par page, et surtout aucun balayage de `page_vec`.
    func testSelectionPlanProbesPageVecByPrimaryKey() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Livres/plan.pdf")
        try db.store.replacePages(docID: doc, pages: (1...5).map {
            page($0, text(ofLength: 2_000))
        })
        let plan = try db.store.rawPlanDetails(
            GRDBStore.pagesNeedingVectorSQL(), arguments: [0, 4])
        let joined = plan.joined(separator: " | ")
        XCTAssertTrue(joined.contains("SEARCH v USING INTEGER PRIMARY KEY"),
                      "la jointure doit rester une sonde de clé primaire : \(joined)")
        XCTAssertFalse(joined.contains("SCAN page_vec"),
                       "page_vec ne doit JAMAIS être balayée : \(joined)")
        XCTAssertFalse(joined.contains("TEMP B-TREE"),
                       "l'ORDER BY ne doit pas ajouter de tri : \(joined)")
        XCTAssertTrue(joined.contains("SCAN f VIRTUAL TABLE INDEX 64:"),
                      "la contrainte rowid > doit être poussée dans fts5 : \(joined)")
    }

    /// GARDE-FOU. Un déclencheur SQL efface la sentinelle : la complétude ne
    /// peut donc jamais s'écrire, et la pompe boucle par construction. Elle
    /// doit s'arrêter d'elle-même, en le disant.
    func testAnEndlessCatchUpPassStopsItself() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Livres/boucle.pdf")
        try db.store.replacePages(docID: doc, pages: (1...8).map {
            page($0, "document 1 page \($0) chromatographie enthalpie polymere")
        })
        try Self.execute("""
            CREATE TRIGGER kill_sentinel AFTER INSERT ON page_vec
            WHEN NEW.rowid % \(Schema.vecChunksPerPage)
                 = \(Schema.vecWindowMax - 1)
            BEGIN DELETE FROM page_vec WHERE rowid = NEW.rowid; END;
            """, on: db.directory.appendingPathComponent("fouine.db"))

        let box = LogBox()
        var config = silentConfig()
        config.batchSize = 4
        config.log = { box.append($0) }

        let engine = RecordingEngine()
        let started = Date()
        let summary = try EmbedRun.run(store: db.store, engine: engine,
                                       config: config)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 10, "la pompe a bouclé")
        XCTAssertEqual(engine.batches, 2,
                       "les fenêtres présentes ne sont pas ré-inférées : seul "
                       + "le premier balayage infère")
        XCTAssertTrue(box.lines.contains { $0.contains("stopping instead of looping") },
                      "la pompe doit DIRE pourquoi elle s'arrête : \(box.lines)")
        XCTAssertGreaterThan(summary.remaining, 0,
                             "le reste-à-faire est réel, il ne faut pas le taire")
    }

    /// Journal capturé (la `Config.log` est `@Sendable`).
    private final class LogBox: @unchecked Sendable {
        private let mutex = NSLock()
        private var stored: [String] = []
        func append(_ line: String) {
            mutex.lock(); stored.append(line); mutex.unlock()
        }
        var lines: [String] {
            mutex.lock(); defer { mutex.unlock() }; return stored
        }
    }

    /// `sqlite3` du système sur une base de TEST (jamais la production).
    private static func execute(_ sql: String, on database: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        process.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        process.standardError = err
        try process.run()
        let message = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "WindowingTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    String(decoding: message, as: UTF8.self)])
        }
    }
}

// MARK: - Repli par page à la recherche (max-pooling)

final class WindowFoldingTests: XCTestCase {

    private let dim = 16

    /// Vecteur porté par un axe, quantifié.
    private func axis(_ i: Int, scale: Int8 = 127) -> [Int8] {
        var v = [Int8](repeating: 0, count: dim)
        v[i] = scale
        return v
    }

    /// Page 1/1 : deux fenêtres, la seconde alignée sur l'axe 0. Page 2/1 :
    /// une fenêtre à demi alignée. Page 3/1 : une fenêtre orthogonale.
    private func index() -> VectorIndex {
        let rows: [(Int64, [Int8])] = [
            (vecRow(1, 1, chunk: 0), axis(1)),
            (vecRow(1, 1, chunk: 1), axis(0)),
            (vecRow(2, 1, chunk: 0), axis(0, scale: 64)),
            (vecRow(3, 1, chunk: 0), axis(2)),
        ]
        return VectorIndex(rowids: rows.map(\.0), data: rows.flatMap(\.1),
                           dim: dim)
    }

    func testAPageAppearsOnceWithItsBestWindow() {
        let index = self.index()
        XCTAssertEqual(index.chunkCount, 4)
        XCTAssertEqual(index.pageCount, 3)

        let hits = index.topK(query: axis(0), k: 10).hits
        XCTAssertEqual(hits.count, 3, "trois PAGES, pas quatre fenêtres")
        XCTAssertEqual(hits.map(\.rowid), [
            Schema.ftsRowID(docID: 1, page: 1),
            Schema.ftsRowID(docID: 2, page: 1),
            Schema.ftsRowID(docID: 3, page: 1),
        ])
        XCTAssertEqual(Double(hits[0].cosine), 1.0, accuracy: 0.01,
                       "la page 1 doit être classée par sa MEILLEURE fenêtre")
        XCTAssertEqual(Double(hits[2].cosine), 0, accuracy: 0.01)
        XCTAssertEqual(Set(hits.map(\.rowid)).count, hits.count,
                       "une page ne doit apparaître qu'une fois")
    }

    /// Les moments portent sur les FENÊTRES : quatre fenêtres balayées pour
    /// trois pages, et c'est ce que `scanned` doit dire.
    func testMomentsCountWindowsNotPages() {
        let scan = index().topK(query: axis(0), k: 10)
        XCTAssertEqual(scan.stats.scanned, 4)
        XCTAssertEqual(scan.stats.zeros, 0)
    }

    func testAllowedDocsReadsTheDocumentThroughTheWindowRowID() {
        let hits = index().topK(query: axis(0), k: 10, allowedDocs: [2]).hits
        XCTAssertEqual(hits.map(\.rowid), [Schema.ftsRowID(docID: 2, page: 1)])
    }

    /// `neighbours` part d'un rowid de PAGE, interroge TOUTES ses fenêtres et
    /// agrège par page cible : la page source est exclue, et une page cible à
    /// plusieurs fenêtres n'apparaît qu'une fois, avec son meilleur cosinus.
    func testNeighboursAggregatePerPageAndExcludeTheSource() {
        let source = Schema.ftsRowID(docID: 1, page: 1)
        let neighbours = index().neighbours(of: source, k: 10)

        XCTAssertFalse(neighbours.contains { $0.rowid == source },
                       "la page source doit être exclue, toutes fenêtres comprises")
        XCTAssertEqual(Set(neighbours.map(\.rowid)).count, neighbours.count)
        XCTAssertEqual(neighbours.map(\.rowid), [
            Schema.ftsRowID(docID: 2, page: 1),   // axe 0, vu par la fenêtre 1
            Schema.ftsRowID(docID: 3, page: 1),   // axe 2, jamais proche
        ])
        // La page 2 porte un vecteur de demi-longueur (64/127) : c'est la
        // fenêtre 1 de la source, alignée sur l'axe 0, qui la voit — la
        // fenêtre 0, portée par l'axe 1, en est orthogonale.
        XCTAssertEqual(Double(neighbours[0].cosine), 64.0 / 127.0,
                       accuracy: 0.01)
        XCTAssertEqual(Double(neighbours[1].cosine), 0, accuracy: 0.01)

        // Un rowid de page inconnu ne trouve rien.
        XCTAssertTrue(index().neighbours(of: 999_999, k: 5).isEmpty)
        // `excludingSameDoc` retire tout le document de la source.
        let cross = index().neighbours(of: source, k: 10, excludingSameDoc: true)
        XCTAssertFalse(cross.contains { $0.rowid / Schema.pagesPerDocLimit == 1 })
    }

    /// Une page dont TOUTES les fenêtres sont nulles n'a aucun voisin.
    func testAZeroPageHasNoNeighbours() {
        let rows: [(Int64, [Int8])] = [
            (vecRow(1, 1), [Int8](repeating: 0, count: dim)),
            (vecRow(2, 1), axis(0)),
        ]
        let index = VectorIndex(rowids: rows.map(\.0), data: rows.flatMap(\.1),
                                dim: dim)
        XCTAssertTrue(index.neighbours(of: Schema.ftsRowID(docID: 1, page: 1),
                                       k: 5).isEmpty)
    }
}

// MARK: - Bout en bout : ce que le fenêtrage fait GAGNER

final class WindowedHybridTests: XCTestCase {

    /// Le constat C2-05, rendu observable : une page longue dont le sujet
    /// n'apparaît qu'APRÈS le 1 400ᵉ caractère. Au schéma v3 son vecteur ne
    /// voyait que le début et la page était introuvable par le sens ; avec le
    /// fenêtrage, sa fenêtre de queue la trouve.
    func testATailOnlyTopicIsFoundOnlyThanksToWindowing() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Livres/traite.pdf")
        let body = String(repeating: "zzzz ", count: 520)     // 2 600 caractères
            + "les félins chassent la nuit en silence"
        try db.store.replacePages(docID: doc, pages: [page(1, body)])

        let engine = FakeEngine()
        _ = try EmbedRun.run(store: db.store, engine: engine,
                             config: silentConfig())
        XCTAssertEqual(try db.store.vectorCount(), 3, "2 fenêtres + 1 sentinelle")

        let query = try QueryParser.searchQuery("chat", limit: 50, inDocIDs: [],
                                                fuzzy: .off, fuzzyScope: .ocrOnly)
        let index = try VectorIndex(store: db.store, dim: engine.dimension)
        let results = try HybridSearch.run(
            store: db.store, engine: engine, index: index, query: query,
            excludingDocsMatching: nil, rawQuery: "chat", typedQuery: "chat", limit: 10)
        XCTAssertEqual(results.semanticOnly, 1,
                       "la page doit être trouvée par sa fenêtre de queue")
        XCTAssertEqual(results.hits.first?.docID, doc)
        XCTAssertEqual(results.vectors, 1, "la couverture se dit en PAGES")
        XCTAssertEqual(Double(try XCTUnwrap(results.hits.first?.cosine)), 1,
                       accuracy: 0.05)

        // CONTRE-ÉPREUVE : le même corpus vu par le schéma v3 — la fenêtre 0
        // seule — ne trouve rien. C'est la mesure du gain, pas une conviction.
        let all = try db.store.allVectors(dim: engine.dimension)
        var rowids: [Int64] = []
        var data: [Int8] = []
        for (i, rowid) in all.rowids.enumerated()
        where rowid % Schema.vecChunksPerPage == 0 {
            rowids.append(rowid)
            data.append(contentsOf: all.data[i * engine.dimension
                                             ..< (i + 1) * engine.dimension])
        }
        let firstWindowOnly = VectorIndex(rowids: rowids, data: data,
                                          dim: engine.dimension)
        let before = try HybridSearch.run(
            store: db.store, engine: engine, index: firstWindowOnly, query: query,
            excludingDocsMatching: nil, rawQuery: "chat", typedQuery: "chat", limit: 10)
        XCTAssertLessThan(Double(try XCTUnwrap(before.hits.first?.cosine)), 0.5,
                          "sans fenêtrage, la page n'a rien à voir avec la requête")
    }
}
