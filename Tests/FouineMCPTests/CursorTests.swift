// CursorTests.swift — budget et curseurs, avant qu'un outil s'en serve.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// AUCUN OUTIL DE LA PR 1 NE PAGINE. Ces mécaniques sont pourtant écrites et
// testées maintenant, et c'est délibéré : `fouine_search` et
// `fouine_list_documents` (PR 2) en dépendront tous les deux, et une pagination
// qu'on écrit en même temps que l'outil qui la consomme se conçoit toujours à
// la mesure de cet outil-là. Ici, elle est conçue toute seule — et le test qui
// compte est celui du curseur REPRIS D'UNE AUTRE REQUÊTE, la panne silencieuse
// que personne ne cherche.

import Foundation
import XCTest
import FouineMCPKit

final class CursorTests: XCTestCase {

    private let arguments: [String: Any] = [
        "query": "electrolyse", "limit": 10, "folder": "Livres",
    ]

    func testARoundTripKeepsTheOffset() throws {
        for offset in [0, 1, 42, 1_000_000] {
            let token = Cursor.encode(offset: offset, arguments: arguments)
            XCTAssertEqual(try Cursor.decode(token, arguments: arguments), offset)
        }
    }

    /// Le curseur est OPAQUE — « clients MUST treat cursors as opaque tokens ».
    /// base64url sans remplissage : ni `+`, ni `/`, ni `=`, donc rien qui
    /// demande un échappement dans une URL ou un journal.
    func testTheTokenIsURLSafeAndCarriesNothingReadable() {
        let token = Cursor.encode(offset: 7, arguments: arguments)
        XCTAssertFalse(token.contains("+"))
        XCTAssertFalse(token.contains("/"))
        XCTAssertFalse(token.contains("="))
        XCTAssertFalse(token.contains("electrolyse"),
                       "un curseur ne doit pas porter la requête en clair")
    }

    /// LE TEST DE CE FICHIER. Un curseur produit pour une requête, présenté avec
    /// une autre, est REFUSÉ. Sans cela, un client qui recycle un curseur
    /// obtiendrait la page 2 d'une recherche appliquée aux résultats d'une
    /// autre : des trous et des doublons, sans le moindre message.
    func testACursorFromAnotherRequestIsRefused() throws {
        let token = Cursor.encode(offset: 10, arguments: arguments)
        var other = arguments
        other["query"] = "enthalpie"

        XCTAssertThrowsError(try Cursor.decode(token, arguments: other)) { error in
            guard let failure = error as? Cursor.Failure else {
                return XCTFail("attendu Cursor.Failure, obtenu \(error)")
            }
            XCTAssertEqual(failure.description, "cursor does not match these arguments")
            XCTAssertEqual(failure.jsonRPCError.code, -32602)
        }
    }

    /// Un changement de FILTRE compte autant qu'un changement de requête : c'est
    /// exactement le cas où la pagination donnerait des résultats faux sans
    /// jamais paraître fausse.
    func testEveryArgumentEntersTheFingerprint() throws {
        let token = Cursor.encode(offset: 3, arguments: arguments)
        for (key, replacement) in [("limit", 20 as Any), ("folder", "Cours" as Any)] {
            var other = arguments
            other[key] = replacement
            XCTAssertThrowsError(try Cursor.decode(token, arguments: other),
                                 "changer \(key) doit invalider le curseur")
        }
    }

    /// Et `cursor` lui-même n'entre PAS dans son empreinte — sans quoi aucun
    /// curseur ne pourrait jamais être présenté une seconde fois.
    func testTheCursorArgumentIsExcludedFromItsOwnFingerprint() throws {
        var first = arguments
        first["cursor"] = "un-curseur-précédent"
        let token = Cursor.encode(offset: 20, arguments: first)

        var second = arguments
        second["cursor"] = token
        XCTAssertEqual(try Cursor.decode(token, arguments: second), 20)
    }

    /// L'ordre des clés n'est pas une information : l'empreinte est calculée sur
    /// un JSON à clés triées.
    func testTheFingerprintDoesNotDependOnKeyOrder() {
        let a: [String: Any] = ["query": "x", "limit": 5]
        let b: [String: Any] = ["limit": 5, "query": "x"]
        XCTAssertEqual(Cursor.fingerprint(of: a), Cursor.fingerprint(of: b))
    }

    func testMalformedTokensAreRefusedWithoutCrashing() {
        for token in ["", "pas-du-base64!!", "eyJvIjoxfQ", "////",
                      Cursor.base64URL(Data(#"{"v":99,"o":1,"f":"abc"}"#.utf8))] {
            XCTAssertThrowsError(try Cursor.decode(token, arguments: arguments),
                                 "token accepté à tort : \(token)")
        }
    }

    /// Un décalage négatif est refusé : un curseur fabriqué à la main ne doit
    /// pas pouvoir faire lire une requête SQL à l'envers.
    func testANegativeOffsetIsRefused() {
        let payload = Data(
            #"{"v":1,"o":-5,"f":"\#(Cursor.fingerprint(of: arguments))"}"#.utf8)
        XCTAssertThrowsError(
            try Cursor.decode(Cursor.base64URL(payload), arguments: arguments))
    }

    // MARK: - Budget

    /// Le budget tronque, et le DIT. Une troncature muette est la pire sortie
    /// possible pour un modèle : il la lit comme « il n'y a rien de plus ».
    func testTheBudgetTruncatesAndSaysSo() {
        let budget = Budget(maxCharacters: 100)
        let items = Array(repeating: 30, count: 10)
        let (kept, truncated) = budget.take(items) { $0 }
        XCTAssertEqual(kept.count, 3, "3 × 30 = 90 tient, 4 × 30 = 120 non")
        XCTAssertTrue(truncated)
    }

    func testWhatFitsIsNotFlaggedAsTruncated() {
        let budget = Budget(maxCharacters: 100)
        let (kept, truncated) = budget.take([10, 20, 30]) { $0 }
        XCTAssertEqual(kept.count, 3)
        XCTAssertFalse(truncated)
    }

    /// Le PREMIER élément passe toujours, même s'il dépasse à lui seul : rendre
    /// zéro résultat parce que le premier est trop long serait pire que de
    /// dépasser une fois — et `truncated` le signale.
    func testAnOversizedFirstItemStillComesBack() {
        let budget = Budget(maxCharacters: 100)
        let (kept, truncated) = budget.take([5_000, 10]) { $0 }
        XCTAssertEqual(kept, [5_000])
        XCTAssertTrue(truncated)
    }

    func testAnEmptyListIsNotTruncated() {
        let (kept, truncated) = Budget().take([Int]()) { $0 }
        XCTAssertTrue(kept.isEmpty)
        XCTAssertFalse(truncated)
    }
}
