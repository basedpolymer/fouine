// IgnoreRulesSheet.swift — « Ce que Fouine ignore… », sous chaque dossier de
// Réglages ▸ Dossiers (lot IG2). Propriété : A-App.
//
// La logique (règle ↔ phrase, refus, compte, menu des types) vit dans
// `IgnoreRulesDraft`, qui se teste ; cette vue ne fait qu'afficher et relayer
// les gestes.

import AppKit
import SwiftUI
import FouineCore
import FouineCrawl

struct IgnoreRulesSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let root: RootStatus

    @State private var draft: IgnoreRulesDraft?
    @State private var loadError: String?
    @State private var note: String?
    @State private var namingFile = false
    @State private var typedName = ""
    @State private var saving = false
    @State private var saveError: String?
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What Fouine skips in “\(root.label)”")
                .font(.title3.weight(.semibold))
            Text("Fouine leaves these out of the index. Your files stay where they are, untouched.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let draft {
                rules(draft)
                gestures(draft)
                consequence(draft)
            } else if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }

            footer
        }
        .padding(20)
        .frame(width: 500)
        .task { await load() }
    }

    // MARK: - La liste

    private func rules(_ draft: IgnoreRulesDraft) -> some View {
        let rows = draft.rows
        return Group {
            if rows.isEmpty {
                Text("Fouine skips nothing in this folder.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else if rows.count <= Self.rowsWithoutScrolling {
                ruleList(rows)
            } else {
                // Une hauteur FIXE, et pas un plafond : dans une feuille qui
                // prend la taille de son contenu, un `ScrollView` n'a pas de
                // hauteur idéale et se réduit à une ligne et demie (vu sur la
                // capture du 14/09/2026).
                ScrollView { ruleList(rows) }
                    .frame(height: 220)
            }
        }
    }

    /// Au-delà, la liste défile ; en deçà, elle se montre entière.
    private static let rowsWithoutScrolling = 6

    private func ruleList(_ rows: [IgnoreRulesDraft.Row]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                ruleRow(row)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
    }

    private func ruleRow(_ row: IgnoreRulesDraft.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.phrase)
                if row.fromFile {
                    Text("from the .fouineignore file in this folder")
                        .font(.caption)
                }
            }
            .foregroundStyle(row.fromFile ? .secondary : .primary)
            Spacer()
            if !row.fromFile {
                Button {
                    mutate { $0.remove(row.rule) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Stop skipping this")
                .accessibilityLabel(Text("Stop skipping: \(row.phrase)"))
            }
        }
    }

    // MARK: - Les trois gestes

    private func gestures(_ draft: IgnoreRulesDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Skip a folder…") { chooseFolder() }
                    .disabled(draft.rootPath == nil)
                Menu("Skip a kind of file") {
                    let kinds = draft.kindsOfFile
                    if kinds.isEmpty {
                        Text("No document in this folder yet")
                    }
                    ForEach(kinds, id: \.ext) { kind in
                        Button {
                            add { $0.addKindOfFile(kind.ext) }
                        } label: {
                            // Un type et un compte : rien à traduire.
                            Text(verbatim: ".\(kind.ext) — \(Format.integer(kind.count))")
                        }
                    }
                }
                .fixedSize()
                Button("Skip files named…") {
                    namingFile = true
                    note = nil
                }
                .disabled(namingFile)
            }
            if namingFile {
                HStack(spacing: 8) {
                    TextField("File name, for example INDEX.md", text: $typedName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTypedName)
                    Button("Add", action: addTypedName)
                        .disabled(typedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") {
                        namingFile = false
                        typedName = ""
                    }
                }
            }
            if let note {
                Text(verbatim: note)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - La conséquence et le pied

    @ViewBuilder
    private func consequence(_ draft: IgnoreRulesDraft) -> some View {
        let sentences = draft.consequenceSentences
        if draft.hasChanges, !sentences.isEmpty {
            Text(verbatim: sentences.joined(separator: " "))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if saved, !(draft?.hasChanges ?? false) {
                Label(IgnoreRulesDraft.savedText(automaticUpdates: !offersUpdateNow),
                      systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if saved, !(draft?.hasChanges ?? false) {
                    if offersUpdateNow {
                        Button("Update now") {
                            app.startIndexing()
                            dismiss()
                        }
                        .disabled(app.indexing.running)
                    }
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                    Button("Save") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!(draft?.hasChanges ?? false) || saving)
                }
            }
        }
    }

    private var offersUpdateNow: Bool {
        IgnoreRulesDraft.offersUpdateNow(agentState: app.agentOperationalState)
    }

    // MARK: - Gestes

    private func mutate(_ change: (inout IgnoreRulesDraft) -> Void) {
        guard var current = draft else { return }
        change(&current)
        draft = current
        note = nil
        saveError = nil
    }

    private func add(_ gesture: (inout IgnoreRulesDraft) -> IgnoreRulesDraft.Outcome) {
        guard var current = draft else { return }
        let outcome = gesture(&current)
        draft = current
        note = current.text(for: outcome)
        saveError = nil
    }

    private func addTypedName() {
        let typed = typedName
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var outcome: IgnoreRulesDraft.Outcome = .added
        add { draft in
            outcome = draft.addFileName(typed)
            return outcome
        }
        if outcome == .added {
            typedName = ""
            namingFile = false
        }
    }

    /// Le panneau s'ouvre SUR la racine, dossiers seulement. Il ne peut pas
    /// empêcher de remonter plus haut : le refus vient après, en une phrase
    /// (`IgnoreRulesDraft.folderRule`).
    private func chooseFolder() {
        guard let rootPath = draft?.rootPath else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        panel.prompt = String(localized: "Skip")
        panel.message = String(localized: "Choose a folder inside “\(root.label)” for Fouine to skip. Nothing in it is modified.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add { $0.addFolder(at: url.path) }
    }

    private func load() async {
        do {
            let snapshot = try await app.ignoreRulesSnapshot(for: root)
            draft = IgnoreRulesDraft(rootLabel: root.label, rootPath: root.absolutePath,
                                     rootRelPath: root.record.relPath,
                                     snapshot: snapshot)
        } catch {
            loadError = String(localized: "Fouine could not read what it skips in this folder: \(ErrorText.describe(error))")
        }
    }

    private func save() async {
        guard let current = draft, current.hasChanges else { return }
        saving = true
        defer { saving = false }
        do {
            try await app.saveIgnoreRules(current.draft, for: root)
            draft?.markSaved()
            saved = true
            note = nil
            saveError = nil
            namingFile = false
        } catch {
            saveError = String(localized: "Saving failed: \(ErrorText.describe(error))")
        }
    }
}
