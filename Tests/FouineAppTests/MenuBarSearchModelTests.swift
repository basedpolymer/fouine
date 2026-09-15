// MenuBarSearchModelTests.swift — la mini-recherche de la barre des menus
// (INT-M1). Propriété : A-App.
//
// Ce que ces tests protègent : le panneau tient en huit lignes, dans l'ordre du
// moteur, les pages d'un même document rassemblées, avec un extrait qui ne
// coupe pas les mots ; il dit quand il n'a rien trouvé et quand la question
// était mal formée ; et la réponse d'une recherche périmée n'écrase pas celle
// de la recherche en cours.

import XCTest
import FouineCore
@testable import FouineApp

@MainActor
final class MenuBarSearchModelTests: XCTestCase {

    // MARK: - Fabriques

    private func hit(doc: Int64, page: Int, path: String = "Essai/livre.pdf",
                     snippet: String = "un extrait") -> Hit {
        Hit(docID: doc, path: path, page: page, score: -1, snippet: snippet,
            source: .native, fuzzyDistance: 0)
    }

    private func results(_ hits: [Hit], totalPages: Int? = nil,
                         totalDocs: Int? = nil) -> SearchResults {
        SearchResults(hits: hits, totalPages: totalPages ?? hits.count,
                      totalDocs: totalDocs ?? Set(hits.map(\.docID)).count,
                      elapsedMS: 1)
    }

    private func rows(_ hits: [Hit]) -> [MenuBarSearchRow] {
        MenuBarSearchModel.rows(from: results(hits), docRows: [:])
    }

    // MARK: - Construction des lignes

    /// Deux pages d'un même document se suivent, et l'ordre des DOCUMENTS reste
    /// celui du moteur : le document dont la meilleure page est première le
    /// reste.
    func testPagesOfTheSameDocumentAreAdjacentAndDocumentOrderIsKept() {
        let built = rows([
            hit(doc: 1, page: 10), hit(doc: 2, page: 3),
            hit(doc: 1, page: 44), hit(doc: 3, page: 7),
        ])
        XCTAssertEqual(built.map { [$0.docID, Int64($0.page)] },
                       [[1, 10], [1, 44], [2, 3], [3, 7]])
    }

    /// Huit lignes, jamais neuf : le panneau ne descend pas jusqu'au Dock.
    func testAtMostEightRows() {
        let many = (1...20).map { hit(doc: Int64($0), page: 1) }
        XCTAssertEqual(rows(many).count, MenuBarSearchModel.limit)
        XCTAssertEqual(MenuBarSearchModel.limit, 8)
    }

    /// Le nom du fichier, sans son chemin — et pris dans la ligne `docs` quand
    /// elle a été chargée.
    func testFileNameHasNoPath() {
        let built = rows([hit(doc: 1, page: 2, path: "Cours/Chimie/organique.pdf")])
        XCTAssertEqual(built.first?.fileName, "organique.pdf")
    }

    // MARK: - Extrait

    /// Les marqueurs « » du snippet FTS5 ne se lisent pas : le panneau ne
    /// colore rien, il les retire.
    func testSnippetLosesTheMarkers() {
        XCTAssertEqual(
            MenuBarSearchModel.plainSnippet("la règle de «Markovnikov» dit"),
            "la règle de Markovnikov dit")
    }

    /// Un extrait long se coupe sur une frontière de MOT, pas au milieu.
    func testLongSnippetIsCutOnAWordBoundary() {
        let long = String(repeating: "alpha beta ", count: 20)
        let cut = MenuBarSearchModel.plainSnippet(long)
        XCTAssertTrue(cut.hasSuffix("…"), cut)
        XCTAssertLessThanOrEqual(cut.count, MenuBarSearchModel.snippetLimit + 1)
        // Ni mot coupé, ni espace avant les points de suspension.
        XCTAssertTrue(cut.hasSuffix("alpha…") || cut.hasSuffix("beta…"), cut)
    }

    /// Les retours à la ligne d'une page deviennent des espaces : une ligne de
    /// panneau ne fait qu'une ligne.
    func testSnippetIsFlattenedToOneLine() {
        let flat = MenuBarSearchModel.plainSnippet("premier\nsecond\t troisième")
        XCTAssertEqual(flat, "premier second troisième")
    }

    // MARK: - États

    func testEmptyResultsGiveTheEmptyState() async throws {
        let db = try TempAppDB()
        let model = MenuBarSearchModel(service: db.service)
        model.apply(results: results([]), docRows: [:], generation: 0)
        XCTAssertEqual(model.state, .empty)
        XCTAssertTrue(model.rows.isEmpty)
    }

    /// L'index pas encore ouvert : une phrase du produit, pas le message du
    /// moteur (BU-02). Le panneau répondait « base : database not open (call
    /// open(at:)) » — dans la seule surface visible de l'application, à un
    /// public qui ne sait pas ce qu'est une base.
    func testAClosedIndexIsSaidInPlainWords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-menubar-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Une façade jamais ouverte : c'est l'état d'un lancement sans fenêtre
        // avant la correction, et celui d'un index qui refuse de s'ouvrir.
        let service = StoreService(
            databaseURL: directory.appendingPathComponent("fouine.db"))
        XCTAssertFalse(service.isOpen)

