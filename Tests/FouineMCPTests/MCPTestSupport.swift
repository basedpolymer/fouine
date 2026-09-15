// MCPTestSupport.swift — base jetable et serveur de test. Propriété : A-MCP.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// AUCUN TEST DE CETTE SUITE NE TOUCHE LA BASE DE PRODUCTION, ne charge le
// modèle sémantique, ni ne sort sur le réseau. Chacun fabrique sa base par les
// API D'ÉCRITURE de `GRDBStore` — comme le fait `FouineCoreTests` —, puis la
// rouvre en lecture seule par le chemin que le serveur emprunte vraiment.

import Foundation
import XCTest
import GRDB
import FouineCore
import FouineMCP
import FouineMCPKit

/// Une base neuve, dans son propre dossier (donc son propre `fouine.lock`),
/// remplie de deux documents et de quelques pages.
final class TempIndex {
    let directory: URL
    let databaseURL: URL

    /// - Parameters:
    ///   - pageChars: longueur minimale du texte de chaque page. Les tests de
    ///     budget en ont besoin ; les transcriptions « golden » gardent 0, qui
    ///     donne la phrase courte d'origine.
    ///   - failedDocuments: documents en état `.failed`, avec un `docs.err`
    ///     ANGLAIS — c'est ce que `fouine_list_documents` expose, et B1-33 est
    ///     un prérequis du palier 4.
    /// - Parameter roots: les étiquettes de racine ENREGISTRÉES. Vide par
    ///   défaut, comme toutes les bases de cette suite l'étaient jusqu'ici :
    ///   `fouine_search` ne confronte `dossier:X` à une liste que lorsqu'il en a
    ///   une (idée 5 de l'audit A1), et les transcriptions « golden » gardent
    ///   donc leur comportement exact.
    /// - Parameter languages: la langue du n-ième document, quand il y en a
    ///   une. Vide par défaut : `docs.lang` reste NULL, et `fouine_search` ne
    ///   confronte alors aucun `lang` à une liste (CM-11, même règle que les
    ///   racines).
    /// - Parameter agentStatus: le rapport que l'agent aurait publié. `nil` par
    ///   défaut — aucun agent n'a jamais tourné sur cette base, ce qui est le
    ///   cas de toutes les transcriptions « golden » et ce qui rend
    ///   `fouine_status.agent` déterministe.
    init(documents: Int = 2, pagesPerDocument: Int = 3,
         vectorisedPages: Int = 0, pageChars: Int = 0,
         failedDocuments: Int = 0, skippedDocuments: Int = 0,
         roots: [String] = [], languages: [String] = [],
         agentStatus: AgentStatusRecord? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("fouine.db")

        let store = GRDBStore()
        try store.open(at: databaseURL)
        for index in 1...documents {
            let id = try store.upsertDoc(DocRecord(
                volUUID: "TEST-VOL",
                relPath: "Users/essai/Livres/document-\(index).pdf",
                ext: "pdf", topFolder: "Livres",
                size: Int64(1_000 * index), mtime: 1_700_000_000))
            try store.setPageCount(id, pagesPerDocument)
            try store.replacePages(docID: id, pages: (1...pagesPerDocument).map {
                var text = "electrolyse enthalpie page \($0) du document \(index)"
                // Le rembourrage est du texte, pas du bruit : il doit rester
                // indexable et lisible dans un extrait.
                while text.count < pageChars {
                    text += " enthalpie libre et potentiel chimique, page \($0)."
                }
                return PageText(page: $0, text: text, source: .native)
            })
            try store.setDocState(id, .extracted, err: nil)
            if index <= languages.count {
                try store.setDocLanguage(id, languages[index - 1])
            }
        }
        for offset in 0..<failedDocuments {
            let id = try store.upsertDoc(DocRecord(
                volUUID: "TEST-VOL",
                relPath: "Users/essai/Livres/casse-\(offset + 1).pdf",
                ext: "pdf", topFolder: "Livres",
                size: 4_096, mtime: 1_700_000_100))
            try store.setDocState(id, .failed,
                                  err: "extraction: the file is encrypted")
        }
        for offset in 0..<skippedDocuments {
            let id = try store.upsertDoc(DocRecord(
                volUUID: "TEST-VOL",
                relPath: "Users/essai/Cours/enorme-\(offset + 1).zip",
                ext: "zip", topFolder: "Cours",
                size: 3 << 30, mtime: 1_700_000_200))
            try store.setDocState(id, .skipped, err: "file too large (3.0 GiB)")
        }
        if vectorisedPages > 0 {
            // Des vecteurs FACTICES : `vectorCount()` compte des lignes, il ne
            // les relit pas. C'est assez pour éprouver le calcul de couverture,
            // et cela évite d'exiger un modèle de 220 Mo dans une suite de
            // tests.
            //
            // La valeur 6 n'est pas prise au hasard. Un vecteur unitaire de
            // dimension 384 quantifié en int8 a des composantes autour de
            // 127/√384 ≈ 6,5 ; le produit scalaire de deux vecteurs remplis de
            // 6 rend donc un cosinus de 0,857, c'est-à-dire dans la bande
            // 0,78-0,88 réellement mesurée sur le corpus. Remplir de 1 aurait
            // donné 0,024 — un chiffre qu'aucune transcription ne devrait
            // montrer comme s'il venait du produit.

            // L'identité du modèle est posée comme `EmbedRun` la pose : c'est
            // elle que `fouine_similar_pages` rend sous `model_id`/`revision`,
            // et une base qui en manquerait ne serait pas représentative.
            try store.setVecMeta(modelID: "multilingual-e5-small", dim: 384,
                                 revision: 1)
            var batch: [(rowid: Int64, vec: Data)] = []
            for offset in 0..<vectorisedPages {
                let page = offset % pagesPerDocument + 1
                let docID = Int64(offset / pagesPerDocument + 1)
                // Schéma v5 : un vecteur vit au rowid de sa FENÊTRE. Fenêtre 0
                // réelle, et la sentinelle de complétude (créneau vecWindowMax-1,
                // blob vide) comme la pompe l'écrit — `allVectors` l'ignore.
                let pageRowID = Schema.ftsRowID(docID: docID, page: page)
                batch.append((Schema.vecRowID(pageRowID: pageRowID, chunk: 0),
                              Data(repeating: 6, count: 384)))
                batch.append((Schema.vecRowID(pageRowID: pageRowID,
                                              chunk: Schema.vecWindowMax - 1),
                              Data()))
            }
            try store.upsertVectors(batch)
        }
        if let agentStatus { try store.writeAgentStatus(agentStatus) }
        // Le verrou est rendu tout de suite : le serveur doit pouvoir lire une
        // base que personne ne tient, et c'est aussi le cas normal.
        store.releaseWriteLock()
        // Les racines sont posées par SQL DIRECT : `addRoot` résout un volume
        // réel et SONDE la lisibilité du dossier (`RootProbe`), ce qu'une base
        // jetable de suite unitaire n'a ni besoin ni moyen de fournir. Même
        // procédé que `bumpSchemaVersion`.
        if !roots.isEmpty {
            let queue = try DatabaseQueue(path: databaseURL.path)
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO volumes(uuid, label, last_seen, fsevent_id)
                    VALUES ('TEST-VOL', 'Test', 0, 0)
                    ON CONFLICT(uuid) DO NOTHING
                    """)
                for label in roots {
                    try db.execute(
                        sql: """
                        INSERT INTO roots(vol_uuid, rel_path, label, enabled)
                        VALUES ('TEST-VOL', ?, ?, 1)
                        """,
                        arguments: ["Users/essai/\(label)", label])
                }
            }
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// Un serveur branché sur cette base, avec la sonde `launchctl` et le
    /// répertoire de modèle NEUTRALISÉS : une transcription ne peut dépendre ni
    /// de l'agent installé sur la machine qui la rejoue, ni d'un téléchargement
    /// de 220 Mo.
    ///
    /// `modelDirectory` pointe par défaut sur un dossier VIDE : aucune suite ne
    /// peut dépendre d'un modèle de 220 Mo présent sur la machine qui la rejoue,
    /// et c'est aussi ce qui rend le repli sémantique éprouvable sans réseau.
    /// Les tests SOUS modèle passent le vrai répertoire et se sautent sans lui.
    func makeServer(logLevel: LogLevel = .quiet,
                    schemaCacheTTL: TimeInterval = 60,
                    modelDirectory: URL? = nil) throws -> MCPServer {
        let model = modelDirectory
            ?? directory.appendingPathComponent("no-model", isDirectory: true)
        return MCPServer(
            options: .init(databaseURL: databaseURL, logLevel: logLevel,
                           schemaCacheTTL: schemaCacheTTL),
            version: "1.0.0-test",
            makeSemanticEngine: { SemanticEngine(store: $0, modelDirectory: model) },
            makeStatusTool: { store, semantic in
                StatusTool(store: store, semantic: semantic, modelDirectory: model,
                           launchdProbe: { .notRegistered })
            })
    }

    /// Force la version de schéma inscrite dans `meta`, par une connexion
    /// SÉPARÉE et en écriture — c'est exactement ce que fait une mise à jour de
    /// Fouine pendant qu'un serveur MCP tourne.
    func bumpSchemaVersion(to version: Int) throws {
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO meta(k, v) VALUES ('schema_version', ?)",
                arguments: [String(version)])
        }
    }
}

// MARK: - Outils de comparaison

enum JSONMatch {

    /// Le joker des transcriptions : `"<any>"` accepte n'importe quelle valeur
    /// À CETTE PLACE. C'est ce qui permet de figer la FORME d'une réponse sans
    /// figer une taille de base, un chemin temporaire ou un horodatage.
    static let wildcard = "<any>"

    /// Comparaison STRUCTURELLE : les deux côtés sont du JSON analysé, l'ordre
    /// des clés n'entre pas en compte, et un `"<any>"` attendu passe toujours.
    /// Rend `nil` si tout va bien, sinon le chemin du premier désaccord.
    static func mismatch(expected: Any, actual: Any, path: String = "$") -> String? {
        if let text = expected as? String, text == wildcard { return nil }

        switch (expected, actual) {
        case let (e as [String: Any], a as [String: Any]):
            let missing = Set(e.keys).subtracting(a.keys).sorted()
            if let first = missing.first { return "\(path).\(first): absent de la réponse" }
            let extra = Set(a.keys).subtracting(e.keys).sorted()
            if let first = extra.first { return "\(path).\(first): en trop dans la réponse" }
            for (key, value) in e.sorted(by: { $0.key < $1.key }) {
                if let problem = mismatch(expected: value, actual: a[key] as Any,
                                          path: "\(path).\(key)") { return problem }
            }
            return nil
        case let (e as [Any], a as [Any]):
            guard e.count == a.count else {
                return "\(path): \(e.count) élément(s) attendu(s), \(a.count) rendu(s)"
            }
            for (offset, value) in e.enumerated() {
                if let problem = mismatch(expected: value, actual: a[offset],
                                          path: "\(path)[\(offset)]") { return problem }
            }
            return nil
        case let (e as String, a as String):
            return e == a ? nil : "\(path): attendu \"\(e)\", rendu \"\(a)\""
        case let (e as NSNumber, a as NSNumber):
            return e == a ? nil : "\(path): attendu \(e), rendu \(a)"
        case (is NSNull, is NSNull):
            return nil
        default:
            return "\(path): attendu \(type(of: expected)) \(expected), "
                + "rendu \(type(of: actual)) \(actual)"
        }
    }

    static func object(_ data: Data) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let object = parsed as? [String: Any] else {
            throw NSError(domain: "MCPTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "pas un objet JSON"])
        }
        return object
    }
}

// MARK: - Chemins du dépôt

enum RepoPaths {
    /// Les transcriptions vivent à côté de ce fichier. `#filePath` plutôt qu'un
    /// `Bundle.module` : le dépôt le fait déjà pour `docs/cli.md`
    /// (`MaintenanceRecetteTests`), et cela évite de déclarer une ressource dont
    /// on n'a besoin qu'en test.
    static var transcripts: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Transcripts", isDirectory: true)
    }

    /// La racine du dépôt : `Tests/FouineMCPTests/` moins deux niveaux. Sert à
    /// `ManifestTests`, qui compare un fichier d'EMPAQUETAGE
    /// (`Packaging/mcpb/manifest.json`) à ce que le serveur annonce vraiment.
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FouineMCPTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // racine
    }
}
