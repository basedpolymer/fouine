// GRDBStore+DocsFTS.swift — le NOM du document, cherchable (D-R3, idée R-02).
// Propriété : A-Core.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// `docs_fts` indexe le nom du fichier et celui de son dossier, à part de
// `page_fts` : une table de quelques milliers de lignes, pas une colonne de
// plus sur quatre cent mille pages (voir le commentaire de la table dans
// `Schema.swift`). Elle naît AVEC le schéma, et chaque écriture de `docs` la
// tient à jour DANS LA MÊME TRANSACTION — sans quoi les deux tables
// divergeraient sur un arrêt brutal.
//
// `rebuildDocsFTS` est le chemin de SECOURS qui répare cette divergence :
// `maintain --repair` s'en sert, et `doctor --deep` compare les deux comptes
// pour savoir s'il faut le faire.

import Foundation
import GRDB

extension GRDBStore {

    /// (Re)construit `docs_fts` depuis `docs`. Rend le nombre de lignes posées.
    /// À appeler dans une transaction d'écriture.
    @discardableResult
    static func rebuildDocsFTS(_ db: Database) throws -> Int {
        try db.execute(sql: "DELETE FROM docs_fts")
        var count = 0
        for row in try Row.fetchAll(db, sql: "SELECT id, rel_path FROM docs") {
            try indexDocumentName(db, id: row["id"], relPath: row["rel_path"])
            count += 1
        }
        return count
    }

    /// Pose (ou repose) le nom d'UN document dans `docs_fts`.
    ///
    /// FTS5 n'a pas d'`INSERT … ON CONFLICT` : un `DELETE` puis un `INSERT`,
    /// et l'appelant doit être dans la transaction qui écrit `docs`, faute de
    /// quoi les deux tables pourraient diverger sur un arrêt brutal.
    static func indexDocumentName(_ db: Database, id: Int64, relPath: String) throws {
        try db.execute(sql: "DELETE FROM docs_fts WHERE rowid = ?", arguments: [id])
        try db.execute(sql: "INSERT INTO docs_fts(rowid, name) VALUES (?, ?)",
                       arguments: [id, Schema.documentIndexName(relPath: relPath)])
    }

    /// Retire le nom d'un document (purge, suppression).
    static func removeDocumentName(_ db: Database, id: Int64) throws {
        try db.execute(sql: "DELETE FROM docs_fts WHERE rowid = ?", arguments: [id])
    }
}
