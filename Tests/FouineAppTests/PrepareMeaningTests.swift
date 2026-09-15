// PrepareMeaningTests.swift — « Préparer la recherche par le sens » depuis
// l'application (UX-12). Propriété : A-App. SPEC §12.
//
// C'était la DERNIÈRE dépendance au Terminal : l'onglet des réglages demandait
// de copier `fouine embed`, d'ouvrir Terminal, de coller, d'appuyer sur Entrée
// — après avoir installé, depuis un autre onglet, l'outil en ligne de commande.
// Le moteur savait déjà tout faire (`EmbedRun.run` est budgété, reprenable,
// annulable) ; ce qui manquait était l'adaptateur.
//
// Ce qui se teste ici : la PASSE (état terminal cohérent, pages réellement
// préparées), les PHRASES de fin (pures, donc éprouvées cas par cas sans
// modèle) et les COMPTES que la feuille affiche. Les vues, elles, ne se testent
// pas.

import XCTest
import FouineCore
import FouineEmbed
@testable import FouineApp

@MainActor
final class PrepareMeaningTests: XCTestCase {

    // MARK: - La passe

    /// Une passe complète sur deux pages : elle se termine, elle dit ce
    /// qu'elle a fait, et les pages sont RÉELLEMENT prêtes ensuite.
    func testAPassPreparesTheSeededPages() async throws {
        guard try SharedModel.encoder() != nil else {
            throw XCTSkip("modèle e5-small absent — `fouine model download` "
                          + "l'installe (220 Mo)")
        }
        let db = try TempAppDB()
        try db.addDoc(relPath: "chimie.txt", pages: [
            String(repeating: "L'énergie libre de Gibbs gouverne la spontanéité "
                              + "des transformations chimiques. ", count: 4),
            String(repeating: "La cinétique fixe la vitesse à laquelle "
                              + "l'équilibre est atteint. ", count: 4),
        ])
        XCTAssertEqual(try db.store.completeVectorPageCount(), 0)

        let service = IndexingService(store: db.store)
        let final = await service.runEmbed(budgetMinutes: nil, progress: { _ in })

        XCTAssertFalse(final.running, "la passe rend un état terminal")
        XCTAssertEqual(final.activity, .preparingMeaning,
                       "la carte « Index » et la barre des menus lisent CE cas")
        XCTAssertFalse(final.cancelled)
        XCTAssertNil(final.error, final.error ?? "")
        XCTAssertNotNil(final.summary, "une passe finie dit ce qu'elle a fait")
        XCTAssertEqual(final.total, 2, "le reste-à-faire relevé au départ")
        XCTAssertEqual(final.done, 2)
        XCTAssertEqual(try db.store.completeVectorPageCount(), 2,
                       "les deux pages portent leur sentinelle de complétude")
        // Le débit est enregistré comme le fait la CLI : c'est ce qui permet à
        // la feuille d'annoncer « environ N h de travail » la fois suivante.
        XCTAssertNotNil(try db.store.embedForecast().windowsPerSecond,
                        "le débit de la passe est gardé en base")
    }

    /// Le geste de l'interface, de bout en bout : la feuille s'ouvre sur la
    /// passe, l'état publié dit « préparation », et la fin est propre.
    func testStartPrepareMeaningAnnouncesItselfInTheSheet() async throws {
        guard try SharedModel.encoder() != nil else {
            throw XCTSkip("modèle e5-small absent — `fouine model download` "
                          + "l'installe (220 Mo)")
        }
        let db = try TempAppDB()
        try db.addDoc(relPath: "note.txt", pages: [
            String(repeating: "Une note assez longue pour mériter un vecteur. ",
                   count: 5),
        ])
        let app = AppModel(service: db.service)

        app.startPrepareMeaning(budgetMinutes: nil)
        XCTAssertTrue(app.indexing.running)
        XCTAssertEqual(app.indexing.activity, .preparingMeaning)
        XCTAssertEqual(app.sheet, .indexing,
                       "la passe s'annonce dans l'UNIQUE feuille (A10.6)")
        // Ce que la carte « Index » et la barre des menus liront : le cas
        // `.working(.preparingMeaning)` est déjà habillé par `IndexStatusText`
        // (pictogramme, phrase) — ici on vérifie que l'activité est bien celle
        // qui l'y conduit, l'évaluateur étant testé à part.
        XCTAssertEqual(
            IndexStatusText.name(app.indexing.activity),
            IndexStatusText.name(.preparingMeaning))

        // Le geste « Continuer en arrière-plan » : une affectation, et la
        // passe continue (A2-07).
        app.sheet = nil
        let deadline = Date().addingTimeInterval(60)
        while app.indexing.running, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(app.indexing.running, "la passe s'est terminée")
        XCTAssertNil(app.sheet, "la fin de passe ne rouvre pas la feuille")
        XCTAssertEqual(app.indexing.activity, .preparingMeaning)
    }

    /// Deux passes ne peuvent pas se chevaucher : `startPrepareMeaning` ne
    /// double pas une passe en cours — le verrou d'écriture est unique.
    func testASecondPassIsRefusedWhileOneRuns() throws {
        let db = try TempAppDB()
        let app = AppModel(service: db.service)
        app.indexing = IndexingState(running: true, activity: .readingScans)
        app.startPrepareMeaning(budgetMinutes: 30)
        XCTAssertEqual(app.indexing.activity, .readingScans,
                       "la passe en cours n'est pas écrasée")
    }

