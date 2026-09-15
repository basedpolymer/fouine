// SettingsTests.swift — réglages typés, override d'environnement, schéma v4.
// SPEC §10, audit U2 / F7. Propriété : A-Core.
//
// Ce que ces tests protègent, dans l'ordre d'importance :
//   1. les DÉFAUTS sont exactement ce que le code faisait avant le palier 2.3 —
//      une base neuve ne doit pas se comporter autrement qu'avant ;
//   2. la PRIORITÉ des trois sources (environnement > base > défaut), qui est ce
//      qui permet de dépanner un agent sans base accessible ;
//   3. la VALIDATION, y compris le cas d'une valeur illisible déjà en base :
//      elle ne doit jamais faire tomber un appelant.

import Foundation
import XCTest
@testable import FouineCore

final class SettingsTests: XCTestCase {

    // MARK: - Défauts

    /// Les valeurs par défaut sont celles du code d'AVANT ce palier. Chaque
    /// nombre ici est repris d'un site précis, cité en commentaire : si l'un
    /// change, ce test doit le dire.
    func testDefaultsMatchThePreviousHardCodedValues() {
        let snapshot = SettingsSnapshot.environmentOnly([:])
        // VisionOCREngine.defaultLanguages
        XCTAssertEqual(snapshot.ocrLanguages, ["fr-FR", "en-US"])
        // OCRRun.defaultJobs
        XCTAssertEqual(snapshot.ocrJobs, 4)
        // CommandsIndex : `--jobs` valait 4 ; IndexingService : `let jobs = 4`
        XCTAssertEqual(snapshot.extractJobs, 4)
        // AgentPaths.extractJobs : 2, « il partage la machine avec vous »
        XCTAssertEqual(snapshot.agentExtractJobs, 2)
        // AgentPaths.ocrBudgetMinutes
        XCTAssertEqual(snapshot.agentOCRBudgetMinutes, 10)
        // AgentPaths.pollSeconds
        XCTAssertEqual(snapshot.agentPollSeconds, 60)
        // Les six conditions du §5.7 étaient toutes en dur, donc armées.
        XCTAssertTrue(snapshot.agentRequireAC)
        XCTAssertTrue(snapshot.agentPauseOnLowPower)
        XCTAssertTrue(snapshot.agentPauseOnThermal)
        // Aucune racine épinglée : le paramètre d'OCRPriority n'avait jamais
        // de source (audit F4).
        XCTAssertTrue(snapshot.pinnedRoots.isEmpty)
        // Aucune notification n'existait (audit F7, `grep UNUserNotification` : 0).
        XCTAssertFalse(snapshot.notifyOnQueueDrained)

        for entry in snapshot.table() {
            XCTAssertEqual(entry.source, .fallback,
                           "\(entry.spec.key) devrait venir du défaut")
        }
    }

    /// La préparation de la recherche par le sens en arrière-plan (lot AG1,
    /// PR-21) est ÉTEINTE par défaut depuis la 1.0.1 (DF1) : elle se demande,
    /// par la case ou par le bouton « Préparer… » de la barre latérale.
    func testMeaningIsNotPreparedInTheBackgroundByDefault() {
        let snapshot = SettingsSnapshot.environmentOnly([:])
        XCTAssertFalse(snapshot.agentPrepareMeaning)
        XCTAssertEqual(snapshot.agentEmbedBudgetMinutes, 10)
        XCTAssertEqual(snapshot.agentLastEmbedBatchAt, 0)
        // La clé d'horodatage est un état interne : elle n'est pas au
        // catalogue (comme `spotlight.synced_at`), et la fenêtre de réglages
        // ne la liste donc pas.
        XCTAssertFalse(SettingKeys.all.contains { $0.key == SettingKeys.agentLastEmbedBatchAt.key })
        XCTAssertTrue(SettingKeys.all.contains { $0.key == SettingKeys.agentPrepareMeaning.key })
        XCTAssertTrue(SettingKeys.all.contains { $0.key == SettingKeys.agentEmbedBudgetMinutes.key })
    }

