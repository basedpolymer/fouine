// StateFreshnessTests.swift — l'état montré est celui qui a été LU, et il est
// publié même quand macOS tarde à répondre (PI-01, PI-03, PI-04).
// Propriété : A-App.
//
// Trois défauts de la source de l'état d'indexation, et un test par défaut :
//   · PI-01 — `refreshRoots(probe: false)`, appelé à chaque ouverture des
//     réglages, déclarait chaque dossier actif « lisible » sans rien lire : la
//     carte « Index » perdait au tour de santé suivant « Fouine n'est pas
//     autorisée à lire “X” » et le bouton qui le répare ;
//   · PI-03 — `SMAppService.mainApp.status` était lu en synchrone sur le fil
//     principal, depuis `init()`, donc avant toute fenêtre : un `smd` lent
//     figeait un lancement entièrement muet (même mesure que BU-03) ;
//   · PI-04 — la sonde publiait l'état de l'agent SEULEMENT après avoir attendu
//     ce même service : la barre d'avancement, la fenêtre « Votre index » et
//     l'icône de la barre des menus restaient figées alors que la base avait
//     répondu en quelques millisecondes.

import XCTest
import Combine
import FouineCore
@testable import FouineApp

@MainActor
final class StateFreshnessTests: XCTestCase {

    // MARK: - PI-01 · un refus de lecture survit à l'ouverture des réglages

    /// Un dossier que macOS refuse reste refusé après `probe: false`, et la
    /// ligne de santé garde son geste. C'est tout le constat : sans sonde, on
    /// REPORTE ce que la dernière sonde a trouvé, on ne repeint pas en vert.
    func testARefusedFolderSurvivesOpeningTheSettings() async throws {
        let db = try TempAppDB()
        let folder = try db.makeFolder(named: "Livres")
        let app = AppModel(service: db.service)
        app.readServiceStatus = { .enabled }
        _ = try db.store.addRoot(path: folder, label: "Livres")

        await app.start()
        defer {
            app.stopAgentStatusProbe()
            app.stopHealthProbe()
        }
        // L'enregistrement se lit dans sa propre tâche (suite de PI-04) :
        // avant sa réponse, la carte dit « Vérification… » à bon droit.
        await until(5) { app.indexStatus != .checking }

        // Ce que la sonde trouve chez qui a refusé l'invite de macOS.
        var refused = try XCTUnwrap(app.roots.first)
        refused.readable = false
        refused.reason = "permission denied"
        refused.probeReason = .permissionDenied
        app.roots = [refused]
        await app.refreshHealth()

        XCTAssertEqual(app.indexStatus,
                       .needsAttention(.folderNotAllowed(folder: "Livres")))
        XCTAssertEqual(app.indexStatus.primaryAction, .openPrivacySettings)

        // ⌘, — et rien d'autre.
        await app.refreshRoots(probe: false)

        let after = try XCTUnwrap(app.roots.first)
        XCTAssertFalse(after.readable, "PI-01 : le dossier a été repeint lisible")
        XCTAssertEqual(after.probeReason, .permissionDenied)

        // Le tour de santé qui suit (au plus 30 s plus tard) effaçait ici la
        // phrase ET le bouton, en laissant le bandeau orange seul.
        await app.refreshHealth()
        XCTAssertEqual(app.indexStatus,
                       .needsAttention(.folderNotAllowed(folder: "Livres")))
        XCTAssertEqual(app.indexStatus.primaryAction, .openPrivacySettings)
    }

    /// Une racine dont on ne sait RIEN — ajoutée depuis une autre fenêtre,
    /// jamais sondée — garde le comportement d'avant : active vaut lisible,
    /// sinon la carte réclamerait une autorisation sans l'avoir demandée.
    func testAFolderNeverProbedYetIsTakenAsReadable() async throws {
        let db = try TempAppDB()
        let folder = try db.makeFolder(named: "Notes")
        let app = AppModel(service: db.service)
        _ = try db.store.addRoot(path: folder, label: "Notes")

        await app.refreshRoots(probe: false)

        let root = try XCTUnwrap(app.roots.first)
        XCTAssertTrue(root.readable)
        XCTAssertNil(root.probeReason)
        XCTAssertNil(root.reason)
    }

    // MARK: - PI-03 · l'ouverture à la session se lit hors du fil principal

