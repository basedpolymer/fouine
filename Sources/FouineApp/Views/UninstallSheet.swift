// UninstallSheet.swift — « Désinstaller Fouine… » (audit D13). Propriété : A-App.
//
// La feuille ne décide de rien : elle AFFICHE le plan calculé par
// `Uninstaller.plan` — chemins résolus, tailles, ce qui est refusé et pourquoi
// — et rend les trois suppressions optionnelles. Ce qui n'est pas optionnel
// (désenregistrer l'agent, retirer notre lien de ligne de commande, mettre
// l'app à la corbeille) est ce qui n'a aucun sens à laisser derrière soi.
//
// ELLE DIT AUSSI CE QU'ELLE NE FAIT PAS, et ce n'est pas de la politesse : la
// première question de quelqu'un qui clique « Désinstaller » sur un moteur de
// recherche documentaire est « et mes documents ? ». La réponse — aucun dossier
// indexé n'est touché, Fouine n'y a jamais écrit — doit être sous ses yeux au
// moment du clic, pas dans une documentation.

import Foundation
import SwiftUI
import AppKit

struct UninstallSheet: View {
    @EnvironmentObject private var app: AppModel

    @State private var plan: Uninstaller.Plan?
    @State private var options = Uninstaller.Options()
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Uninstall Fouine").font(.title3.weight(.semibold))

            Text("Fouine undoes what it installed on this Mac, and nothing else. **No indexed folder is touched**: Fouine has never written inside them, not even to store recognised text.")
                .fixedSize(horizontal: false, vertical: true)

            if let plan {
                Divider()
                always(plan)
                Divider()
                optional(plan)
                Divider()
                afterwards(plan)
            } else {
                ProgressView { Text("Working out what is installed…") }
                    .progressViewStyle(.linear)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { app.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Uninstall", role: .destructive) { uninstall() }
                    .disabled(plan == nil || working)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            // Le calcul parcourt `Application Support/Fouine` pour en faire la
            // taille — plusieurs gigaoctets, des dizaines de milliers d'entrées :
            // jamais sur le fil principal.
            plan = await Task.detached(priority: .userInitiated) {
                Uninstaller.currentPlan()
            }.value
        }
    }

    // MARK: - Ce qui sera fait dans tous les cas

