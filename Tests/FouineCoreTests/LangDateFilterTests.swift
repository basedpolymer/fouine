// LangDateFilterTests.swift — facette « Langue » et filtres `langs` /
// `modifiedAfter` (lot U2, R-07 et R-10). Propriété : A-Core. SPEC §4.2.
//
// Ce qui est prouvé ici, et pourquoi : ces deux filtres sont de VRAIES
// requêtes, pas un tri du jeu déjà chargé. Les totaux (`totalPages`,
// `totalDocs`) doivent donc bouger avec eux — c'est exactement ce qui
// distingue une puce honnête d'une puce qui ment.

import XCTest
@testable import FouineCore

final class LangDateFilterTests: XCTestCase {

    /// Trois documents : deux langues détectées, une indéterminée ; trois dates
    /// de modification bien séparées. Tous portent le mot « enthalpie », de
    /// sorte que seule la dimension testée fasse varier le résultat.
    private struct Corpus {
        let db: TempDB
        let fr: Int64, en: Int64, inconnu: Int64
    }

    /// 2022-01-01, 2024-01-01 et 2026-01-01 en secondes UNIX (UTC).
    private static let y2022: Double = 1_640_995_200
    private static let y2024: Double = 1_704_067_200
    private static let y2026: Double = 1_767_225_600

    private func fixture() throws -> Corpus {
        let db = try makeDB()
        let fr = try addDoc(db, relPath: "Users/a/Livres/chimie.pdf",
                            folder: "Livres", mtime: Self.y2022, lang: "fr")
        let en = try addDoc(db, relPath: "Users/a/Livres/chemistry.pdf",
                            folder: "Livres", mtime: Self.y2024, lang: "en")
        // `lang` absente : c'est le cas de tout document indexé avant que
        // `LanguageDetector` n'existe, et de tout document trop court.
        let inconnu = try addDoc(db, relPath: "Users/a/Cours/notes.txt", ext: "txt",
                                 folder: "Cours", mtime: Self.y2026, lang: nil)
        try db.store.replacePages(docID: fr, pages: [page(1, "enthalpie libre.")])
        try db.store.replacePages(docID: en, pages: [page(1, "enthalpie of formation.")])
        try db.store.replacePages(docID: inconnu, pages: [page(1, "enthalpie ?")])
        return Corpus(db: db, fr: fr, en: en, inconnu: inconnu)
    }

    // MARK: - Facette « Langue » (R-10)

