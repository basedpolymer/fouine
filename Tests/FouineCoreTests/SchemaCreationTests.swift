// SchemaCreationTests.swift — création du schéma courant, refus de tout autre
// schéma. Propriété : A-Recette. Lot RC1 du 13/09/2026.
//
// IL N'Y A QU'UN PAS DE MIGRATION, et il est borné (lot SR1) : la v9 devient
// la v10 en perdant deux tables, parce que refuser ces bases aurait obligé
// chaque utilisateur à refaire un index de plusieurs gigaoctets pour supprimer
// des lignes dont plus rien ne se sert. Toute autre version reste refusée.
//
// Ce qu'il y a donc à prouver :
//
//   · une base neuve naît au schéma courant, complet et cohérent ;
//   · une base d'un schéma PLUS ANCIEN que le pas de migration est refusée,
//     avec le geste (« delete it and index again »), sans être touchée, et en
//     écriture comme en lecture seule ;
//   · une base d'un schéma PLUS RÉCENT est refusée, avec l'autre geste
//     (« update the fouine binary ») ;
//   · une base de la version qui PRÉCÈDE est migrée : les deux tables partent,
//     les documents, leur texte et la recherche ne bougent pas ;
//   · la création prend le verrou nommé, l'ouverture d'une base à jour non ;
//   · rouvrir est idempotent — la seconde ouverture ne recrée rien ;
//   · déplacer un document n'efface ni ses pages, ni sa file ;
//   · et la recherche répond sur la base ainsi créée.
//
// Les bases « d'un autre schéma » sont fabriquées ICI, au sqlite3 du système :
// une table `meta` et une ligne `schema_version` suffisent à décrire ce que le
// Store regarde. Aucune fixture à versionner.

import Foundation
import XCTest
@testable import FouineCore

final class SchemaCreationTests: XCTestCase {

    private var scratch: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-schema-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
        databaseURL = scratch.appendingPathComponent("fouine.db")
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - Plomberie sqlite3

    /// Exécute du SQL avec le sqlite3 du SYSTÈME — le même moteur que celui que
    /// GRDB lie (FTS5 3.43.2 mesuré, §2.2). C'est ce qui permet de fabriquer
    /// une base qu'aucune API du produit ne saurait produire : celle d'un
    /// schéma périmé.
    @discardableResult
    private static func sqlite(_ statements: String, on database: URL,
                               readOnly: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [readOnly ? "file:\(database.path)?mode=ro" : database.path,
                             statements]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(),
                             as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SchemaCreation", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "sqlite3 a refusé : \(message)"])
        }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sql(_ statement: String) throws -> String {
        try Self.sqlite(statement, on: databaseURL, readOnly: true)
    }

    private func count(_ table: String) throws -> Int {
        Int(try sql("SELECT count(*) FROM \(table)")) ?? -1
    }

    /// Une base MINIMALE portant `schema_version = version` — tout ce que le
    /// Store regarde avant de décider d'ouvrir, de créer ou de refuser.
    private func writeVersionedDatabase(_ version: Int) throws {
        try Self.sqlite("""
            CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);
            INSERT INTO meta(k, v) VALUES ('schema_version', '\(version)');
            """, on: databaseURL)
    }

    private func open(lockTimeout: TimeInterval = 5) throws -> GRDBStore {
        let store = GRDBStore(lockTimeout: lockTimeout)
        try store.open(at: databaseURL)
        return store
    }

    private func addDoc(_ store: GRDBStore, relPath: String) throws -> Int64 {
        try store.upsertDoc(DocRecord(
            volUUID: "VOL-J1", relPath: relPath, ext: "pdf",
            topFolder: "Livres", size: 1_000, mtime: 1_700_000_000))
    }

    // MARK: - Une base neuve naît au schéma courant

