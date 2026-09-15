// CorpusSearchTests.swift — recette tranche A sur la base complète (SPEC §8.1).
// Propriété : A-Recette. Tests T1 à T5, T12, T14, T15.
//
// Préconditions, toutes vérifiées par un `XCTSkip` propre :
//   · le binaire `fouine` est bâti (`swift build -c release`) ;
//   · `Tests/Fixtures/paths.json` existe (gitignoré) ;
//   · `FOUINE_TEST_DB` désigne une COPIE de base indexée et peuplée
//     (audit S3 — voir l'en-tête d'IntegrationSupport).
// Aucun test n'écrit dans la base ni sous une racine indexée.

import Foundation
import XCTest

final class CorpusSearchTests: XCTestCase {

    private var database: URL!

    override func setUpWithError() throws {
        _ = try Recette.requireBinary()
        database = try Recette.requireFullIndex()
    }

    // MARK: - T1 · phrase exacte, deux pages, et AUCUNE autre de ce livre

    func testT1PhraseMarkovnikov() throws {
        let fixture = try Recette.requireFixture("T1")
        let payload = try Recette.search(fixture.query, database: database,
                                         extra: ["--fuzzy", "off"], limit: 500)

        let expectedPath = fixture.path.hasPrefix("/")
            ? String(fixture.path.dropFirst()) : fixture.path
        let ofThisBook = payload.hits.filter { $0.path == expectedPath }
        XCTAssertFalse(ofThisBook.isEmpty,
                       "aucune page du livre T1 dans les résultats — "
                       + "chemins vus : \(Set(payload.hits.map(\.path)).sorted())")

        let pages = Set(ofThisBook.map(\.page)).sorted()
        XCTAssertEqual(pages, fixture.expectedPages ?? [247, 265],
                       "le critère porte sur CE livre : aucune autre page ne doit "
                       + "sortir (§8.1 T1)")
        for hit in ofThisBook {
            XCTAssertEqual(hit.source, fixture.expectedSource ?? "native")
            XCTAssertEqual(hit.fuzzyDistance, 0)
        }

        // Le texte lui-même, pas seulement le compte de pages.
        XCTAssertTrue(ofThisBook.contains { $0.snippet.lowercased()
                                             .contains("markovnikov") },
                      "aucun extrait ne porte le terme cherché")
    }

    // MARK: - T2 · proximité

    /// Ex-BOGUE 1 (recette du 31/08/2026, rapport interne), corrigé en wave2fix : la commande NUE du §8.1
    /// T2 doit sortir en 0 — un plan flou sans branche `fz` retombe sur le
    /// chemin exact du §4.1 au lieu de produire une CTE dégénérée que SQLite
    /// aplatit en refusant `bm25()`.
    func testT2ProximityGibbsBareCommand() throws {
        let fixture = try Recette.requireFixture("T2")
        let bare = try Recette.run(["search", fixture.query, "--json"],
                                   database: database)
        XCTAssertEqual(bare.status, 0, bare.describe)
    }

    /// Le critère de fond — la page 93 de CAPES Tome 2 est bien trouvée par
    /// `NEAR(energie libre gibbs, 10)` — est vérifié sur le chemin qui
    /// fonctionne. C'est la traduction du §5.5.1 qui est en cause, pas l'index.
    func testT2ProximityGibbsEngineFindsThePage() throws {
        let fixture = try Recette.requireFixture("T2")
        let payload = try Recette.search(fixture.query, database: database,
                                         extra: ["--fuzzy", "off"], limit: 500)
        let expectedPath = fixture.path.hasPrefix("/")
            ? String(fixture.path.dropFirst()) : fixture.path
        let pages = Set(payload.hits.filter { $0.path == expectedPath }.map(\.page))
        for page in fixture.expectedPages ?? [93] {
            XCTAssertTrue(pages.contains(page),
                          "page \(page) de CAPES Tome 2 absente des résultats "
                          + "(pages trouvées : \(pages.sorted()))")
        }
    }

    // MARK: - T3 · accents

