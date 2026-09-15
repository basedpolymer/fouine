// TypedFormBoostTests.swift — la sonde « forme tapée présente » du lot P1.
// Propriété : A-Core.
//
// Ce que ces tests prouvent : la morphologie du lot R1 fait ENTRER des pages
// qui ne portent que la déclinaison (`entropies` pour `entropie`) — c'est son
// but —, et cette sonde-ci les fait passer DERRIÈRE celles qui portent le mot
// tel qu'il a été tapé. Comme les bonus du lot M1, elle ne change QUE L'ORDRE :
// chaque cas vérifie que le jeu de pages, les totaux et les facettes ne
// bougent pas.

import XCTest
@testable import FouineCore

final class TypedFormBoostTests: XCTestCase {

    /// La même requête, avec et sans la sonde.
    private func ranks(_ db: TempDB, _ input: String,
                       fuzzy: FuzzyMode = .off,
                       rankingBoosts: Bool = true) throws
        -> (without: [(Int64, Int)], with: [(Int64, Int)]) {
        var q = try query(input, fuzzy: fuzzy)
        q.rankingBoosts = rankingBoosts
        q.typedFormBoost = false
        let without = try db.store.search(q).hits.map { ($0.docID, $0.page) }
        q.typedFormBoost = true
        let with = try db.store.search(q).hits.map { ($0.docID, $0.page) }
        return (without, with)
    }

    /// Le SQL des sondes d'une requête, pour lire ce qui est ÉMIS et non
    /// seulement son effet : une sonde inutile coûte une exécution FTS.
    private func probeSQL(_ q: SearchQuery, matchedPages: Int = 0) -> String {
        GRDBStore.probeCTEs(GRDBStore.rankingProbes(for: q, matchedPages: matchedPages))
    }

    // MARK: - Le cas nominal