    func testAFreshDatabaseIsCreatedAtTheCurrentSchema() throws {
        _ = try open()

        XCTAssertEqual(try sql("SELECT v FROM meta WHERE k='schema_version'"),
                       String(Schema.version))
        XCTAssertEqual(Schema.version, 10,
                       "changer `Schema.version` rend TOUTE base plus ancienne "
                       + "que la v9 illisible : l'utilisateur devra refaire "
                       + "son index")
        XCTAssertEqual(try sql("SELECT v FROM meta WHERE k='fouine_version'"),
                       GRDBStore.fouineVersion)
        XCTAssertFalse(try sql("SELECT v FROM meta WHERE k='created_at'").isEmpty)
        XCTAssertEqual(try sql("PRAGMA integrity_check"), "ok")

        // Toutes les tables du schéma, d'un coup : `Schema.ddl` les pose
        // ensemble, il n'y a pas d'ordre d'arrivée.
        let expected = ["agent_status", "docs", "docs_fts", "meta", "ocr_layout",
                        "ocr_queue", "page_fts", "page_src", "roots",
                        "settings", "vocab", "vocab_seen", "vocab_tri",
                        "volumes"]
        for table in expected {
            XCTAssertEqual(
                try sql("SELECT count(*) FROM sqlite_master WHERE name='\(table)'"),
                "1", "« \(table) » manque dans une base neuve")
        }

        // `ocr_layout` est à la forme du rowid structuré (audit A4) : c'est la
        // seule forme qu'il ait.
        XCTAssertEqual(
            try sql("SELECT name FROM pragma_table_info('ocr_layout')")
                .split(separator: "\n").map(String.init),
            ["rowid", "blob"])

        // `docs.inode` et son index naissent avec la base : rien n'est ajouté
        // après coup.
        XCTAssertEqual(
            try sql("SELECT count(*) FROM pragma_table_info('docs') "
                    + "WHERE name='inode'"), "1")
        XCTAssertEqual(
            try sql("SELECT count(*) FROM sqlite_master "
                    + "WHERE type='index' AND name='idx_docs_inode'"), "1")

        // Les tables naissent VIDES : la création ne fabrique aucune donnée.
        for table in ["docs", "docs_fts", "settings", "agent_status"] {
            XCTAssertEqual(try count(table), 0, "« \(table) » doit naître vide")
        }
    }

    /// Le produit se sert de la base qu'il vient de créer : réglages écrits et
    /// relus, état d'agent publié. Une table présente mais inutilisable ne
    /// vaudrait rien.
    func testAFreshDatabaseIsImmediatelyUsable() throws {
        let store = try open()

        try store.writeSetting("ocr.jobs", "2")
        XCTAssertEqual(try store.settingsRows()["ocr.jobs"], "2")

        let status = AgentStatusRecord(phase: .ocr, detail: "scan.pdf",
                                       done: 1, total: 2,
                                       startedAt: Date(), updatedAt: Date())
        try store.writeAgentStatus(status)
        let read = try XCTUnwrap(store.agentStatus())
        XCTAssertEqual(read.phase, .ocr)
        XCTAssertEqual(read.done, 1)
        XCTAssertEqual(read.total, 2)
    }

    // MARK: - Refus des autres schémas

    /// Une base d'un schéma plus ancien n'est pas rattrapée. Le message doit
    /// porter le seul geste possible — la refaire —, et surtout pas promettre
    /// une migration qui n'existe pas.
    func testADatabaseFromAnOlderSchemaIsRefusedAndLeftUntouched() throws {
        try writeVersionedDatabase(4)

        let store = GRDBStore()
        XCTAssertThrowsError(try store.open(at: databaseURL)) {
            guard case FouineError.databaseFailure(let message) = $0 else {
                return XCTFail("attendu .databaseFailure, obtenu \($0)")
            }
            XCTAssertTrue(message.contains("predates 1.0.0"), message)
            XCTAssertTrue(message.contains("schema v4"), message)
            XCTAssertTrue(message.contains("delete it and index again"), message)
            XCTAssertFalse(message.lowercased().contains("migrate"),
                           "le message ne doit plus promettre de migration : \(message)")
        }

        // La base refusée n'est pas touchée : ni complétée, ni vidée.
        XCTAssertEqual(try sql("SELECT v FROM meta WHERE k='schema_version'"), "4")
        XCTAssertEqual(try sql("SELECT count(*) FROM sqlite_master WHERE name='docs'"),
                       "0", "aucune table du schéma courant ne doit apparaître")
    }

    /// TOUTES les versions antérieures sont refusées, SAUF celle qui précède
    /// immédiatement — le seul pas de migration du produit (lot SR1).
    func testEveryOlderSchemaIsRefused() throws {
        for version in 1..<Schema.previousVersion {
            let url = scratch.appendingPathComponent("v\(version).db")
            try Self.sqlite("""
                CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);
                INSERT INTO meta(k, v) VALUES ('schema_version', '\(version)');
                """, on: url)
            XCTAssertThrowsError(try GRDBStore().open(at: url),
                                 "le schéma v\(version) devrait être refusé")
        }
    }