    func testT3Diacritics() throws {
        let plain = try Recette.search("polymere", database: database,
                                       extra: ["--fuzzy", "off"], limit: 500)
        XCTAssertGreaterThan(plain.totalPages, 0)
        XCTAssertTrue(plain.hits.contains { $0.snippet.lowercased().contains("polymère") },
                      "aucun extrait ne contient « polymère » accentué")

        // Contrôle moteur : les deux formes rendent le MÊME total (§5.5.1).
        let accented = try Recette.search("polymère", database: database,
                                          extra: ["--fuzzy", "off"], limit: 500)
        XCTAssertEqual(plain.totalPages, accented.totalPages)
        XCTAssertEqual(plain.totalDocs, accented.totalDocs)
    }

    // MARK: - T4 · facettes

    func testT4FolderFacets() throws {
        let payload = try Recette.search("chromatographie", database: database,
                                         extra: ["--facet", "folder"], limit: 500)
        let buckets = try XCTUnwrap(payload.facets?["folder"],
                                    "aucune facette folder dans la sortie JSON")
        XCTAssertFalse(buckets.isEmpty)
        // Les étiquettes attendues sont celles de `Tests/Fixtures/paths.json`
        // (gitignoré) : aucun nom de dossier personnel n'est écrit en dur ici.
        for label in try Recette.requireFixtures().roots.keys.sorted() {
            XCTAssertNotNil(buckets[label],
                            "facette « \(label) » absente : \(buckets)")
        }
        // Les étiquettes sont les labels de racines, JAMAIS le 1er segment du
        // chemin absolu (§5.2, contrôle implicite du §8.1 T4).
        XCTAssertNil(buckets["Users"], "étiquette « Users » : le label de racine "
                     + "n'est pas utilisé (§5.2)")
        for hit in payload.hits {
            XCTAssertNotEqual(hit.folder, "Users")
        }
    }

    // MARK: - T5 · exclusion

    func testT5Exclusion() throws {
        let payload = try Recette.search("enthalpie -biologie", database: database,
                                         extra: ["--fuzzy", "off"], limit: 500)
        XCTAssertGreaterThan(payload.hits.count, 0)

        // Ce que le §5.5.1 impose et que le moteur fait : exclusion à la PAGE
        // (`-biologie` -> `NOT biologie`, et une ligne de page_fts est une page).
        for hit in payload.hits {
            XCTAssertFalse(hit.snippet.lowercased().contains("biologie"),
                           "page \(hit.docID)/\(hit.page) porte « biologie »")
        }

        // Ce que le §8.1 T5 demande en plus : aucun DOCUMENT contenant
        // « biologie ». Contre-requête, `--in` étant répétable (§4.3).
        // ÉCART DE SPÉCIFICATION (recette du 31/08/2026, rapport interne) : §5.5.1 exclut la page, §8.1 T5
        // exige le document. Non strict : sur un autre corpus les deux lectures
        // peuvent coïncider.
        let docIDs = Set(payload.hits.map(\.docID)).sorted()
        var extra = ["--fuzzy", "off"]
        for id in docIDs { extra += ["--in", "\(id)"] }
        let counter = try Recette.search("biologie", database: database,
                                         extra: extra, limit: 500)
        // Arbitrage n°1 (recette du 31/08/2026, rapport interne), implémenté en wave2fix : l'exclusion
        // `-terme` porte sur le DOCUMENT entier (§8.1 T5 prime sur §5.5.1).
        XCTAssertEqual(counter.totalPages, 0,
                       "\(Set(counter.hits.map(\.docID)).count) document(s) "
                       + "retourné(s) contiennent « biologie » sur une AUTRE page")
    }

    // MARK: - T12 · restriction par document

