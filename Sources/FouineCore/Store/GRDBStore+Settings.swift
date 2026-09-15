// GRDBStore+Settings.swift — `settings`, `agent_status` et la re-priorisation
// d'une racine épinglée (schéma v4). Propriété : A-Core, audit U2 / F7 / F4.
//
// TROIS ÉCRITURES, DEUX RÉGIMES DE VERROU — c'est le point délicat de ce
// fichier, et il vaut d'être écrit noir sur blanc.
//
//   · `writeSetting` / `removeSetting` / `writeAgentStatus` NE PRENNENT PAS
//     `fouine.lock`. Le §5.1 réserve ce verrou aux ÉCRITURES D'INDEXATION, et
//     pour cause : l'agent le garde pendant tout un lot d'OCR (dix minutes par
//     défaut). Si changer un réglage l'exigeait, la fenêtre de réglages
//     répondrait « base verrouillée par un autre processus » précisément quand
//     l'utilisateur veut réduire le budget d'un agent qui monopolise sa
//     machine — c'est-à-dire toujours au pire moment. Ces trois tables ne sont
//     touchées par aucune passe d'indexation : la sérialisation de SQLite (WAL
//     + `busy_timeout` 5 000 ms, §5.1) suffit, et c'est ce qu'elle sait faire.
//
//     Vérifié contre `EmbedRun` : sa boucle `patiently` ne réessaie que sur
//     `WriteLock.isBusy`, c'est-à-dire sur le message exact de `flock`
//     (`ExclusiveLock.acquire`). Une écriture d'état d'agent ne produit jamais
//     ce message — elle ne touche pas `fouine.lock` —, elle ne peut donc pas
//     entrer dans cette boucle d'attente. Reste la contention SQLite pure : une
//     transaction de quelques centaines de microsecondes toutes les 2 s, contre
//     un `busy_timeout` de 5 s ; le cas où elle ferait attendre la pompe à
//     vecteurs plus d'un battement de cil n'existe pas.
//
//   · `repriorizeOCRQueue`, elle, PREND le verrou : c'est un `UPDATE ocr_queue`,
//     donc une écriture d'indexation au sens plein, sur la table que la pompe
//     OCR consomme au même instant. Elle peut échouer en « base verrouillée » ;
//     l'appelant le dit, et la re-priorisation se refera au prochain geste.

import Foundation
import GRDB

// MARK: - État de l'agent (audit F7)

/// Les détails d'état que DEUX exécutables doivent reconnaître.
///
/// `detail` est un JETON SANS LANGUE depuis le lot K5 (audit A1m-10) : les
/// autres jetons, leur analyse et leur rendu anglais vivent dans
/// `AgentStatusDetail.swift`, qui étend cette énumération. Seul celui-ci reste
/// ici, parce qu'il est aussi COMPARÉ — l'app guette la transition vers « file
/// OCR vide » pour en faire sa notification de fin.
public enum AgentStatusDetail {
    /// JETON sans langue, pas une phrase : il est écrit dans `agent_status` par
    /// l'agent et comparé par l'app, qui le rend dans sa langue
    /// (`AgentDetailText`). Une phrase anglaise servait d'identifiant jusqu'au
    /// palier 3 ; un agent et une app de langues différentes se seraient ratés.
    public static let queueDrained = "queue-drained"
}

/// Ce que l'agent publie, et que l'app affiche. Une ligne de `agent_status`
/// par champ (voir `Schema.settingsDDL` pour le pourquoi).
public struct AgentStatusRecord: Sendable, Equatable {

    /// Les six phases. `stopped` est écrite par l'agent à son SIGTERM : sans
    /// elle, un agent proprement arrêté serait indiscernable d'un agent mort en
    /// vol jusqu'à l'expiration des cinq minutes.
    public enum Phase: String, Sendable, CaseIterable {
        case idle, crawl, extract, ocr, waiting, stopped
        /// La campagne de vecteurs menée par l'agent (lot AG1, PR-21). Elle
        /// vient APRÈS l'OCR : une page vectorisée avant sa reconnaissance le
        /// serait deux fois (`completeOCR` invalide ses vecteurs).
        case preparingMeaning = "preparing_meaning"