    /// Une base plus RÉCENTE reste refusée, et avec l'autre geste : mettre le
    /// binaire à jour. Confondre les deux messages ferait détruire un index
    /// qu'une simple mise à jour suffisait à ouvrir.
    func testADatabaseFromANewerSchemaIsRefusedWithTheUpdateGesture() throws {
        try writeVersionedDatabase(Schema.version + 1)

        XCTAssertThrowsError(try GRDBStore().open(at: databaseURL)) {
            guard case FouineError.databaseFailure(let message) = $0 else {
                return XCTFail("attendu .databaseFailure, obtenu \($0)")
            }
            XCTAssertTrue(message.contains("newer version"), message)
            XCTAssertTrue(message.contains("update the fouine binary"), message)
            XCTAssertFalse(message.contains("delete it"),
                           "on ne fait pas détruire un index qu'une mise à jour "
                           + "suffit à ouvrir : \(message)")
        }
    }

    /// La lecture seule (le serveur MCP) refuse exactement de la même façon, et
    /// avec la MÊME phrase : les deux ouvertures partagent `schemaMismatch`.
    func testReadOnlyOpenRefusesAnOlderSchemaWithTheSameSentence() throws {
        try writeVersionedDatabase(4)

        XCTAssertThrowsError(try GRDBStore().openReadOnly(at: databaseURL)) {
            guard case FouineError.databaseFailure(let message) = $0 else {
                return XCTFail("attendu .databaseFailure, obtenu \($0)")
            }
            XCTAssertTrue(message.contains(GRDBStore.schemaMismatch(found: 4)),
                          message)
        }
    }

    /// LE changement du lot RC1, dit explicitement : une base v5 — celle qu'une
    /// chaîne de migrations rattrapait jusqu'ici — s'entend désormais dire de
    /// REFAIRE L'INDEX, et non d'attendre son premier écrivain. La phrase ne
    /// doit plus promettre de mise à jour : il n'y en a plus.
    func testAVersionFiveDatabaseIsAskedToBeIndexedAgain() throws {
        try writeVersionedDatabase(5)

        for open in [{ try GRDBStore().open(at: self.databaseURL) },
                     { try GRDBStore().openReadOnly(at: self.databaseURL) }] {
            XCTAssertThrowsError(try open()) {
                guard case FouineError.databaseFailure(let message) = $0 else {
                    return XCTFail("attendu .databaseFailure, obtenu \($0)")
                }
                XCTAssertTrue(message.contains("delete it and index again"), message)
                XCTAssertFalse(message.contains("one-time upgrade"), message)
            }
        }
        XCTAssertEqual(try sql("SELECT v FROM meta WHERE k='schema_version'"), "5",
                       "une base refusée n'est pas touchée")
    }

    // MARK: - Déplacer un document n'efface rien (constat A3-02)