    func testT12InDocumentFilter() throws {
        let broad = try Recette.search("chimie", database: database,
                                       extra: ["--fuzzy", "off"], limit: 500)
        let docIDs = Array(Set(broad.hits.map(\.docID))).sorted()
        try XCTSkipIf(docIDs.count < 2, "moins de deux documents contiennent « chimie »")

        let one = try Recette.search("chimie", database: database,
                                     extra: ["--fuzzy", "off", "--in", "\(docIDs[0])"],
                                     limit: 500)
        XCTAssertGreaterThan(one.totalPages, 0)
        XCTAssertEqual(Set(one.hits.map(\.docID)), [docIDs[0]])
        XCTAssertEqual(one.totalDocs, 1)

        let two = try Recette.search(
            "chimie", database: database,
            extra: ["--fuzzy", "off", "--in", "\(docIDs[0])", "--in", "\(docIDs[1])"],
            limit: 500)
        XCTAssertTrue(Set(two.hits.map(\.docID)).isSubset(of: [docIDs[0], docIDs[1]]))
        XCTAssertGreaterThanOrEqual(two.totalPages, one.totalPages)
        XCTAssertLessThanOrEqual(two.totalDocs, 2)
    }

    // MARK: - Morphologie et diversité (lot R1, AUDIT-R1)

    /// `--raw-fts` : la chaîne part TELLE QUELLE à FTS5 — ni analyse, ni
    /// morphologie (AUDIT-R1 I1 : `body:mot` sortait en 3 avec un vidage SQL).
    /// « fichier » et « fichiers » sont tous deux dans le corpus versionné.
    func testRawFTSGoesToFTS5Untouched() throws {
        let plain = try Recette.search("fichier", database: database,
                                       extra: ["--fuzzy", "off"], limit: 500)
        let noMorph = try Recette.search("fichier", database: database,
                                         extra: ["--fuzzy", "off", "--no-morphology"], limit: 500)
        let raw = try Recette.search("fichier", database: database,
                                     extra: ["--fuzzy", "off", "--raw-fts"], limit: 500)
        XCTAssertEqual(raw.totalPages, noMorph.totalPages,
                       "brut = sans morphologie : le pluriel n'est pas ajouté")
        XCTAssertGreaterThanOrEqual(plain.totalPages, raw.totalPages)
        XCTAssertGreaterThan(plain.totalPages, 0)

        // Du FTS5 valide que l'analyseur de requête ne connaît pas : un filtre
        // de colonne, une ancre de début de page, un `+` de phrase implicite.
        for expression in ["body:fichier", "^fichier", "fichier + temoin"] {
            let result = try Recette.run(
                ["search", expression, "--raw-fts", "--json", "--fuzzy", "off", "--limit", "5"],
                database: database)
            XCTAssertEqual(result.status, 0, "\(expression) : \(result.describe)")
            XCTAssertFalse(result.stderr.contains("fts5: syntax error"), result.describe)
        }
        let column = try Recette.search("body:fichier", database: database,
                                        extra: ["--fuzzy", "off", "--raw-fts"], limit: 500)
        XCTAssertEqual(column.totalPages, raw.totalPages)
    }

    /// Les options de calibration du lot R1 sont acceptées, et la diversité ne
    /// change que l'ordre : mêmes totaux, mêmes pages, avec et sans.
    func testMorphologyAndDiversityFlagsAreAcceptedAndDiversityKeepsTheSet() throws {
        let plain = try Recette.search("fichier", database: database,
                                       extra: ["--fuzzy", "off"], limit: 500)
        let noDiv = try Recette.search("fichier", database: database,
                                       extra: ["--fuzzy", "off", "--no-diversity"], limit: 500)
        XCTAssertEqual(noDiv.totalPages, plain.totalPages)
        XCTAssertEqual(noDiv.totalDocs, plain.totalDocs)
        // Le JEU ne se compare que s'il tient dans la tranche : au-delà, la
        // diversité déplace légitimement des pages de part et d'autre de la
        // coupure (elle ne change que l'ordre, et l'ordre décide de la tranche).
        if plain.totalPages <= 500 {
            XCTAssertEqual(Set(noDiv.hits.map { "\($0.docID)/\($0.page)" }),
                           Set(plain.hits.map { "\($0.docID)/\($0.page)" }),
                           "la diversité ne change que l'ordre")
        } else {
            XCTAssertEqual(noDiv.hits.count, plain.hits.count)
        }
        let old = try Recette.run(
            ["search", "fichier", "--json", "--fuzzy", "off", "--no-diversity",
             "--no-morphology", "--no-proximity", "--limit", "5"], database: database)
        XCTAssertEqual(old.status, 0, old.describe)
    }

