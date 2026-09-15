// SourceFilterTests.swift — filtre de PROVENANCE `SearchQuery.sources`
// (lot P3, PERSP-5). Propriété : A-Core. SPEC §4.2, §5.5.3.
//
// Ce qui est prouvé ici, et pourquoi. « Pages scannées seulement » était un
// filtre d'AFFICHAGE : il cachait, parmi les pages déjà chargées, celles dont
// le texte est natif — sans que les totaux, les facettes, le comptage par
// document ni « Charger plus » le sachent. Un vrai filtre doit donc (1) porter
// sur les DEUX chemins, exact et flou, (2) déplacer les totaux et les facettes,
// (3) ne RIEN coûter quand on ne le demande pas : le SQL doit alors être celui
// d'avant, au caractère près.

import XCTest
@testable import FouineCore

final class SourceFilterTests: XCTestCase {

    /// Un document natif, un document scanné, et un document MIXTE — c'est ce
    /// dernier qui distingue un filtre par page d'un filtre par document : un
    /// PDF dont la couche texte manque sur quelques planches est le cas
    /// courant, pas l'exception.
    private struct Corpus {
        let db: TempDB
        let natif: Int64, scanne: Int64, mixte: Int64
    }

    private func fixture() throws -> Corpus {
        let db = try makeDB()
        let natif = try addDoc(db, relPath: "Users/a/Livres/cours.pdf")
        let scanne = try addDoc(db, relPath: "Users/a/Livres/photocopie.pdf")
        let mixte = try addDoc(db, relPath: "Users/a/Cours/melange.pdf",
                               folder: "Cours")
        try db.store.replacePages(docID: natif, pages: [
            page(1, "enthalpie libre du systeme"),
            page(2, "enthalpie de reaction"),
        ])
        try db.store.replacePages(docID: scanne, pages: [
            page(1, "enthalpie recopiee", .ocrAccurate),
            page(2, "enthalpie ancienne", .ocrAccurate),
        ])
        try db.store.replacePages(docID: mixte, pages: [
            page(1, "enthalpie tapee"),
            page(2, "enthalpie scannee", .ocrAccurate),
        ])
        return Corpus(db: db, natif: natif, scanne: scanne, mixte: mixte)
    }

    private func query(_ text: String, sources: Set<PageSource>?,
                       fuzzy: FuzzyMode = .off) throws -> SearchQuery {
        var q = try query(text, fuzzy: fuzzy)
        q.sources = sources
        return q
    }

    private func pages(_ r: SearchResults) -> Set<Int64> {
        Set(r.hits.map { Schema.ftsRowID(docID: $0.docID, page: $0.page) })
    }

    // MARK: - Aucun coût quand on ne demande rien

    func testSansFiltreLeSQLEstIdentique() throws {
        var q = try query("enthalpie")
        XCTAssertTrue(q.keepsAllSources)
        let vide = GRDBStore.sourceFilter(q, docID: "d", page: "p")
        XCTAssertEqual(vide.join, "", "sans filtre, aucune jointure ne s'ajoute "
                       + "au FROM : le SQL doit être celui d'avant")
        XCTAssertEqual(vide.sql, "")
        // L'ensemble VIDE et l'ensemble COMPLET ne retirent rien non plus.
        q.sources = []
        XCTAssertEqual(GRDBStore.sourceFilter(q, docID: "d", page: "p").join, "")
        q.sources = Set(PageSource.allCases)
        XCTAssertTrue(q.keepsAllSources)
        XCTAssertEqual(GRDBStore.sourceFilter(q, docID: "d", page: "p").join, "")
        XCTAssertEqual(GRDBStore.sourceFilter(q, docID: "d", page: "p").sql, "")
    }

    /// Le filtre natif passe par un LEFT JOIN : une page absente de `page_src`
    /// est du texte natif, un JOIN interne la ferait disparaître.
    func testLaJointureDuNatifEstExterne() throws {
        let q = try query("enthalpie", sources: PageSource.typed)
        let f = GRDBStore.sourceFilter(q, docID: "d", page: "p")
        XCTAssertTrue(f.join.hasPrefix(" LEFT JOIN page_src pf ON "), f.join)
        XCTAssertEqual(f.sql, " AND coalesce(pf.src, 0) IN (0)")
        let scan = GRDBStore.sourceFilter(
            try query("enthalpie", sources: PageSource.scanned), docID: "d", page: "p")
        XCTAssertTrue(scan.join.hasPrefix(" JOIN page_src pf ON "), scan.join)
        XCTAssertEqual(scan.sql, " AND pf.src IN (2)")
    }

