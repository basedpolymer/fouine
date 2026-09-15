// EmbedTests.swift — quantification, index vectoriel, RRF, EmbedRun, hybride.
// Propriété : A-Embed (01/09/2026).
//
// Les tests unitaires tournent sans le modèle CoreML (moteur factice
// déterministe) ; les tests de parité tokenizer et d'encodeur exigent le
// modèle e5 installé (`fouine model download`, ou FOUINE_MODEL_DIR vers une
// copie) et se sautent proprement sinon. Tout ce qui tire au sort ici le fait
// sur SEMENCE FIXE : cette suite tourne en CI depuis le palier 3.3 (D12/M23).

import Foundation
import XCTest
@testable import FouineEmbed
@testable import FouineCore

// MARK: - Moteur factice

/// Moteur déterministe : un vecteur de base par thème lexical, pour fabriquer
/// des équivalences sémantiques connues (« chat » ≈ « félin ») sans modèle.
final class FakeEngine: EmbedEngine {
    let dimension = 64
    let modelID = "fake-engine"
    let revision = 1

    private static let topics: [(keyword: String, axis: Int)] = [
        ("chat", 0), ("felin", 0), ("félin", 0),
        ("chien", 1), ("canin", 1),
        ("acide", 2), ("base", 2),
    ]

    func vector(for text: String) -> [Float] {
        let lower = text.lowercased()
        var v = [Float](repeating: 0, count: dimension)
        var matched = false
        for (keyword, axis) in Self.topics where lower.contains(keyword) {
            v[axis] += 1
            matched = true
        }
        if !matched {
            // Direction pseudo-aléatoire stable, loin des axes thématiques.
            var h = UInt64(5381)
            for b in lower.utf8 { h = h &* 33 &+ UInt64(b) }
            for i in 8..<dimension {
                h = h &* 6364136223846793005 &+ 1442695040888963407
                v[i] = Float(Int64(bitPattern: h) % 1000) / 1000
            }
        }
        let norm = v.map { $0 * $0 }.reduce(0, +).squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    func embedPassages(_ texts: [String]) throws -> [[Float]] {
        texts.map(vector(for:))
    }

    func embedQuery(_ text: String) throws -> [Float] { vector(for: text) }
}

/// Le même moteur, qui COMPTE ses interrogations : c'est la seule façon de
/// prouver qu'une requête à guillemets ne consulte pas le canal sémantique
/// (RK-01) — un classement identique au lexical ne le prouverait pas, le canal
/// pouvant n'avoir rien remonté d'utile.
final class CountingEngine: EmbedEngine {
    private let inner = FakeEngine()
    var queryCalls = 0
    var passageBatches = 0

    var dimension: Int { inner.dimension }
    var modelID: String { inner.modelID }
    var revision: Int { inner.revision }

    func embedPassages(_ texts: [String]) throws -> [[Float]] {
        passageBatches += 1
        return try inner.embedPassages(texts)
    }

    func embedQuery(_ text: String) throws -> [Float] {
        queryCalls += 1
        return try inner.embedQuery(text)
    }
}

// MARK: - Support

final class TempDB {
    let directory: URL
    let store: GRDBStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-embed-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        store = GRDBStore()
        try store.open(at: directory.appendingPathComponent("fouine.db"))
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

extension XCTestCase {
    func makeDB() throws -> TempDB { try TempDB() }

    @discardableResult
    func addDoc(_ db: TempDB, relPath: String, ext: String = "pdf",
                folder: String = "Livres") throws -> Int64 {
        try db.store.upsertDoc(DocRecord(
            volUUID: "TEST-VOL", relPath: relPath, ext: ext, topFolder: folder,
            size: 1_000, mtime: 1_700_000_000))
    }

    func page(_ n: Int, _ text: String) -> PageText {
        PageText(page: n, text: text, source: .native)
    }

    /// Rowid d'une FENÊTRE de page — ce que `page_vec` porte et ce qu'un
    /// `VectorIndex` charge depuis le schéma v5. Les résultats, eux, se
    /// comparent toujours à des rowids de PAGE (`Schema.ftsRowID`).
    func vecRow(_ docID: Int64, _ page: Int, chunk: Int = 0) -> Int64 {
        Schema.vecRowID(pageRowID: Schema.ftsRowID(docID: docID, page: page),
                        chunk: chunk)
    }

    /// Texte de `chars` caractères, sans césure de mot qui compliquerait le
    /// compte : les tests de fenêtrage raisonnent en LONGUEUR.
    func text(ofLength chars: Int) -> String {
        String(repeating: "a", count: chars)
    }

    /// Répertoire du modèle réel, ou nil (test à sauter).
    func realModelDir() -> URL? {
        let dir = EmbedPaths.modelDirectory()
        return EmbedPaths.modelAvailable(at: dir) ? dir : nil
    }

    /// L'encodeur RÉEL, chargé UNE fois par processus et partagé par les tests
    /// qui n'éprouvent pas le chargement lui-même (lot I2 : ~2,5 s par
    /// `E5Encoder(modelDir:)` sur i5, trois tests le payaient chacun). `nil`
    /// quand le modèle est absent : l'appelant saute.
    func sharedRealEncoder() throws -> E5Encoder? {
        guard realModelDir() != nil else { return nil }
        return try SharedModel.loaded.result.get()
    }

    /// Config muette, garde `minChars` désarmée : les fixtures sont courtes,
    /// le vecteur nul des pages quasi vides a son test dédié.
    ///
    /// Les deux règles de vecteur nul ajoutées par SI1 sont désarmées elles
    /// aussi, et pour la même raison : les fixtures de fenêtrage sont des
    /// « aaaa… » — dégénérés par construction — et chaque règle a son propre
    /// test, qui l'arme explicitement.
    func silentConfig(minChars: Int = 1) -> EmbedRun.Config {
        var config = EmbedRun.Config()
        config.log = { _ in }
        config.minChars = minChars
        config.nullDegenerate = false
        config.sharedTextDocuments = 0
        return config
    }
}

/// Le modèle CoreML chargé une seule fois pour tout le processus de test :
/// `static let` est paresseux et sûr entre fils. La boîte porte l'erreur de
/// chargement plutôt que de la jeter à l'initialisation d'un statique.
enum SharedModel {
    static let loaded = LoadedEncoder {
        try E5Encoder(modelDir: EmbedPaths.modelDirectory())
    }
}

final class LoadedEncoder: @unchecked Sendable {
    let result: Result<E5Encoder, Error>
    init(_ make: () throws -> E5Encoder) { result = Result(catching: make) }
}

// MARK: - Quantification

final class QuantizerTests: XCTestCase {

    /// SEMENCE FIXE, depuis le palier 3.3 (audit D12/M23 : cette suite entre en
    /// CI). Le test tirait ses vecteurs d'un `SystemRandomNumberGenerator` et
    /// exigeait 0,01 d'écart au plus — or l'écart de quantification sur 384
    /// dimensions dépasse ce seuil environ une exécution sur dix (0,0105 mesuré
    /// à l'échec observé). Un test rouge une fois sur dix en intégration
    /// continue n'est pas un test, c'est un bruit qu'on apprend à ignorer.
    ///
    /// Deux corrections, pas une : la SEMENCE devient fixe (le même tirage
    /// partout, donc un échec reproductible), et le SEUIL devient celui qu'on a
    /// mesuré. Sur 2 000 paires de vecteurs unitaires à 384 dimensions, l'écart
    /// maximal relevé est de 0,0122 — la borne est posée à 0,025, soit le
    /// double. Elle reste très en dessous de ce que la recherche
    /// hybride demande : les cosinus qui départagent deux pages se tiennent à
    /// quelques centièmes, jamais à quelques millièmes.
    func testCosineSurvivesQuantization() {
        var generator = SeededGenerator(seed: 0xF0071E)
        var worst: Float = 0
        for _ in 0..<2_000 {
            let a = randomUnit(384, using: &generator)
            let b = randomUnit(384, using: &generator)
            let exact = zip(a, b).map(*).reduce(0, +)
            let qa = VecQuantizer.quantizeQuery(a)
            let qb = VecQuantizer.quantizeQuery(b)
            var dot: Int32 = 0
            for i in 0..<qa.count { dot += Int32(qa[i]) * Int32(qb[i]) }
            let approx = VecQuantizer.cosine(fromDot: dot)
            worst = max(worst, abs(exact - approx))
            XCTAssertEqual(exact, approx, accuracy: 0.025)
        }
        // Contre-épreuve : si la quantification devenait EXACTE, ce serait
        // qu'elle n'a plus lieu — et le blob de 384 octets serait redevenu un
        // tableau de flottants de 1 536.
        XCTAssertGreaterThan(worst, 0.0001, "aucune perte : quantifie-t-on encore ?")
    }

