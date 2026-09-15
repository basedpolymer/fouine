// NameChannelFilterTests.swift — le canal des NOMS obéit aux filtres de la
// requête (lot MC2, constat PM-26). Propriété : A-Core.
//
// LE FAIT MESURÉ. `fouine_search {query:"examen", source:"transcript"}` rendait
// deux hits de transcription… et cinq `.pdf` dans `name_matches`. C'est
// défendable en théorie — un nom ne désigne aucune page, et la provenance est
// une propriété de la page — et indéfendable à l'usage : l'appelant a demandé
// que la réponse ne porte que des transcriptions, et rien ne l'avertit.
// L'audit n'avait éprouvé ni `lang` ni `doc_ids` : ils le sont ici.

import XCTest
@testable import FouineCore

final class NameChannelFilterTests: XCTestCase {

    /// Trois documents dont le NOM répond à « examen », de langues, de dates et
    /// de provenances différentes.
    private func corpus() throws -> (db: TempDB, pdf: Int64, video: Int64,
                                     vieux: Int64) {
        let db = try makeDB()
        let pdf = try addDoc(db, relPath: "Users/a/Livres/examen-2025.pdf",
                             mtime: 1_700_000_000, lang: "fr")
        let video = try addDoc(db, relPath: "Users/a/M2SU/examen filme.mp4",
                               ext: "mp4", folder: "M2SU",
                               mtime: 1_700_000_000, lang: "en")
        let vieux = try addDoc(db, relPath: "Users/a/Livres/examen ancien.pdf",
                               mtime: 1_500_000_000, lang: "fr")
        for doc in [pdf, vieux] {
            try db.store.replacePages(docID: doc, pages: [
                page(1, "enonce de l examen de chimie"),
            ])
        }
        try db.store.replacePages(docID: video, pages: [
            page(1, "[00:01] consignes de l examen filme", .transcript),
        ])
        return (db, pdf, video, vieux)
    }

    private func named(_ db: TempDB, _ build: (inout SearchQuery) -> Void) throws
        -> Set<Int64> {
        var q = try query("examen")
        build(&q)
        return Set(try db.store.documentsMatchingName(q).map(\.id))
    }

    func testSansFiltreLesTroisRepondent() throws {
        let c = try corpus()
        XCTAssertEqual(try named(c.db) { _ in }, [c.pdf, c.video, c.vieux])
    }

    func testLaProvenanceEcarteLesDocumentsSansUneSeulePageDeCetteOrigine() throws {
        let c = try corpus()
        XCTAssertEqual(try named(c.db) { $0.sources = PageSource.transcribed },
                       [c.video],
                       "la réponse ne devait porter que des transcriptions")
        XCTAssertEqual(try named(c.db) { $0.sources = PageSource.typed },
                       [c.pdf, c.vieux])
    }

    func testLaLangueEtLaDateAussi() throws {
        let c = try corpus()
        XCTAssertEqual(try named(c.db) { $0.langs = ["en"] }, [c.video])
        XCTAssertEqual(try named(c.db) { $0.modifiedAfter = 1_600_000_000 },
                       [c.pdf, c.video], "« ancien » est en deçà de la borne")
    }

    func testEtLesDocumentsDesignes() throws {
        let c = try corpus()
        XCTAssertEqual(try named(c.db) { $0.inDocIDs = [c.vieux] }, [c.vieux])
        XCTAssertEqual(try named(c.db) { $0.folders = ["M2SU"] }, [c.video])
    }

    /// La règle du lot : à filtre absent, le SQL est celui d'avant. Les clauses
    /// neuves ne s'écrivent que si la requête les porte.
    func testAFiltreAbsentAucuneClauseNeSAjoute() throws {
        let c = try corpus()
        var q = try query("examen")
        XCTAssertTrue(q.keepsAllSources)
        XCTAssertNil(q.modifiedAfter)
        XCTAssertTrue(q.langs.isEmpty)
        XCTAssertEqual(try c.db.store.documentsMatchingName(q).count, 3)
        // L'ensemble COMPLET des provenances ne retire rien non plus.
        q.sources = Set(PageSource.allCases)
        XCTAssertEqual(try c.db.store.documentsMatchingName(q).count, 3)
    }
}