    /// `relocateDocs` change le CHEMIN et rien d'autre. Les pages, la couche OCR, la file d'attente et les vecteurs sont
    /// tous indexés par `doc_id` — ils survivent parce que le `doc_id` survit.
    func testRelocatingADocumentKeepsPagesOCRQueueAndVectors() throws {
        let store = try open()
        let docID = try addDoc(store, relPath: "Users/fixture/Livres/M2SU/cours.pdf")
        try store.replacePages(docID: docID, pages: [
            PageText(page: 1, text: "tellurium et mesure du rendement",
                     source: .ocrAccurate),
        ])
        // Au moins `minIndexedCharacters` : sous 20 caractères, une page
        // OCRisée n'entre pas dans page_fts et la recherche ne prouverait rien.
        try store.completeOCR(docID: docID, page: 1,
                              result: OCRPage(text: "tellurium et mesure du rendement",
                                              lines: [OCRLine(text: "tellurium",
                                                              x: 0.1, y: 0.8,
                                                              w: 0.6, h: 0.02,
                                                              confidence: 0.9)],
                                              level: .accurate, seconds: 0.1,
                                              engine: .vision,
                                              engineRev: "vision-rev3",
                                              meanConfidence: 0.9))
        try store.enqueueOCR(docID: docID, pages: [2], priority: 1)
        let before = (src: try count("page_src"), layout: try count("ocr_layout"),
                      queue: try count("ocr_queue"))
        XCTAssertEqual(before.layout, 1)

        try store.relocateDocs([DocRelocation(
            id: docID, relPath: "Users/fixture/Livres/M2 Sorbonne/cours.pdf",
            topFolder: "Livres", ext: "pdf", inode: 424_242)])

        XCTAssertEqual(try store.docRow(id: docID)?.record.relPath,
                       "Users/fixture/Livres/M2 Sorbonne/cours.pdf")
        XCTAssertEqual(try sql("SELECT inode FROM docs WHERE id = \(docID)"),
                       "424242")
        XCTAssertEqual(try count("page_src"), before.src)
        XCTAssertEqual(try count("ocr_layout"), before.layout)
        XCTAssertEqual(try count("ocr_queue"), before.queue)
        XCTAssertEqual(try count("docs"), 1, "aucun document neuf")

        // Et le texte se retrouve toujours, au nouveau chemin.
        let hits = try store.search(
            try QueryParser.searchQuery("tellurium", limit: 20, inDocIDs: [],
                                        fuzzy: .off, fuzzyScope: .ocrOnly))
        XCTAssertEqual(hits.hits.first?.docID, docID)
    }

    /// Un lot de déplacements passe par un état intermédiaire en collision dès
    /// qu'un dossier est renommé en profondeur (`a/x -> b/x` pendant que
    /// `a -> b`). La contrainte `UNIQUE(vol_uuid, rel_path)` ne doit jamais le
    /// voir : c'est ce que la passe de garage garantit.
    func testASwapOfTwoPathsIsOneTransactionWithoutUniqueViolation() throws {
        let store = try open()
        let first = try addDoc(store, relPath: "Livres/a.pdf")
        let second = try addDoc(store, relPath: "Livres/b.pdf")

        try store.relocateDocs([
            DocRelocation(id: first, relPath: "Livres/b.pdf", topFolder: "Livres",
                          ext: "pdf", inode: 1),
            DocRelocation(id: second, relPath: "Livres/a.pdf", topFolder: "Livres",
                          ext: "pdf", inode: 2),
        ])

        XCTAssertEqual(try store.docRow(id: first)?.record.relPath, "Livres/b.pdf")
        XCTAssertEqual(try store.docRow(id: second)?.record.relPath, "Livres/a.pdf")
    }

    // MARK: - Verrou nommé (audit D2-10)

    /// La CRÉATION écrit : elle passe donc par le verrou nommé, et échoue en
    /// « base verrouillée » — l'enregistrement `fouine-lock-busy`, qui nomme le
    /// détenteur — plutôt qu'en `SQLITE_BUSY` au bout de cinq secondes.
    func testCreatingWaitsForTheNamedLock() throws {
        let holder = ExclusiveLock(
            path: FouinePaths.lockURL(for: databaseURL).path)
        try holder.acquire()
        defer { holder.release() }

        // 0,3 s et non les 5 s de production : le refus est le même, seule
        // l'attente change (lot I2).
        XCTAssertThrowsError(try open(lockTimeout: 0.3)) {
            guard case FouineError.databaseFailure(let message) = $0 else {
                return XCTFail("attendu .databaseFailure, obtenu \($0)")
            }
            XCTAssertTrue(message.hasPrefix(WriteLock.busyToken),
                          "la création doit échouer sur le verrou NOMMÉ : \(message)")
        }
        XCTAssertEqual(try sql("SELECT count(*) FROM sqlite_master WHERE name='docs'"),
                       "0", "rien n'a été créé")

        // Le verrou rendu, la même ouverture aboutit.
        holder.release()
        _ = try open()
        XCTAssertEqual(try sql("SELECT v FROM meta WHERE k='schema_version'"),
                       String(Schema.version))
    }

    /// Contre-épreuve indispensable : une base DÉJÀ à jour s'ouvre sans prendre
    /// le verrou — sinon `fouine search`, `status` et `doctor` échoueraient dès
    /// qu'une indexation est en cours, ce qu'ils ne doivent jamais faire (§5.1).
    func testOpeningAnUpToDateDatabaseTakesNoLock() throws {
        _ = try open()

        let holder = ExclusiveLock(
            path: FouinePaths.lockURL(for: databaseURL).path)
        try holder.acquire()
        defer { holder.release() }

        XCTAssertNoThrow(try GRDBStore().open(at: databaseURL),
                         "une ouverture sans création ne doit prendre aucun verrou")
    }

