// DocumentDatePassTests.swift — la date du document écrite par la passe
// d'indexation (lot DD1, constat PR-07). Propriété : A-Core.
//
// Ce qui est protégé ici : `IndexPass` tient la métadonnée au moment exact où
// il tient le texte, et c'est le SEUL endroit où la date s'écrit sans rouvrir
// un fichier. La perdre là — ce que faisait Fouine jusqu'au 11/09/2026 —
// oblige à un rattrapage sur tout le fonds.

import XCTest
import FouineCore
@testable import FouineIndex

final class DocumentDatePassTests: XCTestCase {

    /// Une racine jetable, plus un `.eml` daté : le courriel est le format le
    /// plus simple à dater à la main, et son en-tête `Date:` passe par le même
    /// `meta["date"]` que le PDF, l'EPUB et la photo.
    private func scratchWithDatedEmail(_ name: String) throws -> IndexScratch {
        let scratch = try IndexScratch(name, documents: 1)
        try Data("""
        From: greffe@example.org
        To: moi@example.org
        Subject: Attestation
        Date: Sat, 12 Apr 2003 10:30:00 +0200

        \(String(repeating: "attestation de situation, exercice clos. ", count: 6))
        """.utf8).write(to: scratch.root.appendingPathComponent("attestation.eml"))
        return scratch
    }

    private func row(_ scratch: IndexScratch, suffix: String) throws -> DocRow {
        let rows = try scratch.store.docs(underRoot: scratch.rootRecord.id)
        return try XCTUnwrap(rows.first { $0.record.relPath.hasSuffix(suffix) })
    }

    func testThePassWritesTheDateTheDocumentCarries() throws {
        let scratch = try scratchWithDatedEmail("date")
        try IndexPass(store: scratch.store)
            .run(roots: [scratch.rootRecord],
                 options: IndexPassOptions(crawl: .full, warmVocabulary: false))

        let dated = try row(scratch, suffix: "attestation.eml")
        let seconds = try XCTUnwrap(dated.record.docDate)
        let civil = DocumentDate.civil(seconds)
        XCTAssertEqual([civil.year, civil.month, civil.day], [2003, 4, 12])
        // Et la date du FICHIER, elle, est d'aujourd'hui : les deux colonnes
        // disent bien deux choses différentes — tout le constat PR-07.
        XCTAssertGreaterThan(dated.record.mtime, seconds)

        // Un `.txt` ne porte aucune date : la colonne reste vide plutôt que de
        // recopier `mtime`.
        XCTAssertNil(try row(scratch, suffix: "fiche-0.txt").record.docDate)
    }
}
