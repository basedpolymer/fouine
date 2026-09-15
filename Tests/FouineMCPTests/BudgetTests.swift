// BudgetTests.swift — aucune réponse ne mange la fenêtre du modèle.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// LA SATURATION DE CONTEXTE EST UNE PANNE, et une panne particulièrement
// mauvaise : elle ne se voit nulle part. Le modèle reçoit sa réponse, elle est
// juste, et il a perdu le fil de ce qu'il cherchait. Trois affirmations sont
// donc vérifiées ici sur les OCTETS réellement rendus :
//
//   1. aucune réponse d'outil ne dépasse `Budget.responseCharacters` ;
//   2. quand elle a été raccourcie, elle porte `truncated: true` — jamais une
//      troncature muette, que le modèle lirait comme « il n'y a rien de plus » ;
//   3. ce qui sort reste un JSON COMPLET. On refabrique une charge utile plus
//      petite, on ne tronçonne pas une chaîne sérialisée.
//
// LE PLAFOND SE MESURE SUR LE MESSAGE, pas sur `structuredContent` (CM-09).
// Un `CallToolResult` porte la charge utile DEUX FOIS — le bloc texte et
// l'objet structuré —, ce que l'en-tête de `Budget` disait depuis toujours et
// que ni le code ni ce fichier ne faisaient : `fouine_list_documents` à 200
// rendait 115 484 caractères sur le fil, ≈ 29 000 jetons, pour un plafond
// annoncé à 60 000, et sans jamais poser `truncated`. Ce qui est compté ici est
// donc ce que le client reçoit VRAIMENT : la ligne JSON-RPC entière.

import Foundation
import XCTest
import FouineCore
import FouineMCP
import FouineMCPKit

final class BudgetTests: XCTestCase {

    /// La charge utile structurée d'une réponse, et la taille de la LIGNE
    /// entière — celle qui traverse le tuyau et entre dans la fenêtre du modèle.
    private func payload(_ data: Data) throws -> (json: [String: Any], size: Int) {
        let object = try JSONMatch.object(data)
        XCTAssertNil(object["error"], "réponse en erreur : \(object)")
        let structured = try XCTUnwrap(
            (object["result"] as? [String: Any])?["structuredContent"]
                as? [String: Any])
        return (structured, String(decoding: data, as: UTF8.self).count)
    }

