// CorpusRecette.swift — la racine jetable peuplée par le CORPUS VERSIONNÉ.
// Propriété : A-Recette. Audit E5, D12/M23, S3.
//
// `Recette.makeIndexedScratch` (IntegrationSupport.swift) fabrique une racine
// de fiches .txt synthétiques : elle suffit à tester le PRODUIT — hygiène du
// crawl, contrat de `status` —, mais pas les FORMATS, ni l'OCR, ni les six
// formes de requête. C'est ce que ce complément apporte : la MÊME discipline
// (base jetable, racine jetable, rien de personnel, rien en production), sur
// les 22 fichiers versionnés de Tests/Fixtures/corpus/.
//
// LE CORPUS EST COPIÉ, JAMAIS INDEXÉ SUR PLACE. Deux raisons, toutes deux
// dures : `Tests/Fixtures/corpus/` est dans le DÉPÔT — un test qui renomme un
// fichier (recette du document déplacé) salirait l'arbre de travail —, et la
// racine doit être un chemin CANONIQUE hors du dépôt pour que `root add`
// résolve le volume comme il le fait chez l'utilisateur (§2.3).

import Foundation
import XCTest

extension Recette {

    /// Une base et une racine jetables, peuplées par le corpus versionné.
    struct CorpusScratch {
        let directory: URL
        let root: URL
        let database: URL
        let label: String
        let manifest: CorpusManifest

        /// Chemin ABSOLU d'une fixture sous la racine jetable.
        func file(_ name: String) -> URL {
            root.appendingPathComponent(name)
        }
    }

    /// Copie le corpus versionné dans une racine jetable, l'enregistre dans une
    /// base jetable et l'indexe par la CLI. `manifest.json` et `README.md` ne
    /// sont PAS copiés : ils décrivent le corpus, ils n'en font pas partie — et
    /// `manifest.json` serait indexé comme un document .json de plus, ce qui
    /// fausserait tous les décomptes.
    ///
    /// - Parameter withOCR: enchaîne `fouine ocr` après l'indexation. Coûte
    ///   quelques secondes de Vision : ne le demander que pour les tests qui en
    ///   ont besoin.
    static func makeIndexedCorpus(_ name: String, label: String = "Fixtures",
                                  withOCR: Bool = false) throws -> CorpusScratch {
        _ = try requireBinary()
        let manifest = try CorpusManifest.load()
        let directory = try scratchDirectory("corpus-\(name)")
        let root = directory.appendingPathComponent("racine", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        for entry in manifest.files where entry.exists {
            let destination = root.appendingPathComponent(entry.name)
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.copyItem(at: entry.url, to: destination)
        }

        let database = directory.appendingPathComponent("recette.db")
        // Tracé dans la sortie : la garantie de l'audit S3 — « aucun test ne
        // touche la base de production » — doit être vérifiable d'un coup d'œil
        // sur le journal de `make test`.
        print("recette : corpus versionné -> base jetable \(database.path)")

        let added = try run(["root", "add", root.path, "--label", label],
                            database: database)
        XCTAssertEqual(added.status, 0, added.describe)

        // Même garde-fou que `makeIndexedScratch` : la base jetable ne doit
        // porter QUE cette racine, sans quoi `index` partirait sur les dossiers
        // réels de l'utilisateur.
        let listed = try run(["root", "list", "--json"], database: database)
        XCTAssertEqual(listed.status, 0, listed.describe)
        struct Listed: Decodable { let label: String }
        let roots = try JSONDecoder().decode([Listed].self,
                                             from: Data(listed.stdout.utf8))
        XCTAssertEqual(roots.map(\.label), [label],
                       "la base jetable doit ne contenir QUE la racine de test")

        let indexed = try run(["index"], database: database, timeout: 300)
        XCTAssertEqual(indexed.status, 0, indexed.describe)

        if withOCR {
            let ocr = try run(["ocr"], database: database, timeout: 600)
            XCTAssertEqual(ocr.status, 0, ocr.describe)
        }

        return CorpusScratch(directory: directory, root: root, database: database,
                             label: label, manifest: manifest)
    }

    // MARK: - Lectures d'index utiles à la recette du corpus

    /// `(rel_path relatif à la racine) -> (state, ocr_state, n_pages, ext)`.
    /// Lu en `mode=ro` : la recette n'écrit jamais par SQL.
    static func indexedDocuments(under root: URL, on database: URL) throws
        -> [String: (state: Int, ocrState: Int, pages: Int, ext: String,
                     err: String?)] {
        // `docs.rel_path` est relatif à la racine du VOLUME, pas à la racine
        // enregistrée : on retranche le préfixe, sans le « / » de tête.
        //
        // `err` est rendu (audit A1-01) : une fixture REFUSÉE se juge sur son
        // motif, pas seulement sur son état — un piège réseau qui échouerait
        // pour une autre raison voudrait dire que l'importateur AppKit a quand
        // même été appelé.
        let prefix = String(root.path.dropFirst()) + "/"
        let raw = try sqlite(
            "SELECT rel_path || '\t' || state || '\t' || ocr_state || '\t' "
            + "|| n_pages || '\t' || ext || '\t' || coalesce(err, '') FROM docs",
            on: database)
        var out: [String: (Int, Int, Int, String, String?)] = [:]
        for line in raw.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 6 else { continue }
            var path = String(fields[0])
            if path.hasPrefix(prefix) { path.removeFirst(prefix.count) }
            let err = String(fields[5])
            out[path] = (Int(fields[1]) ?? -1, Int(fields[2]) ?? -1,
                         Int(fields[3]) ?? -1, String(fields[4]),
                         err.isEmpty ? nil : err)
        }
        return out
    }

    /// Pages rendues par une requête, restreintes à UNE fixture, triées.
    /// C'est la forme qu'attend le manifeste : « ce terme, dans ce fichier, à
    /// ces pages ».
    static func pages(of query: String, in fixture: String, database: URL,
                      extra: [String] = []) throws -> [Int] {
        let payload = try search(query, database: database, extra: extra)
        return payload.hits
            .filter { $0.path.hasSuffix(fixture) }
            .map(\.page)
            .sorted()
    }
}