    func testFacetteLangueCompteLesTroisValeurs() throws {
        let c = try fixture()
        let facets = try c.db.store.facets(try query("enthalpie"), by: .lang)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: facets),
                       ["fr": 1, "en": 1, FacetKey.undeterminedLanguage: 1],
                       "la langue indéterminée est une valeur de facette à part entière, "
                       + "sous le jeton « und » et non sous la chaîne vide")
    }

    // MARK: - Filtre de langue (R-10)

    func testFiltreLangueEstUneVraieRequete() throws {
        let c = try fixture()
        var q = try query("enthalpie")
        q.langs = ["fr"]
        let r = try c.db.store.search(q)
        XCTAssertEqual(r.hits.map(\.docID), [c.fr])
        XCTAssertEqual(r.totalPages, 1, "le TOTAL suit le filtre : ce n'est pas "
                       + "un tri de la tranche chargée")
        XCTAssertEqual(r.totalDocs, 1)
    }

    func testFiltreLanguePlusieursValeurs() throws {
        let c = try fixture()
        var q = try query("enthalpie")
        q.langs = ["fr", "en"]
        XCTAssertEqual(Set(try c.db.store.search(q).hits.map(\.docID)), [c.fr, c.en])
    }

    func testFiltreLangueIndetermineeAttrapeLesDocumentsSansLangue() throws {
        let c = try fixture()
        var q = try query("enthalpie")
        q.langs = [FacetKey.undeterminedLanguage]
        XCTAssertEqual(try c.db.store.search(q).hits.map(\.docID), [c.inconnu])
    }

    /// La casse d'un code de langue vient de l'utilisateur (`--lang FR`) ;
    /// `docs.lang` est écrite en minuscules par `LanguageDetector`.
    func testFiltreLangueIgnoreLaCasse() throws {
        let c = try fixture()
        var q = try query("enthalpie")
        q.langs = ["FR"]
        XCTAssertEqual(try c.db.store.search(q).hits.map(\.docID), [c.fr])
    }

    // MARK: - Filtre de date (R-07)

    func testModifiedAfterFiltreSurLaDateDuDocument() throws {
        let c = try fixture()
        var q = try query("enthalpie")
        q.modifiedAfter = Self.y2024
        let r = try c.db.store.search(q)
        XCTAssertEqual(Set(r.hits.map(\.docID)), [c.en, c.inconnu],
                       "la borne est INCLUSIVE : le document du 1ᵉʳ janvier 2024 passe")
        XCTAssertEqual(r.totalPages, 2)
        q.modifiedAfter = Self.y2024 + 1
        XCTAssertEqual(try c.db.store.search(q).hits.map(\.docID), [c.inconnu])
    }

    func testModifiedAfterNilNeFiltreRien() throws {
        let c = try fixture()
        var q = try query("enthalpie")
        q.modifiedAfter = nil
        XCTAssertEqual(try c.db.store.search(q).totalDocs, 3)
    }

    // MARK: - Combinaisons

    /// Les quatre filtres de document vivent dans la MÊME sous-requête
    /// `SELECT id FROM docs WHERE …` : leurs arguments doivent rester dans
    /// l'ordre où les clauses sont écrites, sinon SQLite lie une date à une
    /// extension. C'est ce que ce test attrape.
    func testLangueDateDossierExtensionSeCombinent() throws {
        let c = try fixture()
        var q = try query("enthalpie")
        q.folders = ["Livres"]
        q.exts = ["pdf"]
        q.langs = ["fr", "en"]
        q.modifiedAfter = Self.y2024
        XCTAssertEqual(try c.db.store.search(q).hits.map(\.docID), [c.en])

        // Un filtre qui ne laisse rien passer rend zéro, pas une erreur.
        q.langs = ["fr"]
        XCTAssertEqual(try c.db.store.search(q).totalPages, 0)
    }

    /// Les facettes voient les mêmes filtres que les résultats — sauf la leur
    /// (convention du facettage à sélection multiple, appliquée par l'app).
    func testLesFacettesSuiventLesNouveauxFiltres() throws {
        let c = try fixture()
        var q = try query("enthalpie")
        q.modifiedAfter = Self.y2024
        let langues = try c.db.store.facets(q, by: .lang)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: langues),
                       ["en": 1, FacetKey.undeterminedLanguage: 1])
        var parLangue = try query("enthalpie")
        parLangue.langs = ["fr"]
        XCTAssertEqual(try c.db.store.facets(parLangue, by: .folder).map(\.0), ["Livres"])
    }

    // MARK: - Ensemble de documents pour le canal vectoriel

    /// Le canal sémantique ne lit pas le SQL du canal lexical : il ne connaît
    /// des filtres que l'ensemble de documents qu'on lui autorise. Sans cette
    /// méthode, `--lang fr --hybrid` rendait des pages anglaises.
    func testEnsembleDeDocumentsPourLeCanalVectoriel() throws {
        let c = try fixture()
        XCTAssertNil(try c.db.store.docIDsMatching(langs: [], modifiedAfter: nil),
                     "aucun filtre armé : aucune restriction, et pas de requête")
        XCTAssertEqual(try c.db.store.docIDsMatching(langs: ["fr"], modifiedAfter: nil),
                       [c.fr])
        XCTAssertEqual(try c.db.store.docIDsMatching(langs: [], modifiedAfter: Self.y2024),
                       [c.en, c.inconnu])
        XCTAssertEqual(try c.db.store.docIDsMatching(langs: ["en", "fr"],
                                                     modifiedAfter: Self.y2024),
                       [c.en], "les deux filtres se combinent en ET")
    }

    // MARK: - Bornes de date (DateWindow)

    /// Calendrier grégorien à Paris : les bornes sont des instants LOCAUX, la
    /// même convention que la facette « Années » (`localtime`).
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }

    func testDebutDAnneeCivile() throws {
        let calendar = paris
        // 14 juillet 2026, midi.
        let date = calendar.date(from: DateComponents(year: 2026, month: 7, day: 14,
                                                      hour: 12))!
        let cetteAnnee = DateWindow.startOfYear(date, calendar: calendar)
        XCTAssertEqual(cetteAnnee,
                       calendar.date(from: DateComponents(year: 2026, month: 1,
                                                          day: 1))!.timeIntervalSince1970)
        let cinqAns = DateWindow.startOfYear(date, yearsBack: 4, calendar: calendar)
        XCTAssertEqual(cinqAns,
                       calendar.date(from: DateComponents(year: 2022, month: 1,
                                                          day: 1))!.timeIntervalSince1970,
                       "« les 5 dernières années » = 2022 à 2026, celle-ci comprise")
    }

    func testDebutDeJourneeISO() throws {
        let calendar = paris
        XCTAssertEqual(DateWindow.startOfDay(iso8601: "2026-03-01", calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 3,
                                                          day: 1))!.timeIntervalSince1970)
        for mauvais in ["2026-3-1", "01/03/2026", "2026-02-30", "hier", "",
                        "2026-13-01", "2026-03-01T12:00:00"] {
            XCTAssertNil(DateWindow.startOfDay(iso8601: mauvais, calendar: calendar),
                         "« \(mauvais) » n'est pas une date : mieux vaut un refus "
                         + "qu'une borne inventée")
        }
    }

    /// Le comptage par document (audit A12) passe par le même `docFilter` : un
    /// filtre oublié là ferait annoncer des pages que la liste ne montre pas.
    func testComptageParDocumentSuitLesFiltres() throws {
        let c = try fixture()
        var q = try query("enthalpie")
        q.langs = ["fr"]
        let counts = try c.db.store.matchedPageCounts(q, excludingDocsMatching: nil)
        XCTAssertEqual(counts, [c.fr: 1])
    }
}
