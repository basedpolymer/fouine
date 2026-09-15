// PinnedRootTests.swift — la racine épinglée, de bout en bout (U2, F4).
// Propriété : A-Core.
//
// `OCRPriority.forDocument` portait `isPinnedRoot` depuis F4, mais AUCUN
// appelant ne pouvait le renseigner : ni colonne, ni réglage, ni interface. Ces
// cas vérifient les deux moitiés du geste que le palier 2.3 ajoute :
//
//   1. une racine épinglée dans `settings` met les pages NOUVELLEMENT mises en
//      file à la priorité 0 ;
//   2. épingler après coup re-priorise les pages DÉJÀ en file — sans quoi la
//      case à cocher serait sans effet visible avant la prochaine extraction,
//      c'est-à-dire jamais pour un corpus stable.

import Foundation
import XCTest
import FouineCore
@testable import FouineIndex

final class PinnedRootTests: XCTestCase {

    /// Met des pages en file pour un document, comme le ferait une extraction.
    ///
    /// Le `volUUID` est celui de la RACINE, et non un identifiant inventé : la
    /// re-priorisation désigne les documents par `vol_uuid` + préfixe de
    /// `rel_path` (`GRDBStore.underRootClause`), exactement comme le retrait
    /// d'une racine. Un faux UUID ferait passer le test à côté de son sujet.
    private func enqueue(_ store: GRDBStore, volUUID: String, relPath: String,
                         ext: String, pages: Int, pageCount: Int) throws -> Int64 {
        let id = try store.upsertDoc(DocRecord(
            volUUID: volUUID, relPath: relPath, ext: ext, topFolder: "Jetable",
            size: 1_000, mtime: 1_700_000_000, nPages: pageCount))
        try store.setPageCount(id, pageCount)
        try store.enqueueOCR(
            docID: id, pages: Array(1...pages),
            priority: OCRPriority.forDocument(extension: ext, pageCount: pageCount))
        return id
    }

    /// Les priorités des pages d'un document, par l'API PUBLIQUE de la file :
    /// `pendingOCRPages` est ce que lit `fouine ocr export --pending`, et c'est
    /// donc exactement ce qu'un utilisateur peut vérifier lui-même.
    private func priorities(_ store: GRDBStore, _ docID: Int64) throws -> [Int] {
        try store.pendingOCRPages(limit: 1_000)
            .filter { $0.docID == docID }
            .sorted { $0.page < $1.page }
            .map(\.prio)
    }

    // MARK: - 1 · La passe applique le réglage

    func testIndexPassUsesTheSettingsPinnedRoots() throws {
        let scratch = try IndexScratch("epinglee", documents: 0)
        // Un `.txt` n'entre jamais en file OCR : il faut un document dont
        // l'extraction produise des candidats. On court-circuite donc la passe
        // pour la PRIORITÉ, et on éprouve la LECTURE du réglage par la passe.
        let settings = Settings(store: scratch.store, ttl: 0, environment: [:])
        try settings.set(SettingKeys.pinnedRoots.key,
                         String(scratch.rootRecord.id))
        scratch.store.releaseWriteLock()

        let snapshot = SettingsSnapshot(rows: try scratch.store.settingsRows(),
                                        environment: [:])
        XCTAssertEqual(snapshot.pinnedRoots, [scratch.rootRecord.id])
        XCTAssertEqual(
            OCRPriority.forDocument(
                extension: "pdf", pageCount: 1_570,
                isPinnedRoot: snapshot.pinnedRoots.contains(scratch.rootRecord.id)),
            OCRPriority.pinned)
    }

    /// La passe LIT bien la table (et non un `[:]` par défaut) : sans cette
    /// vérification, `settingsRows()` pourrait retomber sur l'implémentation par
    /// défaut du protocole et personne ne s'en apercevrait.
    func testIndexPassStoreExposesTheSettingsTable() throws {
        let scratch = try IndexScratch("reglages-passe", documents: 1)
        let settings = Settings(store: scratch.store, ttl: 0, environment: [:])
        try settings.set(SettingKeys.pinnedRoots.key, "7")
        scratch.store.releaseWriteLock()

        let store: any IndexPassStore = scratch.store
        XCTAssertEqual(try store.settingsRows()["roots.pinned"], "7")
    }

