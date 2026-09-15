// AllDocumentsView.swift — la fenêtre « Tous vos documents » (lot BR1,
// constat PR-06). Propriété : A-App.
//
// CE QU'ELLE REMPLACE : rien. C'était le trou. Fouine ouvrait sur un champ de
// recherche, et le pied de la carte « Index » annonçait « 1 527 documents » sans
// jamais permettre de les VOIR. Le Finder, DEVONthink et EagleFiler ouvrent tous
// sur une liste ; le serveur MCP savait la rendre depuis le palier 4.
//
// LE TON. Cette fenêtre ne parle pas de base, d'état ni d'extension : elle
// montre des documents, avec le dossier où ils sont, leur nombre de pages et
// quand ils ont changé. Aucun chemin en clair (le dossier abrégé suffit à
// reconnaître un document, le chemin entier reste dans l'infobulle).
//
// La vue ne décide de rien : la liste, les filtres et la pagination viennent
// d'`AllDocumentsModel` ; le motif d'un document illisible vient de
// `UnreadableReasonText`, celui de la fenêtre voisine — deux phrases pour le
// même échec, dans la même application, c'est exactement ce que l'audit
// reproche ailleurs.

import SwiftUI
import AppKit
import FouineCore

/// Menu Fenêtre ▸ « Tous vos documents » (⌘⇧L).
///
/// UNE STRUCTURE `Commands` À PART, comme `HelpCommands` : `openWindow` ne se
/// prend que dans l'environnement des commandes, et c'est le seul endroit d'où
/// un élément de menu sait faire naître une scène `Window` que SwiftUI n'a pas
/// encore construite.
///
/// ⌘⇧L : « L » pour la liste ; ⌘L est pris par le champ de recherche des
/// applications macOS et ⇧ le libère sans entrer en conflit avec les raccourcis
/// déjà posés (⇧⌘C citer, ⇧⌘E exporter, ⌥⌘F chercher, ⌘0 ouvrir la fenêtre).
struct AllDocumentsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    static let windowID = "allDocuments"

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("All your documents") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: Self.windowID)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .help("Shows every document Fouine has indexed, most recent first.")
        }
    }
}

