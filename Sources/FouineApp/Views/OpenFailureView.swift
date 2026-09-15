// OpenFailureView.swift — écran d'échec d'ouverture de l'index avec gestes (audit H4, lot I1, B1-14).
// Propriété : A-App. SPEC §5.6.
//
// Le public n'est pas technicien : le message dit le GESTE (« Mettez Fouine à
// jour », « Libérez de l'espace disque », « Réessayez dans un instant »), et le
// message brut du cœur reste en petit, sélectionnable, pour le rapport de bogue.
// Le bouton « Diagnostic » remplace « Lancer fouine doctor dans le Terminal »,
// qui ne pouvait pas fonctionner (voir BundledDoctor.swift).

import SwiftUI
import AppKit
import FouineCore

/// Diagnostic et message lisible de l'échec d'ouverture (B1-14).
enum OpenErrorDiagnosis: Equatable {
    case corrupted
    case lockHeld(who: String)
    case newerVersion
    /// Un index d'un schéma ANTÉRIEUR à la 1.0.0. Depuis le lot J1 il ne se
    /// rattrape plus : le seul geste est de le refaire.
    case tooOld
    case diskFull
    case missingOrInaccessible
    case generic(String)

    /// L'ORDRE COMPTE, et il va du plus étroit au plus large : « malformed
    /// database schema » est une corruption, pas un désaccord de schéma ;
    /// « full-text » n'est pas un disque plein. Les motifs sont ceux que SQLite
    /// et le cœur écrivent réellement — le désaccord de schéma est la phrase de
    /// `GRDBStore.schemaMismatch` (« …written by a newer version — update… »).
    static func diagnose(error: String, lockStatus: WriteLock.LockStatus) -> OpenErrorDiagnosis {
        let lower = error.lowercased()
        if ["malformed", "not a database", "corrupt"].contains(where: lower.contains) {
            return .corrupted
        }
        if case .held(let holder) = lockStatus {
            return .lockHeld(who: LockActivityText.describe(holder))
        }
        if lower.contains(WriteLock.busyToken) || lower.contains("database is locked") {
            return .lockHeld(who: String(localized: "another program"))
        }
        if lower.contains("newer version") {
            return .newerVersion
        }
        // La phrase du cœur, mot pour mot : « this Fouine index predates 1.0.0
        // (schema vN…) ». On ne cherche pas « schema », qui apparaît dans une
        // corruption comme dans un désaccord de version.
        if lower.contains("predates 1.0.0") {
            return .tooOld
        }
        if ["database or disk is full", "no space left", "enospc"].contains(where: lower.contains) {
            return .diskFull
        }
        if ["no such file", "permission denied", "operation not permitted", "read-only file system"]
            .contains(where: lower.contains) {
            return .missingOrInaccessible
        }
        return .generic(error)
    }

    var readableMessage: String {
        switch self {
        case .corrupted:
            return String(localized: "The index file is damaged. Restore a backup if you have one; otherwise delete the file and Fouine will rebuild the index (this can take a long time).")
        case .lockHeld(let who):
            return String(localized: "Try again in a moment: the index is being updated (\(who)).")
        case .newerVersion:
            return String(localized: "This index was created by a newer version of Fouine. Update Fouine.")
        case .tooOld:
            return String(localized: "This index comes from an older trial version of Fouine and can no longer be used. Fouine has to build it again from your folders.")
        case .diskFull:
            return String(localized: "The disk is full. Free up some disk space, then try again.")
        case .missingOrInaccessible:
            return String(localized: "Fouine cannot read or create its index file. Check that the disk is not read-only and that Fouine is allowed to access its folder.")
        case .generic(let message):
            return message
        }
    }
}

struct OpenFailureView: View {
    @EnvironmentObject private var app: AppModel
    let rawError: String

    @State private var confirmingRestoreURL: URL?
    @State private var confirmingRebuild = false
    @State private var diagnosing = false
    @State private var diagnosticOutput: BundledDoctor.Output?