    func testQuantizeBlobRoundtrip() {
        let v: [Float] = [1, -1, 0.5, -0.5] + [Float](repeating: 0, count: 60)
        let norm = v.map { $0 * $0 }.reduce(0, +).squareRoot()
        let unit = v.map { $0 / norm }
        let blob = VecQuantizer.quantize(unit)
        XCTAssertEqual(blob.count, unit.count)
        let ints = blob.withUnsafeBytes { Array($0.bindMemory(to: Int8.self)) }
        XCTAssertEqual(ints, VecQuantizer.quantizeQuery(unit))
    }

    private func randomUnit(_ dim: Int,
                            using g: inout SeededGenerator) -> [Float] {
        let v = (0..<dim).map { _ in Float.random(in: -1...1, using: &g) }
        let norm = v.map { $0 * $0 }.reduce(0, +).squareRoot()
        return v.map { $0 / norm }
    }
}

/// Générateur DÉTERMINISTE (SplitMix64) : un test qui tire au sort doit tirer
/// le même sort partout, sinon la CI clignote (audit D12/M23). Même rôle que la
/// semence de `VectorIndexTests.randomIndex`, sous une forme réutilisable.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Index vectoriel

final class VectorIndexTests: XCTestCase {

    private func randomIndex(count: Int, dim: Int, seed: UInt64)
        -> (VectorIndex, [Int8]) {
        var state = seed
        func next() -> Int8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int8(truncatingIfNeeded: state >> 33)
        }
        var pairs: [(rowid: Int64, vec: [Int8])] = []
        for i in 0..<count {
            let docID = Int64(i / 10 + 1)
            let page = i % 10 + 1
            // Une fenêtre 0 par page : l'index charge des rowids de FENÊTRE.
            let rowid = Schema.vecRowID(
                pageRowID: Schema.ftsRowID(docID: docID, page: page), chunk: 0)
            let vec = (0..<dim).map { _ in next() }
            pairs.append((rowid, vec))
        }
        pairs.sort { $0.rowid < $1.rowid }
        let rowids = pairs.map(\.rowid)
        let data = pairs.flatMap(\.vec)
        let query = (0..<dim).map { _ in next() }
        return (VectorIndex(rowids: rowids, data: data, dim: dim), query)
    }

    func testTopKMatchesNaiveScan() {
        let (index, query) = randomIndex(count: 500, dim: 64, seed: 42)
        let got = index.topK(query: query, k: 50).hits

        var naive: [(Int64, Int32)] = []
        for r in 0..<index.count {
            var dot: Int32 = 0
            index.withVector(at: r) { vec in
                for i in 0..<vec.count { dot += Int32(vec[i]) * Int32(query[i]) }
            }
            naive.append((index.rowids[r], dot))
        }
        naive.sort { $0.1 > $1.1 }
        XCTAssertEqual(got.map(\.cosine),
                       naive.prefix(50).map { VecQuantizer.cosine(fromDot: $0.1) })
        // `topK` rend des rowids de PAGE : le balayage nu, lui, énumère des
        // fenêtres (une par page ici).
        XCTAssertEqual(Set(got.map(\.rowid)),
                       Set(naive.prefix(50).map { Schema.pageRowID(vecRowID: $0.0) }))
    }

    func testAllowedDocsFilter() {
        let (index, query) = randomIndex(count: 300, dim: 64, seed: 7)
        let got = index.topK(query: query, k: 300, allowedDocs: [2]).hits
        XCTAssertFalse(got.isEmpty)
        XCTAssertTrue(got.allSatisfy { $0.rowid / Schema.pagesPerDocLimit == 2 })
    }

    func testSyntheticIndexCollinearOrthogonalAndNeighbours() {
        let dim = 64
        let r1_1 = Schema.ftsRowID(docID: 1, page: 1)
        let r1_2 = Schema.ftsRowID(docID: 1, page: 2)
        let r2_1 = Schema.ftsRowID(docID: 2, page: 1)
        let r3_1 = Schema.ftsRowID(docID: 3, page: 1)
        let r3_2 = Schema.ftsRowID(docID: 3, page: 2)

        func unitVec(at axis: Int) -> [Int8] {
            var v = [Int8](repeating: 0, count: dim)
            if axis >= 0 && axis < dim { v[axis] = 127 }
            return v
        }

        let v1_1 = unitVec(at: 0)
        let v1_2 = unitVec(at: 0)
        let v2_1 = unitVec(at: 1)
        let v3_1 = unitVec(at: 0)
        let v3_2 = [Int8](repeating: 0, count: dim)

        // L'index porte des rowids de FENÊTRE ; `neighbours` et `topK`, eux,
        // parlent en rowids de PAGE.
        let rowids = [r1_1, r1_2, r2_1, r3_1, r3_2].map {
            Schema.vecRowID(pageRowID: $0, chunk: 0)
        }
        let data = v1_1 + v1_2 + v2_1 + v3_1 + v3_2
        let index = VectorIndex(rowids: rowids, data: data, dim: dim)

        // 1. Recherche binaire index(of:) — en rowids de fenêtre
        XCTAssertEqual(index.index(of: rowids[0]), 0)
        XCTAssertEqual(index.index(of: rowids[1]), 1)
        XCTAssertEqual(index.index(of: rowids[2]), 2)
        XCTAssertEqual(index.index(of: rowids[3]), 3)
        XCTAssertEqual(index.index(of: rowids[4]), 4)
        XCTAssertNil(index.index(of: 999_999))
        XCTAssertNil(index.index(of: r1_1),
                     "un rowid de PAGE n'est pas un rowid de fenêtre")
        XCTAssertEqual(index.pageCount, 5)
        XCTAssertEqual(index.chunkCount, 5)

        // 2. Voisins avec même document inclus
        let nAll = index.neighbours(of: r1_1, k: 5, excludingSameDoc: false)
        XCTAssertEqual(nAll.count, 4)
        XCTAssertFalse(nAll.contains { $0.rowid == r1_1 })
        let topCollinear = Set(nAll.prefix(2).map(\.rowid))
        XCTAssertEqual(topCollinear, [r1_2, r3_1])
        XCTAssertEqual(nAll[0].cosine, 1.0, accuracy: 0.05)
        XCTAssertEqual(nAll[1].cosine, 1.0, accuracy: 0.05)
        let r2Hit = try! XCTUnwrap(nAll.first(where: { $0.rowid == r2_1 }))
        XCTAssertEqual(r2Hit.cosine, 0.0, accuracy: 0.05)

        // 3. Voisins avec excludingSameDoc: true
        let nCross = index.neighbours(of: r1_1, k: 5, excludingSameDoc: true)
        XCTAssertFalse(nCross.contains { $0.rowid == r1_1 || $0.rowid == r1_2 })
        let crossHit = try! XCTUnwrap(nCross.first)
        XCTAssertEqual(crossHit.rowid, r3_1)
        XCTAssertEqual(crossHit.cosine, 1.0, accuracy: 0.05)

        // 4. Voisinage d'un vecteur nul -> []
        let nZero = index.neighbours(of: r3_2, k: 5)
        XCTAssertTrue(nZero.isEmpty)

        // 5. Voisinage d'un rowid inexistant -> []
        let nMissing = index.neighbours(of: 888_888, k: 5)
        XCTAssertTrue(nMissing.isEmpty)
    }

    func testRemainderDimension() {
        // dim = 40 : exerce la boucle de reliquat (40 = 0×64 + reste).
        let dim = 40
        let a: [Int8] = (0..<dim).map { Int8($0 % 5 - 2) }
        let expected = a.map { Int32($0) * Int32($0) }.reduce(0, +)
        a.withUnsafeBufferPointer { buf in
            XCTAssertEqual(VectorIndex.dot(buf.baseAddress!, buf.baseAddress!, dim),
                           expected)
        }
    }
}

// MARK: - RRF

final class RRFTests: XCTestCase {

    func testKnownFusion() {
        let fused = RRF.fuse([[10, 20, 30], [20, 40]])
        XCTAssertEqual(fused.map(\.id), [20, 10, 40, 30])
        XCTAssertEqual(fused[0].score, 1 / 62.0 + 1 / 61.0, accuracy: 1e-12)
        XCTAssertEqual(fused[0].ranks, [2, 1])
        XCTAssertEqual(fused[1].ranks, [1, nil])
    }

    func testWeights() {
        // Poids vectoriel nul : l'ordre lexical est conservé tel quel.
        let fused = RRF.fuse([[1, 2], [2, 1]], weights: [1, 0])
        XCTAssertEqual(fused.map(\.id), [1, 2])
    }
}

// MARK: - EmbedRun

final class EmbedRunTests: XCTestCase {

