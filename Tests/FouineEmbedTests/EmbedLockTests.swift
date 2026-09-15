// EmbedLockTests.swift — la pompe à vecteurs rend le verrou à chaque lot.
// Propriété : A-Embed, cible de test uniquement. Audit B1-06, D2-04, C2-04.
//
// ═══ CE QUE CES TESTS EMPÊCHENT DE REVENIR ═════════════════════════════════
//
// `EmbedRun` prenait `fouine.lock` paresseusement au premier lot et ne le
// rendait qu'à la mort du processus. Pendant les vingt heures d'une campagne,
// l'application échouait après cinq secondes d'attente sur « Ajouter un
// dossier », « Indexer », « Lancer l'OCR » — mesuré au `lsof` sur la campagne
// du 2 septembre, verrou tenu en continu depuis 15 h 25 (B1-06).
//
// La conséquence subtile est celle que D2-04 relève : tout le dispositif de
// cohabitation d'`EmbedRun` (tampon borné, `flushIfUnlocked`, `patiently`)
// suppose que le processus N'A PAS le verrou. En le gardant, la pompe se
// garantissait de toujours réussir son écriture, et le code écrit pour
// cohabiter devenait mort dès la cinquième seconde.
//
// L'instrument est vérifié par `testASecondWriterIsRefusedWhileTheLockIsHeld` :
// deux `GRDBStore` sur la même base, dans le même processus, se refusent bien
// l'un l'autre (`flock` porte sur la description de fichier ouverte, pas sur le
// processus). Sans ce test, les deux autres ne prouveraient rien.

import Foundation
import XCTest
@testable import FouineEmbed
@testable import FouineCore

final class EmbedLockTests: XCTestCase {

    /// Une racine RÉELLE et lisible : `addRoot` sonde le dossier avant tout
    /// enregistrement. Jetable, hors du dépôt, comme tout ce qu'écrivent les
    /// tests.
    private func makeRoot(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-embed-lock-\(label)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        try Data("temoin".utf8)
            .write(to: url.appendingPathComponent("note.txt"))
        return url
    }

    /// Remplit la base de quoi produire plusieurs lots.
    @discardableResult
    private func fill(_ db: TempDB, docs: Int, pages: Int) throws -> Int {
        for d in 1...docs {
            let id = try addDoc(db, relPath: "Users/essai/Livres/d\(d).pdf")
            try db.store.replacePages(
                docID: id,
                pages: (1...pages).map {
                    page($0, "document \(d) page \($0) : chromatographie "
                            + "enthalpie polymere azote acide")
                })
        }
        return docs * pages
    }

    // MARK: - Contre-épreuve de l'instrument

