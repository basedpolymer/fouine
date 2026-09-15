// OCRRunTests.swift — la pompe, de bout en bout, sur base temporaire.
// Propriété : A-OCR. SPEC §6.2, §6.3, §8.1 T11.
//
// Aucune de ces bases n'est celle de l'utilisateur : chaque test ouvre la sienne
// dans son propre dossier temporaire (donc son propre `fouine.lock`).
// Les lots restent minuscules — quelques pages — pour ne pas fausser les mesures
// que d'autres font sur la même machine.

import XCTest
import CoreGraphics
import FouineCore
@testable import FouineOCR

final class OCRRunTests: XCTestCase {

    // MARK: - Montage

    /// Un document réel sur le disque, enregistré dans l'index avec le vrai UUID
    /// de son volume : sans lui, `nextOCRBatch` ne saurait pas reconstruire le
    /// chemin absolu (il passe par `VolumeResolver`).
    @discardableResult
    private func enroll(_ url: URL, in store: GRDBStore, folder: String = "Tests",
                        pages: [Int], priority: Int = 0) throws -> Int64 {
        let resolved = try VolumeResolver.resolve(path: url)
        // `root add` enregistre le volume ; les tests font de même, sinon la
        // résolution d'un `rel_path` seul (sans volume) n'a rien à interroger.
        try store.registerVolume(uuid: resolved.volUUID, label: resolved.volLabel)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let docID = try store.upsertDoc(DocRecord(
            volUUID: resolved.volUUID, relPath: resolved.relPath,
            ext: url.pathExtension.lowercased(), topFolder: folder,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            mtime: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            nPages: pages.count, state: .extracted))
        try store.enqueueOCR(docID: docID, pages: pages, priority: priority)
        return docID
    }

    /// Un PDF d'une page par entrée. Chaque page porte AU MOINS 20 caractères :
    /// sous ce seuil, `completeOCR` enregistre la page comme traitée mais vide
    /// (§6.2) — ce qui est le comportement voulu, et rendrait le test trompeur.
    private func makePDF(in directory: TempDirectory, name: String,
                         words: [String]) throws -> URL {
        let url = directory.file(name)
        try OCRTestSupport.writePDF(words.map { word in
            OCRTestSupport.PageSpec(width: 595, height: 500) { context in
                OCRTestSupport.drawText(word, in: context, at: CGPoint(x: 40, y: 320),
                                        size: 44)
                OCRTestSupport.drawText("page de controle Fouine", in: context,
                                        at: CGPoint(x: 40, y: 220), size: 40)
            }
        }, to: url)
        return url
    }

    private func queueLength(_ store: GRDBStore) throws -> Int {
        try store.stats()["ocr_queue_len"] ?? -1
    }

    // MARK: - completeOCR de bout en bout

    /// Une page OCRisée doit devenir cherchable, son layout relisible, et sortir
    /// de la file. C'est le contrat de `completeOCR` (§4.1, §6.2) vu depuis le
    /// module qui l'appelle.
    func testCompleteOCRMakesPageSearchable() throws {
        let temp = try TempStore()
        let store = temp.store
        let directory = try TempDirectory()
        let pdf = try makePDF(in: directory, name: "synthese.pdf", words: ["ignoré"])
        let docID = try enroll(pdf, in: store, pages: [1])
        XCTAssertEqual(try queueLength(store), 1)

        let lines = [
            OCRLine(text: "Chromatographie sur couche mince",
                    x: 0.10, y: 0.82, w: 0.62, h: 0.021, confidence: 0.97),
            OCRLine(text: "bruit illisible", x: 0.10, y: 0.10, w: 0.20, h: 0.02,
                    confidence: 0.05),   // sous le seuil : layout oui, page_fts non
        ]
        let retained = lines.filter { $0.confidence >= VisionOCREngine.confidenceThreshold }
        let result = OCRPage(
            text: retained.map(\.text).joined(separator: "\n"),
            lines: lines, level: .accurate, seconds: 1.5, engine: .vision,
            engineRev: "vision-rev3",
            meanConfidence: retained.reduce(0.0) { $0 + $1.confidence }
                / Double(retained.count))
        try store.completeOCR(docID: docID, page: 1, result: result)

        // File décrémentée, document marqué fini.
        XCTAssertEqual(try queueLength(store), 0)
        XCTAssertEqual(try store.docRow(id: docID)?.record.ocrState, .done)

        // Page cherchable, et marquée OCR `.accurate` (D1).
        let stats = try store.stats()
        XCTAssertEqual(stats["pages_ocr_accurate"], 1)
        let results = try store.search(SearchQuery(fts: "chromatographie", fuzzy: .off))
        XCTAssertEqual(results.hits.count, 1)
        XCTAssertEqual(results.hits.first?.page, 1)
        XCTAssertEqual(results.hits.first?.source, .ocrAccurate)

        // Layout relisible, TOUTES les lignes conservées (surlignage complet).
        let layout = try store.ocrLayout(docID: docID, page: 1)
        XCTAssertEqual(layout?.count, 2)
        XCTAssertEqual(layout?.first?.text, "Chromatographie sur couche mince")
        XCTAssertEqual(layout?.first?.y ?? 0, 0.82, accuracy: 1e-9)
        // La ligne rejetée n'a pas alimenté page_fts.
        let noise = try store.search(SearchQuery(fts: "illisible", fuzzy: .off))
        XCTAssertTrue(noise.hits.isEmpty)
    }