    func testProducesVectorsForEveryIndexedPage() throws {
        let db = try makeDB()
        let a = try addDoc(db, relPath: "Users/alice/Livres/a.pdf")
        let b = try addDoc(db, relPath: "Users/alice/Livres/b.pdf")
        try db.store.replacePages(docID: a, pages: [
            page(1, "le chat dort sur le canapé"), page(2, "un chien aboie")])
        try db.store.replacePages(docID: b, pages: [
            page(1, "les félins chassent la nuit")])

        let summary = try EmbedRun.run(store: db.store, engine: FakeEngine(),
                                       config: silentConfig())
        XCTAssertEqual(summary.embedded, 3, "trois pages complétées")
        XCTAssertEqual(summary.remaining, 0)
        XCTAssertEqual(try db.store.vectorisedPageCount(), 3)
        XCTAssertEqual(try db.store.completeVectorPageCount(), 3)
        // Trois pages courtes : une fenêtre chacune, plus la sentinelle de
        // complétude (blob vide) au dernier créneau.
        XCTAssertEqual(try db.store.vectorCount(), 6)
        XCTAssertEqual(summary.windows, 6)

        // Reprise : rien à refaire.
        let second = try EmbedRun.run(store: db.store, engine: FakeEngine(),
                                      config: silentConfig())
        XCTAssertEqual(second.embedded, 0)
    }

    func testReplacePagesInvalidatesVectors() throws {
        let db = try makeDB()
        let a = try addDoc(db, relPath: "Users/alice/Livres/a.pdf")
        try db.store.replacePages(docID: a, pages: [page(1, "texte initial")])
        _ = try EmbedRun.run(store: db.store, engine: FakeEngine(),
                             config: silentConfig())
        XCTAssertEqual(try db.store.vectorisedPageCount(), 1)
        XCTAssertEqual(try db.store.vectorCount(), 2, "fenêtre 0 + sentinelle")

        try db.store.replacePages(docID: a, pages: [page(1, "texte remplacé")])
        XCTAssertEqual(try db.store.vectorCount(), 0,
                       "réécrire le texte doit invalider TOUTES les fenêtres "
                       + "de la page, sentinelle comprise")
    }

    /// Une page quasi vide reçoit un VECTEUR NUL : jamais classée par le canal
    /// sémantique (cos 0), aucune inférence dépensée, mais couverte (pas
    /// re-présentée à chaque passe).
    func testShortPagesGetZeroVectors() throws {
        let db = try makeDB()
        let a = try addDoc(db, relPath: "Users/alice/Livres/a.pdf")
        try db.store.replacePages(docID: a, pages: [
            page(1, "le chat dort sur le canapé du salon pendant que la pluie "
                 + "tombe doucement sur les toits gris de la ville endormie"),
            page(2, "Page blanche volontairement.")])
        let engine = FakeEngine()
        _ = try EmbedRun.run(store: db.store, engine: engine,
                             config: silentConfig(minChars: 100))
        XCTAssertEqual(try db.store.vectorisedPageCount(), 2,
                       "les deux pages sont couvertes")
        XCTAssertEqual(try db.store.completeVectorPageCount(), 2)

        let index = try VectorIndex(store: db.store, dim: engine.dimension)
        let top = index.topK(
            query: VecQuantizer.quantizeQuery(engine.vector(for: "chat")), k: 2).hits
        XCTAssertEqual(top.first?.rowid, Schema.ftsRowID(docID: a, page: 1))
        XCTAssertEqual(Double(top.last?.cosine ?? -1), 0, accuracy: 0.001,
                       "la page courte porte un vecteur nul")
    }

    /// MO-01 : une page de « A » est assez longue pour passer `minChars`, et son
    /// vecteur est proche de tout. Elle reçoit un vecteur nul, compté à part.
    func testADegeneratePageGetsAZeroVectorAndIsCounted() throws {
        let db = try makeDB()
        let a = try addDoc(db, relPath: "Users/alice/Livres/bombe.docx", ext: "docx")
        try db.store.replacePages(docID: a, pages: [
            page(1, String(repeating: "A", count: 1_400)),
            page(2, "le chat dort sur le canapé du salon pendant que la pluie "
                 + "tombe doucement sur les toits gris de la ville endormie")])

        var config = silentConfig(minChars: 100)
        config.nullDegenerate = true
        let engine = RecordingEngine()
        let summary = try EmbedRun.run(store: db.store, engine: engine,
                                       config: config)

        XCTAssertEqual(summary.degenerate, 1, "une fenêtre annulée")
        XCTAssertEqual(summary.sharedText, 0)
        XCTAssertEqual(engine.seen.count, 1, "seule la vraie page est inférée")
        XCTAssertFalse(engine.seen[0].hasPrefix("AAAA"))
        // Les deux pages restent COUVERTES : elles ne reviendront jamais.
        XCTAssertEqual(try db.store.completeVectorPageCount(), 2)
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT total(abs(vec)) FROM page_vec WHERE rowid = "
            + "\(vecRow(a, 1))"), [0], "la page de « A » porte un vecteur nul")
    }

    /// C2-16 : le préambule de licence recopié dans cinq livres n'apprend rien
    /// au canal sémantique et occupait quatre des cinq premiers résultats.
    func testTextSharedByEnoughDocumentsGetsAZeroVector() throws {
        let db = try makeDB()
        let shared = (1...12).map {
            "Cette licence autorise la copie du texte numero \($0) sous "
            + "reserve de mentionner sa provenance et de ne pas en tirer "
            + "profit commercial dans aucun pays"
        }.joined(separator: " ")
        XCTAssertGreaterThan(shared.count, 400)

        var ids: [Int64] = []
        for n in 1...5 {
            let id = try addDoc(db, relPath: "Users/alice/Livres/livre\(n).epub",
                                ext: "epub")
            try db.store.replacePages(docID: id, pages: [page(1, shared)])
            ids.append(id)
        }
        let unique = try addDoc(db, relPath: "Users/alice/Livres/seul.epub",
                                ext: "epub")
        let ownText = (1...12).map {
            "Le chapitre numero \($0) raconte la cristallisation lente des "
            + "polymeres semi cristallins pendant un refroidissement mesure "
            + "par calorimetrie"
        }.joined(separator: " ")
        try db.store.replacePages(docID: unique, pages: [page(1, ownText)])

        var config = silentConfig(minChars: 100)
        config.sharedTextDocuments = 4
        let engine = RecordingEngine()
        let summary = try EmbedRun.run(store: db.store, engine: engine,
                                       config: config)

        // Cinq copies, deux fenêtres chacune : la règle est PAR FENÊTRE, comme
        // celle de `minChars`.
        XCTAssertEqual(summary.sharedText, 10,
                       "les cinq copies du même passage sont annulées")
        XCTAssertEqual(summary.degenerate, 0)
        XCTAssertEqual(engine.seen.count, 2,
                       "seul le document unique est inféré : \(engine.seen.count)")
        XCTAssertTrue(engine.seen.allSatisfy { $0.contains("cristallisation") })
        for id in ids {
            XCTAssertEqual(try db.store.rawInt64s(
                "SELECT total(abs(vec)) FROM page_vec WHERE rowid = "
                + "\(vecRow(id, 1))"), [0])
        }
        // Les pages restent trouvables AU MOT PRÈS : c'est tout l'intérêt.
        XCTAssertEqual(try db.store.rawInt64s(
            "SELECT count(*) FROM page_fts WHERE page_fts MATCH 'licence'"), [5])
    }

    /// Seuil 0 : la sonde ne tourne pas, et rien ne change.
    func testTheSharedTextProbeIsDisarmedAtZero() throws {
        let db = try makeDB()
        let shared = String(repeating: "phrase recopiee mot pour mot ", count: 30)
        for n in 1...5 {
            let id = try addDoc(db, relPath: "Users/alice/Livres/d\(n).epub",
                                ext: "epub")
            try db.store.replacePages(docID: id, pages: [page(1, shared)])
        }
        var config = silentConfig(minChars: 100)
        config.sharedTextDocuments = 0
        let engine = RecordingEngine()
        let summary = try EmbedRun.run(store: db.store, engine: engine,
                                       config: config)
        XCTAssertEqual(summary.sharedText, 0)
        XCTAssertEqual(engine.seen.count, 5, "les cinq fenêtres sont inférées")
    }

    func testModelChangePurgesVectors() throws {
        let db = try makeDB()
        let a = try addDoc(db, relPath: "Users/alice/Livres/a.pdf")
        try db.store.replacePages(docID: a, pages: [page(1, "du texte")])
        _ = try EmbedRun.run(store: db.store, engine: FakeEngine(),
                             config: silentConfig())
        XCTAssertEqual(try db.store.vectorisedPageCount(), 1)

        // Même modèle : les vecteurs restent. (La géométrie de fenêtrage est
        // dans `vec_meta` dès la création : ce n'est pas une identité de modèle
        // et cela ne doit rien purger.)
        try db.store.setVecMeta(modelID: "fake-engine", dim: 64, revision: 1)
        XCTAssertEqual(try db.store.vectorisedPageCount(), 1)
        // Révision différente : purge.
        try db.store.setVecMeta(modelID: "fake-engine", dim: 64, revision: 2)
        XCTAssertEqual(try db.store.vectorCount(), 0)
    }
}

