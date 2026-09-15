// PathFilterTests.swift — `chemin:` et les quatre exclusions de filtres
// (lot MC1). Propriété : A-Core. SPEC §5.5.1.
//
// Ce que ces tests prouvent, et pourquoi. Retour d'usage du 13/09/2026 sur la
// base de production : `-nom:Pourvue` et `-ext:md` étaient ACCEPTÉS SANS EFFET
// (un `NOT "nom:Pourvue"` que FTS5 n'apparie jamais), et `nom:Offres` ne
// rendait que 6 des ~160 documents rangés sous `Stage/Offres/…` parce que
// `docs_fts` n'indexe que le nom du fichier et celui de son dossier parent.
// Un filtre qui ment est pire qu'un filtre absent : le résultat a l'air juste.
//
// Trois invariants les accompagnent : le canal du SENS voit le même jeu de
// documents que le canal des mots, la forme Unicode de la saisie ne change
// rien, et à champs vides le SQL est celui d'avant, au caractère près.

import XCTest
@testable import FouineCore

final class PathFilterTests: XCTestCase {

    private struct Corpus {
        let db: TempDB
        let pourvue: Int64, notes: Int64, reacteur: Int64, brouillon: Int64
    }

    /// Deux documents sous `Stage/Offres/`, un sous `Livres/Polymères/` (le
    /// dossier accentué du constat), un dans `Cours`. Tous portent « azote » :
    /// c'est le terme positif qui permet de mesurer ce que l'exclusion retire.
    private func fixture() throws -> Corpus {
        let db = try makeDB()
        let pourvue = try addDoc(db, relPath: "Users/a/Stage/Offres/pourvue.md",
                                 ext: "md", folder: "Stage")
        // PLUS PROFOND d'un cran : son dossier PARENT est « 2026 », et
        // `docs_fts` n'indexe que le nom du fichier et celui de son parent —
        // c'est exactement le document que `nom:Offres` ne trouvait pas.
        let notes = try addDoc(db, relPath: "Users/a/Stage/Offres/2026/notes.pdf",
                               folder: "Stage")
        let reacteur = try addDoc(db, relPath: "Users/a/Livres/Polymères/reacteur.pdf",
                                  folder: "Livres")
        let brouillon = try addDoc(db, relPath: "Users/a/Cours/brouillon.pdf",
                                   folder: "Cours")
        try db.store.replacePages(docID: pourvue, pages: [page(1, "azote, offre pourvue")])
        try db.store.replacePages(docID: notes, pages: [page(1, "azote et notes de stage")])
        try db.store.replacePages(docID: reacteur, pages: [
            page(1, "azote dans le reacteur"),
            page(2, "le sejour dans un reacteur reel"),
        ])
        try db.store.replacePages(docID: brouillon, pages: [page(1, "azote en vrac")])
        return Corpus(db: db, pourvue: pourvue, notes: notes,
                      reacteur: reacteur, brouillon: brouillon)
    }

    private func docs(_ c: Corpus, _ input: String) throws -> Set<Int64> {
        let (q, negative) = try QueryParser.searchPlan(input, fuzzy: .off)
        return Set(try c.db.store.search(q, excludingDocsMatching: negative)
                    .hits.map(\.docID))
    }

    // MARK: - Les quatre exclusions

    /// `-dossier:Cours` retire le dossier, et rien d'autre.
    func testFolderExclusion() throws {
        let c = try fixture()
        XCTAssertEqual(try docs(c, "azote"),
                       [c.pourvue, c.notes, c.reacteur, c.brouillon])
        XCTAssertEqual(try docs(c, "azote -dossier:Cours"),
                       [c.pourvue, c.notes, c.reacteur])
        XCTAssertEqual(try docs(c, "azote -folder:Cours"),
                       [c.pourvue, c.notes, c.reacteur], "l'alias anglais")
    }

    /// `-ext:md` retire l'extension. C'est le cas EXACT du retour d'usage :
    /// avant le lot MC1, les quatre documents revenaient.
    func testExtensionExclusion() throws {
        let c = try fixture()
        XCTAssertEqual(try docs(c, "azote -ext:md"),
                       [c.notes, c.reacteur, c.brouillon])
    }