    // MARK: - Run complet

    /// La pompe entière : rendu -> Vision -> `completeOCR`, sur deux pages.
    func testRunProcessesQueue() throws {
        let temp = try TempStore()
        let store = temp.store
        let directory = try TempDirectory()
        let pdf = try makePDF(in: directory, name: "corpus.pdf",
                              words: ["Markovnikov", "tellurium"])
        try enroll(pdf, in: store, pages: [1, 2])

        let outcome = try OCRRun.run(store: store, jobs: 2, budgetSeconds: nil,
                                     prioFolder: nil, only: nil, log: { _ in })
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(try queueLength(store), 0)

        let stats = try store.stats()
        XCTAssertEqual(stats["pages_ocr_accurate"], 2)

        let hits = try store.search(SearchQuery(fts: "markovnikov", fuzzy: .off))
        XCTAssertEqual(hits.hits.first?.page, 1, "texte reconnu introuvable")
        XCTAssertEqual(hits.hits.first?.source, .ocrAccurate)
        let second = try store.search(SearchQuery(fts: "tellurium", fuzzy: .off))
        XCTAssertEqual(second.hits.first?.page, 2)
    }

    /// Piège n°13 : un fichier illisible ne fait pas tomber le lot. La page part
    /// en échec, la suivante est traitée, et `attempts` s'incrémente (§6.3).
    func testUnreadableFileDoesNotStopTheBatch() throws {
        let temp = try TempStore()
        let store = temp.store
        let directory = try TempDirectory()

        let broken = directory.file("casse.pdf")
        try Data("%PDF-1.4 pas un PDF".utf8).write(to: broken)
        try enroll(broken, in: store, folder: "Tests", pages: [1], priority: 0)

        let good = try makePDF(in: directory, name: "bon.pdf", words: ["Markovnikov"])
        try enroll(good, in: store, folder: "Tests", pages: [1], priority: 1)

        let outcome = try OCRRun.run(store: store, jobs: 1, budgetSeconds: nil,
                                     prioFolder: nil, only: nil, log: { _ in })
        XCTAssertEqual(outcome, .completed)
        // La bonne page est passée…
        XCTAssertEqual(try store.stats()["pages_ocr_accurate"], 1)
        // …et la mauvaise a été abandonnée après 3 tentatives, file vide.
        XCTAssertEqual(try queueLength(store), 0)
    }

    // MARK: - Budget (T11)

    /// `--budget-minutes` : à l'échéance, la file reste INTACTE et le run rend
    /// `.budgetExhausted` — que la CLI traduit en sortie 4 (§4.3, T11).
    func testBudgetLeavesQueueIntact() throws {
        let temp = try TempStore()
        let store = temp.store
        let directory = try TempDirectory()
        let pdf = try makePDF(in: directory, name: "budget.pdf",
                              words: ["Markovnikov", "tellurium", "chromatographie"])
        let docID = try enroll(pdf, in: store, pages: [1, 2, 3])
        XCTAssertEqual(try queueLength(store), 3)

        // Le préchauffage mange le budget (tolérance explicite de T11) : à
        // l'ouverture de la file, l'échéance est déjà passée.
        let outcome = try OCRRun.run(store: store, jobs: 4, budgetSeconds: 0.001,
                                     prioFolder: nil, only: nil, log: { _ in })
        XCTAssertEqual(outcome, .budgetExhausted)
        XCTAssertEqual(try queueLength(store), 3, "la file doit rester intacte")
        XCTAssertEqual(try store.docRow(id: docID)?.record.ocrState, .queued)
        XCTAssertEqual(try store.stats()["pages_ocr_accurate"], 0)
    }

