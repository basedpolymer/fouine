// SettingsView.swift — la fenêtre de réglages ⌘, (audit U2, session UX du
// 04/09/2026 UX-10). Propriété : A-App.
//
// SIX onglets, et le découpage n'est pas décoratif : il sépare ce qu'un
// utilisateur ordinaire change de ce qu'un dépanneur touche une fois.
//
//   · GÉNÉRAL — la présence de Fouine sur le Mac : l'icône de la barre des
//     menus, l'ouverture à la session, l'annonce de fin de lecture, le
//     raccourci. Ce sont les seuls réglages qui parlent de l'application
//     elle-même plutôt que de l'index.
//   · DOSSIERS — ce qu'on indexe. Les gestes sont ceux du palier 1, RÉUTILISÉS
//     tels quels (`AppModel.addRoots/removeRoot/setRootEnabled/renameRoot`) :
//     la barre latérale et cette fenêtre appellent le même code, il n'y a pas
//     deux façons de retirer un dossier.
//   · INDEXATION — QUAND Fouine se met à jour toute seule, et dans quelles
//     langues elle lit les documents scannés. Rien de plus : les fils, la
//     durée d'un lot et la période de contrôle sont partis dans Avancé, où
//     personne ne tombe dessus par hasard.
//   · RECHERCHE PAR LE SENS — l'interrupteur existant et l'état du modèle.
//   · MISES À JOUR — Sparkle (palier 2.9, D13). L'onglet est fourni tel quel par
//     A-Pack (`UpdatesSettingsView`), il n'a besoin que de son contrôleur ; il
//     est ici parce qu'un utilisateur de macOS cherche « mises à jour » dans la
//     fenêtre de réglages, et nulle part ailleurs.
//   · AVANCÉ — pour les dépanneurs : fils, durée d'un lot, période, portée du
//     flou, outil en ligne de commande (venu du menu Fouine, UX-11), journal,
//     emplacement de l'index.
//
// CE QUI VA OÙ. Tout ce qui doit être vu par l'AGENT va dans la table
// `settings` (§10) ; ce qui est purement d'interface reste dans `UserDefaults`
// — l'interrupteur « rechercher aussi par le sens », l'icône de la barre des
// menus et la portée du flou en sont les seuls exemples ici.

import SwiftUI
import AppKit
import FouineCore
import FouineIndex

/// Les six onglets, nommés pour qu'un élément de menu puisse en viser un.
enum SettingsTab: Hashable {
    case general, folders, indexing, updates, advanced
}

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var search: SearchModel
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var updates: UpdatesController

    /// L'onglet montré : un élément de menu ou le refus d'un dossier
    /// d'application peut en viser un.
    @State private var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            FoldersSettingsTab()
                .tabItem { Label("Folders", systemImage: "folder") }
                .tag(SettingsTab.folders)
            IndexingSettingsTab()
                .tabItem { Label("Indexing", systemImage: "text.viewfinder") }
                .tag(SettingsTab.indexing)
            // Vue AUTONOME d'A-Pack : elle ne dépend que de son contrôleur, et
            // se pose telle quelle (en-tête d'`UpdatesSettingsView.swift`).
            UpdatesSettingsView(updates: updates)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
                .tag(SettingsTab.updates)
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.advanced)
        }
        // « Open Settings » (le refus du dossier d'une application) dépose
        // l'onglet, ouvre la fenêtre, PUIS
        // l'annonce par une notification, comme ⌥⌘F pour le champ de
        // recherche. Un élément de menu vit hors de la hiérarchie de vues et
        // n'a pas d'autre moyen d'atteindre un `@State` d'ici. Une fenêtre qui
        // naît ne s'est pas encore abonnée : elle relève l'onglet déposé.
        .onReceive(NotificationCenter.default.publisher(for: .fouineShowSettingsTab)) { note in
            if let wanted = note.object as? SettingsTab {
                tab = wanted
                SettingsWindow.pendingTab = nil
            }
        }
        .onAppear {
            if let wanted = SettingsWindow.takePendingTab() { tab = wanted }
        }
        // 620 de large : l'onglet Dossiers doit montrer un chemin absolu sans le
        // tronquer au milieu. La HAUTEUR est négociable — `idealHeight` et non
        // `height` — parce que l'onglet « Avancé » est plus haut que ce qu'un
        // 13" peut afficher : son contenu défile, et qui a de la place peut
        // agrandir la fenêtre pour tout voir d'un coup.
        .frame(minWidth: 620, idealWidth: 620, maxWidth: 620,
               minHeight: 480, idealHeight: 640)
        .task {
            await settings.load()
            await app.refreshRoots(probe: false)
        }
        // Le titre nomme ce dont l'alerte parle quand elle le sait (Spotlight,
        // audit BU-25) : « Réglages / Les documents de Fouine ont été retirés
        // de Spotlight » ne disait pas de quoi il s'agissait.
        .alert(Text(verbatim: settings.noticeTitle
                    ?? String(localized: "Settings")),
               isPresented: Binding(
            get: { settings.notice != nil },
            set: { if !$0 { settings.notice = nil; settings.noticeTitle = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: settings.notice ?? "")
        }
    }
}

