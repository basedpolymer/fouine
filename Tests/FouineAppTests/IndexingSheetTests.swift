// IndexingSheetTests.swift — la feuille d'indexation ne prend plus la fenêtre
// en otage (A2-07). Propriété : A-App. SPEC §5.6.
//
// Une feuille SwiftUI est MODALE à la fenêtre : tant qu'elle est présentée,
// l'application entière — recherche comprise — est inutilisable. Avec un
// budget d'OCR par défaut « sans limite » sur une file de vingt mille pages,
// cela faisait une vingtaine d'heures de fenêtre bloquée, dont le seul geste
// offert était « Annuler ».
//
// Ce qui se teste ici est l'ÉTAT, pas la vue : la feuille se ferme
// (`sheet == nil`), la passe continue (`indexing.running`), et à la fin elle
// ne se rouvre pas toute seule.

import XCTest
import FouineCore
@testable import FouineApp

@MainActor
final class IndexingSheetTests: XCTestCase {

    /// Attend la fin de la passe sans monopoliser le fil principal : les
    /// publications d'état sont des `Task { @MainActor }`.
    private func waitUntilIdle(_ app: AppModel, timeout: TimeInterval = 20,
                               file: StaticString = #filePath,
                               line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !app.indexing.running { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("la passe ne s'est pas terminée en \(timeout) s", file: file, line: line)
    }

    /// « Continuer en arrière-plan » ferme la feuille SANS arrêter la passe,
    /// et la fin de passe ne rouvre rien.
    func testContinueInBackgroundKeepsThePassRunning() async throws {
        let db = try TempAppDB()
        let app = AppModel(service: db.service)

        app.startIndexing()
        XCTAssertTrue(app.indexing.running)
        XCTAssertEqual(app.sheet, .indexing, "la passe s'annonce dans la feuille")

        // Le geste du bouton « Continuer en arrière-plan » : une affectation.
        app.sheet = nil
        XCTAssertTrue(app.indexing.running,
                      "A2-07 : fermer la feuille n'arrête pas le travail")

        await waitUntilIdle(app)
        XCTAssertFalse(app.indexing.running)
        XCTAssertNil(app.sheet,
                     "A2-07 : la fin de passe ne rouvre pas la feuille")
    }

    /// L'état terminal reste lisible : la barre latérale n'affiche plus son
    /// bloc, et « Indexer maintenant » redevient cliquable.
    func testPassEndsCleanlyWithoutASheet() async throws {
        let db = try TempAppDB()
        let app = AppModel(service: db.service)
        app.startIndexing()
        app.sheet = nil
        await waitUntilIdle(app)
        XCTAssertFalse(app.indexing.running)
        XCTAssertNil(app.indexing.error)
        XCTAssertNotNil(app.indexing.summary,
                        "une passe finie dit ce qu'elle a fait")
    }

    /// ST1 : la phrase d'un arrêt NOMME ce qu'on attend. Un seul document en
    /// vol, on le nomme ; plusieurs, on les compte ; aucun, on garde la phrase
    /// du clic — « Stop » ne doit jamais laisser croire qu'il n'a rien fait.
    func testStoppingPhraseNamesWhatIsAwaited() {
        XCTAssertEqual(IndexingService.stoppingPhrase(["cours.mp4"]),
                       String(localized: "Stopping — finishing “cours.mp4”…"))
        XCTAssertEqual(IndexingService.stoppingPhrase(["a.pdf", "b.mp4", "c.docx"]),
                       String(localized: "Stopping — \(3) document(s) are finishing…"))
        XCTAssertEqual(IndexingService.stoppingPhrase([]),
                       String(localized: "cancelling…"))
    }

    /// Et le clic se voit TOUT DE SUITE : le bouton de la carte se désarme sans
    /// attendre que la passe ait rendu la main.
    func testCancellingMarksTheStateStopping() async throws {
        let db = try TempAppDB()
        let app = AppModel(service: db.service)
        app.startIndexing()
        XCTAssertFalse(app.indexing.cancelled)

        app.cancelIndexing()
        XCTAssertTrue(app.indexing.cancelled,
                      "le bouton « Stop » doit se désarmer au clic, pas à la fin")
        await waitUntilIdle(app)
    }

    /// Le budget d'OCR par défaut est de 30 minutes, plus « sans limite ».
    /// Le test lit la même valeur que le bouton radio pré-sélectionné.
    func testDefaultOCRBudgetIsThirtyMinutes() {
        XCTAssertEqual(OCRPromptSheet.defaultBudgetMinutes, 30,
                       "A2-07 : « sans limite » par défaut bloquait la machine pour la nuit")
    }

    /// BU-12 : la même phrase servait pour cinq pages — douze secondes
    /// mesurées — et pour quatre cent mille. « Occupe le Mac un bon moment :
    /// branchez-le sur secteur » devant cinq pages fait renoncer à un geste
    /// sans risque.
    func testAShortQueueIsNotAnnouncedAsAnEvening() {
        XCTAssertEqual(OCRPromptText.effort(queued: 5),
                       String(localized: "Reading them takes a few minutes."))
        XCTAssertEqual(OCRPromptText.effort(queued: OCRPromptText.shortQueue - 1),
                       String(localized: "Reading them takes a few minutes."))

        let long = String(localized: "Reading them keeps the Mac busy for a while: plug it in. You can stop at any time and resume later.")
        XCTAssertEqual(OCRPromptText.effort(queued: OCRPromptText.shortQueue), long)
        XCTAssertEqual(OCRPromptText.effort(queued: 400_000), long)
    }
}
