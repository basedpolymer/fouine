// SearchParametersTests.swift — les cinq paramètres du lot MC2 (`since`,
// `fuzzy`, `facet`, `compact`, `marks`) et le message d'une énumération refusée.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// Les transcriptions golden figent la FORME des schémas ; ce fichier éprouve ce
// qu'elles ne montrent pas : que les paramètres AGISSENT, qu'une date illisible
// est refusée avec son format plutôt que silencieusement ignorée, et qu'une
// valeur hors énumération dit ses valeurs dans `message` — le seul champ que
// beaucoup de clients MCP donnent à lire au modèle (constat PM-08).

import Foundation
import XCTest
import GRDB
import FouineCore
import FouineMCPKit
@testable import FouineMCP

final class SearchParametersTests: XCTestCase {

    // MARK: - Appel

    private func call(_ index: TempIndex, _ arguments: String,
                      id: Int = 1) throws -> [String: Any] {
        let server = try index.makeServer()
        let response = try XCTUnwrap(server.handle(Data(
            #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"fouine_search","arguments":\#(arguments)}}"#.utf8)))
        return try JSONMatch.object(response)
    }

    private func payload(_ index: TempIndex, _ arguments: String) throws
        -> [String: Any] {
        let object = try call(index, arguments)
        XCTAssertNil(object["error"], "\(object)")
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertNil(result["isError"], "\(result)")
        return try XCTUnwrap(result["structuredContent"] as? [String: Any])
    }

    // MARK: - `since`

    func testSinceEcarteLesDocumentsPlusAnciens() throws {
        let index = try TempIndex()
        // Les deux documents de la base jetable sont du 14/11/2023.
        let avant = try payload(index,
            #"{"query":"electrolyse","since":"2020-01-01","limit":50}"#)
        XCTAssertEqual(avant["total_pages"] as? Int, 6)
        let apres = try payload(index,
            #"{"query":"electrolyse","since":"2030-01-01","limit":50}"#)
        XCTAssertEqual(apres["total_pages"] as? Int, 0,
                       "aucun document modifié après cette date")
    }

    /// Une date illisible est une erreur d'OUTIL qui DIT le format : filtrer sur
    /// rien du tout en silence rendrait une réponse à une question qui n'a pas
    /// été posée, et le modèle n'aurait aucun moyen de s'en apercevoir.
    func testUneDateMalFormeeEstRefuseeEnDisantLeFormat() throws {
        let object = try call(try TempIndex(),
                              #"{"query":"electrolyse","since":"14/11/2023"}"#)
        XCTAssertNil(object["error"], "c'est une erreur d'outil, pas une -32602")
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("YYYY-MM-DD"), text)
    }

    // MARK: - `fuzzy`

    func testFuzzyOffNeRendPlusLesOrthographesProches() throws {
        let index = try TempIndex()
        // Le repli lit le vocabulaire de l'index : sans cette chauffe, aucune
        // variante n'existe (même geste que `NameChannelTests`).
        let store = GRDBStore()
        try store.open(at: index.databaseURL)
        try TrigramExpander(store: store).warm()
        store.releaseWriteLock()

        let auto = try payload(index, #"{"query":"electrolyze","limit":50}"#)
        XCTAssertEqual(auto["fuzzy_expanded"] as? Bool, true,
                       "en `auto`, la faute de frappe est rattrapée")
        XCTAssertGreaterThan((auto["hits"] as? [Any])?.count ?? 0, 0)
        let off = try payload(index,
            #"{"query":"electrolyze","limit":50,"fuzzy":"off"}"#)
        XCTAssertEqual((off["hits"] as? [Any])?.count, 0)
        XCTAssertEqual(off["fuzzy_expanded"] as? Bool, false)
    }

    // MARK: - `facet`

    func testUneFacetteCompteLesResultatsParDimension() throws {
        let index = try TempIndex()
        let payload = try payload(index,
            #"{"query":"electrolyse","limit":50,"facet":"ext"}"#)
        let facets = try XCTUnwrap(payload["facets"] as? [String: Any])
        XCTAssertEqual(facets["ext"] as? [String: Int], ["pdf": 6])
        // Sans paramètre, la clé est nulle — et jamais absente.
        let sans = try self.payload(index, #"{"query":"electrolyse"}"#)
        XCTAssertTrue(sans["facets"] is NSNull, "\(sans["facets"] ?? "absente")")
    }

    /// `modified_year` est le nom exposé : l'autre année — celle que le
    /// document PORTE — s'appelle `doc_year` et vient en premier dans
    /// l'énumération. Les confondre était le constat PM-25.
    func testLesDeuxAnneesSontDeuxFacettesDistinctes() throws {
        XCTAssertEqual(SearchTool.facetKey("modified_year"), .year)
        XCTAssertEqual(SearchTool.facetKey("doc_year"), .docYear)
        let index = try TempIndex()
        let payload = try payload(index,
            #"{"query":"electrolyse","limit":50,"facet":"modified_year"}"#)
        let facets = try XCTUnwrap(payload["facets"] as? [String: Any])
        XCTAssertEqual((facets["modified_year"] as? [String: Int])?.values.reduce(0, +), 6)
    }

    // MARK: - `compact`

    func testCompactSortLesCheminsDesHitsEtRegroupeParDocument() throws {
        let index = try TempIndex()
        let plein = try payload(index, #"{"query":"electrolyse","limit":10}"#)
        XCTAssertTrue((plein["documents"] as? [String: Any])?.isEmpty ?? false,
                      "hors compact, la clé est présente et vide")
        let compact = try payload(index,
            #"{"query":"electrolyse","limit":10,"compact":true}"#)
        let hits = try XCTUnwrap(compact["hits"] as? [[String: Any]])
        for key in ["path", "abs_path", "link", "folder", "ext"] {
            XCTAssertTrue(hits.allSatisfy { $0[key] == nil },
                          "\(key) reste dans un hit compact")
        }
        XCTAssertTrue(hits.allSatisfy { $0["snippet"] != nil && $0["doc_id"] != nil })

        let documents = try XCTUnwrap(compact["documents"] as? [String: Any])
        XCTAssertEqual(Set(documents.keys), ["1", "2"])
        let premier = try XCTUnwrap(documents["1"] as? [String: Any])
        XCTAssertEqual(premier["path"] as? String, "Users/essai/Livres/document-1.pdf")
        XCTAssertEqual(premier["link"] as? String, "fouine://open?doc=1&page=1")
        XCTAssertEqual(premier["n_pages"] as? Int, 3)
        XCTAssertEqual(premier["hits"] as? Int, 3, "trois hits viennent de ce document")
    }

    /// L'économie est la raison d'être du paramètre (PM-24 : 56 % d'une réponse
    /// de dix hits partait en chemins).
    func testCompactRaccourcitLaReponse() throws {
        let index = try TempIndex()
        let plein = try payload(index, #"{"query":"electrolyse","limit":10}"#)
        let compact = try payload(index,
            #"{"query":"electrolyse","limit":10,"compact":true}"#)
        XCTAssertLessThan(Budget.size(of: compact), Budget.size(of: plein))
    }

    // MARK: - `marks`

    func testLesMarqueursDExtraitSuiventLeParametre() throws {
        let index = try TempIndex()
        func snippet(_ arguments: String) throws -> String {
            let payload = try payload(index, arguments)
            return ((payload["hits"] as? [[String: Any]])?.first?["snippet"]
                as? String) ?? ""
        }
        XCTAssertTrue(try snippet(#"{"query":"electrolyse","limit":1}"#)
            .contains("«electrolyse»"))
        XCTAssertTrue(try snippet(#"{"query":"electrolyse","limit":1,"marks":"brackets"}"#)
            .contains("[electrolyse]"))
        XCTAssertTrue(try snippet(#"{"query":"electrolyse","limit":1,"marks":"asterisks"}"#)
            .contains("**electrolyse**"))
        let nu = try snippet(#"{"query":"electrolyse","limit":1,"marks":"none"}"#)
        XCTAssertFalse(nu.contains("«"), nu)
        XCTAssertTrue(nu.contains("electrolyse"), nu)
    }

    // MARK: - Le curseur couvre les nouveaux paramètres

    /// Un curseur pris sous `compact: true` ne peut pas servir à une recherche
    /// qui ne l'est pas : l'empreinte porte TOUS les arguments, défauts compris.
    func testLeCurseurRefuseUnAutreJeuDeParametres() throws {
        let index = try TempIndex()
        let compact = try payload(index,
            #"{"query":"electrolyse","limit":2,"compact":true}"#)
        let cursor = try XCTUnwrap(compact["next_cursor"] as? String)
        let object = try call(index,
            #"{"query":"electrolyse","limit":2,"cursor":"\#(cursor)"}"#)
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual((error["data"] as? [String: String])?["reason"],
                       "cursor does not match these arguments")
    }

    // MARK: - Le message d'une énumération (PM-08)

    /// `data.reason` portait la phrase utile et `message` disait « Invalid
    /// params » : beaucoup de clients ne rendent au modèle que le second.
    func testLeMessageDUneEnumerationDitSesValeurs() throws {
        let object = try call(try TempIndex(),
                              #"{"query":"electrolyse","mode":"semantic"}"#)
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["message"] as? String,
                       "Invalid params: fouine_search.mode must be one of "
                       + "auto, lexical, hybrid")
        XCTAssertEqual((error["data"] as? [String: String])?["reason"],
                       "fouine_search.mode must be one of auto, lexical, hybrid")
    }

    /// Toute énumération du schéma porte `"type": "string"` à côté de son
    /// `enum` : c'est ce qui manquait aux clients qui valident de leur côté.
    func testChaqueEnumerationDitSonType() throws {
        let tool = SearchTool(store: ReadOnlyStore(path: URL(fileURLWithPath: "/x")),
                              semantic: SemanticEngine(
                                store: ReadOnlyStore(path: URL(fileURLWithPath: "/x")),
                                modelDirectory: URL(fileURLWithPath: "/x")))
        let properties = try XCTUnwrap(
            tool.inputSchema["properties"] as? [String: [String: Any]])
        let enums = properties.filter { $0.value["enum"] != nil }
        XCTAssertEqual(Set(enums.keys), ["mode", "source", "fuzzy", "facet", "marks"])
        // `doc_year` en TÊTE, et le nom du cœur (`year`) n'est pas exposé :
        // l'année du fichier s'appelle `modified_year` pour le modèle.
        let facet = try XCTUnwrap(properties["facet"]?["enum"] as? [String])
        XCTAssertEqual(facet.first, "doc_year")
        XCTAssertFalse(facet.contains("year"))
        for (name, spec) in enums {
            XCTAssertEqual(spec["type"] as? String, "string", name)
        }
    }
}
