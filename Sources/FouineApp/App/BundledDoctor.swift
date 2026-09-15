// BundledDoctor.swift — le « Diagnostic » de l'écran d'échec d'ouverture (lot I1, B1-14).
// Propriété : A-App. SPEC §5.6.
//
// POURQUOI PAS LE TERMINAL. Le bouton H4 « Lancer fouine doctor dans le
// Terminal » ne pouvait pas marcher : l'app n'a pas le droit
// `com.apple.security.automation.apple-events` (Packaging/Fouine.entitlements,
// délibérément — Fouine ne pilote aucune autre application) ni de
// `NSAppleEventsUsageDescription` ; `NSAppleScript` vers Terminal échouait
// donc en silence, et le repli ouvrait un Terminal vide. L'app lance ELLE-MÊME
// le binaire qu'elle embarque (`Contents/Helpers/fouine doctor`) et montre sa
// sortie dans une feuille, avec « Copier » pour le rapport de bogue.
//
// La sortie s'adresse au dépanneur à qui l'utilisateur la copie : elle reste
// en anglais, comme tout ce que la CLI écrit (docs/i18n.md).

import Foundation
import FouineCore

enum BundledDoctor {
    struct Output: Equatable, Sendable {
        let text: String
        let exitCode: Int32
        let timedOut: Bool
    }

    /// `doctor` sans `--deep` lit `fouine.lock` et `agent_status`, appelle
    /// `launchctl print` et ouvre UN fichier par racine ; une racine sur un
    /// volume réseau endormi peut faire traîner cette lecture. Au-delà de 30 s,
    /// la feuille montre ce qui a été obtenu et le dit, plutôt que de tourner.
    static let timeout: TimeInterval = 30

    /// Vrai dans Fouine.app, faux sous `swift run` : le bouton se cache sinon.
    static var isAvailable: Bool { AppPaths.bundledCLI() != nil }

    /// `nil` si le binaire embarqué est absent. Jamais sur le fil principal :
    /// la lecture des tuyaux et l'attente du processus bloquent.
    static func run(databaseURL: URL, timeout: TimeInterval = timeout) async -> Output? {
        guard let cli = AppPaths.bundledCLI() else { return nil }
        return await Task.detached(priority: .userInitiated) {
            runSynchronously(cli: cli, databaseURL: databaseURL, timeout: timeout)
        }.value
    }

    /// Collecte d'un tuyau depuis une file globale ; `group.wait()` garantit que
    /// la lecture est finie avant qu'on ne lise `data`.
    private final class Sink: @unchecked Sendable {
        var data = Data()
    }

    static func runSynchronously(cli: URL, databaseURL: URL, timeout: TimeInterval) -> Output {
        let process = Process()
        process.executableURL = cli
        process.arguments = ["doctor"]
        // Environnement FIGÉ, comme pour tout sous-processus (audit S1), plus la
        // base de CETTE app : sans `FOUINE_DB`, la CLI regarderait l'emplacement
        // standard, qui n'est pas forcément celui que l'app n'arrive pas à
        // ouvrir. `HOME` pour le modèle sémantique et les journaux, que la CLI
        // cherche sous ~/Library.
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "HOME": NSHomeDirectory(),
            "FOUINE_DB": databaseURL.path,
        ]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let outSink = Sink()
        let errSink = Sink()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outSink.data = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errSink.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        do {
            try process.run()
        } catch {
            // Les lecteurs finiront d'eux-mêmes : les extrémités d'écriture des
            // tuyaux se ferment avec `process`, qui n'a rien à écrire.
            return Output(
                text: "cannot run \(cli.path): \((error as NSError).localizedDescription)\n",
                exitCode: -1, timedOut: false)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace {
                usleep(50_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        group.wait()

        var text = String(decoding: outSink.data, as: UTF8.self)
        let stderr = String(decoding: errSink.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += stderr + "\n"
        }
        if timedOut {
            text += "\n[fouine doctor was stopped after \(Int(timeout)) s]\n"
        }
        return Output(text: text, exitCode: process.terminationStatus, timedOut: timedOut)
    }
}
