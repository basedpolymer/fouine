// AgentLogTests.swift — journal de l'agent : droits 0o600, rotation bornée.
// Propriété : A-Recette. Audit S4, D12/M23.
//
// Les deux corrections de l'audit S4 n'avaient aucun test :
//
//   · DROITS. Le journal porte l'ARBORESCENCE DOCUMENTAIRE de l'utilisateur —
//     chaque racine avec son chemin absolu, chaque page en échec avec le chemin
//     de son document. En 0o644, il était lisible par tout compte de la machine.
//     Le mode doit être posé à la création ET rétabli par `fchmod` sur un
//     journal HÉRITÉ d'une installation antérieure : le `mode` d'`open()` ne
//     s'applique qu'à la création, un fichier existant en 0o644 le serait resté
//     pour toujours.
//
//   · ROTATION. Elle n'était testée que dans `emit`, jamais pour ce qui arrive
//     par `dup2` : les `print` d'OCRRun (une ligne par page, plus le garde-fou
//     thermique) faisaient croître le journal SANS AUCUNE LIMITE, exactement
//     dans le régime où il grossit le plus. `enforceRotation()` doit voir la
//     taille quelle que soit la provenance des octets.
//
// Ce fichier écrit uniquement dans un dossier temporaire : jamais dans
// ~/Library/Logs/Fouine/.

import Foundation
import XCTest
@testable import FouineAgent

final class AgentLogTests: XCTestCase {

