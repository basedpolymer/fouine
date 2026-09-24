// PermissionBannerTextTests.swift — le bandeau d'autorisation ne parle que des
// refus de macOS (défaut vu le 24/09/2026 sur le build 934).
// Propriété : A-App. SPEC §7.1.
//
// Un disque débranché affichait « Fouine cannot read “Documents”. […]
// impossible. disk not plugged in » avec « Open Settings » : aucun réglage ne
// rebranche un disque, et le motif de la barre latérale finissait collé en
// minuscules après un point.

import XCTest
import FouineCore
@testable import FouineApp

final class PermissionBannerTextTests: XCTestCase {

    private func root(id: Int64 = 1, label: String = "Documents",
                      mounted: Bool = true, readable: Bool = true,
                      enabled: Bool = true, reason: String? = nil,
                      probeReason: RootProbe.Reason? = nil) -> RootStatus {
        RootStatus(
            record: RootRecord(id: id, volUUID: "U\(id)", relPath: label,
                               label: label, enabled: enabled),
            absolutePath: mounted ? "/Volumes/Data/\(label)" : nil,
            mounted: mounted, readable: readable, reason: reason,
            probeReason: probeReason)
    }

    private func denied(_ id: Int64, _ label: String) -> RootStatus {
        root(id: id, label: label, readable: false,
             reason: "read denied (privacy settings or file permissions)",
             probeReason: .permissionDenied)
    }

    func testUnpluggedDiskRaisesNoBanner() {
        let offline = root(mounted: false, readable: false,
                           reason: "disk not plugged in")
        XCTAssertNil(PermissionBannerText.make([offline]))
    }

    func testFolderThatCannotBeFixedInSettingsRaisesNoBanner() {
        let cases: [RootProbe.Reason] = [.missing, .noReadableFile,
                                         .system("Input/output error")]
        for reason in cases {
            let blocked = root(readable: false, reason: "motif",
                               probeReason: reason)
            XCTAssertNil(PermissionBannerText.make([blocked]), "\(reason)")
        }
        // Une erreur autre qu'un `rootUnreadable` n'a pas de motif du tout.
        XCTAssertNil(PermissionBannerText.make([root(readable: false)]))
    }

    func testPausedFolderRaisesNoBanner() {
        let paused = root(readable: false, enabled: false,
                          probeReason: .permissionDenied)
        XCTAssertNil(PermissionBannerText.make([paused]))
    }

    func testDenialIsAFullSentenceWithTheSettingsPath() throws {
        let text = try XCTUnwrap(PermissionBannerText.make([denied(1, "Documents")]))
        XCTAssertTrue(text.hasPrefix("Fouine is not allowed to read “Documents”. "), text)
        XCTAssertTrue(text.contains("To allow it: System Settings ▸ Privacy & Security"), text)
        XCTAssertTrue(text.hasSuffix("."), text)
        // Ni le motif de la barre latérale, ni un fragment en minuscules
        // après un point.
        XCTAssertFalse(text.contains("read denied"), text)
        XCTAssertNil(text.range(of: #"\. [a-z]"#, options: .regularExpression), text)
    }

    /// Un disque débranché à côté d'un vrai refus : le bandeau ne nomme que
    /// le dossier refusé, et ne dit rien du disque.
    func testOnlyDeniedFoldersAreNamed() throws {
        let offline = root(id: 2, label: "Archives 2019", mounted: false,
                           readable: false, reason: "disk not plugged in")
        let text = try XCTUnwrap(PermissionBannerText.make(
            [offline, denied(1, "Documents"), denied(3, "Desktop")]))
        XCTAssertTrue(text.contains("“Documents”, “Desktop”"), text)
        XCTAssertFalse(text.contains("Archives 2019"), text)
        XCTAssertFalse(text.contains("plugged"), text)
    }

    // MARK: - De bout en bout, par la vraie sonde

    /// `refreshRoots(probe: true)` sur deux vraies racines : l'une dont le
    /// dossier a disparu (pas de bandeau), l'autre fermée par `chmod 000`
    /// (EACCES, le cas du bandeau).
    @MainActor
    func testRefreshRootsRaisesTheBannerOnlyForADenial() async throws {
        let db = try TempAppDB()
        let fm = FileManager.default
        let gone = db.directory.appendingPathComponent("Parti", isDirectory: true)
        let locked = db.directory.appendingPathComponent("Fermé", isDirectory: true)
        for dir in [gone, locked] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))
        }
        _ = try db.store.addRoot(path: gone, label: "Parti")
        let app = AppModel(service: db.service)

        try fm.removeItem(at: gone)
        await app.refreshRoots(probe: true)
        XCTAssertEqual(app.roots.first?.probeReason, .missing)
        XCTAssertNil(app.tccBanner, "un dossier disparu ne se répare pas dans les Réglages")

        _ = try db.store.addRoot(path: locked, label: "Fermé")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        await app.refreshRoots(probe: true)
        let banner = try XCTUnwrap(app.tccBanner)
        XCTAssertTrue(banner.contains("“Fermé”"), banner)
        XCTAssertFalse(banner.contains("Parti"), banner)
    }
}