    /// Un budget qui expire sur une file DÉJÀ vide n'est pas une interruption.
    func testEmptyQueueCompletesEvenWithBudget() throws {
        let temp = try TempStore()
        let outcome = try OCRRun.run(store: temp.store, jobs: 4, budgetSeconds: 0.001,
                                     prioFolder: nil, only: nil, log: { _ in })
        XCTAssertEqual(outcome, .completed)
    }

    // MARK: - --only

    func testOnlyAcceptsAbsolutePathAndRelPath() throws {
        let temp = try TempStore()
        let store = temp.store
        let directory = try TempDirectory()
        let pdf = try makePDF(in: directory, name: "cible.pdf", words: ["Markovnikov"])
        let docID = try enroll(pdf, in: store, pages: [1])
        let resolved = try VolumeResolver.resolve(path: pdf)

        XCTAssertEqual(try OCRRun.resolveDocument(pdf.path, store: store), docID)
        XCTAssertEqual(try OCRRun.resolveDocument(resolved.relPath, store: store),
                       docID)
    }

    func testOnlyRejectsUnknownDocument() throws {
        let temp = try TempStore()
        XCTAssertThrowsError(
            try OCRRun.resolveDocument("/tmp/inexistant-fouine.pdf", store: temp.store)
        ) { error in
            guard case FouineError.ocr = error else {
                return XCTFail("attendu .ocr, reçu \(error)")
            }
        }
    }

    /// Document connu mais SANS page en file : message clair et sortie normale.
    func testOnlyWithNothingQueuedIsNotAnError() throws {
        let temp = try TempStore()
        let store = temp.store
        let directory = try TempDirectory()
        let pdf = try makePDF(in: directory, name: "deja-fait.pdf", words: ["a"])
        let docID = try enroll(pdf, in: store, pages: [1])
        try store.completeOCR(docID: docID, page: 1, result: OCRPage(
            text: "déjà fait", lines: [], level: .accurate, seconds: 0,
            engine: .vision, engineRev: "vision-rev3", meanConfidence: 1))
        XCTAssertEqual(try queueLength(store), 0)

        // Boîte verrouillée plutôt qu'une variable capturée : le journal est
        // appelé depuis les fils de la pompe, et Swift 6 refuse la mutation
        // d'une `var` capturée dans une fermeture concurrente (audit X4).
        final class Journal: @unchecked Sendable {
            private let lock = NSLock()
            private var lines: [String] = []
            func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
            var messages: [String] { lock.lock(); defer { lock.unlock() }; return lines }
        }
        let journal = Journal()
        let outcome = try OCRRun.run(store: store, jobs: 1, budgetSeconds: nil,
                                     prioFolder: nil, only: pdf.path,
                                     log: { journal.append($0) })
        XCTAssertEqual(outcome, .completed)
        let messages = journal.messages
        XCTAssertTrue(messages.contains { $0.contains("no page queued") },
                      "messages : \(messages)")
    }

    func testOnlyProcessesOneDocumentOnly() throws {
        let temp = try TempStore()
        let store = temp.store
        let directory = try TempDirectory()
        let target = try makePDF(in: directory, name: "cible.pdf",
                                 words: ["Markovnikov"])
        let other = try makePDF(in: directory, name: "autre.pdf", words: ["tellurium"])
        try enroll(target, in: store, pages: [1])
        try enroll(other, in: store, pages: [1])

        let outcome = try OCRRun.run(store: store, jobs: 1, budgetSeconds: nil,
                                     prioFolder: nil, only: target.path,
                                     log: { _ in })
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(try queueLength(store), 1, "l'autre document reste en file")
        XCTAssertEqual(try store.stats()["pages_ocr_accurate"], 1)
    }

    // MARK: - --prio-folder

    /// `--prio-folder` réordonne la CONSOMMATION : il ne réécrit jamais `prio`.
    func testPrioFolderSelectsWithoutRewritingPriorities() throws {
        let temp = try TempStore()
        let store = temp.store
        let directory = try TempDirectory()
        let books = try makePDF(in: directory, name: "livre.pdf", words: ["a", "b"])
        let notes = try makePDF(in: directory, name: "notes.pdf", words: ["c"])
        try enroll(books, in: store, folder: "Livres", pages: [1, 2], priority: 2)
        let notesID = try enroll(notes, in: store, folder: "Cours", pages: [1],
                                 priority: 3)

        let selected = try OCRRun.queuedItems(store: store, inFolder: "Cours")
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.docID, notesID)
        XCTAssertEqual(selected.first?.path, notes.path)