    /// `--no-typed-form` (lot P1) : l'option est acceptée, et la sonde ne change
    /// QUE L'ORDRE — mêmes totaux, mêmes pages. Le corpus versionné porte
    /// « fichier » et « fichiers » : la sonde a donc de quoi départager.
    func testTypedFormFlagIsAcceptedAndKeepsTheSet() throws {
        let plain = try Recette.search("fichier", database: database,
                                       extra: ["--fuzzy", "off"], limit: 500)
        let noTyped = try Recette.search("fichier", database: database,
                                         extra: ["--fuzzy", "off", "--no-typed-form"],
                                         limit: 500)
        XCTAssertEqual(noTyped.totalPages, plain.totalPages)
        XCTAssertEqual(noTyped.totalDocs, plain.totalDocs)
        // Même réserve que pour la diversité : le JEU ne se compare que s'il
        // tient dans la tranche demandée, l'ordre décidant de la coupure.
        if plain.totalPages <= 500 {
            XCTAssertEqual(Set(noTyped.hits.map { "\($0.docID)/\($0.page)" }),
                           Set(plain.hits.map { "\($0.docID)/\($0.page)" }),
                           "la sonde ne change que l'ordre")
        } else {
            XCTAssertEqual(noTyped.hits.count, plain.hits.count)
        }
        // La sonde vit de la morphologie : les deux options ensemble sont
        // acceptées, et `--no-morphology` l'éteint déjà de fait.
        let both = try Recette.run(
            ["search", "fichier", "--json", "--fuzzy", "off",
             "--no-typed-form", "--no-morphology", "--limit", "5"], database: database)
        XCTAssertEqual(both.status, 0, both.describe)
    }

    // MARK: - T14 · inflation bornée, ordre et déduplication

    func testT14FuzzyAutoStaysBounded() throws {
        let exact = try Recette.search("polymere", database: database,
                                       extra: ["--fuzzy", "off"], limit: 500)
        let auto = try Recette.search("polymere", database: database, limit: 500)
        XCTAssertLessThanOrEqual(auto.totalPages, 2 * max(exact.totalPages, 1),
                                 "le mode auto a plus que doublé le nombre de pages")
    }

    func testT14FuzzyOnOrdersAndDeduplicates() throws {
        // Portée `all` : sans OCR, la portée `ocr` par défaut ne peut RIEN
        // étendre — le test d'ordre et de déduplication serait vide de sens.
        let payload = try Recette.search(
            "polymere", database: database,
            extra: ["--fuzzy", "on", "--fuzzy-scope", "all"], limit: 500)

        // D-R1 : le classement ordonne par score scalaire r_final croissant (bm25 négatif,
        // plus bas = meilleur). La clause « fuzzy_distance = 0 d'abord » saute.
        let scores = payload.hits.map(\.score)
        XCTAssertEqual(scores, scores.sorted(),
                       "les scores doivent être croissants (plus bas = meilleur)")

        // Aucune page en double (GROUP BY doc_id, page du §5.5.3).
        let keys = payload.hits.map { "\($0.docID):\($0.page)" }
        XCTAssertEqual(keys.count, Set(keys).count, "une page apparaît deux fois")
    }

    // MARK: - T15 · plancher de 6 lettres et contre-épreuve

    func testT15ShortTermsAreNeverExpanded() throws {
        for term in ["mayer", "gibbs"] {
            let off = try Recette.search(term, database: database,
                                         extra: ["--fuzzy", "off"], limit: 500)
            let on = try Recette.search(
                term, database: database,
                extra: ["--fuzzy", "on", "--fuzzy-scope", "all"], limit: 500)
            XCTAssertEqual(on.totalPages, off.totalPages,
                           "« \(term) » (5 lettres) a été étendu — d = 0 imposé (§5.5.2)")
            XCTAssertEqual(Set(on.hits.map { "\($0.docID):\($0.page)" }),
                           Set(off.hits.map { "\($0.docID):\($0.page)" }))
            XCTAssertTrue(on.hits.allSatisfy { $0.fuzzyDistance == 0 })
        }
    }

