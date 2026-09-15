// DocumentDateStoreTests.swift — la date du document en base : la facette
// « Daté de » (constat PR-07). Propriété : A-Core.
//
// Ce qui est prouvé ici : la facette `doc_year` range les documents sous
// l'année qu'ils PORTENT et non sous celle de leur fichier — c'est tout le
// constat PR-07, où « Guymont — cristallographie (2003).pdf » sortait sous
// 2024 — et une réécriture du fichier efface la date, que la ré-extraction
// relira.
//
// `docs.doc_date` s'écrit à L'EXTRACTION, seul moment où le fichier est ouvert
// (`IndexPass`) : il n'y a pas d'autre chemin d'écriture. `MetadataReaderTests`
// éprouve la lecture de la métadonnée elle-même, format par format.

import XCTest
@testable import FouineCore

final class DocumentDateStoreTests: XCTestCase {

    /// Un document indexé, avec une page cherchable.
    @discardableResult
    private func indexed(_ db: TempDB, _ relPath: String, text: String,
                         mtime: Double = 1_700_000_000) throws -> Int64 {
        let id = try addDoc(db, relPath: relPath, mtime: mtime)
        try db.store.replacePages(docID: id, pages: [page(1, text)])
        try db.store.setPageCount(id, 1)
        try db.store.setDocState(id, .extracted, err: nil)
        return id
    }

    // MARK: - La facette

    /// LE test du constat : trois ouvrages recopiés sur le Mac la même année
    /// sortent sous une seule année pour « Modifié en », et sous la leur pour
    /// « Daté de ».
    func testTheDocumentYearFacetSaysWhenTheDocumentIsFromNotTheFile() throws {
        let db = try makeDB()
        // Même `mtime` pour les trois : la copie sur le disque, en 2023.
        let copied = 1_700_000_000.0
        let a = try indexed(db, "Livres/cristallographie.pdf",
                            text: "cristallographie", mtime: copied)
        let b = try indexed(db, "Livres/thermodynamique.pdf",
                            text: "cristallographie", mtime: copied)
        let c = try indexed(db, "Livres/recent.pdf",
                            text: "cristallographie", mtime: copied)
        try db.store.setDocDate(a, XCTUnwrap(DocumentDate.parse("2003-04-12")))
        try db.store.setDocDate(b, XCTUnwrap(DocumentDate.parse("1978")))
        _ = c                                        // celui-ci ne porte rien

        let q = try query("cristallographie")
        XCTAssertEqual(try db.store.facets(q, by: .year).map(\.0), ["2023"],
                       "la date du FICHIER range les trois sous la même année")

        let byDocument = try db.store.facets(q, by: .docYear)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: byDocument),
                       ["2003": 1, "1978": 1, "": 1])
    }

    /// La clé vide est celle des documents sans date : l'interface l'écarte
    /// comme les valeurs vides de toutes les autres facettes, et c'est ce qui
    /// évite une ligne « — » au milieu des années.
    func testDocumentsWithoutADateFallUnderTheEmptyKey() throws {
        let db = try makeDB()
        try indexed(db, "Livres/sans-date.txt", text: "entropie")
        let facet = try db.store.facets(try query("entropie"), by: .docYear)
        XCTAssertEqual(facet.map(\.0), [""])
    }

    /// Un fichier dont le CONTENU a changé perd sa date : la ré-extraction qui
    /// suit la réécrira, ou la laissera vide. Une date qui survivrait à un
    /// remplacement complet parlerait du document d'avant.
    func testChangingTheFileClearsTheDate() throws {
        let db = try makeDB()
        let id = try indexed(db, "Livres/traite.pdf", text: "entropie")
        try db.store.setDocDate(id, XCTUnwrap(DocumentDate.parse("2003-04-12")))
        _ = try db.store.upsertDoc(DocRecord(
            volUUID: "TEST-VOL", relPath: "Livres/traite.pdf", ext: "pdf",
            topFolder: "Livres", size: 2_000, mtime: 1_800_000_000))
        XCTAssertNil(try db.store.docRow(id: id)?.record.docDate)
    }
}