        /// Ce que le journal de l'agent et `fouine status` impriment. La barre
        /// latérale de l'app, elle, part du CAS (`AgentPhaseText`).
        public var english: String {
            switch self {
            case .idle:    return "idle"
            case .crawl:   return "walking the folders"
            case .extract: return "extracting text"
            case .ocr:     return "text recognition (OCR)"
            case .waiting: return "waiting"
            case .stopped: return "stopped"
            case .preparingMeaning: return "preparing search by meaning"
            }
        }
    }

    /// Au-delà, le statut ne veut plus rien dire : l'agent écrit au moins
    /// toutes les 2 s en travail et à chaque changement de phase ; cinq minutes
    /// de silence sont un processus tué, endormi avec la machine, ou bloqué.
    public static let staleAfter: TimeInterval = 5 * 60

    public var phase: Phase
    /// Ce que l'agent fait, en JETON SANS LANGUE (`AgentStatusDetail`) : la
    /// CLI et le serveur MCP le rendent en anglais, l'application le traduit.
    /// Vide quand il n'y a rien à dire ; une condition d'attente du §5.7 reste
    /// du texte libre (elle porte des nombres relevés sur le système).
    public var detail: String
    public var done: Int
    public var total: Int
    public var startedAt: Date?
    public var updatedAt: Date?
    public var pid: pid_t

    public init(phase: Phase, detail: String = "", done: Int = 0, total: Int = 0,
                startedAt: Date? = nil, updatedAt: Date? = nil,
                pid: pid_t = getpid()) {
        self.phase = phase
        self.detail = detail
        self.done = done
        self.total = total
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.pid = pid
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Les lignes à écrire dans `agent_status`.
    public var rows: [String: String] {
        [
            "phase": phase.rawValue,
            "detail": detail,
            "done": String(done),
            "total": String(total),
            "started_at": startedAt.map(Self.iso.string(from:)) ?? "",
            "updated_at": Self.iso.string(from: updatedAt ?? Date()),
            "pid": String(pid),
        ]
    }

    /// Relit les lignes. `nil` si la table est vide (aucun agent n'a jamais
    /// tourné sur cette base) ou si la phase est inconnue — on n'invente pas un
    /// état d'agent à partir d'une table à moitié écrite.
    public init?(rows: [String: String]) {
        guard let raw = rows["phase"], let phase = Phase(rawValue: raw) else {
            return nil
        }
        self.phase = phase
        self.detail = rows["detail"] ?? ""
        self.done = Int(rows["done"] ?? "") ?? 0
        self.total = Int(rows["total"] ?? "") ?? 0
        self.startedAt = (rows["started_at"]).flatMap { $0.isEmpty ? nil : Self.iso.date(from: $0) }
        self.updatedAt = (rows["updated_at"]).flatMap { $0.isEmpty ? nil : Self.iso.date(from: $0) }
        self.pid = (rows["pid"]).flatMap { pid_t($0) } ?? 0
    }

    /// Le processus nommé vit-il encore ? Même prudence que `LockHolder.isAlive`
    /// (audit F3) : seul `ESRCH` prouve l'absence — `EPERM` désigne un processus
    /// bien vivant appartenant à quelqu'un d'autre.
    public var isAlive: Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    /// Statut périmé : le processus a disparu, ou il n'écrit plus depuis cinq
    /// minutes. L'app l'affiche alors « agent arrêté / inactif » plutôt que de
    /// laisser à l'écran une barre de progression figée depuis avant-hier.
    public func isStale(at now: Date = Date()) -> Bool {
        if phase == .stopped { return true }
        if !isAlive { return true }
        guard let updatedAt else { return true }
        return now.timeIntervalSince(updatedAt) > Self.staleAfter
    }

    public var isStale: Bool {
        isStale(at: Date())
    }

    /// Depuis combien de temps le statut n'a pas bougé.
    public func age(at now: Date = Date()) -> TimeInterval? {
        updatedAt.map { now.timeIntervalSince($0) }
    }

    public var age: TimeInterval? {
        age(at: Date())
    }
}

// MARK: - Store

extension GRDBStore: SettingsStore {

    // MARK: Réglages (§ audit U2)

    public func settingsRows() throws -> [String: String] {
        try read { db in
            var out: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT key, value FROM settings") {
                out[row["key"]] = row["value"]
            }
            return out
        }
    }

