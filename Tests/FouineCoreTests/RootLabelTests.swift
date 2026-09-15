// RootLabelTests.swift — étiquettes de racines : dédoublonnage et renommage.
// SPEC §4.1 (`docs.top_folder` = `roots.label`). Propriété : A-Core.
//
// L'étiquette n'est pas décorative : c'est la facette « Dossiers » et la cible de
// `dossier:<étiquette>`. Depuis que les dossiers s'ajoutent depuis le Finder
// (audit D1), deux « Cours » sous deux parents différents sont un cas banal.

import Foundation
import XCTest
@testable import FouineCore

final class RootLabelTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-roots-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func makeFolder(_ components: String) throws -> URL {
        let url = scratch.appendingPathComponent(components, isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        try "contenu".write(to: url.appendingPathComponent("a.txt"),
                            atomically: true, encoding: .utf8)
        return url
    }

    func testHomonymousRootsGetDistinctLabels() throws {
        let db = try makeDB()
        let first = try makeFolder("Documents/Cours")
        let second = try makeFolder("Archives/Cours")

        let idA = try db.store.addRoot(path: first, label: nil)
        let idB = try db.store.addRoot(path: second, label: nil)

        let labels = try db.store.roots().reduce(into: [Int64: String]()) {
            $0[$1.id] = $1.label
        }
        XCTAssertEqual(labels[idA], "Cours")
        XCTAssertEqual(labels[idB], "Cours 2",
                       "deux racines homonymes se fondraient en une seule facette")
    }

    /// Réenregistrer un dossier DÉJÀ connu ne doit pas le renommer : c'est ce que
    /// fait `fouine root add` sur une racine existante (et ce que ferait un
    /// utilisateur qui redépose le même dossier sur la barre latérale).
    func testReAddingSameRootKeepsItsLabel() throws {
        let db = try makeDB()
        let folder = try makeFolder("Documents/Cours")
        let id = try db.store.addRoot(path: folder, label: nil)
        let again = try db.store.addRoot(path: folder, label: nil)
        XCTAssertEqual(id, again)
        XCTAssertEqual(try db.store.roots().first?.label, "Cours")
    }

    func testRenameUpdatesFacetOfAlreadyIndexedDocuments() throws {
        let db = try makeDB()
        let folder = try makeFolder("Documents/Cours")
        let id = try db.store.addRoot(path: folder, label: nil)
        guard let root = try db.store.roots().first(where: { $0.id == id }) else {
            return XCTFail("racine non enregistrée")
        }
        let docID = try db.store.upsertDoc(DocRecord(
            volUUID: root.volUUID, relPath: root.relPath + "/a.txt", ext: "txt",
            topFolder: root.label, size: 7, mtime: 1_700_000_000))

        XCTAssertEqual(try db.store.setRootLabel(id: id, "Chimie"), "Chimie")
        XCTAssertEqual(try db.store.roots().first?.label, "Chimie")
        XCTAssertEqual(try db.store.docRow(id: docID)?.record.topFolder, "Chimie",
                       "la facette « Dossiers » répondrait encore à l'ancien nom")
    }

    func testRenameToATakenLabelIsSuffixed() throws {
        let db = try makeDB()
        let a = try db.store.addRoot(path: try makeFolder("Documents/Cours"), label: nil)
        _ = try db.store.addRoot(path: try makeFolder("Archives/Notes"), label: nil)
        XCTAssertEqual(try db.store.setRootLabel(id: a, "Notes"), "Notes 2")
    }

    func testRenameRejectsEmptyLabel() throws {
        let db = try makeDB()
        let id = try db.store.addRoot(path: try makeFolder("Documents/Cours"), label: nil)
        XCTAssertThrowsError(try db.store.setRootLabel(id: id, "   "))
        XCTAssertEqual(try db.store.roots().first?.label, "Cours")
    }
}
