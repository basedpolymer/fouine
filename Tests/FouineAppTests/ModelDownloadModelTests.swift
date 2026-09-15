// ModelDownloadModelTests.swift — l'installation du modèle vue de l'interface
// (audit D6, palier 3.4). Propriété : A-App.
//
// AUCUN RÉSEAU, ET AUCUN TOUCHER À L'INSTALLATION RÉELLE. Chaque test fabrique
// son archive (`ditto -c -k --keepParent`, exactement comme
// `FouineEmbedTests/ModelDownloadTests`), la sert par une URL `file://`
// (`FOUINE_MODEL_URL`), en donne l'empreinte (`FOUINE_MODEL_SHA256`) et installe
// dans un répertoire temporaire injecté au modèle. `~/Library/Application
// Support/Fouine/models` n'est jamais ni lu ni écrit.
//
// Ce que ces tests tiennent, et que rien d'autre ne tient :
//   · une seconde installation ne rend PAS `alreadyInstalled` — c'est le piège
//     de l'API, et l'utilisateur qui clique « Télécharger » ne doit jamais lire
//     cette phrase ;
//   · un échec laisse le modèle ABSENT et un message rendu depuis le CAS, dans
//     la langue de l'app — jamais le `description` français du moteur ;
//   · le 404 a sa propre phrase : l'asset du modèle est publié séparément de
//     l'application (RELEASING.md § 5 bis), le cas arrive en usage normal.

import Foundation
import XCTest
import CryptoKit
import FouineEmbed
@testable import FouineApp

@MainActor
final class ModelDownloadModelTests: XCTestCase {

    // MARK: - Bac à sable

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-model-model-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv(ModelDownloader.urlVariable)
        unsetenv(ModelDownloader.sha256Variable)
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    /// Répertoire cible : sous le bac à sable, JAMAIS celui de production.
    private var target: URL {
        sandbox.appendingPathComponent("models/e5-small", isDirectory: true)
    }

    private func makeModel(expectedBytes: Int64 = 0) -> ModelDownloadModel {
        ModelDownloadModel(directory: target, expectedBytes: expectedBytes)
    }

    // MARK: - Fabrication d'une archive

    private func meta(revision: Int = ModelDownloader.expectedRevision) -> String {
        """
        {"model_id": "\(ModelDownloader.expectedModelID)", \
        "revision": \(revision), "dim": 384, "seq": 256, "bos_id": 0, \
        "eos_id": 2, "pad_id": 1, "prefix_query": "query: ", \
        "prefix_passage": "passage: "}
        """
    }