// MARK: - EmbedRun · curseur, rattrapage, annulation, erreurs d'écriture

/// Moteur instrumenté (audit V2, F6, X3) : retient les textes vraiment inférés
/// — c'est ce qui permet de vérifier que le curseur couvre EXACTEMENT les pages
/// sans vecteur, chacune UNE fois — compte les lots, et laisse déclencher un
/// effet de bord après un lot donné (invalidation concurrente).
final class RecordingEngine: EmbedEngine, @unchecked Sendable {
    let dimension = 64
    let modelID = "recording-engine"
    let revision = 1

    private let inner = FakeEngine()
    private let mutex = NSLock()
    private var texts: [String] = []
    private var count = 0

    /// Appelé APRÈS chaque lot, avec son numéro (1 pour le premier).
    var afterBatch: ((Int) -> Void)?

    var seen: [String] { mutex.lock(); defer { mutex.unlock() }; return texts }
    var batches: Int { mutex.lock(); defer { mutex.unlock() }; return count }

    func embedPassages(_ passages: [String]) throws -> [[Float]] {
        mutex.lock()
        texts += passages
        count += 1
        let number = count
        mutex.unlock()
        let vectors = try inner.embedPassages(passages)
        afterBatch?(number)
        return vectors
    }

    func embedQuery(_ text: String) throws -> [Float] { try inner.embedQuery(text) }
}

/// Drapeau d'arrêt (même rôle que celui de `fouine embed`).
final class StopBox: @unchecked Sendable {
    private let mutex = NSLock()
    private var value = false
    func request() { mutex.lock(); value = true; mutex.unlock() }
    var isRequested: Bool { mutex.lock(); defer { mutex.unlock() }; return value }
}

final class EmbedCursorTests: XCTestCase {

    /// Blob reconnaissable : un vecteur POSÉ AVANT la passe ne doit jamais être
    /// réécrit (l'incrémental est le contrat — 12 528 vecteurs en production).
    private static let marker = Data(repeating: 42, count: 64)

    private func text(doc: Int, page: Int) -> String {
        "document \(doc) page \(page) : chromatographie enthalpie polymere azote"
    }

    private func fill(_ db: TempDB, docs: Int, pages: Int) throws -> [Int64] {
        var ids: [Int64] = []
        for d in 1...docs {
            let id = try addDoc(db, relPath: "Users/alice/Livres/d\(d).pdf")
            try db.store.replacePages(
                docID: id,
                pages: (1...pages).map { page($0, text(doc: d, page: $0)) })
            ids.append(id)
        }
        return ids
    }

    private func cursorConfig() -> EmbedRun.Config {
        var config = silentConfig()
        config.batchSize = 4          // plusieurs lots sur un corpus de test
        return config
    }

    /// Marque une page comme DÉJÀ FAITE : sa fenêtre 0 porte le blob témoin et
    /// sa sentinelle de complétude est posée. Sans la sentinelle, la page reste
    /// « incomplète » pour la pompe et serait re-sélectionnée — c'est tout
    /// l'objet du schéma v5, et c'est vérifié par son propre test.
    private func markCovered(_ db: TempDB, page rowid: Int64) throws {
        try db.store.upsertVectors([
            (rowid: Schema.vecRowID(pageRowID: rowid, chunk: 0),
             vec: Self.marker),
            (rowid: Schema.vecRowID(pageRowID: rowid,
                                    chunk: Schema.vecWindowMax - 1),
             vec: Data()),
        ])
    }

    // MARK: · Le curseur couvre exactement les pages sans vecteur, une fois

    func testCursorCoversEveryPageWithoutVectorExactlyOnce() throws {
        let db = try makeDB()
        let ids = try fill(db, docs: 3, pages: 6)          // 18 pages

        // Cinq pages DÉJÀ vectorisées, dispersées : le curseur doit les
        // enjamber sans jamais les représenter au moteur.
        let covered: [(doc: Int, page: Int)] = [
            (1, 2), (1, 5), (2, 1), (2, 6), (3, 3),
        ]
        for entry in covered {
            try markCovered(db, page: Schema.ftsRowID(docID: ids[entry.doc - 1],
                                                      page: entry.page))
        }

        let engine = RecordingEngine()
        let summary = try EmbedRun.run(store: db.store, engine: engine,
                                       config: cursorConfig())

        var expected = Set<String>()
        for d in 1...3 {
            for p in 1...6 where !covered.contains(where: { $0.doc == d && $0.page == p }) {
                expected.insert(text(doc: d, page: p))
            }
        }
        XCTAssertEqual(Set(engine.seen), expected,
                       "le curseur ne couvre pas exactement les pages sans vecteur")
        XCTAssertEqual(engine.seen.count, Set(engine.seen).count,
                       "une page a été inférée deux fois")
        XCTAssertEqual(engine.seen.count, 13)
        XCTAssertEqual(summary.embedded, 13)
        XCTAssertFalse(summary.interrupted)
        XCTAssertEqual(summary.remaining, 0)
        XCTAssertEqual(try db.store.vectorisedPageCount(), 18)
        XCTAssertEqual(try db.store.completeVectorPageCount(), 18)

        // Les vecteurs préexistants sont INTACTS : aucun recalcul.
        let all = try db.store.allVectors(dim: 64)
        for entry in covered {
            let rowid = vecRow(ids[entry.doc - 1], entry.page)
            let position = try XCTUnwrap(all.rowids.firstIndex(of: rowid))
            XCTAssertTrue(all.data[position * 64..<(position + 1) * 64]
                            .allSatisfy { $0 == 42 },
                          "le vecteur préexistant de \(rowid) a été recalculé")
        }

        // Reprise : le second passage ne coûte qu'un balayage, zéro inférence.
        let batchesBefore = engine.batches
        let second = try EmbedRun.run(store: db.store, engine: engine,
                                      config: cursorConfig())
        XCTAssertEqual(second.embedded, 0)
        XCTAssertEqual(engine.batches, batchesBefore, "le moteur a été rappelé")
    }

    // MARK: · La passe de rattrapage ramasse ce qui est invalidé derrière

    /// `replacePages` (agent OCR, ré-extraction) supprime les vecteurs des pages
    /// qu'il réécrit. Si ces pages sont DERRIÈRE le curseur, seul un second
    /// balayage depuis 0 peut les voir — c'est la passe de rattrapage. Puis la
    /// pompe doit S'ARRÊTER : un balayage complet qui ne rend rien la termine.
    func testCatchUpSweepPicksUpPagesInvalidatedBehindTheCursor() throws {
        let db = try makeDB()
        // d1 est créé en premier : ses rowids sont les plus PETITS, donc
        // derrière le curseur dès que la pompe travaille sur d2.
        let ids = try fill(db, docs: 2, pages: 4)
        let (behind, ahead) = (ids[0], ids[1])
        try db.store.replacePages(docID: ahead, pages: (1...8).map {
            page($0, text(doc: 2, page: $0))
        })
        // d1 est entièrement couvert — fenêtre 0 ET sentinelle : la pompe
        // démarre donc sur d2.
        for p in 1...4 {
            try markCovered(db, page: Schema.ftsRowID(docID: behind, page: p))
        }

        let engine = RecordingEngine()
        engine.afterBatch = { number in
            guard number == 1 else { return }
            // Le curseur est maintenant au-delà de d1 : on invalide d1 dans son
            // dos, exactement comme le fait l'agent en OCRisant une page.
            try? db.store.replacePages(docID: behind, pages: (1...4).map {
                PageText(page: $0,
                         text: "document 1 page \($0) RÉÉCRITE par l'agent OCR",
                         source: .ocrAccurate)
            })
        }

        let summary = try EmbedRun.run(store: db.store, engine: engine,
                                       config: cursorConfig())

        XCTAssertEqual(engine.seen.count, 12,
                       "8 pages en balayage avant + 4 pages de rattrapage")
        XCTAssertEqual(engine.seen.count, Set(engine.seen).count,
                       "une page a été inférée deux fois")
        XCTAssertEqual(engine.batches, 3, "3 lots de 4 pages")
        XCTAssertTrue(engine.seen.contains("document 1 page 3 RÉÉCRITE par l'agent OCR"),
                      "la passe de rattrapage n'a pas vu la page invalidée")
        XCTAssertEqual(summary.embedded, 12)
        XCTAssertEqual(summary.remaining, 0, "la pompe s'est arrêtée trop tôt")
        XCTAssertEqual(try db.store.vectorisedPageCount(), 12)
        XCTAssertEqual(try db.store.completeVectorPageCount(), 12)

        // …et elle TERMINE : un troisième balayage, sans rien à faire, ne
        // relance aucune inférence.
        let batchesBefore = engine.batches
        let again = try EmbedRun.run(store: db.store, engine: engine,
                                     config: cursorConfig())
        XCTAssertEqual(again.embedded, 0)
        XCTAssertEqual(engine.batches, batchesBefore)
    }