    // MARK: - Les comptes de la feuille

    func testReadinessCountsThePagesLeft() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "a.txt", pages: ["une page", "une autre"])
        let app = AppModel(service: db.service)

        await app.refreshMeaningReadiness()
        let meaning = try XCTUnwrap(app.meaning)
        XCTAssertEqual(meaning.total, 2)
        XCTAssertEqual(meaning.ready, 0)
        XCTAssertEqual(meaning.left, 2)
        XCTAssertFalse(meaning.isComplete)
        // Aucune passe n'a tourné : on n'invente pas une durée.
        XCTAssertNil(meaning.remainingHours)
    }

    /// Un index vide n'est pas « entièrement prêt » : ce serait annoncer une
    /// recherche par le sens qui ne rendrait jamais rien.
    func testAnEmptyIndexIsNotComplete() {
        let empty = AppModel.MeaningReadiness(ready: 0, total: 0,
                                              remainingHours: nil)
        XCTAssertFalse(empty.isComplete)
        XCTAssertEqual(empty.left, 0)
        let done = AppModel.MeaningReadiness(ready: 12, total: 12,
                                             remainingHours: nil)
        XCTAssertTrue(done.isComplete)
    }

    // MARK: - Les phrases de fin (pures)

    func testTheSummarySaysWhatHappenedWithoutJargon() {
        let finished = IndexingService.embedSummary(
            failure: nil, cancelled: false, prepared: 2_000, left: 0)
        let partial = IndexingService.embedSummary(
            failure: nil, cancelled: false, prepared: 1_200, left: 42_000)
        let stopped = IndexingService.embedSummary(
            failure: nil, cancelled: true, prepared: 30, left: 42_000)
        let unknown = IndexingService.embedSummary(
            failure: nil, cancelled: false, prepared: 30, left: nil)
        let broken = IndexingService.embedSummary(
            failure: "disk full", cancelled: false, prepared: 0, left: nil)

        // Aucune de ces phrases ne parle de vecteur, d'embedding ni de commande
        // (CLAUDE.md, PLAN.md § 2).
        for sentence in [finished, partial, stopped, unknown, broken] {
            for banned in ["vector", "vecteur", "embed", "fouine ", "terminal"] {
                XCTAssertFalse(sentence.lowercased().contains(banned),
                               "« \(banned) » est encore là : \(sentence)")
            }
            XCTAssertFalse(sentence.isEmpty)
        }
        // Une passe finie le DIT ; une passe arrêtée dit que rien n'est perdu.
        XCTAssertTrue(finished.contains("ready"), finished)
        XCTAssertTrue(stopped.lowercased().contains("nothing is lost"), stopped)
        XCTAssertTrue(broken.lowercased().contains("nothing is lost"), broken)
        XCTAssertNotEqual(partial, finished)
    }

    // MARK: - Les libellés de la feuille

    /// Le budget par défaut est de 30 minutes, comme l'OCR (A2-07) : une
    /// campagne complète se compte en dizaines d'heures, et un bouton radio
    /// pré-sélectionné n'a pas à décider de bloquer la machine pour la nuit.
    func testDefaultBudgetIsThirtyMinutes() {
        XCTAssertEqual(PrepareMeaningSheet.defaultBudgetMinutes, 30)
        XCTAssertEqual(PrepareMeaningSheet.defaultBudgetMinutes,
                       OCRPromptSheet.defaultBudgetMinutes,
                       "les deux travaux longs se proposent de la même façon")
    }

    /// Le titre de la feuille nomme CE QUI TOURNE : la même feuille sert les
    /// trois travaux.
    func testTheSheetTitleNamesTheRunningJob() {
        XCTAssertEqual(
            IndexingSheet.title(IndexingState(running: true, activity: .preparingMeaning)),
            IndexStatusText.name(.preparingMeaning))
        XCTAssertEqual(
            IndexingSheet.title(IndexingState(running: true, activity: .readingScans)),
            IndexStatusText.name(.readingScans))
        XCTAssertNotEqual(
            IndexingSheet.title(IndexingState(running: false, activity: .preparingMeaning)),
            IndexStatusText.name(.preparingMeaning),
            "au repos, la feuille ne prétend pas qu'un travail tourne")
    }

    /// « environ 30 h de travail » : une DURÉE annoncée avant de lancer, à
    /// distinguer du temps restant d'un travail en cours.
    func testWorkloadIsSaidInHoursThenInDays() {
        XCTAssertEqual(IndexStatusText.workload(hours: 0.4),
                       IndexStatusText.workload(hours: 0.9),
                       "sous l'heure, on ne chiffre pas")
        let thirty = IndexStatusText.workload(hours: 29.6)
        XCTAssertTrue(thirty.contains("30"), thirty)
        let week = IndexStatusText.workload(hours: 24 * 7)
        XCTAssertTrue(week.contains("7"), week)
        for sentence in [thirty, week] {
            XCTAssertFalse(sentence.contains(":"), sentence)
        }
    }
}