    // MARK: - Réouverture

    /// Rouvrir ne recrée rien : `created_at` ne bouge pas, les données restent.
    func testReopeningIsIdempotent() throws {
        let docID: Int64
        do {
            let first = try open()
            docID = try addDoc(first, relPath: "Users/fixture/Livres/traite.pdf")
            try first.replacePages(docID: docID, pages: [
                PageText(page: 1, text: "addition électrophile de Markovnikov",
                         source: .native),
            ])
        }
        let createdAt = try sql("SELECT v FROM meta WHERE k='created_at'")

        let second = try open()
        XCTAssertEqual(try sql("SELECT v FROM meta WHERE k='created_at'"), createdAt,
                       "une réouverture ne doit pas réécrire la date de création")
        XCTAssertEqual(try sql("SELECT v FROM meta WHERE k='schema_version'"),
                       String(Schema.version))
        XCTAssertEqual(try count("docs"), 1)
        XCTAssertEqual(try second.docRow(id: docID)?.record.relPath,
                       "Users/fixture/Livres/traite.pdf")
        XCTAssertEqual(try sql("PRAGMA integrity_check"), "ok")
    }

    // MARK: - Le pas v9 → v10 (lot SR1)

    /// La DDL que la v9 portait EN PLUS de la v10 : les deux tables qui ne
    /// tenaient que les vecteurs. Recopiée ici — et nulle part dans le
    /// produit — pour qu'une base v9 se fabrique sans ressortir l'ancien
    /// `Schema.ddl` d'un dépôt d'archives.
    private static let v9ExtraDDL = """
    CREATE TABLE page_vec(rowid INTEGER PRIMARY KEY, vec BLOB NOT NULL);
    CREATE TABLE vec_meta(k TEXT PRIMARY KEY, v TEXT NOT NULL) WITHOUT ROWID;
    INSERT INTO vec_meta(k, v) VALUES ('win_chars','1400'), ('win_max','3'),
      ('model_id','multilingual-e5-small'), ('dim','384');
    INSERT INTO page_vec(rowid, vec) VALUES (8000080, x'0607'), (8000082, x'');
    UPDATE meta SET v = '9' WHERE k = 'schema_version';
    """

    /// Une base v9 PLAUSIBLE : le schéma courant, plus les deux tables de la
    /// v9, plus un document indexé et cherchable.
    private func makeV9Database() throws -> (docID: Int64, hits: [String]) {
        let store = try open()
        let docID = try addDoc(store, relPath: "Users/fixture/Livres/traite.pdf")
        try store.replacePages(docID: docID, pages: [
            PageText(page: 1, text: "addition électrophile selon Markovnikov",
                     source: .native),
            PageText(page: 2, text: "catalyse heterogene et surfaces",
                     source: .native),
        ])
        let before = try store.search(try QueryParser.searchQuery("catalyse"),
                                      excludingDocsMatching: nil)
        store.releaseWriteLock()
        try Self.sqlite(Self.v9ExtraDDL, on: databaseURL)
        return (docID, before.hits.map { "\($0.docID):\($0.page)" })
    }

    /// LE TEST QUI COMPTE POUR L'UTILISATEUR : son index s'ouvre, les deux
    /// tables sont parties, et sa recherche rend EXACTEMENT ce qu'elle rendait.
    func testAV9DatabaseIsMigratedWithoutLosingAnything() throws {
        let (docID, hitsBefore) = try makeV9Database()
        XCTAssertEqual(try sql("SELECT v FROM meta WHERE k='schema_version'"), "9")
        XCTAssertEqual(try count("page_vec"), 2)

        let store = try open()
        XCTAssertEqual(try sql("SELECT v FROM meta WHERE k='schema_version'"),
                       String(Schema.version))
        for table in ["page_vec", "vec_meta"] {
            XCTAssertEqual(
                try sql("SELECT count(*) FROM sqlite_master WHERE name='\(table)'"),
                "0", "« \(table) » devait partir")
        }
        // Ce qui porte les documents ne bouge PAS : c'est tout l'intérêt du pas
        // de migration plutôt que d'un refus.
        XCTAssertEqual(try store.docRow(id: docID)?.record.relPath,
                       "Users/fixture/Livres/traite.pdf")
        XCTAssertEqual(try store.indexedPageCount(), 2)
        let after = try store.search(try QueryParser.searchQuery("catalyse"),
                                     excludingDocsMatching: nil)
        XCTAssertEqual(after.hits.map { "\($0.docID):\($0.page)" }, hitsBefore)
        XCTAssertFalse(hitsBefore.isEmpty, "la recherche doit avoir trouvé quelque chose")
        store.releaseWriteLock()
    }