    /// LE PIRE APPEL LÉGITIME : cinquante hits de huit cents caractères, le
    /// maximum que le schéma autorise. Il tient sur le fil, et rend bien ses
    /// cinquante pages — un agent cherche OÙ regarder : perdre des hits serait
    /// pire que perdre des extraits.
    func testTheLargestLegitimateSearchFitsOnTheWire() throws {
        let index = try TempIndex(documents: 10, pagesPerDocument: 10, pageChars: 3_000)
        let server = try index.makeServer()
        let response = try XCTUnwrap(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_search","arguments":{"query":"electrolyse","limit":50,"snippet_chars":800}}}"#.utf8)))
        let (json, size) = try payload(response)

        XCTAssertLessThanOrEqual(size, Budget.responseCharacters,
                                 "réponse de \(size) caractères")
        XCTAssertEqual((json["hits"] as? [[String: Any]])?.count, 50)
    }

    /// `fouine_list_documents` À 200 — le maximum du schéma, et l'appel qui
    /// coûtait 29 000 jetons sans le dire (CM-09). Sur le fil, désormais, sous
    /// le plafond ; et s'il a fallu raccourcir, la réponse le porte.
    func testTheLargestDocumentListingFitsOnTheWireAndSaysIfItWasShortened() throws {
        let index = try TempIndex(documents: 200, pagesPerDocument: 1)
        let server = try index.makeServer()
        let response = try XCTUnwrap(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_list_documents","arguments":{"state":"any","limit":200}}}"#.utf8)))
        let (json, size) = try payload(response)

        XCTAssertLessThanOrEqual(size, Budget.responseCharacters,
                                 "réponse de \(size) caractères")
        let listed = (json["documents"] as? [[String: Any]])?.count ?? 0
        if listed < 200 {
            XCTAssertEqual(json["truncated"] as? Bool, true,
                           "\(listed) documents rendus sur 200, sans le dire")
            XCTAssertNotNil(json["next_cursor"] as? String,
                            "raccourcie sans curseur : le reste serait inatteignable")
        }
    }

    /// Une page de 40 000 caractères avec deux pages de contexte de chaque côté
    /// — cinq tranches de 40 000, soit 200 000 caractères demandés. Le plafond
    /// tient, et la réponse le DIT.
    func testAHugePageWithContextIsShortenedAndSaysSo() throws {
        let index = try TempIndex(documents: 1, pagesPerDocument: 5, pageChars: 45_000)
        let server = try index.makeServer()
        let response = try XCTUnwrap(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_read_page","arguments":{"doc_id":1,"page":3,"max_chars":40000,"context_pages":2}}}"#.utf8)))
        let (json, size) = try payload(response)

        XCTAssertLessThanOrEqual(size, Budget.responseCharacters,
                                 "réponse de \(size) caractères")
        XCTAssertEqual(json["truncated"] as? Bool, true,
                       "raccourcie sans le dire : le modèle croirait avoir tout lu")
        // Et ce qui reste est LISIBLE : le texte de la page demandée n'a pas été
        // sacrifié en premier, et il reste du contexte.
        XCTAssertGreaterThan((json["text"] as? String)?.count ?? 0, 1_000)
        XCTAssertFalse(((json["context"] as? [Any]) ?? []).isEmpty,
                       "les extraits se raccourcissent AVANT que des pages tombent")
    }

    /// Le budget sacrifie les EXTRAITS avant les ÉLÉMENTS : dix hits courts
    /// valent mieux que trois hits longs, parce qu'un agent cherche où regarder,
    /// pas à lire.
    func testExcerptsAreSacrificedBeforeHits() throws {
        let index = try TempIndex(documents: 5, pagesPerDocument: 10, pageChars: 5_000)
        let server = try index.makeServer()
        let response = try XCTUnwrap(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_read_page","arguments":{"doc_id":1,"page":5,"max_chars":40000,"context_pages":2}}}"#.utf8)))
        let (json, _) = try payload(response)
        XCTAssertEqual((json["context"] as? [Any])?.count, 4,
                       "les quatre pages de contexte survivent, raccourcies")
    }

    /// Quel que soit l'outil et quels que soient les arguments extrêmes, la
    /// réponse tient. C'est le filet : un outil ajouté demain qui oublierait le
    /// budget ferait rougir ce test-ci, pas la fenêtre d'un utilisateur.
    func testNoToolEverExceedsTheCeiling() throws {
        let index = try TempIndex(documents: 20, pagesPerDocument: 20,
                                  vectorisedPages: 40, pageChars: 6_000,
                                  failedDocuments: 5, skippedDocuments: 5)
        let server = try index.makeServer()
        let calls = [
            #"{"name":"fouine_status","arguments":{"include_agent":false}}"#,
            #"{"name":"fouine_search","arguments":{"query":"electrolyse","limit":50,"snippet_chars":800}}"#,
            #"{"name":"fouine_search","arguments":{"query":"enthalpie","mode":"hybrid","limit":50,"snippet_chars":800}}"#,
            #"{"name":"fouine_read_page","arguments":{"doc_id":1,"page":10,"max_chars":40000,"context_pages":2}}"#,
            #"{"name":"fouine_similar_pages","arguments":{"doc_id":1,"page":1,"limit":50,"preview_chars":600,"exclude_same_document":false}}"#,
            #"{"name":"fouine_list_documents","arguments":{"state":"any","limit":200}}"#,
        ]
        for (offset, call) in calls.enumerated() {
            let response = try XCTUnwrap(server.handle(Data(
                #"{"jsonrpc":"2.0","id":\#(offset),"method":"tools/call","params":\#(call)}"#.utf8)))
            let (json, size) = try payload(response)
            XCTAssertLessThanOrEqual(size, Budget.responseCharacters,
                                     "\(call) rend \(size) caractères")
            // Et la ligne entière reste du JSON valide — c'est ce que la
            // troncature naïve (couper la chaîne) casserait en premier.
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: response))
            _ = json
        }
    }

    /// `truncated` n'apparaît PAS quand rien n'a été raccourci. Un drapeau
    /// toujours présent à `false` serait du bruit ; un drapeau toujours présent
    /// à `true` serait un mensonge.
    func testTruncatedIsAbsentWhenNothingWasCut() throws {
        let index = try TempIndex()
        let server = try index.makeServer()
        let response = try XCTUnwrap(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_search","arguments":{"query":"electrolyse"}}}"#.utf8)))
        XCTAssertNil(try payload(response).json["truncated"])
    }
}