    // MARK: · Annulation (audit F6)

    func testShouldStopReturnsPromptlyWithTheBufferWritten() throws {
        let db = try makeDB()
        _ = try fill(db, docs: 1, pages: 40)

        let engine = RecordingEngine()
        let stop = StopBox()
        engine.afterBatch = { number in if number >= 1 { stop.request() } }

        let started = Date()
        let summary = try EmbedRun.run(store: db.store, engine: engine,
                                       config: cursorConfig(),
                                       shouldStop: { stop.isRequested })
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 2, "la pompe n'a pas rendu la main tout de suite")
        XCTAssertTrue(summary.interrupted, "l'annulation n'est pas rapportée")
        XCTAssertEqual(engine.batches, 1, "un lot de plus a été inféré après l'arrêt")
        XCTAssertEqual(summary.embedded, 4, "le tampon n'a pas été écrit")
        XCTAssertEqual(try db.store.vectorisedPageCount(), 4)
        XCTAssertEqual(summary.remaining, 36, "la reprise repartira d'ici")
    }

    // MARK: · Une panne d'écriture n'est pas un verrou (audit X3)

    /// `EmbedRun` avalait toute erreur d'écriture par un `try?` puis réessayait
    /// pendant quinze minutes : une base en panne était indiscernable d'un
    /// verrou tenu par l'agent. Elle doit REMONTER, et tout de suite.
    func testNonLockWriteFailureIsRaisedImmediately() throws {
        let db = try makeDB()
        _ = try fill(db, docs: 1, pages: 8)
        try Self.execute("""
            CREATE TRIGGER page_vec_panne BEFORE INSERT ON page_vec
            BEGIN SELECT RAISE(ABORT, 'panne d''ecriture simulee'); END;
            """, on: db.directory.appendingPathComponent("fouine.db"))

        let engine = RecordingEngine()
        let started = Date()
        var caught: Error?
        XCTAssertThrowsError(
            try EmbedRun.run(store: db.store, engine: engine,
                             config: cursorConfig())) { caught = $0 }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 10,
                          "la pompe a attendu comme s'il s'agissait d'un verrou")
        let failure = try XCTUnwrap(caught as? FouineError)
        guard case .databaseFailure(let message) = failure else {
            return XCTFail("erreur inattendue : \(failure)")
        }
        XCTAssertTrue(message.contains("panne d'ecriture simulee"),
                      "le motif de la panne est perdu : \(message)")
        XCTAssertFalse(WriteLock.isBusy(failure),
                       "une panne d'écriture ne doit pas passer pour un verrou")
        XCTAssertEqual(try db.store.vectorCount(), 0)
    }

    /// Le message d'`ExclusiveLock` reste, lui, classé comme un verrou : c'est
    /// le seul échec qu'il soit légitime d'attendre.
    func testLockBusyIsRecognised() {
        // Le message est fabriqué par `WriteLock` et non recopié à la main :
        // depuis le palier 3.2 il porte des DONNÉES et non une phrase, et un
        // littéral figé ici cesserait de représenter ce que `flock` produit.
        let busy = FouineError.databaseFailure(WriteLock.busyMessage(
            holder: LockHolder(pid: getpid(), role: .agent, since: Date()),
            path: "/tmp/fouine.lock"))
        XCTAssertTrue(WriteLock.isBusy(busy))
        XCTAssertFalse(WriteLock.isBusy(FouineError.databaseFailure("disque plein")))
        XCTAssertFalse(WriteLock.isBusy(FouineError.ocr("Vision")))
    }

    /// `sqlite3` du système sur une base de TEST (jamais la base de production).
    private static func execute(_ sql: String, on database: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        process.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        process.standardError = err
        try process.run()
        let diagnosis = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "EmbedTests", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                                        String(decoding: diagnosis, as: UTF8.self)])
        }
    }
}

// MARK: - Hybride

final class HybridSearchTests: XCTestCase {

    /// « chat » ne matche pas « félins » lexicalement ; le canal vectoriel du
    /// moteur factice les rapproche. L'hybride doit rendre LES DEUX pages.
    func testSemanticOnlyHitSurfaces() throws {
        let db = try makeDB()
        let a = try addDoc(db, relPath: "Users/alice/Livres/chat.pdf")
        let b = try addDoc(db, relPath: "Users/alice/Livres/felins.pdf")
        try db.store.replacePages(docID: a, pages: [
            page(1, "le chat dort sur le canapé du salon")])
        try db.store.replacePages(docID: b, pages: [
            page(1, "les félins chassent la nuit en silence")])

        let engine = FakeEngine()
        _ = try EmbedRun.run(store: db.store, engine: engine,
                             config: silentConfig())
        let index = try VectorIndex(store: db.store, dim: engine.dimension)
        XCTAssertEqual(index.count, 2)

        let q = try QueryParser.searchQuery("chat", limit: 50, inDocIDs: [],
                                            fuzzy: .off, fuzzyScope: .ocrOnly)
        let results = try HybridSearch.run(
            store: db.store, engine: engine, index: index, query: q,
            excludingDocsMatching: nil, rawQuery: "chat", typedQuery: "chat", limit: 10)

        XCTAssertEqual(results.lexTotalPages, 1)
        XCTAssertEqual(results.hits.count, 2)
        let lexHit = results.hits.first { $0.docID == a }
        let semHit = results.hits.first { $0.docID == b }
        XCTAssertNotNil(lexHit?.lexical, "la page lexicale garde son snippet")
        XCTAssertNil(semHit?.lexical, "la page félins est un hit sémantique pur")
        XCTAssertEqual(results.semanticOnly, 1)
        XCTAssertTrue(semHit?.preview.contains("félins") ?? false)
        XCTAssertNotNil(semHit?.cosine)
        // La page qui cumule les deux canaux passe devant.
        XCTAssertEqual(results.hits.first?.docID, a)
    }

    func testFiltersApplyToVectorChannel() throws {
        let db = try makeDB()
        let a = try addDoc(db, relPath: "Users/alice/Livres/chat.pdf",
                           folder: "Livres")
        let b = try addDoc(db, relPath: "Users/alice/Cours/felins.pdf",
                           folder: "Cours")
        try db.store.replacePages(docID: a, pages: [page(1, "le chat dort")])
        try db.store.replacePages(docID: b, pages: [page(1, "les félins chassent")])
        let engine = FakeEngine()
        _ = try EmbedRun.run(store: db.store, engine: engine,
                             config: silentConfig())
        let index = try VectorIndex(store: db.store, dim: engine.dimension)

        var q = try QueryParser.searchQuery("chat", limit: 50, inDocIDs: [],
                                            fuzzy: .off, fuzzyScope: .ocrOnly)
        q.folders = ["Livres"]
        let results = try HybridSearch.run(
            store: db.store, engine: engine, index: index, query: q,
            excludingDocsMatching: nil, rawQuery: "chat", typedQuery: "chat", limit: 10)
        XCTAssertTrue(results.hits.allSatisfy { $0.docID == a },
                      "le filtre dossier doit aussi restreindre le canal vectoriel")
    }

    /// Le filtre de PROVENANCE (lot P3) ne s'exprime pas en documents : le
    /// canal vectoriel ne peut pas le passer à `allowedDocs`, il tamise sa
    /// liste après le balayage. Sans cela, `--source ocr --hybrid` rendait des
    /// pages natives « proposées par le sens » sous un filtre qui promet le
    /// scan — et sur un document MIXTE, `allowedDocs` ne l'aurait pas rattrapé.
    func testLeFiltreDeProvenanceRestreintAussiLeCanalVectoriel() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Livres/mixte.pdf")
        try db.store.replacePages(docID: doc, pages: [
            PageText(page: 1, text: "le chat dort", source: .native),
            PageText(page: 2, text: "les félins chassent", source: .ocrAccurate),
        ])
        let engine = FakeEngine()
        _ = try EmbedRun.run(store: db.store, engine: engine, config: silentConfig())
        let index = try VectorIndex(store: db.store, dim: engine.dimension)

        var q = try QueryParser.searchQuery("chat", limit: 50, inDocIDs: [],
                                            fuzzy: .off, fuzzyScope: .ocrOnly)
        let tout = try HybridSearch.run(
            store: db.store, engine: engine, index: index, query: q,
            excludingDocsMatching: nil, rawQuery: "chat", typedQuery: "chat", limit: 10)
        XCTAssertEqual(Set(tout.hits.map(\.page)), [1, 2],
                       "sans filtre, la page 2 arrive par le seul canal du sens")

        q.sources = PageSource.typed
        let natif = try HybridSearch.run(
            store: db.store, engine: engine, index: index, query: q,
            excludingDocsMatching: nil, rawQuery: "chat", typedQuery: "chat", limit: 10)
        XCTAssertEqual(natif.hits.map(\.page), [1])
        XCTAssertEqual(natif.semanticOnly, 0)