    /// Le pas est IDEMPOTENT : une coupure de courant laisse une base qui se
    /// dit encore v9 (la version est écrite en dernier, dans la même
    /// transaction), et le lancement suivant le rejoue sur des tables déjà
    /// parties.
    func testTheMigrationCanBeReplayed() throws {
        _ = try makeV9Database()
        let first = try open()
        first.releaseWriteLock()
        // On remet la base en v9 SANS remettre les tables : exactement l'état
        // qu'un `DROP` déjà joué laisserait derrière lui.
        try Self.sqlite("UPDATE meta SET v = '9' WHERE k = 'schema_version';",
                        on: databaseURL)
        let second = try open()
        XCTAssertEqual(try sql("SELECT v FROM meta WHERE k='schema_version'"),
                       String(Schema.version))
        second.releaseWriteLock()
    }

    /// La LECTURE SEULE ne peut pas migrer : elle refuse en nommant le geste
    /// qui le fait, et surtout PAS en envoyant refaire l'index.
    func testAReadOnlyOpenOfAV9DatabaseNamesTheGestureThatMigrates() throws {
        _ = try makeV9Database()
        XCTAssertThrowsError(try GRDBStore().openReadOnly(at: databaseURL)) {
            guard case FouineError.databaseFailure(let message) = $0 else {
                return XCTFail("attendu .databaseFailure, obtenu \($0)")
            }
            XCTAssertTrue(message.contains(GRDBStore.schemaNeedsUpgrade), message)
            XCTAssertFalse(message.contains("delete it"),
                           "un index parfaitement bon ne se refait pas : \(message)")
        }
    }

    // MARK: - Le test qui compte pour l'utilisateur

    /// Sur la base que la création vient de poser, la recherche répond : texte
    /// natif, texte OCR avec la bonne provenance, et repli d'accents.
    func testSearchAnswersOnAFreshlyCreatedDatabase() throws {
        let store = try open()
        let native = try addDoc(store, relPath: "Users/fixture/Livres/traite.pdf")
        try store.replacePages(docID: native, pages: [
            PageText(page: 1, text: "addition électrophile selon Markovnikov",
                     source: .native),
        ])
        let scanned = try addDoc(store, relPath: "Users/fixture/Livres/scan.pdf")
        try store.replacePages(docID: scanned, pages: [
            PageText(page: 1, text: "TELLURIUM mesure du rendement",
                     source: .ocrAccurate),
        ])

        let lexical = try store.search(
            try QueryParser.searchQuery("markovnikov", limit: 20, inDocIDs: [],
                                        fuzzy: .off, fuzzyScope: .ocrOnly))
        XCTAssertEqual(lexical.hits.count, 1, "\(lexical.hits)")
        XCTAssertEqual(lexical.hits[0].docID, native)
        XCTAssertEqual(lexical.hits[0].source, .native)

        let ocr = try store.search(
            try QueryParser.searchQuery("tellurium", limit: 20, inDocIDs: [],
                                        fuzzy: .off, fuzzyScope: .ocrOnly))
        XCTAssertEqual(ocr.hits.count, 1, "\(ocr.hits)")
        XCTAssertEqual(ocr.hits[0].docID, scanned)
        XCTAssertEqual(ocr.hits[0].source, .ocrAccurate)

        // Le repli d'accents du tokenizer : « électrophile » se trouve aussi
        // sans ses accents, et réciproquement.
        let folded = try store.search(
            try QueryParser.searchQuery("electrophile", limit: 20, inDocIDs: [],
                                        fuzzy: .off, fuzzyScope: .ocrOnly))
        XCTAssertEqual(folded.hits.count, 1, "\(folded.hits)")
    }
}
