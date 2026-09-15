// CorpusFixturesTests.swift — le corpus VERSIONNÉ, hors de tout pipeline.
// Propriété : A-Recette. Audit E5, D12/M23.
//
// Ces tests répondent à une question et une seule : « les fichiers du dépôt
// disent-ils ce que le manifeste prétend ? ». Ils n'ouvrent aucune base,
// n'appellent pas la CLI, ne rendent aucune image — ils appellent les
// extracteurs directement. Ce sont donc les tests les plus RAPIDES du corpus
// versionné, et les premiers à casser quand une fixture est régénérée de
// travers.
//
// La recette complète (indexation, recherche, OCR, statut) est dans
// Tests/Integration/VersionedCorpusTests.swift.
//
// À NOTER : `manifest.json` est DANS LE DÉPÔT. Son absence ou sa malformation
// est un ÉCHEC, pas un saut — contrairement à `Tests/Fixtures/paths.json`, qui
// est personnel et gitignoré.

import Foundation
import XCTest
import FouineCore
@testable import FouineExtract

final class CorpusFixturesTests: XCTestCase {

    private var manifest: CorpusManifest!

    override func setUpWithError() throws {
        manifest = try CorpusManifest.load()
    }

    // MARK: - Cohérence manifeste ↔ disque

    /// Aucun fichier orphelin dans un sens ni dans l'autre. C'est ce qui empêche
    /// une fixture d'entrer dans le dépôt sans être décrite — donc sans que
    /// personne ne sache ce qu'elle contient ni pourquoi elle est là.
    func testManifestAndDiskAgree() throws {
        let onDisk = try CorpusManifest.filesOnDisk()
        let declared = Set(manifest.files.map(\.name))

        let undeclared = onDisk.subtracting(declared)
        XCTAssertTrue(undeclared.isEmpty,
                      "fichier(s) presents dans Tests/Fixtures/corpus/ mais "
                      + "absents du manifeste : \(undeclared.sorted()). "
                      + "Ajoutez-les dans Tools/make_fixtures.swift puis "
                      + "relancez `make fixtures`.")

        // Une entrée sans fichier n'est tolérée QUE si elle porte `requires` :
        // c'est le cas de notice.djvu quand djvulibre manquait à la génération.
        for entry in manifest.files where !onDisk.contains(entry.name) {
            XCTAssertNotNil(
                entry.requires,
                "le manifeste declare « \(entry.name) », qui n'est pas dans le "
                + "depot et n'a pas de champ `requires` expliquant son absence")
        }
    }

    /// Le manifeste dit lui-même combien de fichiers le crawler doit voir. Le
    /// contrat est repris tel quel par la recette d'intégration : si les deux
    /// divergent, c'est ici qu'on l'apprend, en une seconde et sans base.
    func testIndexedFileCountIsConsistent() throws {
        let indexable = manifest.files.filter { $0.kind != "ignored" }
        XCTAssertEqual(manifest.indexedFiles, indexable.count)
        XCTAssertEqual(manifest.schema, 1, "schema de manifeste inattendu")
        XCTAssertEqual(manifest.generator, "Tools/make_fixtures.swift")
    }