    private var diagnosis: OpenErrorDiagnosis {
        let lockPath = FouinePaths.lockURL(for: app.service.databaseURL).path
        let lockStatus = WriteLock.inspect(path: lockPath)
        return OpenErrorDiagnosis.diagnose(error: rawError, lockStatus: lockStatus)
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Can't open the index")
                .font(.title2.weight(.semibold))

            Text(diagnosis.readableMessage)
                .font(.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)
                .padding(.horizontal)

            VStack(spacing: 4) {
                // Le chemin et le message brut : ce qu'on recopie dans un rapport
                // de bogue. En petit, sélectionnables, jamais dans la phrase.
                Text("Index file: \(app.service.databaseURL.path)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)

                if diagnosis.readableMessage != rawError {
                    Text(verbatim: rawError)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.quaternary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 12) {
                // Un index trop ancien ne se répare pas en réessayant : le
                // geste principal est de le refaire, et « Réessayer » passe au
                // second plan pour ne pas laisser croire le contraire.
                if diagnosis == .tooOld {
                    Button("Build the Index Again…") {
                        confirmingRebuild = true
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("openFailure.rebuild")
                }

                retryButton

                Button("Show in Finder") {
                    app.revealDatabaseInFinder()
                }
                .accessibilityIdentifier("openFailure.showInFinder")

                // Caché sous `swift run` : il n'y a pas de binaire embarqué.
                if BundledDoctor.isAvailable {
                    Button("Diagnostic") {
                        runDiagnostic()
                    }
                    .disabled(diagnosing)
                    .accessibilityIdentifier("openFailure.diagnostic")
                }

                if let backup = app.availableBackupURL() {
                    Button("Restore Backup “\(backup.lastPathComponent)”") {
                        confirmingRestoreURL = backup
                    }
                    .accessibilityIdentifier("openFailure.restoreNearby")
                } else {
                    Button("Restore Backup…") {
                        chooseAndRestoreBackup()
                    }
                    .accessibilityIdentifier("openFailure.restoreCustom")
                }
            }
            .padding(.top, 8)

            if diagnosing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Diagnostic in progress…"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .sheet(item: $diagnosticOutput) { output in
            DiagnosticSheet(output: output)
        }
        .alert("Restoring this backup will replace the current index. Continue?", isPresented: Binding(
                get: { confirmingRestoreURL != nil },
                set: { if !$0 { confirmingRestoreURL = nil } }
            ),
            presenting: confirmingRestoreURL
        ) { url in
            Button("Restore", role: .destructive) {
                Task { await restore(from: url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The current index is not deleted: it is kept next to the restored one.")
        }
        // La suppression de l'index passe TOUJOURS par une confirmation qui dit
        // ce qui sera perdu, et ce qui ne le sera pas — aucun document n'est
        // touché, c'est le point qui inquiète.
        .alert("Build the index again?", isPresented: $confirmingRebuild) {
            Button("Build Again", role: .destructive) {
                Task { await rebuildIndex() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything Fouine has read from your documents will be deleted, including the text recognised in scanned pages. It will all have to be read again, which can take several hours. Your documents themselves are never touched.")
        }
        .accessibilityIdentifier("app.openFailure")
    }

    /// « Réessayer » perd sa mise en avant quand l'index est trop ancien :
    /// réessayer ne peut alors RIEN réparer, et deux boutons proéminents ne
    /// diraient plus lequel est le geste.
    @ViewBuilder
    private var retryButton: some View {
        let button = Button("Retry") { Task { await app.retryOpen() } }
            .accessibilityIdentifier("openFailure.retry")
        if diagnosis == .tooOld {
            button.buttonStyle(.bordered)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    private func runDiagnostic() {
        diagnosing = true
        Task {
            let output = await app.runDiagnostic()
            diagnosing = false
            diagnosticOutput = output ?? BundledDoctor.Output(
                text: String(localized: "The diagnostic tool is not available in this copy of Fouine."),
                exitCode: -1, timedOut: false)
        }
    }

    /// Efface l'index périmé et rouvre : une base neuve naît au schéma courant,
    /// vide, et l'indexation repart. L'échec s'affiche comme celui d'une
    /// restauration — il n'y a pas de raison d'avoir deux façons de le dire.
    private func rebuildIndex() async {
        do {
            try await app.discardIndexAndStartOver()
        } catch {
            app.restoreNotice = RestoreNotice(
                title: String(localized: "Index not deleted"),
                message: String(localized: "Fouine could not delete the old index: \((error as NSError).localizedDescription)"))
        }
    }

    /// L'erreur de restauration n'est plus avalée par un `try?` (lot I1) : elle
    /// s'affiche, et dit que l'index courant est resté en place.
    private func restore(from url: URL) async {
        do {
            try await app.restoreBackup(from: url)
        } catch {
            app.restoreNotice = RestoreNotice(
                title: String(localized: "Backup not restored"),
                message: String(localized: "The copy failed: \((error as NSError).localizedDescription) The current index was left in place."))
        }
    }

    private func chooseAndRestoreBackup() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Restore")
        if panel.runModal() == .OK, let url = panel.url {
            confirmingRestoreURL = url
        }
    }
}

extension BundledDoctor.Output: Identifiable {
    /// Une sortie = une présentation : la feuille se rouvre à chaque « Diagnostic ».
    var id: String { text + "\(exitCode)" }
}

/// La sortie de `fouine doctor`, défilante et en monospace, avec « Copier ».
private struct DiagnosticSheet: View {
    let output: BundledDoctor.Output
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostic")
                .font(.title3.weight(.semibold))
            Text("This is what Fouine's diagnostic tool reports. Copy it into a bug report if you need help.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: output.text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 260)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            .accessibilityIdentifier("openFailure.diagnostic.output")

            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output.text, forType: .string)
                }
                .accessibilityIdentifier("openFailure.diagnostic.copy")
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
        .accessibilityIdentifier("openFailure.diagnosticSheet")
    }
}
