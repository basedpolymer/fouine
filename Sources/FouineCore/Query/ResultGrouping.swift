// ResultGrouping.swift — agrégation page -> document (SPEC §5.1, D-R5).
// Propriété : A-Core.
//
// « Regrouper par doc_id, score du document = meilleure page + étendue
//   (score_doc = r_meilleure_page × (1 + 0,15 · log2(1 + pages_chargées))),
//   exposer aussi le nombre de pages chargées et la première page. »
// Les hits restent des pages : l'agrégat ne sert qu'au tri de présentation.
// bm25 est NÉGATIF, plus il est bas meilleur il est : multiplier par > 1 améliore
// le score (le rend plus négatif), et le tri des groupes est croissant.
//
// NOTE (audit A12) : `pageCount` représente les pages chargées dans le lot reçu,
// non les pages touchées dans tout l'ouvrage. Le vrai total par document
// n'est disponible que si `matchedPageCounts` a été expressément interrogé.

import Foundation

public struct DocGroup: Sendable {
    public let docID: Int64
    public let path: String
    public let score: Double
    /// Pages de ce document PRÉSENTES DANS LE JEU REÇU — pas les pages touchées
    /// par la requête dans tout l'ouvrage (audit A12).
    ///
    /// La différence n'est pas théorique : une recherche rend une tranche de
    /// 200 pages (50 pour la CLI), toutes réparties entre quelques documents.
    /// Un ouvrage de 400 pages toutes trouvées comptait donc « 200 ». Le vrai
    /// total, quand un appelant a payé le comptage
    /// (`GRDBStore.matchedPageCounts`), arrive dans `matchedPageCount`.
    public let pageCount: Int
    /// Pages touchées par la requête dans TOUT le document, si le compte a été
    /// demandé ; `nil` sinon — et l'affichage doit alors dire « chargées ».
    public let matchedPageCount: Int?
    public let firstPage: Int
    public let hits: [Hit]
    public init(docID: Int64, path: String, score: Double, pageCount: Int,
                firstPage: Int, hits: [Hit], matchedPageCount: Int? = nil) {
        self.docID = docID
        self.path = path
        self.score = score
        self.pageCount = pageCount
        self.matchedPageCount = matchedPageCount
        self.firstPage = firstPage
        self.hits = hits
    }
}

public enum ResultGrouping {
    /// Facteur d'étendue dans l'agrégat document (D-R5) : 0,15 · log2(1 + n).
    public static let spreadFactor = 0.15

    public static func group(_ hits: [Hit]) -> [DocGroup] {
        var order: [Int64] = []
        var byDoc: [Int64: [Hit]] = [:]
        for hit in hits {
            if byDoc[hit.docID] == nil { order.append(hit.docID) }
            byDoc[hit.docID, default: []].append(hit)
        }
        let groups = order.map { docID -> DocGroup in
            let pages = byDoc[docID] ?? []
            let bestScore = pages.map(\.score).min() ?? 0
            // D-R5 : r_meilleure_page × (1 + 0,15 · log2(1 + pages_chargées))
            // bm25 est négatif : multiplier par > 1 améliore (rend plus négatif).
            let score = bestScore * (1.0 + spreadFactor * log2(1.0 + Double(pages.count)))
            return DocGroup(docID: docID, path: pages.first?.path ?? "",
                            score: score, pageCount: pages.count,
                            firstPage: pages.map(\.page).min() ?? 0,
                            hits: pages.sorted { $0.page < $1.page })
        }
        return groups.sorted { a, b in
            if abs(a.score - b.score) > 1e-9 {
                return a.score < b.score
            }
            // DÉPARTAGE PAR docID (audit A1m-12). `Array.sorted(by:)` n'est pas
            // garanti stable en Swift : rendre `false` sur égalité laissait
            // l'ordre de deux documents ex æquo à l'implémentation du tri, donc
            // variable d'une exécution à l'autre — et, plus gênant, d'une page
            // de pagination à la suivante, où le même document pouvait
            // reparaître ou disparaître. `RRF.fuse` tranche déjà de cette
            // façon ; le classement lexical le fait maintenant aussi.
            return a.docID < b.docID
        }
    }
}