    /// Le corpus doit rester MENU : il est dans le dépôt, tout le monde le
    /// clone. Le plafond de l'audit E5 est de 2 Mo ; on est très en dessous, et
    /// cette borne est là pour qu'on le reste.
    func testCorpusStaysSmall() throws {
        var total = 0
        for name in try CorpusManifest.filesOnDisk() {
            let url = CorpusManifest.directory.appendingPathComponent(name)
            total += (try FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        }
        XCTAssertLessThan(total, 2 << 20,
                          "corpus de \(total) o : au-dela de 2 Mo, il n'a plus "
                          + "sa place dans le depot (audit E5)")
        XCTAssertGreaterThan(total, 50 << 10, "corpus suspicieusement vide")
    }

    /// Chaque extension déclarée est bien dans le registre — sauf celle du
    /// fichier « hors registre », qui doit précisément NE PAS y être.
    func testDeclaredExtensionsMatchTheRegistry() throws {
        let supported = DefaultExtractorRegistry.supportedExtensions
        for entry in manifest.files {
            if entry.kind == "ignored" {
                XCTAssertFalse(supported.contains(entry.ext),
                               "« \(entry.name) » est declare hors registre mais "
                               + "« \(entry.ext) » y figure")
            } else {
                XCTAssertTrue(supported.contains(entry.ext),
                              "« \(entry.ext) » (\(entry.name)) n'est pas dans "
                              + "DefaultExtractorRegistry.supportedExtensions")
            }
        }
    }

    /// Contre-épreuve du corpus lui-même : il doit couvrir les extensions du
    /// registre pour lesquelles on SAIT fabriquer une fixture synthétique.
    /// Les absentes sont nommées dans la liste `known` ci-dessous, et le corpus
    /// est décrit par `Tests/Fixtures/corpus/manifest.json` (README à côté).
    func testCorpusCoversTheRegistryExceptTheDocumentedGaps() throws {
        let covered = Set(manifest.files.filter { $0.kind != "ignored" }
            .map(\.ext))
        // `.doc` est SORTI de cette liste au palier « v1.0.0 privée » : le
        // corpus porte désormais un vrai Word 97, deux documents mal nommés et
        // un piège réseau (audit B1-34, A1-01, D2-01).
        // tsv, ods, odp, eml (audit a3-08), srt, vtt, ipynb (lot G1, R-14)
        // sont couverts par des tests unitaires dédiés (SubtitleAndNotebookTests.swift).
        // Les extensions TECHNIQUES (lot INT-F1) sont couvertes par
        // `TechnicalFilesTests` et par quatre fixtures versionnees (script.py,
        // composant.tsx, configuration.xml, reglages.plist, page.min.js) : en
        // exiger une par extension mettrait soixante-dix fichiers dans le depot
        // pour un seul et meme extracteur.
        let technical = PlainTextExtractor.sourceExtensions
            .union(XMLDocumentExtractor.supportedExtensions)
        let known: Set<String> = Set(["rtfd", "webarchive", "cbr", "tsv", "ods",
                                      "odp", "eml", "srt", "vtt", "ipynb"])
            .union(technical)
        let missing = DefaultExtractorRegistry.supportedExtensions
            .subtracting(covered).subtracting(known)
        XCTAssertTrue(missing.isEmpty,
                      "extension(s) du registre sans fixture versionnee : "
                      + "\(missing.sorted()). Ajoutez-la a "
                      + "Tools/make_fixtures.swift ET a "
                      + "Tests/Fixtures/corpus/manifest.json (relancez "
                      + "`make fixtures`), ou inscrivez le trou dans la liste "
                      + "`known` de ce test en disant pourquoi.")
    }

    // MARK: - Extraction, format par format

    /// LE test du corpus : chaque fixture s'extrait, rend le nombre de pages
    /// annoncé, et porte ses termes témoins natifs AUX PAGES ANNONCÉES — et
    /// nulle part ailleurs dans le même fichier. C'est cette dernière moitié
    /// qui donne sa valeur au corpus : sans elle, un extracteur qui collerait
    /// tout le document sur chaque page passerait.
    func testEveryFixtureExtractsAsTheManifestSaysIt() throws {
        let registry = DefaultExtractorRegistry()
        var checked = 0

        for entry in manifest.files where entry.state == "extracted" {
            guard entry.exists else {
                XCTAssertNotNil(entry.requires, entry.name)
                continue                      // djvulibre absent : cas couvert
            }
            let result: ExtractionResult
            do {
                result = try registry.extract(url: entry.url)
            } catch let error as FouineError {
                // djvulibre peut manquer à l'EXÉCUTION même si la fixture a été
                // produite ailleurs : c'est un saut, pas un échec.
                if entry.requires != nil {
                    print("corpus : \(entry.name) non extrait (\(error)) — "
                          + "brew install \(entry.requires!)")
                    continue
                }
                XCTFail("\(entry.name) : \(error)")
                continue
            }

            if let pages = entry.pages {
                XCTAssertEqual(result.pageCount, pages,
                               "\(entry.name) : pageCount")
            }

            // Texte par page, indexé par numéro de page (1-indexé).
            var byPage: [Int: String] = [:]
            for page in result.pages {
                byPage[page.page] = foldedForWitness(page.text)
            }

            for witness in entry.witnesses
            where witness.source == "native" && witness.isPlainWord {
                let needle = foldedForWitness(witness.term)
                for page in witness.pages {
                    let body = byPage[page] ?? ""
                    XCTAssertTrue(body.contains(needle),
                                  "\(entry.name) p.\(page) : « \(witness.term) » "
                                  + "absent du texte extrait")
                }
                // …et sur AUCUNE autre page du même document.
                for (page, body) in byPage where !witness.pages.contains(page) {
                    XCTAssertFalse(body.contains(needle),
                                   "\(entry.name) p.\(page) : « \(witness.term) » "
                                   + "ne devrait pas y etre (manifeste : "
                                   + "\(witness.pages))")
                }
                checked += 1
            }

            // Une fixture « scanned » n'a AUCUN texte natif : c'est ce qui la
            // définit, et ce qui met ses pages en file d'OCR.
            if entry.kind == "scanned" {
                XCTAssertTrue(result.pages.allSatisfy { $0.text.count < 100 },
                              "\(entry.name) : une page scannee ne doit porter "
                              + "aucune couche texte utilisable")
                XCTAssertEqual(result.ocrCandidates.count, entry.pages ?? 0,
                               "\(entry.name) : toutes les pages doivent partir "
                               + "en OCR")
            }
        }

        XCTAssertGreaterThanOrEqual(
            checked, 15,
            "moins de 15 termes temoins natifs verifies : le corpus a maigri")
    }

    // MARK: - Refus propres

    /// Les fixtures REFUSÉES PROPREMENT (`state: "skipped"`). Depuis le lot
    /// INT-F1, ce ne sont plus « les formats OLE » — `.xls` et `.ppt` se lisent —
    /// mais des documents dont il n'y a RIEN à indexer : un classeur et une
    /// présentation chiffrés, une source minifiée. Chacun doit être refusé sur
    /// SON motif, et ce motif doit se classer `.skipped`, jamais `.failed` :
    /// c'est la différence entre « sauté, protégé par mot de passe » et un
    /// document qui manque.
    func testSkippedFixturesAreRefusedWithTheirOwnReason() throws {
        let registry = DefaultExtractorRegistry()
        var seen = 0
        for entry in manifest.files where entry.state == "skipped" {
            XCTAssertTrue(entry.exists, entry.name)
            XCTAssertThrowsError(try registry.extract(url: entry.url)) { error in
                guard case FouineError.extraction(let message) = error else {
                    return XCTFail("\(entry.name) : attendu .extraction, "
                                   + "obtenu \(error)")
                }
                if let expected = entry.err {
                    XCTAssertEqual(message, expected, entry.name)
                }
                XCTAssertEqual(
                    ExtractOutcome.skipReason(for: .extraction(message)), message,
                    "\(entry.name) : ce refus doit se classer .skipped")
            }
            seen += 1
        }
        XCTAssertGreaterThanOrEqual(seen, 3,
                                    "le corpus doit garder ses refus propres : "
                                    + "classeur et presentation chiffres, "
                                    + "source minifiee")
    }

    /// Les fixtures `state: "failed"` : refusées, et refusées POUR LA BONNE
    /// RAISON. `pieges/balise-reseau.doc` est du HTML dans un `.doc` — le piège
    /// de l'audit A1-01 — et son refus doit venir du tri par octets de tête
    /// (« unrecognised format »), pas d'un mojibake ni d'une lecture ratée :
    /// un refus au mauvais endroit voudrait dire que l'importateur WebKit a
    /// quand même été appelé, donc que les sous-ressources ont été chargées.
    ///
    /// Le SILENCE RÉSEAU lui-même se mesure dans NetworkSilenceTests.
    func testTrappedFixturesAreRefusedWithTheAnnouncedReason() throws {
        let registry = DefaultExtractorRegistry()
        var seen = 0
        for entry in manifest.files where entry.state == "failed" {
            XCTAssertTrue(entry.exists, entry.name)
            let started = Date()
            XCTAssertThrowsError(try registry.extract(url: entry.url)) { error in
                guard case FouineError.extraction(let message) = error else {
                    return XCTFail("\(entry.name) : attendu .extraction, "
                                   + "obtenu \(error)")
                }
                if let expected = entry.err {
                    XCTAssertTrue(message.contains(expected),
                                  "\(entry.name) : « \(message) » ne porte pas "
                                  + "« \(expected) »")
                }
                // `fileTooLarge`/`unsupported` mis à part, un refus d'extraction
                // tombe en `.failed` : c'est ce que le manifeste annonce.
                XCTAssertNil(ExtractOutcome.skipReason(for: .extraction(message)),
                             "\(entry.name) : ce refus doit se classer .failed")
            }
            // A1-02 : le piège à adresse noire faisait attendre 62 s. Le refus
            // sur les octets de tête ne lit que huit octets.
            XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                              "\(entry.name) : le refus doit être immédiat")
            seen += 1
        }
        XCTAssertGreaterThanOrEqual(seen, 1,
                                    "le corpus doit garder au moins une fixture "
                                    + "refusée (le piège réseau .doc)")
    }

