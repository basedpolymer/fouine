// Budget.swift — plafond de caractères et curseurs opaques.
// SPDX-License-Identifier: MIT
//
// DEUX PROBLÈMES D'UN SERVEUR D'AGENT, et ils sont jumeaux.
//
//  1. La fenêtre de contexte. Un outil qui rend 40 000 caractères une fois est
//     supportable ; trois fois, la conversation est saturée et le modèle perd le
//     fil de ce qu'il cherchait. Le budget tronque, pose `truncated: true` et
//     rend un curseur — jamais une troncature muette, qu'un modèle interprète
//     comme « il n'y a rien de plus ».
//
//  2. Les curseurs volés. « Clients MUST treat cursors as opaque tokens » : ils
//     le font, mais rien ne les empêche de reprendre le curseur d'une AUTRE
//     requête. Sans garde-fou, le serveur rendrait la page 2 d'une recherche
//     appliquée aux résultats d'une autre — des trous et des doublons, muets.
//     Le curseur porte donc une empreinte des arguments qui l'ont produit, et un
//     curseur qui ne correspond pas est refusé en `-32602`.
//
// FORME DU CURSEUR : base64url, sans remplissage, de
// `{"f":"<24 hexa>","o":<décalage>,"v":1}` — clés triées, donc reproductible.
// L'empreinte est un SHA-256 TRONQUÉ à 12 octets des arguments hors `cursor`.
// Douze octets, et non trente-deux : il ne s'agit pas de résister à un
// adversaire — un client qui veut mentir peut fabriquer le curseur qu'il veut —
// mais d'attraper une reprise ACCIDENTELLE. 96 bits suffisent, et le jeton
// reste court dans les journaux.
//
// CryptoKit est un cadriciel du SYSTÈME : cette cible n'a toujours aucune
// dépendance SPM. C'est la seule concession à macOS de tout FouineMCPKit, et un
// portage la remplacerait par vingt lignes de SHA-256.

import Foundation
import CryptoKit

/// Le plafond d'une réponse, en caractères.
public struct Budget {

    /// ~24 000 caractères ≈ 8 000 jetons : de quoi enchaîner plusieurs appels
    /// sans saturer une fenêtre. C'est le plafond DUR ; les valeurs par défaut
    /// des outils visent bien plus bas (D2 § 5.5 : ~2 400 caractères pour une
    /// recherche ordinaire).
    public static let defaultMaxCharacters = 24_000

    /// PLAFOND DUR D'UNE RÉPONSE D'OUTIL, en caractères du JSON sérialisé —
    /// `structuredContent` compris, puisqu'un `CallToolResult` porte deux fois
    /// la charge utile (le bloc texte et l'objet structuré).
    ///
    /// 60 000 caractères ≈ 20 000 jetons. Ce plafond n'est pas un réglage de
    /// confort : c'est le garde-fou qui empêche une réponse pathologique de
    /// manger une fenêtre entière. Les valeurs par défaut des outils visent
    /// trente fois plus bas (10 hits × 240 caractères ≈ 2 400).
    ///
    /// Il s'applique au MESSAGE, donc à DEUX copies de la charge utile — voir
    /// `fitsResponse`. Le plus gros appel légitime, `fouine_read_page` avec
    /// `max_chars: 40000` et deux pages de contexte, produit ~17 500 caractères
    /// de charge utile : il passe entier. Une recherche de cinquante hits à
    /// huit cents caractères, elle, dépasse — et se raccourcit, ce qui est le
    /// comportement voulu pour un appel qui coûterait 17 000 jetons.
    ///
    /// Une réponse qui le dépasse est RACCOURCIE — les extraits d'abord, les
    /// éléments ensuite — et porte alors `truncated: true`. Jamais coupée au
    /// milieu de son JSON : ce qui sort est toujours un objet complet.
    public static let responseCharacters = 60_000

