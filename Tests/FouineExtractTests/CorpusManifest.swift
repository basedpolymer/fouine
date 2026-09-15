// CorpusManifest.swift — lecture de Tests/Fixtures/corpus/manifest.json.
// Propriété : A-Recette. Cible de test uniquement.
//
// DUPLIQUÉ, EXPRÈS, dans Tests/Integration/CorpusManifest.swift : SwiftPM
// n'autorise pas un même fichier source dans deux cibles, et fabriquer une
// bibliothèque de test partagée pour quatre-vingts lignes de décodage JSON
// coûterait plus cher (une cible de plus au manifeste, propriété de
// l'orchestrateur) que la duplication. Les deux copies DOIVENT rester
// identiques ; `manifest.json` est leur contrat commun.
//
// Le manifeste décrit le CONTENU attendu du corpus versionné — jamais une
// empreinte : la régénération par `make fixtures` ne reproduit pas les octets
// (CoreGraphics date chaque PDF), elle reproduit le contenu.

import Foundation
import XCTest
import FouineExtract

/// Un terme témoin : le mot, les pages où il doit ressortir, par quel canal.
struct CorpusWitness: Decodable {
    let term: String
    let pages: [Int]
    /// `native` ou `ocr_accurate` — la valeur du champ `source` de
    /// `fouine search --json`, et `page_src.src` en base.
    let source: String
    /// Requête `fouine search` exacte, si elle diffère du terme (expression,
    /// préfixe, proximité, faute de frappe du test flou).
    let query: String?
    let note: String?

    /// Vrai si `term` est un MOT SIMPLE, cherchable tel quel dans du texte
    /// extrait. Les autres (`"expression"`, `pres:5 a b`, `prefixe*`) ne se
    /// vérifient que par la recherche, dans IntegrationTests.
    var isPlainWord: Bool {
        !term.contains(" ") && !term.contains("*") && !term.contains(":")
            && !term.contains("\"") && !term.contains("-")
    }
}

struct CorpusEntry: Decodable {
    /// Chemin RELATIF au dossier du corpus.
    let name: String
    let ext: String
    /// `text` · `scanned` · `trap` · `ignored`.
    let kind: String
    /// `docs.n_pages` attendu, `nil` si l'extracteur en décide.
    let pages: Int?
    /// `docs.state` attendu : `extracted` · `failed` · `skipped` · `absent`.
    let state: String
    /// Outil externe requis pour que la fixture EXISTE (`djvulibre`).
    let requires: String?
    /// Fragment attendu de `docs.err`, pour les fixtures `failed` : un refus se
    /// juge sur son MOTIF (audit A1-01 — le piège réseau doit être refusé
    /// « unrecognised format », pas échouer pour une autre raison).
    let err: String?
    let witnesses: [CorpusWitness]
    let note: String
}

struct CorpusManifest: Decodable {
    let schema: Int
    let generator: String
    let note: String
    let indexedFiles: Int
    let files: [CorpusEntry]

    enum CodingKeys: String, CodingKey {
        case schema, generator, note, files
        case indexedFiles = "indexed_files"
    }

    /// Dossier du corpus versionné, déduit de l'emplacement de CE fichier :
    /// Tests/FouineExtractTests/CorpusManifest.swift.
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // Tests/FouineExtractTests
        .deletingLastPathComponent()      // Tests
        .appendingPathComponent("Fixtures/corpus")

    /// Le manifeste, ou un ÉCHEC. Contrairement à `paths.json` (personnel,
    /// gitignoré, dont l'absence se saute), ce fichier est DANS LE DÉPÔT :
    /// son absence est une régression, pas une précondition de machine.
    static func load() throws -> CorpusManifest {
        let url = directory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CorpusManifest.self, from: data)
    }

    /// Fichiers (et paquets) réellement présents sur le disque, hors documentation.
    static func filesOnDisk() throws -> Set<String> {
        var found: Set<String> = []
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey])
            let ext = url.pathExtension.lowercased()
            let isPackage = values?.isPackage == true || ["rtfd", "pages", "numbers", "key"].contains(ext)
            if values?.isDirectory == true && isPackage {
                enumerator?.skipDescendants()
                let relative = url.path
                    .replacingOccurrences(of: directory.path + "/", with: "")
                found.insert(relative)
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let relative = url.path
                .replacingOccurrences(of: directory.path + "/", with: "")
            if relative == "manifest.json" || relative == "README.md" { continue }
            found.insert(relative)
        }
        return found
    }
}

extension CorpusEntry {
    var url: URL { CorpusManifest.directory.appendingPathComponent(name) }

    /// La fixture existe-t-elle ? Une fixture à `requires` peut manquer sur une
    /// machine où l'outil n'était pas installé au moment de la génération.
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// L'extracteur peut-il tourner sur cette machine ? `requires` peut désigner
    /// un outil externe (`djvulibre`) absent de l'environnement d'exécution (CI).
    var isSupportedOnSystem: Bool {
        guard let req = requires else { return true }
        if req == "djvulibre" {
            return DjvuExtractor.tool() != nil
        }
        return true
    }
}

/// Repli d'accents ET de casse, pour comparer un terme témoin (désaccentué,
/// comme le rend le tokenizer `unicode61 remove_diacritics 2`) au texte BRUT
/// que rend un extracteur (« cinétique »).
func foldedForWitness(_ text: String) -> String {
    text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                 locale: Locale(identifier: "fr_FR"))
}
