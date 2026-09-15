// SearchModelDocYearTests.swift — la section « Daté de » de la barre latérale
// (DD1, PR-07) : un filtre d'AFFICHAGE sur la date inscrite dans le document.
//
// Ce qui se teste : le filtre garde les documents de l'année cochée et écarte
// ceux qui n'ont pas de date (le moteur les range sous la clé vide, l'app fait
// pareil) ; « Effacer les filtres » le vide ; une session écrite avant DD1,
// sans la clé `docYears`, se relit toujours.

import XCTest
import FouineCore
@testable import FouineApp

@MainActor
final class SearchModelDocYearTests: XCTestCase {

    private var live: [TempAppDB] = []

    override func setUp() {
        super.setUp()
        _ = TestPrefs.isolate
    }

    override func tearDown() {
        live.removeAll()
        super.tearDown()
    }

    private func fixture() throws -> (TempAppDB, SearchModel, dated: Int64, undated: Int64) {
        let db = try TempAppDB()
        live.append(db)
        let dated = try db.addDoc(relPath: "Users/essai/rapport-2003.pdf", ext: "pdf",
                                  pages: ["alpha rapport de 2003"])
        let undated = try db.addDoc(relPath: "Users/essai/notes.txt",
                                    pages: ["alpha notes sans date"])
        try db.store.setDocDate(dated, DocumentDate.parse("2003-04-12"))
        return (db, SearchModel(service: db.service), dated, undated)
    }

    func testTheDatedFilterKeepsTheDocumentsOfThatYearOnly() async throws {
        let (_, model, dated, undated) = try fixture()
        await run(model, "alpha")
        XCTAssertEqual(Set(model.hits.map(\.docID)), [dated, undated],
                       "sans filtre, les deux documents")

        model.selectedDocYears = ["2003"]
        XCTAssertTrue(model.hasDisplayFilters)
        XCTAssertTrue(model.hasFilters)
        XCTAssertEqual(model.filteredHits.map(\.docID), [dated],
                       "le document sans date ne satisfait aucune année cochée")

        model.selectedDocYears = ["1999"]
        XCTAssertTrue(model.filteredHits.isEmpty)

        model.clearFilters()
        XCTAssertTrue(model.selectedDocYears.isEmpty)
        XCTAssertEqual(model.filteredHits.count, 2, "« Effacer » vide aussi cette facette")
    }

    /// La facette vient du moteur, avec ses comptes, et la clé vide (documents
    /// sans date) est écartée comme pour les autres dimensions.
    func testTheDocYearFacetIsComputedWithoutTheEmptyKey() async throws {
        let (_, model, _, _) = try fixture()
        await run(model, "alpha")
        let values = model.facets[.docYear] ?? []
        XCTAssertEqual(values.map(\.0), ["2003"])
        XCTAssertEqual(values.first?.1, 1)
    }

    /// Une session enregistrée par une version antérieure n'a pas `docYears` :
    /// elle doit se relire, sinon « Reprendre où j'en étais » se tairait pour
    /// tous ceux qui mettent à jour.
    func testASessionWrittenBeforeDD1StillDecodes() throws {
        let json = """
        {"text":"alpha","folders":[],"exts":[],"years":["2024"],"sources":[],
         "langs":[],"date":"any","selectionDocID":null,"selectionPage":null}
        """
        let session = try JSONDecoder().decode(SearchSession.self, from: Data(json.utf8))
        XCTAssertEqual(session.years, ["2024"])
        XCTAssertNil(session.docYears)

        let round = SearchSession(text: "beta", docYears: ["2003"])
        let data = try JSONEncoder().encode(round)
        XCTAssertEqual(try JSONDecoder().decode(SearchSession.self, from: data).docYears,
                       ["2003"])
    }
}
