// IgnoreRulesTests.swift — `.fouineignore` (lot IG1, constat PM-01).
// Propriété : A-Ingest.
//
// Deux classes, deux niveaux : la RÈGLE PURE (chaque forme, la casse, les
// accents, le commentaire, la négation refusée), puis le CRAWL sur une
// arborescence réelle — parce que la conséquence qui compte n'est pas qu'un
// prédicat rende `true`, c'est qu'un document déjà indexé SORTE de l'index avec
// ses pages et ses vecteurs quand l'utilisateur l'exclut.

import XCTest
import FouineCore
@testable import FouineCrawl

final class IgnoreRulesTests: XCTestCase {

    // MARK: - Les trois formes

    func testSubtreeRuleExcludesTheFolderAndEverythingUnderIt() {
        let rules = IgnoreRules(text: "Santé/\nA/B/\n")
        XCTAssertEqual(rules.count, 2)
        XCTAssertTrue(rules.matches(relPath: "Santé", isDirectory: true))
        XCTAssertTrue(rules.matches(relPath: "Santé/analyses.pdf", isDirectory: false))
        XCTAssertTrue(rules.matches(relPath: "Santé/2025/bilan.pdf", isDirectory: false))
        XCTAssertTrue(rules.matches(relPath: "A/B", isDirectory: true))
        XCTAssertTrue(rules.matches(relPath: "A/B/note.md", isDirectory: false))
        // Ce qui est À CÔTÉ reste indexé : une règle de chemin ne vaut que pour
        // le chemin qu'elle nomme.
        XCTAssertFalse(rules.matches(relPath: "A/C/note.md", isDirectory: false))
        XCTAssertFalse(rules.matches(relPath: "Cours/Santé publique.pdf",
                                     isDirectory: false))
        // `Santé/` porte le `/` final : elle ne désigne QU'UN DOSSIER. Un
        // fichier qui porterait ce nom exact reste indexé.
        XCTAssertFalse(rules.matches(relPath: "Santé", isDirectory: false))
    }

    func testPathRuleWithoutSlashDesignatesThatFileOrFolder() {
        let rules = IgnoreRules(text: "Cours/INDEX.md\n")
        XCTAssertTrue(rules.matches(relPath: "Cours/INDEX.md", isDirectory: false))
        XCTAssertFalse(rules.matches(relPath: "INDEX.md", isDirectory: false))
        XCTAssertFalse(rules.matches(relPath: "Cours/TD 3.pdf", isDirectory: false))
    }

    func testExtensionRuleAppliesEverywhereUnderTheRoot() {
        let rules = IgnoreRules(text: "*.md\n")
        XCTAssertTrue(rules.matches(relPath: "notes.md", isDirectory: false))
        XCTAssertTrue(rules.matches(relPath: "M2SU/Cours/INDEX.md", isDirectory: false))
        XCTAssertFalse(rules.matches(relPath: "M2SU/Cours/TD 3.pdf", isDirectory: false))
        // Le motif porte sur le NOM, pas sur le chemin : un dossier nommé
        // « archives.md.old » n'est pas un `.md`.
        XCTAssertFalse(rules.matches(relPath: "archives.md.old", isDirectory: true))
    }

    func testNameRuleMatchesTheNameAnywhere() {
        let rules = IgnoreRules(text: "INDEX.md\n*brouillon*\n")
        XCTAssertTrue(rules.matches(relPath: "INDEX.md", isDirectory: false))
        XCTAssertTrue(rules.matches(relPath: "a/b/c/INDEX.md", isDirectory: false))
        XCTAssertTrue(rules.matches(relPath: "Cours/brouillon 2.docx",
                                    isDirectory: false))
        XCTAssertTrue(rules.matches(relPath: "Brouillons", isDirectory: true))
        XCTAssertFalse(rules.matches(relPath: "Cours/index.html", isDirectory: false))
    }

    // MARK: - Casse et accents (APFS, et le NFD collé d'un terminal)