    // MARK: - 2 · Re-priorisation des pages déjà en file

    func testPinningRepriorizesPagesAlreadyQueued() throws {
        let scratch = try IndexScratch("repriorisation", documents: 0)
        let store = scratch.store
        let relPrefix = scratch.rootRecord.relPath

        let volume = scratch.rootRecord.volUUID
        let small = try enqueue(store, volUUID: volume,
                                relPath: relPrefix + "/petit.pdf",
                                ext: "pdf", pages: 3, pageCount: 12)
        let big = try enqueue(store, volUUID: volume,
                              relPath: relPrefix + "/gros.pdf",
                              ext: "pdf", pages: 2, pageCount: 1_570)
        let comic = try enqueue(store, volUUID: volume,
                                relPath: relPrefix + "/bd.cbz",
                                ext: "cbz", pages: 4, pageCount: 900)
        store.releaseWriteLock()

        // Départ : la hiérarchie intrinsèque du §6.1.
        XCTAssertEqual(try priorities(store, small), [1, 1, 1])
        XCTAssertEqual(try priorities(store, big), [2, 2])
        XCTAssertEqual(try priorities(store, comic), [3, 3, 3, 3])

        // Épinglage : TOUTES les pages de la racine passent en tête.
        let touched = try OCRPriority.repriorize(
            store: store, rootID: scratch.rootRecord.id, pinned: true)
        store.releaseWriteLock()
        XCTAssertEqual(touched, 9, "les 9 pages en file doivent être touchées")
        XCTAssertEqual(try priorities(store, small), [0, 0, 0])
        XCTAssertEqual(try priorities(store, big), [0, 0])
        XCTAssertEqual(try priorities(store, comic), [0, 0, 0, 0])

        // Dépinglage : la priorité est RECALCULÉE, pas restaurée d'un souvenir
        // qu'on n'a jamais gardé — et elle retrouve exactement l'état initial.
        let restored = try OCRPriority.repriorize(
            store: store, rootID: scratch.rootRecord.id, pinned: false)
        store.releaseWriteLock()
        XCTAssertEqual(restored, 9)
        XCTAssertEqual(try priorities(store, small), [1, 1, 1])
        XCTAssertEqual(try priorities(store, big), [2, 2])
        XCTAssertEqual(try priorities(store, comic), [3, 3, 3, 3],
                       "dépingler ne doit pas remettre les BD devant les livres")
    }

    /// La file est servie par `ORDER BY q.prio` ASCENDANT : après épinglage,
    /// c'est bien une page de la racine épinglée qui sort en premier.
    func testPinnedPagesComeOutOfTheQueueFirst() throws {
        let scratch = try IndexScratch("ordre", documents: 0)
        let store = scratch.store
        let comic = try enqueue(store, volUUID: scratch.rootRecord.volUUID,
                                relPath: scratch.rootRecord.relPath + "/bd.cbz",
                                ext: "cbz", pages: 2, pageCount: 900)
        store.releaseWriteLock()

        XCTAssertEqual(try priorities(store, comic), [3, 3])
        _ = try OCRPriority.repriorize(store: store, rootID: scratch.rootRecord.id,
                                       pinned: true)
        store.releaseWriteLock()
        // `pendingOCRPages` trie exactement comme `nextOCRBatch`
        // (`ORDER BY q.prio, q.attempts, q.doc_id, q.page`).
        let first = try store.pendingOCRPages(limit: 1).first
        XCTAssertEqual(first?.prio, OCRPriority.pinned)
    }

    /// Une racine sans page en file ne coûte rien et ne touche rien : la
    /// fenêtre de réglages appelle ce chemin à chaque case cochée.
    func testRepriorizingAnEmptyQueueIsANoOp() throws {
        let scratch = try IndexScratch("vide", documents: 0)
        XCTAssertEqual(try OCRPriority.repriorize(
            store: scratch.store, rootID: scratch.rootRecord.id, pinned: true), 0)
    }
}
