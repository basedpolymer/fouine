// GRDBStore.swift — implémentation de IndexStore sur GRDB.swift (SPEC §5.1).
// Propriété : A-Core.
//
// Règles non négociables appliquées ici :
//   · DatabasePool (§3 : SQLite système compilé THREADSAFE=2, une connexion par fil) ;
//   · WAL, synchronous NORMAL, busy_timeout 5 000 ms, foreign_keys ON (§5.1) ;
//   · schéma CRÉÉ directement à la version courante (Schema.ddl + meta) ; une
//     base d'une AUTRE version est refusée, jamais rattrapée (§4.1) ;
//   · flock() exclusif sur fouine.lock pour TOUTE écriture d'indexation ; les
//     lectures ne le prennent JAMAIS (§5.1) ;
//   · suppression dans page_fts PAR ROWID ou PAR PLAGE, jamais par doc_id
//     (piège n°5 : 143 ms contre 3 ms).

import Foundation
import GRDB

public final class GRDBStore: IndexStore {

    /// Reflétée dans meta.fouine_version.
    public static let fouineVersion = "1.1"
    /// Seuil de confiance OCR provisoire (SPEC §6.2, décision de vague 0).
    /// C'est le seuil d'ENTRÉE d'une ligne dans page_fts, pas un seuil de tri
    /// des pages : voir `doubtfulConfidenceThreshold` pour ce dernier.
    public static let lowConfidenceThreshold = 0.30

    /// Seuil « page douteuse » (audit A6 du 01/09/2026). `page_src.conf` est la
    /// moyenne des lignes RETENUES : sous 0,30 il n'existe, en base réelle,
    /// aucune page — hormis les pages vides que la sentinelle `conf = 0` marque.
    /// Les 326 pages réellement douteuses vivent entre 0,30 et 0,60 (mesuré).
    public static let doubtfulConfidenceThreshold = 0.60

    /// Sous ce nombre de caractères, une page OCRisée n'entre PAS dans page_fts
    /// (§6.2) : `page_src.nchars` vaut alors 0 et le vocabulaire de la page
    /// n'existe pas pour l'index.
    public static let minIndexedCharacters = 20

