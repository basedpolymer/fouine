// SemanticFreshnessTests.swift — l'index vectoriel qui suit la campagne.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// LA PANNE QU'ON ÉCARTE ICI EST LENTE ET MUETTE. La campagne `fouine embed`
// ajoute ~5 vecteurs/s en arrière-plan ; un serveur MCP ouvert vingt heures à
// côté d'elle, s'il gardait l'index de son premier chargement, répondrait
// « rien de proche » sur des pages qu'il a sous les yeux — et rien, dans sa
// sortie, ne le dirait.
//
// LE CRITÈRE N'EST PAS L'ÉGALITÉ. `count(*) != index.count` serait vrai en
// permanence pendant une campagne, donc l'index serait rechargé à chaque appel
// (~1 s pour 379 k vecteurs). C'est le constat de C2-07, et la réponse est
// celle que l'application applique déjà : une DÉRIVE RELATIVE de 10 %
// (`SemanticService.staleRatio`), plus un plafond de dix minutes pour le cas
// d'un gros index qui grossit lentement.
//
// L'horloge est INJECTÉE : un test qui attendrait dix minutes ne serait pas un
// test.

import Foundation
import XCTest
import GRDB
import FouineCore
import FouineMCP

final class SemanticFreshnessTests: XCTestCase {

    /// Une horloge qu'on avance à la main.
    private final class Clock: @unchecked Sendable {
        private let mutex = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { mutex.lock(); defer { mutex.unlock() }; return value }
        func advance(_ seconds: TimeInterval) {
            mutex.lock(); value += seconds; mutex.unlock()
        }
    }

    /// Ajoute des vecteurs par une connexion SÉPARÉE et en écriture — c'est
    /// exactement ce que fait `fouine embed` pendant que le serveur lit.
    private func addVectors(_ index: TempIndex, docID: Int64, pages: Range<Int>) throws {
        let writer = GRDBStore()
        try writer.open(at: index.databaseURL)
        defer { writer.releaseWriteLock() }
        // Schéma v5 : rowid de FENÊTRE (fenêtre 0 de chaque page).
        try writer.upsertVectors(pages.map {
            (Schema.vecRowID(pageRowID: Schema.ftsRowID(docID: docID, page: $0),
                             chunk: 0),
             Data(repeating: 6, count: 384))
        })
    }