    func testRulesIgnoreCaseAndAccents() {
        let rules = IgnoreRules(text: "Santé/\n*.MD\n")
        XCTAssertTrue(rules.matches(relPath: "sante/bilan.pdf", isDirectory: false))
        XCTAssertTrue(rules.matches(relPath: "SANTÉ/bilan.pdf", isDirectory: false))
        // La même chaîne en forme DÉCOMPOSÉE — ce que rend l'énumérateur de
        // FileManager sur un volume HFS+, et ce qu'on colle depuis `ls`.
        let decomposed = "Santé/bilan.pdf".decomposedStringWithCanonicalMapping
        XCTAssertTrue(rules.matches(relPath: decomposed, isDirectory: false))
        XCTAssertTrue(rules.matches(relPath: "notes.md", isDirectory: false))
    }

    func testRuleWrittenInDecomposedFormStillMatches() {
        let rules = IgnoreRules(
            text: "Santé/".decomposedStringWithCanonicalMapping + "\n")
        XCTAssertTrue(rules.matches(relPath: "Santé/bilan.pdf", isDirectory: false))
    }

    // MARK: - Commentaires, lignes vides, négation

    func testCommentsAndBlankLinesAreIgnored() {
        let rules = IgnoreRules(text: """
            # ce que Fouine ne doit pas voir

            Santé/
              # indenté, donc encore un commentaire
            *.md

            """)
        XCTAssertEqual(rules.count, 2)
        XCTAssertTrue(rules.warnings.isEmpty)
    }

    func testNegationIsRefusedWithAWarningAndTheLineIsDropped() {
        let rules = IgnoreRules(text: "*.md\n!INDEX.md\n")
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.warnings.count, 1)
        XCTAssertTrue(rules.warnings[0].contains("!INDEX.md"), rules.warnings[0])
        XCTAssertTrue(rules.warnings[0].contains("negation"), rules.warnings[0])
        // La ligne est TOMBÉE, elle n'a donc rien réactivé : `INDEX.md` reste
        // exclu par `*.md`.
        XCTAssertTrue(rules.matches(relPath: "INDEX.md", isDirectory: false))
    }

    func testALeadingSlashIsToleratedAndStripped() {
        let rules = IgnoreRules(text: "/Santé/\n")
        XCTAssertTrue(rules.matches(relPath: "Santé/bilan.pdf", isDirectory: false))
    }

    func testEmptyRulesMatchNothing() {
        let rules = IgnoreRules(text: "# rien\n\n")
        XCTAssertTrue(rules.isEmpty)
        XCTAssertFalse(rules.matches(relPath: "n'importe quoi.pdf",
                                     isDirectory: false))
    }

    // MARK: - Lecture du fichier

    func testLoadReturnsNilWithoutAFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fouine-ignore-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(IgnoreRules.load(root: directory))

        try "Santé/\n".write(
            to: directory.appendingPathComponent(IgnoreRules.fileName),
            atomically: true, encoding: .utf8)
        XCTAssertEqual(IgnoreRules.load(root: directory)?.count, 1)
    }
}

// MARK: - Le crawl

final class IgnoreRulesCrawlTests: XCTestCase {

    var root: URL!
    var store: InMemoryStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fouine-ignore-crawl-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        let resolved = try VolumeResolver.resolve(path: root)
        store = InMemoryStore()
        store.addRoot(RootRecord(id: 1, volUUID: resolved.volUUID,
                                 relPath: resolved.relPath, label: "TestRoot",
                                 enabled: true))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    func write(_ relative: String, _ contents: String = "contenu") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func ignore(_ text: String) throws {
        try Data(text.utf8).write(
            to: root.appendingPathComponent(IgnoreRules.fileName))
    }

    var names: [String] {
        store.allDocs.map { ($0.record.relPath as NSString).lastPathComponent }
            .sorted()
    }