        q.sources = PageSource.scanned
        let scanne = try HybridSearch.run(
            store: db.store, engine: engine, index: index, query: q,
            excludingDocsMatching: nil, rawQuery: "chat", typedQuery: "chat", limit: 10)
        XCTAssertEqual(scanne.hits.map(\.page), [2])
        XCTAssertEqual(scanne.semanticOnly, 1,
                       "la page scannée n'entre que par le sens : le canal "
                       + "vectoriel garde le droit de la proposer")
    }

    // MARK: - RK-01 : les guillemets désarment le sens

    /// Une phrase entre guillemets promet l'expression EXACTE. Le canal
    /// sémantique n'a pas de guillemets : jugé le 09/09/2026, il versait quatre
    /// pages sur dix qui ne la portent pas. Il n'est donc pas consulté — et le
    /// modèle n'est pas même interrogé, ce qui est la preuve que le remède n'est
    /// pas un tamis posé après coup.
    func testUnePhraseExacteDesarmeLeCanalSemantique() throws {
        let db = try makeDB()
        let chat = try addDoc(db, relPath: "Users/alice/Livres/chat.pdf")
        let felins = try addDoc(db, relPath: "Users/alice/Livres/felins.pdf")
        try db.store.replacePages(docID: chat, pages: [
            page(1, "le chat dort sur le canapé du salon")])
        try db.store.replacePages(docID: felins, pages: [
            page(1, "les félins chassent la nuit en silence")])
        let engine = CountingEngine()
        _ = try EmbedRun.run(store: db.store, engine: engine, config: silentConfig())
        let index = try VectorIndex(store: db.store, dim: engine.dimension)
        engine.queryCalls = 0

        let q = try QueryParser.searchQuery("\"le chat\"", limit: 50, inDocIDs: [],
                                            fuzzy: .off, fuzzyScope: .ocrOnly)
        let results = try HybridSearch.run(
            store: db.store, engine: engine, index: index, query: q,
            excludingDocsMatching: nil, rawQuery: "le chat",
            typedQuery: "\"le chat\"", limit: 10)

        XCTAssertEqual(engine.queryCalls, 0,
                       "le canal sémantique n'est pas interrogé du tout")
        XCTAssertEqual(results.semanticDisarmed, .exactPhrase)
        XCTAssertEqual(results.hits.map(\.docID), [chat],
                       "la page qui ne porte pas la phrase n'entre plus")
        XCTAssertEqual(results.semanticOnly, 0)
        XCTAssertEqual(results.semanticKept, 0)
        XCTAssertTrue(results.hits.allSatisfy { $0.vecRank == nil && $0.z == nil })
        XCTAssertEqual(results.semantic.scanned, 0,
                       "aucune population balayée : rien à publier sur elle")
    }

    /// La même requête sans guillemets consulte le sens : le désarmement porte
    /// sur la PHRASE, pas sur la présence de plusieurs mots.
    func testSansGuillemetsLeCanalSemantiqueEstConsulte() throws {
        let db = try makeDB()
        let chat = try addDoc(db, relPath: "Users/alice/Livres/chat.pdf")
        let felins = try addDoc(db, relPath: "Users/alice/Livres/felins.pdf")
        try db.store.replacePages(docID: chat, pages: [page(1, "le chat dort")])
        try db.store.replacePages(docID: felins, pages: [
            page(1, "les félins chassent")])
        let engine = CountingEngine()
        _ = try EmbedRun.run(store: db.store, engine: engine, config: silentConfig())
        let index = try VectorIndex(store: db.store, dim: engine.dimension)
        engine.queryCalls = 0

        let q = try QueryParser.searchQuery("chat", limit: 50, inDocIDs: [],
                                            fuzzy: .off, fuzzyScope: .ocrOnly)
        let results = try HybridSearch.run(
            store: db.store, engine: engine, index: index, query: q,
            excludingDocsMatching: nil, rawQuery: "chat", typedQuery: "chat",
            limit: 10)

        XCTAssertEqual(engine.queryCalls, 1)
        XCTAssertNil(results.semanticDisarmed)
        XCTAssertEqual(Set(results.hits.map(\.docID)), [chat, felins])
    }

    // MARK: - Le repli en flou traverse la fusion (lot MP1, C2-08)

    /// Le canal lexical de l'hybride passe par `GRDBStore.search` : il rejouait
    /// déjà la requête en flou quand l'exact ne rendait rien, mais `HybridResults`
    /// ne portait pas le drapeau et les trois surfaces se taisaient dans ce mode.
    func testLeRepliEnFlouEstPorteParLHybride() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Cours/rapport.docx",
                             ext: "docx", folder: "Cours")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "Le laboratoire de Villeurbanne accueille la conference.")])
        try TrigramExpander(store: db.store).warm()
        let engine = FakeEngine()
        _ = try EmbedRun.run(store: db.store, engine: engine, config: silentConfig())
        let index = try VectorIndex(store: db.store, dim: engine.dimension)

        let faute = try QueryParser.searchQuery("Villeurbane", limit: 50,
                                                inDocIDs: [], fuzzy: .auto,
                                                fuzzyScope: .ocrOnly)
        let replié = try HybridSearch.run(
            store: db.store, engine: engine, index: index, query: faute,
            excludingDocsMatching: nil, rawQuery: "Villeurbane",
            typedQuery: "Villeurbane", limit: 10)
        XCTAssertTrue(replié.fuzzyFallback,
                      "zéro page exacte : le canal lexical a rejoué en flou")
        XCTAssertEqual(replié.hits.first?.lexical?.fuzzyDistance, 1)

        let juste = try QueryParser.searchQuery("Villeurbanne", limit: 50,
                                                inDocIDs: [], fuzzy: .auto,
                                                fuzzyScope: .ocrOnly)
        let direct = try HybridSearch.run(
            store: db.store, engine: engine, index: index, query: juste,
            excludingDocsMatching: nil, rawQuery: "Villeurbanne",
            typedQuery: "Villeurbanne", limit: 10)
        XCTAssertFalse(direct.fuzzyFallback,
                       "le chemin normal ne porte pas le drapeau")
    }
}

// MARK: - Parité avec le modèle réel (sautés si le modèle n'est pas converti)

final class RealModelTests: XCTestCase {

    func testTokenizerParity() throws {
        guard let dir = realModelDir() else {
            throw XCTSkip("modèle e5-small absent — `fouine model download` "
                          + "l'installe (220 Mo) ; Tools/convert_e5.py + "
                          + "Tools/package_model.sh le refabriquent")
        }
        let data = try Data(contentsOf: dir.appendingPathComponent("parity.json"))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let samples = root["tokens"] as! [[String: Any]]
        let meta = try EmbedPaths.loadMeta(at: dir)
        let tokenizer = try UnigramTokenizer(
            vocabURL: dir.appendingPathComponent("vocab.json"))

        for sample in samples {
            let text = sample["text"] as! String
            let expected = (sample["ids"] as! [Any]).map { ($0 as! NSNumber).int32Value }
            let got = tokenizer.encode(text, maxTokens: meta.seq,
                                       bos: meta.bos_id, eos: meta.eos_id)
            XCTAssertEqual(got, expected, "parité rompue sur : \(text)")
        }
    }

    func testEncoderMatchesPythonReference() throws {
        guard let dir = realModelDir() else {
            throw XCTSkip("modèle e5-small absent — `fouine model download` "
                          + "l'installe (220 Mo) ; Tools/convert_e5.py + "
                          + "Tools/package_model.sh le refabriquent")
        }
        let data = try Data(contentsOf: dir.appendingPathComponent("parity.json"))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let refs = root["embeddings"] as! [[String: Any]]
        let encoder = try XCTUnwrap(sharedRealEncoder())

        for ref in refs {
            let text = ref["text"] as! String
            let expected = (ref["embedding"] as! [Any]).map {
                ($0 as! NSNumber).floatValue }
            // Les textes de référence portent déjà leur préfixe e5.
            let got = try encoder.embedRaw([text])[0]
            let cosine = zip(got, expected).map(*).reduce(0, +)
            XCTAssertGreaterThan(cosine, 0.995,
                                 "embedding trop éloigné de la référence : \(text)")
        }
    }

    func testCrossLingualSanity() throws {
        guard let encoder = try sharedRealEncoder() else {
            throw XCTSkip("modèle e5-small absent — `fouine model download` "
                          + "l'installe (220 Mo) ; Tools/convert_e5.py + "
                          + "Tools/package_model.sh le refabriquent")
        }
        let vecs = try encoder.embedPassages([
            "l'énergie libre de Gibbs et l'enthalpie de réaction",
            "Gibbs free energy and reaction enthalpy",
            "le chat dort paisiblement sur le canapé du salon",
        ])
        func cos(_ a: [Float], _ b: [Float]) -> Float {
            zip(a, b).map(*).reduce(0, +)
        }
        let related = cos(vecs[0], vecs[1])
        let unrelated = cos(vecs[0], vecs[2])
        XCTAssertGreaterThan(related, unrelated + 0.08,
                             "FR/EN de même sujet doit dominer le hors-sujet "
                             + "(related \(related), unrelated \(unrelated))")
    }
}

