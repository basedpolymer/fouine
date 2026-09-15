// VersionedCorpusTests.swift — LA RECETTE PORTABLE (audit E5, D12/M23, S3).
// Propriété : A-Recette.
//
// Tout ce que la recette du §8 sait dire d'un vrai document, sur un corpus qui
// est DANS LE DÉPÔT : `git clone && make test` l'exécute, sur n'importe quelle
// machine, sans `Tests/Fixtures/paths.json` ni `FOUINE_TEST_DB`. C'est
// exactement ce qui manquait — « aucune fixture binaire versionnée », « zéro
// test sur `fouine/` » (audit D12/M23) — et ce que l'audit E5 appelle « la
// condition de toute contribution ».
//
// ═══ RÈGLE D'ASSERTION ══════════════════════════════════════════════════════
//
// Tout est affirmé sur les SORTIES `--json`, les CODES DE SORTIE et l'ÉTAT DE
// LA BASE. Jamais sur une phrase de la CLI : ses libellés passent à l'anglais
// dans une vague ultérieure, et une recette qui casserait sur une traduction ne
// testerait pas le produit mais sa prose.
//
// ═══ OÙ ÇA ÉCRIT ════════════════════════════════════════════════════════════
//
// Base jetable, racine jetable, corpus COPIÉ hors du dépôt (voir
// CorpusRecette.swift). Rien de personnel, rien en production — la garantie de
// l'audit S3 tient mot pour mot ici.

import Foundation
import XCTest
import FouineCore
import FouineExtract

final class VersionedCorpusTests: XCTestCase {

    // Un seul index pour toutes les assertions qui ne MODIFIENT rien : la passe
    // d'indexation du corpus coûte ~1 s, mais la répéter huit fois en coûterait
    // huit, et rien ne le justifie. Les deux tests qui touchent au disque
    // (OCR, document déplacé) fabriquent chacun le leur.
    private static var shared: Recette.CorpusScratch?

    private var scratch: Recette.CorpusScratch!
    private var database: URL { scratch.database }
    private var manifest: CorpusManifest { scratch.manifest }

    override func setUpWithError() throws {
        if Self.shared == nil {
            Self.shared = try Recette.makeIndexedCorpus("lecture")
        }
        scratch = try XCTUnwrap(Self.shared)
    }

    override class func tearDown() {
        if let shared {
            try? FileManager.default.removeItem(at: shared.directory)
        }
        shared = nil
        super.tearDown()
    }

    // MARK: - 1. Ce que le crawl a vu

    /// Le manifeste annonce combien de fichiers le crawler doit voir, lesquels
    /// s'extraient, lesquels se sautent, et lequel doit rester INVISIBLE. On le
    /// vérifie ligne à ligne dans `docs` — pas sur le résumé imprimé.
    func testCrawlAndExtractMatchTheManifest() throws {
        let documents = try Recette.indexedDocuments(under: scratch.root,
                                                     on: database)
        let expectedIndexed = manifest.files
            .filter { $0.kind != "ignored" && $0.exists }
        XCTAssertEqual(documents.count, expectedIndexed.count,
                       "docs : \(documents.keys.sorted())")

        for entry in manifest.files {
            switch entry.state {
            case "absent":
                XCTAssertNil(documents[entry.name],
                             "« \(entry.name) » est hors du registre "
                             + "d'extraction : le crawler ne doit pas le voir")
            case "skipped":
                let row = try XCTUnwrap(documents[entry.name], entry.name)
                // DocState.skipped == 3 : un format refusé PROPREMENT, pas un
                // document manquant (§4.2, §5.3).
                XCTAssertEqual(row.state, 3, "\(entry.name) : docs.state")
                XCTAssertEqual(row.ext, entry.ext)
            case "failed":
                // DocState.failed == 2, avec le MOTIF dans `docs.err`. C'est le
                // piège réseau `.doc` (A1-01) : refusé sur ses octets de tête,
                // et l'utilisateur peut lire pourquoi.
                let row = try XCTUnwrap(documents[entry.name], entry.name)
                XCTAssertEqual(row.state, 2, "\(entry.name) : docs.state")
                XCTAssertEqual(row.ext, entry.ext)
                if let expected = entry.err {
                    XCTAssertTrue(row.err?.contains(expected) == true,
                                  "\(entry.name) : docs.err = "
                                  + "« \(row.err ?? "nil") », attendu "
                                  + "« \(expected) »")
                }
            case "extracted":
                guard entry.exists else { continue }   // djvulibre absent à la génération
                let row = try XCTUnwrap(documents[entry.name], entry.name)
                if !entry.isSupportedOnSystem {
                    // Si l'outil requis (djvulibre) est absent sur la machine hôte (CI),
                    // le fichier est refusé proprement en docs.state == .skipped (3).
                    XCTAssertEqual(row.state, 3, "\(entry.name) : docs.state (requires \(entry.requires!))")
                    XCTAssertEqual(row.ext, entry.ext)
                    continue
                }
                XCTAssertEqual(row.state, 1, "\(entry.name) : docs.state")
                XCTAssertEqual(row.ext, entry.ext)
                if let pages = entry.pages {
                    XCTAssertEqual(row.pages, pages, "\(entry.name) : n_pages")
                }
                // OCRState.queued == 1 pour les fixtures sans couche texte.
                if entry.witnesses.contains(where: { $0.source == "ocr_accurate" }) {
                    XCTAssertEqual(row.ocrState, 1,
                                   "\(entry.name) : ses pages doivent etre en "
                                   + "file d'OCR")
                }
            default:
                XCTFail("état inconnu dans le manifeste : \(entry.state)")
            }
        }
    }

