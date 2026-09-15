// PreviewPane.swift — panneau droit : aperçu du document sélectionné.
// Propriété : A-App. SPEC §5.6.
//
// États : PDF (avec surlignage natif ou boîtes OCR), image de page (cbz/cbr et
// OOXML via FouinePageRenderer), « aperçu non disponible pour ce format »,
// racine indisponible (état explicite, jamais un panneau vide), vide, chargement.

import SwiftUI
import AppKit
import FouineCore

/// Ce que le menu Édition sait de l'aperçu de la fenêtre devant (PN1).
///
/// `available` voyage avec le modèle, et non lu par le menu sur le modèle :
/// un `@FocusedValue` ne s'abonne pas aux `@Published` de l'objet qu'il porte,
/// et l'article resterait grisé — ou actif — d'une page à l'autre. La valeur
/// change, elle, à chaque réévaluation du panneau.
struct OccurrenceNavigation: Equatable {
    let preview: PreviewModel
    let available: Bool

    static func == (a: Self, b: Self) -> Bool {
        a.preview === b.preview && a.available == b.available
    }
}

private struct OccurrenceNavigationKey: FocusedValueKey {
    typealias Value = OccurrenceNavigation
}

extension FocusedValues {
    var occurrenceNavigation: OccurrenceNavigation? {
        get { self[OccurrenceNavigationKey.self] }
        set { self[OccurrenceNavigationKey.self] = newValue }
    }
}