    /// Les bornes du budget, et la façon dont une valeur hors bornes est
    /// RAMENÉE plutôt que refusée (même règle que le budget d'OCR).
    func testTheEmbedBudgetIsClampedBetweenOneAndTwoHours() throws {
        XCTAssertEqual(try SettingKeys.agentEmbedBudgetMinutes.normalize("0"), "1")
        XCTAssertEqual(try SettingKeys.agentEmbedBudgetMinutes.normalize("999"), "120")
        let snapshot = SettingsSnapshot(rows: ["agent.embedBudgetMinutes": "45"],
                                        environment: [:])
        XCTAssertEqual(snapshot.agentEmbedBudgetMinutes, 45)
        let forced = SettingsSnapshot(
            rows: ["agent.prepareMeaning": "true"],
            environment: ["FOUINE_AGENT_PREPARE_MEANING": "false"])
        XCTAssertFalse(forced.agentPrepareMeaning)
    }

    /// Tout défaut du catalogue doit passer sa propre validation : une faute de
    /// frappe dans `SettingKeys` se verrait ici, pas en production.
    func testEveryFallbackIsItsOwnNormalForm() throws {
        for spec in SettingKeys.all {
            let normalized = try spec.normalize(spec.fallback)
            XCTAssertEqual(normalized, spec.fallback,
                           "défaut non normalisé pour \(spec.key)")
        }
    }