    /// `-nom:brouillon` retire les documents dont le NOM répond — la même
    /// mécanique que `nom:`, en négatif.
    func testNameExclusion() throws {
        let c = try fixture()
        XCTAssertEqual(try docs(c, "azote -nom:brouillon"),
                       [c.pourvue, c.notes, c.reacteur])
        XCTAssertEqual(try docs(c, "azote -name:pourvue"),
                       [c.notes, c.reacteur, c.brouillon])
    }

    /// `-chemin:Offres` retire tout un rayon, dossiers intermédiaires compris —
    /// ce que `-nom:` ne sait pas faire.
    func testPathExclusion() throws {
        let c = try fixture()
        XCTAssertEqual(try docs(c, "azote -chemin:Offres"),
                       [c.reacteur, c.brouillon])
        XCTAssertEqual(try docs(c, "azote -path:offres"),
                       [c.reacteur, c.brouillon], "l'alias anglais, casse ignorée")
    }

    // MARK: - `chemin:` positif

    /// Le chemin COMPLET, insensible à la casse ET aux accents : c'est tout
    /// l'intérêt d'une fonction SQL `fold` plutôt qu'un `LIKE`.
    func testPathFilterIgnoresCaseAndAccents() throws {
        let c = try fixture()
        XCTAssertEqual(try docs(c, "azote chemin:Polymères"), [c.reacteur])
        XCTAssertEqual(try docs(c, "azote chemin:polymeres"), [c.reacteur])
        XCTAssertEqual(try docs(c, "azote chemin:POLYMÈRES"), [c.reacteur])
        // `nom:` ne voit que le fichier et son dossier PARENT : c'est la
        // différence que le constat pointait — `nom:Offres` manque le document
        // rangé un cran plus bas, `chemin:Offres` les prend tous les deux.
        XCTAssertEqual(try docs(c, "azote chemin:Offres"), [c.pourvue, c.notes])
        XCTAssertEqual(try docs(c, "azote nom:Offres"), [c.pourvue])
    }

    /// Plusieurs `chemin:` sont TOUS exigés.
    func testSeveralPathFiltersAreAnded() throws {
        let c = try fixture()
        XCTAssertEqual(try docs(c, "azote chemin:Stage chemin:notes"), [c.notes])
        XCTAssertTrue(try docs(c, "azote chemin:Stage chemin:Polymeres").isEmpty)
    }

