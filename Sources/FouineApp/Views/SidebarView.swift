// SidebarView.swift — panneau gauche : l'index, les dossiers, les facettes,
// les options de recherche. Propriété : A-App. SPEC §5.6.
//
// Les facettes folder/ext/year/source viennent du moteur avec leurs comptes et
// sont cliquables comme filtres. folder et ext repartent dans `SearchQuery` ;
// year et source (non exprimables dans l'interface gelée du §4.2) filtrent
// l'affichage du jeu chargé — l'infobulle de la section le dit.
//
// TOUT CE QUI PARLAIT D'INDEXATION EST DANS `IndexStatusCard` (UX-03). Ce
// fichier portait cinq blocs sur le sujet — bandeau de santé, section
// « Indexation », passe manuelle, bloc de l'agent, pied de barre — qui
// pouvaient se contredire et qui parlaient d'agent, de verrou et de
// ré-enregistrement. Ne les faites pas revenir ici : la carte est le seul
// endroit de la barre latérale où l'état de l'index se dit, et son détail est
// dans la fenêtre « Votre index » (`IndexDetailsView`, IX2).

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FouineCore
import FouineIndex

struct SidebarView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var search: SearchModel
    /// Pour lire `agent.prepareMeaning` : le bouton « Préparer… » s'efface
    /// quand l'agent s'en charge (AG1), et la décision doit être la même
    /// qu'à l'onglet Indexation.
    @EnvironmentObject private var settings: SettingsModel

    /// UNE seule boîte de dialogue de gestion des racines peut être demandée à
    /// la fois : deux `@State` booléens indépendants, c'est le travers du §A10.6
    /// transposé aux alertes. Renommer et retirer sont ici exclusifs par
    /// construction.
    private enum RootDialog: Equatable {
        case rename(RootStatus)
        case remove(RootStatus)

        var root: RootStatus {
            switch self {
            case .rename(let r), .remove(let r): return r
            }
        }
        var isRename: Bool { if case .rename = self { return true }; return false }
        var isRemove: Bool { if case .remove = self { return true }; return false }
    }
    @State private var dialog: RootDialog?
    @State private var draftLabel = ""
    /// La recherche enregistrée qu'on est en train de renommer (PR-17), et le
    /// nom en cours de saisie. Un `@State` à part de `dialog` : ce sont deux
    /// matières différentes, et les mélanger dans une même énumération rendrait
    /// les deux alertes illisibles.
    @State private var renamingSaved: SavedSearch?
    @State private var draftSavedName = ""

    var body: some View {
        List {
            Section("Index") { IndexStatusCard() }
            sourcesSection
            // AU-DESSUS des filtres rapides, et présente même sans recherche en
            // cours : c'est par elle qu'on en commence une (PR-17). Cachée tant
            // qu'il n'y en a aucune — une section vide n'apprend rien.
            savedSearchesSection
            if !search.executedText.isEmpty {
                quickFilterSection
                facetSections
            }
            searchOptionsSection
            shortcutSection
        }
        .listStyle(.sidebar)
        // Le dépôt vaut sur TOUTE la barre, pas seulement sur la zone en
        // pointillés : viser une cible de 40 points en tirant un dossier depuis
        // le Finder est un exercice, pas une fonction.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            app.handleDrop(providers: providers)
        }
        .alert("Rename this folder", isPresented: Binding(
            get: { dialog?.isRename == true },
            set: { if !$0 { dialog = nil } }
        ), presenting: dialog?.root) { root in
            TextField("Name", text: $draftLabel)
            Button("Rename") {
                let wanted = draftLabel
                Task { await app.renameRoot(root, to: wanted) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This name is how the folder appears in the “Folders” list and in “folder:…” searches. Documents already indexed follow the new name.")
        }
        .alert("Rename this saved search", isPresented: Binding(
            get: { renamingSaved != nil },
            set: { if !$0 { renamingSaved = nil } }
        ), presenting: renamingSaved) { saved in
            TextField("Name", text: $draftSavedName)
            Button("Rename") {
                search.renameSavedSearch(query: saved.query, to: draftSavedName)
            }
            Button("Cancel", role: .cancel) {}
        } message: { saved in
            // La REQUÊTE en clair : c'est elle qui sera rejouée, et le nom
            // qu'on est en train de changer peut ne plus rien en dire.
            Text("This search runs: \(saved.query)")
        }
        .alert("Remove this folder?", isPresented: Binding(
            get: { dialog?.isRemove == true },
            set: { if !$0 { dialog = nil } }
        ), presenting: dialog?.root) { root in
            Button("Remove", role: .destructive) {
                Task { await app.removeRoot(root) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { root in
            // Ce que `GRDBStore.removeRoot` fait RÉELLEMENT : purge de tous les
            // documents sous la racine (docs, page_fts, page_src, file OCR) puis
            // suppression de la ligne. Les fichiers, eux, ne sont pas touchés.
            Text("“\(root.label)” will be removed, along with everything Fouine has indexed from it (documents, pages, text read from scanned pages). Your files are not modified. To keep what is already indexed, use “Pause” instead.")
        }
        // La mise à jour automatique remplit la file en arrière-plan : sans ce
        // rafraîchissement, la carte « Index » affiche des comptes figés au
        // démarrage, vieux de plusieurs jours (audit A10.5). Le retour à la
        // fenêtre est le moment naturel — l'utilisateur regarde justement ces
        // chiffres à ce moment-là, et `stats()` est déjà interrogée chaque
        // seconde pendant une passe.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !app.indexing.running else { return }
            Task { await app.refreshStats() }
            // Même raison pour le sémantique : la campagne `fouine embed`
            // remplit `page_vec` en arrière-plan, et l'interrupteur doit
            // s'activer tout seul dès qu'il y a de quoi chercher (§12).
            Task { await search.refreshSemanticAvailability() }
            Task { await app.refreshHealth() }
        }
    }

    // MARK: - Recherches enregistrées (PR-17)

    /// Les recherches épinglées, un clic pour les rejouer.
    ///
    /// Une LIGNE-BOUTON, comme celles de « Tous vos documents » (lot BR1) : un
    /// texte cliquable sans être un bouton n'est annoncé ni comme cliquable ni
    /// comme atteignable au clavier.
    @ViewBuilder
    private var savedSearchesSection: some View {
        if !search.savedSearches.isEmpty {
            Section("Saved searches") {
                ForEach(search.savedSearches) { saved in
                    Button {
                        search.runSavedSearch(saved)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bookmark")
                                .foregroundStyle(.secondary)
                            // `verbatim` : un nom donné par l'utilisateur est
                            // une donnée, pas une clé de catalogue.
                            Text(verbatim: saved.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(saved.query)
                    .contextMenu {
                        Button("Rename…") {
                            draftSavedName = saved.name
                            renamingSaved = saved
                        }
                        Button("Remove", role: .destructive) {
                            search.removeSavedSearch(query: saved.query)
                        }
                    }
                    .accessibilityLabel(AccessibilityText.savedSearchLabel(saved.name))
                    .accessibilityHint("Runs this search again.")
                    .accessibilityIdentifier("saved.entry.\(saved.query)")
                }
                // L'ordre se choisit à la souris (lot MN2) : `SavedSearches`
                // n'ajoute qu'à la fin, et une recherche rejouée chaque jour
                // restait sous celles qu'on n'ouvre plus.
                .onMove { from, to in
                    search.moveSavedSearches(fromOffsets: from, toOffset: to)
                }
            }
            // L'aide dit CE QUI EST RETENU, et surtout ce qui ne l'est pas :
            // les facettes cochées ne font pas partie de la recherche
            // enregistrée, et quelqu'un qui croirait le contraire chercherait
            // longtemps pourquoi elle ne rend pas la même chose.
            .help(Self.savedSearchesHelp)
        }
    }

    private static var savedSearchesHelp: String {
        String(localized: "Only the text you typed is kept, not the filters you clicked in this sidebar.")
    }

    // MARK: - Sources (racines)

    private var sourcesSection: some View {
        // « Sources » et « racines » sont le vocabulaire du moteur ; celui de
        // l'utilisateur est « dossiers » (PLAN § 2). La facette « Folders »
        // n'apparaît qu'après une recherche : les deux titres ne se croisent
        // pas dans la même barre.
        Section("Your folders") {
            // « Aucune racine » et « la base n'a pas répondu » sont deux choses
            // différentes : l'échec de lecture est nommé, avec de quoi le
            // diagnostiquer (audit A10.7).
            if let error = app.rootsError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else if app.roots.isEmpty {
                WelcomeView(style: .sidebar)
            }
            ForEach(app.roots) { root in
                rootRow(root)
            }
            Button {
                app.chooseRootsToAdd()
            } label: {
                Label("Add a folder…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityHint("Opens the folder chooser. macOS will ask for permission to access the chosen folder.")
            .accessibilityIdentifier("sidebar.addRoot")
        }
    }

    private func rootRow(_ root: RootStatus) -> some View {
        Button {
            toggle(&search.selectedFolders, root.label)
        } label: {
            HStack(spacing: 8) {
                // Le dossier des cartes d'Anki, des notes de Notes ou de Bear
                // porte l'icône de SON application (lot AN2) : c'est à elle
                // qu'on pense, pas au dossier que Fouine s'est fabriqué. Un
                // état à signaler (pause, disque, refus) garde son pictogramme.
                if let source = appSource(of: root), rootSymbol(root) == "folder.fill" {
                    SourceAppIcon(sourceID: source.id)
                } else {
                    Image(systemName: rootSymbol(root))
                        .foregroundStyle(rootColor(root))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(root.label)
                        .fontWeight(search.selectedFolders.contains(root.label)
                                    ? .semibold : .regular)
                    // La sous-ligne ne s'affiche QUE si elle a quelque chose à
                    // dire. Elle portait le chemin absolu de chaque dossier :
                    // trois lignes de « /Users/… » tronquées au milieu, que
                    // personne ne lit et qui étalent l'arborescence de la
                    // machine sous les yeux du premier venu. Le chemin reste
                    // dans l'infobulle, à la demande.
                    if let detail = rootDetail(root) {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                if search.selectedFolders.contains(root.label) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
        .help(root.reason ?? (appSource(of: root) != nil ? nil : root.absolutePath)
              ?? root.label)
        // Le pictogramme (dossier / pause / cadenas / disque barré) et le
        // sous-titre portaient SEULS l'état de la racine (audit U3) : le
        // libellé parlé le dit, le hint reprend l'infobulle.
        .accessibilityLabel(AccessibilityText.rootLabel(root))
        .accessibilityHint(AccessibilityText.rootHint(
            root, filtering: search.selectedFolders.contains(root.label)))
        .accessibilityAddTraits(search.selectedFolders.contains(root.label)
                                ? [.isSelected] : [])
        .accessibilityIdentifier("sidebar.root.\(root.id)")
        .contextMenu { rootMenu(root) }
    }

    /// Menu contextuel d'une racine (D1). « Retirer » et « Renommer » passent par
    /// une confirmation : le premier détruit un index qui a pu coûter des heures
    /// d'OCR, le second change une facette utilisée dans les requêtes.
    @ViewBuilder
    private func rootMenu(_ root: RootStatus) -> some View {
        if appSource(of: root) != nil {
            sourceRootMenu(root)
        } else {
            folderRootMenu(root)
        }
    }

    /// Le dossier d'une application (lot AN2) : ni Finder — il ne montrerait
    /// que les fichiers de travail de Fouine —, ni renommage — la passe suivante
    /// ne retrouverait plus sa racine —, ni retrait — elle la recréerait. Ces
    /// dossiers s'allument et s'éteignent dans les Réglages, rubrique
    /// Applications, et c'est là que le menu envoie.
    @ViewBuilder
    private func sourceRootMenu(_ root: RootStatus) -> some View {
        Button(root.record.enabled ? "Pause" : "Resume") {
            Task { await app.setRootEnabled(root, !root.record.enabled) }
        }
        Divider()
        Button("Manage in Settings…") {
            openSettings(on: .folders)
        }
    }

    /// La source dont cette racine est le dossier de copies, ou `nil`.
    private func appSource(of root: RootStatus) -> (any AppSource)? {
        SourceDocumentLocator.standard.source(rootRelPath: root.record.relPath)
    }

    @ViewBuilder
    private func folderRootMenu(_ root: RootStatus) -> some View {
        Button("Show in Finder") {
            guard let path = root.absolutePath else { return }
            NSWorkspace.shared.activateFileViewerSelecting(
                [URL(fileURLWithPath: path)])
        }
        .disabled(root.absolutePath == nil)

        Button("Rename…") {
            draftLabel = root.label
            dialog = .rename(root)
        }

        Divider()

        // « Pause » / « Reprendre » et non « Désactiver » / « Activer » : le
        // geste est réversible et ne détruit rien, et c'est exactement ce que
        // ces deux mots-là promettent.
        Button(root.record.enabled ? "Pause" : "Resume") {
            Task { await app.setRootEnabled(root, !root.record.enabled) }
        }

        Button("Remove…", role: .destructive) {
            dialog = .remove(root)
        }
    }

    private func rootSymbol(_ root: RootStatus) -> String {
        if !root.mounted { return "externaldrive.badge.xmark" }
        if !root.record.enabled { return "pause.circle" }
        if !root.readable { return "lock.fill" }
        return "folder.fill"
    }

    private func rootColor(_ root: RootStatus) -> Color {
        if !root.mounted || !root.readable { return .orange }
        if !root.record.enabled { return .secondary }
        return .accentColor
    }

    /// Ce qu'il y a à dire sous le nom du dossier — et `nil` quand tout va
    /// bien, ce qui est le cas courant.
    private func rootDetail(_ root: RootStatus) -> String? {
        if !root.mounted {
            return root.reason ?? String(localized: "disk not plugged in")
        }
        if !root.record.enabled { return String(localized: "paused") }
        if !root.readable {
            // Sous-titre d'une ligne de barre latérale : court, et sans le
            // sigle « TCC », qui n'existe pour personne hors d'Apple. Le motif
            // détaillé vit dans la carte « Index » et dans l'infobulle (B1-25).
            return root.reason ?? String(localized: "read denied")
        }
        return nil
    }

    // MARK: - Facettes

    /// « Extensions » et « Origine (affichage) » étaient des mots de
    /// développeur : le premier nomme la mécanique (le suffixe du nom de
    /// fichier) au lieu de la chose (le type de document), le second annonçait
    /// entre parenthèses une limite technique — ces deux facettes-là ne
    /// filtrent que les résultats DÉJÀ chargés — au milieu du titre. La limite
    /// est vraie et elle se dit toujours, mais dans l'infobulle.
    @ViewBuilder
    private var facetSections: some View {
        facetSection(key: .folder, title: "Folders",
                     selection: $search.selectedFolders)
        facetSection(key: .ext, title: "File types",
                     selection: $search.selectedExts)
        // « Langue » ne paraît que si le jeu trouvé en porte AU MOINS DEUX : un
        // corpus monolingue n'a pas de choix à offrir, et une section à une
        // seule ligne cochable est une décoration qui pousse les autres vers le
        // bas. Elle apparaît donc d'elle-même le jour où un document d'une
        // autre langue entre dans l'index.
        if (search.facets[.lang] ?? []).count >= 2 {
            facetSection(key: .lang, title: "Languages",
                         selection: $search.selectedLangs)
        }
        // « Années » se lisait comme l'année de l'OUVRAGE (AP-06) : le moteur
        // range pourtant selon `docs.mtime`, la date de dernière modification
        // du FICHIER — un livre de 2003 recopié sur le Mac en 2024 tombe sous
        // 2024. Le titre dit désormais ce que le filtre fait, et l'infobulle le
        // redit en toutes lettres. Rien ne change dans le moteur.
        // « Daté de » (DD1, PR-07) : l'année INSCRITE dans le document, quand il
        // la porte — au-dessus de « Modifié en », qui date le fichier. Seulement
        // si le jeu trouvé en porte : les documents sans date sortent sous la
        // clé vide, que `SearchModel` écarte, et une section vide serait du
        // bruit. Filtre d'AFFICHAGE, comme l'année du fichier : l'infobulle le
        // dit.
        if !(search.facets[.docYear] ?? []).isEmpty {
            facetSection(key: .docYear, title: "Dated",
                         help: "\(Self.datedHelp) \(Self.displayOnlyHelp)",
                         selection: $search.selectedDocYears)
        }
        facetSection(key: .year, title: "Modified in",
                     help: "\(Self.modifiedInHelp) \(Self.displayOnlyHelp)",
                     selection: $search.selectedYears)
        // Plus d'infobulle d'aveu ici depuis le lot P3 : « Origine du texte »
        // est un vrai filtre, il relance la requête et les totaux le suivent.
        facetSection(key: .source, title: "Text origin",
                     selection: $search.selectedSources)
    }

    // MARK: - Filtres en un clic (R-07)

    /// Quatre raccourcis vers les filtres que l'on pose le plus souvent, en
    /// langage courant : les facettes disent « 2026 » et « ocr_accurate », ce
    /// qui suppose de savoir ce qu'on cherche AVANT de le chercher.
    ///
    /// Les quatre relancent une VRAIE requête depuis le lot P3 : les dates par
    /// `SearchQuery.modifiedAfter`, « PDF » par `exts`, « Pages scannées » par
    /// `sources`. La dernière portait jusque-là l'infobulle d'aveu de la
    /// facette « Origine du texte » — elle ne filtrait que les résultats déjà
    /// chargés —, et cet aveu n'a plus lieu d'être.
    private var quickFilterSection: some View {
        Section("Quick filters") {
            // Les deux puces de DATE sur leur propre ligne chacune (AP-06) :
            // « Modifié cette année » et « Modifié ces 5 dernières années »
            // disent maintenant la nature de la date, et ces phrases-là ne
            // tiennent pas à deux dans une barre latérale de 230 points —
            // vérifié à l'écran, elles se coupaient en « Modifié cette a… ».
            // Les deux autres, courtes, restent côte à côte.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    quickChip(LanguageNames.dateLabel(.thisYear),
                              isOn: search.dateFilter == .thisYear,
                              identifier: "thisYear") {
                        search.toggleDate(.thisYear)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    quickChip(LanguageNames.dateLabel(.lastFiveYears),
                              isOn: search.dateFilter == .lastFiveYears,
                              identifier: "lastFiveYears") {
                        search.toggleDate(.lastFiveYears)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    quickChip(String(localized: "PDF only"), isOn: search.pdfOnly,
                              identifier: "pdfOnly") {
                        search.togglePDFOnly()
                    }
                    // « Pages scannées seulement » se tronquait en « Pages
                    // scannées seul… » dans 125 px (BU-06) : deux mots
                    // suffisent, et l'infobulle dit le reste.
                    quickChip(String(localized: "Scans only"),
                              isOn: search.scannedOnly,
                              help: String(localized: "Only pages that were scanned and read by Fouine."),
                              identifier: "scannedOnly") {
                        search.toggleScannedOnly()
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func quickChip(_ label: String, isOn: Bool, help: String? = nil,
                           identifier: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: label)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(isOn
                                           ? Color.accentColor.opacity(0.20)
                                           : Color.secondary.opacity(0.12)))
                .overlay(Capsule().stroke(isOn ? Color.accentColor : .clear,
                                          lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help ?? String(localized: "Click again to remove this filter."))
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .accessibilityHint(isOn
                           ? String(localized: "Removes this filter.")
                           : String(localized: "Adds this filter."))
        .accessibilityIdentifier("quickFilter.\(identifier)")
    }

    private static var displayOnlyHelp: String {
        String(localized: "This filter applies to the results already shown, not to the whole index.")
    }

    /// Ce que « Modifié en » filtre vraiment (AP-06).
    private static var modifiedInHelp: String {
        String(localized: "The date the file was last changed, not the date of the document.")
    }

    /// « Daté de » : ce que la date du document EST, et d'où elle vient.
    private static var datedHelp: String {
        String(localized: "The year written in the document itself (PDF, Word, EPUB, email, photo), when it carries one.")
    }

    /// Au-delà de ce nombre, les valeurs d'une facette disparaissaient EN
    /// SILENCE (AP-22) : un fonds à vingt dossiers en montrait douze, et rien
    /// ne disait qu'il en manquait.
    private static let facetValuesShown = 12

    @ViewBuilder
    private func facetSection(key: FacetKey, title: LocalizedStringKey,
                              help: String? = nil,
                              selection: Binding<Set<String>>) -> some View {
        let values = search.facets[key] ?? []
        // RIEN TROUVÉ : pas de section à « — » (AP-07). Cinq titres suivis
        // d'un tiret sous une liste vide font du bruit sans information, et
        // ils poussent hors de vue les gestes que l'état vide propose.
        if !(values.isEmpty && search.groups.isEmpty && !search.isFaceting) {
        Section {
            if values.isEmpty {
                Text(search.isFaceting ? "computing…" : "—")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(values.prefix(Self.facetValuesShown), id: \.0) { value, count in
                facetRow(key: key, label: displayLabel(key: key, raw: value),
                         raw: value, count: count, selection: selection)
            }
            if values.count > Self.facetValuesShown {
                Text("Only the first \(Self.facetValuesShown) are shown")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("facet.\(key.rawValue).truncated")
            }
        } header: {
            // L'infobulle se pose sur le TITRE, pas sur la `Section` : une
            // `Section` de `List` ne porte pas de zone de survol à elle.
            if let help {
                Text(title).help(help)
            } else {
                Text(title)
            }
        }
        }
    }

    private func facetRow(key: FacetKey, label: String, raw: String, count: Int,
                          selection: Binding<Set<String>>) -> some View {
        Button {
            toggle(&selection.wrappedValue, raw)
        } label: {
            HStack {
                Image(systemName: selection.wrappedValue.contains(raw)
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection.wrappedValue.contains(raw)
                                     ? Color.accentColor : Color.secondary)
                    .imageScale(.small)
                Text(verbatim: label)
                    .lineLimit(1)
                Spacer()
                Text(verbatim: Format.integer(count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        // La coche est un pictogramme : sans le trait `.isSelected`, rien ne
        // distingue une facette active d'une facette inerte à l'oreille.
        .accessibilityLabel(AccessibilityText.facetLabel(label))
        .accessibilityValue(AccessibilityText.facetValue(pages: count))
        .accessibilityHint(AccessibilityText.facetHint(
            key, selected: selection.wrappedValue.contains(raw)))
        .accessibilityAddTraits(selection.wrappedValue.contains(raw)
                                ? [.isSelected] : [])
        .accessibilityIdentifier("facet.\(key.rawValue).\(raw)")
    }

    /// « OCR » et « OCR rapide (héritage) » ne veulent rien dire hors du
    /// métier : ce que l'utilisateur voit d'un document, c'est qu'il a été
    /// tapé ou scanné, et que le texte d'un scan a été reconstitué — par
    /// Fouine, ou avant elle et moins bien.
    private func displayLabel(key: FacetKey, raw: String) -> String {
        // Un code ISO 639-1 (« fr ») n'est pas un nom de langue : le système
        // sait le dire dans la langue de l'utilisateur (LanguageNames).
        if key == .lang { return LanguageNames.label(raw) }
        guard key == .source else { return raw }
        return LanguageNames.sourceLabel(raw)
    }

    private func toggle(_ set: inout Set<String>, _ value: String) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }

    // MARK: - Options de recherche (§5.6, §12)

    /// UNE section pour les deux réglages qui changent ce que la recherche
    /// trouve. Il y en avait deux, « Approximate matching » et « Semantic
    /// search », dont trois des quatre commandes étaient du vocabulaire de
    /// spécialiste — et l'une d'elles, la portée du flou (pages scannées
    /// seulement ou tout l'index), est un arbitrage de performance qui n'a
    /// rien à faire sous les yeux de quelqu'un qui cherche un document : elle
    /// est partie dans Réglages ▸ Avancé (X2). La propriété `fuzzyScope` du
    /// modèle, elle, ne bouge pas.
    ///
    /// L'interrupteur du sens n'est actif que si le modèle est présent ET que
    /// la base contient de quoi chercher ; sa légende ne s'affiche QUE s'il
    /// est grisé (elle dit alors le geste qui manque) ou si la dernière
    /// recherche a quelque chose à signaler. Une explication permanente sous
    /// un interrupteur allumé qui fonctionne n'apprend plus rien à personne.
    private var searchOptionsSection: some View {
        Section("Search options") {
            // LE SÉLECTEUR SOUS SON ÉTIQUETTE, ET NON À CÔTÉ (BU-05) : posé
            // en ligne, « toujours » débordait de la barre latérale — 286 px
            // de segments dans 262 px de barre, on lisait « jamais | auto |
            // toujou ». La barre se règle de 230 à 360 points : c'est la
            // largeur du texte français qui décide, pas la nôtre.
            VStack(alignment: .leading, spacing: 4) {
                Text("Typos")
                Picker("Typos", selection: $search.fuzzy) {
                    Text("off").tag(FuzzyMode.off)
                    Text("auto").tag(FuzzyMode.auto)
                    Text("always").tag(FuzzyMode.on)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Pas d'`accessibilityLabel` ici : le `Picker` porte déjà son
                // titre, et le doubler faisait annoncer « Fautes de frappe,
                // Fautes de frappe » (relevé dans l'arbre AX).
                .accessibilityIdentifier("sidebar.fuzzy")
            }
            .help("Auto: typos are tolerated only when a word gives no result.")

            Toggle(isOn: $search.semanticEnabled) {
                Label("Also search by meaning", systemImage: "wand.and.stars")
            }
            .disabled(!search.semanticAvailability.isReady)
            .help(search.semanticAvailability.help)
            // Un interrupteur grisé sans raison énoncée est le pire des cas :
            // le hint dit POURQUOI (modèle absent, base sans vecteur).
            .accessibilityHint(search.semanticAvailability.help)
            .accessibilityIdentifier("sidebar.semantic")

            if !search.semanticAvailability.isReady {
                Text(verbatim: search.semanticAvailability.help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Le modèle est là et aucune page n'est prête : le geste qui
                // manque tient en un bouton, ici même (UX-12). Envoyer
                // quelqu'un dans un onglet de réglages pour un clic est une
                // façon de ne pas le proposer.
                if search.semanticAvailability == .noVectors {
                    // QUAND FOUINE S'EN CHARGE, ON NE PROPOSE PLUS DE LE FAIRE
                    // À LA MAIN (AG1, PR-21) : même décision que le bouton
                    // jumeau de l'onglet Indexation, pour que les deux endroits
                    // disent la même chose. `.noVectors` implique que le
                    // modèle est installé.
                    if MeaningPreparation.decide(
                        settingOn: settings.bool(SettingKeys.agentPrepareMeaning),
                        modelInstalled: true,
                        agent: app.agentOperationalState) == .inBackground {
                        Text("Fouine takes care of it in the background, when the Mac is plugged in and idle.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("sidebar.semantic.background")
                    } else {
                        Button("Prepare search by meaning…") {
                            app.sheet = .prepareMeaning
                        }
                        .buttonStyle(.link)
                        .disabled(app.indexing.running)
                        .accessibilityIdentifier("sidebar.semantic.prepare")
                    }
                }
            }

            if let notice = search.semanticNotice {
                Label {
                    Text(verbatim: notice)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Raccourci global (§5.6, audit A10.10)

    /// Un refus de `RegisterEventHotKey` (combinaison déjà prise par une autre
    /// app, session sans serveur de fenêtres) était totalement silencieux :
    /// l'utilisateur appuyait sur ⌥⌘F depuis une autre app et concluait que
    /// Fouine était cassée. La section n'apparaît QUE dans ce cas.
    @ViewBuilder
    private var shortcutSection: some View {
        if app.globalHotKeyAvailable == false {
            Section("Shortcut") {
                Label {
                    Text("The ⌥⌘F global shortcut could not be registered: another application already uses it. Inside Fouine, ⌥⌘F works normally.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
