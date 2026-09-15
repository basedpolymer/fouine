// RefusalRecetteTests.swift — les valeurs que l'index contredit sont refusées
// EN NOMMANT ce qui existe (constats CM-11, CM-24). Propriété : A-Recette.
//
// LE DÉFAUT. `--source pdf` sortait en 64 en listant les trois provenances et
// `dossier:Cour` en 64 en listant les racines ; `--lang xx`, `--in 999999`,
// `config set roots.pinned 999` et `--only <rien>` rendaient, eux, zéro
// résultat ou un réglage écrit, en silence. Zéro résultat n'est pas une
// information : c'est la même réponse que « votre corpus ne traite pas de ce
// sujet ».
//
// LA RÈGLE, celle de `FolderCheck` : on ne refuse que ce qu'on peut
// contredire. Le dernier test de ce fichier en est la contre-épreuve — un
// filtre dont la valeur EXISTE continue de rendre des résultats.

import Foundation
import XCTest

final class RefusalRecetteTests: XCTestCase {

    private var scratch: Recette.Scratch!
    private var database: URL { scratch.database }

    override func setUpWithError() throws {
        _ = try Recette.requireBinary()
        scratch = try Recette.makeIndexedScratch("refus")
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch.directory)
        }
    }

    /// La langue du corpus jetable, telle que l'index l'a déterminée. Sans
    /// aucune langue en base il n'y a rien à contredire : le test se saute.
    private func indexedLanguage() throws -> String {
        let raw = try Recette.sqlite(
            "SELECT lang FROM docs WHERE lang IS NOT NULL AND lang != '' LIMIT 1",
            on: database)
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw XCTSkip("aucune langue déterminée sur le corpus jetable : "
                          + "rien à contredire (règle de FolderCheck)")
        }
        return value
    }

    func testAnUnknownLanguageIsRefusedAndTheRealOnesAreNamed() throws {
        let known = try indexedLanguage()
        let res = try Recette.run(["search", "azote", "--lang", "xx"],
                                  database: database)
        XCTAssertEqual(res.status, 64, res.describe)
        XCTAssertTrue(res.stderr.contains("unknown language “xx”"), res.stderr)
        XCTAssertTrue(res.stderr.contains("languages in this index"), res.stderr)
        XCTAssertTrue(res.stderr.contains(known),
                      "le refus doit nommer les vraies langues : \(res.stderr)")

        // UNE valeur inconnue suffit, même accompagnée d'une bonne : la
        // recherche rendait les résultats de la première et se taisait sur
        // l'autre.
        let mixed = try Recette.run(
            ["search", "azote", "--lang", known, "--lang", "xx"],
            database: database)
        XCTAssertEqual(mixed.status, 64, mixed.describe)
    }

    /// `und` est la valeur DOCUMENTÉE de `--lang` (« langue non déterminée ») :
    /// la refuser sur un index où tout est détecté serait refuser une demande
    /// parfaitement formée.
    func testUndeterminedIsAlwaysAccepted() throws {
        _ = try indexedLanguage()
        let res = try Recette.run(["search", "azote", "--lang", "und"],
                                  database: database)
        XCTAssertEqual(res.status, 0, res.describe)
    }

    func testAnUnknownDocumentIDIsRefused() throws {
        let res = try Recette.run(["search", "azote", "--in", "999999"],
                                  database: database)
        XCTAssertEqual(res.status, 64, res.describe)
        XCTAssertTrue(res.stderr.contains("unknown document id 999999"), res.stderr)
        XCTAssertTrue(res.stderr.contains("doc_id"),
                      "le refus doit dire où trouver les bons : \(res.stderr)")
    }

    func testAnUnknownPinnedRootIsRefusedAndNothingIsWritten() throws {
        let res = try Recette.run(["config", "set", "roots.pinned", "999"],
                                  database: database)
        XCTAssertEqual(res.status, 64, res.describe)
        XCTAssertTrue(res.stderr.contains("no root with id 999"), res.stderr)
        XCTAssertTrue(res.stderr.contains(scratch.label),
                      "le refus doit nommer les racines : \(res.stderr)")

        // RIEN N'A ÉTÉ ÉCRIT : c'est la moitié du constat.
        let read = try Recette.run(["config", "get", "roots.pinned"],
                                   database: database)
        XCTAssertEqual(read.status, 0, read.describe)
        XCTAssertTrue(read.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty,
                      "roots.pinned a été écrit malgré le refus : \(read.stdout)")
    }

    func testAnOnlyPathThatMatchesNoDocumentIsRefused() throws {
        let nowhere = scratch.directory.appendingPathComponent("rien-du-tout.pdf")
        for command in ["extract", "ocr"] {
            let res = try Recette.run([command, "--only", nowhere.path],
                                      database: database)
            XCTAssertEqual(res.status, 64,
                           "`fouine \(command) --only` doit refuser : \(res.describe)")
            XCTAssertTrue(res.stderr.contains("no indexed document matches"),
                          res.stderr)
        }
    }

    // MARK: - CM-24 : `config set` dit ce qu'il retient

    func testAnOutOfBoundsIntegerSaysWhyItWasClamped() throws {
        let high = try Recette.run(["config", "set", "ocr.jobs", "99"],
                                   database: database)
        XCTAssertEqual(high.status, 0, high.describe)
        XCTAssertTrue(high.stdout.contains("ocr.jobs = 4"), high.stdout)
        XCTAssertTrue(high.stdout.contains("99 is outside 1–4"),
                      "le bornage doit dire pourquoi : " + high.stdout)

        let low = try Recette.run(["config", "set", "ocr.jobs", "0"],
                                  database: database)
        XCTAssertEqual(low.status, 0, low.describe)
        XCTAssertTrue(low.stdout.contains("0 is outside 1–4"), low.stdout)

        let kb = try Recette.run(["config", "set", "spotlight.text_kb", "1"],
                                 database: database)
        XCTAssertEqual(kb.status, 0, kb.describe)
        XCTAssertTrue(kb.stdout.contains("is outside"), kb.stdout)

        // Contre-épreuve : une valeur DANS les bornes ne porte aucune note.
        let inside = try Recette.run(["config", "set", "ocr.jobs", "2"],
                                     database: database)
        XCTAssertEqual(inside.status, 0, inside.describe)
        XCTAssertEqual(inside.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       "ocr.jobs = 2")
    }

    /// `ocr.languages zz-ZZ` passait sans un mot : l'avertissement n'arrivait
    /// qu'à la passe d'OCR suivante, potentiellement des jours plus tard.
    func testAnUnknownOCRLanguageIsRefusedAtWriteTime() throws {
        let refused = try Recette.run(["config", "set", "ocr.languages", "zz-ZZ"],
                                      database: database)
        XCTAssertEqual(refused.status, 64, refused.describe)
        XCTAssertTrue(refused.stderr.contains("zz-ZZ"), refused.stderr)
        XCTAssertTrue(refused.stderr.contains("nothing was written"), refused.stderr)

        let read = try Recette.run(["config", "get", "ocr.languages"],
                                   database: database)
        XCTAssertFalse(read.stdout.contains("zz-ZZ"),
                       "la langue refusée a été écrite : " + read.stdout)

        let accepted = try Recette.run(["config", "set", "ocr.languages", "fr-FR"],
                                       database: database)
        XCTAssertEqual(accepted.status, 0, accepted.describe)
        XCTAssertTrue(accepted.stdout.contains("ocr.languages = fr-FR"),
                      accepted.stdout)
    }

    // MARK: - Une requête qui commence par un tiret (lot MN1)

    /// `fouine search -type:pdf réacteur` sort en **64** — ArgumentParser lit
    /// le premier mot comme une option inconnue, avant que Fouine ne voie la
    /// chaîne —, et le refus PROPOSE DÉSORMAIS LA FORME QUI MARCHE.
    ///
    /// Sans cette ligne, le message était juste et sans issue : rien, ni dans
    /// l'aide ni dans l'erreur, ne disait que `--` existe. Le tiret de tête
    /// appartient à la grammaire de Fouine (exclusions, exclusions de filtres),
    /// c'est-à-dire à ce que les gens tapent.
    func testAQueryStartingWithADashSuggestsTheDoubleDashForm() throws {
        let refused = try Recette.run(["search", "-type:pdf", "réacteur"],
                                      database: database)
        XCTAssertEqual(refused.status, 64, refused.describe)
        XCTAssertTrue(refused.stderr.contains("fouine search -- '-type:pdf réacteur'"),
                      "la forme qui marche doit être proposée : " + refused.stderr)
        // Le message d'ArgumentParser reste, EN ENTIER et devant : c'est lui
        // qui nomme le jeton fautif.
        XCTAssertTrue(refused.stderr.contains("-type:pdf"), refused.stderr)
        XCTAssertTrue(refused.stderr.contains("Usage:"), refused.stderr)

        // Et cette forme-là marche : la requête part telle qu'elle a été tapée
        // — ici refusée par l'ANALYSEUR (« type: » n'est pas un filtre), ce qui
        // est un autre message et la preuve que la chaîne est bien arrivée.
        let passed = try Recette.run(["search", "--", "-type:pdf réacteur"],
                                     database: database)
        XCTAssertEqual(passed.status, 64, passed.describe)
        XCTAssertTrue(passed.stderr.contains("is not a filter"), passed.stderr)
        XCTAssertFalse(passed.stderr.contains("fouine: hint"),
                       "proposer `--` à qui vient de l'écrire serait la pire "
                       + "ligne d'aide possible : " + passed.stderr)
        // Une exclusion de filtre RÉELLE, écrite ainsi, cherche vraiment.
        let excluded = try Recette.run(["search", "--json", "--fuzzy", "off",
                                        "--", "-ext:pdf azote"],
                                       database: database)
        XCTAssertEqual(excluded.status, 0, excluded.describe)

        // CE QUI N'EST PAS TOUCHÉ : une option mal tapée garde son message, et
        // rien de plus — la bonne réponse y est l'usage, pas une requête entre
        // guillemets.
        let option = try Recette.run(["search", "azote", "--limite", "5"],
                                     database: database)
        XCTAssertEqual(option.status, 64, option.describe)
        XCTAssertFalse(option.stderr.contains("fouine: hint"), option.stderr)
    }

    // MARK: - Contre-épreuve

    /// Ce qui EXISTE continue de marcher : sans ce test, tout ce fichier serait
    /// compatible avec une commande qui refuse tout.
    func testAKnownLanguageStillReturnsResults() throws {
        let known = try indexedLanguage()
        let payload = try Recette.search("azote", database: database,
                                         extra: ["--lang", known])
        XCTAssertGreaterThan(payload.hits.count, 0,
                             "le filtre de langue réel ne rend plus rien")
    }
}
