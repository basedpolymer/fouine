// RankingBoostTests.swift — bonus de classement du lot M1 : proximité à deux
// paliers (D-R2, idée R-01) et nom du document (D-R3, idée R-02).
// Propriété : A-Core.
//
// Ce que ces tests prouvent, et pourquoi c'est le bon niveau : les trois bonus
// ne changent QUE L'ORDRE. Aucun n'ajoute ni ne retire une page, aucun ne
// touche un comptage ni une facette. Chaque cas construit donc un corpus où
// les mêmes pages sortent avant comme après, et ne regarde que leur RANG.

import XCTest
@testable import FouineCore

final class RankingBoostTests: XCTestCase {

    /// La même requête, avec et sans les bonus.
    private func ranks(_ db: TempDB, _ input: String,
                       fuzzy: FuzzyMode = .off) throws
        -> (before: [(Int64, Int)], after: [(Int64, Int)]) {
        var q = try query(input, fuzzy: fuzzy)
        q.rankingBoosts = false
        let before = try db.store.search(q).hits.map { ($0.docID, $0.page) }
        q.rankingBoosts = true
        let after = try db.store.search(q).hits.map { ($0.docID, $0.page) }
        return (before, after)
    }

    // MARK: - D-R2 : la phrase devant la paire dispersée

    /// Deux pages du MÊME document portent les deux mots ; l'une les porte
    /// collés, l'autre séparés par une trentaine de mots. Sans bonus, bm25 les
    /// classe à l'identique (mêmes termes, longueurs voisines) et c'est le
    /// rowid qui départage ; avec, la page en phrase passe devant.
    func testAConsecutivePhraseBeatsTheSameWordsScatteredOnThePage() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Cours/notes.pdf")
        let filler = Array(repeating: "remplissage", count: 30).joined(separator: " ")
        try db.store.replacePages(docID: doc, pages: [
            // Page 1 : les deux mots à trente mots l'un de l'autre.
            page(1, "energie \(filler) libre"),
            // Page 2 : les deux mots collés.
            page(2, "energie libre \(filler)"),
        ])