    /// Le tri par OCTETS DE TÊTE, sur les trois fixtures qui en dépendent
    /// (D2-01). Deux d'entre elles s'indexaient AVANT le durcissement et
    /// doivent continuer : c'est la mesure qui a fait rejeter le correctif par
    /// extension. Les témoins eux-mêmes sont vérifiés par le test général
    /// ci-dessus ; ici on affirme le CHEMIN choisi.
    func testDocIsTypedByItsHeadBytes() throws {
        let cases: [(String, RichTextExtractor.Shape?)] = [
            ("vrai-word97.doc", .attributed(.docFormat)),
            ("faux-nom.doc", .ooxml),
            ("rtf-nomme-doc.doc", .attributed(.rtf)),
            ("pieges/balise-reseau.doc", nil),
        ]
        for (name, expected) in cases {
            let url = CorpusManifest.directory.appendingPathComponent(name)
            XCTAssertEqual(RichTextExtractor.shape(of: url, ext: "doc"), expected,
                           name)
        }
        // `.rtfd` est un PAQUET : tranché sur l'extension, sans lecture — et
        // donc sans que le fichier ait besoin d'exister.
        XCTAssertEqual(
            RichTextExtractor.shape(of: URL(fileURLWithPath: "/nowhere/x.rtfd"),
                                    ext: "rtfd"),
            .attributed(.rtfd))
    }

