// SearchTests.swift — accents (T3), NOT (T5), NEAR (T2), --in (T12), facettes (T4),
// filtres et pagination. SPEC §4.1, §4.3, §5.5. Propriété : A-Core.

import XCTest
@testable import FouineCore

final class SearchTests: XCTestCase {

    private func fixture() throws -> (TempDB, chimie: Int64, bio: Int64) {
        let db = try makeDB()
        let chimie = try addDoc(db, relPath: "Users/alice/Livres/chimie.pdf",
                                folder: "Livres", mtime: 1_600_000_000)
        let bio = try addDoc(db, relPath: "Users/alice/Cours/bio.docx", ext: "docx",
                             folder: "Cours", mtime: 1_700_000_000)
        try db.store.replacePages(docID: chimie, pages: [
            page(1, "Le polymère est une macromolécule. Chromatographie sur papier."),
            page(2, "Énergie libre F et enthalpie libre G, ou énergie de Gibbs."),
            page(3, "azote et reduction dans un même paragraphe."),
            page(4, "azote suivi de beaucoup de mots inutiles avant la reduction finale"),
        ])
        try db.store.replacePages(docID: bio, pages: [
            page(1, "enthalpie et biologie dans la même page."),
            page(2, "chromatographie appliquée à la biologie."),
        ])
        return (db, chimie, bio)
    }

    // MARK: - T3 : accents

    func testAccentInsensitiveSearch() throws {
        let (db, chimie, _) = try fixture()
        let unaccented = try db.store.search(try query("polymere"))
        let accented = try db.store.search(try query("polymère"))
        XCTAssertEqual(unaccented.totalPages, 1)
        XCTAssertEqual(unaccented.hits.first?.docID, chimie)
        XCTAssertEqual(unaccented.hits.first?.page, 1)
        XCTAssertEqual(accented.hits.map(\.page), unaccented.hits.map(\.page),
                       "T3 : « polymere » et « polymère » rendent les mêmes pages")
        XCTAssertTrue(unaccented.hits[0].snippet.contains("«"),
                      "snippet(page_fts, 0, '«', '»', '…', 12) attendu")
    }

    // MARK: - T5 : exclusion (par DOCUMENT — arbitrage post-recette)

    func testNOTExcludesTheWholeDocument() throws {
        let (db, chimie, _) = try fixture()
        let all = try db.store.search(try query("enthalpie"))
        XCTAssertEqual(all.totalPages, 2)
        let (q, negative) = try QueryParser.searchPlan("enthalpie -biologie",
                                                       fuzzy: .off)
        let filtered = try db.store.search(q, excludingDocsMatching: negative)
        XCTAssertEqual(filtered.totalPages, 1)
        XCTAssertEqual(filtered.hits.first?.docID, chimie)
        // Le cas discriminant (« biologie » sur une AUTRE page du document)
        // est couvert par FixRegressionTests.testNegativeTermExcludesTheWholeDocument.
    }

    // MARK: - T2 : proximité

    func testNEARRespectsDistance() throws {
        let (db, chimie, _) = try fixture()
        let close = try db.store.search(try query("pres:10 energie libre gibbs"))
        XCTAssertEqual(close.hits.first?.docID, chimie)
        XCTAssertEqual(close.hits.first?.page, 2)

        // Les deux pages contiennent « azote » et « reduction » ; seule celle
        // où ils sont voisins passe à pres:3.
        XCTAssertEqual(try db.store.search(try query("azote reduction")).totalPages, 2)
        let near = try db.store.search(try query("pres:3 azote reduction"))
        XCTAssertEqual(near.hits.map(\.page), [3])
        let wide = try db.store.search(try query("pres:12 azote reduction"))
        XCTAssertEqual(Set(wide.hits.map(\.page)), [3, 4])
    }

    // MARK: - T12 : recherche secondaire

    func testInDocIDsRestrictsResults() throws {
        let (db, chimie, bio) = try fixture()
        let everywhere = try db.store.search(try query("chromatographie"))
        XCTAssertEqual(everywhere.totalDocs, 2)

        let one = try db.store.search(try query("chromatographie", inDocIDs: [chimie]))
        XCTAssertEqual(one.totalPages, 1)
        XCTAssertEqual(one.hits.map(\.docID), [chimie])

        let two = try db.store.search(
            try query("chromatographie", inDocIDs: [chimie, bio]))
        XCTAssertEqual(two.totalDocs, 2)
        XCTAssertEqual(Set(two.hits.map(\.docID)), [chimie, bio])
    }

