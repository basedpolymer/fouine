// GRDBStore+OCRRequeue.swift — Remise en file des pages OCR douteuses ou sans lignes (R-16).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available

import Foundation
import GRDB

/// Résultat d'une opération de remise en file OCR.
public struct OCRRequeueResult: Sendable, Equatable {
    /// Nombre de pages nouvellement insérées dans `ocr_queue`.
    public let requeued: Int
    /// Nombre de pages déjà présentes dans `ocr_queue` (non réinsérées, priorité inchangée).
    public let alreadyQueued: Int
    /// Nombre total de pages candidates trouvées pour cette population.
    public let totalCandidates: Int

    public init(requeued: Int, alreadyQueued: Int, totalCandidates: Int) {
        self.requeued = requeued
        self.alreadyQueued = alreadyQueued
        self.totalCandidates = totalCandidates
    }

    public var json: [String: Any] {
        [
            "requeued": requeued,
            "already_queued": alreadyQueued,
            "total_candidates": totalCandidates,
        ]
    }
}

extension GRDBStore {

    /// Priorité attribuée aux pages remises en file : 3 (la plus basse de l'échelle d'OCRPriority,
    /// identique à `comicArchives`).
    ///
    /// DÉCISION D'ARCHITECTURE (R-16) :
    /// Les pages remises en file ont déjà été analysées au moins une fois et disposent d'un texte
    /// dans `page_fts` (bien que de faible confiance ou sans lignes). Les nouveaux documents en attente
    /// d'OCR initial n'ont quant à eux AUCUN texte exploitable : ils doivent passer en priorité
    /// (priorités 0, 1, 2). La reprise de pages douteuses est un travail de fond d'amélioration
    /// de la qualité qui ne doit jamais bloquer ni ralentir l'indexation initiale de documents utiles.
    public static let defaultOCRRequeuePriority: Int = 3

    /// Les provenances qu'une relecture peut viser, écrites pour SQL (« 2 »).
    ///
    /// PAS `src != 0` (IX2, constaté le 12/09/2026 sur la production). Une page
    /// mise par écrit depuis un son (`src = 3`) porte `conf` NULL, exactement
    /// comme une page OCR sans ligne : le filtre la comptait « sans ligne », et
    /// la remise en masse la mettait en file, où l'OCR échouait trois fois
    /// avant de marquer le document en échec — deux vidéos transcrites y sont
    /// passées. C'est le refus que `requeueOCRPage` pose depuis BR1, appliqué
    /// aux populations et aux comptes de `stats()`.
    static let scannedSourceList = PageSource.scanned
        .map { String($0.rawValue) }.sorted().joined(separator: ", ")

    /// Efface la marque d'échec d'OCR des documents qui n'ont AUCUNE page
    /// scannée (IX2, `maintain --repair`). Rend le nombre de documents remis
    /// d'aplomb.
    ///
    /// D'OÙ VIENT LA MARQUE. Tant que la remise en masse filtrait sur
    /// `src != 0`, elle mettait en file des pages mises par écrit depuis un
    /// son ; l'OCR n'y trouvait pas d'image, échouait trois fois, et `failOCR`
    /// posait `ocr_state = failed` avec « OCR gave up after 3 attempts ». Le
    /// texte n'a jamais bougé, mais la marque se lit : `fouine_list_documents`
    /// la rend en `error`, et `SpotlightPolicy.isScanned` prend tout
    /// `ocr_state` autre que `notNeeded` pour un scan. Deux vidéos de la
    /// production la portaient le 12/09/2026.
    ///
    /// TROIS GARDES QUI TIENNENT ENSEMBLE : la marque est celle de `failOCR`
    /// (son message), le document n'a aucune page scannée — une vraie page
    /// scannée illisible garde la sienne —, et rien ne l'attend en file.
    /// `notNeeded` est l'état qu'`upsertDoc` donne à un document sans OCR.
    @discardableResult
    public func clearOCRFailuresWithoutScans() throws -> Int {
        try writeLocked { db in
            try db.execute(sql: """
                UPDATE docs SET ocr_state = ?, err = NULL
                WHERE ocr_state = ? AND err LIKE ?
                  AND NOT EXISTS (SELECT 1 FROM page_src s
                                  WHERE s.doc_id = docs.id
                                    AND s.src IN (\(Self.scannedSourceList)))
                  AND NOT EXISTS (SELECT 1 FROM ocr_queue q WHERE q.doc_id = docs.id)
                """, arguments: [OCRState.notNeeded.rawValue, OCRState.failed.rawValue,
                                 "OCR gave up after %"])
            return db.changesCount
        }
    }