    @ViewBuilder
    private func always(_ plan: Uninstaller.Plan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Background indexing is stopped, and Fouine waits until it has finished writing to the index.", systemImage: "bolt.slash")
                .fixedSize(horizontal: false, vertical: true)
            cli(plan.cli)
        }
    }

    @ViewBuilder
    private func cli(_ state: Uninstaller.CLILink) -> some View {
        switch state {
        case .absent:
            Label("No `fouine` command was installed in /usr/local/bin: there is nothing to undo there.", systemImage: "terminal")
                .fixedSize(horizontal: false, vertical: true)
        case .ours(let link, _):
            Label("The `\(link.path)` link is removed: it points inside this copy of Fouine.", systemImage: "terminal")
                .fixedSize(horizontal: false, vertical: true)
        case .manual(let link, let command):
            VStack(alignment: .leading, spacing: 3) {
                Label("`\(link.deletingLastPathComponent().path)` is not writable by Fouine, and the application never asks for an administrator password. The command below will be copied to the clipboard:", systemImage: "terminal")
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        case .foreign(let link, let target):
            VStack(alignment: .leading, spacing: 3) {
                Label("`\(link.path)` is left alone: it does not point inside this copy of Fouine.", systemImage: "hand.raised")
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: "→ \(target)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        case .notALink(let link):
            Label("`\(link.path)` is a real file, not a link made by Fouine: it is left alone. Remove it yourself if it is no longer wanted.", systemImage: "hand.raised")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Ce qui est optionnel

    @ViewBuilder
    private func optional(_ plan: Uninstaller.Plan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("The deletions below are permanent and irreversible (files are deleted directly, not moved to the Trash).", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            box(targets: plan.support,
                title: "Delete the index and the settings",
                detail: Text("The index, its working files and the model for search by meaning. Rebuilding it means reading and recognising every document again, which can take hours."),
                isOn: $options.deleteIndex)
            box(targets: [plan.logs],
                title: "Delete the logs",
                detail: Text("What background indexing wrote about its own runs. Nothing from your documents is in there."),
                isOn: $options.deleteLogs)
            box(targets: [plan.preferences],
                title: "Delete the preferences",
                detail: Text("Search history, saved searches, the state of the switches, the size and position of the window."),
                isOn: $options.deletePreferences)
        }
    }

    /// `detail` est passé en `Text` DÉJÀ construit, et pas en
    /// `LocalizedStringKey` : le lint de traduction ne reconnaît que les
    /// littéraux qui suivent un marqueur (`Text(`, `Button(`, `title: `…), et
    /// un `detail: "…"` lui échapperait en silence (docs/i18n.md).
    ///
    /// PLUSIEURS CIBLES POUR UNE CASE : quand la base ne vit pas dans un dossier
    /// à nous, « supprimer l'index » vise le fichier et ses deux compagnons de
    /// travail, jamais le dossier qui les contient (BU-32). La case reste UNE
    /// case — c'est un seul geste pour l'utilisateur — et les chemins sont tous
    /// affichés, comme avant.
    /// (`title` est sur sa propre ligne : `l10n-lint` prend une ligne qui porte
    /// à la fois `LocalizedStringKey` et un `[` pour le début d'un tableau de
    /// clés, et lit alors tout le reste du fichier comme des littéraux à
    /// traduire.)
    /// La taille d'une case à cocher. `allowsNonnumericFormatting` éteint,
    /// et c'est tout l'objet : le formateur du système rend « Zéro ko » en
    /// français et « Zero KB » en anglais, ce qui, au milieu d'une phrase à
    /// tiret — « Supprimer les journaux — Zéro ko » —, se lit comme une faute
    /// de frappe (BU-12). On veut « 0 ko ».
    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    private static func size(_ bytes: Int64) -> String {
        sizeFormatter.string(fromByteCount: bytes)
    }

    private func box(targets: [Uninstaller.Target],
                     title: LocalizedStringKey,
                     detail: Text,
                     isOn: Binding<Bool>) -> some View {
        let bytes = targets.reduce(Int64(0)) { $0 + $1.bytes }
        let exists = targets.contains(where: \.exists)
        let removable = targets.contains { $0.exists && $0.removable }
        return VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: isOn) {
                Text("\(Text(title)) — \(Self.size(bytes))")
            }
            .disabled(!exists || !removable)
            ForEach(targets.filter { $0.exists || targets.count == 1 },
                    id: \.url) { target in
                Text(verbatim: target.url.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if !exists {
                Text("Nothing at this location.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !removable {
                // GARDE-FOU. `FOUINE_DB` et `FOUINE_AGENT_LOG` peuvent désigner
                // n'importe quel chemin de la machine ; la désinstallation vise
                // les emplacements RÉSOLUS, mais elle n'efface jamais hors de
                // ~/Library. Le chemin est montré, et c'est tout.
                Label("This one is outside the folder Fouine installed, so Fouine leaves it alone. Remove it yourself if you want it gone.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Ce qui vient après

    @ViewBuilder
    private func afterwards(_ plan: Uninstaller.Plan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let bundle = plan.bundle {
                Label("`\(bundle.path)` is moved to the Trash, then Fouine quits.", systemImage: "trash")
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline) {
                Label("The privacy permissions you granted stay listed in System Settings; macOS keeps them, and only you can remove them.", systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") {
                    NSWorkspace.shared.open(AppPaths.privacyFilesPaneURL)
                }
            }
        }
    }

    // MARK: - Exécution

    /// Le travail se fait HORS du fil principal, et pas par élégance : il attend
    /// que l'agent lâche `fouine.lock` (jusqu'à 8 s) puis la fin de la mise à la
    /// corbeille. Sur le fil principal, cette dernière attente est un blocage
    /// mutuel si AppKit livre son rappel sur la file principale.
    private func uninstall() {
        guard let plan, !working else { return }
        working = true
        let chosen = options
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Uninstaller.perform(plan, options: chosen)
            }.value
            report(outcome)
            NSApp.terminate(nil)
        }
    }

    /// Ce qui n'a pas pu être fait, dit avant de quitter — et la commande à
    /// coller, s'il en reste une, mise dans le presse-papiers.
    private func report(_ outcome: Uninstaller.Outcome) {
        var lines: [String] = []
        if let command = outcome.command {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            lines.append(String(localized: "One thing is left to do in Terminal; the command has been copied to the clipboard:\n\n\(command)"))
        }
        lines.append(contentsOf: outcome.failures)
        guard !lines.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Uninstall finished, with something left to do")
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}
