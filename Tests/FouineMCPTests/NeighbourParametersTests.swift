// NeighbourParametersTests.swift — `encode_if_missing` et `compact` sur
// `fouine_similar_pages` (lot MC4, PM-07).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// AUCUN DE CES TESTS NE CHARGE COREML, et c'est le point : le contrat de coût
// de l'outil est son défaut, et la porte ouverte par `encode_if_missing` se
// juge d'abord sur ce qu'elle fait QUAND ELLE NE PEUT PAS S'OUVRIR — modèle
// absent, page sans texte. Le vecteur produit, lui, est éprouvé là où il est
// produit : `FouineEmbedTests.PageEmbeddingTests`, contre une vraie campagne.

import Foundation
import XCTest
import FouineCore
import FouineMCP
import FouineMCPKit

final class NeighbourParametersTests: XCTestCase {

    private func tool(_ index: TempIndex) -> SimilarPagesTool {
        let store = ReadOnlyStore(path: index.databaseURL)
        return SimilarPagesTool(
            store: store,
            semantic: SemanticEngine(store: store,
                                     modelDirectory: index.directory
                                         .appendingPathComponent("no-model")))
    }

    /// Le défaut. Le refus NOMME l'option qui le lèverait : sans cela un modèle
    /// conclut « rien ne ressemble à cette page » là où la cause est une
    /// campagne qui n'est pas passée.
    func testWithoutTheParameterTheRefusalNamesIt() throws {
        let index = try TempIndex(vectorisedPages: 2)
        let result = try tool(index).call(arguments: ["doc_id": 2, "page": 3])

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.structured["source_has_vector"] as? Bool, false)
        XCTAssertTrue(result.structured["source_vector"] is NSNull)
        let note = try XCTUnwrap(result.structured["note"] as? String)
        XCTAssertTrue(note.contains("encode_if_missing"), note)
    }

    /// Demandé, mais le modèle n'est pas installé : un refus qui dit lequel des
    /// deux manque, et le geste. Pas une erreur d'outil — la page existe.
    func testAskedForWithoutAModelSaysWhichPieceIsMissing() throws {
        let index = try TempIndex(vectorisedPages: 2)
        let result = try tool(index).call(arguments: [
            "doc_id": 2, "page": 3, "encode_if_missing": true,
        ])

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.structured["source_has_vector"] as? Bool, false)
        XCTAssertTrue(result.structured["source_vector"] is NSNull)
        let note = try XCTUnwrap(result.structured["note"] as? String)
        XCTAssertTrue(note.contains("model is not installed"), note)
        XCTAssertEqual((result.structured["neighbours"] as? [Any])?.count, 0)
    }

    /// Une page déjà vectorisée ne passe JAMAIS par le modèle, que le paramètre
    /// soit là ou non : le coût de l'appel ordinaire est un acquis.
    /// `source_has_vector` décrit LA BASE. Une page encodée à la volée n'en a
    /// toujours pas, et le dire autrement ferait croire que la campagne y est
    /// passée — c'est `source_vector` qui dit d'où vient celui qui a servi.
    func testAStoredVectorIsUsedEvenWhenEncodingIsAllowed() throws {
        let index = try TempIndex(vectorisedPages: 2)
        let result = try tool(index).call(arguments: [
            "doc_id": 1, "page": 1, "encode_if_missing": true,
        ])
        XCTAssertEqual(result.structured["source_has_vector"] as? Bool, true)
        XCTAssertEqual(result.structured["source_vector"] as? String, "stored")
    }

    /// `compact` : les chemins quittent les voisins pour `documents`, et `hits`
    /// dit combien de voisins viennent du même fichier.
    func testCompactMovesThePathsOutOfTheNeighbours() throws {
        let index = try TempIndex(vectorisedPages: 2)
        // Les deux seules pages vectorisées de cette base sont dans le MÊME
        // document : sans lever l'exclusion, il n'y aurait aucun voisin.
        let result = try tool(index).call(arguments: [
            "doc_id": 1, "page": 1, "compact": true,
            "exclude_same_document": false,
        ])
        let neighbours = try XCTUnwrap(result.structured["neighbours"]
                                        as? [[String: Any]])
        XCTAssertFalse(neighbours.isEmpty)
        for neighbour in neighbours {
            XCTAssertNil(neighbour["path"])
            XCTAssertNil(neighbour["link"])
            XCTAssertNotNil(neighbour["doc_id"])
            // La clé reste PRÉSENTE même hors transcription.
            XCTAssertTrue(neighbour.keys.contains("time_seconds"))
        }
        let documents = try XCTUnwrap(result.structured["documents"]
                                        as? [String: Any])
        let first = try XCTUnwrap(documents.values.first as? [String: Any])
        XCTAssertNotNil(first["path"])
        XCTAssertNotNil(first["hits"])
    }

    /// Sans `compact`, la clé `documents` est ABSENTE : un objet vide se lirait
    /// comme un listage qui n'a rien rendu.
    func testDocumentsIsAbsentWithoutCompact() throws {
        let index = try TempIndex(vectorisedPages: 2)
        let result = try tool(index).call(arguments: [
            "doc_id": 1, "page": 1, "exclude_same_document": false,
        ])
        XCTAssertFalse((result.structured["neighbours"] as? [Any] ?? []).isEmpty)
        XCTAssertNil(result.structured["documents"])
    }
}
