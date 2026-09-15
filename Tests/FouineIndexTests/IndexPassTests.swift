// IndexPassTests.swift — la passe unifiée (audit F2, F3, X3). Propriété : A-Core.
//
// Ce que ces tests protègent, dans l'ordre de l'audit :
//   · une erreur PAR DOCUMENT ne fait pas tomber le lot (piège n°13) ;
//   · une erreur FATALE fait tomber le lot, remonte, et rend le verrou — c'est
//     la divergence n°1 de l'app, qui marquait 1 330 documents `.failed` pour
//     un câble débranché ;
//   · l'écriture de l'état d'un document n'est plus avalée par un `try?`
//     (audit X3) ;
//   · « Annuler » s'arrête vraiment, et rend le verrou ;
//   · `fouine.lock` nomme son détenteur pendant la passe, et est libre après.

import XCTest
import FouineCore
@testable import FouineIndex

final class IndexPassTests: XCTestCase {

    private func options(_ role: LockRole = .cli,
                         budget: Budget = .none,
                         warm: Bool = false) -> IndexPassOptions {
        // `optimize` et `vocab_tri` sont hors sujet ici et coûtent une passe
        // FTS5 complète : les tests qui les veulent le disent.
        IndexPassOptions(crawl: .delta, jobs: 4, budget: budget,
                         optimize: warm, warmVocabulary: warm, role: role)
    }

    // MARK: - Passe nominale

    func testNominalPassExtractsEveryDocument() throws {
        let scratch = try IndexScratch("nominal", documents: 6)
        let observer = RecordingObserver()

        let summary = try IndexPass(store: scratch.store, observer: observer)
            .run(roots: [scratch.rootRecord], options: options(warm: true))

        XCTAssertEqual(summary.stop, .completed)
        XCTAssertEqual(summary.counters.total, 6)
        XCTAssertEqual(summary.counters.extracted, 6)
        XCTAssertEqual(summary.counters.failed, 0)
        XCTAssertEqual(summary.counters.skipped, 0)
        XCTAssertGreaterThan(summary.counters.pages, 0)

        // Un événement par document, ni plus ni moins.
        XCTAssertEqual(observer.documents.count, 6)
        XCTAssertTrue(observer.documents.allSatisfy { $0.kind == .extracted })
        XCTAssertEqual(observer.crawled.map(\.root), ["Jetable"])
        XCTAssertEqual(observer.crawled.first?.summary.added, 6)
        XCTAssertEqual(observer.finishedSummaries.count, 1)

        // Et la base dit la même chose que l'observateur.
        let docs = try scratch.documents()
        XCTAssertEqual(docs.count, 6)
        XCTAssertTrue(docs.allSatisfy { $0.record.state == .extracted })
        XCTAssertTrue(docs.allSatisfy { $0.record.err == nil })
        // `upsertDoc` post-extraction : `n_pages` renseigné. L'app l'oubliait
        // (audit F2), tous ses documents restaient à 0 page.
        XCTAssertTrue(docs.allSatisfy { $0.record.nPages > 0 })
    }

    /// Le second passage n'a plus rien à extraire : le delta est vide, et la
    /// passe le dit sans rien re-marquer.
    func testSecondPassExtractsNothing() throws {
        let scratch = try IndexScratch("idempotence", documents: 3)
        let pass = IndexPass(store: scratch.store)
        _ = try pass.run(roots: [scratch.rootRecord], options: options())
        let again = try pass.run(roots: [scratch.rootRecord], options: options())
        XCTAssertEqual(again.counters.total, 0)
        XCTAssertEqual(again.counters.done, 0)
    }

    // MARK: - Erreur par document

