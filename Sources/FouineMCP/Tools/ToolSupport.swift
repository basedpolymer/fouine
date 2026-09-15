// ToolSupport.swift — ce que les quatre outils partagent.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// Quatre outils, une seule façon de dire les mêmes choses. Ce fichier existe
// pour que `path`, `abs_path`, `folder`, `ext`, `source`, `engine` et les
// arrondis n'aient qu'UNE définition : deux outils qui décrivent la même page
// autrement, c'est un modèle qui croit avoir deux pages.
//
// LE CAS QUI JUSTIFIE `abs_path`. `docs.rel_path` est relatif au VOLUME
// (`Users/mathis/Livres/…`, sans `/` initial) : il ne veut rien dire pour un
// client, qui ne connaît ni le volume ni son point de montage. `VolumeResolver`
// le résout — et rend `nil` quand le volume est démonté, ce qui est un état
// NORMAL (un disque externe débranché) et non une panne : les hits restent
// rendus, `abs_path` est nul, et `fouine_status` dit quelle racine manque.

import Foundation
import FouineCore
import FouineMCPKit

enum ToolSupport {

    // MARK: - Chemins

    /// Chemin absolu d'un document, ou `nil` si son volume n'est pas monté.
    ///
    /// La résolution passe par le cache de `VolumeResolver` ; elle n'ouvre ni
    /// ne lit le fichier. Un document dont le fichier a disparu du disque garde
    /// donc un `abs_path` — c'est voulu : le chemin est celui que Fouine a
    /// indexé, et le dire permet à l'utilisateur de comprendre qu'il a bougé.
    static func absolutePath(volUUID: String, relPath: String) -> String? {
        (try? VolumeResolver.absolutePath(volUUID: volUUID, relPath: relPath))?.path
    }

    /// Les champs communs à toute page rendue : `path`, `abs_path`, `folder`,
    /// `ext`. `nil` quand le document a disparu de `docs` entre la recherche et
    /// l'habillage (une passe d'indexation concurrente peut le supprimer).
    static func documentFields(_ row: DocRow?) -> [String: Any] {
        guard let row else { return ["abs_path": NSNull()] }
        let record = row.record
        return [
            "path": record.relPath,
            "abs_path": absolutePath(volUUID: record.volUUID,
                                     relPath: record.relPath).map { $0 as Any }
                ?? NSNull(),
            "folder": record.topFolder,
            "ext": record.ext,
        ]
    }

    /// Les champs communs, PLUS le lien `fouine://` de la page (lot INT-L1).
    ///
    /// Le lien est ce qui permet à un assistant de CITER : « <nom du fichier>,
    /// page N » suivi de cette adresse, et le lecteur rouvre Fouine exactement
    /// là. Sans lui, la réponse dit où regarder mais n'y ramène pas — il
    /// faudrait retrouver la page à la main.
    ///
    /// `abs_path` est relu de `documentFields` plutôt que recalculé :
    /// `VolumeResolver.absolutePath` énumère les volumes montés à chaque
    /// appel, et le refaire par hit doublerait ce coût pour rien.
    ///
    /// `page` nulle = le lien du DOCUMENT, sans page (`fouine_list_documents`).
    ///
    /// `time` (lot MC2, PM-22) : le moment de la page dans un enregistrement,
    /// en secondes. `DeepLink` sait le porter depuis le lot PV1 et AUCUNE
    /// surface ne lui en donnait — « page 1 » d'une vidéo de deux heures
    /// rouvrait Fouine au début, ce qui ne cite rien.
    static func pageFields(_ row: DocRow?, docID: Int64, page: Int?,
                           time: Int? = nil) -> [String: Any] {
        var fields = documentFields(row)
        fields["link"] = link(absolutePath: fields["abs_path"] as? String,
                              docID: docID, page: page, time: time)
        return fields
    }

    /// Le lien `fouine://` d'une page. Le CHOIX de la forme — chemin quand le
    /// volume est monté, `doc` sinon — est celui de `DeepLink.link`, point
    /// unique du dépôt : les trois surfaces qui émettent un lien doivent en
    /// émettre le même.
    static func link(absolutePath: String?, docID: Int64, page: Int?,
                     time: Int? = nil) -> String {
        DeepLink.link(absolutePath: absolutePath, docID: docID,
                      page: page, time: time).absoluteString
    }

    // MARK: - Nombres