struct AllDocumentsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var search: SearchModel
    @EnvironmentObject private var model: AllDocumentsModel

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 620, minHeight: 400)
        // `.task` et non `.onAppear` : la lecture est asynchrone, et SwiftUI
        // l'annule de lui-même si la fenêtre se referme entre-temps.
        .task { await model.start() }
    }

    // MARK: - En-tête : filtrer, choisir, compter

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Filter by name", text: $model.nameFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 160)
                    .accessibilityLabel("Filter by name")
                    .accessibilityHint("Keeps only the documents whose name or folder contains what you type.")
                    .accessibilityIdentifier("allDocuments.filter")
                folderMenu
                typeMenu
                orderMenu
            }
            HStack(spacing: 10) {
                // Le compte de TOUT ce qui répond aux filtres, pas de ce qui est
                // à l'écran : c'est la réponse à « qu'est-ce que Fouine
                // connaît ? ».
                Text("\(model.total) documents")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityIdentifier("allDocuments.count")
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Looking…")
                }
                Spacer()
            }
            if let errorText = model.errorText {
                Label { Text(verbatim: errorText) } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("allDocuments.error")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Les dossiers surveillés, tels que la barre latérale les nomme — jamais
    /// les `top_folder` de la base : ce sont les mêmes étiquettes, et les lire
    /// deux fois à deux endroits finirait par les faire diverger.
    private var folderMenu: some View {
        Picker(selection: $model.folder) {
            Text("All folders").tag(String?.none)
            ForEach(app.roots) { root in
                Text(verbatim: root.label).tag(String?.some(root.label))
            }
        } label: {
            Text("Folder")
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel("Folder")
        .accessibilityIdentifier("allDocuments.folder")
    }

    /// Les types PRÉSENTS dans l'index, le plus fréquent d'abord
    /// (`documentExtensions`). Une extension reste une extension : c'est le mot
    /// que le Finder affiche, et personne ne cherche « un document PDF » sous un
    /// autre nom.
    private var typeMenu: some View {
        Picker(selection: $model.ext) {
            Text("All types").tag(String?.none)
            ForEach(model.extensions, id: \.self) { ext in
                Text(verbatim: "." + ext).tag(String?.some(ext))
            }
        } label: {
            Text("Type")
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel("Type")
        .accessibilityIdentifier("allDocuments.type")
    }

    private var orderMenu: some View {
        Picker(selection: $model.order) {
            ForEach(AllDocumentsOrder.allCases) { order in
                Text(verbatim: order.label).tag(order)
            }
        } label: {
            Text("Sort by")
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel("Sort by")
        .accessibilityIdentifier("allDocuments.order")
    }

    // MARK: - La liste

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            centered {
                ProgressView()
                Text("Looking…").font(.callout).foregroundStyle(.secondary)
            }
        case .empty:
            centered {
                Image(systemName: "tray")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("No document matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("allDocuments.empty")
        case .failure, .list:
            list
        }
    }

    private var list: some View {
        List {
            ForEach(model.rows ?? []) { row($0) }
            if model.canLoadMore {
                Button {
                    Task { await model.loadMore() }
                } label: {
                    // Le nombre restant est dit : « Charger plus » seul ne
                    // laisse pas deviner s'il en reste dix ou dix mille.
                    Text("Load more (\(model.total - (model.rows?.count ?? 0)) left)")
                        .font(.callout)
                }
                .buttonStyle(.link)
                .disabled(model.isLoading)
                .accessibilityIdentifier("allDocuments.loadMore")
            }
        }
        .accessibilityIdentifier("allDocuments.list")
    }

    /// Une ligne est un VRAI bouton, pas une rangée qui écoute les clics.
    ///
    /// Vu à l'écran le 10/09/2026 sur le corpus réel : avec un `onTapGesture` et
    /// un `accessibilityElement(children: .contain)`, la rangée n'a aucun rôle,
    /// et SwiftUI verse alors l'indication dans le RÔLE LU — VoiceOver annonçait
    /// « README.md, in M2SU, ouvre ce document dans une fenêtre d'aperçu »
    /// comme si c'était la nature de l'élément (même famille de défaut que
    /// BU-13 et BU-15). Un bouton se dit bouton, garde son indication à sa
    /// place, et s'active au clavier — ce qu'un geste tactile ne fait jamais.
    private func row(_ document: AllDocumentsRow) -> some View {
        Button {
            openPreview(document)
        } label: {
            rowLabel(document)
        }
        .buttonStyle(.plain)
        // Le chemin complet ne s'affiche jamais en clair : il est ici, à la
        // demande, pour distinguer deux fichiers de même nom.
        .help(Text(verbatim: document.source?.breadcrumb ?? document.relPath))
        .contextMenu { rowMenu(document) }
        .accessibilityLabel(String(localized: "\(document.fileName), in \(document.folder)"))
        .accessibilityValue(Self.spoken(document))
        .accessibilityHint("Opens this document in a preview window.")
        .accessibilityIdentifier("allDocuments.row.\(document.id)")
    }

    /// Ce que VoiceOver annonce en VALEUR : les pages et la date, dans l'ordre
    /// où elles sont écrites. Le compte passe par `AccessibilityText`, qui retire
    /// le séparateur de milliers — « 1 376 » se prononce sinon « un » puis
    /// « trois cent soixante-seize ».
    static func spoken(_ document: AllDocumentsRow) -> String {
        var parts = [AccessibilityText.pages(document.pages),
                     modifiedText(document.modified)]
        if document.isUnreadable {
            parts.append(UnreadableReasonText.describe(raw: document.rawReason))
        }
        return parts.joined(separator: ", ")
    }

    private func rowLabel(_ document: AllDocumentsRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: document.fileName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if !document.folderPath.isEmpty {
                        Text(verbatim: document.folderPath)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    if document.source?.isAnkiDeck == true {
                        Text(verbatim: String(localized: "\(document.pages) card(s)"))
                    } else {
                        Text("\(document.pages) pages")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                // Le marqueur des documents que Fouine n'a pas su lire, avec la
                // phrase de la fenêtre voisine (UX-16) : ils sont dans la liste
                // — les cacher recréerait le trou de l'audit —, mais on dit
                // pourquoi leur texte n'est pas cherchable.
                if document.isUnreadable {
                    Label {
                        Text(verbatim: UnreadableReasonText.describe(
                            raw: document.rawReason))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                } else if document.isPending {
                    Text("Not read yet: it will be at the next update")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(verbatim: Self.modifiedText(document.modified))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Le clic droit d'une ligne : les trois gestes de la liste de résultats
    /// (UX2), aux mêmes libellés — un même geste ne doit pas changer de nom
    /// d'une fenêtre à l'autre.
    @ViewBuilder
    private func rowMenu(_ document: AllDocumentsRow) -> some View {
        if let source = document.source {
            // Une copie de Fouine s'ouvre dans son application (lot AN2).
            Button(SourceOpenTarget.label(forSource: source.sourceID)) {
                guard let target = SourceOpenTarget.resolve(
                    relPath: document.relPath, fileURL: document.fileURL) else { return }
                NSWorkspace.shared.open(target.url)
            }
            .disabled(document.fileURL == nil)
        } else {
            Button("Show in Finder") {
                guard let url = document.fileURL else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .disabled(document.fileURL == nil)
            Button("Open") {
                guard let url = document.fileURL else { return }
                NSWorkspace.shared.open(url)
            }
            .disabled(document.fileURL == nil)
        }
        Button("Search inside this document") {
            // La portée se pose dans la fenêtre principale : on referme
            // celle-ci et on ramène l'autre devant, sinon le geste n'aurait
            // aucun effet visible (elle a pu être fermée, UX-08).
            dismiss()
            MainWindow.show(openWindow)
            search.scopeToDocument(id: document.id, name: document.fileName)
        }
    }

    private func openPreview(_ document: AllDocumentsRow) {
        PreviewWindowsModel.shared.open(docID: document.id, page: 1,
                                        using: openWindow)
    }

    // MARK: - Plomberie

    /// « Modifié hier », « Modifié il y a 3 mois ». Le style NOMMÉ : « hier »
    /// se lit mieux que « il y a 1 jour », et c'est ce que le Finder affiche.
    private static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter
    }()

    static func modifiedText(_ date: Date, now: Date = Date()) -> String {
        String(localized: "Modified \(relativeDate.localizedString(for: date, relativeTo: now))")
    }

    private func centered<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        VStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }
}
