// SearchModelSortTests.swift — le tri honnête (PR-08). Propriété : A-App.
//
// Ce que ces tests prouvent : « montre-moi le document le plus récent qui parle
// de X » a une réponse. Trier les 200 premiers résultats d'un fonds de 29 000
// pages ne rendait pas les 200 plus récents, mais les plus pertinents remis en
// ordre — et le document cherché pouvait être en 2 000e position.

import XCTest
import FouineCore
@testable import FouineApp

@MainActor
final class SearchModelSortTests: XCTestCase {

    private var live: [TempAppDB] = []

    override func setUp() {
        super.setUp()
        _ = TestPrefs.isolate
        Prefs.defaults.removeObject(forKey: Prefs.sortOrder)
    }

    override func tearDown() {
        live.removeAll()
        super.tearDown()
    }

    private func makeAppDB() throws -> TempAppDB {
        let db = try TempAppDB()
        live.append(db)
        return db
    }

    /// `settle` ne connaît que la recherche et les facettes : le chargement pour
    /// trier est une troisième tâche, et c'est elle qu'on attend ici.
    private func settleSort(_ model: SearchModel, timeout: TimeInterval = 60,
                            file: StaticString = #filePath,
                            line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !model.isSearching && !model.isFaceting && !model.isLoadingForSort {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("le chargement pour trier ne s'est pas terminé en \(timeout) s",
                file: file, line: line)
    }

    /// `docs` documents de `pages` pages chacun ; le DERNIER est le plus récent
    /// — donc le plus loin dans l'ordre de pertinence, celui qu'un tri sur la
    /// seule première tranche ne pouvait pas voir.
    private func fixture(docs: Int, pages: Int) throws -> (TempAppDB, SearchModel) {
        let db = try makeAppDB()
        for d in 0..<docs {
            try db.addDoc(relPath: "Users/essai/d\(d).txt",
                          mtime: 1_600_000_000 + Double(d) * 86_400,
                          pages: (0..<pages).map { "alpha page \($0) du document \(d)" })
        }
        return (db, SearchModel(service: db.service))
    }

    // MARK: - Le jeu entier est chargé avant d'être trié

    func testTriParDateChargeToutLeJeuPuisTrie() async throws {
        let (_, model) = try fixture(docs: 45, pages: 10)   // 450 résultats
        await run(model, "alpha")
        XCTAssertEqual(model.hits.count, SearchModel.pageSize,
                       "une recherche neuve rend une tranche, comme avant")
        XCTAssertTrue(model.canLoadMore)

        model.sortOrder = .dateDesc
        XCTAssertTrue(model.isLoadingForSort, "le chargement part tout de suite")
        await settleSort(model)

        XCTAssertEqual(model.hits.count, 450, "trois tranches : 200, 200, 50")
        XCTAssertFalse(model.canLoadMore)
        XCTAssertFalse(model.sortIsPartial, "tout est chargé : plus rien à avouer")
        XCTAssertFalse(model.sortCapReached)
        XCTAssertEqual(model.groups.count, 45)
        XCTAssertEqual((model.groups.first?.path as NSString?)?.lastPathComponent,
                       "d44.txt", "le plus récent en tête, où que la pertinence l'ait mis")
        XCTAssertEqual((model.groups.last?.path as NSString?)?.lastPathComponent,
                       "d0.txt")
    }

    /// Le plafond coupe, et la ligne du tri le DIT — avec les deux nombres.
    func testAuDelaDuPlafondLeTriEstAnnonceCommePartiel() async throws {
        let (_, model) = try fixture(docs: 50, pages: 100)  // 5 000 résultats
        await run(model, "alpha")
        XCTAssertEqual(model.totalPages, 5_000)

        model.sortOrder = .title
        await settleSort(model)

        XCTAssertEqual(model.hits.count, SearchModel.sortLoadCap)
        XCTAssertTrue(model.canLoadMore, "il reste des pages derrière le plafond")
        XCTAssertTrue(model.sortIsPartial)
        XCTAssertTrue(model.sortCapReached)
    }

    /// Le chemin normal ne paie RIEN : tant que le tri est la pertinence,
    /// aucune tranche de plus n'est demandée au moteur.
    func testLeTriParPertinenceNeChargeAucuneTrancheDePlus() async throws {
        let (_, model) = try fixture(docs: 45, pages: 10)
        await run(model, "alpha")
        await settleSort(model)
        XCTAssertFalse(model.isLoadingForSort)
        XCTAssertEqual(model.hits.count, SearchModel.pageSize)
        XCTAssertTrue(model.canLoadMore)
        XCTAssertFalse(model.sortIsPartial)
    }

    /// Revenir à « pertinence » pendant le chargement l'interrompt : c'est la
    /// seule façon de renoncer, et le sélecteur reste actif pour cela.
    func testRevenirALaPertinenceInterromptLeChargement() async throws {
        let (_, model) = try fixture(docs: 45, pages: 10)
        await run(model, "alpha")
        model.sortOrder = .dateDesc
        XCTAssertTrue(model.isLoadingForSort)
        model.sortOrder = .score
        XCTAssertFalse(model.isLoadingForSort)
        await settleSort(model)
        XCTAssertLessThan(model.hits.count, 450,
                          "le chargement s'est arrêté en chemin")
    }

    /// Une nouvelle requête arrête net le chargement : ses tranches parleraient
    /// de la requête précédente.
    func testUneNouvelleRequeteArreteLeChargement() async throws {
        let db = try makeAppDB()
        for d in 0..<45 {
            try db.addDoc(relPath: "Users/essai/d\(d).txt",
                          mtime: 1_600_000_000 + Double(d) * 86_400,
                          pages: (0..<10).map { "alpha page \($0) du document \(d)" })
        }
        try db.addDoc(relPath: "Users/essai/unique.txt", pages: ["beta tout seul"])
        let model = SearchModel(service: db.service)
        await run(model, "alpha")
        model.sortOrder = .dateDesc
        XCTAssertTrue(model.isLoadingForSort)

        await run(model, "beta")
        await settleSort(model)

        XCTAssertEqual(model.hits.count, 1)
        XCTAssertEqual(model.executedText, "beta")
        XCTAssertFalse(model.isLoadingForSort)
        XCTAssertTrue(model.hits.allSatisfy { $0.snippet.contains("beta") },
                      "aucune tranche de la requête précédente n'a atterri ici")
    }
}