    /// L'alias ne peut PAS être `s` : la branche floue en portée `ocr` joint
    /// déjà `page_src s` dans la même requête (§5.5.3).
    func testLAliasNeHeurtePasCeluiDeLaBrancheFloue() throws {
        let q = try query("enthalpie", sources: PageSource.scanned)
        XCTAssertFalse(GRDBStore.sourceFilter(q, docID: "d", page: "p")
                           .join.contains(" page_src s "))
    }

    // MARK: - Le filtre sur le chemin exact

    func testScanneNeRendQueLesPagesScannees() throws {
        let c = try fixture()
        let r = try c.db.store.search(try query("enthalpie", sources: PageSource.scanned))
        XCTAssertEqual(pages(r), [
            Schema.ftsRowID(docID: c.scanne, page: 1),
            Schema.ftsRowID(docID: c.scanne, page: 2),
            Schema.ftsRowID(docID: c.mixte, page: 2),
        ], "le document MIXTE n'entre que par sa page scannée : le filtre porte "
           + "sur la page, pas sur le document")
        XCTAssertTrue(r.hits.allSatisfy { $0.source != .native })
    }

    func testNatifNeRendQueLesPagesNatives() throws {
        let c = try fixture()
        let r = try c.db.store.search(try query("enthalpie", sources: PageSource.typed))
        XCTAssertEqual(pages(r), [
            Schema.ftsRowID(docID: c.natif, page: 1),
            Schema.ftsRowID(docID: c.natif, page: 2),
            Schema.ftsRowID(docID: c.mixte, page: 1),
        ])
        XCTAssertTrue(r.hits.allSatisfy { $0.source == .native })
    }

    /// Ce que le lot corrige : les TOTAUX suivent. C'est la différence entre un
    /// filtre et un tri de la tranche chargée.
    func testLesTotauxSuiventLeFiltre() throws {
        let c = try fixture()
        let tout = try c.db.store.search(try query("enthalpie", sources: nil))
        XCTAssertEqual(tout.totalPages, 6)
        XCTAssertEqual(tout.totalDocs, 3)
        let scan = try c.db.store.search(try query("enthalpie", sources: PageSource.scanned))
        XCTAssertEqual(scan.totalPages, 3)
        XCTAssertEqual(scan.totalDocs, 2)
        let natif = try c.db.store.search(try query("enthalpie", sources: PageSource.typed))
        XCTAssertEqual(natif.totalPages, 3)
        XCTAssertEqual(natif.totalDocs, 2)
        XCTAssertEqual(scan.totalPages + natif.totalPages, tout.totalPages,
                       "les deux provenances PARTITIONNENT le jeu : aucune page "
                       + "ne se perd, aucune ne compte deux fois")
    }

    /// Une page sans ligne dans `page_src` est du texte natif : c'est la
    /// convention de `pageMeta` et de la facette « Origine du texte », et le
    /// filtre doit la partager, sans quoi le compte du natif serait faux sur
    /// une base ancienne.
    func testUnePageSansLigneDeProvenanceEstNative() throws {
        let c = try fixture()
        try c.db.store.writeLocked { db in
            try db.execute(sql: "DELETE FROM page_src WHERE doc_id = ? AND page = 1",
                           arguments: [c.natif])
        }
        let natif = try c.db.store.search(try query("enthalpie", sources: PageSource.typed))
        XCTAssertTrue(pages(natif).contains(Schema.ftsRowID(docID: c.natif, page: 1)))
        let scan = try c.db.store.search(try query("enthalpie", sources: PageSource.scanned))
        XCTAssertFalse(pages(scan).contains(Schema.ftsRowID(docID: c.natif, page: 1)))
    }

    // MARK: - Le filtre sur le chemin FLOU (CTE fz, §5.5.3)

