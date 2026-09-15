// GRDBStore+Media.swift — relire les enregistrements quand leur transcription
// s'allume ou change (lot TR1).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// POURQUOI UNE MARQUE. Un document `extracted` n'est jamais repris, et le crawl
// ne réexamine que trois causes de `.skipped`, toutes extérieures au fichier
// (FouineCrawler). Deux situations laissaient donc des enregistrements lus à
// moitié pour toujours : ceux transcrits avant TR1, dont seule la dernière
// minute de chaque tranche de dix était gardée, et ceux lus pendant que la
// transcription était éteinte (« no metadata »), qu'allumer la case ne faisait
// pas relire. `meta.transcription_revision` dit avec quelle voie les médias de
// la base ont été lus ; la passe la compare au réglage courant.
//
// PAS UNE MIGRATION DE SCHÉMA : une clé de plus dans `meta`, absente d'une base
// ancienne — et l'absence se traite comme une révision différente.

import Foundation
import GRDB

extension GRDBStore {

    /// Clé de `meta` : la révision de transcription avec laquelle les médias de
    /// cette base ont été lus, ou `transcriptionRevisionOff`.
    public static let transcriptionRevisionKey = "transcription_revision"

    /// Valeur de la marque quand la transcription est éteinte.
    public static let transcriptionRevisionOff = "off"

    /// La marque, `nil` si aucune passe ne l'a encore écrite.
    public func transcriptionRevision() throws -> String? {
        try read { db in
            try String.fetchOne(db, sql: "SELECT v FROM meta WHERE k = ?",
                                arguments: [Self.transcriptionRevisionKey])
        }
    }

    /// Écrit la marque SEULE. C'est le geste de la transcription qui s'éteint :
    /// rien à relire, les transcriptions déjà faites restent cherchables.
    public func setTranscriptionRevision(_ value: String) throws {
        try writeLocked { db in
            try db.execute(sql: "INSERT OR REPLACE INTO meta(k, v) VALUES (?, ?)",
                           arguments: [Self.transcriptionRevisionKey, value])
        }
    }

    /// Remet en `discovered` les médias à relire, et inscrit la révision, en
    /// UNE transaction : une passe interrompue entre les deux relirait tout à
    /// nouveau, ou ne relirait rien du tout.
    ///
    /// Sont repris, parmi les documents dont l'extension est dans
    /// `extensions` (comparée en minuscules) :
    ///   · les `extracted` — transcrits par une voie antérieure, ou lus sans
    ///     transcription avec leurs seules balises ;
    ///   · les `skipped` dont `err` est EXACTEMENT l'un de `skipReasons`, ou
    ///     commence par l'un de `skipReasonPrefixes` ;
    ///   · les `failed` dont `err` contient l'une des sous-chaînes de
    ///     `failedReasonSubstrings` — les échecs « returned nothing » causés par
    ///     le bogue des morceaux d'une minute d'avant TR1.
    /// Les autres `failed` ne sont pas touchés, ni les autres `skipped` — « no
    /// metadata (no audio track) » a été produit transcription allumée, le
    /// relire ne changerait rien.
    ///
    /// Les motifs arrivent en paramètres : ils vivent dans FouineExtract, que
    /// le cœur ne peut pas importer. Rend le nombre de documents remis en file.
    @discardableResult
    public func requeueMediaForTranscription(extensions: Set<String>,
                                             skipReasons: [String],
                                             skipReasonPrefixes: [String],
                                             failedReasonSubstrings: [String] = [],
                                             revision: String) throws -> Int {
        let exts = extensions.map { $0.lowercased() }.sorted()
        return try writeLocked { db in
            var changed = 0
            if !exts.isEmpty {
                var skipTests: [String] = []
                var arguments: [DatabaseValueConvertible] = exts
                if !skipReasons.isEmpty {
                    skipTests.append("err IN (\(Self.placeholders(skipReasons.count)))")
                    arguments += skipReasons
                }
                for prefix in skipReasonPrefixes {
                    // `substr` et non `LIKE` : LIKE ignore la casse et fait de
                    // `_` et `%` des jokers.
                    skipTests.append("substr(err, 1, length(?)) = ?")
                    arguments += [prefix, prefix]
                }
                let skipped = skipTests.isEmpty ? "" : """
                     OR (state = \(DocState.skipped.rawValue)
                         AND (\(skipTests.joined(separator: " OR "))))
                    """
                var failedTests: [String] = []
                for substr in failedReasonSubstrings {
                    failedTests.append("instr(err, ?) > 0")
                    arguments.append(substr)
                }
                let failed = failedTests.isEmpty ? "" : """
                     OR (state = \(DocState.failed.rawValue)
                         AND (\(failedTests.joined(separator: " OR "))))
                    """
                try db.execute(sql: """
                    UPDATE docs SET state = \(DocState.discovered.rawValue), err = NULL
                    WHERE lower(ext) IN (\(Self.placeholders(exts.count)))
                      AND (state = \(DocState.extracted.rawValue)\(skipped)\(failed))
                    """, arguments: StatementArguments(arguments))
                changed = db.changesCount
            }
            try db.execute(sql: "INSERT OR REPLACE INTO meta(k, v) VALUES (?, ?)",
                           arguments: [Self.transcriptionRevisionKey, revision])
            return changed
        }
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }
}
