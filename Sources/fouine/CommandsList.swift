// CommandsList.swift — `fouine list` : PARCOURIR l'index, sans chercher un mot
// (lot BR1, constat PR-06). Propriété : A-Core.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// CE QUE ÇA RÉPARE. `fouine search ""` répond « empty query », et il n'existait
// AUCUN moyen de voir ce que l'index contient : ni la liste des documents, ni un
// dossier parcouru sans requête, ni les derniers modifiés. L'assistant, lui,
// pouvait le faire depuis le palier 4 — `fouine_list_documents` sert exactement
// ces questions. Ce que l'assistant peut faire, l'humain doit pouvoir le faire.
//
// LA CLI S'ALIGNE SUR L'OUTIL MCP, JAMAIS L'INVERSE. Mêmes filtres (`folder`,
// `ext`, `path_contains`, `state`), même ordre (`path | pages | recent`), et en
// `--json` les MÊMES noms de clés que `ListDocumentsTool` — `documents`,
// `total`, `has_more`, `truncated`, et par document `doc_id`, `path`, `link`,
// `folder`, `ext`, `pages`, `state`. Un script qui lit l'un lit l'autre. Les
// deux surfaces portent désormais les MÊMES clés : `modified` est arrivée ici
// d'abord et l'outil MCP l'a gagnée au lot MC4, `ocr_pages` et
// `vectorised_pages` sont arrivées là-bas d'abord et la ligne de commande les a
// gagnées aux lots MC3 et MN1. `abs_path` reste la seule différence, et c'est
// le lien qui la porte ici.
//
// LECTURE SEULE. `openStoreReadOnly` : parcourir son index ne doit ni créer une
// base, ni prendre `fouine.lock` — sans quoi lister pendant une passe
// d'indexation serait refusé.
//
// PAGINATION PAR SQLITE (`limit`/`offset` sur un ordre TOTAL, voir
// `DocumentOrder`) : deux pages consécutives ne peuvent ni se recouvrir ni
// sauter une ligne, même si l'agent écrit entre les deux appels.

import Foundation
import ArgumentParser
import FouineCore

// MARK: - Énumérations d'options

/// Les états, avec les MOTS de l'outil MCP (`ToolSupport.states`) : `indexed`,
/// `failed`, `skipped`, `pending`. Un `ExpressibleByArgument & CaseIterable`
/// fait refuser toute autre valeur par ArgumentParser — code 64, avec la liste
/// des valeurs possibles dans le message.
enum DocStateArg: String, ExpressibleByArgument, CaseIterable {
    case indexed, failed, skipped, pending

    var value: DocState {
        switch self {
        case .indexed: return .extracted
        case .failed:  return .failed
        case .skipped: return .skipped
        case .pending: return .discovered
        }
    }
}

enum DocOrderArg: String, ExpressibleByArgument, CaseIterable {
    case path, pages, recent

    var value: DocumentOrder {
        switch self {
        case .path:   return .path
        case .pages:  return .pages
        case .recent: return .recent
        }
    }
}