    /// Les trois pièces qu'`EmbedPaths.modelAvailable` exige, et rien de plus.
    private func makeTree() throws -> URL {
        let fm = FileManager.default
        let root = sandbox
            .appendingPathComponent("build-\(UUID().uuidString)/e5-small",
                                    isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try meta().write(to: root.appendingPathComponent("meta.json"),
                         atomically: true, encoding: .utf8)
        try "[[\"▁le\", -1.0]]".write(
            to: root.appendingPathComponent("vocab.json"),
            atomically: true, encoding: .utf8)
        let compiled = root.appendingPathComponent("E5Small.mlmodelc",
                                                   isDirectory: true)
        try fm.createDirectory(at: compiled, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 256).write(
            to: compiled.appendingPathComponent("coremldata.bin"))
        return root
    }

    /// `ditto -c -k --keepParent` : le dossier de tête reste dans le zip, comme
    /// dans l'archive publiée.
    @discardableResult
    private func publishArchive() throws -> (url: URL, sha256: String) {
        let tree = try makeTree()
        let archive = sandbox.appendingPathComponent("\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", tree.path, archive.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "ditto -c -k a échoué")
        let digest = SHA256.hash(data: try Data(contentsOf: archive))
            .map { String(format: "%02x", $0) }.joined()
        setenv(ModelDownloader.urlVariable, archive.absoluteString, 1)
        setenv(ModelDownloader.sha256Variable, digest, 1)
        return (archive, digest)
    }

    // MARK: - Le chemin normal

    func testDownloadInstallsFromALocalArchive() async throws {
        try publishArchive()
        let model = makeModel()
        await model.download()

        XCTAssertNil(model.failure, "installation refusée : \(model.failure?.message ?? "")")
        XCTAssertNil(model.transfer, "le transfert doit être retombé au repos")
        XCTAssertTrue(model.justInstalled)
        XCTAssertEqual(model.installed?.revision, ModelDownloader.expectedRevision)
        XCTAssertEqual(model.installed?.modelID, ModelDownloader.expectedModelID)
        XCTAssertGreaterThan(model.installed?.bytesOnDisk ?? 0, 0)
        XCTAssertTrue(EmbedPaths.modelAvailable(at: target))
    }

    /// LE piège de l'API : `install` jette `alreadyInstalled` quand le modèle
    /// est là et que `force` est faux. Le modèle relit l'état avant de partir,
    /// et réinstalle — personne ne doit lire cette phrase après avoir cliqué.
    func testSecondDownloadReinstallsInsteadOfFailing() async throws {
        try publishArchive()
        let model = makeModel()
        await model.download()
        XCTAssertNil(model.failure)

        try publishArchive()          // une seconde archive, même identité
        await model.download()
        XCTAssertNil(model.failure,
                     "seconde installation refusée : \(model.failure?.message ?? "")")
        XCTAssertEqual(model.installed?.revision, ModelDownloader.expectedRevision)
    }

    func testRemoveDeletesTheModel() async throws {
        try publishArchive()
        let model = makeModel()
        await model.download()
        XCTAssertNotNil(model.installed)

        await model.remove()
        XCTAssertNil(model.installed)
        XCTAssertNil(model.failure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        // Deux fois de suite : la suppression est idempotente, comme
        // `fouine model remove`.
        await model.remove()
        XCTAssertNil(model.failure)
    }

    // MARK: - Les refus

    func testWrongFingerprintInstallsNothing() async throws {
        try publishArchive()
        setenv(ModelDownloader.sha256Variable, String(repeating: "0", count: 64), 1)

        let model = makeModel()
        await model.download()

        XCTAssertNil(model.installed, "une archive refusée ne doit rien installer")
        XCTAssertFalse(model.justInstalled)
        XCTAssertNil(model.transfer)
        let message = try XCTUnwrap(model.failure?.message)
        XCTAssertTrue(message.contains("SHA-256"), message)
        // La phrase est celle de l'APP, pas celle du moteur (qui est française).
        XCTAssertFalse(message.contains("empreinte"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    /// L'asset du modèle est publié séparément de l'application : une version
    /// installée avant la mise en ligne de son modèle voit un 404, et doit lire
    /// « pas encore publié », pas « erreur réseau ».
    func testMissingArchiveSaysTheModelIsNotPublishedYet() async throws {
        let absent = sandbox.appendingPathComponent("jamais-publie.zip")
        setenv(ModelDownloader.urlVariable, absent.absoluteString, 1)
        setenv(ModelDownloader.sha256Variable, String(repeating: "0", count: 64), 1)

        let model = makeModel()
        await model.download()

        XCTAssertNil(model.installed)
        let failure = try XCTUnwrap(model.failure)
        XCTAssertEqual(failure.message,
                       ErrorText.describe(ModelDownloadError.notFound(absent)))
        XCTAssertTrue(failure.message.contains("404"), failure.message)
        // Le détail est une DONNÉE — l'adresse —, jamais une phrase.
        XCTAssertEqual(failure.detail, absent.absoluteString)
    }

    // MARK: - Rendu des erreurs

    /// Chaque cas rend une phrase, et aucune n'est celle du moteur.
    ///
    /// `swift test` ne tourne pas depuis Fouine.app : `String(localized:)` rend
    /// la CLÉ, c'est-à-dire l'anglais source. C'est sur cet anglais-là que
    /// portent les assertions ; le français se vérifie au catalogue (`L10nTests`).
    func testEveryErrorCaseIsRenderedFromItsCase() {
        let url = URL(string: "https://example.invalid/e5.zip")!
        let cases: [ModelDownloadError] = [
            .badURL("pas une adresse"),
            .unsupportedScheme("ftp://x"),
            .notFound(url),
            .httpStatus(503, url),
            .transport("réseau coupé"),
            .cancelled,
            .notEnoughSpace(needed: 1_000, available: 10, path: "/tmp"),
            .sizeMismatch(expected: 10, got: 5),
            .hashMismatch(expected: "aa", got: "bb"),
            .extraction("ditto"),
            .badLayout("meta.json absent"),
            .badIdentity(gotID: "x", gotRevision: 2,
                         wantID: "multilingual-e5-small", wantRevision: 1),
            .install("disque plein"),
            .alreadyInstalled(revision: 1),
        ]
        for error in cases {
            let rendered = ErrorText.describe(error)
            XCTAssertFalse(rendered.isEmpty, "\(error) rend une phrase vide")
            // La phrase de l'app est CONSTRUITE depuis le cas (`ErrorText`),
            // celle du moteur est la phrase anglaise de `fouine model`. Depuis
            // le palier 3.5 elles peuvent coïncider mot pour mot : ce qui se
            // vérifie, c'est qu'`ErrorText` sait rendre CHAQUE cas, ce que
            // fait la boucle, pas qu'il choisit d'autres mots.
            // `ErrorText.describe(_: Error)` doit router vers la même phrase.
            XCTAssertEqual(ErrorText.describe(error as Error), rendered)
        }
    }

    // MARK: - Progression

    func testFractionIsNilWhenTheTotalIsUnknown() {
        let unknown = ModelDownloadModel.Transfer(phase: .extracting,
                                                  received: 0, expected: 0)
        XCTAssertNil(unknown.fraction)

        let half = ModelDownloadModel.Transfer(phase: .downloading,
                                               received: 50, expected: 100)
        XCTAssertEqual(half.fraction ?? 0, 0.5, accuracy: 0.001)

        // Un serveur qui envoie plus que promis ne fait pas déborder la barre.
        let overflow = ModelDownloadModel.Transfer(phase: .downloading,
                                                   received: 300, expected: 100)
        XCTAssertEqual(overflow.fraction ?? 0, 1, accuracy: 0.001)
    }

    /// L'app rend les quatre phases DEPUIS LEUR CAS, et chacune a son nom.
    ///
    /// Comparer au libellé du moteur ne prouve plus rien depuis le palier 3.5,
    /// où il est lui aussi en anglais. Ce qui se vérifie ici : quatre noms
    /// distincts, aucun vide, et un rendu pour chaque cas.
    func testPhaseNamesAreDistinctAndNonEmpty() {
        let names = [ModelDownloadPhase.downloading, .verifying,
                     .extracting, .installing].map(ModelPhaseText.name)
        XCTAssertEqual(Set(names).count, 4, "deux phases portent le même nom")
        XCTAssertTrue(names.allSatisfy { !$0.isEmpty }, "\(names)")
    }

    /// L'étape restante reste affichée tant qu'aucune page n'est prête (A2-02).
    ///
    /// La barre latérale envoie l'utilisateur sur « Réglages ▸ Sémantique »
    /// dès que `availability == .noVectors` ; l'onglet n'y montrait le mode
    /// d'emploi que dans l'instant qui suit l'installation, et
    /// `ModelDownloadModel.refresh()` efface `justInstalled` au premier retour.
    func testRemainingStepStaysVisibleUntilPagesArePrepared() {
        // Modèle absent : rien à expliquer, c'est le bouton de téléchargement.
        XCTAssertFalse(SemanticAvailability.showsRemainingStep(
            modelInstalled: false, justInstalled: false, availability: .modelMissing))
        // Juste après l'installation : l'étape restante, comme avant.
        XCTAssertTrue(SemanticAvailability.showsRemainingStep(
            modelInstalled: true, justInstalled: true, availability: .unknown))
        // LE CAS DU BOGUE : modèle présent, aucune page prête, onglet rouvert.
        XCTAssertTrue(SemanticAvailability.showsRemainingStep(
            modelInstalled: true, justInstalled: false, availability: .noVectors),
            "A2-02 : l'onglet doit encore expliquer l'étape restante")
        // Préparation faite : plus une ligne là-dessus.
        XCTAssertFalse(SemanticAvailability.showsRemainingStep(
            modelInstalled: true, justInstalled: false,
            availability: .ready(vectors: 12)))
    }
}