    func testBrokenDocumentFailsAloneAndThePassContinues() throws {
        let scratch = try IndexScratch("par-document", documents: 4, brokenPDFs: 1)
        let observer = RecordingObserver()

        let summary = try IndexPass(store: scratch.store, observer: observer)
            .run(roots: [scratch.rootRecord], options: options())

        XCTAssertEqual(summary.stop, .completed)
        XCTAssertEqual(summary.counters.total, 5)
        XCTAssertEqual(summary.counters.extracted, 4)
        XCTAssertEqual(summary.counters.failed, 1)
        XCTAssertEqual(observer.documents.count, 5)

        let (state, err) = try scratch.state(ofDocumentAt: "casse-0.pdf")
        XCTAssertEqual(state, .failed)
        // `docs.err` porte le motif, et pas une chaîne vide : c'est tout ce que
        // l'utilisateur aura pour comprendre.
        XCTAssertNotNil(err)
        XCTAssertFalse(err?.isEmpty ?? true)
        let failure = try XCTUnwrap(observer.documents.first { $0.kind == .failed })
        XCTAssertEqual(failure.reason, err)
    }

    // MARK: - Erreur fatale

    func testFatalDatabaseErrorStopsThePassAndReleasesTheLock() throws {
        let scratch = try IndexScratch("fatale", documents: 8)
        // La 3e écriture de pages échoue : le lot doit s'arrêter là, et non
        // marquer les cinq suivants `.failed`.
        let store = FailingStore(scratch.store, fail: .replacePages, after: 2)
        let observer = RecordingObserver()

        XCTAssertThrowsError(
            try IndexPass(store: store, observer: observer)
                .run(roots: [scratch.rootRecord], options: options())
        ) { error in
            guard case FouineError.databaseFailure(let message)? = error as? FouineError
            else { return XCTFail("erreur fatale attendue, reçu \(error)") }
            XCTAssertTrue(message.contains("disque plein"), message)
        }

        // Aucun document n'a été marqué en échec : la panne ne les concernait pas.
        let docs = try scratch.documents()
        XCTAssertEqual(docs.filter { $0.record.state == .failed }.count, 0)
        XCTAssertLessThan(docs.filter { $0.record.state == .extracted }.count, 8)
        // Le bilan part quand même — l'app doit pouvoir dire ce qui avait abouti.
        XCTAssertEqual(observer.finishedSummaries.count, 1)
        // Et le verrou est RENDU : c'est tout l'objet du `defer` de F3.
        XCTAssertEqual(scratch.lockContents(), "")
    }

    /// Audit X3 : l'agent avalait l'échec d'écriture d'état par un `try?`, et le
    /// document restait `.discovered` — ré-extrait à chaque salve, indéfiniment.
    /// Une écriture d'état qui échoue est désormais FATALE.
    func testAFailedStateWriteIsFatal() throws {
        let scratch = try IndexScratch("etat", documents: 4)
        let store = FailingStore(scratch.store, fail: .setDocState, after: 0)

        XCTAssertThrowsError(
            try IndexPass(store: store).run(roots: [scratch.rootRecord],
                                            options: options())
        )
        XCTAssertEqual(scratch.lockContents(), "")
    }

    // MARK: - Annulation

    func testCancellationStopsQuicklyAndReleasesTheLock() throws {
        let scratch = try IndexScratch("annulation", documents: 60)
        let stop = Latch()
        let observer = RecordingObserver()
        observer.onDocument = { rank in if rank >= 2 { stop.raise() } }

        let started = Date()
        let summary = try IndexPass(store: scratch.store, observer: observer,
                                    shouldStop: { stop.isRaised })
            .run(roots: [scratch.rootRecord], options: options(warm: true))
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(summary.stop, .cancelled)
        // CE QUE PROUVE CE TEST : la passe s'arrête sur le drapeau, pas au
        // bout du lot. Le compte le dit mieux qu'une horloge — il ne dépend
        // pas de la charge de la machine, alors que le seuil d'une seconde
        // qui figurait ici rougissait sous une autre compilation (1,045 s
        // mesurées pour 1,0 s de seuil, lot BT1). Quatre fils, arrêt demandé
        // au deuxième document : une douzaine de documents au plus peuvent
        // être en vol.
        XCTAssertLessThanOrEqual(summary.counters.done, 12,
                                 "annulation au 2e document sur 60, et "
                                 + "\(summary.counters.done) traités : la passe "
                                 + "ne s'arrête pas sur le drapeau")
        // L'horloge ne sert plus qu'à attraper un BLOCAGE (un verrou attendu,
        // une passe qui va au bout des 60) : seuil très large, exprès.
        XCTAssertLessThan(elapsed, 20, "\(elapsed) s : la passe ne rend pas la main")
        // Les documents non traités restent `.discovered` : la reprise repartira
        // d'ici, rien n'est perdu ni marqué en échec.
        let docs = try scratch.documents()
        XCTAssertEqual(docs.filter { $0.record.state == .failed }.count, 0)
        XCTAssertGreaterThan(docs.filter { $0.record.state == .discovered }.count, 0)
        XCTAssertEqual(scratch.lockContents(), "")
    }