// MARK: - Moments du balayage et plancher de marge (C2-01, C2-02)

final class ScanStatsTests: XCTestCase {

    /// Cosinus exacts de la population synthétique : les vecteurs sont
    /// colinéaires à la requête sur un seul axe, donc `cos = k / 127`.
    private static let band: [Double] = [110, 108, 106].map { $0 / 127 }

    /// Index de trois vecteurs COLINÉAIRES à la requête, de cosinus connus et
    /// resserrés (0,835 – 0,866), plus deux vecteurs NULS. La bande étroite
    /// n'est pas un détail : c'est celle du corpus réel (0,78-0,88), et c'est
    /// elle qui rend visible ce que deux zéros font à σ.
    private func knownIndex() -> (VectorIndex, [Int8]) {
        let dim = 16
        func vector(_ scaled: Int8) -> [Int8] {
            var v = [Int8](repeating: 0, count: dim)
            v[0] = scaled
            return v
        }
        let rows: [(Int64, [Int8])] = [
            (vecRow(1, 1), vector(110)),
            (vecRow(1, 2), vector(108)),
            (vecRow(1, 3), vector(106)),
            (vecRow(2, 1), vector(0)),
            (vecRow(2, 2), vector(0)),
        ]
        let index = VectorIndex(rowids: rows.map(\.0),
                                data: rows.flatMap(\.1), dim: dim)
        return (index, vector(127))
    }

    func testMomentsExcludeZeroVectors() {
        let (index, query) = knownIndex()
        let scan = index.topK(query: query, k: 5)

        XCTAssertEqual(scan.stats.scanned, 3, "trois vecteurs non nuls")
        XCTAssertEqual(scan.stats.zeros, 2, "deux vecteurs nuls, comptés à part")

        // Les trois annotations ne sont pas décoratives : sans elles, le
        // `reduce(0, +)` sur des littéraux sans type coûtait 2,1 s de
        // type-checking à ce seul test (lot BT1).
        let cosines: [Double] = Self.band
        let mu: Double = cosines.reduce(0.0, +) / 3
        let variance: Double = cosines.map { ($0 - mu) * ($0 - mu) }.reduce(0.0, +) / 3
        XCTAssertEqual(scan.stats.mu, mu, accuracy: 1e-6)
        XCTAssertEqual(scan.stats.sigma, variance.squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(scan.stats.z(1.0), (1.0 - mu) / variance.squareRoot(),
                       accuracy: 1e-5)
    }

    /// Le vecteur nul gonflerait σ s'il entrait dans les moments : c'est
    /// exactement ce que la contre-expertise D2 reprochait à la proposition
    /// initiale de C2-01, en avançant un facteur trois. Le test le CHIFFRE
    /// plutôt que de le croire — sur cette population, deux zéros sur cinq
    /// multiplient σ par trente.
    func testZeroVectorsWouldInflateSigma() {
        let (index, query) = knownIndex()
        let sigma = index.topK(query: query, k: 5).stats.sigma
        let cosines = Self.band + [0, 0]
        let mu = cosines.reduce(0, +) / 5
        let contaminated = (cosines.map { ($0 - mu) * ($0 - mu) }
                               .reduce(0, +) / 5).squareRoot()
        XCTAssertGreaterThan(contaminated, sigma * 3,
                             "σ contaminé (\(contaminated)) contre σ propre "
                             + "(\(sigma))")
    }

    func testSigmaIsZeroOnADegenerateIndexAndZIsThenNeutral() {
        let dim = 16
        var v = [Int8](repeating: 0, count: dim)
        v[0] = 127
        let index = VectorIndex(rowids: [vecRow(1, 1)], data: v, dim: dim)
        let scan = index.topK(query: v, k: 1)
        XCTAssertEqual(scan.stats.sigma, 0)
        XCTAssertEqual(scan.stats.z(1.0), 0,
                       "σ nul : aucune marge n'a de sens, z vaut 0 — et tout "
                       + "plancher strictement positif est alors inatteignable")
    }

    /// Le centrage retire le vecteur moyen du corpus, puis renormalise. Trois
    /// pages qui ne différaient que par une composante commune énorme doivent
    /// s'écarter les unes des autres.
    func testCenteringRemovesTheCommonComponent() {
        let dim = 16
        func unit(_ a: Float, _ b: Float) -> [Int8] {
            var v = [Float](repeating: 0, count: dim)
            v[0] = a
            v[1] = b
            let norm = (a * a + b * b).squareRoot()
            return VecQuantizer.quantizeQuery(v.map { $0 / norm })
        }
        let rows: [(Int64, [Int8])] = [
            (vecRow(1, 1), unit(1, 0.10)),
            (vecRow(1, 2), unit(1, 0.05)),
            (vecRow(1, 3), unit(1, -0.10)),
        ]
        let index = VectorIndex(rowids: rows.map(\.0),
                                data: rows.flatMap(\.1), dim: dim)
        let query = unit(1, 0.10)

        let plain = index.topK(query: query, k: 3)
        let centered = index.centered()
        XCTAssertNotNil(centered.centeringMean)
        let centeredQuery = VecQuantizer.quantizeQuery(
            centered.center(query: (0..<dim).map { i in
                Float(query[i]) / VecQuantizer.scale
            }))
        let after = centered.topK(query: centeredQuery, k: 3)

        let spreadBefore = Double(plain.hits[0].cosine - plain.hits[2].cosine)
        let spreadAfter = Double(after.hits[0].cosine - after.hits[2].cosine)
        XCTAssertGreaterThan(spreadAfter, spreadBefore * 2,
                             "le centrage doit écarter les cosinus "
                             + "(avant \(spreadBefore), après \(spreadAfter))")
        // Le CÔTÉ est conservé, pas le rang : une fois la composante commune
        // retirée, les deux pages du même côté deviennent quasi colinéaires et
        // c'est la quantification int8 qui les départage. Exiger un ordre
        // stable ici ferait un test qui clignote, pas un test.
        XCTAssertEqual(after.hits[2].rowid, plain.hits[2].rowid,
                       "la page du côté opposé reste la plus lointaine")
    }

    /// Le centrage ne DONNE PAS de direction à une page vide : un vecteur nul
    /// le reste, sans quoi les pages trop courtes remonteraient dans tous les
    /// top-k.
    func testCenteringKeepsZeroVectorsZero() {
        let (index, _) = knownIndex()
        let centered = index.centered()
        for r in 3..<centered.count {
            let allZero = centered.withVector(at: r) { $0.allSatisfy { $0 == 0 } }
            XCTAssertTrue(allZero, "le vecteur nul de rang \(r) doit le rester")
        }
    }
}

// MARK: - Plancher, poids et couverture dans la fusion (C2-01, C2-02)

final class HybridFloorTests: XCTestCase {

    /// Deux documents, un seul répond lexicalement : le second n'arrive que par
    /// le canal vectoriel. C'est le montage qui rend le plancher observable.
    private func corpus() throws -> (db: TempDB, index: VectorIndex,
                                     engine: FakeEngine,
                                     lexical: Int64, semantic: Int64) {
        let db = try makeDB()
        let a = try addDoc(db, relPath: "Users/alice/Livres/chat.pdf")
        let b = try addDoc(db, relPath: "Users/alice/Livres/felins.pdf")
        try db.store.replacePages(docID: a, pages: [
            page(1, "le chat dort sur le canapé du salon")])
        try db.store.replacePages(docID: b, pages: [
            page(1, "les félins chassent la nuit en silence")])
        let engine = FakeEngine()
        _ = try EmbedRun.run(store: db.store, engine: engine,
                             config: silentConfig())
        return (db, try VectorIndex(store: db.store, dim: engine.dimension),
                engine, a, b)
    }

    private func query(_ text: String) throws -> SearchQuery {
        try QueryParser.searchQuery(text, limit: 50, inDocIDs: [],
                                    fuzzy: .off, fuzzyScope: .ocrOnly)
    }

    func testFloorZeroKeepsTodaysBehaviour() throws {
        let c = try corpus()
        let results = try HybridSearch.run(
            store: c.db.store, engine: c.engine, index: c.index,
            query: try query("chat"), excludingDocsMatching: nil,
            rawQuery: "chat", typedQuery: "chat", limit: 10, vecFloor: 0)
        XCTAssertEqual(results.hits.count, 2)
        XCTAssertEqual(results.semanticOnly, 1)
        XCTAssertEqual(results.semanticFloor, 0)
        XCTAssertEqual(results.semanticKept, c.index.pageCount,
                       "sans plancher, toute la liste vectorielle est fusionnée")
        XCTAssertTrue(results.hits.contains { $0.docID == c.semantic })
    }