        let (before, after) = try ranks(db, "energie libre")
        XCTAssertEqual(before.map(\.1), [1, 2],
                       "sans bonus, le rowid départage : la page 1 d'abord")
        XCTAssertEqual(after.map(\.1), [2, 1],
                       "avec le bonus de phrase, la page qui porte l'expression passe devant")
    }

    /// Le palier intermédiaire : à moins de `proximityWindow` jetons, sans être
    /// collés. La page voisine passe devant la page dispersée, et derrière la
    /// page en phrase (les deux bonus se cumulent : ×2,2 contre ×1,4).
    func testTheNearBoostSitsBetweenPhraseAndScattered() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Cours/notes.pdf")
        let far = Array(repeating: "remplissage", count: 50).joined(separator: " ")
        let close = Array(repeating: "remplissage", count: 4).joined(separator: " ")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "energie \(far) libre"),
            page(2, "energie \(close) libre \(far)"),
            page(3, "energie libre \(close) \(far)"),
        ])

        let (before, after) = try ranks(db, "energie libre")
        XCTAssertEqual(before.map(\.1), [1, 2, 3],
                       "sans bonus, l'ordre est celui du rowid (scores très voisins)")
        XCTAssertEqual(after.map(\.1), [3, 2, 1],
                       "phrase, puis voisinage, puis dispersé")
        XCTAssertEqual(Set(before.map(\.1)), Set(after.map(\.1)),
                       "les bonus ne changent QUE l'ordre : mêmes pages")
    }

    /// La fenêtre du NEAR est bien celle de `Schema.proximityWindow` : à un mot
    /// de plus, le bonus tombe.
    func testTheNearWindowIsTheDocumentedOne() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Cours/notes.pdf")
        let inside = Array(repeating: "mot", count: Schema.proximityWindow - 1)
            .joined(separator: " ")
        let outside = Array(repeating: "mot", count: Schema.proximityWindow + 1)
            .joined(separator: " ")
        let tail = Array(repeating: "remplissage", count: 40).joined(separator: " ")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "energie \(outside) libre \(tail)"),
            page(2, "energie \(inside) libre \(tail)"),
        ])

        let (_, after) = try ranks(db, "energie libre")
        XCTAssertEqual(after.map(\.1), [2, 1],
                       "seule la page dont les mots tiennent dans la fenêtre est promue")
    }

    // MARK: - D-R2 : ce qui ne reçoit AUCUN bonus

    /// Une page trouvée par VARIANTE FLOUE ne reçoit pas le bonus : les sondes
    /// partent des termes exacts, et cette page est déjà pénalisée par
    /// `1/(1+d)`. Ici, deux pages portent l'expression ; l'une l'écrit
    /// correctement, l'autre avec une coquille d'OCR.
    func testAPageFoundThroughAFuzzyVariantGetsNoBoost() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Cours/notes.pdf")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "thermodynamlque chimique appliquee", .ocrAccurate),
            page(2, "thermodynamique chimique appliquee", .ocrAccurate),
        ])
        try TrigramExpander(store: db.store).warm()

        var q = try query("thermodynamique chimique", fuzzy: .on)
        let hits = try db.store.search(q).hits
        XCTAssertEqual(Set(hits.map(\.page)), [1, 2],
                       "les deux pages sortent : l'une exacte, l'autre par variante")
        XCTAssertEqual(hits.first?.page, 2,
                       "la page exacte, qui SEULE reçoit le bonus, passe devant")

        // Et la variante n'a bien reçu aucun bonus : son score est exactement
        // celui d'avant les bonus.
        q.rankingBoosts = false
        let plain = try db.store.search(q).hits
        let fuzzyBefore = plain.first { $0.page == 1 }?.score
        let fuzzyAfter = hits.first { $0.page == 1 }?.score
        XCTAssertEqual(fuzzyBefore ?? 0, fuzzyAfter ?? -1, accuracy: 1e-9,
                       "la page trouvée par variante garde son score")
    }

    /// Quatre formes de requête où l'utilisateur a DÉJÀ dit ce qu'il voulait :
    /// aucune sonde n'est construite, et l'ordre est celui d'avant le lot M1.
    func testQuotesNearPrefixAndORDisableEveryProbe() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Cours/notes.pdf")
        let filler = Array(repeating: "remplissage", count: 30).joined(separator: " ")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "energie \(filler) libre"),
            page(2, "energie libre \(filler)"),
        ])

        for input in ["\"energie libre\"", "pres:5 energie libre", "energ* libre"] {
            let (before, after) = try ranks(db, input)
            XCTAssertEqual(before.map(\.1), after.map(\.1),
                           "« \(input) » ne doit produire aucune sonde")
        }
        // Le `OR` ne peut pas être TAPÉ (l'analyseur le refuse) mais une
        // `SearchQuery` bâtie à la main — `--raw-fts`, le serveur MCP — le peut.
        let raw = SearchQuery(terms: ["energie", "libre"],
                              fts: "energie OR libre", fuzzy: .off)
        XCTAssertNil(GRDBStore.rankingProbes(for: raw),
                     "un OR dans la chaîne FTS désarme les sondes")
    }

    /// GARDE-FOU DE COÛT : au-delà du seuil de comptage approché, les sondes
    /// sont désarmées. Une sonde de phrase sur deux mots-outils parcourt des
    /// listes de positions gigantesques — 1,3 s de recherche devenaient 2,9 s
    /// sur `the of` (176 000 pages, base réelle du 05/09/2026).
    func testTheProbesAreDisarmedAboveTheApproximateCountThreshold() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Cours/notes.pdf")
        let filler = Array(repeating: "remplissage", count: 30).joined(separator: " ")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "energie \(filler) libre"),
            page(2, "energie libre \(filler)"),
        ])

        var q = try query("energie libre")
        XCTAssertNotNil(GRDBStore.rankingProbes(for: q, matchedPages: 1))
        XCTAssertEqual(try db.store.search(q).hits.map(\.page), [2, 1])

        // Deux pages appariées, un seuil à 2 : `counts()` borne son résultat au
        // seuil, donc « au moins 2 » — le cas que le garde-fou écarte.
        q.approximateThreshold = 2
        XCTAssertNil(GRDBStore.rankingProbes(for: q, matchedPages: 2))
        XCTAssertEqual(try db.store.search(q).hits.map(\.page), [1, 2],
                       "au-dessus du seuil, l'ordre est celui d'avant le lot M1")
    }

    /// L'interrupteur rend EXACTEMENT le classement d'avant, scores compris.
    func testNoProximityRestoresTheFormerOrderAndScores() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Cours/notes.pdf")
        let filler = Array(repeating: "remplissage", count: 30).joined(separator: " ")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "energie \(filler) libre"),
            page(2, "energie libre \(filler)"),
        ])
        var off = try query("energie libre")
        off.rankingBoosts = false
        let hits = try db.store.search(off).hits
        XCTAssertEqual(hits.map(\.page), [1, 2])
        // Le score reste celui de bm25, sans facteur.
        for hit in hits { XCTAssertLessThan(hit.score, 0) }
    }

    /// Les comptages, les facettes et le comptage par document ne bougent PAS.
    func testCountsAndFacetsAreUntouchedByTheBoosts() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Cours/energie.pdf")
        let filler = Array(repeating: "remplissage", count: 30).joined(separator: " ")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "energie \(filler) libre"),
            page(2, "energie libre \(filler)"),
        ])
        var on = try query("energie libre")
        var off = on
        off.rankingBoosts = false

        XCTAssertEqual(try db.store.search(on).totalPages,
                       try db.store.search(off).totalPages)
        XCTAssertEqual(try db.store.search(on).totalDocs,
                       try db.store.search(off).totalDocs)
        XCTAssertEqual(try db.store.facets(on, by: .folder).map(\.1),
                       try db.store.facets(off, by: .folder).map(\.1))
        XCTAssertEqual(
            try db.store.matchedPageCounts(on, excludingDocsMatching: nil),
            try db.store.matchedPageCounts(off, excludingDocsMatching: nil))
        on.limit = 1
        XCTAssertEqual(try db.store.search(on).totalPages, 2,
                       "un LIMIT ne rogne pas les totaux, bonus ou non")
    }

    // MARK: - D-R3 : le nom du document

    /// Le document DONT LE NOM porte le mot passe devant celui qui ne le cite
    /// qu'une fois dans son texte, à contenu de page comparable.
    func testADocumentNamedAfterTheQueryComesFirst() throws {
        let db = try makeDB()
        let named = try addDoc(db, relPath: "Users/alice/Cours/Thermodynamique.pdf")
        let other = try addDoc(db, relPath: "Users/alice/Cours/divers.pdf")
        let body = "la thermodynamique chimique y est citee une fois seulement"
        try db.store.replacePages(docID: named, pages: [page(1, body)])
        try db.store.replacePages(docID: other, pages: [page(1, body)])

        let (before, after) = try ranks(db, "thermodynamique chimique")
        XCTAssertEqual(before.map(\.0), [named, other],
                       "à scores égaux, le rowid départage")
        XCTAssertEqual(after.first?.0, named,
                       "le bonus de nom fait passer le document ainsi nommé devant")

        // Le même corpus, mais c'est l'AUTRE document qui porte le nom : la
        // preuve que c'est bien le nom qui agit, et non l'ordre d'insertion.
        let db2 = try makeDB()
        let plain = try addDoc(db2, relPath: "Users/alice/Cours/divers.pdf")
        let titled = try addDoc(db2, relPath: "Users/alice/Cours/Thermodynamique.pdf")
        try db2.store.replacePages(docID: plain, pages: [page(1, body)])
        try db2.store.replacePages(docID: titled, pages: [page(1, body)])
        let (_, after2) = try ranks(db2, "thermodynamique chimique")
        XCTAssertEqual(after2.first?.0, titled)
    }

    /// Le DOSSIER parent compte autant que le fichier : « M2SU/chap3.pdf » ne
    /// dit rien par son nom de fichier et tout par son dossier.
    func testTheParentFolderNameCountsToo() throws {
        let db = try makeDB()
        let inFolder = try addDoc(db, relPath: "Users/alice/Cours/Thermodynamique/chap3.pdf")
        let elsewhere = try addDoc(db, relPath: "Users/alice/Cours/divers/chap3.pdf")
        let body = "la thermodynamique chimique y est citee une fois seulement"
        try db.store.replacePages(docID: inFolder, pages: [page(1, body)])
        try db.store.replacePages(docID: elsewhere, pages: [page(1, body)])

        let (_, after) = try ranks(db, "thermodynamique chimique")
        XCTAssertEqual(after.first?.0, inFolder)
    }

    /// Un mot seul ne déclenche AUCUNE des trois sondes du lot M1, nom compris.
    /// La première version accordait le bonus de nom dès un mot ; sur la base
    /// réelle, il faisait occuper les 50 premières pages par le seul livre dont
    /// le titre portait le mot (`polymere` : 50/50 ; `thermodynamique` : 42/50)
    /// — les autres documents disparaissaient de l'écran. Décision du
    /// propriétaire, 05/09/2026. La sonde « forme tapée » du lot P1, elle, agit
    /// dès un mot : elle porte sur la PAGE, pas sur le document, et ne peut donc
    /// pas faire monter un livre entier d'un bloc.
    func testASingleWordQueryGetsNoBoostAtAll() throws {
        let db = try makeDB()
        // `other` d'abord : à scores égaux le rowid le plus bas passe devant,
        // et seul un bonus de nom indûment appliqué ferait passer `named`.
        let other = try addDoc(db, relPath: "Users/alice/Cours/divers.pdf")
        let named = try addDoc(db, relPath: "Users/alice/Cours/Polymere.pdf")
        let body = "le polymere y est cite une fois seulement dans la page"
        try db.store.replacePages(docID: other, pages: [page(1, body)])
        try db.store.replacePages(docID: named, pages: [page(1, body)])

        let probes = GRDBStore.rankingProbes(for: try query("polymere"))
        XCTAssertNil(probes?.phrase, "un seul mot : rien à mettre en phrase")
        XCTAssertNil(probes?.near, "un seul mot : rien à rapprocher")
        XCTAssertNil(probes?.name, "un seul mot : pas de bonus de nom (le débordement)")
        XCTAssertEqual(probes?.typedForm, "\"polymere\"",
                       "seule la sonde du lot P1 reste, et elle porte sur la page")

        let (before, after) = try ranks(db, "polymere")
        XCTAssertEqual(before.map(\.0), after.map(\.0),
                       "sans sonde, l'ordre est celui de bm25 seul")
        XCTAssertEqual(after.first?.0, other,
                       "à scores égaux, le rowid départage : le nom n'a pas agi")
    }

    /// Le nom indexé : dernier composant sans extension, puis dossier parent.
    func testTheIndexedNameIsTheFileAndItsFolderWithoutTheExtension() {
        XCTAssertEqual(
            Schema.documentIndexName(relPath: "Users/alice/Cours/M2SU/Thermodynamique.pdf"),
            "Thermodynamique M2SU")
        XCTAssertEqual(Schema.documentIndexName(relPath: "notes.txt"), "notes")
        XCTAssertEqual(Schema.documentIndexName(relPath: "Cours/notes.tar.gz"),
                       "notes.tar Cours")
        XCTAssertEqual(Schema.documentIndexName(relPath: ""), "")
    }

    // MARK: - `docs_fts` suit `docs`

    func testDocsFTSFollowsUpsertRemoveAndRelocate() throws {
        let db = try makeDB()
        let id = try addDoc(db, relPath: "Users/alice/Cours/M2SU/chimie.pdf")
        XCTAssertEqual(try db.store.rawStrings("SELECT name FROM docs_fts"),
                       ["chimie M2SU"])
        XCTAssertEqual(try db.store.rawInt64s("SELECT rowid FROM docs_fts"), [id])

        // Déplacement : le nom ET le dossier changent, dans la même transaction.
        try db.store.relocateDocs([DocRelocation(
            id: id, relPath: "Users/alice/Livres/Polymeres/chimie.pdf",
            topFolder: "Livres", ext: "pdf", inode: 0)])
        XCTAssertEqual(try db.store.rawStrings("SELECT name FROM docs_fts"),
                       ["chimie Polymeres"])
        XCTAssertEqual(try db.store.rawInt64s("SELECT count(*) FROM docs_fts"), [1],
                       "un déplacement ne dédouble pas la ligne")

        // Un second document, puis la suppression du premier.
        let other = try addDoc(db, relPath: "Users/alice/Livres/atlas.pdf")
        XCTAssertEqual(try db.store.rawInt64s("SELECT count(*) FROM docs_fts"), [2])
        try db.store.removeDoc(id: id)
        XCTAssertEqual(try db.store.rawInt64s("SELECT rowid FROM docs_fts"), [other])
    }

    /// Un document réécrit (taille et date changées) garde UNE ligne de nom.
    func testRewritingADocumentKeepsExactlyOneName() throws {
        let db = try makeDB()
        let id = try addDoc(db, relPath: "Users/alice/Cours/chimie.pdf")
        _ = try db.store.upsertDoc(DocRecord(
            volUUID: "TEST-VOL", relPath: "Users/alice/Cours/chimie.pdf",
            ext: "pdf", topFolder: "Livres", size: 2_000, mtime: 1_800_000_000))
        XCTAssertEqual(try db.store.rawInt64s("SELECT count(*) FROM docs_fts"), [1])
        XCTAssertEqual(try db.store.rawInt64s("SELECT rowid FROM docs_fts"), [id])
    }

    /// `maintain --repair` reconstruit la table, et `doctor --deep` voit l'écart.
    func testRepairRebuildsDocsFTSAndTheDeepCheckSeesTheGap() throws {
        let db = try makeDB()
        _ = try addDoc(db, relPath: "Users/alice/Cours/chimie.pdf")
        _ = try addDoc(db, relPath: "Users/alice/Cours/physique.pdf")
        XCTAssertTrue(try db.store.checkDocumentNames().consistent)

        // On casse la table à la main, comme le ferait une base rattrapée
        // hors du produit.
        try db.store.writeLocked { db in try db.execute(sql: "DELETE FROM docs_fts") }
        let broken = try db.store.checkDocumentNames()
        XCTAssertEqual(broken.docs, 2)
        XCTAssertEqual(broken.names, 0)
        XCTAssertFalse(broken.consistent)

        XCTAssertEqual(try db.store.rebuildDocumentNames().names, 2)
        XCTAssertTrue(try db.store.checkDocumentNames().consistent)
        XCTAssertEqual(
            try db.store.rawStrings("SELECT name FROM docs_fts ORDER BY name"),
            ["chimie Cours", "physique Cours"])
    }
}
