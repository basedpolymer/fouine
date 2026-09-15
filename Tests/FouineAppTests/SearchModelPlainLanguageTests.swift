// SearchModelPlainLanguageTests.swift — chercher comme on parle, dans l'app
// (lot MP1 : PR-02, PR-04, C2-08, C2-12). Propriété : A-App.
//
// Ce qui se prouve ici est ce que l'utilisateur VOIT : la ligne du repli, le
// bandeau des noms, la phrase du faux filtre et le montant tapé sans son
// espace. Les vues SwiftUI ne se testent pas — c'est donc l'état du modèle et
// les fonctions pures des textes qui sont éprouvés.

import XCTest
import FouineCore
@testable import FouineApp

@MainActor
final class SearchModelPlainLanguageTests: XCTestCase {

    // MARK: - C2-08 : le repli en flou

    /// Un document NATIF porte « Villeurbanne » : c'est le cas du constat, celui
    /// où la portée « pages scannées » ne pouvait rien rattraper.
    private func typoFixture() throws -> (db: TempAppDB, doc: Int64,
                                          model: SearchModel) {
        let db = try TempAppDB()
        let doc = try db.addDoc(
            relPath: "Users/essai/rapport.txt",
            pages: ["Le laboratoire de Villeurbanne accueille la conference."])
        try TrigramExpander(store: db.store).warm()
        return (db, doc, SearchModel(service: db.service))
    }

    func testTheFuzzyFallbackIsAnnouncedAndFindsTheDocument() async throws {
        let f = try typoFixture()
        await run(f.model, "Villeurbane")
        XCTAssertTrue(f.model.fuzzyFallback,
                      "l'app doit savoir que le jeu affiché vient du repli")
        XCTAssertEqual(f.model.hits.map(\.docID), [f.doc])
        XCTAssertEqual(f.model.hits.first?.fuzzyDistance, 1)
    }

    func testNoFallbackFlagOnAnOrdinarySearch() async throws {
        let f = try typoFixture()
        await run(f.model, "Villeurbanne")
        XCTAssertFalse(f.model.fuzzyFallback)
        XCTAssertEqual(f.model.hits.count, 1)
    }

    /// Vider le champ efface la ligne : une phrase qui survit à la requête
    /// qu'elle explique est un mensonge.
    func testTheFallbackLineDisappearsWithTheQuery() async throws {
        let f = try typoFixture()
        await run(f.model, "Villeurbane")
        XCTAssertTrue(f.model.fuzzyFallback)
        await run(f.model, "")
        XCTAssertFalse(f.model.fuzzyFallback)
        XCTAssertTrue(f.model.nameMatches.isEmpty)
    }

    // MARK: - PR-02 : le bandeau des noms

    func testTheNameBannerListsTheDocumentsFoundByTheirName() async throws {
        let db = try TempAppDB()
        let named = try db.addDoc(
            relPath: "Users/essai/IP2022__Analyse.txt",
            pages: ["une page dont le texte ne porte pas le sigle du titre."])
        let model = SearchModel(service: db.service)

        await run(model, "IP2022")
        XCTAssertTrue(model.hits.isEmpty, "aucune PAGE ne répond")
        XCTAssertEqual(model.nameMatches.map(\.id), [named])
        XCTAssertEqual(NameMatchText.banner(count: 1, query: "IP2022"),
                       String(localized: "\(1) document(s)") + " "
                       + String(localized: "whose name contains “IP2022”"))
    }

    /// Le bandeau ne survit pas à la requête suivante.
    func testTheNameBannerFollowsTheQuery() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "Users/essai/IP2022__Analyse.txt",
                      pages: ["texte sans le sigle."])
        try db.addDoc(relPath: "Users/essai/autre.txt", pages: ["polymere seul."])
        let model = SearchModel(service: db.service)

        await run(model, "IP2022")
        XCTAssertEqual(model.nameMatches.count, 1)
        await run(model, "polymere")
        XCTAssertTrue(model.nameMatches.isEmpty,
                      "« autre.txt » ne porte pas « polymere » dans son NOM")
        XCTAssertEqual(model.hits.count, 1)
    }

    // MARK: - PR-04 : un faux filtre se dit, sous le champ

    func testAnUnknownPrefixIsSaidUnderTheField() {
        let expected = ErrorText.describe(
            QueryError.unknownPrefix("type:", known: []))
        XCTAssertEqual(QueryDiagnosis.describe(text: "azote type:pdf"), expected)
        XCTAssertEqual(QueryDiagnosis.describe(text: "dans:Livres azote"),
                       ErrorText.describe(
                           QueryError.unknownPrefix("dans:", known: [])))
        // Les vrais filtres, les alias anglais, une URL, une heure : rien à dire.
        for ordinary in ["dossier:Livres azote", "folder:Livres azote",
                         "near:5 azote carbone", "ext:pdf azote",
                         "https://exemple.org", "10:30", "type:"] {
            XCTAssertNil(QueryDiagnosis.describe(text: ordinary), ordinary)
        }
    }

    /// `-texte:` EXISTE et ne s'exclut pas (lot MN2) : la phrase ne prétend
    /// plus que ce n'est pas un filtre. Elle nomme ceux qui s'excluent, sans
    /// leurs alias, et le geste qui écarte un mot.
    func testAFilterThatCannotBeExcludedIsSaidAsSuch() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "Users/essai/un.txt", pages: ["azote reacteur"])
        let model = SearchModel(service: db.service)

        await run(model, "azote -texte:reacteur")
        XCTAssertEqual(model.errorText,
                       "“texte:” cannot be excluded. The filters that can are "
                       + "dossier:, ext:, nom:, chemin:. To leave out a word, write -word.")
        XCTAssertTrue(model.hits.isEmpty)
    }

    // MARK: - C2-12 : le montant tapé sans son espace

    func testAnAmountIsFoundWithoutItsThousandsSpace() async throws {
        let db = try TempAppDB()
        let doc = try db.addDoc(
            relPath: "Users/essai/facture.txt",
            pages: ["Total du mois : 1\u{202F}512,50 € toutes taxes comprises."])
        let model = SearchModel(service: db.service)

        await run(model, "1512,50")
        XCTAssertEqual(model.hits.map(\.docID), [doc])
        XCTAssertFalse(model.fuzzyFallback,
                       "le montant est trouvé exactement, pas par un repli")
    }

    // MARK: - RK-01 : la ligne « le sens n'est pas consulté »

    /// La ligne ne s'affiche QUE pour qui a armé « Chercher aussi par le sens ».
    /// Sans modèle, `useSemantic` est faux : une phrase entre guillemets est une
    /// recherche exacte ordinaire, et annoncer un canal qui n'a jamais servi
    /// serait une phrase de plus à comprendre pour rien.
    func testTheDisarmedLineStaysHiddenForALexicalSearch() async throws {
        let db = try TempAppDB()
        let doc = try db.addDoc(
            relPath: "Users/essai/thermo.txt",
            pages: ["L'énergie libre de Gibbs décide du sens d'une réaction."])
        let model = SearchModel(service: db.service)

        await run(model, "\"energie libre\"")
        XCTAssertFalse(model.semanticDisarmed,
                       "l'interrupteur du sens est éteint : rien à désarmer")
        XCTAssertEqual(model.hits.map(\.docID), [doc])
        await run(model, "")
        XCTAssertFalse(model.semanticDisarmed)
    }
}