    // MARK: - Filtres dossier / extension, appliqués AVANT limit

    func testFolderAndExtensionFiltersApplyInsideTheSubquery() throws {
        let (db, chimie, bio) = try fixture()
        let folder = try db.store.search(try query("dossier:Cours chromatographie"))
        XCTAssertEqual(folder.hits.map(\.docID), [bio])
        XCTAssertEqual(folder.totalPages, 1)

        let ext = try db.store.search(try query("ext:pdf chromatographie"))
        XCTAssertEqual(ext.hits.map(\.docID), [chimie])

        // La pagination porte sur le jeu FILTRÉ, pas sur le jeu complet.
        var paged = try query("chromatographie", limit: 1)
        paged.folders = ["Cours"]
        let first = try db.store.search(paged)
        XCTAssertEqual(first.totalPages, 1)
        XCTAssertEqual(first.hits.count, 1)
        XCTAssertEqual(first.hits[0].docID, bio)
    }

    func testPaginationIsStableAcrossOffsets() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Users/alice/Livres/pagination.pdf")
        try db.store.replacePages(docID: docID, pages: (1...10).map {
            page($0, "chromatographie page \($0)")
        })
        var q = try query("chromatographie", limit: 4)
        let firstPage = try db.store.search(q)
        XCTAssertEqual(firstPage.totalPages, 10)
        XCTAssertEqual(firstPage.hits.count, 4)
        q.offset = 8
        let lastPage = try db.store.search(q)
        XCTAssertEqual(lastPage.totalPages, 10)
        XCTAssertEqual(lastPage.hits.count, 2)
    }

    // MARK: - T4 : facettes

    func testFacets() throws {
        let (db, _, _) = try fixture()
        let q = try query("chromatographie")

        let folders = try db.store.facets(q, by: .folder)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: folders),
                       ["Livres": 1, "Cours": 1])

        let exts = try db.store.facets(q, by: .ext)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: exts), ["pdf": 1, "docx": 1])

        let years = try db.store.facets(q, by: .year)
        XCTAssertEqual(years.map(\.1).reduce(0, +), 2)
        XCTAssertTrue(years.allSatisfy { $0.0.count == 4 })

        let sources = try db.store.facets(q, by: .source)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: sources), ["native": 2])
    }

    func testSourceFacetSeparatesOCRFromNative() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Users/alice/Cours/mixte.pdf",
                               folder: "Cours")
        try db.store.replacePages(docID: docID, pages: [page(1, "conversion native")])
        try db.store.completeOCR(docID: docID, page: 2,
                                 result: ocrPage("conversion reconnue par Vision"))
        let sources = try db.store.facets(try query("conversion"), by: .source)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: sources),
                       ["native": 1, "ocr_accurate": 1])
    }

    // MARK: - Provenance et agrégation

    func testHitCarriesSourceAndRelativePath() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Users/alice/Cours/scan.pdf", folder: "Cours")
        try db.store.completeOCR(docID: docID, page: 4,
                                 result: ocrPage("le taux de conversion mesuré"))
        let hit = try XCTUnwrap(db.store.search(try query("conversion")).hits.first)
        XCTAssertEqual(hit.path, "Users/alice/Cours/scan.pdf")
        XCTAssertEqual(hit.page, 4)
        XCTAssertEqual(hit.source, .ocrAccurate)
        XCTAssertEqual(hit.fuzzyDistance, 0)
    }

    func testGroupingUsesBestPagePlusSpreadFormula() throws {
        let hits = (1...7).map {
            Hit(docID: 1, path: "a.pdf", page: $0, score: Double(-$0),
                snippet: "", source: .native, fuzzyDistance: 0)
        } + [Hit(docID: 2, path: "b.pdf", page: 1, score: -1, snippet: "",
                 source: .native, fuzzyDistance: 0)]
        let groups = ResultGrouping.group(hits)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].docID, 1)
        XCTAssertEqual(groups[0].pageCount, 7)
        XCTAssertEqual(groups[0].firstPage, 1)
        // D-R5 : -7 * (1 + 0,15 * log2(1 + 7)) = -7 * (1 + 0,45) = -10,15.
        let expected1 = -7.0 * (1.0 + 0.15 * log2(1.0 + 7.0))
        XCTAssertEqual(groups[0].score, expected1, accuracy: 1e-9)
        // Doc 2 : -1 * (1 + 0,15 * log2(1 + 1)) = -1 * (1 + 0,15) = -1,15.
        let expected2 = -1.0 * (1.0 + 0.15 * log2(1.0 + 1.0))
        XCTAssertEqual(groups[1].score, expected2, accuracy: 1e-9)
    }

    /// D-R5 : une note de 2 pages excellentes bat un traité de 1 000 pages
    /// à 5 pages moyennes (l'ancienne somme donnait -20 contre -25 en faveur du traité).
    func testExcellentNoteBeatsAverageTreatise() throws {
        let note = [
            Hit(docID: 1, path: "note.pdf", page: 1, score: -10.0, snippet: "", source: .native, fuzzyDistance: 0),
            Hit(docID: 1, path: "note.pdf", page: 2, score: -10.0, snippet: "", source: .native, fuzzyDistance: 0),
        ]
        let treatise = (1...5).map {
            Hit(docID: 2, path: "treatise.pdf", page: $0 * 100, score: -5.0, snippet: "", source: .native, fuzzyDistance: 0)
        }
        let groups = ResultGrouping.group(treatise + note)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].docID, 1, "La note de 2 pages excellentes doit battre le traité de 5 pages moyennes")
        XCTAssertEqual(groups[1].docID, 2)
    }

    /// EX ÆQUO : l'ordre est celui du `docID`, et il ne dépend PAS de l'ordre
    /// d'arrivée (audit A1m-12).
    ///
    /// Le comparateur rendait `false` sur égalité et laissait donc trancher le
    /// tri — `Array.sorted(by:)` n'est pas garanti stable en Swift. Deux
    /// documents de même score pouvaient permuter d'une exécution à l'autre, et
    /// surtout d'une page de pagination à la suivante : le même document
    /// reparaissait, ou disparaissait, sans que rien n'ait changé.
    func testEqualScoresAreBrokenByDocIDWhateverTheInputOrder() throws {
        let hitA = Hit(docID: 10, path: "a.pdf", page: 1, score: -5.0, snippet: "", source: .native, fuzzyDistance: 0)
        let hitB = Hit(docID: 20, path: "b.pdf", page: 1, score: -5.0, snippet: "", source: .native, fuzzyDistance: 0)

        XCTAssertEqual(ResultGrouping.group([hitA, hitB]).map(\.docID), [10, 20])
        XCTAssertEqual(ResultGrouping.group([hitB, hitA]).map(\.docID), [10, 20])
    }

    /// Cent mélanges de dix documents ex æquo : un seul ordre, toujours le
    /// même. C'est ce qu'un lecteur qui pagine attend, et ce que `RRF.fuse`
    /// garantissait déjà de son côté.
    func testAHundredShufflesOfTiedDocumentsGiveTheSameOrder() throws {
        let hits = (1...10).map {
            Hit(docID: Int64($0), path: "d\($0).pdf", page: 1, score: -5.0,
                snippet: "", source: .native, fuzzyDistance: 0)
        }
        let expected = Array<Int64>(1...10)
        for _ in 0..<100 {
            XCTAssertEqual(ResultGrouping.group(hits.shuffled()).map(\.docID),
                           expected)
        }
    }

    func testSingleDocumentRemainsUnchanged() throws {
        let hits = [
            Hit(docID: 42, path: "doc.pdf", page: 10, score: -3.0, snippet: "", source: .native, fuzzyDistance: 0),
            Hit(docID: 42, path: "doc.pdf", page: 2, score: -8.0, snippet: "", source: .native, fuzzyDistance: 0),
            Hit(docID: 42, path: "doc.pdf", page: 5, score: -1.0, snippet: "", source: .native, fuzzyDistance: 0),
        ]
        let groups = ResultGrouping.group(hits)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].docID, 42)
        XCTAssertEqual(groups[0].pageCount, 3)
        XCTAssertEqual(groups[0].firstPage, 2)
        XCTAssertEqual(groups[0].hits.map(\.page), [2, 5, 10], "Les hits doivent être triés par numéro de page croissant")
        let expected = -8.0 * (1.0 + 0.15 * log2(1.0 + 3.0))
        XCTAssertEqual(groups[0].score, expected, accuracy: 1e-9)
    }

    func testEmptyQueryReturnsNothingWithoutThrowing() throws {
        let db = try makeDB()
        let results = try db.store.search(SearchQuery(fts: "   "))
        XCTAssertEqual(results.totalPages, 0)
        XCTAssertTrue(results.hits.isEmpty)
    }

    func testApproximateTotalsAboveThreshold() throws {
        let db = try makeDB()
        let docID1 = try addDoc(db, relPath: "Users/alice/doc1.pdf", folder: "Cours")
        let docID2 = try addDoc(db, relPath: "Users/alice/doc2.pdf", folder: "Cours")

        var pages1: [PageText] = []
        for p in 1...40 {
            pages1.append(page(p, "page \(p) : reaction chimique avec catalyseur metallique"))
        }
        for p in 41...50 {
            pages1.append(page(p, "page \(p) : depot de platine pur"))
        }
        try db.store.replacePages(docID: docID1, pages: pages1)

        var pages2: [PageText] = []
        for p in 1...30 {
            pages2.append(page(p, "page \(p) : synthese organique et catalyseur acide"))
        }
        try db.store.replacePages(docID: docID2, pages: pages2)

        // 1. Sous le seuil (seuil = 50, requête « platine » sur 10 pages)
        let queryUnder = SearchQuery(fts: "platine", approximateThreshold: 50)
        let resultsUnder = try db.store.search(queryUnder)
        XCTAssertEqual(resultsUnder.totalPages, 10, "Sous le seuil, le compte est exact")
        XCTAssertEqual(resultsUnder.totalDocs, 1)
        XCTAssertFalse(resultsUnder.totalsApproximate, "totalsApproximate doit être faux sous le seuil")

        // 2. Au-dessus du seuil (seuil = 50, « catalyseur » a 70 pages réparties sur 2 docs)
        let queryOver = SearchQuery(fts: "catalyseur", approximateThreshold: 50)
        let resultsOver = try db.store.search(queryOver)
        XCTAssertEqual(resultsOver.totalPages, 50, "Au-dessus du seuil, total_pages est borné à N")
        XCTAssertEqual(resultsOver.totalDocs, 2, "total_docs est compté sur la sous-requête bornée")
        XCTAssertTrue(resultsOver.totalsApproximate, "totalsApproximate doit être vrai au-dessus du seuil")
    }

    /// Le seuil se règle PAR REQUÊTE (lot J1) : `Schema.approximateCountThreshold`
    /// n'est plus une variable globale qu'un test remplaçait le temps d'un cas
    /// — un état partagé par tout le processus, donc par tous les tests que
    /// `swift test --parallel` fait tourner dans le même.
    func testApproximateThresholdIsPerQuery() throws {
        let db = try makeDB()
        let docID = try addDoc(db, relPath: "Users/alice/doc.pdf", folder: "Docs")
        var pages: [PageText] = []
        for p in 1...30 {
            pages.append(page(p, "page \(p) : polymere lineaire"))
        }
        try db.store.replacePages(docID: docID, pages: pages)

        let bounded = try db.store.search(
            SearchQuery(fts: "polymere", approximateThreshold: 25))
        XCTAssertEqual(bounded.totalPages, 25)
        XCTAssertTrue(bounded.totalsApproximate)

        // Sans le paramètre, c'est la constante (50 000) qui s'applique : le
        // compte redevient exact, et aucun autre test n'a pu la déplacer.
        let exact = try db.store.search(SearchQuery(fts: "polymere"))
        XCTAssertEqual(exact.totalPages, 30)
        XCTAssertFalse(exact.totalsApproximate)
    }

    // MARK: - C2-08 : le repli en flou quand l'exact rend zéro

    /// Trois documents NATIFS portaient « Villeurbanne » et `Villeurbane`
    /// rendait zéro page : la portée `ocr` du flou ne couvre que les fautes de
    /// la MACHINE, jamais celles de la requête (mesuré le 09/09/2026 sur la base
    /// de production). Le repli rejoue la requête sur tout l'index et le DIT.
    private func typoCorpus() throws -> (TempDB, doc: Int64) {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Cours/rapport.docx",
                             ext: "docx", folder: "Cours")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "Le laboratoire de Villeurbanne accueille la conference."),
            page(2, "Une autre page qui parle de chimie analytique."),
        ])
        try TrigramExpander(store: db.store).warm()
        return (db, doc)
    }

    func testFuzzyFallbackWhenTheExactSearchFindsNothing() throws {
        let (db, doc) = try typoCorpus()
        let results = try db.store.search(try query("Villeurbane", fuzzy: .auto))
        XCTAssertTrue(results.fuzzyFallback,
                      "zéro résultat exact : la requête est rejouée en flou")
        XCTAssertEqual(results.hits.map(\.docID), [doc])
        XCTAssertEqual(results.hits.first?.fuzzyDistance, 1,
                       "le hit garde la distance de sa variante")
        XCTAssertEqual(results.totalPages, 1, "les totaux sont ceux du repli")
    }

    /// Le chemin normal ne change pas : dès qu'il y a un résultat, aucun appel
    /// de plus, et rien à annoncer.
    func testNoFallbackWhenTheExactSearchAnswers() throws {
        let (db, doc) = try typoCorpus()
        let results = try db.store.search(try query("Villeurbanne", fuzzy: .auto))
        XCTAssertFalse(results.fuzzyFallback)
        XCTAssertEqual(results.hits.map(\.docID), [doc])
        XCTAssertEqual(results.hits.first?.fuzzyDistance, 0)
    }

    /// « Jamais » veut dire jamais : le repli n'est pas une exception au
    /// réglage, c'est le réglage qui décide.
    func testFuzzyOffNeverFallsBack() throws {
        let (db, _) = try typoCorpus()
        let results = try db.store.search(try query("Villeurbane", fuzzy: .off))
        XCTAssertTrue(results.hits.isEmpty)
        XCTAssertFalse(results.fuzzyFallback)
        XCTAssertEqual(results.totalPages, 0)
    }

    /// Une requête DÉJÀ en flou sur tout l'index n'est pas rejouée : la seconde
    /// passe serait la copie de la première.
    func testAFallbackQueryIsNotReplayedAgain() throws {
        let (db, _) = try typoCorpus()
        let results = try db.store.search(
            try query("Villeurbanx", fuzzy: .on, scope: .all))
        XCTAssertFalse(results.fuzzyFallback)
    }

    // MARK: - PR-02 : le canal des noms de fichier

    /// `fouine search IP2022` rendait sept pages sans rapport alors que trois
    /// fichiers S'APPELLENT `IP2022__…` : `docs_fts` existait, était à jour, et
    /// ne servait que de bonus de classement. Un nom ne désigne aucune page :
    /// les documents sortent donc à part, et ne touchent NI les totaux NI
    /// l'ordre des pages.
    func testNameChannelAnswersWhenOnlyTheFileNameMatches() throws {
        let db = try makeDB()
        let named = try addDoc(db, relPath: "Users/alice/Livres/IP2022__Analyse.pdf")
        try db.store.replacePages(docID: named, pages: [
            page(1, "Une page dont le texte ne porte pas le sigle du titre."),
        ])
        let results = try db.store.search(try query("IP2022"))
        XCTAssertTrue(results.hits.isEmpty, "aucune PAGE ne porte le sigle")
        XCTAssertEqual(results.totalPages, 0)
        XCTAssertEqual(results.nameMatches.map(\.id), [named])
        XCTAssertEqual(results.nameMatches.first?.relPath,
                       "Users/alice/Livres/IP2022__Analyse.pdf")
    }

    func testNameChannelAndTextChannelBothAnswer() throws {
        let db = try makeDB()
        let named = try addDoc(db, relPath: "Users/alice/Livres/enthalpie-cours.pdf")
        try db.store.replacePages(docID: named, pages: [
            page(1, "L'enthalpie libre G est definie ici."),
        ])
        let results = try db.store.search(try query("enthalpie"))
        XCTAssertEqual(results.hits.map(\.docID), [named])
        XCTAssertEqual(results.nameMatches.map(\.id), [named],
                       "le document répond par son nom ET par son texte")
        XCTAssertEqual(results.totalPages, 1,
                       "le canal des noms ne change pas les totaux")
    }

    /// Les filtres de la requête s'appliquent au canal des noms, et un mot de
    /// moins de trois caractères ne le déclenche pas.
    func testNameChannelHonoursFiltersAndTheThreeLetterRule() throws {
        let db = try makeDB()
        let livre = try addDoc(db, relPath: "Users/alice/Livres/polymere.pdf")
        _ = try addDoc(db, relPath: "Users/alice/Cours/polymere.docx", ext: "docx",
                       folder: "Cours")
        try db.store.replacePages(docID: livre, pages: [page(1, "texte quelconque")])

        XCTAssertEqual(try db.store.search(try query("polymere")).nameMatches.count, 2)
        let filtered = try db.store.search(try query("dossier:Livres polymere"))
        XCTAssertEqual(filtered.nameMatches.map(\.id), [livre])
        let byExt = try db.store.search(try query("ext:docx polymere"))
        XCTAssertEqual(byExt.nameMatches.count, 1)
        XCTAssertEqual(byExt.nameMatches.first?.ext, "docx")
        // Deux lettres : le nom de fichier répondrait presque toujours.
        XCTAssertTrue(try db.store.search(try query("po")).nameMatches.isEmpty)
    }

    // MARK: - C2-12 : un montant se trouve dans ses deux écritures

    /// La page porte l'espace fine insécable des montants français ; le
    /// tokenizer en fait `1` et `512,50`. Les deux écritures partent ensemble.
    func testAnAmountIsFoundTypedWithOrWithoutItsThousandsSpace() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Livres/facture.pdf")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "Total du mois : 1\u{202F}512,50 € toutes taxes comprises."),
            page(2, "Acompte de 1512,50 € verse le meme jour."),
        ])
        let compact = try db.store.search(try query("1512,50"))
        XCTAssertEqual(Set(compact.hits.map(\.page)), [1, 2],
                       "les deux écritures répondent à la forme compacte")
        let grouped = try db.store.search(try query("1 512,50"))
        XCTAssertEqual(Set(grouped.hits.map(\.page)), [1, 2])
        // Un montant qui n'est pas là ne se trouve pas pour autant.
        XCTAssertEqual(try db.store.search(try query("1512,51")).totalPages, 0)
    }

    // MARK: - RK2 : le quorum des mots (RK-04)

    /// Une page porte les trois mots, trois autres en portent deux, une
    /// dernière n'en porte qu'un.
    private func quorumFixture() throws -> TempDB {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Livres/thermo.pdf")
        try db.store.replacePages(docID: doc, pages: [
            page(1, "la chaleur degagee par une reaction se mesure au calorimetre"),
            page(2, "chaleur degagee lors du melange, mesure au calorimetre"),
            page(3, "la chaleur produite par une reaction exothermique"),
            page(4, "energie degagee par la reaction de combustion"),
            page(5, "la chaleur specifique de l eau"),
        ])
        return db
    }

    func testQuorumShowsThePagesCarryingMostOfTheWords() throws {
        let db = try quorumFixture()
        var q = try query("chaleur degagee reaction")
        q.quorum = false
        let strict = try db.store.search(q)
        XCTAssertEqual(strict.hits.map(\.page), [1],
                       "le ET strict n'apparie que la page qui porte tout")
        XCTAssertFalse(strict.quorum)

        q.quorum = true
        let relaxed = try db.store.search(q)
        XCTAssertTrue(relaxed.quorum, "le quorum s'annonce")
        XCTAssertEqual(relaxed.hits.first?.page, 1,
                       "la page stricte garde la tête")
        XCTAssertEqual(Set(relaxed.hits.map(\.page)), [1, 2, 3, 4],
                       "les pages à deux mots sur trois suivent ; celle qui n'en "
                       + "porte qu'un reste dehors")
        XCTAssertEqual(relaxed.totalPages, 4)
    }

    /// Au-dessus du seuil, rien ne se relâche : même jeu, même drapeau qu'à
    /// l'option éteinte.
    func testQuorumStaysSilentWhenTheStrictSearchIsEnough() throws {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Livres/manuel.pdf")
        try db.store.replacePages(docID: doc, pages: (1...Schema.quorumTrigger).map {
            page($0, "chaleur degagee reaction numero \($0)")
        } + [page(99, "chaleur degagee seulement")])

        var q = try query("chaleur degagee reaction")
        q.quorum = false
        let strict = try db.store.search(q)
        q.quorum = true
        let armed = try db.store.search(q)
        XCTAssertFalse(armed.quorum)
        XCTAssertEqual(armed.hits.map(\.page), strict.hits.map(\.page))
        XCTAssertEqual(armed.totalPages, strict.totalPages)
    }

    /// Désarmé (`--no-quorum`, banc), la recherche est EXACTEMENT celle
    /// d'avant : mêmes pages, mêmes totaux, et aucune requête de plus (le
    /// drapeau reste faux). Armé par défaut depuis le 11/09/2026.
    func testDisarmedQuorumChangesNothing() throws {
        let db = try quorumFixture()
        var q = try query("chaleur degagee reaction")
        q.quorum = false
        let before = try db.store.search(q)
        XCTAssertEqual(before.hits.map(\.page), [1])
        XCTAssertFalse(before.quorum)
        XCTAssertNil(GRDBStore.quorumExpression(for: q, strictPages: 0, negative: nil),
                     "sans l'interrupteur, aucune expression n'est même bâtie")
    }

    // MARK: - RK2 : le malus des sommaires (RK-07)

    /// Un sommaire (lignes courtes finissant par un numéro de page) et deux
    /// pages de prose qui traitent le sujet.
    private func tableOfContentsFixture() throws -> TempDB {
        let db = try makeDB()
        let doc = try addDoc(db, relPath: "Users/alice/Livres/analyse.pdf")
        try db.store.replacePages(docID: doc, pages: [
            page(1, """
                Table des matieres
                1 Spectroscopie infrarouge 12
                2 Spectroscopie de masse 24
                3 Spectroscopie RMN 36
                4 Spectroscopie UV 48
                5 Spectroscopie Raman 60
                """),
            page(2, "La spectroscopie infrarouge mesure l absorption des liaisons "
                 + "chimiques par le rayonnement, et sert a identifier les groupes."),
            page(3, "En spectroscopie de masse, l echantillon est ionise puis "
                 + "separe selon le rapport masse sur charge des fragments."),
        ])
        return db
    }

    func testTableOfContentsGoesBehindTheOtherResults() throws {
        let db = try tableOfContentsFixture()
        var q = try query("spectroscopie")
        q.demoteTableOfContents = false
        let before = try db.store.search(q)
        XCTAssertEqual(before.hits.first?.page, 1,
                       "sans le malus, le sommaire est en tête : c'est la page "
                       + "où le mot apparaît le plus souvent (RK-07)")
        XCTAssertFalse(before.hits.contains { $0.tableOfContents })

        q.demoteTableOfContents = true
        let after = try db.store.search(q)
        XCTAssertEqual(after.hits.last?.page, 1, "le sommaire passe derrière")
        XCTAssertEqual(Set(after.hits.map(\.page)), Set(before.hits.map(\.page)),
                       "le malus ne RETIRE rien : mêmes pages")
        XCTAssertEqual(after.totalPages, before.totalPages)
        XCTAssertEqual(after.hits.filter(\.tableOfContents).map(\.page), [1],
                       "« pourquoi ce résultat » sait le dire")
    }

    /// Le malus ne touche pas les pages qui n'en sont pas : l'ordre des autres
    /// est celui d'avant, au rang près.
    func testDemotionKeepsTheOrderOfTheOtherPages() throws {
        let db = try tableOfContentsFixture()
        var q = try query("spectroscopie")
        q.demoteTableOfContents = false
        let before = try db.store.search(q).hits.map(\.page).filter { $0 != 1 }
        q.demoteTableOfContents = true
        let after = try db.store.search(q).hits.map(\.page).filter { $0 != 1 }
        XCTAssertEqual(after, before)
    }
}