struct PreviewPane: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var search: SearchModel
    @EnvironmentObject private var preview: PreviewModel

    /// Le surlignage du PDF a-t-il buté sur son plafond ? Remonté par
    /// `PDFPreviewView`, qui seul le sait (audit A12).
    @State private var highlightCapReached = false
    /// « Document » ou « Texte », pour toute la session (lot PV1). Un objet
    /// PARTAGÉ : le panneau de droite et les fenêtres détachées montrent
    /// autrement le même document sinon.
    @ObservedObject private var viewMode = PreviewModeMemory.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let notice = preview.offlineNotice {
                offlineNoticeLine(notice)
            }
            content
                // Le menu contextuel de l'APERÇU (constat PR-24) : un clic droit
                // sur la page. Il ne porte qu'un geste, et seulement quand la
                // page a été lue sur une image — `PreviewModel.canRereadPage`.
                .contextMenu { pageMenu }
            if let notice = preview.rereadNotice {
                rereadNoticeLine(notice)
            }
        }
        // Le menu Édition ▸ « Occurrence suivante » vise l'aperçu de la
        // fenêtre DEVANT (PN1) : la fenêtre principale et chaque fenêtre
        // détachée ont leur propre `PreviewModel`.
        .focusedSceneValue(\.occurrenceNavigation,
                           OccurrenceNavigation(preview: preview,
                                                available: preview.canStepOccurrences))
    }

    /// Le menu contextuel de la page. Vide — donc absent — sur une page dont le
    /// texte vient du document : un menu à un seul geste impossible vaut moins
    /// que pas de menu.
    @ViewBuilder
    private var pageMenu: some View {
        if preview.canRereadPage {
            Button {
                preview.rereadCurrentPage()
            } label: {
                Label("Read this page again", systemImage: "text.viewfinder")
            }
        }
    }

    /// Ce que la remise en file a répondu. Une LIGNE sous l'aperçu, pas une
    /// alerte : le geste est mineur, son effet est différé, et une fenêtre
    /// modale pour dire « c'est noté » interrompt la lecture.
    ///
    /// Le texte passe à la ligne par un cadre, pas par `fixedSize` : dans une
    /// colonne du `NavigationSplitView`, un texte figé en hauteur faisait
    /// déborder la fenêtre entière (`ResultsView`, 11/09/2026 ; pièges
    /// connus, « la colonne des résultats qui déborde »).
    private func rereadNoticeLine(_ notice: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "text.viewfinder")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(verbatim: notice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Divider(), alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(notice)
        .accessibilityIdentifier("preview.rereadNotice")
    }

    /// « Le disque n'est pas branché — voici le texte gardé » (lot PV1).
    ///
    /// Un bandeau, pas une page d'erreur : le texte de la page est en dessous,
    /// il se lit et se feuillette. Le seul geste qui reste possible sans le
    /// fichier est de l'emporter — d'où « Copier ce texte », et rien d'autre.
    private func offlineNoticeLine(_ notice: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "externaldrive.badge.questionmark")
                .imageScale(.small)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(verbatim: notice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy this text") { preview.copyPageText() }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityIdentifier("preview.offline.copy")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(notice)
        .accessibilityIdentifier("preview.offlineNotice")
    }

    // MARK: - En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: preview.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !preview.subtitle.isEmpty {
                        Text(verbatim: preview.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                // Le chemin ENTIER est ici, et seulement ici : à la demande,
                // dans l'infobulle (AP-15).
                .help(Text(verbatim: preview.fullPath))
                // Les deux lignes sont tronquées « au milieu » à l'écran : le
                // libellé parlé, lui, porte le titre et le chemin entiers.
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(preview.subtitle.isEmpty
                    ? preview.title
                    : String(localized: "\(preview.title), \(preview.subtitle)"))
                .accessibilityIdentifier("preview.title")
                Spacer()
                // `fileURL` et non `docRow` : l'aperçu texte marche sans le
                // fichier (volume débranché), mais les deux actions, elles,
                // ont besoin d'un chemin. Un bouton qui ne peut rien faire
                // vaut moins que pas de bouton.
                // Citer la page (lot INT-L1). AVANT « Afficher dans le
                // Finder », et sans la condition `fileURL != nil` : une page
                // dont le disque est débranché reste parfaitement citable —
                // c'est le lien qui la rouvrira, pas le fichier.
                if preview.docRow != nil {
                    Menu {
                        Button("Copy the reference") { preview.copyReference() }
                        Button("Copy the link") { preview.copyLink() }
                    } label: {
                        // Un `Label` et non une image nue (BU-13) : le titre
                        // d'un `AXPopUpButton` est ce que VoiceOver lit, et
                        // c'était « quote point opening ».
                        Label("Copy a reference to this page",
                              systemImage: "quote.opening")
                            .labelStyle(.iconOnly)
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Copy a reference to this page")
                    .accessibilityLabel("Copy a reference to this page")
                    .accessibilityHint("Copies the file name, the page number and a link that reopens Fouine on this page.")
                    .accessibilityIdentifier("preview.cite")
                }
                // Une note recopiée d'une application, ou une page exportée de
                // Notion : le bouton mène à SA note, pas au fichier de travail
                // que Fouine s'est fabriqué (lot INT-F4). Il PREND LA PLACE de
                // « Afficher dans le Finder » : montrer à quelqu'un le dossier
                // interne de Fouine ne lui apprend rien et l'invite à y toucher.
                if let target = preview.sourceTarget {
                    Button {
                        preview.openInSourceApp()
                    } label: { Image(systemName: target.symbol) }
                    .help(target.label)
                    .accessibilityLabel(target.label)
                    .accessibilityIdentifier("preview.openSource")
                } else if preview.fileURL != nil, preview.sourceDocument == nil {
                    // Une copie de Fouine dont l'application manque (Anki
                    // désinstallé) n'a PAS de repli vers le Finder (lot AN2) :
                    // il ne montrerait que le dossier de travail de Fouine.
                    Button {
                        preview.revealInFinder()
                    } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
                    .accessibilityLabel("Show in Finder")
                    .accessibilityIdentifier("preview.reveal")
                }
                if preview.fileURL != nil, preview.sourceTarget == nil,
                   preview.sourceDocument == nil {
                    Button {
                        preview.openExternally()
                    } label: { Image(systemName: "arrow.up.forward.app") }
                    // L'infobulle nomme la page pour un PDF (lot OP1), et
                    // seulement pour lui : c'est le seul format dont la page
                    // veut dire quelque chose pour un autre logiciel.
                    .help(ExternalOpen.helpText(fileURL: preview.fileURL,
                                                page: preview.page))
                    .accessibilityLabel("Open the document")
                    .accessibilityHint(ExternalOpen.accessibilityHint(
                        fileURL: preview.fileURL, page: preview.page))
                    .accessibilityIdentifier("preview.open")
                }
            }

            if preview.docRow != nil {
                HStack(spacing: 8) {
                    pageNavigator
                    modePicker
                    if let provenance = preview.provenance {
                        Label(provenance.label, systemImage: provenance.symbol)
                            .font(.caption)
                            .foregroundStyle(provenance.isOCR ? Color.teal
                                                              : Color.secondary)
                            .help("Origin of the text layer of this page")
                            .accessibilityLabel(String(localized: "Origin: \(provenance.label)"))
                            .accessibilityHint("Where the text layer of this page comes from.")
                            .accessibilityIdentifier("preview.provenance")
                    }
                    Spacer()
                }
                occurrenceRow
                insideSearchField
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Occurrences (PN1)

    /// L'aperçu montre-t-il le texte indexé, avec ses mots en évidence ?
    private var showsIndexedText: Bool {
        switch preview.content {
        case .text:                    return true
        case .quickLook(_, let text):  return text != nil
                                           && viewMode.mode(for: preview.route) == .text
        default:                       return false
        }
    }

    /// « 3 / 27 », les deux chevrons, et une pastille par mot cherché.
    ///
    /// UNE LIGNE À ELLE : la ligne du dessus porte déjà le numéro de page, le
    /// sélecteur et l'origine du texte, et la colonne descend à 300 pt. Les
    /// pastilles qui ne tiennent pas passent dans l'infobulle — `ViewThatFits`
    /// essaie cinq, trois, puis une.
    @ViewBuilder
    private var occurrenceRow: some View {
        let chips = preview.occurrenceChips(terms: search.terms,
                                            showsText: showsIndexedText)
        let stepping = preview.canStepOccurrences
        if stepping || !chips.isEmpty {
            HStack(spacing: 8) {
                if stepping { occurrenceStepper }
                ViewThatFits(in: .horizontal) {
                    chipList(chips, limit: OccurrenceTally.visibleLimit)
                    chipList(chips, limit: 3)
                    chipList(chips, limit: 1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var occurrenceStepper: some View {
        HStack(spacing: 2) {
            Button {
                preview.previousOccurrence()
            } label: { Image(systemName: "chevron.up") }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help("Previous occurrence (⇧⌘G)")
                .accessibilityLabel("Previous occurrence")
                .accessibilityIdentifier("preview.previousOccurrence")
            if let position = preview.occurrenceCursor.position {
                let total = preview.occurrenceCursor.count
                Text(verbatim: "\(Format.integer(position)) / \(Format.integer(total))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "Occurrence \(position) of \(total) on this page"))
                    .accessibilityIdentifier("preview.occurrencePosition")
            }
            Button {
                preview.nextOccurrence()
            } label: { Image(systemName: "chevron.down") }
                .keyboardShortcut("g", modifiers: .command)
                .help("Next occurrence (⌘G)")
                .accessibilityLabel("Next occurrence")
                .accessibilityIdentifier("preview.nextOccurrence")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize()
    }

    private func chipList(_ chips: [OccurrenceTally.Chip], limit: Int) -> some View {
        let shown = chips.prefix(limit)
        let hidden = chips.dropFirst(limit)
        let also = hidden.map(Self.spokenChip).joined(separator: ", ")
        return HStack(spacing: 10) {
            ForEach(Array(shown)) { chip in
                HStack(spacing: 4) {
                    Circle()
                        .fill(TermPalette.color(chip.colorIndex))
                        .frame(width: 8, height: 8)
                    Text(verbatim: chip.label)
                        .lineLimit(1)
                    Text(verbatim: Self.countText(chip))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.spokenChip(chip))
            }
            if !hidden.isEmpty {
                Text(verbatim: "+\(Format.integer(hidden.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }
        // Les mots qui ne tiennent pas sont À LA DEMANDE, pas perdus.
        .help(hidden.isEmpty
              ? String(localized: "How many times each word you searched for appears on this page")
              : String(localized: "Also on this page: \(also)"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Words found on this page"))
        .accessibilityIdentifier("preview.occurrenceCounts")
    }

    private static func countText(_ chip: OccurrenceTally.Chip) -> String {
        Format.integer(chip.count) + (chip.atLeast ? "+" : "")
    }

    /// « azote, 3 fois ». Le mot est recollé HORS catalogue : `xcstringstool`
    /// refuse `%@` dans une clé à pluriel.
    private static func spokenChip(_ chip: OccurrenceTally.Chip) -> String {
        let times = chip.atLeast
            ? String(localized: "more than \(chip.count) times")
            : String(localized: "\(chip.count) time(s)")
        return chip.label + ", " + times
    }

    /// « Document | Texte » — et seulement là où les deux existent (lot PV1).
    ///
    /// Le PDF, les pages rendues en image et les enregistrements n'y sont pas :
    /// ils ont une seule façon de se montrer, et un sélecteur à un seul choix
    /// utile est un bouton qui ne fait rien. Un document sans texte indexé non
    /// plus — il n'y aurait rien derrière « Texte ».
    @ViewBuilder
    private var modePicker: some View {
        if case .quickLook(_, let text) = preview.content, text != nil {
            Picker("How to show this document", selection: Binding(
                get: { viewMode.mode(for: preview.route) },
                set: { viewMode.choice = $0 })) {
                    ForEach(PreviewMode.allCases) { mode in
                        Text(verbatim: mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                // LE SURLIGNAGE NE SUIT PAS DANS « DOCUMENT » : c'est macOS qui
                // dessine la page, et Fouine n'a pas la main dessus. Le dire
                // ici évite de chercher des couleurs qui ne viendront pas.
                .help("The words you searched for are highlighted in “Text” only.")
                .accessibilityLabel("How to show this document")
                .accessibilityHint("“Document” shows the page as macOS draws it; “Text” shows the text Fouine indexed, with your search words highlighted.")
                .accessibilityIdentifier("preview.mode")
        }
    }

    /// Numéro de page, et — pour l'aperçu texte d'un document multipage — les
    /// deux flèches qui le parcourent.
    ///
    /// Elles ne s'affichent QUE sur l'aperçu texte : le PDF a déjà sa propre
    /// navigation dans `PDFView`, et une image de page vient d'un rendu, donc
    /// d'un accès disque qu'un clic répété paierait cher. Les pages proposées
    /// sont celles qui portent du texte indexé — sauter sur une page vide
    /// n'aurait rien à montrer.
    @ViewBuilder
    private var pageNavigator: some View {
        // La page vient de la BASE quelle que soit la voie (lot PV1) : une
        // transcription et un document montré par le Coup d'œil se feuillettent
        // comme un aperçu texte — c'est le même `SELECT`.
        // Un paquet Anki se feuillette CARTE par carte (lot AN2) : même
        // navigation, mêmes pages en base, d'autres mots.
        let cards = preview.pageUnit == .card
        if let content = preview.pageTextContent, content.pages.count > 1 {
            let index = content.pages.firstIndex(of: preview.page)
            HStack(spacing: 2) {
                Button {
                    if let i = index, i > 0 { preview.goToPage(content.pages[i - 1]) }
                } label: { Image(systemName: "chevron.left") }
                    .disabled((index ?? 0) <= 0)
                    .help(cards ? String(localized: "Previous card")
                                : String(localized: "Previous page carrying text"))
                    // Deux chevrons nus : sans libellé, VoiceOver annonçait
                    // « bouton » deux fois de suite.
                    .accessibilityLabel(cards ? String(localized: "Previous card")
                                              : String(localized: "Previous page"))
                    .accessibilityHint(cards ? "" : String(localized: "Previous page carrying text."))
                    .accessibilityIdentifier("preview.previousPage")
                Text(verbatim: preview.pageUnit.position(preview.page,
                                                         of: content.pages.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(cards
                        ? String(localized: "Card \(preview.page) of \(content.pages.count)")
                        : String(localized: "Page \(preview.page) of \(content.pages.count) pages carrying text"))
                    .accessibilityIdentifier("preview.pageNumber")
                Button {
                    if let i = index, i + 1 < content.pages.count {
                        preview.goToPage(content.pages[i + 1])
                    }
                } label: { Image(systemName: "chevron.right") }
                    .disabled(index == nil || index! + 1 >= content.pages.count)
                    .help(cards ? String(localized: "Next card")
                                : String(localized: "Next page carrying text"))
                    .accessibilityLabel(cards ? String(localized: "Next card")
                                              : String(localized: "Next page"))
                    .accessibilityHint(cards ? "" : String(localized: "Next page carrying text."))
                    .accessibilityIdentifier("preview.nextPage")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        } else {
            Text(verbatim: preview.pageUnit.single(preview.page))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(cards ? String(localized: "Card \(preview.page)")
                                          : String(localized: "Page \(preview.page)"))
                .accessibilityIdentifier("preview.pageNumber")
        }
    }

    /// « Rechercher dans ce document » : la même requête, restreinte au document
    /// courant via `SearchQuery.inDocIDs` (§5.6).
    private var insideSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text.magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search inside this document…", text: $preview.insideText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit { searchInsideDocument() }
                .accessibilityLabel("Search inside this document")
                .accessibilityHint("Restricts the search to the document shown.")
                .accessibilityIdentifier("preview.insideSearch")
            if case .document(_, let name) = search.scope {
                Button {
                    search.clearScope()
                } label: {
                    // LIBELLÉ FIXE (AP-02). Le nom du fichier entier tenait
                    // dans ce bouton : « Guymont — Structure de la matière…
                    // (2003).pdf » s'y repliait sur deux lignes à 1 309 pt et
                    // sur SIX à 900 pt — la largeur minimale documentée —, où
                    // il recouvrait le champ « Rechercher dans ce document ».
                    // Le nom est déjà en titre, deux lignes au-dessus.
                    Label("Leave this document", systemImage: "xmark.circle")
                        .font(.caption)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                // Le nom du document reste atteignable, à la demande.
                .help(Text(verbatim: String(localized: "Leave the \(name) scope")))
                .accessibilityLabel(String(localized: "Leave the \(name) scope"))
                .accessibilityHint("Returns the search to the whole index.")
                .accessibilityIdentifier("preview.clearScope")
            }
        }
    }

    private func searchInsideDocument() {
        let query = preview.insideText.trimmingCharacters(in: .whitespaces)
        // Le document VU, et non la sélection de la liste (UX-17) : dans une
        // fenêtre d'aperçu détachée, les deux peuvent différer — la liste a
        // continué d'avancer pendant que la fenêtre reste sur sa page — et la
        // recherche se serait alors restreinte au mauvais document.
        guard !query.isEmpty, let docID = preview.docRow?.id else { return }
        search.text = query
        let name = preview.title
        if case .document(let current, _) = search.scope, current == docID {
            search.submit()             // portée déjà en place : relancer
        } else {
            search.scope = .document(id: docID, name: name)  // didSet relance
        }
    }

    // MARK: - Contenu

    @ViewBuilder
    private var content: some View {
        switch preview.content {
        case .empty:
            placeholder(symbol: "doc.text.magnifyingglass",
                        title: String(localized: "No selection"),
                        detail: String(localized: "Choose a result to display the page."))
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("loading…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading the preview")
        case .pdf(let box):
            VStack(spacing: 0) {
                if highlightCapReached {
                    // Le plafond de surlignages était silencieux : une page très
                    // dense semblait ne plus rien contenir passé la 400ᵉ
                    // occurrence (audit A12).
                    Label("first \(PDFPreviewView.Coordinator.highlightsPerTerm) occurrences highlighted per term on this page",
                          systemImage: "highlighter")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .overlay(Divider(), alignment: .bottom)
                        // Le plafond était muet à l'écran (audit A12) ; il ne
                        // doit pas l'être non plus à l'oreille.
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityLabel(String(localized: "first \(PDFPreviewView.Coordinator.highlightsPerTerm) occurrences highlighted per term on this page; the rest are present but not highlighted."))
                        .accessibilityIdentifier("preview.highlightCap")
                }
                PDFPreviewView(box: box,
                               page: preview.page,
                               terms: search.terms,
                               ocrLines: (preview.provenance?.isOCR ?? false)
                                         ? preview.ocrLines : nil,
                               highlightCapReached: $highlightCapReached,
                               preview: preview)
                    .accessibilityIdentifier("preview.pdf")
            }
        case .text(let page):
            TextPreviewView(page: page, terms: search.terms,
                            identity: preview.loadedKey,
                            onCounts: { preview.noteTextOccurrences($0) })
        case .quickLook(let url, let page):
            // Le texte n'existe pas toujours (un document que Fouine n'a pas su
            // lire) : le Coup d'œil, lui, sait le montrer quand même.
            if let page, viewMode.mode(for: preview.route) == .text {
                TextPreviewView(page: page, terms: search.terms,
                                identity: preview.loadedKey,
                                onCounts: { preview.noteTextOccurrences($0) })
            } else {
                QuickLookPreviewView(url: url)
                    .accessibilityLabel(String(localized: "Preview of \(preview.title)"))
                    .accessibilityIdentifier("preview.quickLook")
            }
        case .media(let url, let page):
            MediaPreviewView(url: url, page: page, terms: search.terms,
                             start: mediaStart(page: page),
                             onPlayhead: { preview.notePlayhead($0) })
        case .image(let box):
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: box.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(String(localized: "Image of page \(preview.page) of \(preview.title)"))
                    .accessibilityIdentifier("preview.image")
            }
            .background(Color(nsColor: .windowBackgroundColor))
        case .unavailable(let title, let detail, let actions):
            unavailableView(title: title, detail: detail, actions: actions)
        case .unsupported(let ext):
            placeholder(symbol: "eye.slash",
                        title: String(localized: "Preview not available for this format"),
                        detail: String(localized: ".\(ext) files have no per-page preview. The indexed text stays searchable; open the document in its own application."))
        }
    }

    /// Où poser la tête de lecture d'un enregistrement (lot PV1).
    ///
    /// Le moment DEMANDÉ gagne — une pastille cliquée dans la liste, un lien
    /// `fouine://…&t=` —, sinon c'est le repère qui ouvre le paragraphe de la
    /// première occurrence trouvée. Une page sans repère est la page de balises
    /// de l'enregistrement : elle commence à zéro.
    private func mediaStart(page: PageTextContent?) -> Int {
        let found = page.map {
            TranscriptMarkers.playhead(text: $0.text, terms: search.terms,
                                       pageStart: 0)
        } ?? 0
        guard let requested = preview.requestedTime else { return found }
        // Une demande venue de la liste est une ESTIMATION quand l'extrait ne
        // portait pas de repère : on ne la suit que si elle tombe dans la page.
        guard let text = page?.text,
              TranscriptMarkers.covers(text: text, seconds: requested)
        else { return found }
        return requested
    }

    /// Les boutons viennent de la CAUSE, pas de la vue (A2-11) : un fichier
    /// déplacé ne propose plus « Ouvrir les Réglages Système ».
    private func unavailableView(title: String, detail: String,
                                 actions: [PreviewAction]) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.doc")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(verbatim: title).font(.title3.weight(.semibold))
            Text(verbatim: detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if !actions.isEmpty {
                HStack {
                    ForEach(actions, id: \.self) { action in
                        Button(action.localizedLabel) { perform(action) }
                            .accessibilityIdentifier("preview.unavailable.\(action.identifier)")
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "\(title). \(detail)"))
        .accessibilityIdentifier("preview.unavailable")
    }

    private func perform(_ action: PreviewAction) {
        switch action {
        case .openPrivacySettings:
            app.openPrivacySettings()
        case .retestRoots:
            Task { await app.refreshRoots(probe: true) }
        case .indexNow:
            app.startIndexing()
        case .revealExpectedLocation(let path):
            // Le fichier n'est plus là : on ouvre le DOSSIER qui devrait le
            // contenir, `activateFileViewerSelecting` ne sélectionnerait rien.
            let parent = (path as NSString).deletingLastPathComponent
            NSWorkspace.shared.selectFile(
                nil, inFileViewerRootedAtPath: parent)
        }
    }

    private func placeholder(symbol: String, title: String,
                             detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(verbatim: title).font(.title3.weight(.semibold))
            Text(verbatim: detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(String(localized: "\(title). \(detail)"))
        .accessibilityIdentifier("preview.placeholder")
    }
}