        let model = MenuBarSearchModel(service: service)
        model.text = "hydrogène"
        model.execute()

        XCTAssertEqual(model.state, .indexNotOpen)
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testResultsStateCarriesTheTotals() async throws {
        let db = try TempAppDB()
        let model = MenuBarSearchModel(service: db.service)
        model.apply(results: results([hit(doc: 1, page: 1)],
                                     totalPages: 132, totalDocs: 12),
                    docRows: [:], generation: 0)
        XCTAssertEqual(model.state, .results(pages: 132, docs: 12))
        // Huit lignes montrées sur 132 pages : la ligne « voir tout » s'impose.
        XCTAssertTrue(model.hasMore)
    }

    /// Une requête que l'analyseur refuse (ici une exclusion toute seule, la
    /// faute la plus courante) dit ce qui ne va pas — elle ne rend pas une
    /// liste vide et muette.
    func testInvalidQueryGivesAnError() async throws {
        let db = try TempAppDB()
        let model = MenuBarSearchModel(service: db.service)
        model.text = "-markovnikov"
        model.execute()
        guard case .error(let message) = model.state else {
            return XCTFail("état attendu : erreur, obtenu \(model.state)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(model.rows.isEmpty)
    }

    /// La réponse d'une recherche PÉRIMÉE ne s'affiche pas : on a tapé une
    /// lettre de plus entre-temps, et c'est la nouvelle question qui compte.
    func testStaleAnswerIsDropped() async throws {
        let db = try TempAppDB()
        let model = MenuBarSearchModel(service: db.service)
        model.apply(results: results([hit(doc: 1, page: 1)]),
                    docRows: [:], generation: 0)
        XCTAssertEqual(model.rows.count, 1)

        // Une nouvelle question part (génération 1) ; la réponse de la
        // précédente arrive après.
        model.text = "markovnikov"
        model.execute()
        model.apply(results: results([hit(doc: 9, page: 9)]),
                    docRows: [:], generation: 0)
        XCTAssertFalse(model.rows.contains { $0.docID == 9 })
        model.fail("erreur périmée", generation: 0)
        XCTAssertNotEqual(model.state, .error("erreur périmée"))
    }

    // MARK: - Recherche réelle, sur une base jetable

    /// Le chemin complet : une base, une requête, des lignes. C'est ce qui
    /// prouve que le panneau interroge le moteur comme la fenêtre.
    func testSearchesTheIndex() async throws {
        let db = try TempAppDB()
        _ = try db.addDoc(relPath: "Cours/organique.txt",
                          pages: ["la règle de Markovnikov",
                                  "rien ici",
                                  "Markovnikov encore"])
        let model = MenuBarSearchModel(service: db.service)
        model.text = "markovnikov"
        model.execute()
        try await settle(model)

        XCTAssertEqual(model.rows.count, 2)
        // Les deux pages qui portent le mot, et elles seules. L'ORDRE est celui
        // du moteur (la page la mieux classée d'abord), pas celui des numéros
        // de page : l'affirmer autrement figerait le classement dans un test
        // qui ne parle pas de classement.
        XCTAssertEqual(Set(model.rows.map(\.page)), [1, 3])
        XCTAssertEqual(model.rows.first?.fileName, "organique.txt")
        XCTAssertEqual(model.state, .results(pages: 2, docs: 1))
        XCTAssertFalse(model.hasMore)
    }

    /// Aucun document ne porte le mot : l'état le dit.
    func testNoMatchGivesTheEmptyState() async throws {
        let db = try TempAppDB()
        _ = try db.addDoc(relPath: "Cours/organique.txt", pages: ["rien ici"])
        let model = MenuBarSearchModel(service: db.service)
        model.text = "markovnikov"
        model.execute()
        try await settle(model)
        XCTAssertEqual(model.state, .empty)
    }

    // MARK: - Sélection au clavier

    func testArrowKeysWalkTheRowsAndGiveTheFieldBack() {
        let model = MenuBarSearchModel(service: StoreService(
            databaseURL: URL(fileURLWithPath: "/dev/null")))
        model.apply(results: results([hit(doc: 1, page: 1), hit(doc: 2, page: 2)]),
                    docRows: [:], generation: 0)
        XCTAssertNil(model.selection)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selection, HitKey(docID: 1, page: 1))
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selection, HitKey(docID: 2, page: 2))
        // On ne sort pas de la liste par le bas…
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selection, HitKey(docID: 2, page: 2))
        // … et remonter au-delà de la première ligne rend la main au champ.
        model.moveSelection(by: -1)
        model.moveSelection(by: -1)
        XCTAssertNil(model.selection)
    }

    // MARK: - Attente

    /// Le modèle travaille par `Task` détachées, comme `SearchModel` : on
    /// attend qu'il soit retombé au repos sans bloquer le fil principal.
    private func settle(_ model: MenuBarSearchModel,
                        timeout: TimeInterval = 10,
                        file: StaticString = #filePath,
                        line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if model.state != .searching { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("la mini-recherche ne s'est pas stabilisée en \(timeout) s",
                file: file, line: line)
    }
}