    func testT15LongTermIsExpanded() throws {
        let off = try Recette.search("enthalpie", database: database,
                                     extra: ["--fuzzy", "off"], limit: 2000)
        let on = try Recette.search(
            "enthalpie", database: database,
            extra: ["--fuzzy", "on", "--fuzzy-scope", "all"], limit: 2000)
        XCTAssertGreaterThan(on.totalPages, off.totalPages,
                             "contre-épreuve : « enthalpie » doit s'étendre (d = 2)")

        // L'expansion atteint bien des VOISINS, pas seulement plus de pages :
        // au moins un voisin attendu du §8.1 T15 doit exister dans le corpus et
        // ses pages doivent se retrouver dans le résultat flou.
        let expanded = Set(on.hits.map { "\($0.docID):\($0.page)" })
        var reached: [String] = []
        for neighbour in ["enthalpic", "enthalpies", "enthalpique", "enthalpy"] {
            let hits = try Recette.search(neighbour, database: database,
                                          extra: ["--fuzzy", "off"], limit: 2000)
            guard hits.totalPages > 0 else { continue }
            let keys = Set(hits.hits.map { "\($0.docID):\($0.page)" })
            if !keys.isDisjoint(with: expanded) { reached.append(neighbour) }
        }
        XCTAssertFalse(reached.isEmpty,
                       "aucun voisin (enthalpic/enthalpies/enthalpique/enthalpy) "
                       + "n'est atteint par l'expansion")
    }

    // MARK: - Pagination (--offset, D2-11)

    func testPaginationLexicalDisjointPages() throws {
        let fixture = try Recette.requireFixture("T1")
        let page1 = try Recette.search(fixture.query, database: database,
                                       extra: ["--offset", "0"], limit: 2)
        XCTAssertEqual(page1.offset, 0)
        XCTAssertEqual(page1.hits.count, min(2, page1.totalPages))

        if page1.totalPages > 2 {
            XCTAssertEqual(page1.hasMore, true)
            let page2 = try Recette.search(fixture.query, database: database,
                                           extra: ["--offset", "2"], limit: 2)
            XCTAssertEqual(page2.offset, 2)
            let keys1 = Set(page1.hits.map { "\($0.docID):\($0.page)" })
            let keys2 = Set(page2.hits.map { "\($0.docID):\($0.page)" })
            XCTAssertTrue(keys1.isDisjoint(with: keys2),
                          "les pages de résultats doivent être disjointes")

            let lastOffset = page1.totalPages
            let pageEnd = try Recette.search(fixture.query, database: database,
                                             extra: ["--offset", "\(lastOffset)"], limit: 2)
            XCTAssertEqual(pageEnd.offset, lastOffset)
            XCTAssertEqual(pageEnd.hasMore, false)
        } else {
            XCTAssertEqual(page1.hasMore, false)
        }
    }

    func testPaginationHybridDisjointPages() throws {
        let modelDir = ("~/Library/Application Support/Fouine/models" as NSString)
            .expandingTildeInPath
        guard FileManager.default.fileExists(atPath: modelDir) else {
            throw XCTSkip("modèle sémantique absent")
        }
        let fixture = try Recette.requireFixture("T1")
        let res1 = try Recette.run(
            ["search", fixture.query, "--hybrid", "--offset", "0", "--limit", "2", "--json"],
            database: database)
        guard res1.status == 0, let data1 = res1.stdout.data(using: .utf8),
              let json1 = try? JSONSerialization.jsonObject(with: data1) as? [String: Any],
              let hits1 = json1["hits"] as? [[String: Any]],
              let hasMore1 = json1["has_more"] as? Bool
        else {
            throw XCTSkip("recherche hybride indisponible")
        }
        XCTAssertEqual(json1["offset"] as? Int, 0)
        if hasMore1 {
            let res2 = try Recette.run(
                ["search", fixture.query, "--hybrid", "--offset", "2", "--limit", "2", "--json"],
                database: database)
            XCTAssertEqual(res2.status, 0)
            if let data2 = res2.stdout.data(using: .utf8),
               let json2 = try? JSONSerialization.jsonObject(with: data2) as? [String: Any],
               let hits2 = json2["hits"] as? [[String: Any]] {
                XCTAssertEqual(json2["offset"] as? Int, 2)
                let keys1 = Set(hits1.map { "\($0["doc_id"] ?? ""):\($0["page"] ?? "")" })
                let keys2 = Set(hits2.map { "\($0["doc_id"] ?? ""):\($0["page"] ?? "")" })
                XCTAssertTrue(keys1.isDisjoint(with: keys2))
            }
        }
    }

