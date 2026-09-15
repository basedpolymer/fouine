// PreviewActionTests.swift — « Aperçu impossible » propose le BON geste (A2-11).
// Propriété : A-App. SPEC §5.6 (amendement du 04/09/2026, lot K2).
//
// Les six causes d'un aperçu indisponible affichaient les deux mêmes boutons :
// « Ouvrir les Réglages Système » et « Retester les dossiers ». Un fichier que
// l'utilisateur a déplacé la veille n'a rien à voir avec une autorisation de
// confidentialité, et le renvoyer là détourne du seul geste utile —
// « Indexer maintenant ». Le §5.6 demande « un état explicite nommant la
// racine ET l'action à faire » : la moitié y était.

import XCTest
import FouineCore
@testable import FouineApp

@MainActor
final class PreviewActionTests: XCTestCase {

    private func root(readable: Bool) -> RootStatus {
        RootStatus(
            record: RootRecord(id: 1, volUUID: "U1", relPath: "docs",
                               label: "Docs", enabled: true),
            absolutePath: "/Volumes/Data/Docs", mounted: true,
            readable: readable,
            reason: readable ? nil : "read denied (privacy settings or file permissions)")
    }

    private func state(url: URL, roots: [RootStatus]) -> PreviewContent {
        PreviewModel.unavailableState(url: url, rootLabel: "Docs",
                                      fallback: "unreadable file", roots: roots)
    }

    private func actions(_ content: PreviewContent) -> [PreviewAction] {
        guard case .unavailable(_, _, let actions) = content else {
            XCTFail("état inattendu : \(content)")
            return []
        }
        return actions
    }

    /// Autorisation refusée : les Réglages Système, et le retest qui suit.
    func testPermissionDeniedOffersTheSettings() {
        let content = state(url: URL(fileURLWithPath: "/Volumes/Data/Docs/x.pdf"),
                            roots: [root(readable: false)])
        XCTAssertEqual(actions(content), [.openPrivacySettings, .retestRoots])
    }

    /// Fichier déplacé : l'emplacement attendu et « Indexer maintenant ».
    /// Et SURTOUT PAS les réglages de confidentialité.
    func testMissingFileNeverOffersPrivacySettings() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("k2-absent-\(UUID().uuidString)/livre.pdf")
        let content = state(url: missing, roots: [root(readable: true)])
        XCTAssertEqual(actions(content),
                       [.revealExpectedLocation(path: missing.path), .indexNow])
        XCTAssertFalse(actions(content).contains(.openPrivacySettings),
                       "A2-11 : un fichier déplacé n'est pas un refus d'accès")
        guard case .unavailable(let title, _, _) = content else {
            return XCTFail("état inattendu")
        }
        XCTAssertEqual(title, "File not found")
    }

    /// Le chemin voyage avec l'action : le fichier n'est plus là, on ouvrira
    /// son dossier parent.
    func testTheExpectedLocationCarriesItsPath() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("k2-absent-\(UUID().uuidString)/livre.pdf")
        guard case .revealExpectedLocation(let path)? = actions(
            state(url: missing, roots: [root(readable: true)])).first else {
            return XCTFail("le premier geste doit porter le chemin")
        }
        XCTAssertEqual(path, missing.path)
    }

    /// Un fichier présent mais illisible : c'est bien une histoire de droits.
    func testUnreadableExistingFileOffersTheSettings() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("k2-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("livre.pdf")
        try Data("%PDF".utf8).write(to: file)

        let content = state(url: file, roots: [root(readable: true)])
        XCTAssertEqual(actions(content), [.openPrivacySettings, .retestRoots])
        guard case .unavailable(let title, _, _) = content else {
            return XCTFail("état inattendu")
        }
        XCTAssertEqual(title, "Preview impossible")
    }

    /// Les trois causes rendent trois jeux de gestes DISTINCTS : c'est tout
    /// l'objet du correctif.
    func testTheThreeCausesGiveThreeDifferentGestures() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("k2-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let present = dir.appendingPathComponent("livre.pdf")
        try Data("%PDF".utf8).write(to: present)
        let absent = dir.appendingPathComponent("parti.pdf")

        let sets = [
            actions(state(url: present, roots: [root(readable: false)])),
            actions(state(url: absent, roots: [root(readable: true)])),
            actions(state(url: present, roots: [root(readable: true)])),
        ]
        XCTAssertEqual(Set(sets.map { $0.map(\.identifier).joined(separator: "+") }).count, 2,
                       "refus d'accès et aperçu impossible partagent le même geste, "
                       + "le fichier déplacé a le sien")
        XCTAssertEqual(sets[1].map(\.identifier), ["reveal", "index"])
    }

    /// Chaque geste a un libellé, et aucun ne parle technicien.
    func testEveryGestureHasALabel() {
        let all: [PreviewAction] = [.openPrivacySettings, .retestRoots, .indexNow,
                                    .revealExpectedLocation(path: "/x/y.pdf")]
        for action in all {
            XCTAssertFalse(action.localizedLabel.isEmpty, "\(action)")
            XCTAssertFalse(action.localizedLabel.contains("/x/y.pdf"),
                           "le chemin ne s'affiche pas dans un bouton")
        }
        XCTAssertEqual(Set(all.map(\.identifier)).count, 4)
    }
}
