// IndexDetailsActionTests.swift — le geste de la fenêtre « Votre index »
// (PI-07). Propriété : A-App.
//
// Deux moitiés d'un même défaut, et les deux se tiennent ici :
//   · la fenêtre tirait son bouton de `status.primaryAction` brut, sans
//     `isStopping` ni désarmement : un « Stop » cliquable, et recliquable,
//     sans tourniquet, là où la carte désarme le sien dès le clic (ST1) ;
//   · `cancelIndexing()` mutait `indexing` sans republier `indexStatus` :
//     l'état restait « arrêtable » jusqu'à la publication suivante du service,
//     c'est-à-dire jusqu'à ce que la passe reprenne la main.
//
// La vue ne se teste pas : ce qu'elle peint est décidé par
// `IndexDetailsActivity`, et c'est lui qu'on interroge.

import XCTest
import FouineCore
@testable import FouineApp

@MainActor
final class IndexDetailsActionTests: XCTestCase {

    private func activity(_ app: AppModel) -> IndexDetailsActivity {
        IndexDetailsActivity(status: app.indexStatus, disk: .silent,
                             indexing: app.indexing)
    }

    /// Un clic sur « Stop » : l'état publié perd son geste TOUT DE SUITE, et la
    /// fenêtre garde le bouton, désarmé, avec son tourniquet.
    func testStoppingDisarmsTheWindowButtonWithoutWaitingForAPass() async throws {
        let db = try TempAppDB()
        let app = AppModel(service: db.service)
        let folder = db.directory.appendingPathComponent("Livres", isDirectory: true)
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        try "un".write(to: folder.appendingPathComponent("un.txt"),
                       atomically: true, encoding: .utf8)
        _ = try db.store.addRoot(path: folder, label: "Livres")

        await app.start()
        defer {
            app.stopAgentStatusProbe()
            app.stopHealthProbe()
        }

        // Une passe de l'application en cours, comme après « Mettre à jour
        // maintenant ».
        app.indexing = IndexingState(running: true, phase: "reading “un.txt”…")
        app.refreshIndexStatus()

        XCTAssertEqual(app.indexStatus.primaryAction, .stop,
                       "une passe de l'app s'arrête d'ici")
        let before = activity(app)
        XCTAssertEqual(before.action, .stop)
        XCTAssertFalse(before.isStopping, "rien n'a encore été demandé")

        app.cancelIndexing()

        XCTAssertNil(app.indexStatus.primaryAction,
                     "PI-07 : l'état est republié sans attendre un tic — il n'est plus arrêtable")
        let after = activity(app)
        XCTAssertEqual(after.action, .stop,
                       "PI-07 : le bouton RESTE, sinon on ne saurait plus si le clic a été pris")
        XCTAssertTrue(after.isStopping,
                      "PI-07 : désarmé et accompagné du tourniquet, comme dans la carte")
    }

    /// Ce que la fenêtre porte et que la carte écarte : « Lire les pages
    /// scannées… ». Le résumé de la carte le rend `nil` — la fenêtre ne doit
    /// pas perdre le geste au passage.
    func testTheWindowKeepsTheGestureTheCardDrops() {
        let paused = IndexStatus.paused(reason: .onBattery, scansWaiting: 12)
        let decision = IndexDetailsActivity(status: paused, disk: .silent,
                                            indexing: IndexingState())

        XCTAssertNil(decision.summary.action, "la carte n'ouvre pas de feuille de budget")
        XCTAssertEqual(decision.action, .readScans, "la fenêtre, elle, la porte")
        XCTAssertFalse(decision.isStopping)
    }
}
