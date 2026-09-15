// StoredIgnoreRulesPassTests.swift — une règle gardée dans les réglages, sans
// fichier `.fouineignore`, sur une vraie passe et une vraie base (lot IG2).
// Propriété : A-Core.
//
// Le test d'IG1 (`testExcludingADocumentTakesItsVectorsWithIt`) prouvait que
// les vecteurs partent avec un document exclu par le FICHIER. Celui-ci rejoue
// la chaîne par le chemin de l'app : la règle est écrite dans
// `roots.ignore_rules`, la passe est celle que lancent l'app, la CLI et l'agent
// (`IndexPass`), et rien n'est jamais écrit dans le dossier.

import XCTest
import FouineCore
import FouineCrawl
@testable import FouineIndex

final class StoredIgnoreRulesPassTests: XCTestCase {

    private func options() -> IndexPassOptions {
        IndexPassOptions(crawl: .delta, jobs: 2, optimize: false,
                         warmVocabulary: false, role: .cli)
    }

    func testAStoredRuleTakesTheDocumentAndItsVectorsOutAtTheNextPass() throws {
        let scratch = try IndexScratch("regle-gardee", documents: 3)
        let store = scratch.store
        _ = try IndexPass(store: store, observer: RecordingObserver())
            .run(roots: [scratch.rootRecord], options: options())
        let docs = try scratch.documents()
        XCTAssertEqual(docs.count, 3)

        // Un vecteur pour chaque document : c'est `page_vec` qu'il faut voir
        // se vider pour le seul document exclu.
        try store.upsertVectors(docs.map { doc in
            (rowid: Schema.vecRowID(pageRowID: Schema.ftsRowID(docID: doc.id, page: 0),
                                    chunk: 0),
             vec: Data(repeating: 1, count: 384))
        })
        store.releaseWriteLock()
        XCTAssertEqual(try store.vectorCount(), 3)

        try store.setIgnoreRulesJSON(
            rootID: scratch.rootRecord.id,
            try IgnoreRuleSet(validating: ["fiche-1.txt"]).json)

        let observer = RecordingObserver()
        _ = try IndexPass(store: store, observer: observer)
            .run(roots: [scratch.rootRecord], options: options())

        XCTAssertEqual(observer.crawled.first?.summary.removed, 1)
        let left = try scratch.documents().map {
            ($0.record.relPath as NSString).lastPathComponent
        }.sorted()
        XCTAssertEqual(left, ["fiche-0.txt", "fiche-2.txt"])
        XCTAssertEqual(try store.vectorCount(), 2, "les vecteurs du document exclu partent avec lui")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: scratch.root.appendingPathComponent(IgnoreRules.fileName).path),
            "la règle vit dans la base, jamais dans le dossier")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: scratch.root.appendingPathComponent("fiche-1.txt").path),
            "le fichier de l'utilisateur n'est pas touché")
    }
}