    /// Les clés sont uniques, et les variables d'environnement aussi : deux
    /// réglages qui liraient la même variable seraient indissociables.
    func testCatalogueHasNoDuplicates() {
        let keys = SettingKeys.all.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "clé en double")
        let variables = SettingKeys.all.compactMap(\.environmentVariable)
        XCTAssertEqual(Set(variables).count, variables.count, "variable en double")
    }

    // MARK: - Priorité des trois sources

    func testEnvironmentBeatsDatabaseWhichBeatsFallback() {
        let rows = ["agent.pollSeconds": "120", "ocr.jobs": "2"]
        let base = SettingsSnapshot(rows: rows, environment: [:])
        XCTAssertEqual(base.agentPollSeconds, 120)
        XCTAssertEqual(base.effective(SettingKeys.agentPollSeconds).source, .database)
        XCTAssertEqual(base.ocrJobs, 2)

        // La variable historique reste PRIORITAIRE : c'est ce qui permet de
        // dépanner un agent dont la base dit une bêtise.
        let forced = SettingsSnapshot(
            rows: rows, environment: ["FOUINE_AGENT_POLL_SECONDS": "30"])
        XCTAssertEqual(forced.agentPollSeconds, 30)
        XCTAssertEqual(forced.effective(SettingKeys.agentPollSeconds).source,
                       .environment)
        // … et n'affecte QUE sa clé.
        XCTAssertEqual(forced.ocrJobs, 2)
    }

    /// Une variable VIDE ne compte pas : `FOUINE_AGENT_JOBS=` dans un plist mal
    /// rempli ne doit pas neutraliser le réglage de la fenêtre.
    func testEmptyEnvironmentVariableIsIgnored() {
        let snapshot = SettingsSnapshot(rows: ["agent.extractJobs": "3"],
                                        environment: ["FOUINE_AGENT_JOBS": ""])
        XCTAssertEqual(snapshot.agentExtractJobs, 3)
        XCTAssertEqual(snapshot.effective(SettingKeys.agentExtractJobs).source,
                       .database)
    }

    // MARK: - Validation

    func testIntegersAreClampedNeverRefused() throws {
        // Même règle que JobsCap (audit X1) : on TRONQUE, on ne refuse pas.
        XCTAssertEqual(try SettingKeys.ocrJobs.normalize("99"), "4")
        XCTAssertEqual(try SettingKeys.ocrJobs.normalize("0"), "1")
        XCTAssertEqual(try SettingKeys.agentPollSeconds.normalize("1"), "5")
        XCTAssertEqual(try SettingKeys.agentPollSeconds.normalize("99999"), "3600")
    }

    func testNonNumericIntegerIsRefusedWithAnActionableMessage() {
        XCTAssertThrowsError(try SettingKeys.ocrJobs.normalize("beaucoup")) { error in
            let refusal = error as? SettingsError
            XCTAssertEqual(refusal?.reason,
                           .notAnInteger(value: "beaucoup", key: "ocr.jobs",
                                         min: 1, max: 4),
                           "le motif typé porte la clé et les bornes")
            let message = refusal?.message ?? ""
            XCTAssertTrue(message.contains("is not an integer"), message)
            XCTAssertTrue(message.contains("ocr.jobs"), message)
            // La phrase donne les bornes : sans elles, l'utilisateur retente au
            // hasard.
            XCTAssertTrue(message.contains("between 1 and 4"), message)
        }
    }

    func testBooleansAcceptTheFrenchAndTheUsualSpellings() throws {
        for raw in ["true", "1", "oui", "VRAI", "on"] {
            XCTAssertEqual(try SettingKeys.agentRequireAC.normalize(raw), "true", raw)
        }
        for raw in ["false", "0", "non", "FAUX", "off"] {
            XCTAssertEqual(try SettingKeys.agentRequireAC.normalize(raw), "false", raw)
        }
        XCTAssertThrowsError(try SettingKeys.agentRequireAC.normalize("peut-être"))
    }

    func testListsAreTrimmedAndIdentifiersSortedAndDeduplicated() throws {
        XCTAssertEqual(try SettingKeys.ocrLanguages.normalize(" fr-FR ,  en-US , "),
                       "fr-FR,en-US")
        XCTAssertEqual(try SettingKeys.pinnedRoots.normalize("3, 1, 3"), "1,3")
        XCTAssertEqual(try SettingKeys.pinnedRoots.normalize(""), "")
        XCTAssertThrowsError(try SettingKeys.pinnedRoots.normalize("Livres")) { error in
            let message = (error as? SettingsError)?.message ?? ""
            XCTAssertTrue(message.contains("is not a root identifier"), message)
        }
        // Un identifiant nul ou négatif n'existe pas : `roots.id` est un
        // INTEGER PRIMARY KEY, donc ≥ 1.
        XCTAssertThrowsError(try SettingKeys.pinnedRoots.normalize("0"))
    }

    /// Une valeur ILLISIBLE déjà en base ne fait tomber personne : elle est
    /// signalée, et le défaut s'applique. C'est le contraire qui serait grave —
    /// un agent qui refuse de démarrer à cause d'une ligne de réglage.
    func testUnreadableStoredValueFallsBackAndWarns() {
        let snapshot = SettingsSnapshot(rows: ["ocr.jobs": "beaucoup"],
                                        environment: [:])
        XCTAssertEqual(snapshot.ocrJobs, 4)
        XCTAssertEqual(snapshot.effective(SettingKeys.ocrJobs).source, .fallback)
        XCTAssertEqual(snapshot.warnings.count, 1)
        XCTAssertTrue(snapshot.warnings[0].contains("ocr.jobs"),
                      snapshot.warnings[0])
    }

    func testUnreadableEnvironmentValueFallsBackAndWarns() {
        let snapshot = SettingsSnapshot(
            rows: [:], environment: ["FOUINE_AGENT_REQUIRE_AC": "parfois"])
        XCTAssertTrue(snapshot.agentRequireAC)
        XCTAssertEqual(snapshot.warnings.count, 1)
        XCTAssertTrue(snapshot.warnings[0].contains("FOUINE_AGENT_REQUIRE_AC"),
                      snapshot.warnings[0])
    }

    // MARK: - Aller-retour en base (schéma v4)

    func testWriteReadResetThroughTheStore() throws {
        let db = try makeDB()
        let settings = Settings(store: db.store, ttl: 0, environment: [:])

        XCTAssertEqual(settings.snapshot().agentOCRBudgetMinutes, 10)
        XCTAssertEqual(try settings.set("agent.ocrBudgetMinutes", "45"), "45")
        XCTAssertEqual(settings.snapshot().agentOCRBudgetMinutes, 45)
        XCTAssertEqual(settings.snapshot()
            .effective(SettingKeys.agentOCRBudgetMinutes).source, .database)

        // La normalisation est appliquée À L'ÉCRITURE : la base ne contient
        // jamais une valeur qu'il faudrait re-corriger à chaque lecture.
        XCTAssertEqual(try settings.set("agent.ocrBudgetMinutes", "999"), "120")
        XCTAssertEqual(try db.store.settingsRows()["agent.ocrBudgetMinutes"], "120")

        try settings.reset("agent.ocrBudgetMinutes")
        XCTAssertNil(try db.store.settingsRows()["agent.ocrBudgetMinutes"])
        XCTAssertEqual(settings.snapshot().agentOCRBudgetMinutes, 10)
    }

    func testUnknownKeyIsRefusedWithTheListOfValidOnes() throws {
        let db = try makeDB()
        let settings = Settings(store: db.store, ttl: 0, environment: [:])
        XCTAssertThrowsError(try settings.set("ocr.langue", "fr")) { error in
            let message = (error as? SettingsError)?.message ?? ""
            XCTAssertTrue(message.contains("unknown setting"), message)
            XCTAssertTrue(message.contains("ocr.languages"), message)
        }
    }

    /// Le cache est BORNÉ : l'agent doit voir dans la minute un réglage écrit
    /// par l'app. Avec `ttl: 0`, toute lecture recharge ; avec un TTL long, la
    /// valeur précédente tient jusqu'à `invalidate()`.
    func testSnapshotCacheIsBoundedAndInvalidatable() throws {
        let db = try makeDB()
        let reader = Settings(store: db.store, ttl: 3_600, environment: [:])
        XCTAssertEqual(reader.snapshot().ocrJobs, 4)

        // Écriture par un AUTRE porteur (l'app, ou `fouine config set`).
        let writer = Settings(store: db.store, ttl: 0, environment: [:])
        try writer.set("ocr.jobs", "1")

        XCTAssertEqual(reader.snapshot().ocrJobs, 4, "le cache doit tenir")
        reader.invalidate()
        XCTAssertEqual(reader.snapshot().ocrJobs, 1)
    }

    // MARK: - Schéma courant

    func testSchemaVersionAndTablesExistOnAFreshDatabase() throws {
        let db = try makeDB()
        XCTAssertEqual(Schema.version, 9)
        XCTAssertEqual(try db.store.rawStrings(
            "SELECT v FROM meta WHERE k = 'schema_version'"),
                       [String(Schema.version)])
        for table in ["settings", "agent_status"] {
            XCTAssertEqual(try db.store.rawInt64s(
                "SELECT count(*) FROM sqlite_master WHERE type='table' "
                + "AND name='\(table)'"), [1], "table \(table) absente")
        }
        XCTAssertEqual(try db.store.rawStrings("PRAGMA integrity_check"), ["ok"])
    }

    // MARK: - État de l'agent (audit F7)

    func testAgentStatusRoundTrip() throws {
        let db = try makeDB()
        XCTAssertNil(try db.store.agentStatus(),
                     "aucun agent n'a écrit : le statut doit être absent, "
                     + "et non un statut par défaut inventé")

        let published = AgentStatusRecord(
            phase: .ocr, detail: "Clayden.pdf", done: 12, total: 340,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(), pid: getpid())
        try db.store.writeAgentStatus(published)

        let read = try XCTUnwrap(try db.store.agentStatus())
        XCTAssertEqual(read.phase, .ocr)
        XCTAssertEqual(read.detail, "Clayden.pdf")
        XCTAssertEqual(read.done, 12)
        XCTAssertEqual(read.total, 340)
        XCTAssertEqual(read.pid, getpid())
        // Notre propre processus est vivant et vient d'écrire : rien de périmé.
        XCTAssertFalse(read.isStale)

        // Une ligne par champ : c'est ce qui rend la table lisible au `sqlite3`.
        XCTAssertEqual(try db.store.rawInt64s("SELECT count(*) FROM agent_status"),
                       [7])
    }

    func testStaleStatusIsDetectedThreeWays() throws {
        let now = Date()
        // 1. Le processus a disparu. pid 0 n'existe jamais comme cible de kill().
        let dead = AgentStatusRecord(phase: .ocr, updatedAt: now, pid: 0)
        XCTAssertTrue(dead.isStale)
        XCTAssertFalse(dead.isAlive)

        // 2. Plus d'écriture depuis plus de cinq minutes, processus vivant.
        let silent = AgentStatusRecord(
            phase: .extract,
            updatedAt: now.addingTimeInterval(-AgentStatusRecord.staleAfter - 1),
            pid: getpid())
        XCTAssertTrue(silent.isAlive)
        XCTAssertTrue(silent.isStale)

        // 3. Arrêt propre : `stopped` est périmé par définition, sans attendre
        //    les cinq minutes.
        let stopped = AgentStatusRecord(phase: .stopped, updatedAt: now,
                                        pid: getpid())
        XCTAssertTrue(stopped.isStale)

        // Contre-épreuve : un agent vivant qui vient d'écrire ne l'est pas.
        let fresh = AgentStatusRecord(phase: .ocr, updatedAt: now, pid: getpid())
        XCTAssertFalse(fresh.isStale)
    }

    /// Une table à moitié écrite (phase inconnue, ou absente) ne doit pas
    /// produire un statut inventé : mieux vaut « aucun état » qu'un faux.
    func testMalformedAgentStatusIsRejected() {
        XCTAssertNil(AgentStatusRecord(rows: [:]))
        XCTAssertNil(AgentStatusRecord(rows: ["phase": "dansant"]))
        XCTAssertNotNil(AgentStatusRecord(rows: ["phase": "idle"]))
    }

    // MARK: - SettingsSnapshot.load (audit C2-11)

    private final class FailingStore: SettingsStore, @unchecked Sendable {
        func settingsRows() throws -> [String: String] {
            throw NSError(domain: "test", code: 42,
                          userInfo: [NSLocalizedDescriptionKey: "disk I/O failure"])
        }
        func writeSetting(_ key: String, _ value: String) throws {}
        func removeSetting(_ key: String) throws {}
    }

    func testSettingsSnapshotLoadFromNilStore() {
        let (snapshot, warning) = SettingsSnapshot.load(from: nil, environment: [:])
        XCTAssertNil(warning)
        XCTAssertEqual(snapshot.ocrJobs, 4) // fallback is 4
    }

    func testSettingsSnapshotLoadSuccess() throws {
        let db = try makeDB()
        try db.store.writeSetting("ocr.jobs", "1")
        let (snapshot, warning) = SettingsSnapshot.load(from: db.store, environment: [:])
        XCTAssertNil(warning)
        XCTAssertEqual(snapshot.ocrJobs, 1)
    }

    func testSettingsSnapshotLoadFailureYieldsWarningAndFallback() {
        let store = FailingStore()
        let (snapshot, warning) = SettingsSnapshot.load(from: store, environment: [:])
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("cannot read settings from the database") == true)
        XCTAssertTrue(warning?.contains("disk I/O failure") == true)
        XCTAssertEqual(snapshot.ocrJobs, 4) // default fallback intact
    }

    func testSettingsReloadCapturesLoadWarning() {
        let store = FailingStore()
        let settings = Settings(store: store, ttl: 0, environment: [:])
        let snapshot = settings.reload()
        XCTAssertTrue(snapshot.warnings.contains { $0.contains("cannot read settings from the database") })
    }
}