    /// `init()` ne pose plus la question au système : il la fait poser. Un
    /// `smd` lent ne peut donc plus figer un lancement sans fenêtre ni icône.
    func testOpeningAtLoginIsNeverReadOnTheMainThread() async {
        _ = TestPrefs.isolate
        Prefs.defaults.removeObject(forKey: Prefs.opensAtLoginLastKnown)
        let offMain = CallCounter()
        let onMain = CallCounter()
        let prefs = InterfacePreferences(canOpenAtLogin: true) {
            if Thread.isMainThread { onMain.bump() } else { offMain.bump() }
            return .enabled
        }

        XCTAssertEqual(offMain.count + onMain.count, 0,
                       "PI-03 : la naissance du modèle a attendu `smd`")

        await until(5) { offMain.count + onMain.count == 1 }

        XCTAssertEqual(onMain.count, 0, "PI-03 : lu sur le fil principal")
        XCTAssertEqual(offMain.count, 1, "une lecture, hors du fil principal")
        await until(5) { prefs.opensAtLogin }
        XCTAssertTrue(prefs.opensAtLogin, "l'état finit par refléter le système")
    }

    /// Attend une condition sans monopoliser le fil principal — dont les
    /// continuations @MainActor ont justement besoin pour s'y exécuter.
    private func until(_ timeout: TimeInterval,
                       _ done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if done() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Pendant que le système répond, l'interrupteur montre la DERNIÈRE VALEUR
    /// CONNUE : partir de « non » le faisait basculer sous les yeux de
    /// l'utilisateur, et mentait tant que la réponse n'arrivait pas.
    func testTheSwitchKeepsTheLastKnownValueWhileTheSystemAnswers() {
        _ = TestPrefs.isolate
        Prefs.lastKnownOpensAtLogin = true
        defer { Prefs.defaults.removeObject(forKey: Prefs.opensAtLoginLastKnown) }

        let prefs = InterfacePreferences(canOpenAtLogin: true) { .notRegistered }
        XCTAssertTrue(prefs.opensAtLogin)

        // Hors bundle, il n'y a rien à enregistrer : la case est éteinte et
        // désactivée, et la valeur mémorisée n'y change rien.
        XCTAssertFalse(InterfacePreferences(canOpenAtLogin: false) { .enabled }
            .opensAtLogin)
    }

    // MARK: - PI-04 · un service lent ne fige plus la progression

    /// L'état de l'agent est publié dès que la BASE a répondu, et la lecture de
    /// l'enregistrement — l'aller-retour vers `smd` — ne s'empile pas derrière
    /// elle : dix tics pendant que le service se tait, une seule lecture en vol.
    func testTheAgentStateIsPublishedWhileTheServiceStaysSilent() async throws {
        let db = try TempAppDB()
        try db.store.writeAgentStatus(
            AgentStatusRecord(phase: .ocr, detail: "", done: 3, total: 10,
                              startedAt: Date(), updatedAt: Date()))
        let app = AppModel(service: db.service)
        let reads = CallCounter()
        // Un `smd` qui ne répond pas, comme sur la machine du propriétaire.
        let silence = DispatchSemaphore(value: 0)
        defer { silence.signal() }
        app.readServiceStatus = {
            reads.bump()
            _ = silence.wait(timeout: .now() + 10)
            return .enabled
        }

        let started = Date()
        await app.refreshAgentActivity()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 1,
                          "PI-04 : la publication a attendu la réponse du service")
        XCTAssertEqual(app.agentStatus?.phase, .ocr)
        XCTAssertEqual(app.agentStatus?.done, 3)

        // La lecture du service, elle, est LANCÉE : elle part dans sa propre
        // tâche et se bloque là, sans que rien l'attende.
        await until(2) { reads.count == 1 }
        XCTAssertEqual(reads.count, 1, "la lecture du service n'a pas été lancée")

        for _ in 0..<10 { await app.refreshAgentActivity() }
        XCTAssertEqual(reads.count, 1,
                       "PI-04 : les lectures du service s'empilent derrière un `smd` muet")
    }