    /// ST1 : l'arrêt entre DANS l'extraction. L'extracteur consulte
    /// `limits.shouldStop` et lève `.cancelled` ; son document ne doit alors
    /// porter AUCUNE trace — ni `.failed`, ni `.extracted`, ni motif dans
    /// `docs.err` —, parce qu'il n'a pas été lu et que la passe suivante doit
    /// le reprendre entier.
    func testADocumentStoppedWhileItIsReadStaysToDo() throws {
        let scratch = try IndexScratch("arret-en-lecture", documents: 2)
        let stop = Latch()
        let registry = StoppableRegistry(stop: stop)
        let observer = RecordingObserver()

        // UN SEUL fil : le second document ne doit pas partir avant que le
        // premier n'ait levé le drapeau, sinon le test mesurerait une course.
        let summary = try IndexPass(store: scratch.store, observer: observer,
                                    shouldStop: { stop.isRaised },
                                    registry: registry)
            .run(roots: [scratch.rootRecord],
                 options: IndexPassOptions(crawl: .delta, jobs: 1,
                                           optimize: false, warmVocabulary: false,
                                           languageBackfillLimit: 0))

        XCTAssertEqual(summary.stop, .cancelled)
        // NON TENTÉ, et non « sauté » : aucun compteur ne bouge.
        XCTAssertEqual(summary.counters.done, 0)
        XCTAssertEqual(summary.counters.failed, 0)
        XCTAssertEqual(summary.counters.skipped, 0)
        XCTAssertEqual(summary.counters.budgetSkipped, 0)

        let docs = try scratch.documents()
        XCTAssertEqual(docs.count, 2)
        for doc in docs {
            XCTAssertEqual(doc.record.state, .discovered, doc.record.relPath)
            XCTAssertNil(doc.record.err, doc.record.relPath)
        }
        XCTAssertEqual(observer.documents.count, 0)
        XCTAssertEqual(observer.started.count, 1)
        XCTAssertEqual(observer.abandoned, observer.started,
                       "le document lâché est celui dont la lecture avait commencé")
        XCTAssertEqual(scratch.lockContents(), "")
    }

    // MARK: - Budget

    func testExhaustedBudgetLeavesEveryDocumentInPlace() throws {
        let scratch = try IndexScratch("budget", documents: 5)
        // Échéance déjà passée : aucune extraction ne doit être tentée.
        let expired = Budget(deadline: Date().addingTimeInterval(-1))

        let summary = try IndexPass(store: scratch.store)
            .run(roots: [scratch.rootRecord], options: options(budget: expired))

        XCTAssertEqual(summary.stop, .budgetExhausted)
        XCTAssertEqual(summary.counters.total, 5)
        XCTAssertEqual(summary.counters.done, 0)
        // `remaining` de `FouineError.budgetExhausted` (§4.3, sortie 4) : les
        // cinq documents sont COMPTÉS, pas seulement le premier rencontré.
        XCTAssertEqual(summary.counters.budgetSkipped, 5)
        let docs = try scratch.documents()
        XCTAssertTrue(docs.allSatisfy { $0.record.state == .discovered })
        XCTAssertEqual(scratch.lockContents(), "")
    }

    // MARK: - Verrou (audit F3)

