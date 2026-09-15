// UnreadableDocumentsView.swift — la fenêtre « Documents que Fouine n'a pas pu
// lire » (F10, UX-16). Propriété : A-App.
//
// CE QU'ELLE REMPLACE : rien. C'était le trou. Le pied de la barre latérale
// annonçait « 1 499 documents · 396 364 pages » et se taisait sur les 22 qui
// n'avaient pas pu être lus ; on ne pouvait les découvrir qu'en ouvrant le
// journal d'indexation, 200 ko d'anglais technique.
//
// LE TON. Cette fenêtre s'ouvre sur une mauvaise nouvelle : elle doit d'abord
// rassurer (« vos fichiers ne sont pas touchés »), puis nommer chaque cas en
// langage courant, puis proposer le seul geste utile — réessayer. Elle
// n'affiche AUCUN chemin en clair : le nom du fichier et son dossier suffisent
// à le reconnaître, le chemin complet reste dans l'infobulle et dans le Finder.
//
// La vue ne décide de rien : la liste vient de `UnreadableDocumentsModel`, la
// phrase de `UnreadableReasonText`, tous deux testés.

import SwiftUI
import AppKit

struct UnreadableDocumentsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var model: UnreadableDocumentsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 560, minHeight: 360)
        // `.task` et non `.onAppear` : la lecture est asynchrone, et SwiftUI
        // l'annule tout seul si la fenêtre se ferme entre-temps.
        .task { await model.load() }
    }

    // MARK: - En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("These files are in your folders, but Fouine could not read them. Your files are untouched.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("unreadable.intro")

            HStack(spacing: 12) {
                if let documents = model.documents {
                    Text("\(documents.count) document(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("unreadable.count")
                }
                Spacer()
                // Le seul geste qui puisse changer quelque chose : un outil
                // installé depuis, un fichier téléchargé depuis iCloud, un
                // document réenregistré — tout cela se rattrape par une
                // nouvelle passe.
                Button("Check again") {
                    // La passe s'annonce dans une feuille de la fenêtre
                    // principale, qui peut être fermée (UX-08) : on la ramène
                    // d'abord, sinon le clic n'aurait aucun effet visible.
                    MainWindow.show()
                    app.startIndexing()
                }
                // Une passe déjà en cours, ou aucun dossier : le bouton ne
                // pourrait rien lancer.
                .disabled(app.indexing.running || app.roots.isEmpty)
                .help("Runs through your folders again and tries to read these documents once more.")
                .accessibilityIdentifier("unreadable.retry")
            }

            if model.isTruncated {
                Text("Only the first \(UnreadableDocumentsModel.displayLimit) are listed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("unreadable.truncated")
            }
            if let errorText = model.errorText {
                Label { Text(verbatim: errorText) } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("unreadable.error")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - La liste

    @ViewBuilder
    private var content: some View {
        switch model.documents {
        case nil:
            centered {
                ProgressView()
                Text("Looking…").font(.callout).foregroundStyle(.secondary)
            }
        case .some(let documents) where documents.isEmpty:
            centered {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("Fouine read every document in your folders.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("unreadable.empty")
        case .some(let documents):
            list(documents)
        }
    }

    /// Groupé par DOSSIER, dans l'ordre que le store a déjà donné : c'est le
    /// premier repère de quelqu'un qui cherche un document manquant, et un
    /// dossier entier illisible (disque débranché, autorisation refusée) se
    /// voit alors d'un coup d'œil au lieu de se deviner ligne par ligne.
    private func list(_ documents: [UnreadableDocument]) -> some View {
        List {
            ForEach(folders(of: documents), id: \.name) { folder in
                Section {
                    ForEach(folder.documents) { row($0) }
                } header: {
                    Text(verbatim: folder.name)
                }
            }
        }
        .accessibilityIdentifier("unreadable.list")
    }

    private func row(_ document: UnreadableDocument) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: document.fileName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: UnreadableReasonText.describe(raw: document.rawReason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(document.modified, format: .dateTime.day().month().year())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            // Le bouton n'existe QUE si le chemin se résout : un fichier sur un
            // disque débranché n'a rien à montrer au Finder, et un bouton qui
            // ne fait rien vaut moins que pas de bouton (même règle que
            // `PreviewPane`).
            if document.fileURL != nil {
                // Le geste que la RAISON conseille (AP-17). Vingt-deux des
                // vingt-trois documents illisibles du propriétaire sont des
                // fichiers Pages enregistrés sans aperçu, et leur motif dit
                // « ouvrez-le une fois dans son application » — sans offrir de
                // l'ouvrir. Il fallait aller le chercher au Finder.
                Button { openInDefaultApp(document) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("Open the document")
                .accessibilityLabel("Open the document")
                .accessibilityIdentifier("unreadable.open.\(document.id)")
                Button { reveal(document) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
                .accessibilityIdentifier("unreadable.reveal.\(document.id)")
            }
        }
        .padding(.vertical, 3)
        // Le chemin complet ne s'affiche JAMAIS en clair (public visé) : il est
        // ici, à la demande, pour distinguer deux fichiers de même nom.
        .help(Text(verbatim: document.relPath))
        .contextMenu {
            if document.fileURL != nil {
                Button("Open the document") { openInDefaultApp(document) }
                Button("Show in Finder") { reveal(document) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "\(document.fileName), in \(document.folder)"))
        .accessibilityValue(UnreadableReasonText.describe(raw: document.rawReason))
        .accessibilityIdentifier("unreadable.row.\(document.id)")
    }

    private func reveal(_ document: UnreadableDocument) {
        guard let url = document.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Ouvre le document dans son application, comme le fait le panneau
    /// d'aperçu : le fichier est SOUS UN DOSSIER SUIVI — c'est de là que vient
    /// la liste —, jamais un chemin venu d'ailleurs (BU-01).
    private func openInDefaultApp(_ document: UnreadableDocument) {
        guard let url = document.fileURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Plomberie

    private struct Folder {
        let name: String
        let documents: [UnreadableDocument]
    }

    /// Regroupe SANS retrier : `unreadableDocuments` a déjà rendu ses lignes
    /// dans l'ordre (dossier, chemin). Un `Dictionary(grouping:)` perdrait cet
    /// ordre, et les sections changeraient de place d'une lecture à l'autre.
    private func folders(of documents: [UnreadableDocument]) -> [Folder] {
        var out: [Folder] = []
        for document in documents {
            if let last = out.last, last.name == document.folder {
                out[out.count - 1] = Folder(name: last.name,
                                            documents: last.documents + [document])
            } else {
                out.append(Folder(name: document.folder, documents: [document]))
            }
        }
        return out
    }

    private func centered<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        VStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }
}