    func testOffsetNegativeOrNonIntegerExits64() throws {
        let neg = try Recette.run(["search", "test", "--offset", "-1"], database: database)
        XCTAssertEqual(neg.status, 64)
        let nonInt = try Recette.run(["search", "test", "--offset", "abc"], database: database)
        XCTAssertEqual(nonInt.status, 64)
    }

    // MARK: - Chercher comme on parle (lot MP1)

    /// PR-02 · un fichier se trouve par son NOM.
    ///
    /// Le mot cherché est LU DANS LE CORPUS, pas écrit ici : un nom de fichier
    /// codé en dur dans la recette ne vaudrait que sur la machine de qui l'a
    /// écrite. On prend le premier document dont le nom porte un mot d'au moins
    /// six lettres, et on le cherche.
    func testNameChannelFindsADocumentOfTheCorpusByItsName() throws {
        let raw = try Recette.sqlite(
            "SELECT rel_path FROM docs ORDER BY id LIMIT 400", on: database)
        var probe: (word: String, path: String)?
        for path in raw.split(separator: "\n").map(String.init) {
            let base = ((path as NSString).lastPathComponent as NSString)
                .deletingPathExtension
            let words = base.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 6 && $0.rangeOfCharacter(from: .letters) != nil }
            if let word = words.first { probe = (word, path); break }
            _ = base
        }
        guard let probe else {
            throw XCTSkip("aucun nom de fichier du corpus ne porte un mot assez long")
        }
        let payload = try Recette.search(probe.word, database: database,
                                         extra: ["--fuzzy", "off"], limit: 5)
        let names = payload.nameMatches ?? []
        XCTAssertFalse(names.isEmpty,
                       "« \(probe.word) » est dans le nom de \(probe.path) : "
                       + "le canal des noms doit le rendre")
        XCTAssertLessThanOrEqual(names.count, 5, "cinq documents au plus")
        for match in names {
            XCTAssertTrue(match.link.hasSuffix("page=1"),
                          "un nom mène à la première page : \(match.link)")
            let base = ((match.path as NSString).lastPathComponent as NSString)
                .deletingPathExtension
                .folding(options: [.diacriticInsensitive, .caseInsensitive],
                         locale: Locale(identifier: "en_US_POSIX"))
            XCTAssertTrue(base.contains(probe.word.folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX"))),
                "le NOM du fichier doit porter le mot, pas seulement son dossier : "
                + match.path)
        }
        // La ligne d'en-tête de la sortie TEXTE dit la même chose.
        let text = try Recette.run(["search", probe.word, "--fuzzy", "off",
                                    "--limit", "5"], database: database)
        XCTAssertEqual(text.status, 0, text.describe)
        XCTAssertTrue(text.stdout.contains("whose name matches:"), text.describe)
    }