    /// Un nombre à `places` décimales, LISIBLE.
    ///
    /// `JSONSerialization` sérialise un `Double` sur dix-sept chiffres
    /// significatifs dès que la valeur n'est pas exactement représentable en
    /// binaire : 16,63 y sort en `16.629999999999999`. Sur un serveur d'agent,
    /// le modèle recopie ce nombre tel quel dans sa phrase à l'utilisateur.
    /// `NSDecimalNumber` construit depuis le texte formaté sort par sa
    /// représentation décimale. Même remède que `StatusTool.percentage`.
    static func decimal(_ value: Double, places: Int = 2) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.\(places)f", value))
    }

    /// Pourcentage de couverture sémantique. Passe par le POINT UNIQUE des
    /// pages vectorisées (`ReadOnlyStore.vectorisedPageCount`).
    static func coveragePercentage(vectorisedPages: Int,
                                   indexedPages: Int) -> NSDecimalNumber {
        decimal(indexedPages > 0
                ? Double(vectorisedPages) * 100 / Double(indexedPages) : 0)
    }

    // MARK: - Étiquettes

    static func source(_ value: PageSource) -> String {
        GRDBStore.sourceLabel(value.rawValue)
    }

    static func engine(_ value: OCREngineID) -> String {
        GRDBStore.engineLabel(value)
    }

    /// `docs.state` en un mot ANGLAIS, aligné sur l'énumération `state` de
    /// `fouine_list_documents` : c'est le même vocabulaire à l'entrée et à la
    /// sortie, sans quoi un client ne peut pas relancer la requête qui lui
    /// rendrait la ligne qu'il vient de lire.
    static func state(_ value: DocState) -> String {
        switch value {
        case .discovered: return "pending"
        case .extracted:  return "indexed"
        case .failed:     return "failed"
        case .skipped:    return "skipped"
        }
    }

    static func states(for name: String) -> [DocState]? {
        switch name {
        case "indexed": return [.extracted]
        case "failed":  return [.failed]
        case "skipped": return [.skipped]
        case "pending": return [.discovered]
        default:        return nil          // "any"
        }
    }

    // MARK: - Arguments

    static func int(_ arguments: [String: Any], _ key: String, _ fallback: Int) -> Int {
        (arguments[key] as? NSNumber)?.intValue ?? fallback
    }

    static func double(_ arguments: [String: Any], _ key: String,
                       _ fallback: Double) -> Double {
        (arguments[key] as? NSNumber)?.doubleValue ?? fallback
    }

    static func bool(_ arguments: [String: Any], _ key: String, _ fallback: Bool) -> Bool {
        (arguments[key] as? NSNumber)?.boolValue ?? fallback
    }

    static func string(_ arguments: [String: Any], _ key: String) -> String? {
        guard let value = arguments[key] as? String,
              !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    static func int64s(_ arguments: [String: Any], _ key: String) -> [Int64] {
        (arguments[key] as? [Any])?.compactMap { ($0 as? NSNumber)?.int64Value } ?? []
    }

    /// Le décalage porté par un curseur, ou 0. Un curseur d'une AUTRE requête
    /// lève une `-32602` : c'est tout l'intérêt de l'empreinte (voir `Cursor`).
    static func offset(from arguments: [String: Any]) throws -> Int {
        guard let token = arguments["cursor"] as? String, !token.isEmpty else {
            return 0
        }
        do { return try Cursor.decode(token, arguments: arguments) }
        catch let failure as Cursor.Failure { throw failure.jsonRPCError }
    }

    /// Une page hors de la plage du rowid structuré ferait CASSER le programme
    /// (`Schema.ftsRowID` a une `precondition`, et c'est délibéré : rendre un
    /// rowid qui appartient à un autre document est pire). Les schémas d'entrée
    /// bornent déjà `page`, mais un seul chemin qui l'oublierait suffirait.
    static func rowid(docID: Int64, page: Int) -> Int64? {
        guard docID >= 0, page >= 0, page <= Schema.maxPage else { return nil }
        return Schema.ftsRowID(docID: docID, page: page)
    }
}

// MARK: - Plafond de réponse

/// Ce qui garantit qu'aucune réponse ne dépasse `Budget.responseCharacters`.
///
/// L'ORDRE DES SACRIFICES EST LE POINT. On raccourcit d'abord les EXTRAITS
/// (garder dix hits courts vaut mieux que trois hits longs : un agent cherche
/// où regarder, pas à lire), puis, seulement si cela ne suffit pas, on retire
/// des éléments. Dans les deux cas la réponse porte `truncated: true` et,
/// quand l'outil pagine, un `next_cursor` : une troncature MUETTE est la pire
/// sortie possible pour un modèle, qui la lit comme « il n'y a rien de plus ».
///
/// La charge utile n'est JAMAIS coupée au milieu de son JSON : on refabrique
/// une charge utile complète et plus petite, on ne tronçonne pas une chaîne
/// sérialisée.
enum ToolBudget {

    /// Refabrique la charge utile jusqu'à ce qu'elle tienne.
    ///
    /// - Parameters:
    ///   - textChars: longueur d'extrait demandée par l'appelant.
    ///   - count: nombre d'éléments à rendre.
    ///   - render: fabrique la charge utile pour un couple (extrait, nombre).
    /// - Returns: la charge utile retenue, et si elle a été raccourcie.
    static func fit(textChars: Int, count: Int,
                    render: (_ textChars: Int, _ count: Int) -> [String: Any])
        -> (payload: [String: Any], truncated: Bool) {
        var attempts: [(Int, Int)] = [(textChars, count)]
        // 1. Les extraits, par moitiés, jusqu'au minimum lisible.
        var chars = textChars
        while chars > 80 {
            chars = max(80, chars / 2)
            attempts.append((chars, count))
        }
        // 2. Puis les éléments, par moitiés, jusqu'à un seul.
        var kept = count
        while kept > 1 {
            kept = max(1, kept / 2)
            attempts.append((chars, kept))
        }

        var last: [String: Any] = [:]
        for (index, attempt) in attempts.enumerated() {
            let payload = render(attempt.0, attempt.1)
            last = payload
            // `fitsResponse` et non `size(of:) <= responseCharacters` : le
            // plafond porte sur le MESSAGE, qui porte la charge utile deux fois
            // (CM-09). C'est la seule ligne du correctif.
            if Budget.fitsResponse(payload) {
                return (payload, index > 0)
            }
        }
        // Un seul élément qui dépasse encore : on le rend quand même, comme
        // `Budget.take` rend toujours son premier élément. Rendre une réponse
        // vide serait pire, et `truncated` le dit.
        return (last, true)
    }
}
