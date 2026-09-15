// OCRPriority.swift — la priorité de file OCR, une seule fois (SPEC §6.1).
// Propriété : A-Core, audit F4 / A9.
//
// Les trois pipelines portaient la MÊME règle recopiée, et elle commençait par
// `if rootLabel != "Livres" { return 0 }` : une chaîne de caractères prise dans
// l'arborescence personnelle de l'auteur. Depuis D1 (aucune racine implicite),
// AUCUNE base neuve n'a de racine nommée « Livres » — donc, chez un tiers,
// toute la file partait à 0 et la hiérarchie du §6.1 ne s'appliquait jamais :
// les 5 291 images des archives BD passaient devant les documents utiles.
//
// SENS DE `prio` — vérifié dans le schéma et dans la file, pas supposé :
//   · `Schema.swift` : `prio INTEGER NOT NULL, -- 0 = le plus urgent` ;
//   · `idx_ocr_prio ON ocr_queue(prio, attempts, doc_id, page)` ;
//   · `GRDBStore.nextOCRBatch` : `ORDER BY q.prio, q.attempts, q.doc_id, q.page`.
// Le tri est ASCENDANT : un petit nombre passe D'ABORD. 3 est donc bien le
// moins urgent, et inverser l'échelle ferait sortir les BD en tête.
//
// Ce qui reste du §6.1 après F4 : les critères INTRINSÈQUES au document, les
// seuls qui gardent un sens sur une machine inconnue.
//
//   prio 0  racine épinglée par l'utilisateur   (réglages, palier 2.3)
//   prio 1  moins de 100 pages                  (petits, gains visibles tôt)
//   prio 2  100 pages et plus                   (Clayden 1 570 p., Baudin 1 053 p.)
//   prio 3  archives BD cbz/cbr                 (5 291 images mesurées, ~2 h)
//
// LES PAGES DÉJÀ EN FILE (palier 2.3). L'en-tête précédent laissait ce point
// hors périmètre : « les pages déjà en file gardent la priorité qu'elles
// avaient […] le seul cas qui le justifierait vraiment (épingler une racine)
// n'existera qu'avec la fenêtre de réglages du palier 2.3, qui saura alors le
// faire dans le même geste ». C'est ce geste : `repriorize(store:root:pinned:)`.
// Il ne touche QUE les documents de la racine concernée qui ont encore des
// pages en file — quelques centaines, pas les 34 000 lignes de la table —, en
// une transaction sous le verrou d'écriture, et il recalcule la priorité avec
// la MÊME fonction que l'extraction (`forDocument`) : dépingler une racine ne
// remet pas les BD devant les livres.

import Foundation
import FouineCore

public enum OCRPriority {

    /// Le plus urgent. Réservé à une racine épinglée par l'utilisateur.
    public static let pinned = 0
    /// Le moins urgent : les archives d'images.
    public static let comicArchives = 3
    /// Seuil « petit document », repris du §6.1.
    public static let smallDocumentPages = 100

    /// Extensions traitées comme des archives d'images (§5.3).
    static let comicExtensions: Set<String> = ["cbz", "cbr"]

    /// La priorité d'un document, sur ses seules caractéristiques.
    ///
    /// - Parameter isPinnedRoot: la racine est épinglée par l'utilisateur.
    ///   L'appelant le dit ; aucune colonne ne le porte, parce qu'aucune
    ///   interface ne le règle encore.
    public static func forDocument(extension ext: String, pageCount: Int,
                                   isPinnedRoot: Bool = false) -> Int {
        if isPinnedRoot { return pinned }
        if comicExtensions.contains(ext.lowercased()) { return comicArchives }
        return pageCount < smallDocumentPages ? 1 : 2
    }

    /// Re-priorise les pages DÉJÀ en file d'une racine qu'on vient d'épingler
    /// (ou de dépingler). Rend le nombre de pages touchées.
    ///
    /// Épingler une racine sans toucher la file serait un réglage auquel
    /// personne ne croirait : sur la base de l'auteur, 34 000 pages attendent
    /// depuis des jours, et une racine épinglée dont RIEN ne bouge se lit comme
    /// une case sans effet. C'est le geste que l'en-tête de ce fichier annonçait.
    ///
    /// La priorité rendue à une racine dépinglée est RECALCULÉE, pas restaurée :
    /// on n'a jamais mémorisé l'ancienne, et `forDocument` la reconstruit
    /// exactement — c'est une fonction des seules caractéristiques du document.
    @discardableResult
    public static func repriorize(store: GRDBStore, rootID: Int64,
                                  pinned isPinned: Bool) throws -> Int {
        let documents = try store.queuedDocuments(underRoot: rootID)
        guard !documents.isEmpty else { return 0 }
        var priorities: [Int64: Int] = [:]
        for doc in documents {
            priorities[doc.id] = forDocument(extension: doc.ext,
                                             pageCount: doc.pageCount,
                                             isPinnedRoot: isPinned)
        }
        return try store.setOCRPriorities(priorities)
    }
}