    /// Le geste du propriétaire : un dossier entier, une extension, un nom.
    func testExcludedFolderExtensionAndNameNeverEnterTheIndex() throws {
        try write("Cours/TD 3.pdf")
        try write("Santé/analyses.pdf")
        try write("Santé/2025/bilan.pdf")
        try write("Cours/INDEX.md")
        try write("Cours/notes.md")
        try ignore("""
            # ce que Fouine ne doit pas voir
            Santé/
            *.md
            """)

        let summary = try FouineCrawler(note: { _ in })
            .crawl(rootID: 1, mode: .full, store: store)

        XCTAssertEqual(names, ["TD 3.pdf"])
        XCTAssertEqual(summary.seen, 1)
        // Le dossier exclu compte UNE exclusion, pas trois : on n'y descend pas.
        XCTAssertGreaterThan(summary.skipped, 0)
    }

    /// Le fichier de règles lui-même n'est jamais indexé — il est caché, et
    /// `.skipsHiddenFiles` suffit. Le test le prouve plutôt que de le croire :
    /// `.md` fait partie des extensions indexables, et rien n'interdirait au
    /// crawl de prendre un fichier de configuration pour un document.
    func testTheIgnoreFileItselfIsNeverIndexed() throws {
        try write("Cours/TD 3.pdf")
        try ignore("*.md\n")
        _ = try FouineCrawler(note: { _ in }).crawl(rootID: 1, mode: .full,
                                                    store: store)
        XCTAssertEqual(names, ["TD 3.pdf"])
    }

    /// LA conséquence voulue : ce qui était indexé et devient exclu SORT de
    /// l'index à la passe suivante, par la passe de suppression existante.
    func testAnAlreadyIndexedDocumentLeavesTheIndexOnceExcluded() throws {
        try write("Santé/analyses.pdf")
        try write("Cours/TD 3.pdf")
        let crawler = FouineCrawler(note: { _ in })
        _ = try crawler.crawl(rootID: 1, mode: .full, store: store)
        XCTAssertEqual(names, ["TD 3.pdf", "analyses.pdf"])

        try ignore("Santé/\n")
        let second = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(names, ["TD 3.pdf"])
        XCTAssertEqual(second.removed, 1)
    }

    /// Et le contraire : la règle retirée, le document revient à la passe
    /// suivante. Une exclusion n'est pas une destruction du corpus.
    func testRemovingTheRuleBringsTheDocumentBack() throws {
        try write("Santé/analyses.pdf")
        try ignore("Santé/\n")
        let crawler = FouineCrawler(note: { _ in })
        _ = try crawler.crawl(rootID: 1, mode: .full, store: store)
        XCTAssertEqual(names, [])

        try FileManager.default.removeItem(
            at: root.appendingPathComponent(IgnoreRules.fileName))
        let second = try crawler.crawl(rootID: 1, mode: .delta, store: store)
        XCTAssertEqual(names, ["analyses.pdf"])
        XCTAssertEqual(second.added, 1)
    }

    /// Une ligne fautive se DIT. Sans cela, l'utilisateur croit avoir exclu un
    /// dossier qui continue d'être indexé.
    func testARefusedLineIsReportedOnce() throws {
        try write("Cours/TD 3.pdf")
        try ignore("*.md\n!INDEX.md\n")
        let notes = NoteCollector()
        _ = try FouineCrawler(note: { notes.append($0) })
            .crawl(rootID: 1, mode: .full, store: store)
        XCTAssertEqual(notes.messages.count, 1)
        XCTAssertTrue(notes.messages[0].contains("negation"), notes.messages[0])
    }

    /// La sonde du piège n°1 emprunte les mêmes règles : une racine dont tout
    /// le contenu lisible est exclu est VIDE, pas illisible.
    func testProbeTreatsAFullyExcludedRootAsEmptyNotUnreadable() throws {
        try write("Santé/analyses.pdf")
        try ignore("Santé/\n")
        XCTAssertNil(FouineCrawler.firstFile(under: root,
                                             ignore: IgnoreRules.load(root: root)))
        XCTAssertNoThrow(try FouineCrawler(note: { _ in })
            .crawl(rootID: 1, mode: .full, store: store))
    }