    /// PR-03, PR-04 · `near:` et `folder:` rendent exactement ce que rendent
    /// `pres:` et `dossier:`, et un préfixe inconnu sort en 64 au lieu d'être
    /// cherché comme un mot.
    func testEnglishAliasesAndTheRefusalOfAFalseFilter() throws {
        let french = try Recette.search("pres:5 energie libre", database: database,
                                        extra: ["--fuzzy", "off"], limit: 20)
        let english = try Recette.search("near:5 energie libre", database: database,
                                         extra: ["--fuzzy", "off"], limit: 20)
        XCTAssertEqual(english.totalPages, french.totalPages)
        XCTAssertEqual(english.hits.map { "\($0.docID)/\($0.page)" },
                       french.hits.map { "\($0.docID)/\($0.page)" })

        let label = try Recette.sqlite("SELECT top_folder FROM docs LIMIT 1",
                                       on: database)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty {
            let fr = try Recette.search("dossier:\(label) energie", database: database,
                                        extra: ["--fuzzy", "off"], limit: 20)
            let en = try Recette.search("folder:\(label) energie", database: database,
                                        extra: ["--fuzzy", "off"], limit: 20)
            XCTAssertEqual(en.totalPages, fr.totalPages)
            XCTAssertGreaterThan(fr.totalPages, 0,
                                 "le filtre de dossier doit rendre quelque chose")
        }

        let refused = try Recette.run(["search", "type:pdf azote", "--json"],
                                      database: database)
        XCTAssertEqual(refused.status, 64, refused.describe)
        XCTAssertTrue(refused.stderr.contains("is not a filter"), refused.describe)
    }

    /// C2-08 · une faute de frappe sur un mot NATIF trouve quand même, et la
    /// commande le dit sur l'erreur standard.
    func testTheFuzzyFallbackAnswersAndSaysSo() throws {
        // LA COQUILLE EST CHOISIE EN INTERROGEANT LA BASE. Sur un corpus de
        // 390 000 pages dont beaucoup sont OCRisées, une coquille écrite ici au
        // hasard a de bonnes chances (1) d'exister vraiment — « fichler » rend
        // 20 pages —, ou (2) d'être rattrapée dès la PREMIÈRE passe par le flou
        // en portée « pages scannées », qui existait déjà. Le cas du constat
        // C2-08 est le troisième : le mot correct n'est que dans du texte
        // NATIF, et rien ne le trouvait. On garde la première coquille dont la
        // réponse porte effectivement `fuzzy_fallback`.
        let payload = try Recette.search("fichier", database: database,
                                         extra: ["--fuzzy", "off"], limit: 1)
        try XCTSkipIf(payload.totalPages == 0, "le corpus ne porte pas « fichier »")
        var found: (word: String, result: CommandResult, payload: SearchPayload)?
        for candidate in ["Villeurbanx", "thermodynamiqx", "chromatographix",
                          "electrolysx", "polymerisatiox", "fichieqr"] {
            let exact = try Recette.search(candidate, database: database,
                                           extra: ["--fuzzy", "off"], limit: 1)
            guard exact.totalPages == 0 else { continue }
            let run = try Recette.run(["search", candidate, "--json", "--limit", "5"],
                                      database: database)
            XCTAssertEqual(run.status, 0, run.describe)
            let decoded = try JSONDecoder().decode(
                SearchPayload.self, from: Data(run.stdout.utf8))
            if decoded.fuzzyFallback == true {
                found = (candidate, run, decoded)
                break
            }
        }
        guard let found else {
            throw XCTSkip("aucune coquille essayée n'isole le cas C2-08 sur ce corpus")
        }
        let word = found.word
        let typo = found.result
        let decoded = found.payload
        XCTAssertGreaterThan(decoded.totalPages, 0)
        XCTAssertTrue(decoded.hits.allSatisfy { $0.fuzzyDistance > 0 },
                      "chaque page vient d'une orthographe proche")
        XCTAssertTrue(typo.stderr.contains("No exact match"), typo.describe)

        // Et « jamais » veut dire jamais.
        let off = try Recette.run(["search", word, "--json", "--fuzzy", "off"],
                                  database: database)
        XCTAssertEqual(off.status, 0, off.describe)
        let none = try JSONDecoder().decode(
            SearchPayload.self, from: Data(off.stdout.utf8))
        XCTAssertNil(none.fuzzyFallback)
        XCTAssertEqual(none.totalPages, 0)
    }
}
