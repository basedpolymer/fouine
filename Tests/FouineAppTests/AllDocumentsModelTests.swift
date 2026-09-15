// AllDocumentsModelTests.swift — « Tous vos documents » (lot BR1, PR-06).
// Propriété : A-App.
//
// Ce qui se teste ici est ce qui DÉCIDE : la traduction des filtres de la
// fenêtre en filtre du cœur, la pagination, les trois états, et le geste du
// pied de la carte « Index ». La vue, elle, ne se vérifie qu'à l'œil.

import XCTest
import FouineCore
@testable import FouineApp

@MainActor
final class AllDocumentsQueryTests: XCTestCase {

    /// Un filtre de nom VIDE ne doit pas descendre dans le SQL : `pathContains:
    /// ""` deviendrait `rel_path LIKE '%%'`, un balayage complet de `docs` pour
    /// ne rien filtrer.
    func testAnEmptyNameFilterIsNotAFilter() {
        XCTAssertNil(AllDocumentsQuery().filter.pathContains)
        XCTAssertNil(AllDocumentsQuery(nameFilter: "   ").filter.pathContains)
        XCTAssertEqual(AllDocumentsQuery(nameFilter: "  IP2022 ").filter.pathContains,
                       "IP2022", "les espaces de saisie sont retirés")
    }

    /// Aucun filtre d'état : la fenêtre répond « ce que Fouine connaît », ce qui
    /// inclut les documents qu'il n'a pas su lire — les cacher recréerait le
    /// trou que l'audit a relevé.
    func testEveryStateIsListed() {
        XCTAssertNil(AllDocumentsQuery().filter.states)
    }

    /// « Nom » passe par l'ordre `path` du cœur : `rel_path` finit par le nom du
    /// fichier, et trier sur le chemin garde ensemble les documents d'un même
    /// dossier.
    func testTheThreeOrdersMapToTheCore() {
        XCTAssertEqual(AllDocumentsOrder.recent.value, .recent)
        XCTAssertEqual(AllDocumentsOrder.name.value, .path)
        XCTAssertEqual(AllDocumentsOrder.pages.value, .pages)
        for order in AllDocumentsOrder.allCases {
            XCTAssertFalse(order.label.isEmpty)
        }
    }

    /// Le dossier et le type se recopient tels quels ; « Tous » est `nil`, pas
    /// une chaîne vide.
    func testFolderAndTypePassThrough() {
        let query = AllDocumentsQuery(folder: "Livres", ext: "pdf")
        XCTAssertEqual(query.filter.folder, "Livres")
        XCTAssertEqual(query.filter.ext, "pdf")
        XCTAssertNil(AllDocumentsQuery().filter.folder)
        XCTAssertNil(AllDocumentsQuery().filter.ext)
    }
}

@MainActor
final class DocumentCountAffordanceTests: XCTestCase {

    /// Tant que les statistiques n'ont pas répondu, on ne prétend pas compter et
    /// il n'y a rien à ouvrir.
    func testNoStatisticsMeansNoGesture() {
        let affordance = DocumentCountAffordance.decide(documents: nil, pages: nil)
        XCTAssertEqual(affordance, .unavailable)
        XCTAssertFalse(affordance.isGesture)
        XCTAssertNil(affordance.help)
        XCTAssertFalse(affordance.label.isEmpty)
    }

    /// Un index vide : ouvrir une liste de zéro ligne n'apprendrait rien.
    func testAnEmptyIndexOffersNoGesture() {
        let affordance = DocumentCountAffordance.decide(documents: 0, pages: 0)
        XCTAssertEqual(affordance, .empty)
        XCTAssertFalse(affordance.isGesture)
    }

