// AppModelStartupTests.swift — le démarrage ne montre rien de faux (UX-01,
// UX-02) et « depuis votre dernière visite » (UX-06). Propriété : A-App.
//
// Ce qui se teste ici est l'ÉTAT, pas la vue. Deux clignotements coûtaient
// leur crédit aux deux premières secondes de chaque lancement :
//   · `roots` est vide par construction tant que la base n'est pas lue, et
//     `ContentView` en concluait « aucun dossier » — l'écran d'accueil
//     « Bienvenue dans Fouine » s'affichait par-dessus un index de quatre cent
//     mille pages ;
//   · `agent_status` n'était lu qu'au premier tour de la sonde, et la barre
//     latérale affichait entre-temps « L'agent est enregistré mais ne démarre
//     pas » avec son bouton « Ré-enregistrer ».
// `isReady` et `agentProbed` sont les deux verrous qui l'empêchent ; ce test
// les tient.

import XCTest
import FouineCore
import FouineCrawl
@testable import FouineApp

/// Compteur d'appels partageable avec une fermeture `@Sendable` : la lecture du
/// statut de l'agent se fait hors du fil principal (BU-03), le compteur doit
/// donc l'être aussi.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() {
        lock.lock(); value += 1; lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

@MainActor
final class AppModelStartupTests: XCTestCase {

    /// Avant `start()`, l'app ne sait RIEN : elle ne dit donc rien.
    func testAvantLeDemarrageRienNEstDecide() throws {
        let db = try TempAppDB()
        let app = AppModel(service: db.service)

        XCTAssertFalse(app.isReady,
                       "UX-01 : la fenêtre ne montre ni accueil ni panneaux")
        XCTAssertEqual(app.indexStatus, .checking,
                       "UX-02 : « Vérification… », pas un état deviné")
        XCTAssertNil(app.indexStatus.primaryAction,
                     "UX-02 : aucun bouton — c'est « Ré-enregistrer » qui apparaissait")
    }

    /// Après `start()` sur une base sans dossier, l'état est celui qui est
    /// VRAI : aucun dossier à indexer, et le seul geste qui ait un sens.
    func testApresLeDemarrageLEtatEstCeluiDeLaBase() async throws {
        let db = try TempAppDB()
        let app = AppModel(service: db.service)

        await app.start()
        defer {
            app.stopAgentStatusProbe()
            app.stopHealthProbe()
        }

        XCTAssertTrue(app.isReady)
        XCTAssertNil(app.openError)
        XCTAssertEqual(app.indexStatus, .noFolders)
        XCTAssertEqual(app.indexStatus.primaryAction, .addFolder)
    }

    /// `start()` part du délégué d'application ET le `.task` de la fenêtre
    /// l'attend (BU-02) : deux appels, UNE ouverture. Sans cette garantie, le
    /// second chemin rejouerait la sonde TCC — une invite système — et le
    /// balayage du vocabulaire à chaque apparition de la fenêtre.
    func testLeDemarrageNOuvreLIndexQuUneFois() async throws {
        let db = try TempAppDB()          // ouvre déjà l'index une fois
        let app = AppModel(service: db.service)
        defer {
            app.stopAgentStatusProbe()
            app.stopHealthProbe()
        }
        let before = db.service.openCount

        await app.start()
        await app.start()

        XCTAssertEqual(db.service.openCount, before + 1,
                       "deux appels de start() n'ouvrent l'index qu'une fois")
        XCTAssertTrue(app.isReady)
    }

    /// Le rendu de l'état de l'agent n'interroge PLUS le service au passage
    /// (BU-03) : `SMAppService.status` est un aller-retour XPC synchrone, et
    /// la sonde le jouait sur le fil principal toutes les deux secondes.
    func testLEtatDeLAgentNInterrogePlusLeServiceSurLeFilPrincipal() async throws {
        let db = try TempAppDB()
        let app = AppModel(service: db.service)
        let counter = CallCounter()
        app.readServiceStatus = {
            counter.bump()
            return .notRegistered
        }

        app.updateOperationalState(serviceStatus: .enabled)
        XCTAssertEqual(counter.count, 0,
                       "le statut est DONNÉ au rendu, il n'est pas lu par lui")

        await app.refreshAgentStatus()
        XCTAssertEqual(counter.count, 1, "une lecture, hors du fil principal")
        XCTAssertFalse(app.backgroundIndexing)
    }

