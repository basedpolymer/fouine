// ModelDownloadTests.swift — installation du modèle sémantique (audit D6).
// Propriété : A-Embed (palier 3, 02/09/2026).
//
// AUCUN RÉSEAU. Chaque test fabrique sa propre archive zip (par `ditto -c -k
// --keepParent`, l'inverse exact de ce que fait l'installateur), calcule son
// SHA-256, et la fait installer par une URL `file://`. C'est le MÊME chemin de
// code que le téléchargement réel à partir du hachage : seule la source des
// octets change.
//
// Ce que ces tests tiennent, et qui n'est vérifiable qu'ici :
//   · une empreinte fausse ne laisse RIEN derrière elle — ni modèle installé,
//     ni archive, ni répertoire de travail dans le dossier des modèles ;
//   · le remplacement d'un modèle existant est atomique : l'ancien n'est retiré
//     qu'une fois le nouveau complet.

import Foundation
import XCTest
import CryptoKit
@testable import FouineEmbed

final class ModelDownloadTests: XCTestCase {

    // MARK: - Bac à sable

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-model-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    /// Répertoire cible, sous le bac à sable : JAMAIS celui de production.
    private func targetDirectory() -> URL {
        sandbox.appendingPathComponent("models/e5-small", isDirectory: true)
    }

    // MARK: - Fabrication d'une archive de modèle

    private func meta(modelID: String = ModelDownloader.expectedModelID,
                      revision: Int = ModelDownloader.expectedRevision) -> String {
        """
        {"model_id": "\(modelID)", "revision": \(revision), "dim": 384, \
        "seq": 256, "bos_id": 0, "eos_id": 2, "pad_id": 1, \
        "prefix_query": "query: ", "prefix_passage": "passage: "}
        """
    }