    /// Le cas normal : le compte devient le geste, et il dit EXACTEMENT ce qu'il
    /// disait avant de devenir cliquable (les deux nombres, groupés).
    func testTheCountBecomesTheGesture() {
        let affordance = DocumentCountAffordance.decide(documents: 1_527,
                                                       pages: 408_951)
        XCTAssertEqual(affordance, .gesture(documents: 1_527, pages: 408_951))
        XCTAssertTrue(affordance.isGesture)
        XCTAssertNotNil(affordance.help)
        XCTAssertTrue(affordance.label.contains("documents"), affordance.label)
        XCTAssertTrue(affordance.label.contains("pages"), affordance.label)
        // VoiceOver annonce le NOM du geste, pas deux nombres : les comptes sont
        // rendus en valeur par la carte (BU-15).
        XCTAssertFalse(affordance.accessibilityLabel.contains("1"),
                       affordance.accessibilityLabel)
    }
}

@MainActor
final class AllDocumentsModelTests: XCTestCase {

    /// Trois documents semés : la fenêtre les rend tous, avec leur compte, dans
    /// l'ordre demandé — et le plus récemment modifié d'abord par défaut.
    func testModelListsEverythingMostRecentFirst() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "Livres/vieux.pdf", ext: "pdf", folder: "Livres",
                      mtime: 1_600_000_000, pages: ["a", "b", "c"])
        try db.addDoc(relPath: "Livres/recent.pdf", ext: "pdf", folder: "Livres",
                      mtime: 1_700_000_000, pages: ["a"])
        try db.addDoc(relPath: "Cours/note.txt", ext: "txt", folder: "Cours",
                      mtime: 1_650_000_000, pages: ["a", "b"])

        let model = AllDocumentsModel(service: db.service)
        XCTAssertEqual(model.phase, .loading, "avant lecture : ni vide, ni liste")
        await model.start()

        XCTAssertEqual(model.total, 3)
        XCTAssertEqual(model.phase, .list)
        XCTAssertEqual(model.rows?.map(\.fileName),
                       ["recent.pdf", "note.txt", "vieux.pdf"])
        XCTAssertFalse(model.canLoadMore)
        // Les types PRÉSENTS, le plus fréquent d'abord : deux pdf, un txt.
        XCTAssertEqual(model.extensions, ["pdf", "txt"])

        let row = try XCTUnwrap(model.rows?.first)
        XCTAssertEqual(row.folder, "Livres")
        XCTAssertEqual(row.pages, 1)
        // Aucun chemin en clair : le dossier abrégé, comme la liste de résultats.
        XCTAssertEqual(row.folderPath, "Livres")
        XCTAssertFalse(row.isUnreadable)
    }

    /// Le filtre de nom, le dossier, le type et l'ordre changent la liste ET le
    /// compte : c'est le compte annoncé par la fenêtre.
    func testFiltersNarrowTheListAndTheCount() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "Livres/chimie-IP2022.pdf", ext: "pdf",
                      folder: "Livres", pages: ["a"])
        try db.addDoc(relPath: "Livres/physique.pdf", ext: "pdf",
                      folder: "Livres", pages: ["a", "b"])
        try db.addDoc(relPath: "Cours/IP2022-notes.txt", ext: "txt",
                      folder: "Cours", pages: ["a"])

        let model = AllDocumentsModel(service: db.service)
        await model.start()
        XCTAssertEqual(model.total, 3)

        model.nameFilter = "IP2022"
        await model.reload()
        XCTAssertEqual(model.total, 2)
        XCTAssertEqual(Set(model.rows?.map(\.fileName) ?? []),
                       ["chimie-IP2022.pdf", "IP2022-notes.txt"])

        model.folder = "Cours"
        await model.reload()
        XCTAssertEqual(model.rows?.map(\.fileName), ["IP2022-notes.txt"])

        model.folder = nil
        model.ext = "pdf"
        await model.reload()
        XCTAssertEqual(model.rows?.map(\.fileName), ["chimie-IP2022.pdf"])

        model.nameFilter = ""
        model.ext = nil
        model.order = .pages
        await model.reload()
        XCTAssertEqual(model.rows?.first?.fileName, "physique.pdf",
                       "« Pages » met le plus long en tête")
    }

    /// Un filtre qui ne rend rien : « lu et vide », pas « en cours de lecture ».
    /// C'est cette distinction qui évite d'annoncer « aucun document » pendant
    /// la lecture.
    func testAFilterThatMatchesNothingIsEmptyNotLoading() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "Livres/chimie.pdf", ext: "pdf", pages: ["a"])
        let model = AllDocumentsModel(service: db.service)
        model.nameFilter = "introuvable"
        await model.reload()
        XCTAssertEqual(model.phase, .empty)
        XCTAssertEqual(model.total, 0)
        XCTAssertNil(model.errorText)
    }

    /// La pagination : une tranche, puis « Charger plus » qui AJOUTE la suite
    /// sans redonner ni sauter de ligne (l'ordre du cœur est total).
    func testLoadMoreAppendsTheNextSliceWithoutOverlap() async throws {
        let db = try TempAppDB()
        // Deux tranches et une miette, sans en payer 401 : la taille de tranche
        // est celle du produit, on sème juste au-delà d'une tranche.
        let count = AllDocumentsModel.pageSize + 5
        for index in 0..<count {
            try db.addDoc(relPath: String(format: "Livres/fiche-%04d.txt", index),
                          ext: "txt", mtime: 1_700_000_000 - Double(index),
                          pages: ["a"])
        }
        let model = AllDocumentsModel(service: db.service)
        await model.start()

        XCTAssertEqual(model.total, count)
        XCTAssertEqual(model.rows?.count, AllDocumentsModel.pageSize)
        XCTAssertTrue(model.canLoadMore)

        await model.loadMore()
        XCTAssertEqual(model.rows?.count, count)
        XCTAssertFalse(model.canLoadMore)
        let names = model.rows?.map(\.fileName) ?? []
        XCTAssertEqual(Set(names).count, names.count, "aucune ligne en double")
    }

    /// Un document que Fouine n'a pas su lire reste dans la liste — les cacher
    /// recréerait le trou de l'audit — mais il porte son marqueur, avec la
    /// phrase de la fenêtre voisine.
    func testUnreadableAndPendingDocumentsAreMarked() async throws {
        let db = try TempAppDB()
        let failed = try db.store.upsertDoc(DocRecord(
            volUUID: "TEST-VOL", relPath: "Livres/casse.pdf", ext: "pdf",
            topFolder: "Livres", size: 10, mtime: 1_700_000_000))
        try db.store.setDocState(failed, .failed,
                                 err: "password-protected PDF: document is locked")
        try db.store.upsertDoc(DocRecord(
            volUUID: "TEST-VOL", relPath: "Livres/attente.pdf", ext: "pdf",
            topFolder: "Livres", size: 10, mtime: 1_600_000_000))

        let model = AllDocumentsModel(service: db.service)
        await model.start()
        XCTAssertEqual(model.total, 2)

        let broken = try XCTUnwrap(model.rows?.first { $0.fileName == "casse.pdf" })
        XCTAssertTrue(broken.isUnreadable)
        XCTAssertEqual(UnreadableReason.classify(broken.rawReason),
                       .passwordProtected)

        let waiting = try XCTUnwrap(model.rows?.first { $0.fileName == "attente.pdf" })
        XCTAssertTrue(waiting.isPending)
        XCTAssertFalse(waiting.isUnreadable, "« pas encore lu » n'est pas un échec")
    }

    /// « Modifié hier » : une date relative, jamais un horodatage — et la phrase
    /// est traduite.
    func testTheModifiedColumnIsRelative() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let text = AllDocumentsView.modifiedText(
            now.addingTimeInterval(-86_400), now: now)
        XCTAssertTrue(text.lowercased().contains("yesterday")
                      || text.lowercased().contains("hier"), text)
        XCTAssertFalse(text.contains("1970"), text)
    }
}