    /// Écrit un réglage DÉJÀ normalisé (`SettingSpec.normalize`). Sans
    /// `fouine.lock` : voir l'en-tête du fichier.
    public func writeSetting(_ key: String, _ value: String) throws {
        try mapped {
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO settings(key, value, updated_at) VALUES (?,?,?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value,
                                                   updated_at = excluded.updated_at
                    """, arguments: [key, value, Self.timestamp()])
            }
        }
    }

    public func removeSetting(_ key: String) throws {
        try mapped {
            try pool.write { db in
                try db.execute(sql: "DELETE FROM settings WHERE key = ?",
                               arguments: [key])
            }
        }
    }

    // MARK: État de l'agent (audit F7)

    /// Le statut publié par l'agent, ou `nil` si aucun agent n'a jamais écrit.
    public func agentStatus() throws -> AgentStatusRecord? {
        let rows = try read { db -> [String: String] in
            var out: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT key, value FROM agent_status") {
                out[row["key"]] = row["value"]
            }
            return out
        }
        return AgentStatusRecord(rows: rows)
    }

    /// Publie le statut. Une transaction, sept `UPSERT`, aucun `fouine.lock`.
    public func writeAgentStatus(_ status: AgentStatusRecord) throws {
        let rows = status.rows
        try mapped {
            try pool.write { db in
                for (key, value) in rows.sorted(by: { $0.key < $1.key }) {
                    try db.execute(sql: """
                        INSERT INTO agent_status(key, value) VALUES (?,?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value
                        """, arguments: [key, value])
                }
            }
        }
    }

    // MARK: File OCR

    /// Longueur de la file, SEULE.
    ///
    /// `stats()` fait une quinzaine de `count(*)`, dont un sur `page_fts` — une
    /// table FTS5 de 380 000 pages. La sonde de progression de l'agent tourne
    /// toutes les 2 s pendant un lot : elle n'a besoin que de ce compte-ci, sur
    /// une table de 34 000 lignes dont c'est la clé primaire.
    public func ocrQueueLength() throws -> Int {
        try read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM ocr_queue") ?? 0
        }
    }

    /// Les documents d'une racine qui ont encore des pages en file, avec ce
    /// qu'il faut pour recalculer leur priorité (audit F4).
    public func queuedDocuments(underRoot rootID: Int64) throws
        -> [(id: Int64, ext: String, pageCount: Int)] {
        try read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT vol_uuid, rel_path FROM roots WHERE id = ?",
                arguments: [rootID]) else { return [] }
            let (clause, args) = Self.underRootClause(volUUID: row["vol_uuid"],
                                                      relPath: row["rel_path"])
            return try Row.fetchAll(db, sql: """
                SELECT DISTINCT d.id AS id, d.ext AS ext, d.n_pages AS n_pages
                FROM ocr_queue q JOIN docs d ON d.id = q.doc_id
                WHERE \(clause)
                """, arguments: StatementArguments(args))
                .map { (id: $0["id"], ext: $0["ext"], pageCount: $0["n_pages"]) }
        }
    }

    /// Repose la priorité des pages DÉJÀ en file, document par document.
    ///
    /// SOUS LE VERROU D'ÉCRITURE, et en UNE transaction : la pompe OCR lit
    /// `ocr_queue` en continu (`ORDER BY prio, attempts, doc_id, page`), et un
    /// lot qui verrait la moitié des lignes re-priorisées travaillerait dans un
    /// ordre qui n'a jamais existé. Rend le nombre de pages touchées, que
    /// l'appelant annonce à l'utilisateur — épingler une racine sans rien voir
    /// changer dans la file serait le genre de réglage auquel personne ne croit.
    @discardableResult
    public func setOCRPriorities(_ priorities: [Int64: Int]) throws -> Int {
        guard !priorities.isEmpty else { return 0 }
        return try writeLocked { db in
            var touched = 0
            for (docID, prio) in priorities.sorted(by: { $0.key < $1.key }) {
                try db.execute(sql: "UPDATE ocr_queue SET prio = ? WHERE doc_id = ?",
                               arguments: [prio, docID])
                touched += db.changesCount
            }
            return touched
        }
    }

    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