    /// `chemin:` SEUL rend les documents, comme `nom:` seul : une ligne par
    /// document, l'extrait est le nom du fichier, les totaux comptent des
    /// documents.
    func testPathAloneReturnsDocuments() throws {
        let c = try fixture()
        let results = try c.db.store.search(try query("chemin:Offres"))
        XCTAssertEqual(Set(results.hits.map(\.docID)), [c.pourvue, c.notes])
        XCTAssertEqual(results.totalPages, 2)
        XCTAssertEqual(results.totalDocs, 2)
        XCTAssertEqual(Set(results.hits.map(\.snippet)), ["pourvue.md", "notes.pdf"])
        XCTAssertEqual(results.hits.map(\.page), [1, 1])
        // Les facettes comptent les documents rendus, comme pour `nom:` seul.
        let facets = try c.db.store.facets(try query("chemin:Offres"), by: .ext)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: facets), ["md": 1, "pdf": 1])
        // Et il se combine avec `nom:` sans changer de chemin de code.
        XCTAssertEqual(try c.db.store.search(try query("chemin:Offres nom:notes"))
                        .hits.map(\.docID), [c.notes])
    }

    // MARK: - Forme Unicode

    /// Un accent COLLÉ depuis le Finder arrive décomposé (NFD) ; la base est en
    /// NFC. L'analyseur recompose donc l'entrée, une fois pour toutes.
    func testDecomposedInputIsRecomposed() throws {
        let c = try fixture()
        let nfd = "chemin:Polyme\u{0300}res"
        XCTAssertTrue(RelPath.needsNormalization(nfd), "la fixture doit être en NFD")
        let parsed = try QueryParser.parse("azote " + nfd)
        XCTAssertEqual(parsed.pathContains.count, 1)
        XCTAssertTrue(parsed.pathContains[0].utf8.elementsEqual("Polymères".utf8),
                      "la valeur du filtre est recomposée, en OCTETS")
        XCTAssertEqual(try docs(c, "azote " + nfd), [c.reacteur])
    }

    /// `fouine list --path-contains` et le serveur MCP passent par
    /// `DocumentFilter` : la normalisation est dans le STORE, pas chez eux.
    func testDocumentFilterPathIsNormalised() throws {
        let c = try fixture()
        let nfc = DocumentFilter(pathContains: "Polymères")
        let nfd = DocumentFilter(pathContains: "Polyme\u{0300}res")
        XCTAssertEqual(try c.db.store.countDocuments(nfc), 1)
        XCTAssertEqual(try c.db.store.countDocuments(nfd), 1,
                       "collé depuis `ls`, le même filtre doit rendre le même compte")
        XCTAssertEqual(try c.db.store.listDocuments(nfd, limit: 10).map(\.id),
                       [c.reacteur])
    }

    // MARK: - Refus

    /// `-dossier:Xyz` est confronté aux étiquettes qui existent, comme
    /// `dossier:Xyz` : exclure un dossier inconnu n'exclut rien, en silence.
    func testUnknownExcludedFolderIsRefused() throws {
        let parsed = try QueryParser.parse("azote -dossier:Cour")
        XCTAssertEqual(parsed.folderExcludes, ["Cour"])
        XCTAssertThrowsError(try FolderCheck.resolve(parsed.folderExcludes,
                                                     known: ["Cours", "Livres"])) {
            guard case QueryError.unknownFolder(let asked, _) = $0 else {
                return XCTFail("attendu unknownFolder, reçu \($0)")
            }
            XCTAssertEqual(asked, "Cour")
        }
        // La casse est canonisée, comme pour le filtre positif.
        XCTAssertEqual(try FolderCheck.resolve(["cours"], known: ["Cours"]), ["Cours"])
    }

    /// Une requête faite d'exclusions SEULES ne cherche rien : même refus que
    /// `-biologie` seul.
    func testExclusionsAloneAreRefused() throws {
        for input in ["-ext:md", "-dossier:Cours", "-nom:brouillon",
                      "-chemin:Offres", "-biologie", "-ext:md -dossier:Cours"] {
            XCTAssertThrowsError(try QueryParser.parse(input), input) {
                XCTAssertEqual($0 as? QueryError, .exclusionOnly, input)
            }
        }
        // `chemin:` seul, lui, est une requête entière.
        XCTAssertNoThrow(try QueryParser.parse("chemin:Offres"))
        XCTAssertNoThrow(try QueryParser.parse("chemin:Offres -ext:md"))
    }

    // MARK: - Le SQL ne bouge pas quand on ne demande rien

    func testSQLIsUnchangedWithoutTheNewFields() throws {
        let c = try fixture()
        let plain = try query("azote")
        let filter = c.db.store.docFilter(plain, column: "d", page: "p", negative: nil)
        XCTAssertEqual(filter.join, "")
        XCTAssertEqual(filter.sql, "", "sans chemin ni exclusion, le SQL est "
                       + "celui d'avant le lot MC1, au caractère près")
        XCTAssertTrue(filter.args.isEmpty)
        XCTAssertTrue(GRDBStore.pathAndExcludeClauses(plain, alias: "d").clauses.isEmpty)
        XCTAssertNil(GRDBStore.nameExcludeExpression(plain))

        // Et dès qu'on demande, la clause porte sur `docs`, pas sur les pages.
        let asked = try query("azote chemin:Offres -ext:md")
        let full = c.db.store.docFilter(asked, column: "d", page: "p", negative: nil)
        XCTAssertTrue(full.sql.contains("instr(fold(rel_path), fold(?)) > 0"), full.sql)
        XCTAssertTrue(full.sql.contains("ext NOT IN (?)"), full.sql)
        XCTAssertTrue(full.sql.contains("SELECT id FROM docs WHERE"), full.sql)
        XCTAssertEqual(full.join, "", "aucune jointure de plus")
    }

    // MARK: - La garde du périmètre du sens (lot MN1)

    /// `SearchQuery.filtersDocuments` : la question que la ligne de commande et
    /// le serveur MCP se posaient chacun de leur côté, avec onze conditions
    /// recopiées. Les ONZE champs comptent — un oubli fait payer deux comptes
    /// (240 ms mesurés) ou, à l'inverse, annoncer la couverture GLOBALE d'un
    /// périmètre filtré.
    func testFiltersDocumentsSeesEveryDocumentFilter() throws {
        XCTAssertFalse(try query("azote").filtersDocuments)
        for input in ["azote dossier:Livres", "azote ext:pdf", "azote nom:rapport",
                      "azote chemin:Offres", "azote -dossier:Cours", "azote -ext:md",
                      "azote -nom:brouillon", "azote -chemin:Archive"] {
            XCTAssertTrue(try query(input).filtersDocuments, input)
        }
        var q = try query("azote")
        q.langs = ["fr"]
        XCTAssertTrue(q.filtersDocuments)
        q = try query("azote")
        q.modifiedAfter = 1_700_000_000
        XCTAssertTrue(q.filtersDocuments)
        q = try query("azote")
        q.inDocIDs = [12]
        XCTAssertTrue(q.filtersDocuments)
        // LA PROVENANCE N'EN EST PAS UN : elle porte sur la page, et ne retire
        // aucun document du périmètre.
        q = try query("azote")
        q.sources = [.ocrAccurate]
        XCTAssertFalse(q.filtersDocuments,
                       "un filtre de page ne restreint pas les documents")
    }

    // MARK: - Le canal du sens voit le même jeu

    func testVectorChannelSeesTheSameDocuments() throws {
        let c = try fixture()
        XCTAssertEqual(try c.db.store.docIDsMatchingName(try query("azote chemin:Offres")),
                       [c.pourvue, c.notes])
        XCTAssertEqual(try c.db.store.docIDsMatchingName(try query("azote -ext:md")),
                       [c.notes, c.reacteur, c.brouillon])
        XCTAssertEqual(try c.db.store.docIDsMatchingName(try query("azote -nom:brouillon")),
                       [c.pourvue, c.notes, c.reacteur])
        XCTAssertNil(try c.db.store.docIDsMatchingName(try query("azote")),
                     "sans filtre de nom ni de chemin, le canal du sens voit tout")
        // La fonction que le canal vectoriel appelle aussi, avec ses valeurs
        // par défaut vides : elle rend `nil` quand rien n'est demandé.
        XCTAssertNil(try c.db.store.docIDsMatchingFilters(
            folders: [], exts: [], inDocIDs: [], excludingDocsMatching: nil))
        XCTAssertEqual(try c.db.store.docIDsMatchingFilters(
            folders: [], exts: [], inDocIDs: [], excludingDocsMatching: nil,
            pathContains: ["polymeres"]), [c.reacteur])
        XCTAssertEqual(try c.db.store.docIDsMatchingFilters(
            folders: [], exts: [], inDocIDs: [], excludingDocsMatching: nil,
            extExcludes: ["md"]), [c.notes, c.reacteur, c.brouillon])
    }

    // MARK: - Non-régression

    /// `-terme` reste une exclusion de MOT, par document (arbitrage T5), et
    /// `nom:` reste ce qu'il était.
    func testWordExclusionAndNameFilterAreUnchanged() throws {
        let c = try fixture()
        let (q, negative) = try QueryParser.searchPlan("azote -reacteur")
        XCTAssertEqual(negative, "reacteur")
        XCTAssertTrue(q.folderExcludes.isEmpty)
        XCTAssertTrue(q.nameExcludes.isEmpty)
        XCTAssertEqual(Set(try c.db.store.search(q, excludingDocsMatching: negative)
                            .hits.map(\.docID)),
                       [c.pourvue, c.notes, c.brouillon])
        XCTAssertEqual(try docs(c, "azote nom:brouillon"), [c.brouillon])
        // Une heure et une URL ne deviennent pas des filtres exclus.
        XCTAssertNil(QueryParser.excludedFilter("-10:30"))
        XCTAssertNil(QueryParser.excludedFilter("-biologie"))
        XCTAssertEqual(QueryParser.excludedFilter("-ext:MD")?.value, "MD")
    }
}