    /// `fold(texte)` — la fonction SQL du filtre de CHEMIN (lot MC1).
    ///
    /// POURQUOI UNE FONCTION SWIFT. `chemin:polymeres` doit trouver
    /// `Polymères/` : il faut ignorer la casse ET les accents sur
    /// `docs.rel_path`, que rien n'indexe (ce n'est ni `page_fts`, ni
    /// `docs_fts`). SQLite n'offre ni `lower()` Unicode ni repliement des
    /// diacritiques, et aucune extension ne se charge (§5.5.2). La clause porte
    /// sur les DOCUMENTS (1 883 lignes en production), pas sur les pages : un
    /// appel par ligne de `docs`.
    ///
    /// PURE et DÉTERMINISTE : SQLite a le droit de la sortir d'une boucle et de
    /// la mettre en cache. `locale: nil` — le repliement doit être le même pour
    /// tous les utilisateurs, comme celui du tokenizer.
    static let fold = DatabaseFunction("fold", argumentCount: 1,
                                       pure: true) { values in
        guard let text = String.fromDatabaseValue(values[0]) else { return nil }
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                            locale: nil)
    }

    private final class State: @unchecked Sendable {
        let mutex = NSLock()
        /// `any DatabaseWriter` et non `DatabasePool` depuis le palier 4 : les
        /// deux ouvertures ne veulent pas la même connexion. `open(at:)` garde
        /// le `DatabasePool` (lectures parallèles, une connexion par fil) ;
        /// `openReadOnly(at:)` pose un `DatabaseQueue`, et c'est LUI qui rend
        /// la promesse « n'écrit jamais » tenable — voir l'en-tête de cette
        /// méthode. Tout ce qui suit ne parle que le protocole (`read`,
        /// `write`, `backup`, `barrierWriteWithoutTransaction`) : aucun site
        /// d'appel ne change de comportement.
        var pool: (any DatabaseWriter)?
        var lockFile: ExclusiveLock?
        var dbURL: URL?
    }

    private let state = State()

    /// Attente maximale sur `fouine.lock`, en secondes, pour la création du
    /// schéma comme pour toute écriture (§5.1 : 5 s, la même valeur que
    /// `busy_timeout`).
    /// Injectable : les tests qui prouvent le REFUS d'un verrou tenu n'ont pas
    /// à payer cinq secondes chacun pour lire le même `fouine-lock-busy`
    /// (lot I2 — quatre tests, vingt secondes par gate).
    let lockTimeout: TimeInterval

    public init(lockTimeout: TimeInterval = 5) {
        self.lockTimeout = lockTimeout
    }

    // MARK: - Ouverture et création

    /// Ouvre la base, et la CRÉE au schéma courant si elle n'existe pas encore.
    ///
    /// Trois cas, et trois seulement :
    ///
    ///   · pas de `meta.schema_version` — base absente ou vide : on CRÉE, sous
    ///     le verrou nommé, en une transaction ;
    ///   · `schema_version` = `Schema.version` : on ouvre, SANS prendre le
    ///     verrou (c'est le cas de toutes les lectures, `fouine search` et
    ///     `status` compris) ;
    ///   · toute autre valeur : on REFUSE, avec la phrase de `schemaMismatch`,
    ///     et sans toucher à la base. Il n'y a AUCUNE migration : ce binaire
    ///     n'ouvre que le schéma qu'il crée (§4.1).
    public func open(at url: URL) throws {
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        } catch {
            throw FouineError.databaseFailure(
                "cannot create \(dir.path): \(error.localizedDescription)")
        }

        var config = Configuration()
        config.busyMode = .timeout(5.0)            // 5 000 ms (§5.1)
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            db.add(function: Self.fold)
        }

        do {
            let pool = try DatabasePool(path: url.path, configuration: config)
            // DROITS (audit A1-06, D2-09). ICI, et pas dans `prepareDatabase` :
            // celui-là s'exécute par connexion, et à la première les `-wal` et
            // `-shm` n'existent pas encore. Best-effort, jamais une raison de
            // refuser l'ouverture — voir l'en-tête de FilePermissions.swift.
            FilePermissions.restrictDatabase(at: url)

            // LA CRÉATION PASSE PAR LE VERROU NOMMÉ (audit D2-10).
            //
            // Toutes les autres écritures passent par `writeLocked` ; la
            // création du schéma s'en dispensait. Sur une installation à jour
            // c'est inoffensif — on ne fait que LIRE `meta`. Sur une PREMIÈRE
            // OUVERTURE, le seul moment où l'agent, l'app et la CLI peuvent
            // démarrer dans la même minute, deux processus entraient ensemble
            // dans la création : SQLite les sérialise, donc pas de corruption,
            // mais le second échouait en `SQLITE_BUSY` au bout de 5 s, avec un
            // message qui ne nomme personne.
            //
            // Le verrou n'est donc pris QUE s'il y a quelque chose à écrire :
            // la lecture de `meta.schema_version` n'écrit rien, et l'ouverture
            // d'une base à jour ne prend toujours aucun verrou.
            // Le nom du verrou SUIT LA BASE (BU-30) : deux bases d'un même
            // dossier ne se bloquent plus l'une l'autre. `fouine.db` donne
            // toujours `fouine.lock`.
            let lock = ExclusiveLock(path: FouinePaths.lockURL(for: url).path)
            switch try pool.read({ try Self.storedSchemaVersion($0) }) {
            case .some(Schema.version):
                break                                   // rien à faire
            case .some(let found):
                throw FouineError.databaseFailure(Self.schemaMismatch(found: found))
            case .none:
                try lock.acquire(timeout: lockTimeout)
                defer { lock.release() }
                // On RELIT sous le verrou : entre la lecture ci-dessus et
                // l'obtention du verrou, un autre processus a pu créer la base.
                // Sans cette seconde lecture on rejouerait la DDL —
                // idempotente, mais on réécrirait `created_at`.
                switch try pool.read({ try Self.storedSchemaVersion($0) }) {
                case .some(Schema.version):
                    break
                case .some(let found):
                    throw FouineError.databaseFailure(
                        Self.schemaMismatch(found: found))
                case .none:
                    try pool.write { try Self.createSchema($0) }
                }
            }

            state.mutex.lock()
            state.pool = pool
            state.dbURL = url
            state.lockFile = lock
            state.mutex.unlock()
        } catch let e as FouineError {
            throw e
        } catch {
            throw FouineError.databaseFailure(
                "opening \(url.path): \(error.localizedDescription)")
        }
    }

    // MARK: - Ouverture en LECTURE SEULE (palier 4, D2 § 5.2)

    /// Ouvre une base EXISTANTE sans jamais pouvoir y écrire, et sans la créer.
    ///
    /// Écrite pour le serveur MCP, qui vit des heures à côté de l'agent et de
    /// l'application. Trois différences avec `open(at:)`, et chacune répare un
    /// piège précis.
    ///
    /// 1. **`DatabaseQueue` en `Configuration.readonly`, et non un
    ///    `DatabasePool` sous `PRAGMA query_only`.** D2 § 5.2 recommandait
    ///    l'inverse ; la mise à l'épreuve contre la base de production a montré
    ///    que ce montage-là ne tient pas, pour DEUX raisons distinctes, et
    ///    aucune ne se voit à la lecture :
    ///
    ///    · `DatabasePool.init` appelle `setUpWALMode()`, qui **écrit** un
    ///      savepoint dès que le `-wal` est absent ou vide — exactement le cas
    ///      quand aucun autre processus Fouine ne tourne. Sous `query_only`
    ///      l'ouverture échoue (« attempt to write a readonly database ») ;
    ///      sans `query_only`, le serveur démarre en ayant écrit.
    ///    · `PRAGMA query_only` **appartient à GRDB** : `Database.endReadOnly()`
    ///      le remet à 0 à la sortie de chaque bloc de lecture
    ///      (`Database.swift:844-859`), sauf si `configuration.readonly` est
    ///      vrai. Posé dans `prepareDatabase`, il est donc effacé par la
    ///      PREMIÈRE lecture, et toutes les écritures suivantes passent. Un
    ///      garde-fou qui se désarme tout seul est pire que pas de garde-fou :
    ///      il rassure.
    ///
    ///    `Configuration.readonly` est le seul réglage que GRDB traite comme
    ///    définitif : il ouvre en `SQLITE_OPEN_READONLY`, saute la mise en place
    ///    du WAL, et court-circuite `beginReadOnly`/`endReadOnly`. C'est le
    ///    contrat qu'on veut.
    ///
    /// 2. **Le piège WAL est réel, et il est TRAITÉ, pas contourné.** Une
    ///    connexion `O_RDONLY` sur une base WAL a besoin du fichier `-shm`, et
    ///    ne peut pas le créer. Depuis SQLite 3.22, elle s'en passe quand le
    ///    `-wal` est **vide** — le cas normal, base au repos —, et sinon un
    ///    autre processus Fouine tient déjà le `-shm` : les deux cas courants
    ///    marchent. Reste un cas rare et réel : un `-wal` NON vide sans aucun
    ///    processus vivant, c'est-à-dire un écrivain qui a planté. SQLite rend
    ///    alors `SQLITE_CANTOPEN`, et la bonne réponse n'est pas d'écrire à sa
    ///    place : c'est de le dire avec le geste (`cantOpenGuidance`).
    ///
    /// 3. **Aucune création.** `open(at:)` crée une base absente, donc écrit.
    ///    Un serveur MCP qui fabriquerait un index vide parce que le chemin
    ///    était faux répondrait « rien trouvé » à tout, indéfiniment. On
    ///    compare et on refuse : créer est un geste de l'application ou de la
    ///    CLI. Depuis le lot J1 il n'y a plus de migration nulle part, donc
    ///    plus rien à distinguer de ce côté : les deux ouvertures refusent le
    ///    même désaccord de schéma, avec la même phrase.
    ///
    /// 4. **Aucun `ExclusiveLock`.** `state.lockFile` reste nil : ce store ne
    ///    peut donc littéralement pas prendre `fouine.lock`, et la campagne
    ///    d'embedding ou l'agent continuent d'écrire pendant qu'il lit. Le WAL
    ///    autorise les lecteurs concurrents, et les lectures n'ont jamais pris
    ///    le verrou (§5.1).
    ///
    /// Le délai d'occupation est ramené à **2 s** (contre 5 pour l'écriture) :
    /// un client MCP attend une réponse, pas une transaction.
    public func openReadOnly(at url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path,
                                             isDirectory: &isDirectory) else {
            throw FouineError.databaseFailure(Self.noIndexMessage(at: url.path))
        }
        // UN RÉPERTOIRE N'EST PAS UN INDEX À REPRENDRE (constat CM-20).
        // `FOUINE_DB` posé sur un dossier tombait dans le `SQLITE_CANTOPEN`
        // ci-dessous et rendait la phrase du journal à reprendre : elle
        // envoyait lancer `fouine maintain` sur un dossier.
        if isDirectory.boolValue {
            throw FouineError.databaseFailure(Self.folderNotAnIndex(at: url.path))
        }

        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(2.0)
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in db.add(function: Self.fold) }

        let pool: DatabaseQueue
        do {
            pool = try DatabaseQueue(path: url.path, configuration: config)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CANTOPEN {
            // DEUX CAUSES DERRIÈRE LE MÊME CODE, et une seule était nommée
            // (constat CM-06). Mesuré le 10/09/2026, base en `journal_mode =
            // wal`, ouverture `mode=ro` :
            //   · `.db` SEUL, sans `-wal` : CANTOPEN — c'est une COPIE, rien
            //     n'a planté ;
            //   · `.db` + `-wal` (vide ou non), même sans `-shm` : s'ouvre.
            // Le signe observable est donc l'absence du `-wal`, et non celle
            // du `-shm` comme on pouvait le croire.
            let hasWAL = FileManager.default.fileExists(atPath: url.path + "-wal")
            throw FouineError.databaseFailure(
                "cannot open \(url.path) read-only: "
                + (hasWAL ? Self.cantOpenGuidance
                          : Self.copiedWithoutCompanions(at: url.path)))
        } catch {
            throw FouineError.databaseFailure(
                "opening \(url.path) read-only: \(error.localizedDescription)")
        }

        let found = try mapped {
            try pool.read { db in
                try Int.fetchOne(db, sql: "SELECT v FROM meta WHERE k = 'schema_version'")
            }
        }
        guard let found else {
            throw FouineError.databaseFailure(
                "\(url.path) is not a Fouine index (no schema_version in meta)")
        }
        guard found == Schema.version else {
            // EXACTEMENT la phrase de l'ouverture en écriture : une base d'un
            // autre schéma est refusée de la même façon partout, et le geste
            // qu'on donne ne dépend pas de la commande qui l'a rencontrée.
            throw FouineError.databaseFailure(Self.schemaMismatch(found: found))
        }

        state.mutex.lock()
        state.pool = pool
        state.dbURL = url
        state.lockFile = nil
        state.mutex.unlock()
    }

    /// « Il n'y a pas d'index ici », en un seul endroit : le serveur MCP, la
    /// CLI en lecture (audit A1m-09) et l'application doivent refuser un chemin
    /// vide avec exactement la même phrase, et cette phrase doit porter le
    /// GESTE — sans quoi « aucun résultat » reste la seule chose que
    /// l'utilisateur lise, indéfiniment.
    public static func noIndexMessage(at path: String) -> String {
        "no Fouine index at \(path) — index some folders first "
        + "(open Fouine.app, or `fouine root add <folder>` then `fouine index`)"
    }

    /// Ce qu'il faut faire quand une ouverture en lecture seule bute sur le
    /// `-shm`. Le cas est rare (un écrivain a planté en laissant un `-wal` non
    /// vide) et il se répare tout seul dès qu'un processus qui a le droit
    /// d'écrire ouvre la base : la CLI, l'application, l'agent.
    ///
    /// Le geste NOMMAIT `fouine status` jusqu'à l'audit A1m-09 ; depuis, cette
    /// commande lit elle aussi en lecture seule et ne peut donc plus rejouer le
    /// journal. `fouine maintain` est le geste le plus proche qui écrive : il
    /// prend le verrou et termine par un `wal_checkpoint(TRUNCATE)`.
    /// `FOUINE_DB` (ou `--db`) posé sur un RÉPERTOIRE (constat CM-20). La
    /// variable attend le chemin complet du fichier `.db` ; jusqu'ici, un
    /// dossier tombait dans le refus `SQLITE_CANTOPEN` et l'utilisateur lisait
    /// qu'un programme avait planté.
    public static func folderNotAnIndex(at path: String) -> String {
        "\(path) is a folder, not a Fouine index — FOUINE_DB must point at the "
        + ".db file"
    }

    /// Le `.db` a été recopié SEUL (constat CM-06) : `cp`, une restauration
    /// Time Machine, un transfert vers un autre Mac. Rien n'a planté, et la
    /// phrase de reprise de journal (`cantOpenGuidance`) le laissait croire.
    ///
    /// Le geste est le même — une ouverture en écriture répare —, mais il est
    /// donné avec la variable, parce que la copie n'est pas la base par défaut :
    /// `fouine maintain` tout court réparerait l'autre.
    public static func copiedWithoutCompanions(at path: String) -> String {
        "this copy of the index was made without its -wal and -shm companions "
        + "(a plain copy, Time Machine, another Mac) — run `fouine maintain` "
        + "once on it (FOUINE_DB=\(path) fouine maintain), or make copies with "
        + "`fouine backup`"
    }

    public static let cantOpenGuidance =
        "the index has a write-ahead log that only a writer can recover "
        + "(this happens after a crash, or when the .db was copied without its -wal). "
        + "Run `fouine maintain` once, or open "
        + "Fouine.app, then try again."

    /// La phrase d'un désaccord de schéma, en ANGLAIS et en un seul endroit :
    /// le serveur MCP la rend à l'ouverture ET à chaque `tools/call` (la base
    /// peut changer de version pendant qu'il tourne), l'application la traduit
    /// en un geste (`OpenErrorDiagnosis`), et les trois doivent dire exactement
    /// la même chose.
    ///
    /// UN SCHÉMA PLUS ANCIEN NE SE RATTRAPE PAS : Fouine n'ouvre que le schéma
    /// qu'il crée, et la phrase doit donc dire le seul geste possible — refaire
    /// l'index — au lieu de promettre une migration qui n'existe pas.
    public static func schemaMismatch(found: Int) -> String {
        found > Schema.version
            ? "this Fouine index was written by a newer version — update the fouine binary"
            : "this Fouine index predates 1.0.0 (schema v\(found), this binary "
              + "expects v\(Schema.version)) — delete it and index again"
    }

    /// La version inscrite dans `meta`, lue sur une connexion ARBITRAIRE et
    /// sans supposer que la table existe. `nil` = base vide, ou base qui n'a
    /// jamais été une base Fouine.
    static func storedSchemaVersion(_ db: Database) throws -> Int? {
        guard try db.tableExists("meta") else { return nil }
        return try Int.fetchOne(
            db, sql: "SELECT v FROM meta WHERE k = 'schema_version'")
    }

    /// Le schéma COURANT, POSÉ D'UN COUP. C'est la SEULE façon dont une base
    /// Fouine vient au monde, et `Schema.ddl` la seule source de la forme des
    /// tables. À appeler dans une transaction d'écriture — `pool.write` en
    /// ouvre une —, sous le verrou nommé.
    static func createSchema(_ db: Database) throws {
        try db.execute(sql: Schema.ddl)
        try db.execute(sql: Schema.vecWindowMetaSQL)
        try db.execute(
            sql: """
            INSERT OR REPLACE INTO meta(k, v) VALUES
              ('schema_version', ?), ('fouine_version', ?), ('created_at', ?)
            """,
            arguments: [String(Schema.version), fouineVersion,
                        String(Date().timeIntervalSince1970)])
    }

    /// La version de schéma inscrite dans `meta`, relue MAINTENANT.
    /// `nil` si la table `meta` ne la porte pas.
    public func schemaVersion() throws -> Int? {
        try read { db in
            try Int.fetchOne(db, sql: "SELECT v FROM meta WHERE k = 'schema_version'")
        }
    }

    // MARK: - Accès interne

    var pool: any DatabaseWriter {
        get throws {
            state.mutex.lock()
            defer { state.mutex.unlock() }
            guard let p = state.pool else {
                throw FouineError.databaseFailure("database not open (call open(at:))")
            }
            return p
        }
    }

    public var databaseURL: URL? {
        state.mutex.lock(); defer { state.mutex.unlock() }
        return state.dbURL
    }

    /// Prend le verrou d'écriture inter-processus. Toute opération d'écriture
    /// d'indexation l'appelle ; aucune lecture ne l'appelle (§5.1).
    func acquireWriteLock(timeout: TimeInterval? = nil) throws {
        state.mutex.lock()
        let lock = state.lockFile
        state.mutex.unlock()
        try lock?.acquire(timeout: timeout ?? lockTimeout)
    }

    /// Prend le verrou EXPLICITEMENT, en se nommant (audit F3).
    ///
    /// Appelé en début de passe d'indexation, avec le `defer` de libération qui
    /// va avec : une passe qui tient le verrou du début à la fin échoue TÔT et
    /// avec le nom du détenteur, au lieu de découvrir l'occupation à la
    /// première écriture, après avoir déjà parcouru les racines.
    public func acquireWriteLock(as role: LockRole) throws {
        try acquireWriteLock(as: role, timeout: lockTimeout)
    }

    public func acquireWriteLock(as role: LockRole, timeout: TimeInterval) throws {
        state.mutex.lock()
        let lock = state.lockFile
        state.mutex.unlock()
        lock?.setRole(role)
        try lock?.acquire(timeout: timeout)
    }

    /// Branche le journal des reprises de verrou périmé (audit F3). Sans lui, la
    /// reprise du verrou d'un processus mort n'est écrite nulle part.
    public func setWriteLockLog(_ log: @escaping @Sendable (String) -> Void) {
        state.mutex.lock()
        let lock = state.lockFile
        state.mutex.unlock()
        lock?.setLog(log)
    }

    /// Branche le gestionnaire d'annonce d'attente de verrou (audit H4, B1-26).
    /// Appelé dès le premier blocage avec le détenteur et le délai d'attente.
    public func setWriteLockWaitHandler(_ handler: @escaping WriteLock.WaitHandler) {
        state.mutex.lock()
        let lock = state.lockFile
        state.mutex.unlock()
        lock?.setWaitHandler(handler)
    }

    /// Rend le verrou d'écriture inter-processus, sans fermer la base : le
    /// prochain write le reprendra paresseusement. C'est ce qui permet à l'agent
    /// d'arrière-plan de libérer `fouine.lock` à ses points de repos, faute de
    /// quoi la CLI et l'app ne peuvent plus jamais indexer tant qu'il tourne
    /// (§5.1). Idempotent.
    ///
    /// La libération passe par une barrière du pool : on ne rend jamais le verrou
    /// pendant qu'une écriture d'un autre fil est en vol (l'agent écrit le curseur
    /// FSEvents depuis la file du flux, hors de sa file de travail).
    public func releaseWriteLock() {
        state.mutex.lock()
        let lock = state.lockFile
        let currentPool = state.pool
        state.mutex.unlock()
        guard let lock else { return }
        guard let currentPool else { lock.release(); return }
        do { try currentPool.barrierWriteWithoutTransaction { _ in lock.release() } }
        catch { lock.release() }
    }

    /// `pool.write` précédé du verrou d'écriture.
    func writeLocked<T>(_ body: (Database) throws -> T) throws -> T {
        try acquireWriteLock()
        return try mapped { try pool.write(body) }
    }

    func read<T>(_ body: (Database) throws -> T) throws -> T {
        try mapped { try pool.read(body) }
    }

    /// Interne (et non privé) depuis le palier 2.3 : les écritures de réglages
    /// et d'état d'agent vivent dans `GRDBStore+Settings.swift` et doivent
    /// traduire leurs `DatabaseError` en `FouineError` comme tout le reste.
    func mapped<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let e as FouineError { throw e }
        catch let e as DatabaseError {
            throw FouineError.databaseFailure(e.description)
        }
    }

    // MARK: - Racines et volumes

    public func addRoot(path: URL, label: String?) throws -> Int64 {
        let resolved = try VolumeResolver.resolve(path: path)
        // Lisibilité EFFECTIVE avant tout enregistrement (§4.3, §7.1) :
        // une racine muette est pire qu'une racine absente.
        try RootProbe.probe(path)

        let effectiveLabel = label.flatMap { $0.isEmpty ? nil : $0 }
            ?? defaultLabel(for: path, resolved: resolved)

        return try writeLocked { db in
            try db.execute(sql: """
                INSERT INTO volumes(uuid, label, last_seen, fsevent_id)
                VALUES (?, ?, ?, 0)
                ON CONFLICT(uuid) DO UPDATE SET label = excluded.label,
                                                last_seen = excluded.last_seen
                """,
                arguments: [resolved.volUUID, resolved.volLabel,
                            Date().timeIntervalSince1970])
            // L'étiquette EST la facette « Dossiers » (`docs.top_folder`) : deux
            // racines homonymes — ~/Documents/Cours et ~/Archives/Cours, cas
            // banal dès que les dossiers s'ajoutent depuis le Finder — se
            // fondraient en une seule ligne de facette, sans moyen de les
            // distinguer ni de filtrer l'une sans l'autre. On suffixe.
            let unique = try Self.uniqueLabel(
                db, wanted: effectiveLabel,
                excludingVolUUID: resolved.volUUID, relPath: resolved.relPath)
            try db.execute(sql: """
                INSERT INTO roots(vol_uuid, rel_path, label, enabled)
                VALUES (?, ?, ?, 1)
                ON CONFLICT(vol_uuid, rel_path) DO UPDATE SET label = excluded.label,
                                                              enabled = 1
                """,
                arguments: [resolved.volUUID, resolved.relPath, unique])
            guard let id = try Int64.fetchOne(
                db, sql: "SELECT id FROM roots WHERE vol_uuid = ? AND rel_path = ?",
                arguments: [resolved.volUUID, resolved.relPath]) else {
                throw FouineError.databaseFailure("root was not registered")
            }
            return id
        }
    }

    private func defaultLabel(for path: URL,
                              resolved: VolumeResolver.ResolvedRoot) -> String {
        let last = path.standardizedFileURL.lastPathComponent
        return last.isEmpty || last == "/" ? resolved.volLabel : last
    }

    /// « Cours » libre, sinon « Cours 2 », « Cours 3 »… La racine que l'on est
    /// en train de RÉENREGISTRER (même volume, même rel_path) est exclue de la
    /// comparaison : réajouter un dossier déjà connu ne doit pas le renommer.
    private static func uniqueLabel(_ db: Database, wanted: String,
                                    excludingVolUUID volUUID: String,
                                    relPath: String) throws -> String {
        let taken = Set(try String.fetchAll(db, sql: """
            SELECT label FROM roots WHERE NOT (vol_uuid = ? AND rel_path = ?)
            """, arguments: [volUUID, relPath]))
        guard taken.contains(wanted) else { return wanted }
        var n = 2
        while taken.contains("\(wanted) \(n)") { n += 1 }
        return "\(wanted) \(n)"
    }

    /// Renomme l'étiquette d'une racine.
    ///
    /// `docs.top_folder` recopie `roots.label` (§4.1) : sans la mise à jour des
    /// documents, la facette « Dossiers » et `dossier:<étiquette>` continueraient
    /// de répondre à l'ANCIEN nom jusqu'au prochain crawl complet. Les deux
    /// écritures tiennent dans la même transaction.
    /// - Returns: l'étiquette réellement posée (dédoublonnée si nécessaire).
    @discardableResult
    public func setRootLabel(id: Int64, _ label: String) throws -> String {
        let wanted = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else {
            throw FouineError.databaseFailure("empty label")
        }
        return try writeLocked { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT vol_uuid, rel_path, label FROM roots WHERE id = ?",
                arguments: [id]) else {
                throw FouineError.databaseFailure("unknown root \(id)")
            }
            let volUUID: String = row["vol_uuid"]
            let relPath: String = row["rel_path"]
            let previous: String = row["label"]
            guard previous != wanted else { return previous }
            let unique = try Self.uniqueLabel(db, wanted: wanted,
                                              excludingVolUUID: volUUID,
                                              relPath: relPath)
            try db.execute(sql: "UPDATE roots SET label = ? WHERE id = ?",
                           arguments: [unique, id])
            let (clause, args) = Self.underRootClause(volUUID: volUUID, relPath: relPath)
            let all: [(any DatabaseValueConvertible)?] = [unique] + args
            try db.execute(sql: "UPDATE docs SET top_folder = ? WHERE \(clause)",
                           arguments: StatementArguments(all))
            return unique
        }
    }

    public func roots() throws -> [RootRecord] {
        try read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, vol_uuid, rel_path, label, enabled FROM roots ORDER BY id
                """).map { row in
                RootRecord(id: row["id"], volUUID: row["vol_uuid"],
                           relPath: row["rel_path"], label: row["label"],
                           enabled: (row["enabled"] as Int) != 0)
            }
        }
    }

    /// Activation/désactivation d'une racine sans perdre l'index
    /// (utilisée par `fouine root remove` sans `--purge`).
    public func setRootEnabled(id: Int64, _ enabled: Bool) throws {
        try writeLocked { db in
            try db.execute(sql: "UPDATE roots SET enabled = ? WHERE id = ?",
                           arguments: [enabled ? 1 : 0, id])
        }
    }

    public func removeRoot(id: Int64) throws {
        try writeLocked { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT vol_uuid, rel_path FROM roots WHERE id = ?",
                arguments: [id]) else { return }
            let volUUID: String = row["vol_uuid"]
            let relPath: String = row["rel_path"]
            let ids = try Self.docIDs(db, volUUID: volUUID, relPath: relPath)
            for docID in ids { try Self.purgeDoc(db, id: docID) }
            try db.execute(sql: "DELETE FROM roots WHERE id = ?", arguments: [id])
        }
    }

    public func volumes() throws -> [(uuid: String, label: String, lastSeen: Double?)] {
        try read { db in
            try Row.fetchAll(db, sql: """
                SELECT uuid, label, last_seen FROM volumes ORDER BY label
                """).map { (uuid: $0["uuid"], label: $0["label"],
                            lastSeen: $0["last_seen"] as Double?) }
        }
    }

    /// Enregistre (ou rafraîchit) un volume monté — `fouine volume add`, annexe A.
    public func registerVolume(uuid: String, label: String) throws {
        try writeLocked { db in
            try db.execute(sql: """
                INSERT INTO volumes(uuid, label, last_seen, fsevent_id)
                VALUES (?, ?, ?, 0)
                ON CONFLICT(uuid) DO UPDATE SET label = excluded.label,
                                                last_seen = excluded.last_seen
                """, arguments: [uuid, label, Date().timeIntervalSince1970])
        }
    }

    public func fseventID(volUUID: String) throws -> UInt64 {
        try read { db in
            let v = try Int64.fetchOne(
                db, sql: "SELECT fsevent_id FROM volumes WHERE uuid = ?",
                arguments: [volUUID]) ?? 0
            return v < 0 ? 0 : UInt64(v)
        }
    }

    public func setFSEventID(volUUID: String, _ id: UInt64) throws {
        try writeLocked { db in
            try db.execute(sql: "UPDATE volumes SET fsevent_id = ? WHERE uuid = ?",
                           arguments: [Int64(bitPattern: id), volUUID])
        }
    }

    // MARK: - Documents

    public func docs(underRoot rootID: Int64) throws -> [DocRow] {
        try read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT vol_uuid, rel_path FROM roots WHERE id = ?",
                arguments: [rootID]) else { return [] }
            let volUUID: String = row["vol_uuid"]
            let relPath: String = row["rel_path"]
            let (clause, args) = Self.underRootClause(volUUID: volUUID, relPath: relPath)
            return try Row.fetchAll(db, sql: """
                SELECT id, vol_uuid, rel_path, ext, top_folder, size, mtime, n_pages,
                       state, ocr_state, lang, err, inode, doc_date
                FROM docs WHERE \(clause) ORDER BY id
                """, arguments: StatementArguments(args)).map(Self.docRow)
        }
    }

    /// `rel_path` d'une racine vide ("") désigne TOUT le volume (§4.1).
    /// Interne (et non privé) depuis le palier 2.3 : la re-priorisation d'une
    /// racine épinglée (`GRDBStore+Settings`) désigne les mêmes documents, et
    /// une seconde écriture de cette clause serait une divergence de plus.
    static func underRootClause(volUUID: String, relPath: String)
        -> (String, [(any DatabaseValueConvertible)?]) {
        if relPath.isEmpty {
            return ("vol_uuid = ?", [volUUID])
        }
        // NFC (A3-10) : le préfixe et les chemins stockés doivent être de la
        // même forme Unicode, sans quoi `substr(rel_path, 1, n)` ne reconnaît
        // rien — et `n` lui-même change, SQLite comptant les points de code.
        let prefix = RelPath.normalized(relPath) + "/"
        // SQLite compte les CARACTÈRES (points de code), pas les octets.
        return ("vol_uuid = ? AND substr(rel_path, 1, ?) = ?",
                [volUUID, prefix.unicodeScalars.count, prefix])
    }

    private static func docIDs(_ db: Database, volUUID: String,
                               relPath: String) throws -> [Int64] {
        let (clause, args) = underRootClause(volUUID: volUUID, relPath: relPath)
        return try Int64.fetchAll(db, sql: "SELECT id FROM docs WHERE \(clause)",
                                  arguments: StatementArguments(args))
    }

    private static func docRow(_ row: Row) -> DocRow {
        DocRow(id: row["id"], record: DocRecord(
            volUUID: row["vol_uuid"], relPath: row["rel_path"], ext: row["ext"],
            topFolder: row["top_folder"], size: row["size"], mtime: row["mtime"],
            nPages: row["n_pages"],
            state: DocState(rawValue: row["state"]) ?? .discovered,
            ocrState: OCRState(rawValue: row["ocr_state"]) ?? .notNeeded,
            lang: row["lang"], err: row["err"],
            // `hasColumn` : toutes les lectures ne demandent pas `inode`
            // (`docRow(id:)` et la recherche n'en ont que faire), et une colonne
            // absente de la requête vaut « inconnu », pas 0 par accident.
            inode: row.hasColumn("inode") ? (row["inode"] ?? 0) : 0,
            // Même règle que `inode` : une colonne absente de la requête vaut
            // « on n'a pas demandé », pas « le document n'a pas de date ».
            docDate: row.hasColumn("doc_date") ? row["doc_date"] : nil))
    }

    public func upsertDoc(_ d: DocRecord) throws -> Int64 {
        try writeLocked { db in
            let existing = try Row.fetchOne(db, sql: """
                SELECT id, size, mtime FROM docs WHERE vol_uuid = ? AND rel_path = ?
                """, arguments: [d.volUUID, d.relPath])

            if let row = existing {
                let id: Int64 = row["id"]
                let size: Int64 = row["size"]
                let mtime: Double = row["mtime"]
                // Delta no-op : (size, mtime) identiques -> on conserve
                // state / ocr_state / n_pages / indexed_at (T10, idempotence).
                if size == d.size && mtime == d.mtime { return id }

                // Le contenu a changé : l'OCR précédent n'est plus valide, et
                // la date lue dans les métadonnées non plus (schéma v9) — la
                // ré-extraction qui suit la réécrit, ou la laisse vide.
                try db.execute(sql: """
                    UPDATE docs SET ext = ?, top_folder = ?, size = ?, mtime = ?,
                                    n_pages = ?, state = ?, ocr_state = ?,
                                    lang = ?, err = ?, indexed_at = ?, inode = ?,
                                    doc_date = NULL
                    WHERE id = ?
                    """,
                    arguments: [d.ext, d.topFolder, d.size, d.mtime, d.nPages,
                                d.state.rawValue, OCRState.notNeeded.rawValue,
                                d.lang, d.err, Date().timeIntervalSince1970,
                                d.inode, id])
                try db.execute(sql: "DELETE FROM ocr_queue WHERE doc_id = ?",
                               arguments: [id])
                // Le chemin n'a pas bougé (c'est la clé de la recherche
                // ci-dessus), donc le nom non plus : ce repose est un filet,
                // pas une mise à jour — il rattrape une ligne de `docs_fts`
                // perdue par une base plus ancienne que le schéma v8.
                try Self.indexDocumentName(db, id: id, relPath: d.relPath)
                return id
            }

            try db.execute(sql: """
                INSERT INTO docs(vol_uuid, rel_path, ext, top_folder, size, mtime,
                                 n_pages, state, ocr_state, lang, err, indexed_at,
                                 inode)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                arguments: [d.volUUID, d.relPath, d.ext, d.topFolder, d.size, d.mtime,
                            d.nPages, d.state.rawValue, d.ocrState.rawValue,
                            d.lang, d.err, Date().timeIntervalSince1970, d.inode])
            let id = db.lastInsertedRowID
            // MÊME TRANSACTION que l'insertion dans `docs` : les deux tables ne
            // peuvent pas diverger sur un arrêt brutal (schéma v8, D-R3).
            try Self.indexDocumentName(db, id: id, relPath: d.relPath)
            return id
        }
    }

    /// Renommages et déplacements (schéma v6, constat A3-02).
    ///
    /// LA MÉTHODE QUI N'EFFACE RIEN. Elle ne touche ni `page_fts`, ni
    /// `page_src`, ni `ocr_layout`, ni `ocr_queue`, ni `page_vec` : ces tables
    /// sont indexées par `doc_id` (ou par le rowid structuré qui en dérive), et
    /// le `doc_id` ne bouge pas. C'est exactement ce qui rend un `mv` gratuit
    /// là où il coûtait des heures d'OCR et de vectorisation.
    ///
    /// `indexed_at` n'est PAS retouché : rien n'a été ré-indexé.
    ///
    /// DEUX PASSES, dans la même transaction. `docs` porte
    /// `UNIQUE(vol_uuid, rel_path)`, et un lot de déplacements peut passer par
    /// un état intermédiaire en collision — `a -> b` pendant que `b -> c`, ce
    /// qu'un dossier renommé produit dès qu'il contient deux niveaux. La
    /// première passe gare chaque ligne sur un chemin impossible (préfixe
    /// `\u{0}`, qu'aucun chemin POSIX ne peut porter), la seconde pose le
    /// chemin définitif. Deux écritures par ligne, une seule transaction.
    public func relocateDocs(_ moves: [DocRelocation]) throws {
        guard !moves.isEmpty else { return }
        try writeLocked { db in
            for move in moves {
                try db.execute(
                    sql: "UPDATE docs SET rel_path = ? WHERE id = ?",
                    arguments: [Self.parkingPath(id: move.id), move.id])
            }
            for move in moves {
                try db.execute(sql: """
                    UPDATE docs SET rel_path = ?, top_folder = ?, ext = ?, inode = ?
                    WHERE id = ?
                    """,
                    arguments: [move.relPath, move.topFolder, move.ext,
                                move.inode, move.id])
                // Un déplacement CHANGE le nom du document et celui de son
                // dossier : `docs_fts` suit, dans la même transaction (D-R3).
                try Self.indexDocumentName(db, id: move.id, relPath: move.relPath)
            }
        }
    }

    /// Chemin de garage d'une ligne en cours de déplacement.
    ///
    /// Un `rel_path` est relatif à la racine du volume (§4.1) : il ne commence
    /// jamais par une barre oblique, et le crawler retire toutes celles de tête.
    /// Le préfixe ci-dessous ne peut donc entrer en collision avec aucun chemin
    /// réel, et l'identifiant le rend unique dans le lot.
    ///
    /// PAS de `\u{0}` (essayé) : SQLite tronque une chaîne au premier octet nul,
    /// les deux chemins de garage devenaient la chaîne vide et la contrainte
    /// `UNIQUE(vol_uuid, rel_path)` sautait dès le second déplacement.
    static func parkingPath(id: Int64) -> String { "//fouine-relocating/\(id)" }

    /// Nombre de pages du document, connu seulement APRÈS extraction.
    /// `upsertDoc` étant un no-op strict quand (size, mtime) n'ont pas bougé
    /// (§ contrat), il ne peut pas porter cette mise à jour : d'où ce point
    /// d'entrée dédié, hors protocole gelé.
    public func setPageCount(_ id: Int64, _ n: Int) throws {
        try writeLocked { db in
            try db.execute(sql: "UPDATE docs SET n_pages = ? WHERE id = ?",
                           arguments: [n, id])
        }
    }

    /// Langue dominante du document (audit X2, F8).
    ///
    /// `docs.lang` existe depuis le schéma v1 et n'a JAMAIS été alimentée :
    /// `DocRecord.lang` naît à `nil` et `upsertDoc` est un no-op strict quand
    /// (size, mtime) n'ont pas bougé — c'est-à-dire entre le crawl et
    /// l'extraction de la même passe, le seul moment où l'on connaît le texte.
    /// D'où ce point d'entrée dédié, jumeau de `setPageCount`.
    public func setDocLanguage(_ id: Int64, _ lang: String?) throws {
        try writeLocked { db in
            try db.execute(sql: "UPDATE docs SET lang = ? WHERE id = ?",
                           arguments: [lang, id])
        }
    }

    /// Date INSCRITE DANS LE DOCUMENT (schéma v9, constat PR-07).
    ///
    /// Jumeau de `setDocLanguage`, et pour la même raison : la métadonnée n'est
    /// connue qu'à l'extraction, moment où `upsertDoc` est un no-op strict
    /// (size et mtime n'ont pas bougé depuis le crawl). L'appelant passe déjà
    /// la valeur ANALYSÉE (`DocumentDate.parse`) : le store n'interprète aucune
    /// chaîne, il écrit un instant ou NULL.
    public func setDocDate(_ id: Int64, _ date: Double?) throws {
        try writeLocked { db in
            try db.execute(sql: "UPDATE docs SET doc_date = ? WHERE id = ?",
                           arguments: [date, id])
        }
    }

    public func setDocState(_ id: Int64, _ s: DocState, err: String?) throws {
        try writeLocked { db in
            try db.execute(sql: """
                UPDATE docs SET state = ?, err = ?, indexed_at = ? WHERE id = ?
                """,
                arguments: [s.rawValue, err, Date().timeIntervalSince1970, id])
        }
    }

    public func removeDoc(id: Int64) throws {
        try writeLocked { db in try Self.purgeDoc(db, id: id) }
    }

    /// Purge complète : docs, page_fts (PAR PLAGE DE ROWID), page_src,
    /// ocr_layout, ocr_queue (§4.2).
    static func purgeDoc(_ db: Database, id: Int64) throws {
        let range = Schema.ftsRowIDRange(docID: id)
        try db.execute(sql: "DELETE FROM page_fts WHERE rowid BETWEEN ? AND ?",
                       arguments: [range.lowerBound, range.upperBound])
        try db.execute(sql: "DELETE FROM page_src  WHERE doc_id = ?", arguments: [id])
        // ocr_layout partage le rowid structuré de page_fts (§4.1, audit A4) :
        // même suppression par PLAGE, jamais par doc_id.
        try db.execute(sql: "DELETE FROM ocr_layout WHERE rowid BETWEEN ? AND ?",
                       arguments: [range.lowerBound, range.upperBound])
        // page_vec porte un rowid de FENÊTRE depuis le schéma v5 : la plage est
        // celle des pages multipliée par le facteur de fenêtre. Toujours par
        // PLAGE, jamais par doc_id.
        let vecRange = Schema.vecRowIDRange(docID: id)
        try db.execute(sql: "DELETE FROM page_vec   WHERE rowid BETWEEN ? AND ?",
                       arguments: [vecRange.lowerBound, vecRange.upperBound])
        try db.execute(sql: "DELETE FROM ocr_queue  WHERE doc_id = ?", arguments: [id])
        // Le nom du document part avec lui (schéma v8, D-R3).
        try removeDocumentName(db, id: id)
        try db.execute(sql: "DELETE FROM docs       WHERE id = ?",     arguments: [id])
    }

    /// Résolution (vol_uuid, rel_path) -> doc_id, pour `fouine ocr import` (annexe B).
    public func docID(volUUID: String, relPath: String) throws -> Int64? {
        // NFC (A3-10) : le chemin peut venir d'un JSON, d'un argument `--only`
        // ou d'un glisser-déposer, donc de n'importe quelle forme Unicode ; la
        // base, elle, n'en contient qu'une.
        let wanted = RelPath.normalized(relPath)
        return try read { db in
            try Int64.fetchOne(
                db, sql: "SELECT id FROM docs WHERE vol_uuid = ? AND rel_path = ?",
                arguments: [volUUID, wanted])
        }
    }

    public func docRow(id: Int64) throws -> DocRow? {
        try read { db in
            try Row.fetchOne(db, sql: """
                SELECT id, vol_uuid, rel_path, ext, top_folder, size, mtime, n_pages,
                       state, ocr_state, lang, err, doc_date FROM docs WHERE id = ?
                """, arguments: [id]).map(Self.docRow)
        }
    }

    // MARK: - Pages

    /// POINT D'ÉTRANGLEMENT du rowid structuré (audit S2). Refuse une page hors
    /// de `0…Schema.maxPage` AVANT d'ouvrir la transaction : au-delà, le rowid
    /// calculé désigne un AUTRE document et l'écrase en silence.
    ///
    /// `FouineError.extraction` et non un cas nouveau : les trois pipelines la
    /// traduisent déjà en `docs.err` + état `.failed` par leur `describe`
    /// (« extraction : … »), là où `.databaseFailure` interromprait toute la
    /// passe. PDF et djvu refusent déjà en amont, avant de payer l'extraction ;
    /// ce point-ci est celui que TOUS les autres chemins traversent — archives à
    /// 100 000 images, texte re-paginé, canal d'import, appel direct au store.
    private static func checkPageBound(docID: Int64, page: Int,
                                       what: String) throws {
        guard page >= 0, page <= Schema.maxPage else {
            throw FouineError.extraction(
                "document too long: page \(page) is past the limit of "
                + "\(Schema.maxPage) pages per document (\(what), doc \(docID))")
        }
    }

    public func replacePages(docID: Int64, pages: [PageText]) throws {
        for p in pages {
            try Self.checkPageBound(docID: docID, page: p.page,
                                    what: "\(pages.count) page(s) supplied")
        }
        try writeLocked { db in
            // UNE transaction : effacement PAR PLAGE puis insertion à rowid explicite.
            let range = Schema.ftsRowIDRange(docID: docID)
            try db.execute(sql: "DELETE FROM page_fts WHERE rowid BETWEEN ? AND ?",
                           arguments: [range.lowerBound, range.upperBound])
            // Le texte change : TOUTES les fenêtres de ces pages sont périmées,
            // sentinelle de complétude comprise. `fouine embed` les reproduira
            // (schéma v5) — et tant que la sentinelle manque, la page est
            // « incomplète » pour la pompe, donc re-sélectionnée.
            let vecRange = Schema.vecRowIDRange(docID: docID)
            try db.execute(sql: "DELETE FROM page_vec WHERE rowid BETWEEN ? AND ?",
                           arguments: [vecRange.lowerBound, vecRange.upperBound])
            for p in pages {
                try db.execute(sql: """
                    INSERT INTO page_fts(rowid, body, doc_id, page) VALUES (?,?,?,?)
                    """,
                    arguments: [Schema.ftsRowID(docID: docID, page: p.page),
                                p.text, docID, p.page])
                try db.execute(sql: """
                    INSERT INTO page_src(doc_id, page, src, nchars, engine, engine_rev, conf)
                    VALUES (?,?,?,?,0,NULL,NULL)
                    ON CONFLICT(doc_id, page) DO UPDATE
                      SET src = excluded.src, nchars = excluded.nchars,
                          engine = 0, engine_rev = NULL, conf = NULL
                    """,
                    arguments: [docID, p.page, p.source.rawValue, p.text.count])
            }
            // Les pages de ce document qui ne sont plus fournies disparaissent.
            //
            // TROIS TABLES, PAS UNE (audit A1m-13). `page_src` était seule
            // purgée : un document ré-extrait avec MOINS de pages — une
            // pagination qui change, un PDF remplacé — laissait derrière lui
            // des lignes d'`ocr_queue` pour des pages qui n'existent plus
            // (rendues par la file, échouées au rendu, retentées trois fois
            // avant d'abandonner) et des blobs `ocr_layout` que plus rien ne
            // lit. Même transaction, même liste de pages : il n'y a aucune
            // raison que les trois divergent.
            //
            // `ocr_layout` s'attaque par PLAGE de rowid structuré — elle n'a
            // plus de colonne `doc_id` depuis le schéma v5 —, avec l'exclusion
            // sur `rowid % 100000`. C'est la forme de `completeOCR`, et elle
            // reste une sonde de clé primaire.
            let ocrRange = Schema.ftsRowIDRange(docID: docID)
            if pages.isEmpty {
                try db.execute(sql: "DELETE FROM page_src WHERE doc_id = ?",
                               arguments: [docID])
                try db.execute(sql: "DELETE FROM ocr_queue WHERE doc_id = ?",
                               arguments: [docID])
                try db.execute(
                    sql: "DELETE FROM ocr_layout WHERE rowid BETWEEN ? AND ?",
                    arguments: [ocrRange.lowerBound, ocrRange.upperBound])
            } else {
                let list = pages.map { String($0.page) }.joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM page_src WHERE doc_id = ? AND page NOT IN (\(list))",
                    arguments: [docID])
                try db.execute(
                    sql: "DELETE FROM ocr_queue WHERE doc_id = ? AND page NOT IN (\(list))",
                    arguments: [docID])
                try db.execute(
                    sql: "DELETE FROM ocr_layout WHERE rowid BETWEEN ? AND ? "
                        + "AND rowid % \(Schema.pagesPerDocLimit) NOT IN (\(list))",
                    arguments: [ocrRange.lowerBound, ocrRange.upperBound])
            }
        }
    }

    /// Métadonnées de provenance des pages désignées, indexées par rowid structuré.
    ///
    /// FORME SARGABLE OBLIGATOIRE (recette tranche A, bogue 2) : le filtre
    /// `(doc_id * 100000 + page) IN (…)` n'est pas résoluble par la clé
    /// primaire de page_src — `EXPLAIN QUERY PLAN` rendait `SCAN page_src`,
    /// 42-49 ms par appel sur 363 058 lignes, DEUX fois par recherche (P4).
    /// Les row-values `(doc_id, page) IN (VALUES …)` passent par la PK :
    /// mesuré < 0,5 ms à 50 clés. Les clés sont interpolées en littéraux
    /// entiers (aucune injection possible) pour ne pas heurter le plafond de
    /// variables SQLite à `--limit` élevé.
    public func pageMeta(for keys: [(docID: Int64, page: Int)]) throws
        -> [Int64: (source: PageSource, engine: OCREngineID, conf: Double?)] {
        guard !keys.isEmpty else { return [:] }
        return try read { db in
            var out: [Int64: (source: PageSource, engine: OCREngineID, conf: Double?)] = [:]
            let rows = try Row.fetchAll(db, sql: Self.pageMetaSQL(for: keys))
            for r in rows {
                let key = Schema.ftsRowID(docID: r["doc_id"], page: r["page"])
                out[key] = (PageSource(rawValue: r["src"]) ?? .native,
                            OCREngineID(rawValue: r["engine"]) ?? .none,
                            r["conf"] as Double?)
            }
            return out
        }
    }

    /// SQL de `pageMeta`, exposé en interne pour que le test de non-régression
    /// puisse vérifier le plan (`SEARCH … USING PRIMARY KEY`).
    static func pageMetaSQL(for keys: [(docID: Int64, page: Int)]) -> String {
        let values = keys.map { "(\($0.docID),\($0.page))" }.joined(separator: ",")
        return """
            SELECT doc_id, page, src, engine, conf FROM page_src
            WHERE (doc_id, page) IN (VALUES \(values))
            """
    }

    /// Boîtes OCR d'une page (surlignage, §5.6). Accès DIRECT par rowid
    /// structuré depuis l'audit A4 : `SEARCH ocr_layout USING INTEGER PRIMARY KEY`.
    public func ocrLayout(docID: Int64, page: Int) throws -> [OCRLine]? {
        let rowid = Schema.ftsRowID(docID: docID, page: page)
        let blob: Data? = try read { db in
            try Data.fetchOne(
                db, sql: "SELECT blob FROM ocr_layout WHERE rowid = ?",
                arguments: [rowid])
        }
        guard let blob else { return nil }
        return try OCRLayoutCodec.decode(blob)
    }

    // MARK: - File OCR

    public func enqueueOCR(docID: Int64, pages: [Int], priority: Int) throws {
        guard !pages.isEmpty else { return }
        try writeLocked { db in
            for page in pages {
                try db.execute(sql: """
                    INSERT INTO ocr_queue(doc_id, page, prio, attempts) VALUES (?,?,?,0)
                    ON CONFLICT(doc_id, page) DO UPDATE SET prio = excluded.prio
                    """, arguments: [docID, page, priority])
            }
            try db.execute(sql: "UPDATE docs SET ocr_state = ? WHERE id = ?",
                           arguments: [OCRState.queued.rawValue, docID])
        }
    }

    public func nextOCRBatch(limit: Int) throws
        -> [(docID: Int64, page: Int, path: String)] {
        let rows: [(Int64, Int, String, String)] = try read { db in
            try Row.fetchAll(db, sql: """
                SELECT q.doc_id AS doc_id, q.page AS page,
                       d.vol_uuid AS vol_uuid, d.rel_path AS rel_path,
                       (SELECT count(*) FROM ocr_queue q2 WHERE q2.doc_id = q.doc_id) AS remaining
                FROM ocr_queue q JOIN docs d ON d.id = q.doc_id
                ORDER BY q.prio, q.attempts, remaining ASC, q.doc_id DESC, q.page
                LIMIT ?
                """, arguments: [limit])
                .map { ($0["doc_id"], $0["page"], $0["vol_uuid"], $0["rel_path"]) }
        }
        // Chemin ABSOLU ; volume démonté -> volumeNotMounted (exit 2, §4.3).
        return try rows.map { docID, page, volUUID, relPath in
            let url = try VolumeResolver.absolutePath(volUUID: volUUID, relPath: relPath)
            return (docID: docID, page: page, path: url.path)
        }
    }

    /// Pages en attente d'OCR, pour `fouine ocr export --pending` (annexe B).
    public func pendingOCRPages(limit: Int) throws
        -> [(docID: Int64, page: Int, volUUID: String, relPath: String, prio: Int)] {
        try read { db in
            try Row.fetchAll(db, sql: """
                SELECT q.doc_id AS doc_id, q.page AS page, q.prio AS prio,
                       d.vol_uuid AS vol_uuid, d.rel_path AS rel_path,
                       (SELECT count(*) FROM ocr_queue q2 WHERE q2.doc_id = q.doc_id) AS remaining
                FROM ocr_queue q JOIN docs d ON d.id = q.doc_id
                ORDER BY q.prio, q.attempts, remaining ASC, q.doc_id DESC, q.page
                LIMIT ?
                """, arguments: [limit])
                .map { (docID: $0["doc_id"], page: $0["page"],
                        volUUID: $0["vol_uuid"], relPath: $0["rel_path"],
                        prio: $0["prio"]) }
        }
    }

    /// Les deux populations de pages OCR à reprendre — elles n'ont RIEN à voir
    /// et le seul seuil ne les distinguait pas (audit A6 du 01/09/2026).
    ///
    /// `VisionOCREngine` pose `meanConfidence = 0` quand AUCUNE ligne n'est
    /// retenue : ce 0 est une sentinelle d'absence, pas une mesure de qualité.
    /// Un unique `conf < 0,30` ne remontait donc que les 510 pages vides de la
    /// base, jamais une seule page douteuse.
    public enum OCRPagePopulation: Sendable {
        /// `conf` nulle ou 0 : aucune ligne reconnue — à re-rendre, peut-être à
        /// un DPI supérieur. 510 pages en base (mesuré).
        case noLines
        /// `0 < conf < seuil` : du texte a été reconnu, mais mal. Le vrai
        /// gisement d'une re-OCRisation : 326 pages sous 0,60 (mesuré).
        case doubtful
    }

    /// Pages OCRisées à reprendre — annexe B, « re-OCRiser les pages douteuses »
    /// en une requête sur idx_page_src_conf.
    ///
    /// `threshold` n'est lu que pour `.doubtful` ; `.noLines` n'a pas de seuil,
    /// c'est un test d'égalité sur la sentinelle.
    public func ocrPagesToRevisit(_ population: OCRPagePopulation,
                                  below threshold: Double = doubtfulConfidenceThreshold,
                                  limit: Int) throws
        -> [(docID: Int64, page: Int, volUUID: String, relPath: String, conf: Double?)] {
        let predicate: String
        var arguments: [any DatabaseValueConvertible] = []
        switch population {
        case .noLines:
            predicate = "s.conf IS NULL OR s.conf <= 0"
        case .doubtful:
            predicate = "s.conf > 0 AND s.conf < ?"
            arguments.append(threshold)
        }
        arguments.append(limit)
        return try read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.doc_id AS doc_id, s.page AS page, s.conf AS conf,
                       d.vol_uuid AS vol_uuid, d.rel_path AS rel_path
                FROM page_src s JOIN docs d ON d.id = s.doc_id
                WHERE s.src IN (\(Self.scannedSourceList)) AND (\(predicate))
                ORDER BY s.conf, s.doc_id, s.page
                LIMIT ?
                """, arguments: StatementArguments(arguments))
                .map { (docID: $0["doc_id"], page: $0["page"],
                        volUUID: $0["vol_uuid"], relPath: $0["rel_path"],
                        conf: $0["conf"] as Double?) }
        }
    }

    /// Ancien point d'entrée, conservé pour les appelants qui raisonnent encore
    /// en « sous tel seuil ». Il rend désormais les pages DOUTEUSES seules : les
    /// pages sans aucune ligne se demandent par `ocrPagesToRevisit(.noLines:)`.
    public func lowConfidencePages(below threshold: Double, limit: Int) throws
        -> [(docID: Int64, page: Int, volUUID: String, relPath: String, conf: Double?)] {
        try ocrPagesToRevisit(.doubtful, below: threshold, limit: limit)
    }

    public func completeOCR(docID: Int64, page: Int, result: OCRPage) throws {
        // Même borne que `replacePages` : le canal externe (`fouine ocr import`,
        // annexe B) n'a AUCUN privilège, numéro de page compris (audit S2).
        try Self.checkPageBound(docID: docID, page: page, what: "OCR")
        let layout = try OCRLayoutCodec.encode(result.lines)
        let text = result.text
        let nchars = text.count

        try writeLocked { db in
            // UNE transaction PAR PAGE (§6.3) ; suppression PAR ROWID EXACT.
            let rowid = Schema.ftsRowID(docID: docID, page: page)
            try db.execute(sql: "DELETE FROM page_fts WHERE rowid = ?",
                           arguments: [rowid])
            // Texte remplacé par l'OCR : toutes les fenêtres de la page sont
            // périmées, sentinelle comprise (schéma v5).
            let vecRange = Schema.vecRowIDRange(pageRowID: rowid)
            try db.execute(sql: "DELETE FROM page_vec WHERE rowid BETWEEN ? AND ?",
                           arguments: [vecRange.lowerBound, vecRange.upperBound])
            if nchars >= Self.minIndexedCharacters {
                try db.execute(sql: """
                    INSERT INTO page_fts(rowid, body, doc_id, page) VALUES (?,?,?,?)
                    """, arguments: [rowid, text, docID, page])
                // Relecture de langue (PERSP-5) : un document scanné dont la langue
                // avait été posée à « und » (ou vide) redevient candidat au rattrapage
                // dès qu'une page reçoit du texte OCR.
                try Self.resetLanguageIfUndetermined(db, docID: docID)
            }
            // src = ocrAccurate (2) pour TOUTE page OCR, quel que soit le niveau
            // demandé au moteur (D1), et le canal externe n'a aucun privilège
            // (annexe B).
            try db.execute(sql: """
                INSERT INTO page_src(doc_id, page, src, nchars, engine, engine_rev, conf)
                VALUES (?,?,?,?,?,?,?)
                ON CONFLICT(doc_id, page) DO UPDATE
                  SET src = excluded.src, nchars = excluded.nchars,
                      engine = excluded.engine, engine_rev = excluded.engine_rev,
                      conf = excluded.conf
                """,
                arguments: [docID, page, PageSource.ocrAccurate.rawValue,
                            nchars >= Self.minIndexedCharacters ? nchars : 0,
                            result.engine.rawValue, result.engineRev,
                            result.meanConfidence])
            try db.execute(sql: """
                INSERT INTO ocr_layout(rowid, blob) VALUES (?,?)
                ON CONFLICT(rowid) DO UPDATE SET blob = excluded.blob
                """, arguments: [rowid, layout])
            try db.execute(sql: "DELETE FROM ocr_queue WHERE doc_id = ? AND page = ?",
                           arguments: [docID, page])

            let remaining = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM ocr_queue WHERE doc_id = ?",
                arguments: [docID]) ?? 0
            // `indexed_at` SUIT L'OCR (lot INT-S1). La colonne ne bougeait
            // qu'à l'extraction : un document scanné gardait donc la date du
            // jour où l'on avait constaté qu'il était vide, et tout ce qui se
            // demande « qu'est-ce qui a changé depuis ? » — la remise à
            // Spotlight — passait à côté du seul texte qu'il aura jamais.
            try db.execute(sql: """
                UPDATE docs SET ocr_state = ?, indexed_at = ? WHERE id = ?
                """,
                           arguments: [(remaining == 0 ? OCRState.done
                                                       : OCRState.partial).rawValue,
                                       Date().timeIntervalSince1970, docID])
        }
    }

    public func failOCR(docID: Int64, page: Int) throws {
        try writeLocked { db in
            try db.execute(sql: """
                UPDATE ocr_queue SET attempts = attempts + 1
                WHERE doc_id = ? AND page = ?
                """, arguments: [docID, page])
            let attempts = try Int.fetchOne(
                db, sql: "SELECT attempts FROM ocr_queue WHERE doc_id = ? AND page = ?",
                arguments: [docID, page]) ?? 0
            if attempts >= 3 {
                try db.execute(
                    sql: "DELETE FROM ocr_queue WHERE doc_id = ? AND page = ?",
                    arguments: [docID, page])
                try db.execute(sql: "UPDATE docs SET err = ? WHERE id = ?",
                               arguments: ["OCR gave up after 3 attempts "
                                           + "(page \(page))", docID])
            }
            let remaining = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM ocr_queue WHERE doc_id = ?",
                arguments: [docID]) ?? 0
            let err = try String.fetchOne(
                db, sql: "SELECT err FROM docs WHERE id = ?", arguments: [docID])
            if remaining == 0, err != nil {
                try db.execute(sql: "UPDATE docs SET ocr_state = ? WHERE id = ?",
                               arguments: [OCRState.failed.rawValue, docID])
            }
        }
    }

    // MARK: - Statistiques et vocabulaire

    public func stats() throws -> [String: Int] {
        var out = try read { db -> [String: Int] in
            func count(_ sql: String, _ args: StatementArguments = []) throws -> Int {
                try Int.fetchOne(db, sql: sql, arguments: args) ?? 0
            }
            var s: [String: Int] = [:]
            s["docs_total"]     = try count("SELECT count(*) FROM docs")
            s["docs_discovered"] = try count(
                "SELECT count(*) FROM docs WHERE state = ?",
                [DocState.discovered.rawValue])
            s["docs_extracted"] = try count(
                "SELECT count(*) FROM docs WHERE state = ?", [DocState.extracted.rawValue])
            s["docs_failed"]    = try count(
                "SELECT count(*) FROM docs WHERE state = ?", [DocState.failed.rawValue])
            s["docs_skipped"]   = try count(
                "SELECT count(*) FROM docs WHERE state = ?", [DocState.skipped.rawValue])
            // `count(*) FROM page_fts` était un BALAYAGE COMPLET de la table
            // de contenu FTS5 : mesuré à 16-45 s sur 1,1 Gio (390 114 pages,
            // `EXPLAIN QUERY PLAN` : « SCAN page_fts VIRTUAL TABLE INDEX 0 »),
            // c'est-à-dire 162× le coût du même compte sur la table d'ombre
            // `page_fts_docsize` (0,28 s). `fouine status` coûtait 24 s, et
            // l'app faisait tourner ce balayage EN BOUCLE pendant toute une
            // passe d'OCR pour lire `ocr_queue_len` (audit C2-03).
            //
            // Lire une table d'ombre fts5 est déjà une convention du dépôt,
            // argumentée et mesurée : `TrigramExpander.swift` lit
            // `vocab_tri_content` pour la même raison. Équivalence vérifiée par
            // C2 sur base jetable à travers une suppression par rowid, un
            // `optimize` et une réinsertion (28/28 → 25/25 → 25/25 → 26/26).
            //
            // RÉSERVE À NE PAS PERDRE : `_docsize` n'existe que tant que
            // `page_fts` n'est pas déclarée `columnsize=0`. C'est le cas
            // (`Schema.swift`), et ça ne doit pas changer sans changer cette
            // ligne — `StoreTests` le vérifie.
            s["pages_indexed"]  = try count("SELECT count(*) FROM page_fts_docsize")
            s["pages_native"]   = try count(
                "SELECT count(*) FROM page_src WHERE src = 0")
            s["pages_ocr_accurate"] = try count(
                "SELECT count(*) FROM page_src WHERE src = 2")
            // DEUX populations, pas une (audit A6) : `conf = 0` est la sentinelle
            // « aucune ligne reconnue » posée par le moteur, pas une confiance
            // faible. Mélangées, elles rendaient `pages_ocr_low_conf` illisible —
            // il ne comptait QUE des pages blanches. Pages SCANNÉES seulement
            // (IX2) : une transcription porte `conf` NULL et passait pour une
            // page sans ligne — voir `scannedSourceList`.
            s["pages_ocr_low_conf"] = try count(
                "SELECT count(*) FROM page_src "
                + "WHERE src IN (\(Self.scannedSourceList)) AND conf > 0 AND conf < ?",
                [Self.doubtfulConfidenceThreshold])
            s["pages_ocr_no_lines"] = try count(
                "SELECT count(*) FROM page_src "
                + "WHERE src IN (\(Self.scannedSourceList)) AND (conf IS NULL OR conf <= 0)")
            s["ocr_queue_len"]  = try count("SELECT count(*) FROM ocr_queue")
            // TROIS nombres depuis le fenêtrage (schéma v5), et pas un :
            // `pages_vec` reste ce qu'il a toujours été — des PAGES que le
            // canal sémantique voit —, `pages_vec_complete` compte celles dont
            // toutes les fenêtres sont produites (sentinelle posée), et
            // `vectors_vec` compte les lignes, c'est-à-dire les fenêtres.
            // UN SEUL BALAYAGE POUR LES TROIS (lot MN1). `page_vec` n'a pas
            // d'index secondaire — `SCAN page_vec`, vérifié par EXPLAIN QUERY
            // PLAN —, et un balayage y coûte cher parce que chaque ligne porte
            // un blob de 384 octets : 820 458 lignes, ~315 Mo de table.
            // Mesuré le 14/09/2026 sur une copie de la base de production
            // (820 458 fenêtres), cache chaud, trois passes : **502 ms** en
            // trois requêtes (182 + 183 + 137), **258 ms** en une. C'est le
            // poste dominant de `fouine status`, qui tient en 672 ms à chaud et
            // 3,2 s à froid. Les trois nombres et leurs clés sont inchangés.
            //
            // Les comptes de `page_src` ci-dessus, EUX, restent séparés : ils
            // passent par `idx_page_src_conf` (index couvrant), soit 22 ms pour
            // les quatre, quand le même regroupement en un balayage coûtait
            // 167 ms — sept fois pire. On ne regroupe que ce qui balaie déjà.
            // `coalesce` parce que `sum()` rend NULL sur une table VIDE, là où
            // `count()` rendait 0 : une base neuve doit lire « 0 vecteur ».
            let windows = try Row.fetchOne(db, sql: """
                SELECT count(*) AS n,
                       coalesce(sum(rowid % \(Schema.vecChunksPerPage) = 0), 0)
                           AS pages,
                       coalesce(sum(rowid % \(Schema.vecChunksPerPage)
                           = \(Schema.vecWindowMax - 1)), 0) AS complete
                  FROM page_vec
                """)
            s["pages_vec"] = windows?["pages"] ?? 0
            s["pages_vec_complete"] = windows?["complete"] ?? 0
            s["vectors_vec"] = windows?["n"] ?? 0
            return s
        }
        out["db_bytes"] = databaseBytes()
        return out
    }

    /// Taille de la base, journal WAL compris.
    public func databaseBytes() -> Int {
        guard let url = databaseURL else { return 0 }
        let fm = FileManager.default
        var total = 0
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let size = attrs[.size] as? NSNumber {
                total += size.intValue
            }
        }
        return total
    }

    public func topVocabulary(limit: Int, minLength: Int) throws -> [String] {
        try read { db in
            try String.fetchAll(db, sql: """
                SELECT term FROM vocab WHERE length(term) >= ?
                ORDER BY cnt DESC LIMIT ?
                """, arguments: [minLength, limit])
        }
    }

    /// À appeler après une passe complète d'indexation (§5.1).
    public func optimize() throws {
        try writeLocked { db in
            try db.execute(sql: "INSERT INTO page_fts(page_fts) VALUES('optimize')")
        }
    }

    // MARK: - Accès brut, réservé aux tests unitaires (@testable)

    func rawInt64s(_ sql: String) throws -> [Int64] {
        try read { db in try Int64.fetchAll(db, sql: sql) }
    }

    func rawDoubles(_ sql: String) throws -> [Double] {
        try read { db in try Double.fetchAll(db, sql: sql) }
    }

    func rawStrings(_ sql: String) throws -> [String] {
        try read { db in try String.fetchAll(db, sql: sql) }
    }

    /// Colonne `detail` de `EXPLAIN QUERY PLAN` — pour vérifier qu'une requête
    /// passe par un index (non-régression du bogue 2).
    func rawPlanDetails(_ sql: String,
                        arguments: StatementArguments = []) throws -> [String] {
        try read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql,
                             arguments: arguments)
                .map { ($0["detail"] as String?) ?? "" }
        }
    }
}