// MARK: - fouine list

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the indexed documents (browse, without searching).",
        discussion: """
            Answers “what does Fouine know, exactly?”. Read-only: it never \
            creates an index and never takes the write lock, so it works while \
            an indexing pass is running.

            Without --state, EVERY state is listed — indexed, pending, failed \
            and skipped — because the question is what the index contains. The \
            state column is omitted for the documents that are indexed, the \
            normal case. Repeat --state to combine two of them: \
            `--state failed --state skipped` lists exactly what \
            `status --unreadable` lists.
            """)

    @Option(name: .long, help: "One root label (see `fouine root list`).")
    var folder: String?

    @Option(name: .long, help: "Extension, without the dot.")
    var ext: String?

    @Option(name: .customLong("path-contains"),
            help: "Substring of the path, matched literally.")
    var pathContains: String?

    @Option(name: .long,
            help: "Keep only these states; repeat to combine (default: all).")
    var state: [DocStateArg] = []

    @Option(name: .long,
            help: "recent = newest first; path = alphabetical; pages = longest first.")
    var order: DocOrderArg = .recent

    @Option(name: .long, help: "Documents per page (max \(ListCommand.maxLimit)).")
    var limit: Int = 50

    @Option(name: .long, help: "Skip the first N documents (paging).")
    var offset: Int = 0

    @Flag(name: .long, help: "JSON output.")
    var json = false

    /// Au-delà, une liste ne se lit plus dans un terminal — et la pagination
    /// existe pour ça (`--offset`). Le plafond est celui de l'outil MCP porté à
    /// 500 : un terminal accepte ce qu'une réponse d'assistant ne peut pas.
    static let maxLimit = 500

    /// Refus en 64, AVANT la base : une limite hors bornes est une faute de
    /// frappe, pas une panne (§4.3).
    func validate() throws {
        guard limit > 0, limit <= Self.maxLimit else {
            throw ValidationError(
                "--limit must be between 1 and \(Self.maxLimit).")
        }
        guard offset >= 0 else {
            throw ValidationError("--offset must be 0 or more.")
        }
    }

    func run() {
        CLI.guarded {
            let store = try CLI.openStoreReadOnly()
            // `--folder` qui ne désigne AUCUNE racine : refus en 64 avec les
            // étiquettes réelles (la règle de `FolderCheck`, constat CM-11 —
            // on ne refuse que ce que la base contredit). Sans cela, une faute
            // de frappe rendait « 0 of 0 documents », indiscernable d'un
            // dossier réellement vide.
            if let folder, !folder.isEmpty {
                let labels = try store.roots().map(\.label)
                if !labels.isEmpty, !labels.contains(folder) {
                    throw UsageRefusal(
                        message: "unknown folder “\(folder)” — folders in this "
                        + "index: " + labels.joined(separator: ", "))
                }
            }
            let filter = DocumentFilter(
                folder: folder, ext: ext, pathContains: pathContains,
                states: state.isEmpty ? nil : state.map(\.value))
            let total = try store.countDocuments(filter)
            // Un de plus que demandé : `has_more` est OBSERVÉ, jamais déduit de
            // `offset + limit < total` — le total et la page sont deux requêtes,
            // et une écriture peut les séparer (même raison que l'outil MCP).
            let rows = try store.listDocuments(filter, order: order.value,
                                               limit: limit + 1, offset: offset)
            let hasMore = rows.count > limit
            let page = Array(rows.prefix(limit))

            if json {
                // Les points de montage sont résolus UNE fois par volume, pas
                // une fois par document : `VolumeResolver.mountPoint` énumère
                // les volumes montés à chaque appel. Mesuré sur une copie de la
                // base de production le 10/09/2026, `--json --limit 500`,
                // médiane de trois passes : 152 ms avec une résolution par
                // ligne, 134 ms avec ce cache, pour un plancher de 72 ms
                // (démarrage du processus et ouverture de la base). Un listage
                // porte un ou deux volumes, jamais cinq cents.
                var mounts: [String: URL?] = [:]
                var documents: [[String: Any]] = []
                documents.reserveCapacity(page.count)
                // Les pages vectorisées, EN UNE requête pour toute la page de
                // résultats (lot MC3, constat PM-16a) : c'est la même méthode
                // que `fouine_list_documents` appelle, le POINT UNIQUE où des
                // vecteurs deviennent des pages (fenêtrage v5).
                let vectors = try store.vectorisedPageCounts(
                    forDocIDs: page.map(\.id))
                // Les pages LUES SUR L'IMAGE, en une requête comme les
                // vecteurs (lot MN1, reste du constat PM-16a) : PM-16a
                // demandait trois clés côté ligne de commande, MC3 en avait
                // livré deux. Même méthode, donc même définition que
                // `fouine_list_documents` — une transcription n'y compte pas.
                let ocr = try store.ocrPageCounts(forDocIDs: page.map(\.id))
                for row in page {
                    let mount = mounts[row.volUUID]
                        ?? VolumeResolver.mountPoint(forVolumeUUID: row.volUUID)
                    mounts[row.volUUID] = mount
                    documents.append(Self.documentJSON(
                        row, mountPoint: mount,
                        ocrPages: ocr[row.id] ?? 0,
                        vectorisedPages: vectors[row.id] ?? 0))
                }
                try CLI.printJSON([
                    "documents": documents,
                    "total": total,
                    "has_more": hasMore,
                    // `truncated` a le sens de l'outil MCP : la page rendue est
                    // plus courte que ce qui était demandé parce qu'un plafond
                    // s'est appliqué. Ici le seul plafond est `--limit`, qui
                    // est une demande : la clé est donc toujours `false`, et
                    // elle est PRÉSENTE pour qu'un script écrit sur le contrat
                    // MCP n'ait pas à distinguer les deux surfaces.
                    "truncated": false,
                ])
                return
            }
            for row in page { print("  " + Self.line(row)) }
            print("\(page.count) of \(total) documents"
                  + (hasMore ? " — `--offset \(offset + page.count)` for the next"
                             + " ones" : ""))
        }
    }

    // MARK: - Rendus

    /// `chemin · pages · modifié · état`. L'état est OMIS quand le document est
    /// indexé : c'est le cas normal, et le répéter sur mille lignes noie les
    /// quelques-unes qui disent quelque chose.
    static func line(_ row: DocumentListing) -> String {
        var parts = [row.relPath, "\(row.nPages) p.", isoDay(row.mtime)]
        // La date du DOCUMENT quand il en porte une (schéma v9, constat PR-07),
        // préfixée pour qu'on ne la confonde pas avec celle du fichier qui la
        // précède. Rien du tout sinon : une colonne vide sur mille lignes
        // apprendrait seulement que la plupart des formats ne datent rien.
        if let docDate = row.docDate { parts.append("dated " + docDay(docDate)) }
        if row.state != .extracted {
            parts.append(StatusCommand.unreadableState(row.state))
            // LA CAUSE, à la suite de l'état (lot MC3, PM-16a). « failed » sur
            // une ligne oblige à relancer une commande pour savoir si c'est un
            // fichier chiffré, un format refusé ou un disque absent ; la phrase
            // est déjà en base (`docs.err`), il n'y avait qu'à l'écrire. Elle
            // n'apparaît que là où elle dit quelque chose — jamais sur les
            // documents indexés, qui sont le cas normal.
            if let err = row.err, !err.isEmpty { parts.append(err) }
        }
        return parts.joined(separator: " · ")
    }

    static func documentJSON(_ row: DocumentListing, mountPoint: URL?,
                             ocrPages: Int = 0,
                             vectorisedPages: Int = 0) -> [String: Any] {
        [
            "doc_id": row.id,
            "path": row.relPath,
            "link": link(row, mountPoint: mountPoint),
            "folder": row.topFolder,
            "ext": row.ext,
            "pages": row.nPages,
            "modified": iso(row.mtime),
            // ADDITIF, et toujours PRÉSENT (`nil` en JSON quand le document ne
            // porte pas de date) : un script qui lit ce contrat ne doit pas
            // avoir à distinguer « clé absente » de « pas de date ».
            "doc_date": row.docDate.map { docDay($0) as Any } ?? NSNull(),
            "state": StatusCommand.unreadableState(row.state),
            // POURQUOI UN DOCUMENT MANQUE (lot MC3, PM-16a). `state: "failed"`
            // disait qu'il avait échoué, jamais pourquoi — et le serveur MCP,
            // lui, publiait la cause depuis le palier 4. Toujours PRÉSENTE et
            // `null` quand il n'y a rien à dire, comme chez lui.
            "error": row.err.map { $0 as Any } ?? NSNull(),
            // Pages dont le texte a été LU SUR L'IMAGE (lot MN1). Même clé,
            // même compte que `fouine_list_documents` : une page transcrite
            // depuis un son n'y compte pas (elle a sa propre provenance), et
            // c'est ce nombre qui dit qu'un document est un scan.
            "ocr_pages": ocrPages,
            // Pages que la recherche par le sens VOIT dans ce document. Même
            // clé, même compte que `fouine_list_documents` : c'est ce qui
            // permet de voir qu'un dossier entier est à zéro alors que la
            // couverture globale annonce deux tiers (constat PM-05).
            "vectorised_pages": vectorisedPages,
        ]
    }

    /// Le lien `fouine://` du DOCUMENT, sans page : un listage désigne des
    /// documents, et un lien qui prétendrait à la page 1 mentirait sur ce qui a
    /// été trouvé (même règle que l'outil MCP).
    ///
    /// Aucune requête de plus : `DocumentListing` porte déjà le volume et le
    /// chemin relatif.
    ///
    /// Le chemin absolu se compose comme le fait le cœur
    /// (`VolumeResolver.absolutePath` : point de montage + chemin relatif) ;
    /// seule la résolution du point de montage est remontée d'un cran, pour
    /// être partagée par toutes les lignes. Volume démonté : pas de chemin, et
    /// le lien retombe sur sa forme `doc` — c'est la règle de `DeepLink`.
    static func link(_ row: DocumentListing, mountPoint: URL?) -> String {
        let absolute = mountPoint.map {
            row.relPath.isEmpty ? $0 : $0.appendingPathComponent(row.relPath)
        }?.path
        return DeepLink.link(absolutePath: absolute, docID: row.id,
                             page: nil).absoluteString
    }

    /// UN SEUL formateur pour toute la commande. Mesuré sur une copie de la base
    /// de production le 10/09/2026 : en fabriquer un par ligne coûtait 170 ms
    /// pour 500 documents (deux appels par ligne, `modified` et la colonne de
    /// date), contre 25 ms partagé — `ISO8601DateFormatter()` est un objet cher,
    /// et une liste en rend cinq cents.
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    /// ISO 8601 complet pour le JSON — un script doit pouvoir comparer deux
    /// dates —, dans le fuseau de la machine : c'est la date que l'utilisateur
    /// reconnaît dans son propre calendrier (même choix que `AgentIdle`).
    static func iso(_ epoch: Double) -> String {
        isoFormatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    /// `AAAA-MM-JJ` pour la table : l'heure d'une date de fichier n'apprend
    /// rien à qui parcourt une liste.
    static func isoDay(_ epoch: Double) -> String {
        String(iso(epoch).prefix(10))
    }

    /// `AAAA-MM-JJ` d'une date de DOCUMENT. Elle ne passe PAS par `iso` : la
    /// valeur est un jour civil écrit à midi UTC (`DocumentDate`), et un
    /// horodatage complet dans le fuseau de la machine — « 2003-04-12T14:00:00
    /// +02:00 » — laisserait croire à une heure que le document ne porte pas.
    static func docDay(_ epoch: Double) -> String {
        let civil = DocumentDate.civil(epoch)
        return String(format: "%04d-%02d-%02d", civil.year, civil.month, civil.day)
    }
}