    /// Plancher inatteignable : le canal vectoriel n'apporte PLUS rien, et le
    /// top-k hybride redevient exactement le top-k lexical. C'est la moitié de
    /// C2-02 — le canal ne prend plus une place sur deux quand il n'a rien à
    /// dire.
    func testUnreachableFloorCollapsesToTheLexicalRanking() throws {
        let c = try corpus()
        let lexical = try c.db.store.search(try query("chat"),
                                            excludingDocsMatching: nil)
        let results = try HybridSearch.run(
            store: c.db.store, engine: c.engine, index: c.index,
            query: try query("chat"), excludingDocsMatching: nil,
            rawQuery: "chat", typedQuery: "chat", limit: 10, vecFloor: 1e9)

        XCTAssertEqual(results.semanticKept, 0)
        XCTAssertEqual(results.semanticOnly, 0)
        XCTAssertEqual(results.hits.map(\.docID), lexical.hits.map(\.docID),
                       "le top-k hybride doit être le top-k lexical")
        XCTAssertEqual(results.hits.first?.docID, c.lexical)
        XCTAssertNil(results.hits.first?.cosine,
                     "un hit sous le plancher n'est plus un hit vectoriel")
        XCTAssertNil(results.hits.first?.z)
    }

    /// Aucun vecteur en base : même conclusion par l'autre bout — couverture
    /// nulle, top-k identique au lexical.
    func testZeroCoverageCollapsesToTheLexicalRanking() throws {
        let db = try makeDB()
        let a = try addDoc(db, relPath: "Users/alice/Livres/chat.pdf")
        try db.store.replacePages(docID: a, pages: [page(1, "le chat dort")])
        let engine = FakeEngine()
        let index = VectorIndex(rowids: [], data: [], dim: engine.dimension)
        let results = try HybridSearch.run(
            store: db.store, engine: engine, index: index,
            query: try query("chat"), excludingDocsMatching: nil,
            rawQuery: "chat", typedQuery: "chat", limit: 10)
        XCTAssertEqual(results.vectors, 0)
        XCTAssertEqual(results.coveragePct, 0)
        XCTAssertEqual(results.semanticOnly, 0)
        XCTAssertEqual(results.hits.map(\.docID), [a])
    }

    func testCoverageIsReported() throws {
        let c = try corpus()
        let results = try HybridSearch.run(
            store: c.db.store, engine: c.engine, index: c.index,
            query: try query("chat"), excludingDocsMatching: nil,
            rawQuery: "chat", typedQuery: "chat", limit: 10)
        XCTAssertEqual(results.vectors, 2)
        XCTAssertEqual(results.pagesIndexed, 2)
        XCTAssertEqual(results.coveragePct, 100, accuracy: 0.001)
    }

    /// Les poids arrivent bien jusqu'au RRF : à poids lexical nul, l'ordre est
    /// celui du seul canal vectoriel.
    func testWeightsReachTheFusion() throws {
        let c = try corpus()
        let balanced = try HybridSearch.run(
            store: c.db.store, engine: c.engine, index: c.index,
            query: try query("chat"), excludingDocsMatching: nil,
            rawQuery: "chat", typedQuery: "chat", limit: 10, lexWeight: 1, vecWeight: 1)
        XCTAssertEqual(balanced.hits.first?.docID, c.lexical)

        let vectorOnly = try HybridSearch.run(
            store: c.db.store, engine: c.engine, index: c.index,
            query: try query("chat"), excludingDocsMatching: nil,
            rawQuery: "chat", typedQuery: "chat", limit: 10, lexWeight: 0, vecWeight: 1)
        let byVectorRank = vectorOnly.hits.sorted {
            ($0.vecRank ?? .max) < ($1.vecRank ?? .max)
        }
        XCTAssertEqual(vectorOnly.hits.map(\.docID), byVectorRank.map(\.docID),
                       "à poids lexical nul, l'ordre est celui du canal vectoriel")
        XCTAssertTrue(vectorOnly.hits.contains { $0.docID == c.semantic })
    }

    /// La marge est rendue avec chaque hit vectoriel : c'est ce que la CLI
    /// affiche et ce que l'app met en infobulle (C2-13).
    ///
    /// Corpus PROPRE à ce test : le montage à deux pages de `corpus()` donne
    /// deux vecteurs identiques (« chat » et « félins » sont le même thème pour
    /// le moteur factice), donc σ = 0 et aucune marge n'a de sens. Il faut une
    /// troisième page d'un autre thème pour que la population ait une
    /// dispersion — c'est exactement la condition sous laquelle une marge se
    /// calcule.
    func testHitsCarryTheirMargin() throws {
        let db = try makeDB()
        let a = try addDoc(db, relPath: "Users/alice/Livres/chat.pdf")
        let b = try addDoc(db, relPath: "Users/alice/Livres/felins.pdf")
        let c = try addDoc(db, relPath: "Users/alice/Livres/acide.pdf")
        try db.store.replacePages(docID: a, pages: [
            page(1, "le chat dort sur le canapé du salon")])
        try db.store.replacePages(docID: b, pages: [
            page(1, "les félins chassent la nuit en silence")])
        try db.store.replacePages(docID: c, pages: [
            page(1, "un acide fort réagit avec une base faible")])
        let engine = FakeEngine()
        _ = try EmbedRun.run(store: db.store, engine: engine,
                             config: silentConfig())
        let index = try VectorIndex(store: db.store, dim: engine.dimension)

        let results = try HybridSearch.run(
            store: db.store, engine: engine, index: index,
            query: try query("chat"), excludingDocsMatching: nil,
            rawQuery: "chat", typedQuery: "chat", limit: 10)
        XCTAssertGreaterThan(results.semantic.sigma, 0,
                             "trois thèmes : la population a une dispersion")
        var checked = 0
        for hit in results.hits where hit.vecRank != nil {
            let z = try XCTUnwrap(hit.z)
            let cosine = try XCTUnwrap(hit.cosine)
            XCTAssertEqual(z, (Double(cosine) - results.semantic.mu)
                                  / results.semantic.sigma,
                           accuracy: 1e-6)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "au moins un hit vectoriel vérifié")
    }
}

// MARK: - Plancher sous le VRAI modèle (sauté sans lui)

final class RealModelFloorTests: XCTestCase {

    /// Le mécanisme du plancher, de bout en bout, avec le vrai encodeur : une
    /// requête HORS DOMAINE ne doit produire AUCUN hit sémantique pur dès que
    /// le plancher passe au-dessus de sa meilleure marge.
    ///
    /// Ce test vérifie la MÉCANIQUE, pas une séparation : la mesure du
    /// 03/09/2026 sur la base de production (12 requêtes témoins, 64 872
    /// vecteurs) montre qu'aucun plancher constant ne sépare les requêtes
    /// absurdes des requêtes pertinentes — la marge les classe même à l'envers.
    /// C'est pourquoi `HybridSearch.defaultVectorFloor` vaut 0.
    func testFloorRemovesOutOfDomainSemanticHits() throws {
        guard let engine = try sharedRealEncoder() else {
            throw XCTSkip("modèle e5-small absent — `fouine model download` "
                          + "l'installe (220 Mo)")
        }
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Cours/thermo.pdf")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "L'énergie libre de Gibbs G = H − TS décide du sens "
                  + "spontané d'une transformation à température et pression "
                  + "constantes."),
            page(2, "La calorimétrie mesure la chaleur dégagée par une "
                  + "réaction : le calorimètre est étalonné par effet Joule."),
            page(3, "La spectroscopie infrarouge identifie les groupes "
                  + "carbonyles par leur bande d'élongation vers 1700 cm⁻¹."),
        ])
        _ = try EmbedRun.run(store: db.store, engine: engine,
                             config: silentConfig(minChars: 1))
        let index = try VectorIndex(store: db.store, dim: engine.dimension)
        XCTAssertEqual(index.count, 3)

        let raw = "recette de tarte aux pommes de ma grand mere"
        let q = try QueryParser.searchQuery(raw, limit: 50, inDocIDs: [],
                                            fuzzy: .off, fuzzyScope: .ocrOnly)
        let open = try HybridSearch.run(
            store: db.store, engine: engine, index: index, query: q,
            excludingDocsMatching: nil, rawQuery: raw, typedQuery: raw, limit: 10, vecFloor: 0)
        XCTAssertGreaterThan(open.semanticOnly, 0,
                             "sans plancher, la requête absurde ramène du bruit")
        let best = try XCTUnwrap(open.semantic.zMax)

        let floored = try HybridSearch.run(
            store: db.store, engine: engine, index: index, query: q,
            excludingDocsMatching: nil, rawQuery: raw, typedQuery: raw, limit: 10,
            vecFloor: best + 0.01)
        XCTAssertEqual(floored.semanticKept, 0)
        XCTAssertEqual(floored.semanticOnly, 0,
                       "au-dessus de sa meilleure marge, la requête absurde ne "
                       + "produit plus aucun hit sémantique pur")
    }
}