    /// Remet en file d'OCR UNE page désignée (lot BR1, constat PR-24).
    ///
    /// POURQUOI À PART DE `requeueOCRPages`. Celle-ci choisit une POPULATION
    /// (les douteuses, celles sans ligne) : c'est le geste d'un dépanneur sur
    /// tout l'index. Ce que réclamait l'audit est l'autre geste, celui de qui
    /// LIT une page mal reconnue et veut qu'on la relise — un document, une
    /// page, sans condition de confiance : une page peut être parfaitement
    /// « sûre » aux yeux de Vision et illisible aux yeux du lecteur.
    ///
    /// REFUS NOMMÉ SUR UNE PAGE QUI N'EST PAS UN SCAN. Une page dont le texte
    /// vient du document (`page_src.src == 0`) ou d'une transcription (3) n'a
    /// pas d'image à relire : la remettre en file la ferait échouer trois fois
    /// dans la passe suivante, puis marquerait le document en échec. Le refus
    /// part d'ici, une seule fois, plutôt que de chaque appelant.
    ///
    /// Écriture sous verrou (`writeLocked`), comme la remise en masse. Une page
    /// déjà en file n'est pas réinsérée : elle revient en `alreadyQueued`, sa
    /// priorité et ses tentatives intactes — ce n'est pas une erreur, c'est
    /// « c'était déjà fait ».
    @discardableResult
    public func requeueOCRPage(docID: Int64, page: Int) throws -> OCRRequeueResult {
        try writeLocked { db in
            let raw = try Int.fetchOne(db, sql: """
                SELECT src FROM page_src WHERE doc_id = ? AND page = ?
                """, arguments: [docID, page])
            guard let raw, let source = PageSource(rawValue: raw),
                  PageSource.scanned.contains(source) else {
                throw FouineError.ocr(
                    "page \(page) of document \(docID) does not come from OCR: "
                    + "there is no scanned image to read again")
            }
            try db.execute(sql: """
                INSERT OR IGNORE INTO ocr_queue(doc_id, page, prio, attempts)
                VALUES (?, ?, ?, 0)
                """, arguments: [docID, page, Self.defaultOCRRequeuePriority])
            guard db.changesCount > 0 else {
                return OCRRequeueResult(requeued: 0, alreadyQueued: 1,
                                        totalCandidates: 1)
            }
            try db.execute(sql: "UPDATE docs SET ocr_state = ? WHERE id = ?",
                           arguments: [OCRState.queued.rawValue, docID])
            return OCRRequeueResult(requeued: 1, alreadyQueued: 0,
                                    totalCandidates: 1)
        }
    }

    /// Remet en file d'OCR (`ocr_queue`, `attempts = 0`, priorité la plus basse 3)
    /// les pages scannées de la population choisie (`ocrPagesToRevisit`, seuil `doubtfulConfidenceThreshold`),
    /// sans toucher au texte existant : la passe `fouine ocr` suivante les relira et remplacera.
    ///
    /// Écriture sous verrou (`writeLocked`).
    /// Les pages déjà en file sont ignorées (laissées avec leur priorité et tentatives existantes).
    @discardableResult
    public func requeueOCRPages(
        _ population: OCRPagePopulation = .doubtful,
        below threshold: Double = doubtfulConfidenceThreshold,
        limit: Int = 100_000,
        priority: Int = defaultOCRRequeuePriority
    ) throws -> OCRRequeueResult {
        try writeLocked { db in
            let predicate: String
            var statementArgs: [any DatabaseValueConvertible] = []
            switch population {
            case .noLines:
                predicate = "s.conf IS NULL OR s.conf <= 0"
            case .doubtful:
                predicate = "s.conf > 0 AND s.conf < ?"
                statementArgs.append(threshold)
            }
            statementArgs.append(limit)

            let candidateRows = try Row.fetchAll(db, sql: """
                SELECT s.doc_id AS doc_id, s.page AS page
                FROM page_src s
                WHERE s.src IN (\(Self.scannedSourceList)) AND (\(predicate))
                ORDER BY s.conf, s.doc_id, s.page
                LIMIT ?
                """, arguments: StatementArguments(statementArgs))

            var requeued = 0
            var alreadyQueued = 0
            var touchedDocs: Set<Int64> = []

            for row in candidateRows {
                let docID: Int64 = row["doc_id"]
                let page: Int = row["page"]

                try db.execute(sql: """
                    INSERT OR IGNORE INTO ocr_queue(doc_id, page, prio, attempts)
                    VALUES (?, ?, ?, 0)
                    """, arguments: [docID, page, priority])

                if db.changesCount > 0 {
                    requeued += 1
                    touchedDocs.insert(docID)
                } else {
                    alreadyQueued += 1
                }
            }

            for docID in touchedDocs {
                try db.execute(sql: "UPDATE docs SET ocr_state = ? WHERE id = ?",
                               arguments: [OCRState.queued.rawValue, docID])
            }

            return OCRRequeueResult(
                requeued: requeued,
                alreadyQueued: alreadyQueued,
                totalCandidates: candidateRows.count
            )
        }
    }
}