    /// Le plan flou empile `ex` et `fz` : le filtre doit être dans LES DEUX.
    /// Sans lui dans `fz`, une variante rendait des pages que le filtre venait
    /// d'écarter du chemin exact.
    func testLeCheminFlouPorteAussiLeFiltre() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/a/Livres/flou.pdf")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "thermodynamique appliquee"),
            page(2, "thermodynamlque scannee", .ocrAccurate),
        ])
        try TrigramExpander(store: db.store).warm()
        // Portée `all` : les deux branches voient les deux pages.
        var q = try query("thermodynamique", fuzzy: .on)
        q.fuzzyScope = .all
        let tout = try db.store.search(q)
        XCTAssertEqual(tout.totalPages, 2, "sans filtre, la variante ramène la "
                       + "page scannée en plus de la page exacte")
        q.sources = PageSource.typed
        let natif = try db.store.search(q)
        XCTAssertEqual(natif.totalPages, 1)
        XCTAssertEqual(natif.hits.map(\.page), [1])
        q.sources = PageSource.scanned
        let scanne = try db.store.search(q)
        XCTAssertEqual(scanne.totalPages, 1)
        XCTAssertEqual(scanne.hits.map(\.page), [2])
    }

    // MARK: - Facettes et comptage par document

    func testLesFacettesSuiventLeFiltre() throws {
        let c = try fixture()
        let q = try query("enthalpie", sources: PageSource.scanned)
        let origine = Dictionary(uniqueKeysWithValues:
                                    try c.db.store.facets(q, by: .source))
        XCTAssertEqual(origine, ["ocr_accurate": 3],
                       "la facette « Origine du texte » ne compte plus que ce "
                       + "que le filtre laisse passer")
        let dossiers = Dictionary(uniqueKeysWithValues:
                                    try c.db.store.facets(q, by: .folder))
        XCTAssertEqual(dossiers, ["Livres": 2, "Cours": 1])
    }

    func testLeComptageParDocumentSuitLeFiltre() throws {
        let c = try fixture()
        let counts = try c.db.store.matchedPageCounts(
            try query("enthalpie", sources: PageSource.scanned),
            excludingDocsMatching: nil)
        XCTAssertEqual(counts, [c.scanne: 2, c.mixte: 1],
                       "« n pages touchées » compte les pages que le filtre "
                       + "garde, sinon l'annonce contredit la liste")
    }

    // MARK: - Composition avec les autres filtres

    func testLExclusionParDocumentResteRespectee() throws {
        let c = try fixture()
        let q = try query("enthalpie", sources: PageSource.scanned)
        let r = try c.db.store.search(q, excludingDocsMatching: "recopiee")
        XCTAssertEqual(pages(r), [Schema.ftsRowID(docID: c.mixte, page: 2)],
                       "`-recopiee` écarte le DOCUMENT entier (T5) ; le filtre "
                       + "de provenance ne le rattrape pas")
    }

    func testSeCombineAvecLeFiltreDeDossier() throws {
        let c = try fixture()
        var q = try query("enthalpie", sources: PageSource.scanned)
        q.folders = ["Cours"]
        let r = try c.db.store.search(q)
        XCTAssertEqual(pages(r), [Schema.ftsRowID(docID: c.mixte, page: 2)])
        XCTAssertEqual(r.totalPages, 1)
    }

    // MARK: - Le prédicat pur, celui que le canal vectoriel emploie

    func testLePredicatPurAccepteEtRefuse() throws {
        var q = try query("enthalpie")
        XCTAssertTrue(q.keeps(.native))
        XCTAssertTrue(q.keeps(.ocrAccurate))
        q.sources = PageSource.scanned
        XCTAssertFalse(q.keeps(.native))
        XCTAssertTrue(q.keeps(.ocrAccurate))
        q.sources = PageSource.typed
        XCTAssertTrue(q.keeps(.native))
        XCTAssertFalse(q.keeps(.ocrAccurate))
    }

    // MARK: - La TROISIÈME provenance : la transcription (lot INT-F3)

    /// Une page transcrite depuis un enregistrement n'est ni tapée ni scannée.
    /// Les trois ensembles partitionnent l'énumération : demander « scanné » ne
    /// doit PAS rendre une transcription, et l'inverse non plus.
    func testTranscriptionEstUneTroisiemeProvenance() throws {
        let db = try makeDB()
        let media = try addDoc(db, relPath: "Users/a/Cours/conference.m4a")
        try db.store.replacePages(docID: media, pages: [
            // Page 1 : les métadonnées, portées par le fichier — du natif.
            page(1, "enthalpie de la conference"),
            page(2, "enthalpie prononcee a voix haute", .transcript),
        ])

        let q = try query("enthalpie", sources: PageSource.transcribed)
        let filter = GRDBStore.sourceFilter(q, docID: "d", page: "p")
        XCTAssertTrue(filter.join.hasPrefix(" JOIN page_src pf ON "), filter.join)
        XCTAssertEqual(filter.sql, " AND pf.src IN (3)")

        let transcrit = try db.store.search(q)
        XCTAssertEqual(pages(transcrit), [Schema.ftsRowID(docID: media, page: 2)])
        XCTAssertTrue(transcrit.hits.allSatisfy { $0.source == .transcript })

        // Ni le scan ni le natif ne l'attrapent.
        let scanne = try db.store.search(
            try query("enthalpie", sources: PageSource.scanned))
        XCTAssertTrue(scanne.hits.isEmpty)
        let natif = try db.store.search(
            try query("enthalpie", sources: PageSource.typed))
        XCTAssertEqual(pages(natif), [Schema.ftsRowID(docID: media, page: 1)])

        // L'étiquette publiée par la CLI, le MCP et les facettes.
        XCTAssertEqual(GRDBStore.sourceLabel(PageSource.transcript.rawValue),
                       "transcript")
        XCTAssertFalse(q.keeps(.native))
        XCTAssertFalse(q.keeps(.ocrAccurate))
        XCTAssertTrue(q.keeps(.transcript))
    }
}
