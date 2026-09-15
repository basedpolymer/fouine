// EmbedCampaignLockTests.swift — une seule campagne à la fois (constat C2-11).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Embed, cible de test uniquement.
//
// CE QUE CES TESTS EMPÊCHENT DE REVENIR. Deux `fouine embed` lancés sur la même
// base ont tourné ensemble onze minutes, chacun inférant les mêmes pages, tous
// deux en sortie 0. Le verrou d'écriture ne pouvait rien y faire : `EmbedRun`
// le rend après chaque lot, délibérément (B1-06, D2-04), et c'est une bonne
// décision — l'application doit pouvoir indexer pendant une campagne de vingt
// heures. Il fallait donc un verrou SÉPARÉ, qui ne protège aucune écriture et
// répond à une seule question.
//
// `flock` porte sur la DESCRIPTION de fichier ouverte, pas sur le processus :
// deux prises dans le même processus se refusent bien l'une l'autre, ce qui
// rend ces cas exécutables sans lancer un second binaire.

import XCTest
@testable import FouineEmbed
@testable import FouineCore

final class EmbedCampaignLockTests: XCTestCase {

    private var directory: URL!
    private var database: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-embed-campaign-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        database = directory.appendingPathComponent("fouine.db")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Le fichier vit À CÔTÉ de la base, comme `fouine.lock` : une copie de
    /// base emportée ailleurs emmène son propre verrou, pas celui du fonds.
    func testTheLockFileSitsNextToTheDatabase() {
        let url = EmbedCampaignLock.url(for: database)
        XCTAssertEqual(url.lastPathComponent, "fouine-embed.lock")
        XCTAssertEqual(url.deletingLastPathComponent().path, directory.path)
    }

    func testASecondCampaignIsRefusedAndNamesTheFirst() throws {
        let first = try EmbedCampaignLock.acquire(databaseURL: database)

        XCTAssertThrowsError(try EmbedCampaignLock.acquire(databaseURL: database)) {
            guard let busy = $0 as? EmbedCampaignLock.Busy else {
                return XCTFail("attendu Busy, obtenu \($0)")
            }
            XCTAssertEqual(busy.holder?.pid, getpid())
            XCTAssertTrue(busy.description.hasPrefix(
                "a vectorisation campaign is already running"), busy.description)
            XCTAssertTrue(busy.description.contains("pid \(getpid())"),
                          busy.description)
        }

        // Rendu, le verrou se reprend : une campagne interrompue n'interdit
        // pas la suivante.
        first.release()
        let second = try EmbedCampaignLock.acquire(databaseURL: database)
        second.release()
    }

    /// La sonde de `fouine status` : elle ne crée rien, n'attend rien, et dit
    /// « personne » dès que le verrou est rendu — même si le fichier nommait
    /// encore quelqu'un.
    func testProbeSeesTheCampaignThenTheFreeLock() throws {
        XCTAssertNil(EmbedCampaignLock.probe(databaseURL: database),
                     "aucun fichier : personne ne vectorise")

        let lock = try EmbedCampaignLock.acquire(databaseURL: database)
        let holder = try XCTUnwrap(EmbedCampaignLock.probe(databaseURL: database))
        XCTAssertEqual(holder.pid, getpid())
        XCTAssertTrue(holder.isAlive)
        XCTAssertLessThan(abs(holder.since.timeIntervalSinceNow), 60)
        XCTAssertFalse(holder.isoText.isEmpty)

        lock.release()
        XCTAssertNil(EmbedCampaignLock.probe(databaseURL: database))
    }

    /// La ligne du fichier est un contrat minuscule : « pid N since <ISO> ».
    /// Un fichier vide, tronqué ou d'un autre format ne nomme PERSONNE — on
    /// n'accuse jamais un détenteur incertain.
    func testTheLineIsReadBack() {
        let since = Date(timeIntervalSince1970: 1_788_000_000)
        let line = EmbedCampaignLock.line(pid: 4_242, since: since)
        let holder = EmbedCampaignLock.parse(line)
        XCTAssertEqual(holder?.pid, 4_242)
        XCTAssertEqual(holder?.since.timeIntervalSince1970 ?? 0,
                       since.timeIntervalSince1970, accuracy: 1)

        XCTAssertNil(EmbedCampaignLock.parse(""))
        XCTAssertNil(EmbedCampaignLock.parse("pid zéro since maintenant\n"))
        XCTAssertNil(EmbedCampaignLock.parse("fouine-lock 1 pid=12 role=cli\n"))
    }

    /// Le verrou D'ÉCRITURE et celui de CAMPAGNE sont deux fichiers, et c'est
    /// tout le point : `embed` rend le premier après chaque lot et garde le
    /// second, donc l'application peut indexer pendant une campagne.
    func testTheCampaignLockDoesNotTakeTheWriteLock() throws {
        let store = GRDBStore(lockTimeout: 0.3)
        try store.open(at: database)
        let campaign = try EmbedCampaignLock.acquire(databaseURL: database)
        defer { campaign.release() }

        XCTAssertTrue(WriteLock.inspect(path: FouinePaths.lockURL(for: database).path)
            .isFree, "la campagne ne doit pas tenir `fouine.lock`")
        // Et un autre écrivain peut bel et bien écrire.
        XCTAssertNoThrow(try store.writeSetting("extract.jobs", "2"))
        store.releaseWriteLock()
    }
}