    /// Le rechargement attend que la file de fond ait fini. Elle est SÉRIE : un
    /// appel de plus suffit à savoir qu'elle a rendu la main.
    private func settle(_ engine: SemanticEngine, dimension: Int = 384) {
        for _ in 0..<20 {
            _ = try? engine.currentIndex(dimension: dimension)
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// Le premier chargement est BLOQUANT — il n'y a rien à répondre avec — et
    /// il remplit `index_freshness`.
    func testTheFirstLoadIsSynchronousAndDated() throws {
        let index = try TempIndex(documents: 4, pagesPerDocument: 5,
                                  vectorisedPages: 10)
        let clock = Clock()
        let engine = SemanticEngine(store: ReadOnlyStore(path: index.databaseURL),
                                    modelDirectory: index.directory
                                        .appendingPathComponent("no-model"),
                                    now: { clock.now })

        XCTAssertNil(engine.freshness().indexLoadedAt, "rien n'est chargé au départ")
        let loaded = try XCTUnwrap(engine.currentIndex(dimension: 384))
        XCTAssertEqual(loaded.count, 10)

        let state = engine.freshness()
        XCTAssertEqual(state.indexCount, 10)
        XCTAssertEqual(state.indexLoadedAt, clock.now)
        XCTAssertFalse(state.modelLoaded, "l'index n'entraîne PAS le modèle")
    }

    /// Une dérive SOUS le seuil ne recharge pas. C'est le point : recharger à la
    /// moindre différence coûterait une seconde par appel pendant toute une
    /// campagne, pour un index à peine plus complet.
    func testADriftBelowTenPercentDoesNotReload() throws {
        // Cinq documents, quarante pages vectorisées : les quatre premiers sont
        // couverts, le CINQUIÈME ne l'est pas. C'est lui qu'on remplit — sans
        // quoi l'écriture serait un `upsert` sur des lignes existantes et le
        // compte ne bougerait pas, ce qui ferait passer le test pour rien.
        let index = try TempIndex(documents: 5, pagesPerDocument: 10,
                                  vectorisedPages: 40)
        let clock = Clock()
        let engine = SemanticEngine(store: ReadOnlyStore(path: index.databaseURL),
                                    modelDirectory: index.directory
                                        .appendingPathComponent("no-model"),
                                    now: { clock.now })
        _ = try engine.currentIndex(dimension: 384)
        XCTAssertEqual(engine.freshness().indexCount, 40)

        // +3 vecteurs sur 40, soit 7,5 % : sous le seuil de 10 %.
        try addVectors(index, docID: 5, pages: 1..<4)
        clock.advance(SemanticEngine.countInterval + 1)   // le compte se relit
        settle(engine)
        XCTAssertEqual(engine.freshness().indexCount, 40,
                       "7,5 % de dérive ne justifie pas de relire 40 vecteurs")
    }

    /// Une dérive AU-DESSUS du seuil recharge — sur la file de fond, donc la
    /// requête qui l'a déclenchée répond avec l'ancien index. Un index vieux
    /// d'une minute est une bonne réponse ; une réponse en retard d'une
    /// seconde, non.
    func testADriftAboveTenPercentReloadsInTheBackground() throws {
        let index = try TempIndex(documents: 4, pagesPerDocument: 10,
                                  vectorisedPages: 20)
        let clock = Clock()
        let engine = SemanticEngine(store: ReadOnlyStore(path: index.databaseURL),
                                    modelDirectory: index.directory
                                        .appendingPathComponent("no-model"),
                                    now: { clock.now })
        _ = try engine.currentIndex(dimension: 384)
        XCTAssertEqual(engine.freshness().indexCount, 20)

        // +10 vecteurs sur 20, soit 50 %.
        try addVectors(index, docID: 3, pages: 1..<11)
        clock.advance(SemanticEngine.countInterval + 1)
        settle(engine)
        XCTAssertEqual(engine.freshness().indexCount, 30,
                       "la dérive dépasse 10 % : l'index doit avoir été échangé")
        XCTAssertEqual(engine.freshness().indexLoadedAt, clock.now)
    }

    /// Le PLAFOND D'ÂGE, pour le cas que la dérive relative ne voit pas : un
    /// gros index qui grossit lentement. Dix minutes, quoi qu'il arrive.
    func testTenMinutesReloadEvenWithoutDrift() throws {
        let index = try TempIndex(documents: 5, pagesPerDocument: 10,
                                  vectorisedPages: 40)
        let clock = Clock()
        let engine = SemanticEngine(store: ReadOnlyStore(path: index.databaseURL),
                                    modelDirectory: index.directory
                                        .appendingPathComponent("no-model"),
                                    now: { clock.now })
        _ = try engine.currentIndex(dimension: 384)
        let firstLoad = engine.freshness().indexLoadedAt

        try addVectors(index, docID: 5, pages: 1..<3)      // +2 sur 40 : 5 %
        clock.advance(SemanticEngine.maxIndexAge + 1)
        settle(engine)

        XCTAssertNotEqual(engine.freshness().indexLoadedAt, firstLoad,
                          "au-delà de dix minutes, on relit sans discuter")
        XCTAssertEqual(engine.freshness().indexCount, 42)
    }

    /// Le `count(*)` est demandé AU PLUS UNE FOIS PAR MINUTE. Sans cette
    /// mémoire, chaque appel paierait un balayage de `page_vec` pour découvrir,
    /// neuf fois sur dix, qu'il n'y a rien à faire.
    func testTheVectorCountIsPolledAtMostOncePerMinute() throws {
        let index = try TempIndex(documents: 4, pagesPerDocument: 10,
                                  vectorisedPages: 20)
        let clock = Clock()
        let engine = SemanticEngine(store: ReadOnlyStore(path: index.databaseURL),
                                    modelDirectory: index.directory
                                        .appendingPathComponent("no-model"),
                                    now: { clock.now })
        _ = try engine.currentIndex(dimension: 384)

        try addVectors(index, docID: 3, pages: 1..<11)     // +10 sur 20 : 50 %
        // L'horloge n'a pas bougé : le compte est encore celui d'il y a un
        // instant, et l'index ne doit PAS être rechargé.
        settle(engine)
        XCTAssertEqual(engine.freshness().indexCount, 20,
                       "le compte ne se relit pas plus d'une fois par minute")

        clock.advance(SemanticEngine.countInterval + 1)
        settle(engine)
        XCTAssertEqual(engine.freshness().indexCount, 30,
                       "une minute plus tard, la dérive est vue")
    }

    /// Une base SANS vecteur ne rend pas d'index — et ce n'est pas une erreur.
    /// C'est une campagne qui n'a pas tourné, et l'appelant doit pouvoir le dire
    /// au modèle.
    func testAnEmptyIndexIsNilAndNotAFailure() throws {
        let index = try TempIndex()
        let engine = SemanticEngine(store: ReadOnlyStore(path: index.databaseURL),
                                    modelDirectory: index.directory
                                        .appendingPathComponent("no-model"))
        XCTAssertNil(try engine.indexWithoutModel())
        XCTAssertFalse(engine.isAvailable())
        XCTAssertNil(engine.freshness().indexCount)
    }

    /// La dimension se lit dans `vec_meta` — et, à défaut, sur la LONGUEUR d'un
    /// blob. Une base dont `vec_meta` a été perdue porte quand même des vecteurs
    /// parfaitement utilisables : refuser de les charger ferait répondre
    /// « aucun vecteur » sur un index qui en a des dizaines de milliers.
    func testTheDimensionFallsBackToTheBlobLength() throws {
        let index = try TempIndex(vectorisedPages: 2)
        let writer = try DatabaseQueue(path: index.databaseURL.path)
        try writer.write { db in try db.execute(sql: "DELETE FROM vec_meta") }

        let engine = SemanticEngine(store: ReadOnlyStore(path: index.databaseURL),
                                    modelDirectory: index.directory
                                        .appendingPathComponent("no-model"))
        XCTAssertEqual(try engine.storedDimension(), 384)
        XCTAssertEqual(try engine.indexWithoutModel()?.count, 2)
    }
}
