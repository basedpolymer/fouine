// CLIInstaller.swift — « Installer l'outil en ligne de commande… » (audit D1/V9).
// Propriété : A-App. SPEC §11.2.
//
// La CLI `fouine` est désormais copiée dans `Contents/Helpers/fouine` par
// `bundle.sh` : elle est donc SIGNÉE avec l'app et voit la même base (même
// chemin par défaut, même variable `FOUINE_DB`, cf. `AppPaths.databaseURL()` et
// `CLI.databaseURL()`). Reste à la rendre appelable depuis un terminal.
//
// Un lien symbolique, pas une copie : une copie divergerait à la première mise à
// jour de l'app et lirait la base avec un schéma périmé.
//
// L'app ne lance JAMAIS `sudo` : si `/usr/local/bin` n'est pas inscriptible —
// c'est le cas d'un Mac neuf, où le dossier n'existe même pas — elle affiche la
// commande à coller, et la met dans le presse-papiers. Demander un mot de passe
// administrateur depuis une app de recherche documentaire serait exactement le
// genre de geste qu'un utilisateur prudent doit refuser.

import Foundation
import AppKit

enum CLIInstaller {

    struct Outcome {
        let title: String
        let message: String
        /// Commande copiée dans le presse-papiers, s'il y en a une.
        let command: String?
    }

    /// L'élément de menu n'existe que si la CLI est là : hors bundle
    /// (`swift run FouineApp`), il n'y a rien à installer.
    static var isAvailable: Bool { AppPaths.bundledCLI() != nil }

    static func install() -> Outcome {
        guard let source = AppPaths.bundledCLI() else {
            return Outcome(
                title: String(localized: "Command line tool not found"),
                message: String(localized: "This copy of Fouine does not contain `fouine` in Contents/Helpers. Rebuild the app with `make bundle`."),
                command: nil)
        }
        let link = AppPaths.cliLinkURL
        let fm = FileManager.default

        // Déjà en place et pointant au bon endroit : ne rien refaire.
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path),
           existing == source.path {
            return Outcome(
                title: String(localized: "Already installed"),
                message: String(localized: "`\(link.path)` already points at this copy of Fouine.\n\nCheck with: fouine --version"),
                command: nil)
        }

        let directory = link.deletingLastPathComponent()
        guard fm.fileExists(atPath: directory.path),
              fm.isWritableFile(atPath: directory.path) else {
            return manualOutcome(source: source, link: link,
                                 needsDirectory: !fm.fileExists(atPath: directory.path))
        }

        do {
            // Un lien mort ou un lien vers une AUTRE copie de Fouine se remplace ;
            // un vrai fichier, non — ce n'est pas à nous de supprimer le binaire
            // que quelqu'un a installé là (Homebrew, compilation manuelle).
            if let attributes = try? fm.attributesOfItem(atPath: link.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                try fm.removeItem(at: link)
            } else if fm.fileExists(atPath: link.path) {
                return Outcome(
                    title: String(localized: "Installation impossible"),
                    message: String(localized: "`\(link.path)` already exists and is not a symbolic link. Remove it yourself if you want Fouine to replace it."),
                    command: nil)
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: source)
        } catch {
            return manualOutcome(source: source, link: link, needsDirectory: false)
        }

        return Outcome(
            title: String(localized: "Command line tool installed"),
            message: String(localized: "`\(link.path)` now points at this copy of Fouine.\n\nOpen a terminal and try: fouine search \"your term\"\nThe CLI and the app share the same database."),
            command: nil)
    }

    private static func manualOutcome(source: URL, link: URL,
                                      needsDirectory: Bool) -> Outcome {
        let command = (needsDirectory ? "sudo mkdir -p \(link.deletingLastPathComponent().path) && " : "")
            + "sudo ln -sf '\(source.path)' '\(link.path)'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        return Outcome(
            title: String(localized: "To finish in Terminal"),
            message: String(localized: "\(link.deletingLastPathComponent().path) is not writable by Fouine, and the app never asks for an administrator password. The command below has been copied to the clipboard:\n\n\(command)"),
            command: command)
    }
}