    /// Est-ce que cette charge utile tient dans une réponse d'outil ?
    ///
    /// FOIS DEUX. Un `CallToolResult` porte la charge utile deux fois : le bloc
    /// `content` texte, que lisent les clients qui ne connaissent pas la sortie
    /// structurée, et `structuredContent`, que valide `outputSchema`. Compter
    /// une seule copie — ce que faisait le code jusqu'au constat CM-09 —
    /// laissait passer 115 484 caractères sur le fil pour un plafond annoncé à
    /// 60 000, sans jamais poser `truncated`.
    public static func fitsResponse(_ payload: [String: Any]) -> Bool {
        size(of: payload) * 2 <= responseCharacters
    }

    /// Taille du JSON sérialisé d'une charge utile, en caractères. C'est la
    /// mesure exacte de ce qui partira sur le fil, pas une estimation.
    public static func size(of payload: [String: Any]) -> Int {
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]) else { return .max }
        return String(decoding: data, as: UTF8.self).count
    }

    public let maxCharacters: Int

    public init(maxCharacters: Int = Budget.defaultMaxCharacters) {
        self.maxCharacters = maxCharacters
    }

    /// Prend les éléments qui tiennent dans le budget.
    ///
    /// Le premier élément passe TOUJOURS, même s'il dépasse à lui seul : rendre
    /// zéro résultat parce que le premier est trop long serait pire que de
    /// dépasser une fois, et le `truncated` le dit.
    public func take<Element>(_ items: [Element],
                              cost: (Element) -> Int) -> (kept: [Element], truncated: Bool) {
        var kept: [Element] = []
        var total = 0
        for item in items {
            let size = cost(item)
            if !kept.isEmpty && total + size > maxCharacters {
                return (kept, true)
            }
            kept.append(item)
            total += size
        }
        return (kept, false)
    }
}

/// Curseur opaque de pagination.
public enum Cursor {

    public static let version = 1

    public enum Failure: Error, CustomStringConvertible {
        case malformed
        case wrongVersion(Int)
        case mismatch

        public var description: String {
            switch self {
            case .malformed:
                return "cursor is not a cursor produced by this server"
            case .wrongVersion(let v):
                return "cursor was produced by another version of this server (v\(v))"
            case .mismatch:
                return "cursor does not match these arguments"
            }
        }

        /// La forme JSON-RPC de ces trois cas : toujours `-32602`.
        public var jsonRPCError: JSONRPCError { .invalidParams(description) }
    }

    /// Empreinte des arguments, `cursor` exclu — c'est bien le POINT : le
    /// curseur ne peut pas faire partie de ce qui l'identifie.
    public static func fingerprint(of arguments: [String: Any]) -> String {
        var stable = arguments
        stable.removeValue(forKey: "cursor")
        let canonical = (try? JSONSerialization.data(
            withJSONObject: stable,
            options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let digest = SHA256.hash(data: canonical)
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    public static func encode(offset: Int, arguments: [String: Any]) -> String {
        let payload: [String: Any] = [
            "v": version, "o": offset, "f": fingerprint(of: arguments),
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return base64URL(data)
    }

    /// Rend le décalage porté par le curseur, ou lève.
    public static func decode(_ token: String, arguments: [String: Any]) throws -> Int {
        guard let data = decodeBase64URL(token),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any],
              let offset = (payload["o"] as? NSNumber)?.intValue,
              let stamp = payload["f"] as? String
        else { throw Failure.malformed }
        let carried = (payload["v"] as? NSNumber)?.intValue ?? 0
        guard carried == version else { throw Failure.wrongVersion(carried) }
        guard offset >= 0 else { throw Failure.malformed }
        guard stamp == fingerprint(of: arguments) else { throw Failure.mismatch }
        return offset
    }

    // MARK: - base64url sans remplissage (RFC 4648 § 5)

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decodeBase64URL(_ token: String) -> Data? {
        var text = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = text.count % 4
        if remainder != 0 { text += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: text)
    }
}