    /// Deux `GRDBStore` ouverts sur la MÊME base : tant que le premier tient le
    /// verrou, le second doit être refusé — et refusé avec l'enregistrement
    /// sans langue `fouine-lock-busy`, que trois boucles de reprise lisent
    /// (`EmbedRun`, `AgentStatusWriter`, `GRDBStore+Settings`) et que l'app
    /// recompose dans sa langue. Ce message ne doit PAS changer.
    func testASecondWriterIsRefusedWhileTheLockIsHeld() throws {
        let db = try makeDB()
        // 0,3 s d'attente au lieu des 5 s de production : le refus est le même
        // (verrou nommé, détenteur lu à l'échéance), seule l'attente change.
        let other = GRDBStore(lockTimeout: 0.3)
        try other.open(at: db.directory.appendingPathComponent("fouine.db"))

        try db.store.acquireWriteLock(as: .cli)
        defer { db.store.releaseWriteLock() }

        let root = try makeRoot("refuse")
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try other.addRoot(path: root, label: "Refusée")) {
            guard case FouineError.databaseFailure(let message) = $0 else {
                return XCTFail("attendu .databaseFailure, obtenu \($0)")
            }
            XCTAssertTrue(message.hasPrefix(WriteLock.busyToken),
                          "l'enregistrement d'occupation a changé : \(message)")
            XCTAssertTrue(WriteLock.isBusy(FouineError.databaseFailure(message)))
            let busy = WriteLock.busy(FouineError.databaseFailure(message))
            XCTAssertEqual(busy?.holder?.pid, getpid())
            XCTAssertEqual(busy?.holder?.role, .cli)
        }
    }

    // MARK: - B1-06 / D2-04

    /// LE test de B1-06 : une passe d'embed EN COURS — entre deux lots — ne doit
    /// pas empêcher un second écrivain d'aboutir. C'est exactement ce que
    /// l'utilisateur essaie de faire quand il ajoute un dossier pendant que la
    /// campagne tourne.
    func testAnEmbeddingPassDoesNotBlockAnotherWriter() throws {
        let db = try makeDB()
        try fill(db, docs: 4, pages: 3)          // 12 pages
        let other = GRDBStore()
        try other.open(at: db.directory.appendingPathComponent("fouine.db"))

        let root = try makeRoot("pendant")
        defer { try? FileManager.default.removeItem(at: root) }

        // Le résultat de l'écriture concurrente, tentée DEPUIS l'intérieur de la
        // pompe : au deuxième lot, le premier a été écrit et le verrou rendu.
        let outcome = OutcomeBox()
        let engine = RecordingEngine()
        engine.afterBatch = { number in
            guard number == 2 else { return }
            do {
                _ = try other.addRoot(path: root, label: "Pendant la campagne")
                outcome.set(nil)
            } catch {
                outcome.set(error)
            }
            // Le second écrivain rend le verrou à SON point de repos — ici, la
            // fin de son geste. C'est ce que fait la CLI à la sortie du
            // processus (`Support.swift`). Sans cela il le garderait, et la
            // pompe attendrait quinze minutes son écriture finale : la
            // cohabitation demande la même discipline des deux côtés.
            other.releaseWriteLock()
        }

        var config = silentConfig()
        config.batchSize = 2                     // au moins six lots
        let summary = try EmbedRun.run(store: db.store, engine: engine,
                                       config: config)
        XCTAssertEqual(summary.embedded, 12)
        XCTAssertGreaterThanOrEqual(engine.batches, 2,
                                    "il faut au moins deux lots pour que le "
                                    + "test ait un sens")

        if let error = outcome.value {
            XCTFail("`addRoot` a été refusé pendant la campagne — le verrou "
                    + "n'est pas rendu entre deux lots (B1-06) : \(error)")
        }
        XCTAssertEqual(try other.roots().count, 1)
    }

    /// Et une fois la pompe revenue, le verrou n'est plus tenu du tout : ni par
    /// une écriture en vol, ni par le `defer` de sortie. Deux preuves — une
    /// écriture concurrente qui passe, et le fichier `fouine.lock` TRONQUÉ, ce
    /// que `release()` fait et que rien d'autre ne fait.
    func testTheLockIsNotHeldAfterThePumpReturns() throws {
        let db = try makeDB()
        try fill(db, docs: 2, pages: 3)
        var config = silentConfig()
        config.batchSize = 2
        _ = try EmbedRun.run(store: db.store, engine: FakeEngine(), config: config)

        let lock = db.directory.appendingPathComponent("fouine.lock")
        let contents = (try? Data(contentsOf: lock)) ?? Data()
        XCTAssertTrue(contents.isEmpty,
                      "`fouine.lock` nomme encore un détenteur après le retour "
                      + "de la pompe : « \(String(decoding: contents, as: UTF8.self)) »")

        let other = GRDBStore()
        try other.open(at: db.directory.appendingPathComponent("fouine.db"))
        let root = try makeRoot("apres")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNoThrow(try other.addRoot(path: root, label: "Après"))
    }

    // MARK: - C2-04 : le débit dit vrai

    /// Le journal affichait une moyenne CUMULÉE (4,9-5,0 p/s là où la pompe
    /// tournait à 6,4-6,6), qui met des heures à refléter un ralentissement.
    /// La fenêtre glissante, elle, ne regarde que les cinq dernières minutes.
    func testSlidingRateIgnoresWhatIsOutsideTheWindow() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        // Une heure très lente (1 p/s), puis cinq minutes rapides (10 p/s).
        let now = start.addingTimeInterval(3_600 + 300)
        let samples: [(at: Date, produced: Int)] = [
            (start, 0),
            (start.addingTimeInterval(3_600), 3_600),
            (now, 3_600 + 3_000),
        ]
        let rate = EmbedRun.slidingRate(samples, now: now)
        XCTAssertEqual(rate, 10, accuracy: 0.01,
                       "la fenêtre doit ignorer l'heure lente")

        // Moyenne cumulée, pour mémoire : 1,79 p/s — c'est ce qu'on affichait.
        let cumulative = Double(3_600 + 3_000) / now.timeIntervalSince(start)
        XCTAssertLessThan(cumulative, 2)

        // Avant cinq minutes de campagne, il n'y a rien d'autre à dire que la
        // moyenne depuis le début : c'est le repli, et il ne doit pas rendre 0.
        let young = start.addingTimeInterval(60)
        XCTAssertEqual(EmbedRun.slidingRate([(start, 0), (young, 300)], now: young),
                       5, accuracy: 0.01)
    }
}

/// Boîte à résultat, écrite depuis le fil de la pompe et lue par le test.
final class OutcomeBox: @unchecked Sendable {
    private let mutex = NSLock()
    private var stored: Error?
    private var written = false

    func set(_ error: Error?) {
        mutex.lock(); stored = error; written = true; mutex.unlock()
    }

    /// L'erreur rencontrée, ou `nil` si l'écriture a abouti.
    var value: Error? { mutex.lock(); defer { mutex.unlock() }; return stored }
    var wasAttempted: Bool { mutex.lock(); defer { mutex.unlock() }; return written }
}
