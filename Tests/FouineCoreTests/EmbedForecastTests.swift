// EmbedForecastTests.swift — « il reste combien de temps ? » (idée 7 de A1m).
// Propriété : A-Core.
//
// `fouine embed --status` disait « 385 626 pages » et `--bench` projetait sur
// « 379 267 pages », le corpus de recette codé en dur. Ni l'un ni l'autre ne
// répondait à la seule question qui se pose devant une campagne de vingt
// heures. La projection se fait désormais sur les pages RÉELLES et le débit
// RÉEL de la dernière passe — et se tait quand elle ne sait pas.

import Foundation
import XCTest
@testable import FouineCore

final class EmbedForecastTests: XCTestCase {

    /// `n` pages d'un texte assez long pour porter `windows` fenêtres, toutes
    /// vectorisées et complètes.
    private func fill(_ db: TempDB, pages: Int, windowsEach: Int) throws {
        let docID = try addDoc(db, relPath: "corpus.pdf")
        // Table de référence de `vecWindowCount` : 1 000 -> 1 fenêtre,
        // 2 000 -> 2, 3 000 -> 3. La longueur ne change rien à la projection
        // (qui compte les blobs non vides) ; elle garde la base plausible.
        try db.store.replacePages(docID: docID, pages: (1...pages).map {
            page($0, String(repeating: "a", count: windowsEach * 1_000))
        })
        var rows: [(rowid: Int64, vec: Data)] = []
        for p in 1...pages {
            let rowid = Schema.ftsRowID(docID: docID, page: p)
            for chunk in 0..<Schema.vecWindowMax {
                let real = chunk < windowsEach
                rows.append((Schema.vecRowID(pageRowID: rowid, chunk: chunk),
                             real ? Data(repeating: 1, count: 384) : Data()))
            }
        }
        try db.store.upsertVectors(rows)
    }

    func testWithoutAMeasuredThroughputTheForecastSaysNothing() throws {
        let db = try makeDB(lockTimeout: 0.3)
        try fill(db, pages: 4, windowsEach: 2)
        let docID = try addDoc(db, relPath: "reste.pdf")
        try db.store.replacePages(docID: docID, pages: [page(1, "à faire")])

        let forecast = try db.store.embedForecast()
        XCTAssertNil(forecast.windowsPerSecond)
        XCTAssertNil(forecast.remainingHours,
                     "un chiffre inventé est pire que pas de chiffre")
        XCTAssertEqual(forecast.incompletePages, 1)
    }

    /// La géométrie se MESURE sur cette base : un corpus de notes courtes tient
    /// en une fenêtre par page, et lui projeter les 2,13 du corpus de
    /// production lui annoncerait le double du travail réel.
    func testWindowsPerPageIsMeasuredOnThisDatabase() throws {
        let short = try makeDB(lockTimeout: 0.3)
        try fill(short, pages: 5, windowsEach: 1)
        XCTAssertEqual(try short.store.embedForecast().windowsPerPage,
                       1.0, accuracy: 0.001)

        let long = try makeDB(lockTimeout: 0.3)
        try fill(long, pages: 5, windowsEach: 3)
        XCTAssertEqual(try long.store.embedForecast().windowsPerPage,
                       3.0, accuracy: 0.001)
    }

    /// Sur une base neuve — aucune page complète —, on retombe sur la constante
    /// du corpus de production plutôt que de diviser par zéro.
    func testAnEmptyDatabaseFallsBackToTheProductionRatio() throws {
        let db = try makeDB(lockTimeout: 0.3)
        let docID = try addDoc(db, relPath: "neuf.pdf")
        try db.store.replacePages(docID: docID, pages: [page(1, "rien encore")])
        let forecast = try db.store.embedForecast()
        XCTAssertEqual(forecast.windowsPerPage, 2.13, accuracy: 0.001)
        XCTAssertEqual(forecast.incompletePages, 1)
    }

    func testTheRecordedThroughputTurnsPagesIntoHours() throws {
        let db = try makeDB(lockTimeout: 0.3)
        try fill(db, pages: 2, windowsEach: 2)
        let docID = try addDoc(db, relPath: "reste.pdf")
        try db.store.replacePages(docID: docID, pages: (1...900).map {
            page($0, String(repeating: "b", count: 2_000))
        })

        try db.store.recordEmbedRate(windowsPerSecond: 5.0)
        let forecast = try db.store.embedForecast()
        XCTAssertEqual(forecast.windowsPerSecond, 5.0)
        XCTAssertNotNil(forecast.measuredAt)
        XCTAssertEqual(forecast.incompletePages, 900)
        // 900 pages × 2 fenêtres / 5 par seconde = 360 s = 0,1 h.
        XCTAssertEqual(try XCTUnwrap(forecast.remainingHours),
                       0.1, accuracy: 0.001)
    }

    /// Une file vide ne projette rien : il n'y a plus rien à attendre.
    func testNothingLeftMeansNoForecast() throws {
        let db = try makeDB(lockTimeout: 0.3)
        try fill(db, pages: 3, windowsEach: 2)
        try db.store.recordEmbedRate(windowsPerSecond: 5.0)
        let forecast = try db.store.embedForecast()
        XCTAssertEqual(forecast.incompletePages, 0)
        XCTAssertNil(forecast.remainingHours)
    }

    /// Un débit nul ou négatif ne s'enregistre pas : il produirait une
    /// projection infinie.
    func testAZeroThroughputIsNotRecorded() throws {
        let db = try makeDB(lockTimeout: 0.3)
        try db.store.recordEmbedRate(windowsPerSecond: 0)
        XCTAssertNil(try db.store.embedForecast().windowsPerSecond)
    }
}
