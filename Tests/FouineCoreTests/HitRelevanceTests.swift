// HitRelevanceTests.swift — la pertinence relative d'un hit (lot MC2, constat
// PM-16d). Propriété : A-Core.
//
// La référence est la sortie texte de `fouine search` : `100 %` au premier,
// `86 %` à un hit dont le BM25 vaut 86 % du meilleur. Ce test fige cette
// arithmétique, y compris ses deux cas dégénérés — un BM25 nul (le terme est
// sur toutes les pages, l'IDF s'annule) et une liste d'un seul élément, qui
// valent 100 et non 0.

import XCTest
@testable import FouineCore

final class HitRelevanceTests: XCTestCase {

    func testLeMeilleurVaut100EtLesAutresLeurPart() throws {
        let pct = HitRelevance.percentages(bm25: [-10, -8.6, -8.1, -5])
        XCTAssertEqual(pct, [100, 86, 81, 50])
    }

    func testUnScoreNulNeDitRienDoncVaut100() throws {
        XCTAssertEqual(HitRelevance.percentages(bm25: [0, 0]), [100, 100])
        XCTAssertEqual(HitRelevance.percentages(bm25: []), [])
    }

    /// Une page dont le score est nul dans une liste qui, elle, classe : 0 %
    /// est la valeur juste — elle ne porte rien de ce qui départage.
    func testUnScoreNulDansUneListeQuiClasse() throws {
        XCTAssertEqual(HitRelevance.percentages(bm25: [-10, 0]), [100, 0])
    }

    /// En hybride le meilleur est le PLUS GRAND (le RRF est positif) : prendre
    /// le minimum aurait mis 100 % au dernier résultat.
    func testLeRRFSeLitDansLAutreSens() throws {
        let pct = HitRelevance.percentages(rrf: [0.0164, 0.0143, 0.0082])
        XCTAssertEqual(pct, [100, 87, 50])
    }

    func testLePourcentageResteBorne() throws {
        XCTAssertEqual(HitRelevance.percentage(score: -20, best: -10), 100,
                       "un score meilleur que le meilleur ne dépasse pas 100")
        XCTAssertEqual(HitRelevance.percentage(score: 3, best: -10), 100,
                       "des signes contraires : rien à comparer")
    }
}