    /// La cadence est bornée même quand le service répond : l'enregistrement ne
    /// change que sur un geste ou une approbation système, et le relire deux
    /// fois par seconde coûtait ~1 800 allers-retours par heure pour rien.
    func testTheServiceIsNotAskedAgainBeforeItsInterval() async throws {
        let db = try TempAppDB()
        try db.store.writeAgentStatus(
            AgentStatusRecord(phase: .idle, detail: "", updatedAt: Date()))
        let app = AppModel(service: db.service)
        let reads = CallCounter()
        app.readServiceStatus = { reads.bump(); return .enabled }

        await app.refreshAgentActivity()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(reads.count, 1)

        for _ in 0..<5 {
            await app.refreshAgentActivity()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(reads.count, 1,
                       "PI-04 : relu avant les \(Int(AppModel.serviceStatusInterval)) s de cadence")

        // Les signaux, eux, passent devant la cadence : un geste sur
        // l'interrupteur ou le retour de l'app au premier plan.
        app.refreshServiceStatusIfStale(force: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(reads.count, 2, "un geste relit tout de suite")
    }

    // MARK: - Suite de PI-04 · le lancement n'attend plus `smd`

    /// Un service qui ne répond pas ne retient plus le démarrage, et il ne fait
    /// pas afficher un agent « non enregistré » qui n'a jamais été lu : la
    /// carte reste sur « Vérification… », sans bouton, et l'avancement lu en
    /// base est publié quand même.
    func testASilentServiceNeitherDelaysTheLaunchNorInventsAnUnregisteredAgent() async throws {
        let db = try TempAppDB()
        try db.store.writeAgentStatus(
            AgentStatusRecord(phase: .ocr, detail: "", done: 3, total: 10,
                              startedAt: Date(), updatedAt: Date()))
        let app = AppModel(service: db.service)
        let silence = DispatchSemaphore(value: 0)
        defer { silence.signal() }
        app.readServiceStatus = {
            _ = silence.wait(timeout: .now() + 10)
            return .enabled
        }
        var states: [AgentOperationalState] = []
        let token = app.$agentOperationalState.sink { states.append($0) }
        defer { token.cancel() }

        let started = Date()
        await app.start()
        let elapsed = Date().timeIntervalSince(started)
        defer {
            app.stopAgentStatusProbe()
            app.stopHealthProbe()
        }

        XCTAssertLessThan(elapsed, 2,
                          "suite de PI-04 : le lancement a attendu `smd`")
        XCTAssertTrue(app.isReady, "la base est ouverte, la fenêtre peut s'ouvrir")
        XCTAssertEqual(app.agentStatus?.done, 3,
                       "l'avancement de la mise à jour automatique n'est pas publié")
        XCTAssertEqual(app.indexStatus, .checking,
                       "un état a été deviné avant la réponse du service")
        XCTAssertNil(app.indexStatus.primaryAction, "aucun bouton sur un doute")
        XCTAssertFalse(states.contains(.notFound),
                       "« non enregistré » a été publié sans avoir été lu")
        XCTAssertFalse(states.contains(.registeredButSilent))
    }

    // MARK: - PI-06 · un tic immobile ne publie rien

    /// L'agent republie `.idle` à chaque tic : c'est son battement. Un
    /// `@Published` publiant AVANT de comparer, chaque tic réévaluait le corps
    /// de la scène et celui de `MenuBarExtra` pour réécrire le même état.
    func testATickWithoutChangePublishesNothing() async throws {
        let db = try TempAppDB()
        let beat = AgentStatusRecord(phase: .idle,
                                     detail: AgentStatusDetail.queueDrained,
                                     startedAt: Date(), updatedAt: Date(),
                                     pid: getpid())
        try db.store.writeAgentStatus(beat)
        let app = AppModel(service: db.service)
        app.readServiceStatus = { .enabled }
        _ = try db.store.addRoot(path: try db.makeFolder(named: "Docs"),
                                 label: "Docs")

        await app.start()
        // Les sondes battent toutes les deux secondes : elles publieraient
        // pendant le comptage.
        app.stopAgentStatusProbe()
        app.stopHealthProbe()
        await until(5) { app.indexStatus != .checking }
        XCTAssertEqual(app.indexStatus, .idle(automatic: true, scansWaiting: 0,
                                              lastUpdate: nil),
                       "état de départ : à jour, rien d'indexé à dater")

        var publications = 0
        let token = app.objectWillChange.sink { _ in publications += 1 }
        defer { token.cancel() }

        // Le battement, à l'identique : rien n'a changé, rien ne se publie.
        try db.store.writeAgentStatus(beat)
        await app.refreshAgentActivity()
        XCTAssertEqual(publications, 0,
                       "PI-06 : un tic immobile a publié \(publications) fois")

        // Et quand quelque chose change, ça se publie.
        try db.store.writeAgentStatus(
            AgentStatusRecord(phase: .ocr, detail: "", done: 2, total: 40,
                              startedAt: Date(), updatedAt: Date(),
                              pid: getpid()))
        await app.refreshAgentActivity()
        XCTAssertGreaterThan(publications, 0, "un changement ne s'est pas publié")
        XCTAssertTrue(app.indexStatus.isWorking)
    }
}

// MARK: - Soutien

extension TempAppDB {

    /// Un dossier RÉEL, avec un fichier lisible dedans : `addRoot` sonde ce
    /// qu'on lui donne et refuse une racine muette.
    func makeFolder(named name: String) throws -> URL {
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        try "un".write(to: folder.appendingPathComponent("un.txt"),
                       atomically: true, encoding: .utf8)
        return folder
    }
}
