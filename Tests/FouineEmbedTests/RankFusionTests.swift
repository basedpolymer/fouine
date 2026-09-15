// RankFusionTests.swift — la fusion RRF du lot R1 : échelle de rang du canal
// sémantique et diversité par document de la liste vectorielle.
// Propriété : A-Embed.

import XCTest
import FouineCore
@testable import FouineEmbed

final class RankFusionTests: XCTestCase {

    /// Sans échelle, la fusion est le RRF canonique : les deux têtes de liste
    /// sont ex æquo et le rang 1 de chaque liste vaut 1/61.
    func testWithoutScaleTheFusionIsTheCanonicalRRF() {
        let fused = RRF.fuse([[1, 2, 3], [4, 5, 6]])
        XCTAssertEqual(fused.map(\.id), [1, 4, 2, 5, 3, 6])
        XCTAssertEqual(fused[0].score, 1 / 61, accuracy: 1e-12)
    }

    /// Avec une échelle de 6 sur la seconde liste, son premier vaut le
    /// septième de la première : `1 / (60 + 1 × 6) = 1 / 66`.
    func testARankScaleMovesAListDownWithoutSilencingIt() {
        let fused = RRF.fuse([[1, 2, 3], [4, 5, 6]], rankScales: [1, 6])
        XCTAssertEqual(fused.map(\.id), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(fused[3].score, 1 / 66, accuracy: 1e-12)
        XCTAssertEqual(fused[3].ranks, [nil, 1], "le rang d'origine reste celui de la liste")
    }

    /// Une page présente dans les deux listes cumule toujours ses deux parts.
    func testAPageInBothListsStillAddsUp() {
        let fused = RRF.fuse([[1, 2], [2, 3]], rankScales: [1, 6])
        XCTAssertEqual(fused.first?.id, 2)
        // Somme sortie de l'assertion et TYPÉE : dans l'appel, les quatre
        // littéraux sans type coûtaient 2,7 s de type-checking (lot BT1).
        let expected: Double = 1 / 62 + 1 / 66
        XCTAssertEqual(fused.first?.score ?? 0, expected, accuracy: 1e-12)
    }

    func testSemanticRankScaleIsTheInverseOfCoverage() {
        XCTAssertEqual(HybridSearch.semanticRankScale(vectors: 16, pagesIndexed: 100), 6.25)
        XCTAssertEqual(HybridSearch.semanticRankScale(vectors: 100, pagesIndexed: 100), 1)
        XCTAssertEqual(HybridSearch.semanticRankScale(vectors: 0, pagesIndexed: 100), 1,
                       "sans vecteur, aucune correction plutôt qu'une division par zéro")
        XCTAssertEqual(HybridSearch.semanticRankScale(vectors: 150, pagesIndexed: 100), 1,
                       "plus de vecteurs que de pages (compte périmé) : pas d'échelle < 1")
        XCTAssertEqual(HybridSearch.semanticRankScale(vectors: 10, pagesIndexed: 0), 1)
    }

    /// Cinq pages d'un même document en tête de la liste vectorielle : les
    /// trois premières restent, les deux suivantes comptent comme si elles
    /// étaient DEUX FOIS plus loin (4ᵉ → rang 8, 5ᵉ → rang 10) — un palier doux,
    /// pas une relégation en queue (AUDIT-R1 I4). Avec sept autres documents
    /// derrière, la quatrième page ressort sixième, la cinquième neuvième.
    func testTheVectorListDemotesTheFourthPageSoftly() {
        func doc(_ n: Int64) -> Int64 { n * Schema.pagesPerDocLimit }
        let d1 = doc(1)
        let others = (2...8).map { doc(Int64($0)) + 1 }
        let list = [d1 + 1, d1 + 2, d1 + 3, d1 + 4, d1 + 5] + others
        let out = HybridSearch.diversified(list)
        XCTAssertEqual(Array(out.prefix(3)), [d1 + 1, d1 + 2, d1 + 3],
                       "les trois meilleures pages du document gardent leur place")
        XCTAssertEqual(out.firstIndex(of: d1 + 4), 5, "rang 8, à égalité devant le 8ᵉ venu")
        XCTAssertEqual(out.firstIndex(of: d1 + 5), 8, "rang 10")
        XCTAssertEqual(out, [d1 + 1, d1 + 2, d1 + 3, others[0], others[1], d1 + 4,
                             others[2], others[3], d1 + 5, others[4], others[5], others[6]])
        XCTAssertEqual(Set(out), Set(list), "ne change que l'ordre")
        XCTAssertEqual(HybridSearch.diversified(list, perDocument: 10), list,
                       "sous le plafond, rien ne bouge")
        XCTAssertEqual(HybridSearch.diversified([]), [])
    }

    /// Un seul document dans la liste : ses pages 4 et suivantes gardent leur
    /// ordre relatif — il n'y a personne à faire passer devant.
    func testASingleDocumentKeepsItsOrder() {
        let d1 = Int64(1) * Schema.pagesPerDocLimit
        let list = (1...6).map { d1 + Int64($0) }
        XCTAssertEqual(HybridSearch.diversified(list), list)
    }
}