    /// Deux pages de même longueur et de même fréquence : l'une écrit le mot au
    /// pluriel, l'autre au singulier tel qu'il a été tapé. Sans la sonde, bm25
    /// les classe à l'identique et c'est le rowid qui départage ; avec, la page
    /// du mot tapé passe devant.
    func testThePageCarryingTheTypedWordComesFirst() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Cours/notes.pdf")
        let filler = Array(repeating: "remplissage", count: 30).joined(separator: " ")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "polymeres \(filler)"),
            page(2, "polymere \(filler)"),
        ])

        let (without, with) = try ranks(db, "polymere")
        XCTAssertEqual(without.map(\.1), [1, 2],
                       "sans la sonde, le rowid départage deux scores égaux")
        XCTAssertEqual(with.map(\.1), [2, 1],
                       "la page qui porte le mot TAPÉ passe devant sa déclinaison")
        XCTAssertEqual(Set(without.map(\.1)), Set(with.map(\.1)),
                       "la sonde ne change QUE l'ordre : mêmes pages")
    }

    /// Le pluriel tapé est le mot tapé : c'est la page en « polymeres » qui
    /// monte, pas celle du singulier. La sonde suit la SAISIE, pas une forme
    /// canonique.
    func testTheProbeFollowsWhatWasTypedNotACanonicalForm() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Cours/notes.pdf")
        let filler = Array(repeating: "remplissage", count: 30).joined(separator: " ")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "polymeres \(filler)"),
            page(2, "polymere \(filler)"),
        ])
        let (_, with) = try ranks(db, "polymeres")
        XCTAssertEqual(with.map(\.1), [1, 2],
                       "« polymeres » tapé : c'est la page au pluriel qui monte")
    }

    /// Deux mots dont un seul se décline (`gaz` n'a ni pluriel ni singulier à
    /// proposer) : la sonde porte quand même les DEUX, avec le même ET que la
    /// requête. Les bonus du lot M1 sont désarmés pour n'observer qu'elle.
    func testTheProbeCarriesEveryTypedWordEvenWhenOnlyOneInflects() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Cours/notes.pdf")
        let filler = Array(repeating: "remplissage", count: 30).joined(separator: " ")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "polymeres gaz \(filler)"),
            page(2, "polymere gaz \(filler)"),
        ])

        let q = try query("polymere gaz")
        let probes = try XCTUnwrap(GRDBStore.rankingProbes(for: q))
        XCTAssertEqual(probes.typedForm, "\"polymere\" AND \"gaz\"",
                       "les deux mots tapés, repliés, avec le ET de la requête")

        let (without, with) = try ranks(db, "polymere gaz", rankingBoosts: false)
        XCTAssertEqual(without.map(\.1), [1, 2])
        XCTAssertEqual(with.map(\.1), [2, 1])
    }

    // MARK: - Ce qui n'émet AUCUNE sonde

    /// Rien de décliné, rien à départager : la sonde vaudrait pour toutes les
    /// pages du jeu, c'est-à-dire un facteur constant payé d'une exécution FTS.
    func testNoProbeWhenMorphologyAddedNothing() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Cours/notes.pdf")
        try db.store.replacePages(docID: doc, pages: [page(1, "le gaz est parfait")])

        // « gaz » : trop court pour perdre un s, et un mot en -z ne prend pas
        // de pluriel (`Morphology`).
        let q = try query("gaz")
        XCTAssertEqual(Morphology.variants(of: "gaz"), [])
        XCTAssertNil(GRDBStore.rankingProbes(for: q)?.typedForm)
        XCTAssertFalse(probeSQL(q).contains("tf AS"),
                       "aucune CTE tf quand rien n'est décliné")
    }

    /// Les deux interrupteurs, chacun de son côté.
    func testBothSwitchesSilenceTheProbe() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Cours/notes.pdf")
        try db.store.replacePages(docID: doc, pages: [page(1, "les polymeres")])

        var q = try query("polymere")
        XCTAssertTrue(probeSQL(q).contains("tf AS"), "armée par défaut")

        q.typedFormBoost = false
        XCTAssertFalse(probeSQL(q).contains("tf AS"), "--no-typed-form")

        q.typedFormBoost = true
        q.morphology = false
        XCTAssertFalse(probeSQL(q).contains("tf AS"),
                       "sans morphologie, il n'y a plus de déclinaison à départager")

        // `--raw-fts` : aucun terme analysé, donc aucune sonde (AUDIT-R1 I1).
        let raw = SearchQuery(terms: [], fts: "polymere", fuzzy: .off)
        XCTAssertNil(GRDBStore.rankingProbes(for: raw))
    }

    /// Le garde-fou de coût des sondes, partagé avec celles du lot M1 : au-delà
    /// du seuil de comptage approché, plus aucune n'est payée, et l'ordre est
    /// celui d'avant.
    func testTheProbeIsDisarmedAboveTheCountingThreshold() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Cours/notes.pdf")
        let filler = Array(repeating: "remplissage", count: 30).joined(separator: " ")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "polymeres \(filler)"),
            page(2, "polymere \(filler)"),
        ])

        var q = try query("polymere")
        q.approximateThreshold = 1
        XCTAssertNil(GRDBStore.rankingProbes(for: q, matchedPages: 1),
                     "un compte ÉGAL au seuil signifie « au moins autant »")
        XCTAssertEqual(try db.store.search(q).hits.map(\.page), [1, 2],
                       "au-delà du seuil, l'ordre est celui du rowid")
    }

    /// Une page trouvée par VARIANTE FLOUE ne reçoit rien : la sonde part des
    /// mots tapés, et cette page est déjà pénalisée par son `1/(1+d)`.
    func testAPageFoundThroughAFuzzyVariantGetsNoBoost() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Scans/scan.pdf")
        try db.store.completeOCR(docID: doc, page: 1,
                                 result: ocrPage("les thermodynamiques sont ici"))
        try db.store.completeOCR(docID: doc, page: 2,
                                 result: ocrPage("la thermodynamlque est ici"))
        try db.store.completeOCR(docID: doc, page: 3,
                                 result: ocrPage("la thermodynamique est ici"))
        try TrigramExpander(store: db.store).warm()

        var q = try query("thermodynamique", fuzzy: .on)
        let with = try db.store.search(q).hits
        XCTAssertEqual(with.first?.page, 3, "la page du mot tapé passe devant")
        q.typedFormBoost = false
        let without = try db.store.search(q).hits
        XCTAssertEqual(Set(with.map(\.page)), Set(without.map(\.page)),
                       "mêmes pages avec et sans")
        XCTAssertEqual(with.first { $0.page == 2 }?.score ?? 0,
                       without.first { $0.page == 2 }?.score ?? -1, accuracy: 1e-9,
                       "la page trouvée par variante floue garde son score")
    }

    // MARK: - Ce que la sonde ne touche pas

    func testTotalsFacetsAndPageCountsAreUntouched() throws {
        let db = try makeDB()
        let book = try addDoc(db, relPath: "Users/alice/Livres/traite.pdf", folder: "Livres")
        let note = try addDoc(db, relPath: "Users/alice/Cours/note.pdf", folder: "Cours")
        try db.store.replacePages(docID: book, pages: [
            page(1, "les polymeres"), page(2, "le polymere"), page(3, "des polymeres"),
        ])
        try db.store.replacePages(docID: note, pages: [page(1, "un polymere")])

        var q = try query("polymere")
        let with = try db.store.search(q)
        let withFacets = try db.store.facets(q, by: .folder)
        let withCounts = try db.store.matchedPageCounts(q, excludingDocsMatching: nil)
        q.typedFormBoost = false
        let without = try db.store.search(q)
        let withoutFacets = try db.store.facets(q, by: .folder)
        let withoutCounts = try db.store.matchedPageCounts(q, excludingDocsMatching: nil)

        XCTAssertEqual(with.totalPages, 4)
        XCTAssertEqual(with.totalPages, without.totalPages)
        XCTAssertEqual(with.totalDocs, without.totalDocs)
        XCTAssertEqual(withFacets.map(\.0).sorted(), withoutFacets.map(\.0).sorted())
        XCTAssertEqual(withFacets.map(\.1).sorted(), withoutFacets.map(\.1).sorted())
        XCTAssertEqual(withCounts, withoutCounts)
        XCTAssertEqual(withCounts[book], 3)
        XCTAssertEqual(Set(with.hits.map { "\($0.docID)/\($0.page)" }),
                       Set(without.hits.map { "\($0.docID)/\($0.page)" }))
    }

    /// La pagination reste disjointe et complète avec la sonde : elle vit dans
    /// la même couche `gb` que les bonus du lot M1, avant `LIMIT`/`OFFSET`.
    func testPaginationStaysDisjointWithTheProbe() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Livres/traite.pdf")
        try db.store.replacePages(docID: doc, pages: (1...6).map {
            page($0, $0.isMultiple(of: 2) ? "le polymere ici" : "les polymeres ici")
        })
        var q = try query("polymere", limit: 3)
        let first = try db.store.search(q).hits.map(\.page)
        q.offset = 3
        let second = try db.store.search(q).hits.map(\.page)
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(second.count, 3)
        XCTAssertEqual(Set(first).intersection(second), [], "aucune page en double")
        XCTAssertEqual(Set(first).union(second).count, 6, "aucune page perdue")
        XCTAssertEqual(Set(first), [2, 4, 6],
                       "les trois pages du mot tapé occupent la première tranche")
    }

    /// La sonde et les bonus du lot M1 se cumulent, et le facteur est bien
    /// celui de `Schema` : un score exactement multiplié par 1,5.
    func testTheBoostIsTheDocumentedFactor() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Cours/notes.pdf")
        try db.store.replacePages(docID: doc, pages: [page(1, "le polymere ici")])
        var q = try query("polymere")
        let with = try XCTUnwrap(try db.store.search(q).hits.first?.score)
        q.typedFormBoost = false
        let without = try XCTUnwrap(try db.store.search(q).hits.first?.score)
        XCTAssertEqual(with, without * (1 + Schema.typedFormBoost), accuracy: 1e-9)
    }
}