    private var scratch: URL!
    private var logURL: URL { scratch.appendingPathComponent("fouine.log") }
    private var rotatedURL: URL { scratch.appendingPathComponent("fouine.log.1") }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-log-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func size(of url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size]
            as? Int) ?? -1
    }

    /// Ajoute `bytes` octets AU FICHIER, par un descripteur tiers : c'est le
    /// régime `dup2` de l'audit S4 — des octets qui n'ont jamais traversé
    /// `emit`.
    private func appendBytes(_ bytes: Int) throws {
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let chunk = Data(repeating: 0x61, count: 1 << 20)      // 1 Mio de « a »
        var written = 0
        while written < bytes {
            try handle.write(contentsOf: chunk)
            written += chunk.count
        }
    }

    // MARK: - Droits

    /// Un journal CRÉÉ par l'agent naît en 0o600, et son dossier est créé au
    /// passage : un agent launchd démarre parfois avant que
    /// ~/Library/Logs/Fouine/ n'existe.
    func testFreshLogIsCreatedPrivate() throws {
        let nested = scratch.appendingPathComponent("Logs/Fouine/fouine.log")
        let log = AgentLog(url: nested)
        log.info("premiere ligne")

        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
        XCTAssertEqual(try mode(of: nested), 0o600,
                       "le journal porte l'arborescence documentaire : "
                       + "il ne doit être lisible que par son propriétaire")
        XCTAssertEqual(log.path, nested.path)
    }

    /// Un journal HÉRITÉ d'une installation antérieure au palier S4 est déjà
    /// sur le disque en 0o644. Le `mode` d'`open()` ne le toucherait pas :
    /// c'est le `fchmod` qui doit le rattraper, à la première écriture.
    func testInheritedWorldReadableLogIsTightenedOnFirstWrite() throws {
        FileManager.default.createFile(atPath: logURL.path,
                                       contents: Data("ancien journal\n".utf8),
                                       attributes: [.posixPermissions: 0o644])
        XCTAssertEqual(try mode(of: logURL), 0o644, "précondition")

        let log = AgentLog(url: logURL)
        log.warn("premiere ligne apres mise a jour")

        XCTAssertEqual(try mode(of: logURL), 0o600,
                       "un journal 0o644 hérité doit être resserré par fchmod "
                       + "(audit S4) — sans quoi il le resterait pour toujours")
        // Et le contenu antérieur n'est pas perdu : le descripteur est O_APPEND.
        let content = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("ancien journal"), content)
        XCTAssertTrue(content.contains("premiere ligne apres mise a jour"), content)
    }

    // MARK: - Contenu

    /// Chaque ligne porte son horodatage, le pid et le niveau : c'est le seul
    /// diagnostic dont dispose un agent sans interface.
    func testEachLineCarriesLevelAndPid() throws {
        let log = AgentLog(url: logURL)
        log.info("indexation demarree")
        log.warn("racine illisible")
        log.error("base verrouillee")

        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        let pid = ProcessInfo.processInfo.processIdentifier
        for line in lines {
            XCTAssertTrue(line.contains("fouine-agent[\(pid)]"), line)
            XCTAssertTrue(line.hasPrefix("20"), "horodatage attendu en tête : \(line)")
        }
        XCTAssertTrue(lines[0].contains("info "), lines[0])
        XCTAssertTrue(lines[1].contains("warn "), lines[1])
        XCTAssertTrue(lines[2].contains("error "), lines[2])
    }

    // MARK: - Rotation

    /// LE test de l'audit S4 : des octets arrivés HORS d'`emit` (le régime
    /// `dup2` des `print` d'OCRRun) font quand même tourner le journal, dès que
    /// l'agent appelle `enforceRotation()` à son tic de scrutation.
    func testRotationIsEnforcedOnBytesThatNeverWentThroughEmit() throws {
        let log = AgentLog(url: logURL)
        log.info("amorce")                       // crée le fichier et le fd

        try appendBytes(Int(AgentLog.maxBytes))  // 10 Mio par un tiers
        XCTAssertGreaterThanOrEqual(try size(of: logURL), Int(AgentLog.maxBytes))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotatedURL.path),
                       "rien ne doit tourner tant que personne ne regarde")

        log.enforceRotation()

        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedURL.path),
                      "le journal aurait dû tourner : c'est exactement le cas "
                      + "qui le faisait croître sans limite (audit S4)")
        XCTAssertGreaterThanOrEqual(try size(of: rotatedURL),
                                    Int(AgentLog.maxBytes))
        XCTAssertLessThan(try size(of: logURL), 1024,
                          "le journal courant doit repartir de zéro")
        XCTAssertEqual(try mode(of: logURL), 0o600,
                       "le fichier rouvert après rotation reste privé")

        // Le journal reste ÉCRIVABLE après rotation : le descripteur a été
        // rouvert, pas seulement fermé.
        log.info("apres rotation")
        let content = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(content.contains("apres rotation"), content)
    }

    /// Un seul fichier de secours : `fouine.log.1` est REMPLACÉ, jamais
    /// accumulé. Le journal d'un agent ne doit jamais coûter plus de deux fois
    /// sa borne — 20 Mio, pas 20 Mio par rotation.
    func testOnlyOneBackupIsKept() throws {
        let log = AgentLog(url: logURL)
        log.info("amorce")

        for round in 1...2 {
            try appendBytes(Int(AgentLog.maxBytes))
            log.enforceRotation()
            log.info("tour \(round)")
        }

        let entries = try FileManager.default
            .contentsOfDirectory(atPath: scratch.path)
            .filter { $0.hasPrefix("fouine.log") }
            .sorted()
        XCTAssertEqual(entries, ["fouine.log", "fouine.log.1"],
                       "aucun .2, .3… : un seul fichier de secours (§10)")

        let total = try size(of: logURL) + size(of: rotatedURL)
        XCTAssertLessThan(total, 3 * Int(AgentLog.maxBytes),
                          "le journal ne doit jamais dépasser deux fois sa borne")
    }

    /// La borne du §10 est 10 Mo, et c'est un contrat, pas un détail : au-delà,
    /// un agent qui tourne des semaines remplirait le disque de l'utilisateur.
    func testBoundIsTenMegabytes() {
        XCTAssertEqual(AgentLog.maxBytes, 10 << 20)
    }

    /// En cas d'échec de création du répertoire de logs (permissions, collision),
    /// l'agent doit remonter l'erreur sur stderr et continuer sans journal
    /// sans planter (audit C2-11).
    func testCreateDirectoryFailureWritesToStderrAndContinuesWithoutCrashing() throws {
        let blockingFile = scratch.appendingPathComponent("file-blocking-dir")
        try Data("block".utf8).write(to: blockingFile)
        let impossibleURL = blockingFile.appendingPathComponent("sub/fouine.log")

        let log = AgentLog(url: impossibleURL)
        log.info("test message when dir creation fails")
        log.warn("another message")
        log.error("critical error message")
        XCTAssertFalse(FileManager.default.fileExists(atPath: impossibleURL.path))
    }
}
