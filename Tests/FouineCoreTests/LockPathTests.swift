// LockPathTests.swift — le verrou porte le nom de sa base (constat BU-30).
// Propriété : A-Core.
//
// Deux bases dans un même dossier partageaient `fouine.lock` : le régime
// documenté du travail sur copie (`FOUINE_DB=<copie>`) faisait se bloquer deux
// agents ou deux tests voisins en silence. Ce qui doit rester vrai, et que ce
// fichier fixe : `fouine.db` garde `fouine.lock` — sans quoi l'agent DÉJÀ
// installé sonderait un autre fichier que le store.

import XCTest
@testable import FouineCore

final class LockPathTests: XCTestCase {

    private func base(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/fouine-verrou").appendingPathComponent(name)
    }

    func testTheWriteLockCarriesTheDatabaseName() {
        XCTAssertEqual(FouinePaths.lockURL(for: base("fouine.db")).lastPathComponent,
                       "fouine.lock",
                       "la base de production doit garder son nom historique")
        XCTAssertEqual(FouinePaths.lockURL(for: base("c2.db")).lastPathComponent,
                       "c2.lock")
        XCTAssertEqual(FouinePaths.lockURL(for: base("ix1.db")).lastPathComponent,
                       "ix1.lock")
    }

    func testTheCampaignLockCarriesTheDatabaseNameToo() {
        XCTAssertEqual(FouinePaths.embedLockURL(for: base("fouine.db")).lastPathComponent,
                       "fouine-embed.lock")
        XCTAssertEqual(FouinePaths.embedLockURL(for: base("c2.db")).lastPathComponent,
                       "c2-embed.lock")
    }

    /// Le verrou reste VOISIN de la base : c'est ce qui fait qu'une copie
    /// emportée ailleurs emmène son propre verrou.
    func testTheLockSitsNextToTheDatabase() {
        let url = base("c2.db")
        XCTAssertEqual(FouinePaths.lockURL(for: url).deletingLastPathComponent().path,
                       url.deletingLastPathComponent().path)
    }
}
