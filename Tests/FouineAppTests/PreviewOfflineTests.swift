// PreviewOfflineTests.swift — le disque n'est pas branché, et l'aperçu le dit
// (lot PV1). Propriété : A-App.
//
// Le texte indexé s'affiche déjà dans ce cas (audit U4), mais SANS un mot : une
// lettre mise en page apparaissait en caractères bruts, et rien ne disait que
// c'était un pis-aller. La base jetable porte un volume « TEST-VOL » qui n'est
// monté nulle part : c'est exactement le disque débranché, sans en débrancher un.

import XCTest
import FouineCore
@testable import FouineApp

@MainActor
final class PreviewOfflineTests: XCTestCase {

    /// Attend que le chargement de l'aperçu soit retombé. Le modèle travaille
    /// par `Task` : lire `content` juste après `load` verrait `.loading`.
    private func settle(_ preview: PreviewModel, timeout: TimeInterval = 10,
                        file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if preview.content != .loading, preview.content != .empty { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("l'aperçu ne s'est pas chargé en \(timeout) s", file: file, line: line)
    }

    func testAnUnmountedVolumeShowsTheKeptTextAndSaysSo() async throws {
        let db = try TempAppDB()
        let id = try db.addDoc(relPath: "Users/essai/lettre.rtf", ext: "rtf",
                               folder: "Essai",
                               pages: ["Madame, Monsieur,\n\nsuite à notre entretien…"])
        let preview = PreviewModel(service: db.service)
        preview.load(hit: Hit(docID: id, path: "Users/essai/lettre.rtf", page: 1,
                              score: 0, snippet: "", source: .native,
                              fuzzyDistance: 0),
                     roots: [])
        await settle(preview)

        guard case .text(let page) = preview.content else {
            return XCTFail("le texte gardé doit rester affiché : \(preview.content)")
        }
        XCTAssertTrue(page.text.hasPrefix("Madame"))
        let notice = try XCTUnwrap(preview.offlineNotice)
        // La phrase nomme le DOSSIER, jamais le volume ni son identifiant —
        // « TEST-VOL » ne veut rien dire pour qui lit.
        XCTAssertTrue(notice.contains("Essai"), notice)
        XCTAssertFalse(notice.contains("TEST-VOL"), notice)
    }

    /// Le disque rebranché — ici, un document dont l'aperçu se résout — ne
    /// garde pas la phrase de l'ancien : elle s'efface à chaque chargement.
    func testTheNoticeIsClearedWhenAnotherPageLoads() async throws {
        let db = try TempAppDB()
        let id = try db.addDoc(relPath: "Users/essai/lettre.rtf", ext: "rtf",
                               pages: ["première page", "deuxième page"])
        let preview = PreviewModel(service: db.service)
        let hit = Hit(docID: id, path: "Users/essai/lettre.rtf", page: 1,
                      score: 0, snippet: "", source: .native, fuzzyDistance: 0)
        preview.load(hit: hit, roots: [])
        await settle(preview)
        XCTAssertNotNil(preview.offlineNotice)

        preview.load(hit: nil, roots: [])
        XCTAssertNil(preview.offlineNotice)
    }
}