    // MARK: - Le refus qui a une issue (AP-01)

    /// Une lecture refusée se répare dans les Réglages Système : l'alerte
    /// « Dossier non ajouté » porte alors deux gestes de plus. Un dossier
    /// disparu, lui, n'a rien à autoriser — proposer d'ouvrir les Réglages
    /// enverrait chercher une case qui ne changerait rien.
    func testUnRefusDeLectureOffreUneIssueEtPasUnDossierDisparu() {
        let refuse = FouineError.rootUnreadable(
            path: "/Users/x/Livres", reason: RootProbe.Reason.permissionDenied.token)
        XCTAssertTrue(RootNotice.offersRecovery(for: refuse))

        let disparu = FouineError.rootUnreadable(
            path: "/Users/x/Livres", reason: RootProbe.Reason.missing.token)
        XCTAssertFalse(RootNotice.offersRecovery(for: disparu))

        XCTAssertTrue(RootNotice.offersRecovery(
            for: .permissionDenied(path: "/Users/x/Livres")))
        XCTAssertFalse(RootNotice.offersRecovery(for: .wholeDisk))
        XCTAssertFalse(RootNotice.offersRecovery(
            for: FouineError.volumeNotMounted(uuid: "U1")))

        // Le champ voyage jusqu'à l'alerte, et il est FAUX par défaut : une
        // alerte de renommage raté ne propose pas d'ouvrir les Réglages.
        XCTAssertFalse(RootNotice(title: "t", message: "m").offersRecovery)
    }

    /// Le dossier d'Anki choisi pour ses cartes : rien à autoriser dans les
    /// Réglages Système, la case est dans ceux de Fouine — et la phrase le dit,
    /// sans le « ne contient pas de documents » d'un dossier système.
    func testLeDossierDAnkiEnvoieVersLaCaseDeLApplication() {
        let refus = RootPolicy.Refusal.applicationData(
            path: "~/Library/Application Support/Anki2/Matisse", application: .anki)
        XCTAssertTrue(RootNotice.offersApplicationSettings(for: refus))
        XCTAssertFalse(RootNotice.offersRecovery(for: refus))
        XCTAssertFalse(RootNotice.offersApplicationSettings(
            for: .systemTree(path: "~/Library")))
        XCTAssertFalse(RootNotice(title: "t", message: "m").offersApplicationSettings)

        let phrase = RootPolicyText.describe(refus)
        XCTAssertTrue(phrase.contains("Anki"), phrase)
        XCTAssertFalse(phrase.contains("~/Library"), phrase)
    }

    // MARK: - « Depuis votre dernière visite » (UX-06)

    /// Trois cas, et ce sont les cas limites qui comptent : la PREMIÈRE visite
    /// n'annonce rien (sinon Fouine présenterait tout l'index comme une
    /// nouveauté), un compte qui a BAISSÉ n'annonce rien non plus (un dossier
    /// retiré, un index refait), et un compte qui monte annonce l'écart.
    func testDepuisLaDerniereVisite() {
        XCTAssertNil(SinceLastVisit.added(previous: nil, current: 396_364),
                     "première visite : tout l'index n'est pas une nouveauté")
        XCTAssertNil(SinceLastVisit.added(previous: 396_364, current: 396_364),
                     "rien de neuf ne s'annonce pas")
        XCTAssertNil(SinceLastVisit.added(previous: 396_364, current: 12),
                     "un index refait ou un dossier retiré n'est pas une nouvelle")
        XCTAssertEqual(SinceLastVisit.added(previous: 392_164, current: 396_364),
                       4_200)
    }

    // `testLaLegendeSeReferme` a été retiré avec la croix qu'il protégeait
    // (IX2) : la nouvelle vit dans la fenêtre « Votre index », sans croix.
}