        // Les priorités en base sont inchangées : 2 pages à prio 2, 1 à prio 3.
        let pending = try store.pendingOCRPages(limit: 100)
        XCTAssertEqual(pending.filter { $0.prio == 2 }.count, 2)
        XCTAssertEqual(pending.filter { $0.prio == 3 }.count, 1)

        // Et un run complet avec ce dossier prioritaire vide bien toute la file.
        let outcome = try OCRRun.run(store: store, jobs: 2, budgetSeconds: nil,
                                     prioFolder: "Cours", only: nil, log: { _ in })
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(try queueLength(store), 0)
    }

    func testPrioFolderUnknownIsHarmless() throws {
        let temp = try TempStore()
        let store = temp.store
        let directory = try TempDirectory()
        let pdf = try makePDF(in: directory, name: "seul.pdf", words: ["Markovnikov"])
        try enroll(pdf, in: store, folder: "Livres", pages: [1])

        let outcome = try OCRRun.run(store: store, jobs: 1, budgetSeconds: nil,
                                     prioFolder: "Inexistant", only: nil,
                                     log: { _ in })
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(try queueLength(store), 0)
    }

    // MARK: - Concurrence et garde-fou

    /// §6.3 : 8 fils sont une régression mesurée. La demande est RAMENÉE à 4,
    /// avec un avertissement — jamais refusée.
    func testJobsAreCappedAtFour() {
        var messages: [String] = []
        XCTAssertEqual(OCRRun.clampJobs(8, log: { messages.append($0) }), 4)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("REGRESSION"), messages[0])

        messages.removeAll()
        XCTAssertEqual(OCRRun.clampJobs(4, log: { messages.append($0) }), 4)
        XCTAssertEqual(OCRRun.clampJobs(1, log: { messages.append($0) }), 1)
        XCTAssertTrue(messages.isEmpty)
        XCTAssertEqual(OCRRun.clampJobs(0, log: { messages.append($0) }), 1)
        XCTAssertEqual(OCRRun.maxJobs, 4)
    }

    /// Piège n°4 : la grandeur surveillée est `CPU_Speed_Limit`, lue dans la
    /// sortie de `pmset -g therm`.
    func testThermalParsing() {
        let sample = """
        Note: No thermal warning level has been recorded
        2026-08-31 20:01:34 +0200 CPU Power notify
        \tCPU_Scheduler_Limit \t= 100
        \tCPU_Available_CPUs \t= 8
        \tCPU_Speed_Limit \t= 46
        """
        XCTAssertEqual(ThermalGovernor.parseSpeedLimit(sample), 46)
        XCTAssertNil(ThermalGovernor.parseSpeedLimit("rien à voir"))
        XCTAssertNil(ThermalGovernor.parseSpeedLimit("CPU_Speed_Limit = beaucoup"))
        // Seuils de la spec, pour qu'un réglage distrait se voie tout de suite.
        XCTAssertEqual(ThermalGovernor.reduceBelow, 70)
        XCTAssertEqual(ThermalGovernor.suspendBelow, 50)
        XCTAssertEqual(ThermalGovernor.throttledConcurrency, 2)
        XCTAssertEqual(ThermalGovernor.sampleInterval, 30)
    }

    /// Le portillon doit relâcher les fils quand le run est annulé, sinon un
    /// budget épuisé pendant une suspension thermique bloquerait la sortie.
    func testGovernorReleasesWorkersOnCancel() {
        let governor = ThermalGovernor(nominalConcurrency: 1, log: { _ in })
        governor.cancel()
        XCTAssertTrue(governor.isCancelled)
        XCTAssertFalse(governor.admit(worker: 3))
    }

    /// Une suspension thermique doublée d'un budget ne doit pas figer le run :
    /// le portillon rend la main à l'échéance. Le fil n°3 d'un run à 1 fil est
    /// hors quota, donc en attente — l'équivalent exact d'une suspension.
    func testGovernorReleasesWorkersAtDeadline() {
        let governor = ThermalGovernor(nominalConcurrency: 1, log: { _ in })
        let deadline = Date().addingTimeInterval(0.6)
        let started = Date()
        XCTAssertFalse(governor.admit(worker: 3, deadline: deadline))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "le portillon doit rendre la main à l'échéance")
    }

    /// `pmset` réellement lu sur cette machine : la valeur doit être un
    /// pourcentage plausible, ou nil (et le run continue alors sans garde-fou).
    func testThermalProbeOnThisMachine() {
        guard let limit = ThermalGovernor.cpuSpeedLimit() else {
            return  // pas de pmset : le garde-fou se désarme, c'est prévu
        }
        XCTAssertTrue((1...100).contains(limit), "CPU_Speed_Limit = \(limit)")
    }
}