    /// Le crawl est idempotent : une seconde passe ne doit rien ajouter ni
    /// retirer. On l'affirme sur les compteurs de `status --json`, pas sur le
    /// « ajoutés 0 » imprimé.
    func testSecondIndexPassChangesNothing() throws {
        let before = try statusJSON()
        let again = try Recette.run(["index"], database: database, timeout: 300)
        XCTAssertEqual(again.status, 0, again.describe)
        let after = try statusJSON()
        for key in ["docs_total", "docs_extracted", "docs_skipped",
                    "pages_indexed", "pages_native", "ocr_queue_len"] {
            XCTAssertEqual(after[key] as? Int, before[key] as? Int,
                           "« \(key) » a bougé sur une seconde passe")
        }
    }

    // MARK: - 2. Les six formes de requête

    /// Chaque terme témoin NATIF du manifeste sort aux pages annoncées, et
    /// seulement là. Une seule boucle, mais c'est le cœur de la recette : elle
    /// couvre le terme exact, l'expression, le préfixe, la proximité et le flou,
    /// puisque le manifeste porte pour chacun la requête exacte.
    func testEveryNativeWitnessAnswersAtTheAnnouncedPages() throws {
        var checked = 0
        // `requires == nil` et non `isSupportedOnSystem` : le filtre doit être
        // le MÊME sur toutes les machines. Les fixtures à outil externe (djvu)
        // ont leur test à part, qui se SAUTE bruyamment quand l'outil manque —
        // voir `testDjvuWitnessesAnswerAtTheAnnouncedPages` et l'audit B1-08.
        for entry in manifest.files where entry.exists && entry.requires == nil {
            for witness in entry.witnesses where witness.source == "native" {
                let query = witness.query ?? witness.term
                // Le flou est EXPLICITE : `auto` ne s'appliquerait qu'aux pages
                // OCR (--fuzzy-scope ocr par défaut), et un terme natif exact ne
                // doit rien devoir au hasard.
                let extra = query == "sublimatlon"
                    ? ["--fuzzy", "on", "--fuzzy-scope", "all"]
                    : ["--fuzzy", "off"]
                let pages = try Recette.pages(of: query, in: entry.name,
                                              database: database, extra: extra)
                XCTAssertEqual(pages, witness.pages,
                               "\(entry.name) · « \(query) » : pages obtenues "
                               + "\(pages), attendues \(witness.pages)")
                checked += 1
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 20,
                                    "moins de 20 requetes temoins : le corpus "
                                    + "a maigri")
    }

    /// Les témoins djvu, SÉPARÉMENT — et c'est tout l'intérêt (audit B1-08).
    ///
    /// Avant le 02/09/2026, ces témoins vivaient dans la boucle ci-dessus,
    /// derrière un filtre `entry.isSupportedOnSystem` : sur un runner sans
    /// djvulibre, l'entrée sortait du lot et **plus rien du contenu extrait
    /// n'était contrôlé**, sans que le compteur bouge d'une unité. Les runs
    /// 33646864731 (rouge) et 33648319798 (vert) affichaient exactement les
    /// mêmes 494/11 et 49/27 : la « réparation » avait rendu la perte
    /// silencieuse au lieu de l'empêcher.
    ///
    /// Ici, l'absence de l'outil est un `XCTSkip` — donc une ligne « tests
    /// skipped » qui augmente, donc un fait visible dans le journal de la CI.
    /// `XCTSkipIf` est appelé UNE FOIS, avant la boucle : dans une boucle, il
    /// interromprait tout le test dès la première entrée et emporterait les
    /// suivantes.
    ///
    /// La CI installe djvulibre (`brew install djvulibre` dans `ci.yml`) : ce
    /// test doit s'y EXÉCUTER. Le voir sauté sur le runner est le signal que
    /// cette étape a disparu.
    func testDjvuWitnessesAnswerAtTheAnnouncedPages() throws {
        let djvu = manifest.files.filter { $0.requires == "djvulibre" }
        XCTAssertFalse(djvu.isEmpty,
                       "le manifeste ne porte plus aucune fixture djvu : "
                       + "DJVU est pourtant l'un des formats mis en avant")

        try XCTSkipIf(DjvuExtractor.tool() == nil,
                      "djvulibre absent de cette machine : "
                      + "\(djvu.map(\.name).joined(separator: ", ")) — "
                      + "le contenu extrait n'est PAS contrôlé "
                      + "(`brew install djvulibre`)")

        let documents = try Recette.indexedDocuments(under: scratch.root,
                                                     on: database)
        var checked = 0
        for entry in djvu {
            XCTAssertTrue(entry.exists,
                          "\(entry.name) : fixture absente du dépôt alors que "
                          + "djvulibre est installé — `make fixtures`")
            guard entry.exists else { continue }

            // L'extraction a bien eu lieu : DocState.extracted == 1, et non le
            // refus propre (3) qu'on observe quand l'outil manque.
            let row = try XCTUnwrap(documents[entry.name], entry.name)
            XCTAssertEqual(row.state, 1, "\(entry.name) : docs.state")
            XCTAssertEqual(row.ext, entry.ext)
            if let pages = entry.pages {
                XCTAssertEqual(row.pages, pages, "\(entry.name) : n_pages")
            }

            for witness in entry.witnesses where witness.source == "native" {
                let query = witness.query ?? witness.term
                let pages = try Recette.pages(of: query, in: entry.name,
                                              database: database,
                                              extra: ["--fuzzy", "off"])
                XCTAssertEqual(pages, witness.pages,
                               "\(entry.name) · « \(query) » : pages obtenues "
                               + "\(pages), attendues \(witness.pages)")
                checked += 1
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 2,
                                    "moins de 2 temoins djvu : la couverture "
                                    + "du format a maigri")
    }

    /// L'EXCLUSION porte sur le DOCUMENT, pas sur la page (arbitrage T5) : c'est
    /// exactement ce que le corpus est fait pour montrer. « polymere » vit dans
    /// deux documents ; « reticulation » n'est que dans l'un des deux.
    func testExclusionRemovesTheWholeDocument() throws {
        let all = try Recette.search("polymere", database: database,
                                     extra: ["--fuzzy", "off"])
        XCTAssertEqual(all.totalDocs, 2, all.hits.map(\.path).description)
        XCTAssertEqual(all.totalPages, 3)

        let filtered = try Recette.search("polymere -reticulation",
                                          database: database,
                                          extra: ["--fuzzy", "off"])
        XCTAssertEqual(filtered.totalDocs, 1)
        XCTAssertEqual(filtered.totalPages, 1)
        XCTAssertTrue(filtered.hits.allSatisfy { $0.path.hasSuffix("memo.rtf") },
                      filtered.hits.map(\.path).description)
    }

    /// Le repli d'accents du tokenizer (`unicode61 remove_diacritics 2`) :
    /// « cinétique » est écrit avec son accent dans lisezmoi.md, et les deux
    /// formes doivent rendre la même page.
    /// Le lien profond de chaque page trouvée (lot INT-L1).
    ///
    /// Le corpus versionné est indexé depuis un dossier du volume de la
    /// machine : c'est donc la forme CANONIQUE — par chemin absolu, celle qui
    /// survit à une réindexation — qui doit sortir, et non le repli par
    /// identifiant. C'est le seul endroit du dépôt où la distinction se joue
    /// sur un vrai index ; les tests unitaires du serveur MCP travaillent sur
    /// un volume factice.
    func testEveryJSONHitCarriesADeepLink() throws {
        let payload = try Recette.search("cinetique", database: database,
                                         extra: ["--fuzzy", "off"])
        XCTAssertFalse(payload.hits.isEmpty, "aucun hit à vérifier")
        for hit in payload.hits {
            XCTAssertTrue(hit.link.hasPrefix("fouine://open?path=/"), hit.link)
            XCTAssertTrue(hit.link.contains("page=\(hit.page)"), hit.link)
        }
    }

    func testAccentFoldingIsSymmetric() throws {
        let bare = try Recette.search("cinetique", database: database,
                                      extra: ["--fuzzy", "off"])
        let accented = try Recette.search("cinétique", database: database,
                                          extra: ["--fuzzy", "off"])
        XCTAssertEqual(bare.totalPages, 1)
        XCTAssertEqual(accented.totalPages, bare.totalPages)
        XCTAssertEqual(accented.hits.map(\.path), bare.hits.map(\.path))
    }

    /// Contre-épreuves : ce que la recherche ne doit PAS trouver. Sans elles,
    /// un index qui rendrait tout sur tout passerait la boucle ci-dessus.
    func testCounterProofs() throws {
        // (a) le contenu de <script> et <style> n'entre pas dans l'index.
        let script = try Recette.search("\"ce script ne doit pas\"",
                                        database: database,
                                        extra: ["--fuzzy", "off"])
        XCTAssertEqual(script.totalPages, 0, script.hits.map(\.path).description)

        // (b) sans le flou, la faute de frappe ne trouve rien : c'est ce qui
        //     donne son sens au test flou.
        let typo = try Recette.search("sublimatlon", database: database,
                                      extra: ["--fuzzy", "off"])
        XCTAssertEqual(typo.totalPages, 0)

        // (c) l'expression exacte est plus stricte que la conjonction : la
        //     page 4 porte « Markovnikov » ET « regle », mais pas cote a cote.
        let conjunction = try Recette.pages(of: "markovnikov regle",
                                            in: "chimie-organique.pdf",
                                            database: database,
                                            extra: ["--fuzzy", "off"])
        XCTAssertEqual(conjunction, [2, 4])
        let phrase = try Recette.pages(of: "\"regle de markovnikov\"",
                                       in: "chimie-organique.pdf",
                                       database: database,
                                       extra: ["--fuzzy", "off"])
        XCTAssertEqual(phrase, [2])

        // (d) un préfixe de moins de quatre caractères est REFUSÉ (§4.1, D3) :
        //     une SORTIE NON NULLE et aucun JSON — surtout pas un résultat vide,
        //     qui laisserait croire à un index incomplet.
        //
        //     Le code est 64, celui des erreurs d'ARGUMENT. La divergence
        //     relevée ici (le code était 1, le fourre-tout des pannes) a été
        //     tranchée dans le sens de `docs/cli.md` § codes de sortie au
        //     palier 3.5 : une requête que l'analyseur refuse est une faute de
        //     frappe, comme un argument manquant, et `root add` comme
        //     `config get` refusaient déjà les leurs en 64.
        let short = try Recette.run(["search", "chr*", "--json"],
                                    database: database)
        XCTAssertEqual(short.status, 64, short.describe)
        XCTAssertTrue(short.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty,
                      "un refus de requête ne doit produire AUCUN JSON : "
                      + short.describe)
    }

    /// Les facettes du §4.3, sur un corpus dont on connaît la composition.
    func testFacetsCountTheRightThings() throws {
        let payload = try Recette.search("polymere", database: database,
                                         extra: ["--fuzzy", "off",
                                                 "--facet", "ext"])
        let facet = try XCTUnwrap(payload.facets?["ext"])
        XCTAssertEqual(facet["pdf"], 2)
        XCTAssertEqual(facet["rtf"], 1)
    }

    // MARK: - 3. `status --json` et `doctor --json`

    private func statusJSON() throws -> [String: Any] {
        let result = try Recette.run(["status", "--json"], database: database)
        XCTAssertEqual(result.status, 0, result.describe)
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    /// Les compteurs de `status --json` sont ceux du corpus, et non des chiffres
    /// plausibles : on les confronte au manifeste.
    func testStatusJSONCountsTheVersionedCorpus() throws {
        let payload = try statusJSON()
        let indexable = manifest.files.filter { $0.kind != "ignored" && $0.exists }
        let skipped = indexable.filter { $0.state == "skipped" || !$0.isSupportedOnSystem }
        // Le corpus porte désormais UN document qui doit ÉCHOUER : le piège
        // réseau `.doc` (A1-01), refusé sur ses octets de tête. C'est un état
        // attendu, décrit au manifeste, et non un accident de recette.
        let failed = indexable.filter { $0.state == "failed" }
        let nativePages = indexable
            .filter { $0.state == "extracted" && $0.isSupportedOnSystem
                && !$0.witnesses.contains { $0.source == "ocr_accurate" } }
            .compactMap(\.pages).reduce(0, +)
        let ocrPages = indexable
            .filter { $0.witnesses.contains { $0.source == "ocr_accurate" } && $0.isSupportedOnSystem }
            .compactMap(\.pages).reduce(0, +)

        XCTAssertEqual(payload["docs_total"] as? Int, indexable.count)
        XCTAssertEqual(payload["docs_skipped"] as? Int, skipped.count)
        XCTAssertEqual(payload["docs_failed"] as? Int, failed.count,
                       "seules les fixtures « failed » du manifeste doivent "
                       + "échouer : \(failed.map(\.name))")
        XCTAssertEqual(failed.count, 2,
                       "deux documents du corpus doivent échouer — le piège "
                       + "réseau .doc (A1-01) et le .key sans aperçu (audit D2 § 5.12)")
        XCTAssertEqual(payload["pages_native"] as? Int, nativePages)
        // Avant toute passe OCR, la file porte exactement les pages scannées.
        XCTAssertEqual(payload["ocr_queue_len"] as? Int, ocrPages)
        XCTAssertEqual(payload["pages_ocr_accurate"] as? Int, 0)

        // Une seule racine, montée et lisible.
        let roots = try XCTUnwrap(payload["roots"] as? [[String: Any]])
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0]["label"] as? String, scratch.label)
        XCTAssertEqual(roots[0]["mounted"] as? Bool, true)
        XCTAssertEqual(roots[0]["readable"] as? Bool, true)
    }

    /// `doctor --json` sur un index sain : sortie 0, `ok` vrai, racine lisible.
    /// C'est le premier geste de diagnostic du produit ; il n'avait aucun test
    /// portable.
    func testDoctorJSONIsHealthyOnTheVersionedCorpus() throws {
        let result = try Recette.run(["doctor", "--json"], database: database)
        XCTAssertEqual(result.status, 0, result.describe)
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
        let payload = try XCTUnwrap(object as? [String: Any])

        XCTAssertEqual(payload["ok"] as? Bool, true, result.describe)
        XCTAssertEqual(payload["db_path"] as? String, database.path)
        XCTAssertNotNil(payload["db_bytes"] as? Int)
        let roots = try XCTUnwrap(payload["roots"] as? [[String: Any]])
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0]["readable"] as? Bool, true)
        // `djvused` est une CLÉ, pas une exigence : présent ou non, `doctor`
        // doit la rendre et rester en 0.
        XCTAssertTrue(payload.keys.contains("djvused"))
        XCTAssertTrue(payload.keys.contains("semantic_model"))
    }

    /// `doctor` sort en 5 quand une racine devient illisible — et le dit dans le
    /// JSON. Vérifié sur une racine JETABLE qu'on déplace, jamais sur une racine
    /// réelle.
    func testDoctorReportsAnUnreadableRoot() throws {
        let own = try Recette.makeIndexedCorpus("doctor-racine-absente")
        defer { try? FileManager.default.removeItem(at: own.directory) }

        try FileManager.default.moveItem(
            at: own.root,
            to: own.directory.appendingPathComponent("racine-partie"))

        let result = try Recette.run(["doctor", "--json"], database: own.database)
        XCTAssertEqual(result.status, 5, result.describe)
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
        let payload = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(payload["ok"] as? Bool, false)
        let roots = try XCTUnwrap(payload["roots"] as? [[String: Any]])
        XCTAssertEqual(roots.first?["readable"] as? Bool, false)
    }

    // MARK: - 4. Le piège S1, de bout en bout

    /// L'archive piégée passe l'indexation sans qu'aucune de ses deux pages ne
    /// disparaisse. Sans le `--` de `Bsdtar`, l'entrée « --exclude=001.png »
    /// RETIRAIT l'autre image de la sortie : le document n'aurait qu'une page.
    ///
    /// Le test de non-exécution (marqueur sur disque) reste dans
    /// FouineExtractTests/GuardTests.swift : la fixture VERSIONNÉE désigne
    /// /usr/bin/false, inerte, parce qu'un chemin de marqueur ne peut pas être
    /// versionné.
    func testTrappedArchiveKeepsBothPagesAndIndexesCleanly() throws {
        let documents = try Recette.indexedDocuments(under: scratch.root,
                                                     on: database)
        let row = try XCTUnwrap(documents["pieges/archive-piegee.cbz"])
        XCTAssertEqual(row.state, 1, "l'archive piégée doit s'extraire, pas échouer")
        XCTAssertEqual(row.pages, 2,
                       "une seule page = « --exclude=001.png » a été honorée "
                       + "comme une option (audit S1)")
        XCTAssertEqual(row.ocrState, 1, "deux pages image, donc deux pages en file")
    }

    // MARK: - 5. OCR

    /// La passe OCR retrouve les termes témoins des pages SCANNÉES, à la bonne
    /// page, et le JSON les annonce comme venant de l'OCR. C'est le seul chemin
    /// possible : ces pages n'ont aucune couche texte (vérifié sans base par
    /// FouineExtractTests.CorpusFixturesTests).
    func testOCRRecoversTheScannedWitnesses() throws {
        let own = try Recette.makeIndexedCorpus("ocr", withOCR: true)
        defer { try? FileManager.default.removeItem(at: own.directory) }

        // La file est vidée, et les pages sont comptées comme OCRisées.
        let status = try Recette.run(["status", "--json"], database: own.database)
        XCTAssertEqual(status.status, 0, status.describe)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(status.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(payload["ocr_queue_len"] as? Int, 0)

        let ocrPages = own.manifest.files
            .filter { $0.witnesses.contains { $0.source == "ocr_accurate" } }
            .compactMap(\.pages).reduce(0, +)
        XCTAssertEqual(payload["pages_ocr_accurate"] as? Int, ocrPages)

        // `ocr_pages` PAR DOCUMENT (lot MN1, reste du constat PM-16a) : la clé
        // manquait à `fouine list --json`, que l'outil MCP porte depuis MC3.
        // Même définition : les pages dont le TEXTE a été lu sur l'image.
        let listed = try Recette.run(["list", "--json", "--limit", "500"],
                                     database: own.database)
        XCTAssertEqual(listed.status, 0, listed.describe)
        let documents = try XCTUnwrap(try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(listed.stdout.utf8))
                as? [String: Any])["documents"] as? [[String: Any]])
        var scanned = 0
        for document in documents {
            let path = document["path"] as? String ?? ""
            let name = path.components(separatedBy: "/").last ?? ""
            let count = try XCTUnwrap(document["ocr_pages"] as? Int,
                                      "clé `ocr_pages` absente de \(name)")
            // PAR SUFFIXE DU CHEMIN, comme le reste de la suite : le manifeste
            // nomme `pieges/archive-piegee.cbz`, pas son dernier composant, et
            // comparer les noms nus faisait passer une archive piégée — deux
            // pages lues sur l'image — pour un document sans OCR.
            let entry = own.manifest.files.first { path.hasSuffix($0.name) }
            let expectsOCR = entry?.witnesses
                .contains { $0.source == "ocr_accurate" } ?? false
            if expectsOCR {
                XCTAssertEqual(count, entry?.pages,
                               "\(name) : toutes ses pages viennent de l'image")
            } else {
                XCTAssertEqual(count, 0, "\(name) : aucune page lue sur l'image")
            }
            scanned += count
        }
        XCTAssertEqual(scanned, ocrPages,
                       "la somme par document vaut le compte de `status`")

        var checked = 0
        for entry in own.manifest.files where entry.exists {
            for witness in entry.witnesses where witness.source == "ocr_accurate" {
                let hits = try Recette.search(witness.query ?? witness.term,
                                              database: own.database,
                                              extra: ["--fuzzy", "off"]).hits
                    .filter { $0.path.hasSuffix(entry.name) }
                XCTAssertEqual(hits.map(\.page).sorted(), witness.pages,
                               "\(entry.name) · « \(witness.term) »")
                for hit in hits {
                    XCTAssertEqual(hit.source, "ocr_accurate",
                                   "\(entry.name) p.\(hit.page) : ce terme ne "
                                   + "peut venir que de l'OCR")
                    XCTAssertEqual(hit.engine, "vision")
                }
                checked += 1
            }
        }
        XCTAssertEqual(checked, 6, "six termes témoins d'OCR au manifeste")

        // Le flou sur une page OCR est le régime PAR DÉFAUT (--fuzzy-scope ocr) :
        // c'est précisément pour rattraper les fautes de reconnaissance qu'il
        // existe (§5.5.2). Une faute de frappe à distance 1 doit passer.
        let fuzzy = try Recette.search("tellurlum", database: own.database,
                                       extra: ["--fuzzy", "on"])
        XCTAssertEqual(fuzzy.totalPages, 1, fuzzy.hits.map(\.path).description)
        XCTAssertEqual(fuzzy.hits.first?.fuzzyDistance, 1)
        XCTAssertEqual(fuzzy.hits.first?.source, "ocr_accurate")
    }

    /// `--source` (lot P3) : le filtre de PROVENANCE partitionne le corpus, et
    /// il porte sur la page — pas sur le document. Sur la base réelle, un même
    /// PDF mêle des planches scannées et des pages tapées ; ici le corpus les
    /// met dans deux fichiers, ce qui suffit à prouver le partage et les
    /// totaux.
    func testSourceFilterSplitsPagesByOrigin() throws {
        let own = try Recette.makeIndexedCorpus("provenance", withOCR: true)
        defer { try? FileManager.default.removeItem(at: own.directory) }

        // `--raw-fts` : le seul moyen d'apparier d'un coup un témoin OCR et un
        // témoin natif — aucun terme du manifeste n'est porté par les deux.
        let both = ["--raw-fts", "--fuzzy", "off"]
        let query = "tellurium OR polymere"
        let tout = try Recette.search(query, database: own.database, extra: both)
        let scanne = try Recette.search(query, database: own.database,
                                        extra: both + ["--source", "ocr"])
        let natif = try Recette.search(query, database: own.database,
                                       extra: both + ["--source", "native"])
        XCTAssertGreaterThan(scanne.totalPages, 0)
        XCTAssertGreaterThan(natif.totalPages, 0)
        XCTAssertEqual(scanne.totalPages + natif.totalPages, tout.totalPages,
                       "les deux provenances partitionnent le jeu")
        XCTAssertTrue(scanne.hits.allSatisfy { $0.source != "native" },
                      scanne.hits.map(\.source).description)
        XCTAssertTrue(natif.hits.allSatisfy { $0.source == "native" },
                      natif.hits.map(\.source).description)

        // Un témoin qui n'existe QUE sur une page scannée disparaît du natif.
        let horsNatif = try Recette.search("tellurium", database: own.database,
                                           extra: ["--fuzzy", "off",
                                                   "--source", "native"])
        XCTAssertEqual(horsNatif.totalPages, 0)

        // La requête publiée dit le filtre : sans cela, deux exécutions dont
        // les totaux diffèrent seraient indiscernables dans un journal.
        let brut = try Recette.run(["search", "tellurium", "--json",
                                    "--source", "ocr"], database: own.database)
        XCTAssertEqual(brut.status, 0, brut.describe)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(brut.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(payload["source"] as? String, "ocr")
        XCTAssertNil(try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(try Recette.run(["search", "tellurium", "--json"],
                                       database: own.database).stdout.utf8))
                as? [String: Any])["source"],
                     "sans filtre, aucune clé de plus dans le JSON du §4.3")

        // Une valeur inconnue est une erreur d'ARGUMENT, comme `--fuzzy zzz`.
        let refus = try Recette.run(["search", "tellurium", "--source", "scanned"],
                                    database: own.database)
        XCTAssertEqual(refus.status, 64, refus.describe)
    }

    // MARK: - 6. Documents déplacés et renommés

    /// Un fichier renommé sous la même racine : le crawl complet doit retirer
    /// l'ancien chemin et indexer le nouveau, sans perdre le contenu. C'est T9
    /// à l'échelle du fichier — `MovedRootTests` couvre la RACINE déplacée.
    func testRenamedAndRemovedFilesAreReconciled() throws {
        let own = try Recette.makeIndexedCorpus("deplacement")
        defer { try? FileManager.default.removeItem(at: own.directory) }
        let fm = FileManager.default

        // (a) renommage, dans un sous-dossier neuf.
        let archives = own.root.appendingPathComponent("archives", isDirectory: true)
        try fm.createDirectory(at: archives, withIntermediateDirectories: true)
        try fm.moveItem(at: own.file("memo.rtf"),
                        to: archives.appendingPathComponent("memo-2026.rtf"))
        // (b) suppression pure.
        try fm.removeItem(at: own.file("journal.log"))

        // `--full` : c'est la passe qui détecte les SUPPRESSIONS (§4.3).
        let crawl = try Recette.run(["crawl", "--full"], database: own.database,
                                    timeout: 300)
        XCTAssertEqual(crawl.status, 0, crawl.describe)
        let extract = try Recette.run(["extract"], database: own.database,
                                      timeout: 300)
        XCTAssertEqual(extract.status, 0, extract.describe)

        let documents = try Recette.indexedDocuments(under: own.root,
                                                     on: own.database)
        XCTAssertNil(documents["memo.rtf"], "l'ancien chemin doit disparaître")
        XCTAssertNil(documents["journal.log"], "le fichier supprimé aussi")
        let moved = try XCTUnwrap(documents["archives/memo-2026.rtf"])
        XCTAssertEqual(moved.state, 1)

        // Le contenu suit le fichier : « azeotrope » répond au NOUVEAU chemin…
        let hits = try Recette.search("azeotrope", database: own.database,
                                      extra: ["--fuzzy", "off"]).hits
        XCTAssertEqual(hits.count, 1, hits.map(\.path).description)
        XCTAssertTrue(hits[0].path.hasSuffix("archives/memo-2026.rtf"),
                      hits[0].path)
        // …et le terme du fichier supprimé ne répond plus du tout.
        let gone = try Recette.search("stoechiometrie", database: own.database,
                                      extra: ["--fuzzy", "off"])
        XCTAssertEqual(gone.totalPages, 0)
    }

    func testPaginationOffsetAndDisjointPages() throws {
        let query = "enthalpie"
        let page1 = try Recette.search(query, database: database,
                                       extra: ["--offset", "0"], limit: 2)
        XCTAssertEqual(page1.offset, 0)
        if page1.totalPages > 2 {
            XCTAssertEqual(page1.hasMore, true)
            let page2 = try Recette.search(query, database: database,
                                           extra: ["--offset", "2"], limit: 2)
            XCTAssertEqual(page2.offset, 2)
            let keys1 = Set(page1.hits.map { "\($0.docID):\($0.page)" })
            let keys2 = Set(page2.hits.map { "\($0.docID):\($0.page)" })
            XCTAssertTrue(keys1.isDisjoint(with: keys2))
        }
        let endPage = try Recette.search(query, database: database,
                                         extra: ["--offset", "\(page1.totalPages)"], limit: 2)
        XCTAssertEqual(endPage.hasMore, false)

        let neg = try Recette.run(["search", query, "--offset", "-5"], database: database)
        XCTAssertEqual(neg.status, 64)
        let bad = try Recette.run(["search", query, "--offset", "xyz"], database: database)
        XCTAssertEqual(bad.status, 64)
    }

    /// `--limit=-5` TUAIT le programme : SIGILL, sortie 132, rien sur la sortie
    /// standard ni sur l'erreur standard (audit A1m-02, mesuré sur une copie de
    /// la base de production). `hits.prefix(limit)` piège sur une longueur
    /// négative, et SQLite lit `LIMIT -1` comme « aucune limite ». Une longueur
    /// négative est une erreur d'ARGUMENT, comme `--offset` : sortie 64, jamais
    /// un signal. `--depth` suit la même règle en mode hybride.
    func testNegativeLimitOrDepthExits64AndNeverCrashes() throws {
        for arguments in [["search", "azote", "--limit=-5"],
                          ["search", "azote", "--depth=-1", "--hybrid"]] {
            let result = try Recette.run(arguments, database: database)
            XCTAssertLessThan(result.status, 128,
                              "un argument refusé ne doit jamais tuer le "
                              + "programme — \(result.describe)")
            XCTAssertEqual(result.status, 64, result.describe)
        }
    }

    // MARK: - Une lecture ne fabrique pas d'index (audit A1m-09)

    /// `fouine search` sur un `FOUINE_DB` erroné CRÉAIT un index vide — schéma,
    /// `fouine.lock`, `-wal`, `-shm`, et le dossier au besoin — puis répondait
    /// « 0 résultat » indéfiniment. Une faute de frappe devenait un index
    /// fantôme sur le disque, et la seule chose que l'utilisateur lisait était
    /// « aucun résultat ».
    ///
    /// Sept commandes de lecture, un chemin qui n'existe pas : sortie 3
    /// (§ codes de sortie : « échec de base »), une phrase qui nomme le geste,
    /// et RIEN sur le disque.
    func testAReadCommandRefusesAMissingIndexAndCreatesNothing() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-a1m09-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        // Le dossier de la base n'existe pas non plus : `open(at:)` le créait.
        let absent = sandbox.appendingPathComponent("nulle-part/index.db")

        let readOnly = [
            ["search", "azote"],
            ["search", "azote", "--json"],
            ["status"],
            ["status", "--json"],
            ["doctor"],
            ["doctor", "--deep"],
            ["root", "list"],
            ["config", "list"],
            ["embed", "--status"],
        ]
        for arguments in readOnly {
            let result = try Recette.run(arguments, database: absent)
            XCTAssertEqual(result.status, 3,
                           "une lecture sur un index absent sort en 3 — "
                           + result.describe)
            XCTAssertTrue((result.stdout + result.stderr)
                            .contains("no Fouine index at"),
                          "le refus doit nommer le geste — " + result.describe)
        }

        var created: [String] = []
        if let walk = FileManager.default.enumerator(
            at: sandbox, includingPropertiesForKeys: nil) {
            for case let url as URL in walk {
                created.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(created, [],
                       "une lecture ne doit RIEN poser sur le disque")
    }

    /// …et sur un index qui EXISTE, une recherche n'installe plus de
    /// `fouine.lock` : elle ouvre en lecture seule.
    func testSearchOnARealIndexTakesNoWriteLock() throws {
        // Le verrou porte le nom de la base (BU-30) : sur la base jetable
        // `recette.db`, c'est `recette.lock` — chercher `fouine.lock` rendrait
        // ce test vide.
        let lock = FouinePaths.lockURL(for: database)
        try? FileManager.default.removeItem(at: lock)

        let result = try Recette.run(["search", "azote"], database: database)
        XCTAssertEqual(result.status, 0, result.describe)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path),
                       "`search` ne prend aucun verrou et ne doit donc pas "
                       + "créer `fouine.lock`")
    }

    /// `polymere OR catalyse` vidait le SQL de la requête interne sur l'erreur
    /// standard et sortait en **3** — le code de « base verrouillée ou
    /// corrompue » — pour une faute de frappe (audit A1m-07). C'est une erreur
    /// d'ARGUMENT : 64, avec la règle et le geste.
    func testUppercaseFTSOperatorExits64WithTheRule() throws {
        for word in ["AND", "OR", "NOT"] {
            let result = try Recette.run(["search", "enthalpie \(word) azote"],
                                         database: database)
            XCTAssertEqual(result.status, 64, result.describe)
            XCTAssertTrue(result.stderr.contains("-word"),
                          "le geste manque — \(result.describe)")
            XCTAssertFalse(result.stderr.contains("SQLite error"),
                           "vidage de SQL — \(result.describe)")
        }
        // En minuscules, ce sont des mots ordinaires : la recherche aboutit.
        let ordinary = try Recette.run(["search", "or", "--json"], database: database)
        XCTAssertEqual(ordinary.status, 0, ordinary.describe)
    }

    /// `dossier:Xyz` qui ne nomme aucune racine rendait « 0 page(s) », sortie 0 :
    /// indiscernable d'un corpus qui ne contient pas le terme (idée 5 de
    /// l'audit A1). C'est une erreur d'ARGUMENT, et le message nomme les
    /// étiquettes qui existent.
    func testUnknownFolderExits64AndNamesTheRealOnes() throws {
        let result = try Recette.run(["search", "dossier:Inconnu enthalpie"],
                                     database: database)
        XCTAssertEqual(result.status, 64, result.describe)
        XCTAssertTrue(result.stderr.contains("unknown folder “Inconnu”"),
                      result.describe)
        XCTAssertTrue(result.stderr.contains("yours are:"), result.describe)

        // L'étiquette RÉELLE, elle, filtre — et sa casse n'a pas d'importance.
        let label = try Recette.sqlite("SELECT label FROM roots LIMIT 1;",
                                       on: database)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(label.isEmpty, "le corpus de recette a une racine")
        let ok = try Recette.run(["search", "dossier:\(label) enthalpie", "--json"],
                                 database: database)
        XCTAssertEqual(ok.status, 0, ok.describe)
        let lowered = try Recette.run(
            ["search", "dossier:\(label.lowercased()) enthalpie", "--json"],
            database: database)
        XCTAssertEqual(lowered.status, 0, lowered.describe)
        XCTAssertEqual(lowered.stdout.contains("\"total_pages\" : 0"),
                       ok.stdout.contains("\"total_pages\" : 0"),
                       "la casse ne doit rien changer au filtre — \(lowered.describe)")
    }

    /// Le conseil « mot très courant » n'accompagne QUE les totaux bornés
    /// (au-delà de 50 000 pages, audit A1m-08). Sur un corpus de recette, aucun
    /// total ne l'est : la ligne doit rester muette, et le JSON sans
    /// `totals_approximate`. C'est la moitié éprouvable ici — le déclenchement
    /// est éprouvé sur seuil abaissé dans `FouineCoreTests.SearchTests`.
    func testVeryCommonWordAdviceStaysSilentOnAnOrdinarySearch() throws {
        let result = try Recette.run(["search", "enthalpie"], database: database)
        XCTAssertEqual(result.status, 0, result.describe)
        XCTAssertFalse(result.stdout.contains("very common word"), result.describe)
        let json = try Recette.run(["search", "enthalpie", "--json"],
                                   database: database)
        XCTAssertFalse(json.stdout.contains("totals_approximate"), json.describe)
    }
}