    /// Un répertoire de modèle factice : les trois pièces attendues, plus le
    /// `parity.json` que porte l'archive réelle (il doit être TOLÉRÉ).
    private func makeModelTree(named name: String = "e5-small",
                               metaJSON: String? = nil,
                               omit: Set<String> = [],
                               marker: String? = nil) throws -> URL {
        let fm = FileManager.default
        let root = sandbox.appendingPathComponent("build-\(UUID().uuidString)/\(name)",
                                                  isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if !omit.contains("meta.json") {
            try (metaJSON ?? meta()).write(
                to: root.appendingPathComponent("meta.json"),
                atomically: true, encoding: .utf8)
        }
        if !omit.contains("vocab.json") {
            try "[[\"▁le\", -1.0]]".write(
                to: root.appendingPathComponent("vocab.json"),
                atomically: true, encoding: .utf8)
        }
        if !omit.contains("E5Small.mlmodelc") {
            let compiled = root.appendingPathComponent("E5Small.mlmodelc",
                                                       isDirectory: true)
            try fm.createDirectory(at: compiled, withIntermediateDirectories: true)
            try Data(repeating: 0x42, count: 128).write(
                to: compiled.appendingPathComponent("coremldata.bin"))
        }
        try "{\"pairs\": []}".write(to: root.appendingPathComponent("parity.json"),
                                    atomically: true, encoding: .utf8)
        if let marker {
            try marker.write(to: root.appendingPathComponent("marqueur.txt"),
                             atomically: true, encoding: .utf8)
        }
        return root
    }

    /// `ditto -c -k --keepParent` : le dossier de tête est conservé dans le zip,
    /// comme dans l'archive publiée.
    private func zip(_ tree: URL) throws -> (url: URL, sha256: String) {
        let archive = sandbox.appendingPathComponent("\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", tree.path, archive.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "ditto -c -k a échoué")
        let data = try Data(contentsOf: archive)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (archive, digest)
    }

    /// Installe l'archive `tree` dans `directory`, sans réseau.
    @discardableResult
    private func install(_ tree: URL, into directory: URL,
                         sha256: String? = nil,
                         force: Bool = false) throws -> ModelStatus {
        let packed = try zip(tree)
        return try ModelDownloader.install(into: directory,
                                           from: packed.url,
                                           sha256: sha256 ?? packed.sha256,
                                           expectedBytes: 0,
                                           force: force)
    }

    /// Ce qui reste dans le dossier des modèles, hors le modèle lui-même.
    private func leftovers(in parent: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path))
            ?? []
        return names.filter { $0 != "e5-small" }.sorted()
    }

    // MARK: - Résolution de l'adresse et de l'empreinte

    func testResolvedURLPrefersOverrideThenEnvironmentThenConstant() throws {
        XCTAssertEqual(try ModelDownloader.resolvedURL(environment: [:]).absoluteString,
                       ModelDownloader.defaultURLString)
        XCTAssertEqual(
            try ModelDownloader.resolvedURL(
                environment: ["FOUINE_MODEL_URL": "file:///tmp/m.zip"]).absoluteString,
            "file:///tmp/m.zip")
        // L'argument explicite (option `--url`) l'emporte sur la variable.
        XCTAssertEqual(
            try ModelDownloader.resolvedURL(
                override: "https://example.org/a.zip",
                environment: ["FOUINE_MODEL_URL": "file:///tmp/m.zip"]).absoluteString,
            "https://example.org/a.zip")
    }

    func testResolvedURLRefusesPlainHTTP() {
        XCTAssertThrowsError(
            try ModelDownloader.resolvedURL(override: "http://example.org/a.zip")) {
            guard case ModelDownloadError.unsupportedScheme = $0 else {
                return XCTFail("attendu unsupportedScheme, obtenu \($0)")
            }
        }
    }

    func testResolvedSHA256Overrides() {
        XCTAssertEqual(ModelDownloader.resolvedSHA256(environment: [:]),
                       ModelDownloader.expectedSHA256)
        XCTAssertEqual(
            ModelDownloader.resolvedSHA256(environment: ["FOUINE_MODEL_SHA256": "AB12  "]),
            "ab12")
    }

    // MARK: - Installation nominale

    func testInstallsCorrectArchiveWithExpectedLayout() throws {
        let target = targetDirectory()
        let status = try install(try makeModelTree(), into: target)

        XCTAssertTrue(status.installed)
        XCTAssertEqual(status.modelID, ModelDownloader.expectedModelID)
        XCTAssertEqual(status.revision, ModelDownloader.expectedRevision)
        XCTAssertGreaterThan(status.bytesOnDisk, 0)

        // La disposition installée est celle qu'attend `EmbedPaths` : les trois
        // pièces DIRECTEMENT dans le répertoire, sans le dossier de tête du zip.
        XCTAssertTrue(EmbedPaths.modelAvailable(at: target))
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("e5-small").path),
                       "le dossier de tête de l'archive ne doit pas survivre")
        // parity.json est toléré et conservé.
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("parity.json").path))
        XCTAssertEqual(leftovers(in: target.deletingLastPathComponent()), [],
                       "aucun répertoire de travail ne doit rester")
    }

    func testInstallRefusesSecondTimeWithoutForce() throws {
        let target = targetDirectory()
        try install(try makeModelTree(), into: target)
        XCTAssertThrowsError(try install(try makeModelTree(), into: target)) {
            guard case ModelDownloadError.alreadyInstalled = $0 else {
                return XCTFail("attendu alreadyInstalled, obtenu \($0)")
            }
        }
    }

    /// Remplacement : l'ancien modèle disparaît d'un coup, le nouveau est complet.
    func testForceReplacesExistingModelAtomically() throws {
        let target = targetDirectory()
        try install(try makeModelTree(marker: "ancien"), into: target)
        XCTAssertEqual(
            try String(contentsOf: target.appendingPathComponent("marqueur.txt"),
                       encoding: .utf8), "ancien")

        try install(try makeModelTree(marker: "nouveau"), into: target, force: true)
        XCTAssertEqual(
            try String(contentsOf: target.appendingPathComponent("marqueur.txt"),
                       encoding: .utf8), "nouveau")
        XCTAssertTrue(EmbedPaths.modelAvailable(at: target))
        XCTAssertEqual(leftovers(in: target.deletingLastPathComponent()), [])
    }

    // MARK: - Refus

    func testWrongHashInstallsNothingAndLeavesNoTemporary() throws {
        let target = targetDirectory()
        let wrong = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try install(try makeModelTree(), into: target,
                                         sha256: wrong)) {
            guard case ModelDownloadError.hashMismatch = $0 else {
                return XCTFail("attendu hashMismatch, obtenu \($0)")
            }
        }
        XCTAssertFalse(EmbedPaths.modelAvailable(at: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(leftovers(in: target.deletingLastPathComponent()), [],
                       "l'archive refusée et son répertoire de travail ont fui")
    }

    /// Une empreinte fausse ne doit pas non plus emporter le modèle DÉJÀ installé.
    func testWrongHashKeepsPreviousModel() throws {
        let target = targetDirectory()
        try install(try makeModelTree(marker: "ancien"), into: target)
        XCTAssertThrowsError(try install(try makeModelTree(marker: "nouveau"),
                                         into: target,
                                         sha256: String(repeating: "f", count: 64),
                                         force: true))
        XCTAssertEqual(
            try String(contentsOf: target.appendingPathComponent("marqueur.txt"),
                       encoding: .utf8), "ancien")
    }

    func testMissingPieceIsRefused() throws {
        for missing in ["meta.json", "vocab.json", "E5Small.mlmodelc"] {
            let target = targetDirectory()
            XCTAssertThrowsError(
                try install(try makeModelTree(omit: [missing]), into: target),
                "\(missing) manquant devait être refusé") {
                guard case ModelDownloadError.badLayout = $0 else {
                    return XCTFail("attendu badLayout pour \(missing), obtenu \($0)")
                }
            }
            XCTAssertFalse(EmbedPaths.modelAvailable(at: target))
        }
    }

    /// Dossier de tête au mauvais nom : l'archive n'est pas celle de Fouine.
    func testWrongArchiveRootIsRefused() throws {
        let target = targetDirectory()
        XCTAssertThrowsError(
            try install(try makeModelTree(named: "autre-modele"), into: target)) {
            guard case ModelDownloadError.badLayout = $0 else {
                return XCTFail("attendu badLayout, obtenu \($0)")
            }
        }
    }

    /// `meta.json` qui annonce un autre modèle : refusé AVANT installation, sans
    /// quoi `E5Encoder` échouerait plus tard, loin de la cause.
    func testUnexpectedModelIdentityIsRefused() throws {
        let target = targetDirectory()
        let tree = try makeModelTree(metaJSON: meta(modelID: "e5-large", revision: 7))
        XCTAssertThrowsError(try install(tree, into: target)) {
            guard case ModelDownloadError.badIdentity = $0 else {
                return XCTFail("attendu badIdentity, obtenu \($0)")
            }
        }
        XCTAssertFalse(EmbedPaths.modelAvailable(at: target))
    }

    func testSizeMismatchIsRefused() throws {
        let target = targetDirectory()
        let packed = try zip(try makeModelTree())
        XCTAssertThrowsError(
            try ModelDownloader.install(into: target, from: packed.url,
                                        sha256: packed.sha256,
                                        expectedBytes: 999_999_999)) {
            guard case ModelDownloadError.sizeMismatch = $0 else {
                return XCTFail("attendu sizeMismatch, obtenu \($0)")
            }
        }
        XCTAssertFalse(EmbedPaths.modelAvailable(at: target))
    }

    /// `FOUINE_MODEL_SHA256` doit VRAIMENT permettre d'installer sa propre
    /// archive : la taille de l'archive de référence ne doit plus lui être
    /// opposée. Régression constatée en recette le 02/09 — l'override était
    /// documenté et inutilisable.
    func testEnvironmentHashOverrideRelaxesTheSizeCheck() throws {
        let target = targetDirectory()
        let packed = try zip(try makeModelTree())
        setenv("FOUINE_MODEL_SHA256", packed.sha256, 1)
        defer { unsetenv("FOUINE_MODEL_SHA256") }

        // `expectedBytes` reste à sa valeur de production : c'est exactement la
        // situation de la CLI, où l'utilisateur n'a que la variable.
        let status = try ModelDownloader.install(into: target, from: packed.url)
        XCTAssertTrue(status.installed)
    }

    func testMissingSourceFileIsNotFound() throws {
        XCTAssertThrowsError(
            try ModelDownloader.install(
                into: targetDirectory(),
                from: sandbox.appendingPathComponent("absent.zip"),
                sha256: String(repeating: "0", count: 64),
                expectedBytes: 0)) {
            guard case ModelDownloadError.notFound = $0 else {
                return XCTFail("attendu notFound, obtenu \($0)")
            }
        }
    }

    // MARK: - Annulation

    func testCancelledBeforeStartInstallsNothing() throws {
        let target = targetDirectory()
        let packed = try zip(try makeModelTree())
        let token = ModelDownloadCancellation()
        token.cancel()
        XCTAssertThrowsError(
            try ModelDownloader.install(into: target, from: packed.url,
                                        sha256: packed.sha256,
                                        expectedBytes: 0,
                                        cancellation: token)) {
            guard case ModelDownloadError.cancelled = $0 else {
                return XCTFail("attendu cancelled, obtenu \($0)")
            }
        }
        XCTAssertFalse(EmbedPaths.modelAvailable(at: target))
        XCTAssertEqual(leftovers(in: target.deletingLastPathComponent()), [])
    }

    // MARK: - Progression

    func testProgressReachesTheEndOfEveryPhase() throws {
        let target = targetDirectory()
        let packed = try zip(try makeModelTree())
        let seen = PhaseBox()
        try ModelDownloader.install(into: target, from: packed.url,
                                    sha256: packed.sha256,
                                    expectedBytes: 0,
                                    progress: { seen.record($0) })
        XCTAssertTrue(seen.phases.contains(.downloading))
        XCTAssertTrue(seen.phases.contains(.verifying))
        XCTAssertTrue(seen.phases.contains(.extracting))
        XCTAssertTrue(seen.phases.contains(.installing))
        XCTAssertGreaterThan(seen.maxBytes, 0)
    }

    /// Le rappel de progression est appelé depuis un fil quelconque.
    private final class PhaseBox: @unchecked Sendable {
        private let mutex = NSLock()
        private var storedPhases: Set<ModelDownloadPhase> = []
        private var storedBytes: Int64 = 0
        func record(_ p: ModelDownloadProgress) {
            mutex.lock()
            storedPhases.insert(p.phase)
            storedBytes = max(storedBytes, p.bytesReceived)
            mutex.unlock()
        }
        var phases: Set<ModelDownloadPhase> {
            mutex.lock(); defer { mutex.unlock() }; return storedPhases
        }
        var maxBytes: Int64 { mutex.lock(); defer { mutex.unlock() }; return storedBytes }
    }

    // MARK: - État et suppression

    func testStatusAndRemove() throws {
        let target = targetDirectory()
        XCTAssertFalse(ModelDownloader.status(directory: target).installed)
        XCTAssertEqual(ModelDownloader.status(directory: target).bytesOnDisk, 0)

        try install(try makeModelTree(), into: target)
        XCTAssertTrue(ModelDownloader.status(directory: target).installed)

        XCTAssertTrue(try ModelDownloader.remove(directory: target))
        XCTAssertFalse(ModelDownloader.status(directory: target).installed)
        // Deux fois de suite : sans erreur, et sans rien à supprimer.
        XCTAssertFalse(try ModelDownloader.remove(directory: target))
    }
}