    /// Les accents du conteneur mal nommé (D2-01) : c'est la moitié de la
    /// mesure qui a fait rejeter le correctif par extension — le document
    /// n'était pas seulement indexé, il l'était CORRECTEMENT.
    func testMislabeledContainerKeepsItsAccents() throws {
        let result = try DefaultExtractorRegistry().extract(
            url: CorpusManifest.directory.appendingPathComponent("faux-nom.doc"))
        let text = result.pages.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("QUINQUENNAT"), text)
        XCTAssertTrue(text.contains("éàçûî"),
                      "les accents du conteneur OOXML sont perdus : " + text)
    }

    /// Le fichier hors registre : le registre ne lui connaît AUCUN extracteur.
    /// C'est ce qui fait que le crawler ne le verra pas du tout — vérifié de
    /// bout en bout par la recette d'intégration.
    func testOutOfRegistryFixtureHasNoExtractor() throws {
        let registry = DefaultExtractorRegistry()
        for entry in manifest.files where entry.kind == "ignored" {
            XCTAssertTrue(entry.exists, entry.name)
            XCTAssertNil(registry.extractor(for: entry.ext))
            XCTAssertEqual(ExtractOutcome.skipReason(ext: entry.ext),
                           "unsupported format")
        }
    }

    // MARK: - Fichier « trop volumineux », simulé

    /// La borne réelle est de 2 Gio (`ExtractLimits.maxFileBytes`) : on ne peut
    /// pas la mettre dans le dépôt. On abaisse donc la LIMITE au lieu de gonfler
    /// le FICHIER — c'est le même code de garde qui décide, et le test tient en
    /// quelques millisecondes.
    ///
    /// Ce qui compte n'est pas seulement le refus, c'est son CLASSEMENT :
    /// `fileTooLarge` doit tomber en `.skipped` et non en `.failed` (audit
    /// A11.3, où les trois pipelines le classaient en échec).
    func testFileTooLargeIsSkippedNotFailed() throws {
        let pdf = try XCTUnwrap(manifest.files.first { $0.name.hasSuffix(".pdf") })
        var limits = ExtractLimits()
        limits.maxFileBytes = 64                     // tout le corpus dépasse

        XCTAssertThrowsError(
            try DefaultExtractorRegistry().extract(url: pdf.url, limits: limits)
        ) { error in
            guard let fouine = error as? FouineError,
                  case .fileTooLarge(let bytes) = fouine else {
                return XCTFail("attendu .fileTooLarge, obtenu \(error)")
            }
            XCTAssertGreaterThan(bytes, 64)
            XCTAssertNotNil(ExtractOutcome.skipReason(for: fouine),
                            "fileTooLarge doit se classer en .skipped (A11.3)")
        }

        // Contre-épreuve : à limites nominales, le même fichier s'extrait.
        XCTAssertNoThrow(try DefaultExtractorRegistry().extract(url: pdf.url))
    }
}