    /// LES VECTEURS PARTENT AVEC LE DOCUMENT. C'est ce qui rend l'exclusion
    /// effective « à toutes les étapes » sans toucher à l'extraction, à l'OCR
    /// ni à la vectorisation : elles ne voient que `docs`. Sur une VRAIE base —
    /// `InMemoryStore` ne porte pas `page_vec`, et c'est précisément la table
    /// qu'il faut voir vide.
    func testExcludingADocumentTakesItsVectorsWithIt() throws {
        let database = root.appendingPathComponent("index.db")
        let real = GRDBStore()
        try real.open(at: database)
        defer { real.releaseWriteLock() }
        let corpus = root.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpus,
                                                withIntermediateDirectories: true)
        try Data("azote et catalyse".utf8)
            .write(to: corpus.appendingPathComponent("cours.txt"))
        let rootID = try real.addRoot(path: corpus, label: "Corpus")

        let crawler = FouineCrawler(note: { _ in })
        _ = try crawler.crawl(rootID: rootID, mode: .full, store: real)
        let doc = try XCTUnwrap(real.docs(underRoot: rootID).first)
        try real.replacePages(docID: doc.id,
                              pages: [PageText(page: 0, text: "azote et catalyse",
                                               source: .native)])
        let pageRowID = Schema.ftsRowID(docID: doc.id, page: 0)
        try real.upsertVectors([(rowid: Schema.vecRowID(pageRowID: pageRowID, chunk: 0),
                                 vec: Data(repeating: 1, count: 384))])
        XCTAssertEqual(try real.vectorCount(), 1)

        try Data("*.txt\n".utf8)
            .write(to: corpus.appendingPathComponent(IgnoreRules.fileName))
        let second = try crawler.crawl(rootID: rootID, mode: .delta, store: real)
        XCTAssertEqual(second.removed, 1)
        XCTAssertTrue(try real.docs(underRoot: rootID).isEmpty)
        XCTAssertEqual(try real.vectorCount(), 0)
    }
}

// MARK: - FSEvents

final class IgnoreFileWatchTests: XCTestCase {

    /// LA question à laquelle il fallait répondre pour promettre que le fichier
    /// est « relu à chaque passe » : un fichier CACHÉ déclenche-t-il un
    /// événement ? `.skipsHiddenFiles` est une option de l'ÉNUMÉRATEUR, pas du
    /// noyau — FSEvents, lui, ne connaît pas les fichiers cachés. Mesuré ici
    /// plutôt que raisonné : l'écriture de `.fouineignore` remonte une salve
    /// qui porte son chemin, donc l'agent programme une passe sur cette racine
    /// (son `receive` ne compare que le préfixe de la racine), et la nouvelle
    /// règle s'applique dans les secondes qui suivent au lieu d'attendre le
    /// crawl périodique.
    func testWritingTheIgnoreFileRaisesAnFSEvent() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fouine-ignore-fsevents-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let seen = expectation(description: "salve portant .fouineignore")
        seen.assertForOverFulfill = false
        let watcher = FSEventsWatcher(
            roots: [URL(fileURLWithPath: root.resolvingSymlinksInPath().path,
                        isDirectory: true)],
            volUUID: "75F6E680-A01E-49E2-A130-1800826B45AA",
            store: InMemoryStore(), latency: 0.01,
            onBatch: { batch in
                if batch.paths.contains(where: {
                    $0.hasSuffix(IgnoreRules.fileName)
                }) { seen.fulfill() }
            })
        try watcher.start()
        defer { watcher.stop() }
        try Data("*.md\n".utf8)
            .write(to: root.appendingPathComponent(IgnoreRules.fileName))
        wait(for: [seen], timeout: 20)
    }
}

/// Recueil des avertissements du crawl, sûr entre fils (`note` est `@Sendable`).
final class NoteCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ message: String) {
        lock.lock(); storage.append(message); lock.unlock()
    }
    var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