    func testLockNamesItsHolderDuringThePassAndIsFreeAfter() throws {
        let scratch = try IndexScratch("verrou", documents: 4)
        let seen = Box()
        let observer = RecordingObserver()
        observer.onDocument = { _ in seen.set(scratch.lockContents()) }

        XCTAssertEqual(scratch.lockContents(), "",
                       "un verrou libre ne nomme personne")
        _ = try IndexPass(store: scratch.store, observer: observer)
            .run(roots: [scratch.rootRecord], options: options(.app))

        let during = seen.value
        let holder = try XCTUnwrap(LockHolder.parse(during),
                                   "fouine.lock ne nomme pas son détenteur : \(during)")
        XCTAssertEqual(holder.pid, getpid())
        XCTAssertEqual(holder.role, .app)
        XCTAssertTrue(holder.isAlive)
        XCTAssertTrue(holder.phrase.contains("the app"), holder.phrase)
        XCTAssertTrue(holder.phrase.contains("pid \(getpid())"), holder.phrase)

        XCTAssertEqual(scratch.lockContents(), "",
                       "le verrou n'a pas été rendu en fin de passe (F3)")
    }

    /// Un `fouine.lock` qui nomme un processus mort ne bloque rien — flock est
    /// rendu par le noyau — mais son NOM traînait et aurait accusé un fantôme.
    /// La reprise est tracée.
    func testStaleLockIsTakenOverWithAJournalLine() throws {
        let scratch = try IndexScratch("perime", documents: 2)
        let ghost = LockHolder(pid: try Self.deadPID(), role: .agent,
                               since: Date().addingTimeInterval(-3600))
        XCTAssertFalse(ghost.isAlive)
        try ghost.line.write(to: scratch.lockURL, atomically: true, encoding: .utf8)

        let observer = RecordingObserver()
        _ = try IndexPass(store: scratch.store, observer: observer)
            .run(roots: [scratch.rootRecord], options: options(.cli))

        let note = try XCTUnwrap(observer.notes.first { $0.contains("stale") },
                                 "aucune ligne de journal : \(observer.notes)")
        XCTAssertTrue(note.contains("pid \(ghost.pid)"), note)
        XCTAssertTrue(note.contains("the agent"), note)
        XCTAssertEqual(scratch.lockContents(), "")
    }

    /// Un pid qui n'existe plus : un processus lancé, attendu, et récolté.
    /// Le noyau peut théoriquement le recycler, mais pas dans la milliseconde
    /// qui suit — et un recyclage rendrait le test SÉVÈRE, pas laxiste.
    private static func deadPID() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }
}

// MARK: - Outils

/// Un extracteur qui demande l'arrêt EN COURS DE ROUTE (ST1) : il lève le
/// drapeau à son premier appel, puis constate `limits.shouldStop` et abandonne,
/// exactement comme le fait un PDF entre deux pages ou un média entre deux
/// fenêtres.
final class StoppableRegistry: ExtractorRegistry, @unchecked Sendable {
    static let supportedExtensions: Set<String> = ["txt"]
    let stop: Latch

    init(stop: Latch) { self.stop = stop }

    func extractor(for ext: String) -> (any TextExtractor)? {
        Self.supportedExtensions.contains(ext) ? StoppableExtractor(stop: stop) : nil
    }
}

private struct StoppableExtractor: TextExtractor {
    static let supportedExtensions: Set<String> = []
    let stop: Latch

    func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        stop.raise()
        if limits.shouldStop() { throw FouineError.cancelled }
        return ExtractionResult(pages: [PageText(page: 1, text: "lu", source: .native)],
                                pageCount: 1, ocrCandidates: [], meta: [:])
    }
}

/// Drapeau à sens unique, sûr en concurrence.
final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.lock(); raised = true; lock.unlock() }
    var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
}

/// Première valeur observée, sûre en concurrence.
final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    func set(_ value: String) {
        lock.lock(); if storage.isEmpty { storage = value }; lock.unlock()
    }
    var value: String { lock.lock(); defer { lock.unlock() }; return storage }
}