// MARK: - Onglet 1 · Général (UX-07, UX-09, UX-10)

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var interface: InterfacePreferences

    /// Le retrait de Spotlight se confirme : c'est un geste qui défait
    /// silencieusement quelque chose que l'utilisateur ne voit pas d'ici.
    @State private var confirmingSpotlightRemoval = false

    /// La case des notifications suit l'AUTORISATION, pas le réglage seul
    /// (audit BU-23) : ces deux états sont relus à chaque affichage de
    /// l'onglet et après chaque geste, jamais devinés.
    @State private var notifyOn = false
    @State private var notifyNotice: NotificationConsent.Notice?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                presence
                Divider()
                notifications
                Divider()
                spotlight
                Divider()
                shortcut
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // macOS peut avoir défait l'ouverture à la session pendant que la
        // fenêtre était fermée (l'utilisateur décoche la case dans Réglages
        // Système) : on relit, on ne se souvient pas. Même raisonnement pour
        // l'autorisation des messages, qui se retire au même endroit.
        .task {
            // DANS SA PROPRE TÂCHE : cette lecture passe par `smd`, qui peut
            // traîner (PI-03), et le reste de l'onglet n'a aucune raison de
            // l'attendre pour s'afficher.
            Task { await interface.refreshLoginItem() }
            // `load()` d'abord : la case doit partir de la valeur ÉCRITE, et
            // non du zéro d'un modèle encore vide (la fenêtre charge en
            // parallèle ; l'appel est idempotent).
            await settings.load()
            await refreshNotificationConsent()
        }
    }

    private var presence: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fouine on this Mac").font(.headline)

            Toggle("Keep Fouine in the menu bar", isOn: $interface.showsMenuBarIcon)
            // L'icône change de nouveau avec l'état de l'index (AP1) : la
            // phrase ne peut plus dire « la petite loupe », elle dirait faux
            // pendant une mise à jour.
            Text("The small icon at the top of the screen lets you search your documents and open Fouine. It also shows what the index is doing. While it is there, closing the window no longer quits Fouine.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // « Chercher pendant que je tape » (AP1). Ici et non dans un onglet
            // « Recherche » : c'est une façon dont Fouine se comporte sous les
            // doigts, comme les deux cases au-dessus, et le seul onglet de
            // recherche existant ne parle que du sens.
            Toggle("Search as I type", isOn: $interface.searchesAsYouType)
            Text("Results appear as you type. Off, press Return to search.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Open Fouine when I log in", isOn: Binding(
                get: { interface.opensAtLogin },
                set: { interface.setOpensAtLogin($0) }
            ))
            .disabled(!interface.canOpenAtLogin)
            .help(interface.openAtLoginHelp)
            // Une case grisée dont la raison n'existe qu'au survol ne se
            // comprend pas à la souris, et pas du tout au clavier (audit
            // AP-24) : la raison est écrite sous elle, comme sous
            // l'interrupteur du sens dans la barre latérale.
            if !interface.canOpenAtLogin {
                Text(verbatim: interface.openAtLoginHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = interface.loginNotice {
                Text(verbatim: notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("The index is kept up to date even when Fouine is closed. That is the job of the switch under “Index” in the main window.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Venue de l'onglet « Indexation & OCR » (UX-10) : c'est un réglage de
    /// l'APPLICATION — quand est-ce qu'elle vous parle — et non de l'index.
    private var notifications: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notifications").font(.headline)
            Toggle("Tell me when the scanned pages are all read", isOn: Binding(
                get: { notifyOn },
                // Le setter n'est appelé que par le GESTE de l'utilisateur :
                // remettre `notifyOn` à zéro plus bas ne le rappelle pas, et
                // il n'y a donc pas de boucle.
                set: { wanted in
                    notifyOn = wanted
                    Task { await applyNotificationChoice(wanted: wanted) }
                }
            ))
            .disabled(settings.isOverridden(SettingKeys.notifyOnQueueDrained))
            .help(settings.help(SettingKeys.notifyOnQueueDrained))

            // Ce qui manque, et le geste qui le donne. La case est revenue à
            // zéro : sans cette ligne, elle serait revenue sans un mot.
            if let notice = notifyNotice {
                HStack(spacing: 6) {
                    Text(verbatim: notice.message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if let url = notice.settingsURL {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(url)
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                    }
                }
            }

            Text("The message comes from Fouine itself: if Fouine is closed when the last page is read, there is none.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// L'ordre qui rend la case honnête (audit BU-23) : DEMANDER, RELIRE,
    /// puis seulement écrire. Le réglage écrit avant la demande promettait des
    /// messages que macOS n'avait jamais autorisés — et n'enverrait jamais.
    private func applyNotificationChoice(wanted: Bool) async {
        if wanted { await Notifier.requestAuthorization() }
        let status = await Notifier.authorizationStatus()
        let outcome = NotificationConsent.resolve(wanted: wanted, status: status)
        settings.setBool(SettingKeys.notifyOnQueueDrained, outcome.switchOn)
        notifyOn = outcome.switchOn
        notifyNotice = outcome.notice
    }

    /// À chaque affichage de l'onglet : une autorisation retirée dans les
    /// Réglages Système éteint la case et montre la ligne.
    private func refreshNotificationConsent() async {
        let wanted = settings.bool(SettingKeys.notifyOnQueueDrained)
        let status = await Notifier.authorizationStatus()
        let outcome = NotificationConsent.resolve(wanted: wanted, status: status)
        if wanted && !outcome.switchOn {
            settings.setBool(SettingKeys.notifyOnQueueDrained, false)
        }
        notifyOn = outcome.switchOn
        notifyNotice = outcome.notice
    }

    /// Fouine dans Spotlight (lot INT-S1).
    ///
    /// La portée est un choix EXCLUSIF, donc deux boutons radio et non une
    /// seconde case : « tout » et « seulement ce que Spotlight ne lit pas »
    /// s'excluent, et une case à cocher imbriquée sous une autre case se lit
    /// mal. Les deux boutons du bas ne sont pas décoratifs : le premier est le
    /// seul geste qui retire de Spotlight un document supprimé depuis, le
    /// second rend le Mac exactement comme avant.
    private var spotlight: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Spotlight").font(.headline)

            Toggle("Show Fouine's documents in Spotlight", isOn: Binding(
                get: { settings.bool(SettingKeys.spotlightEnabled) },
                set: { settings.setSpotlightEnabled($0) }
            ))
            .disabled(spotlightLocked)
            .help(settings.spotlightHelp)

            // La raison du grisé, EN CLAIR (audit AP-24). Deux causes
            // possibles, et elles ne se disent pas de la même façon : hors
            // application installée, Fouine ne peut pas parler à Spotlight ;
            // sous variable d'environnement, la valeur est imposée.
            if !settings.spotlightAvailable {
                Text(verbatim: settings.spotlightHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if settings.isOverridden(SettingKeys.spotlightEnabled) {
                OverriddenNote(spec: SettingKeys.spotlightEnabled)
            }

            Picker("", selection: Binding(
                get: { settings.bool(SettingKeys.spotlightAllDocuments) },
                set: { settings.setSpotlightAllDocuments($0) }
            )) {
                Text("Only what Spotlight cannot read itself (scanned pages, DjVu, comics…)")
                    .tag(false)
                Text("Every document Fouine has read").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .padding(.leading, 18)
            .disabled(spotlightLocked
                      || !settings.bool(SettingKeys.spotlightEnabled)
                      || settings.isOverridden(SettingKeys.spotlightAllDocuments))

            Text("Spotlight results open in Fouine, on the page where your words are. Nothing leaves this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Update Spotlight now") { settings.refreshSpotlight() }
                Button("Remove Fouine's documents from Spotlight") {
                    confirmingSpotlightRemoval = true
                }
            }
            .disabled(!settings.spotlightAvailable || settings.spotlightWorking)

            // La SEULE preuve visible qu'un don a eu lieu (audit BU-26) :
            // `mdfind` ne voit pas ce que Fouine donne à Spotlight, le journal
            // ne dit rien des succès, et le dossier de Spotlight est protégé.
            Text(verbatim: settings.spotlightHandoverSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .alert("Remove Fouine's documents from Spotlight?",
               isPresented: $confirmingSpotlightRemoval) {
            Button("Remove", role: .destructive) { settings.removeFromSpotlight() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your documents are not touched, and Fouine keeps finding them. Only Spotlight forgets them.")
        }
    }

    /// Hors application installée, la section reste VISIBLE mais figée : la
    /// faire disparaître laisserait croire que Fouine ne sait pas le faire.
    private var spotlightLocked: Bool {
        !settings.spotlightAvailable
            || settings.isOverridden(SettingKeys.spotlightEnabled)
    }

    private var shortcut: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keyboard shortcut").font(.headline)
            Text("⌥⌘F opens Fouine and puts the cursor in the search field, from wherever you are.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Un refus de la combinaison est silencieux côté système : le taire
            // ici laisserait croire que Fouine est cassée (audit A10.10).
            if app.globalHotKeyAvailable == false {
                Label("Another application already uses ⌥⌘F. Inside Fouine, the shortcut works normally.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Onglet 2 · Dossiers

private struct FoldersSettingsTab: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: SettingsModel

    @State private var renaming: RootStatus?
    @State private var draftLabel = ""
    /// La racine dont la feuille « Ce que Fouine ignore… » est ouverte (IG2).
    @State private var skipping: RootStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fouine reads these folders without ever modifying them.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let error = app.rootsError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            List {
                if app.roots.isEmpty {
                    Text("No folder indexed. Use “Add a folder…” below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(app.roots) { root in
                    row(root)
                }
            }
            .listStyle(.inset)
            // La liste cède la place à la section « Applications » sous elle :
            // sans plancher, une liste vide l'écraserait ; sans plafond, une
            // liste de vingt dossiers la pousserait hors de la fenêtre.
            .frame(minHeight: 120)

            // Pas de légende à côté du bouton : elle expliquait une ★ que
            // rien ne dessinait (audit AP-13). La case « Lire ses pages
            // scannées en premier » de chaque ligne se suffit.
            HStack {
                Button("Add a folder…") { app.chooseRootsToAdd() }
                Spacer()
            }

            Divider()
            applications
        }
        .padding(16)
        .task { await settings.loadAppSources() }
        .alert("Rename label", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        ), presenting: renaming) { root in
            TextField("Label", text: $draftLabel)
            Button("Rename") {
                let wanted = draftLabel
                Task { await app.renameRoot(root, to: wanted) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The label is this folder's name in the “Folders” facet and in “folder:…” queries.")
        }
        // Une FEUILLE et non une alerte : la liste des règles, trois gestes et
        // une phrase de conséquence ne tiennent pas dans une alerte. Elle ne
        // s'empile sur rien — l'alerte de renommage et l'`NSAlert` de retrait
        // sont des gestes distincts qui ne s'ouvrent jamais depuis elle.
        .sheet(item: $skipping) { root in
            IgnoreRulesSheet(root: root)
                .environmentObject(app)
        }
    }

    // MARK: - Applications (lot INT-F4)

    /// Les notes d'Apple Notes et de Bear, les cartes d'Anki (lot AN1).
    ///
    /// UNE case par application, et sous chacune l'état en clair. On dit ce que
    /// Fouine fait — « copie le texte de vos notes dans son propre dossier » —
    /// parce que c'est vrai, que c'est visible dans le Finder, et que
    /// l'apprendre par hasard serait pire que de le lire ici.
    ///
    /// Notion et Craft n'ont pas de case : leurs notes ne se lisent pas sur ce
    /// Mac. La phrase dit le geste (exporter, puis ajouter le dossier
    /// ci-dessus) plutôt que de laisser croire à un oubli.
    private var applications: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Applications").font(.headline)
            Text("Fouine copies the text of your notes into its own folder so it can search them; nothing leaves this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(settings.appSources) { source in
                applicationRow(source)
            }

            Text("Notion and Craft: export your pages as Markdown, then add the export folder above with “Add a folder…”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func applicationRow(_ source: SettingsModel.AppSourceState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(
                get: { source.enabled },
                set: { settings.setAppSourceEnabled(source.id, $0) }
            )) {
                HStack(spacing: 6) {
                    SourceAppIcon(sourceID: source.id)
                    Text(verbatim: source.name)
                }
            }
            .disabled(source.presence == .absent || settings.sourcesWorking)

            HStack(spacing: 6) {
                switch source.presence {
                case .absent:
                    Text("not installed on this Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .accessDenied:
                    Text("Fouine is not allowed to read these notes.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Open System Settings") {
                        settings.openFullDiskAccessSettings()
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                case .ready:
                    if source.enabled {
                        Text("\(source.notes) note(s) searchable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 18)
        }
    }

    private func row(_ root: RootStatus) -> some View {
        // Le dossier d'une application (lot AN2) : son icône, et à la place du
        // chemin vers le dossier de travail de Fouine, où il s'éteint. Ni
        // Finder, ni renommage, ni retrait — la passe suivante le recréerait —,
        // ni lecture des scans : il n'y en a pas.
        let source = SourceDocumentLocator.standard.source(rootRelPath: root.record.relPath)
        return HStack(alignment: .top, spacing: 10) {
            // Activer / désactiver : le geste du menu contextuel de la barre
            // latérale, sous une forme qu'on trouve sans clic droit.
            Toggle("", isOn: Binding(
                get: { root.record.enabled },
                set: { on in Task { await app.setRootEnabled(root, on) } }
            ))
            .labelsHidden()
            .help(root.record.enabled
                  ? "Folder watched and indexed"
                  : "Folder ignored; its index stays searchable")
            // Sans libellé, VoiceOver annonçait « case à cocher, cochée » et
            // rien d'autre : ni le dossier, ni ce que la case fait (BU-14).
            .accessibilityLabel(Text("Index “\(root.label)”"))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let source { SourceAppIcon(sourceID: source.id) }
                    Text(verbatim: root.label).fontWeight(.medium)
                    if !root.readable && root.record.enabled {
                        Image(systemName: "lock.fill").foregroundStyle(.orange)
                    }
                }
                if let source {
                    Text("Copied from \(source.displayName). To stop, untick it under “Applications” below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(verbatim: root.absolutePath ?? root.record.relPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let reason = root.reason {
                    Text(verbatim: reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if source == nil {
                    Toggle("Read its scanned pages first", isOn: Binding(
                        get: { settings.isPinned(root.id) },
                        set: { settings.setPinned(root.id, $0) }
                    ))
                    .font(.caption)
                    .disabled(settings.isOverridden(SettingKeys.pinnedRoots))
                    .help(settings.help(SettingKeys.pinnedRoots))
                    // Sous la case, et pas dans le menu « … » : c'est un geste
                    // qu'on cherche (« comment sortir Santé de l'index ? »), et
                    // un menu caché derrière une icône ne se trouve pas.
                    Button("What Fouine skips…") { skipping = root }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            Spacer()

            if source == nil {
                Menu {
                    Button("Show in Finder") {
                        guard let path = root.absolutePath else { return }
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: path)])
                    }
                    .disabled(root.absolutePath == nil)
                    Button("Rename label…") {
                        draftLabel = root.label
                        renaming = root
                    }
                    Divider()
                    // Le retrait détruit un index qui a pu coûter des heures de
                    // lecture : la même confirmation que la barre latérale.
                    Button("Remove and delete its index…", role: .destructive) {
                        confirmRemoval(root)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.vertical, 4)
    }

    /// `NSAlert` et non `.alert` : une troisième alerte SwiftUI sur la même vue
    /// est exactement le travers d'A10.6 (deux feuilles empilées dont la
    /// seconde ne s'ouvre pas). Le geste est destructif, il mérite un modal net.
    private func confirmRemoval(_ root: RootStatus) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove “\(root.label)”?")
        alert.informativeText = String(localized: "The folder will be removed and its whole index deleted: documents, pages, and the text already read from its scans. Your files are not modified. To keep the index, disable the folder instead of removing it.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await app.removeRoot(root) }
    }
}

// MARK: - Onglet 3 · Indexation (UX-10)

private struct IndexingSettingsTab: View {
    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                conditions
                Divider()
                images
                Divider()
                media
                Divider()
                languages
            }
            .padding(16)
        }
    }

    // MARK: Images (PR-05, C2-13)

    /// La case qui manquait. Les images sont lues depuis le lot INT-F2 — dix-neuf
    /// extensions, photos et RAW compris — mais rien dans les six onglets ne
    /// permettait de les allumer : il fallait un terminal, pour un public défini
    /// par le fait qu'il n'en ouvre pas. Cent cinquante-deux images dormaient
    /// ainsi dans les dossiers du propriétaire.
    ///
    /// Deux phrases sous la case, et pas une de plus : ce que cela COÛTE (chaque
    /// image passe par la reconnaissance de texte), et ce que cela DONNE
    /// vraiment — un document photographié se lit, une enseigne ou une étiquette
    /// décorative, presque jamais (C2-13, mesuré sur quatre photos réelles).
    private var images: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Images").font(.headline)
            SettingCheck(spec: SettingKeys.extractImages,
                         title: "Index images (photos, scans, camera RAW files)")
            VStack(alignment: .leading, spacing: 6) {
                Text("Every image has to be read one by one: on a large folder of photos, this can keep Fouine busy for hours.")
                Text("Fouine reads the text of photographed documents; shop signs, labels and decorative lettering often escape it.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 18)
        }
    }

    // MARK: Sons et vidéos (lot INT-F3)

    /// Deux cases, et la seconde dépend de la première. La phrase de la seconde
    /// annonce le COÛT — « à peu près la durée de l'enregistrement » — parce que
    /// c'est la seule chose qu'on puisse promettre honnêtement : sur un i5, une
    /// heure de cours prend une heure.
    private var media: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sound and video files").font(.headline)
            SettingCheck(spec: SettingKeys.extractMedia,
                         title: "Index audio and video files (titles, artists, chapters…)")
            VStack(alignment: .leading, spacing: 6) {
                SettingCheck(spec: SettingKeys.extractTranscribe,
                             title: "Also write down what is said in them")
                Text("Fouine listens on this Mac and writes down the words. Nothing is sent anywhere. Count roughly the length of the recording, and install the language under System Settings ▸ Keyboard ▸ Dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingStepper(spec: SettingKeys.transcribeMaxMinutes,
                               title: "Longest recording to write down (minutes)",
                               step: 10)
            }
            .padding(.leading, 18)
            .disabled(!settings.bool(SettingKeys.extractMedia))
        }
    }

    // MARK: Quand mettre à jour automatiquement (les conditions du §5.7)

    private var conditions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("When to update automatically").font(.headline)
            Text("Fouine updates the index by itself when your documents change. These three conditions stop it from taking the Mac, or the battery, away from you. Unticking one lets it work anyway.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingCheck(spec: SettingKeys.agentRequireAC,
                         title: "Only when the Mac is plugged in")
            SettingCheck(spec: SettingKeys.agentPauseOnLowPower,
                         title: "Not in Low Power Mode")
            SettingCheck(spec: SettingKeys.agentPauseOnThermal,
                         title: "Not when the Mac is hot")

        }
    }

    // MARK: Langues (audit X2)

    private var languages: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Languages of the scanned documents").font(.headline)
            Text("Fouine only recognises the languages installed on this Mac. Ticking several makes reading slower; ticking none is refused.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.availableOCRLanguages.isEmpty {
                Text("Language list unavailable: the system did not answer. Reading will use “\(settings.string(SettingKeys.ocrLanguages))”.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let selected = Set(settings.selectedOCRLanguages.map { $0.lowercased() })
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        // Rangées par leur NOM, et sans leur code (audit
                        // AP-23, BU-09) : le code ne sert à rien à qui coche
                        // une case, et il reste en info-bulle pour qui dépanne.
                        ForEach(settings.sortedOCRLanguages, id: \.code) { language in
                            Toggle(isOn: Binding(
                                get: { selected.contains(language.code.lowercased()) },
                                set: { settings.toggleOCRLanguage(language.code, $0) }
                            )) {
                                Text(verbatim: language.name)
                            }
                            .help(language.code)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 130)
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.secondary.opacity(0.3)))
                .disabled(settings.isOverridden(SettingKeys.ocrLanguages))
            }

            // Une langue demandée mais absente de la machine est ÉCARTÉE à
            // l'exécution : la taire ferait disparaître un réglage sans un mot.
            if !settings.unsupportedOCRLanguages.isEmpty {
                Label("Not supported here, therefore ignored: \(settings.unsupportedOCRLanguages.joined(separator: ", "))",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if settings.isOverridden(SettingKeys.ocrLanguages) {
                OverriddenNote(spec: SettingKeys.ocrLanguages)
            }
        }
    }
}

// MARK: - Onglet 4 · Avancé (UX-10)

/// Ce que personne ne devrait avoir à toucher. L'onglet existe pour deux
/// publics : celui qui dépanne (journal, emplacement de l'index, outil en ligne
/// de commande) et celui qui sait ce qu'il fait (fils, durée d'un lot).
private struct AdvancedSettingsTab: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var search: SearchModel
    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("These settings are here for troubleshooting. The values that come with Fouine suit almost every Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                concurrency
                Divider()
                fuzzy
                Divider()
                tools
                Divider()
                storage
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Fils et lots

    private var concurrency: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How much Fouine does at once").font(.headline)
            SettingStepper(spec: SettingKeys.extractJobs, title: "Documents read at once")
            SettingStepper(spec: SettingKeys.ocrJobs, title: "Scanned pages read at once")
            SettingStepper(spec: SettingKeys.agentExtractJobs,
                           title: "Documents read at once in the background")
            SettingStepper(spec: SettingKeys.agentOCRBudgetMinutes,
                           title: "Length of a reading batch (minutes)")
            SettingStepper(spec: SettingKeys.agentPollSeconds,
                           title: "Check period (seconds)", step: 5)
            // Les deux plafonds valent 4 pour des raisons DIFFÉRENTES, et le
            // dire évite de les prendre pour une limitation arbitraire.
            Text("Both stop at \(JobsCap.extractMaxJobs), for two different reasons. Reading documents takes a lot of memory. Reading scanned pages goes no faster beyond that: measured on this kind of Mac, eight at a time return fewer pages per second than four.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Portée du flou (venue de la barre latérale, UX-04/UX-10)

    private var fuzzy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Typo tolerance").font(.headline)
            Picker("Typo tolerance applies to:", selection: $search.fuzzyScope) {
                Text("scanned pages only").tag(FuzzyScope.ocrOnly)
                Text("the whole index").tag(FuzzyScope.all)
            }
            .pickerStyle(.radioGroup)
            // Le texte justifiait l'inverse du besoin — « le texte que vous
            // avez tapé a rarement besoin de tolérance » —, alors que les
            // fautes les plus fréquentes sont celles de la REQUÊTE, et
            // qu'elles ne dépendent pas de l'origine de la page (audit C2-08).
            // Recalé par le lot MP1 sur ce qui est vrai depuis le repli
            // automatique : il ne nomme plus « auto » ni « toujours », deux
            // valeurs d'un sélecteur qui n'est pas sur cet écran (réserve du
            // lot UX3), et il dit le repli, qui est ce que l'utilisateur voit.
            Text("Scanned pages carry most wrong letters. When a search finds nothing, Fouine also tries close spellings in every document.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Outils (l'outil en ligne de commande vient du menu Fouine, UX-11)

    private var tools: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tools").font(.headline)

            HStack {
                Button("Install the command line tool…") {
                    let outcome = CLIInstaller.install()
                    let alert = NSAlert()
                    alert.messageText = outcome.title
                    alert.informativeText = outcome.message
                    alert.addButton(withTitle: String(localized: "OK"))
                    alert.runModal()
                }
                .disabled(!CLIInstaller.isAvailable)
                .help(CLIInstaller.isAvailable
                      ? String(localized: "Adds the “fouine” command to the Terminal application, pointing at this copy of Fouine.")
                      : String(localized: "Only available from the installed application: “swift run FouineApp” has no command to install."))
            }

            HStack {
                Button("Open the activity log") {
                    // Le journal reste le SEUL endroit où un incident (dossier
                    // illisible, page en échec) est visible : la barre de
                    // progression dit ce qui avance, pas ce qui a raté.
                    NSWorkspace.shared.open(FouinePaths.agentLogURL())
                }
                Text(verbatim: FouinePaths.agentLogURL().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("The log says what happened while the index was updating by itself: folders that could not be read, pages that failed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Emplacement de l'index (venu du pied de la barre latérale)

    private var storage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where the index is stored").font(.headline)
            Text(verbatim: AppPaths.databaseURL().path)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [AppPaths.databaseURL()])
                }
                Text("It takes \(Format.bytes(app.stats["db_bytes"] ?? 0)) on disk. Your documents are not copied there: Fouine only keeps their text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Contrôles partagés par les onglets

private struct SettingStepper: View {
    @EnvironmentObject private var settings: SettingsModel
    let spec: SettingSpec
    let title: LocalizedStringKey
    var step: Int = 1

    var body: some View {
        let bounds = spec.range ?? (min: 1, max: 99)
        HStack {
            Stepper(value: Binding(
                get: { settings.int(spec) },
                set: { settings.setInt(spec, $0) }
            ), in: bounds.min...bounds.max, step: step) {
                Text("\(Text(title)): \(settings.int(spec))")
            }
            .disabled(settings.isOverridden(spec))
            .help(settings.help(spec))
            if settings.isOverridden(spec) { OverriddenBadge(spec: spec) }
        }
    }
}

private struct SettingCheck: View {
    @EnvironmentObject private var settings: SettingsModel
    let spec: SettingSpec
    let title: LocalizedStringKey

    var body: some View {
        HStack {
            Toggle(title, isOn: Binding(
                get: { settings.bool(spec) },
                set: { settings.setBool(spec, $0) }
            ))
            .disabled(settings.isOverridden(spec))
            .help(settings.help(spec))
            if settings.isOverridden(spec) { OverriddenBadge(spec: spec) }
        }
    }
}

/// Une clé forcée par l'environnement est montrée en lecture seule ET
/// nommée : sans cela, l'utilisateur saisit une valeur, la voit revenir à
/// l'ancienne, et conclut que la fenêtre est cassée (audit U2).
private struct OverriddenBadge: View {
    @EnvironmentObject private var settings: SettingsModel
    let spec: SettingSpec

    var body: some View {
        Text(verbatim: spec.environmentVariable
             ?? String(localized: "environment"))
            .font(.caption2.monospaced())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.orange.opacity(0.2), in: Capsule())
            .help(settings.help(spec))
    }
}

private struct OverriddenNote: View {
    let spec: SettingSpec

    var body: some View {
        Text("Forced by \(spec.environmentVariable ?? String(localized: "the environment")). Remove the variable to set this value here.")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}
