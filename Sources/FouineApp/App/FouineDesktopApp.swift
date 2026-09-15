// FouineDesktopApp.swift — scène SwiftUI de Fouine.app (SPEC §5.6).
// Propriété : A-App.
//
// L'app doit tourner dans DEUX contextes (§5.6) : `swift run FouineApp` sans
// bundle (développement) et Fouine.app signée (A-Pack). Rien ici n'exige le
// bundle : la politique d'activation est forcée à `.regular` pour qu'une fenêtre
// apparaisse même lancée depuis un terminal.

import SwiftUI
import AppKit
import OSLog
import CoreSpotlight
import FouineCore
import FouineIndex

extension Notification.Name {
    /// ⌥⌘F — local (Commands) comme global (Carbon) : amener la fenêtre au
    /// premier plan et donner le focus au champ de recherche.
    static let fouineFocusSearch = Notification.Name("io.github.basedpolymer.fouine.focusSearch")
    /// Ouvrir les réglages sur un onglet précis (`SettingsTab` en `object`) :
    /// « Enter licence key… » vise Licence (lot L1C), le refus du dossier
    /// d'une application vise Dossiers.
    static let fouineShowSettingsTab = Notification.Name("io.github.basedpolymer.fouine.showSettingsTab")
}

/// Ouvre la fenêtre de réglages sur l'onglet « Licence ».
@MainActor
func openLicenceSettings() {
    openSettings(on: .licence)
}

/// Ouvre la fenêtre de réglages sur l'onglet voulu.
///
/// L'ACTION DE SWIFTUI, PAS LE SÉLECTEUR. Depuis macOS 14, envoyer
/// `showSettingsWindow:` à l'application ne fait plus rien : SwiftUI écrit
/// « Please use SettingsLink for opening the Settings scene » au journal, et
/// aucune fenêtre ne vient. « Enter licence key… » (menu et carte), « Manage in
/// Settings… » et « Open Settings » sont restés muets ainsi depuis leur
/// création (constaté le 14/09/2026, build 908, macOS 15.7). L'action
/// `openSettings` n'existe que dans l'environnement d'une vue : `SettingsWindow`
/// la retient, comme `MainWindow` retient `openWindow`.
///
/// L'ONGLET EST DÉPOSÉ AVANT L'OUVERTURE. Une fenêtre qui naît ne s'est pas
/// encore abonnée à la notification : elle relève l'onglet en apparaissant.
/// Une fenêtre déjà construite le reçoit par la notification, un tour de
/// boucle plus tard.
@MainActor
func openSettings(on tab: SettingsTab) {
    SettingsWindow.pendingTab = tab
    NSApp.activate(ignoringOtherApps: true)
    SettingsWindow.open()
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .fouineShowSettingsTab, object: tab)
    }
}

/// La fenêtre de réglages ⌘, ouverte par un bouton ou un élément de menu.
@MainActor
enum SettingsWindow {

    /// L'onglet demandé et pas encore montré, relevé par `SettingsView` à son
    /// apparition.
    static var pendingTab: SettingsTab?

    /// `openSettings` de SwiftUI, retenu par `SettingsWindowRegistrar` dès
    /// qu'une vue apparaît (fenêtre principale ou panneau de la barre des
    /// menus). Une fermeture et non `OpenSettingsAction` : une propriété
    /// stockée ne peut pas porter `@available(macOS 14)`.
    private static var opener: (() -> Void)?

    static func register(_ open: @escaping () -> Void) { opener = open }

    /// Rend l'onglet demandé, une seule fois.
    static func takePendingTab() -> SettingsTab? {
        defer { pendingTab = nil }
        return pendingTab
    }

    static func open() {
        if let opener {
            opener()
            return
        }
        // macOS 13 : l'action n'existe pas, et le sélecteur y marche encore.
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}

final class FouineAppDelegate: NSObject, NSApplicationDelegate {

    private var windowObserver: NSObjectProtocol?

    /// Ce qu'il faut mettre en route dès que l'application est vivante, avec ou
    /// sans fenêtre (BU-02) : ouvrir l'index, et tout ce qui en dépend sans
    /// dépendre de la fenêtre.
    ///
    /// POURQUOI PAR UNE FERMETURE. Le délégué est construit par SwiftUI
    /// (`@NSApplicationDelegateAdaptor`) : il n'a aucun accès aux modèles de la
    /// scène, qui sont des `@StateObject` de l'`App`. C'est donc l'`App`, dans
    /// son `init()`, qui lui remet le geste à jouer. Et il DOIT partir d'ici :
    /// tant qu'il vivait dans le `.task` de la fenêtre, un lancement sans
    /// fenêtre — ouverture de session, restauration d'état — n'ouvrait jamais
    /// la base, le panneau de la barre des menus restait sur « Vérification… »,
    /// l'interrupteur était grisé et une recherche répondait par un message de
    /// développeur.
    @MainActor static var launch: (@MainActor @Sendable () async -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sans bundle, l'exécutable démarre en processus d'arrière-plan : sans
        // cette ligne, `swift run FouineApp` ne montre aucune fenêtre.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        observeWindowClosing()
        Task { @MainActor in await Self.launch?() }

        // Ouverte par le système à l'ouverture de session (UX-09) : Fouine est
        // là, dans la barre des menus, sans fenêtre. La scène `Window` crée la
        // sienne au tour de boucle suivant — on la ferme après, pas avant.
        guard WindowLifecyclePolicy.startsWithoutWindow(
                menuBarShown: Prefs.showsMenuBarIcon,
                launchedBySystem: WindowLifecyclePolicy.launchedBySystem(notification.userInfo))
        else { return }
        Task { @MainActor in MainWindow.hideForLoginLaunch() }
    }

    /// Fermer la fenêtre ne quitte plus Fouine quand l'icône de la barre des
    /// menus est là (UX-08) : c'est elle qui rouvre la fenêtre, et c'est elle
    /// qui montre que l'index travaille.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        WindowLifecyclePolicy.terminatesAfterLastWindowClosed(
            menuBarShown: Prefs.showsMenuBarIcon)
    }

    /// Clic sur l'icône du Dock, ou « Ouvrir » depuis le Finder.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.show() }
        return true
    }

    /// Ce que macOS remet à l'application : un dossier lâché sur l'icône du
    /// Dock (lot DD2), un lien `fouine://` (INT-L1). La boîte aux lettres est
    /// dans `AppModel` ; l'`App` remet ici le geste qui l'y dépose, comme pour
    /// `launch` — le délégué n'a accès à aucun modèle.
    @MainActor static var receiveURLs: (@MainActor @Sendable ([URL]) -> Void)?

    /// TOUTES les URL passent par là dès que cette méthode existe : en
    /// l'implémentant, on prend la place du gestionnaire que SwiftUI installe
    /// lui-même, et `.onOpenURL` peut ne plus rien recevoir. Les liens
    /// `fouine://` sont donc remis à la MÊME boîte que les dossiers, et c'est
    /// la vue qui trie — sans quoi déclarer les dossiers aurait cassé les liens
    /// de citation. `.onOpenURL` reste branché de son côté : si c'est lui qui
    /// tire, la garde anti-doublon écarte la seconde livraison.
    func application(_ application: NSApplication, open urls: [URL]) {
        // La fenêtre d'abord : sans elle, personne ne relève la boîte — et un
        // dépôt sur le Dock veut de toute façon dire « montre-toi ».
        MainWindow.show()
        Task { @MainActor in Self.receiveURLs?(urls) }
    }

    /// Le hot key Carbon est enregistré auprès du système : on le rend, avec son
    /// gestionnaire d'événements, au lieu de le laisser fuir (audit A10.10).
    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKey.unregister()
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
    }

    /// L'icône du Dock suit la dernière fenêtre fermée.
    ///
    /// `willClose` et non `didClose` : la notification part AVANT la
    /// disparition, la fenêtre qui se ferme est donc encore dans
    /// `NSApp.windows` et il faut l'écarter explicitement — sinon l'app reste
    /// à jamais `.regular`, avec une icône de Dock qui n'ouvre rien.
    private func observeWindowClosing() {
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard Prefs.showsMenuBarIcon else { return }
                NSApp.setActivationPolicy(WindowLifecyclePolicy.activationPolicy(
                    menuBarShown: true,
                    hasWindow: MainWindow.hasVisibleWindow(
                        excluding: note.object as? NSWindow)))
            }
        }
    }
}

struct FouineDesktopApp: App {
    @NSApplicationDelegateAdaptor(FouineAppDelegate.self) private var delegate

    @StateObject private var app: AppModel
    @StateObject private var search: SearchModel
    @StateObject private var preview: PreviewModel
    /// Réglages de la scène `Settings` (⌘,). Porté par l'`App` comme les autres :
    /// la fenêtre de réglages s'ouvre et se ferme, son modèle survit.
    @StateObject private var settings: SettingsModel
    /// Le menu Fichier vit HORS de la hiérarchie de vues : il n'a pas
    /// d'`@EnvironmentObject`. Il lui faut donc une référence directe au modèle
    /// de recherche, que `body` ne peut pas lui passer autrement.
    private let searchModel: SearchModel
    /// Sparkle (palier 2.9, audit D13). Construit ici et pas plus tard : il
    /// tient l'unique `SPUUpdater` du bundle, que `UpdatesSettingsView` lit et
    /// que l'élément de menu déclenche. Son initialiseur ne sort JAMAIS sur le
    /// réseau — voir l'en-tête de `Updates.swift`.
    @StateObject private var updates = UpdatesController()
    /// L'essai, la clé, l'état (lot L1C). Porté par l'`App` : la carte
    /// « Index » de la barre latérale, l'onglet des réglages et « À propos »
    /// lisent le même objet, et la revalidation mensuelle ne doit pas mourir
    /// avec une fenêtre.
    @StateObject private var license: LicenseModel
    /// Installation du modèle sémantique (audit D6). Porté par l'`App` et non
    /// par l'onglet de réglages : un transfert de 220 Mo ne doit pas mourir
    /// parce qu'on a fermé la fenêtre ⌘, — et l'état doit être retrouvé intact
    /// en la rouvrant.
    @StateObject private var modelDownload = ModelDownloadModel()
    /// Icône dans la barre des menus, ouverture à la session (UX-07, UX-09).
    /// Portée par l'`App` : la scène `MenuBarExtra` en dépend, et la fenêtre de
    /// réglages doit pouvoir la changer sans la recréer.
    @StateObject private var interface = InterfacePreferences()
    /// La mini-recherche du panneau de la barre des menus (INT-M1). Portée par
    /// l'`App`, et SÉPARÉE de `search` : taper dans la barre des menus ne doit
    /// toucher ni les filtres, ni la sélection, ni la requête de la fenêtre.
    @StateObject private var menuSearch: MenuBarSearchModel

    /// Les documents que Fouine n'a pas pu lire (UX-16). Porté par l'`App` :
    /// la fenêtre s'ouvre et se ferme, la liste déjà lue lui survit — et une
    /// réouverture ne repaie pas la lecture.
    @StateObject private var unreadable: UnreadableDocumentsModel
    /// « Tous vos documents » (lot BR1, PR-06). Porté par l'`App` pour la même
    /// raison que la fenêtre voisine : la liste déjà lue, les filtres posés et
    /// les tranches chargées survivent à la fermeture de la fenêtre.
    @StateObject private var allDocuments: AllDocumentsModel
    /// La façade de base, retenue pour les fenêtres d'aperçu détachées : chacune
    /// fabrique SON `PreviewModel` (voir `DetachedPreviewWindow`), et une scène
    /// `WindowGroup` n'a pas d'`@EnvironmentObject` où prendre le service au
    /// moment où elle construit sa vue.
    private let service: StoreService

    init() {
        let service = StoreService()
        let search = SearchModel(service: service)
        let app = AppModel(service: service)
        _app = StateObject(wrappedValue: app)
        _search = StateObject(wrappedValue: search)
        _preview = StateObject(wrappedValue: PreviewModel(service: service))
        _settings = StateObject(wrappedValue: SettingsModel(service: service))
        _unreadable = StateObject(
            wrappedValue: UnreadableDocumentsModel(service: service))
        _allDocuments = StateObject(
            wrappedValue: AllDocumentsModel(service: service))
        _menuSearch = StateObject(wrappedValue: MenuBarSearchModel(service: service))
        let license = LicenseModel()
        _license = StateObject(wrappedValue: license)
        searchModel = search
        self.service = service

        // Le démarrage part du délégué d'application (BU-02), donc AVANT toute
        // fenêtre et quel que soit le chemin de lancement. Les trois gestes
        // sont ceux qui ne dépendent pas d'une fenêtre : ouvrir l'index, lire
        // si la recherche par le sens est disponible (un `count(*)` sur la
        // base, §12), et prendre le raccourci global ⌥⌘F — dont l'intérêt est
        // justement de servir quand Fouine n'est pas devant.
        FouineAppDelegate.launch = {
            // L'ESSAI DÉMARRE ICI, avant tout le reste (lot L1C) : au premier
            // lancement, et une seule fois. Purement local — aucune connexion.
            license.start()
            await app.start()
            await search.refreshSemanticAvailability()
            // La vérification silencieuse de la clé, s'il y en a une et si elle
            // n'a pas été vue depuis 30 jours. Hors ligne, il ne se passe
            // rien du tout et on réessaiera au prochain lancement.
            await license.revalidateIfDue()
            app.globalHotKeyAvailable = GlobalHotKey.registerOptionCommandF {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .fouineFocusSearch,
                                                object: nil)
            }
        }

        // Le dossier lâché sur l'icône du Dock et le lien `fouine://` (DD2)
        // arrivent au délégué, qui n'a pas de modèle : il les dépose dans la
        // boîte aux lettres d'`AppModel`, que la fenêtre relève.
        FouineAppDelegate.receiveURLs = { urls in app.submitOpenedURLs(urls) }
    }

    /// `isInserted` est ÉCRIT par SwiftUI à chaque mise à jour de la scène,
    /// avec la valeur qu'il a déjà. Passer par `$interface.showsMenuBarIcon`
    /// déclenchait alors `objectWillChange` — un `@Published` publie AVANT de
    /// comparer —, donc une réévaluation de l'`App`, donc une nouvelle
    /// écriture : une boucle qui saturait le fil principal (fenêtre vide, 99 %
    /// de CPU, constaté le 05/09/2026 sur une copie de la base de production ;
    /// invisible sur une base vide, où chaque tour est instantané). L'écriture
    /// ne passe que si la valeur change.
    private var menuBarInserted: Binding<Bool> {
        Binding(get: { interface.showsMenuBarIcon },
                set: { wanted in
                    if wanted != interface.showsMenuBarIcon {
                        interface.showsMenuBarIcon = wanted
                    }
                })
    }

    var body: some Scene {
        // `Window` et non `WindowGroup` (audit A10.9) : Fouine est mono-fenêtre.
        // Avec un `WindowGroup`, ⌘N ouvrait une seconde fenêtre qui rejouait le
        // `.task` de démarrage — `open()`, la sonde TCC (invite système) et
        // `loadVocabulary()` (~4 s) — sur les MÊMES modèles, portés par l'`App`.
        // `Window` retire ⌘N ; `AppModel.start()` est idempotent par ailleurs.
        Window("Fouine", id: "main") {
            ContentView()
                // Liens `fouine://` (lot INT-L1). AVANT les `environmentObject`
                // ci-dessous, et c'est la seule place possible : un
                // modificateur posé APRÈS eux enveloppe la vue qui les porte,
                // et ses propres `@EnvironmentObject` lisent alors
                // l'environnement de la SCÈNE, où il n'y a pas d'`AppModel` —
                // l'application meurt au lancement sur « No ObservableObject
                // of type AppModel found » (constaté le 08/09/2026).
                .modifier(DeepLinkReceiver(service: service))
                .environmentObject(app)
                .environmentObject(search)
                .environmentObject(preview)
                // La barre latérale lit `agent.prepareMeaning` (AG1) : le même
                // objet que l'onglet Indexation, pour la même décision.
                .environmentObject(settings)
                // La carte « Index » dit où en est l'essai (lot L1C).
                .environmentObject(license)
                // 900 × 560 (audit U6) : 1080 × 620 ne tenait pas sur un 13"
                // à côté d'une autre fenêtre. Les minimums des trois colonnes
                // ont suivi (230 + 350 + 300 = 880 + deux séparateurs).
                .frame(minWidth: 900, minHeight: 560)
                // Retient l'action « ouvrir la fenêtre » pour le clic sur
                // l'icône du Dock et le menu Fenêtre, qui n'ont pas
                // d'environnement SwiftUI où la prendre (voir `MainWindow`).
                .background(MainWindowRegistrar())
                .background(SettingsWindowRegistrar())
                .task {
                    // L'index s'ouvre au LANCEMENT, pas ici (BU-02) : ce
                    // `.task` n'attend que la fin de ce démarrage-là —
                    // `start()` n'ouvre rien une seconde fois.
                    await app.start()
                    // « Reprendre où j'en étais » (R-11) : la dernière
                    // recherche VALIDÉE est rejouée, avec ses filtres et sa
                    // page. C'est le seul geste qui ait besoin de la fenêtre,
                    // et le seul qui reste ici. Après les étiquettes de
                    // racines, que `dossier:Xyz` doit pouvoir confronter. Rien
                    // à rejouer sur une installation neuve, et rien si l'index
                    // n'a pas pu s'ouvrir.
                    if app.isReady, !app.roots.isEmpty {
                        search.knownFolders = app.roots.map(\.label)
                        search.restoreLastSession()
                    }
                }
        }
        .commands {
            // Menu Aide ▸ « Guide de Fouine » (⌘?) et « À propos » avec ses
            // mentions (BU-27, BU-28). En PREMIER : le remplacement d'« À
            // propos » doit être posé avant les groupes ancrés `after: .appInfo`
            // ci-dessous, sinon ils se rangent autour de l'élément standard.
            HelpCommands()
            // Menu Fenêtre ▸ « Tous vos documents » (⌘⇧L, lot BR1). Dans une
            // structure `Commands` à part : `openWindow` ne se prend que dans
            // l'environnement des COMMANDES, et c'est le seul endroit d'où un
            // élément de menu sait faire naître une scène `Window` que SwiftUI
            // n'a pas encore construite (même raison que `HelpCommands`).
            AllDocumentsCommands()
            // Menu Fenêtre ▸ « Votre index » (IX2), même patron, SANS
            // raccourci : une fenêtre qu'on ouvre pour lire, pas un geste de
            // chaque recherche.
            IndexDetailsCommands()
            // Menu Édition ▸ « Occurrence suivante / précédente » (⌘G / ⇧⌘G,
            // PN1). Structure à part : `@FocusedValue` ne se lit que dans des
            // `Commands` ou une vue, et c'est lui qui vise la fenêtre devant.
            OccurrenceCommands()
            // Menu « Fouine », juste après « À propos » (D1/V9). L'élément
            // n'existe pas hors bundle : `swift run FouineApp` n'a pas de
            // Contents/MacOS/fouine à lier.
            CommandGroup(after: .appInfo) {
                // « Installer l'outil en ligne de commande… » a quitté ce menu
                // (UX-11) : il vit dans Réglages ▸ Avancé, avec les autres
                // choses qui ne concernent que les dépanneurs. Un menu
                // d'application se lit en entier à chaque ouverture ; ce qui
                // sert une fois dans une vie n'a rien à y faire.

                // « Désinstaller Fouine… » (D13). TOUJOURS présent, désactivé
                // hors bundle : un élément qui disparaît laisse croire que le
                // produit ne sait pas se désinstaller — c'est justement le
                // reproche de l'audit. La feuille passe par `AppModel.sheet`,
                // l'UNIQUE feuille de la fenêtre (audit A10.6).
                Button("Uninstall Fouine…") {
                    NSApp.activate(ignoringOtherApps: true)
                    app.sheet = .uninstall
                }
                .disabled(!Uninstaller.isAvailable)
                .help(Uninstaller.isAvailable
                      ? String(localized: "Turns background indexing off, deletes the index and the settings you choose, and moves Fouine to the Trash. No indexed folder is touched.")
                      : String(localized: "Only available from the installed application: “swift run FouineApp” has nothing to uninstall."))
            }
            // Menu Fichier ▸ Exporter les résultats… (audit U4). ⇧⌘E est
            // l'emplacement habituel d'un export sur macOS et n'entre en
            // conflit avec rien ici.
            CommandGroup(after: .saveItem) {
                Button("Export the results…") {
                    ResultExporter.present(searchModel)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            // « Rechercher les mises à jour… » (D13). Toujours PRÉSENT, même
            // quand Sparkle n'a pas pu démarrer : un élément qui disparaît
            // laisse croire que l'app n'a pas de mises à jour du tout. Il est
            // alors désactivé, et son `.help` dit pourquoi — sans clé de
            // signature publique, aucune vérification n'est possible.
            CommandGroup(after: .appInfo) {
                // « Enter licence key… » (lot L1C). Dans le même groupe que
                // « Rechercher les mises à jour… », et pas dans un groupe à
                // lui : `commands` n'accepte que dix enfants, et ces deux
                // éléments parlent de la même chose — l'application elle-même,
                // pas l'index. TOUJOURS présent, même une fois la clé posée :
                // c'est aussi par là qu'on la remplace.
                Button("Enter licence key…") { openLicenceSettings() }
                    .help("Opens the Licence settings, where you can enter the key you bought, or buy one.")
                Button("Check for updates…") {
                    updates.checkForUpdates()
                }
                .disabled(!updates.canCheckNow)
                .help(updates.unavailableReason
                      ?? String(localized: "Contacts the project's releases page to compare version numbers. Nothing else is sent."))
            }
            // Menu Édition ▸ « Copier la référence de cette page » (INT-L1).
            // ⇧⌘C : ⌘C reste la copie du texte sélectionné, et un raccourci de
            // copie « augmentée » se pose traditionnellement sur ⇧⌘C sur macOS.
            // Il agit sur la SÉLECTION de la liste de résultats — sans
            // sélection, il n'y a pas de page à citer.
            CommandGroup(after: .pasteboard) {
                Button("Copy the reference to this page") {
                    searchModel.copySelectionReference()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(search.selection == nil)
                .help("Copies the file name, the page number and a link that reopens Fouine on this page.")
                // « Copier toutes les références » (⌥⌘C, PR-19) : juste
                // en dessous de la référence d'une page, et sur le seul
                // raccourci de copie encore libre — ⌘C est la copie du texte,
                // ⇧⌘C la référence de la page.
                Button("Copy every reference") {
                    searchModel.copyAllReferences()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!search.canExport)
                .help("Copies one reference per result loaded, in the order shown.")
            }
            CommandGroup(after: .textEditing) {
                Button("Search in Fouine") {
                    // La fenêtre a pu être fermée (UX-08) : on la ramène avant
                    // de demander le focus, sinon le raccourci ne fait rien.
                    MainWindow.show()
                    NotificationCenter.default.post(name: .fouineFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
            }
            // Menu Fenêtre ▸ « Ouvrir Fouine » (UX-08). Le pendant, au clavier,
            // de l'entrée du menu de la barre des menus : la fenêtre fermée
            // doit pouvoir revenir sans passer par le Dock.
            CommandGroup(after: .windowArrangement) {
                Button {
                    MainWindow.show()
                } label: {
                    Text(verbatim: MenuBarText.openWindow)
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        // Barre des menus (UX-07, INT-M1, IX2, AP1). Un champ de recherche, les
        // premières pages trouvées, puis UNE ligne d'état et les deux gestes
        // (`MenuBarModel`). Ni geste sur l'index, ni progression, ni
        // interrupteur depuis IX2 : on ouvre ce panneau pour chercher, et le
        // détail de l'index a sa carte et sa fenêtre « Votre index ».
        MenuBarExtra(isInserted: menuBarInserted) {
            MenuBarSearchView()
                .environmentObject(app)
                .environmentObject(search)
                .environmentObject(menuSearch)
                // L'action qui FAIT NAÎTRE la fenêtre principale, retenue ici
                // aussi (BU-02). Le contenu de ce panneau vit dès le
                // lancement, panneau fermé compris ; la fenêtre, elle, peut
                // n'avoir jamais existé — et « Ouvrir Fouine » n'avait alors
                // aucune action à jouer, ni depuis le menu Fenêtre, ni depuis
                // le Dock.
                .background(MainWindowRegistrar())
                .background(SettingsWindowRegistrar())
        } label: {
            // Trois états (AP1, demande du propriétaire du 13/09/2026) : la
            // loupe, la flèche circulaire quand l'index travaille, le triangle
            // quand il attend un geste. IX2 l'avait figée parce que le panneau
            // qu'elle ouvre ne disait plus rien de l'index ; il porte de
            // nouveau la phrase d'état, et l'icône peut donc reparler.
            Image(systemName: MenuBarModel.symbolName(for: app.indexStatus.glyph))
                .accessibilityLabel(Text(verbatim: MenuBarText.iconLabel(app.indexStatus)))
        }
        // `.window` depuis le lot INT-M1 : un menu système ne peut porter ni
        // champ de saisie ni liste défilante. Ce qu'on y perd — la fermeture
        // automatique après un clic, le parcours au clavier d'un menu — est
        // rendu à la main par `MenuBarPanel.dismiss()`, `@FocusState` et
        // `onMoveCommand` (voir `MenuBarSearchView`).
        .menuBarExtraStyle(.window)

        // « Documents que Fouine n'a pas pu lire » (UX-16). Une `Window` et non
        // un `WindowGroup` : il n'y a qu'une liste, en ouvrir deux n'aurait
        // aucun sens. `commandsRemoved()` la retire du menu Fenêtre — on n'y
        // entre que par la fenêtre « Votre index » (le pied de la carte
        // « Index » jusqu'à IX2), là où le nombre de documents illisibles est
        // annoncé, et non par un élément de menu qui parlerait d'échecs à qui
        // n'en a aucun.
        Window("Documents Fouine could not read", id: "unreadable") {
            UnreadableDocumentsView()
                .environmentObject(app)
                .environmentObject(unreadable)
        }
        .commandsRemoved()

        // « Tous vos documents » (lot BR1, constat PR-06). Une `Window` : il n'y
        // a qu'une liste, et rouvrir la même identité ramène celle qui existe au
        // premier plan. `commandsRemoved()` retire l'élément que SwiftUI
        // ajouterait de lui-même au menu Fenêtre — `AllDocumentsCommands` en
        // pose un qui porte le raccourci ⌘⇧L, et deux entrées pour la même
        // fenêtre se liraient comme deux fenêtres.
        //
        // `search` est injecté : « Chercher dans ce document » pose la portée de
        // la fenêtre principale, ce que le modèle de recherche seul sait faire.
        Window("All your documents", id: "allDocuments") {
            AllDocumentsView()
                .environmentObject(app)
                .environmentObject(search)
                .environmentObject(allDocuments)
        }
        .defaultSize(width: 760, height: 560)
        .commandsRemoved()

        // « Votre index » (IX2, demande du propriétaire du 12/09/2026) : tout
        // ce que la carte « Index » ne dit plus. Une `Window` — il n'y a qu'un
        // index —, et `commandsRemoved()` pour la même raison que la fenêtre
        // voisine : `IndexDetailsCommands` pose son propre élément au menu
        // Fenêtre, deux entrées se liraient comme deux fenêtres.
        Window("Your index", id: IndexDetailsCommands.windowID) {
            IndexDetailsView()
                .environmentObject(app)
        }
        .defaultSize(width: 480, height: 600)
        .commandsRemoved()

        // « Guide de Fouine » (BU-27). La scène vit dans GuideWindow.swift ;
        // une scène ne peut se déclarer QUE dans le corps de l'`App`, c'est
        // donc la seule ligne que le guide ajoute ici.
        GuideWindowScene()

        // Aperçu détaché (UX-17) : double-clic sur un résultat. `WindowGroup`
        // AVEC valeur — plusieurs pages peuvent être ouvertes côte à côte, et
        // SwiftUI ramène au premier plan la fenêtre qui porte déjà la même clé
        // au lieu d'en ouvrir une seconde.
        WindowGroup(id: "preview", for: HitKey.self) { $key in
            DetachedPreviewWindow(key: key, service: service)
                .environmentObject(app)
                .environmentObject(search)
        }
        .commandsRemoved()

        // Fenêtre de réglages ⌘, (audit U2). La scène `Settings` installe
        // elle-même l'élément « Réglages… » dans le menu de l'app et son
        // raccourci : il n'y a rien à câbler, et c'est pour cela qu'un
        // utilisateur de macOS la cherche là et nulle part ailleurs.
        //
        // Les mêmes modèles que la fenêtre principale, portés par l'`App` :
        // épingler une racine ici doit se voir dans la barre latérale sans
        // rechargement, et l'onglet « Sémantique » pilote l'interrupteur réel.
        Settings {
            SettingsView()
                .environmentObject(app)
                .environmentObject(search)
                .environmentObject(settings)
                .environmentObject(modelDownload)
                .environmentObject(interface)
                // Sparkle a son onglet dans la MÊME fenêtre (palier 2.9) : deux
                // fenêtres de réglages sur macOS, il n'y en a jamais qu'une.
                .environmentObject(updates)
                .environmentObject(license)
        }
    }
}

/// Menu Édition ▸ « Occurrence suivante / précédente » (PN1).
///
/// LES MÊMES RACCOURCIS QUE LES CHEVRONS DE L'EN-TÊTE, et les mêmes gestes :
/// que la touche soit prise par le menu ou par le bouton, c'est l'aperçu de la
/// fenêtre devant qui avance. Grisé hors PDF, et sur une page sans mot trouvé.
private struct OccurrenceCommands: Commands {
    @FocusedValue(\.occurrenceNavigation) private var navigation

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Next occurrence") {
                navigation?.preview.nextOccurrence()
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(navigation?.available != true)
            Button("Previous occurrence") {
                navigation?.preview.previousOccurrence()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(navigation?.available != true)
        }
    }
}

/// Retient l'action SwiftUI qui ouvre la fenêtre principale.
///
/// Une vue de zéro point, posée en arrière-plan de `ContentView` : c'est le
/// seul moyen d'obtenir `openWindow` dans un VRAI contexte de vue et de le
/// donner au délégué d'application, qui n'en a pas (voir `MainWindow.show`).
private struct MainWindowRegistrar: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { MainWindow.register(openWindow) }
    }
}

/// Retient l'action SwiftUI qui ouvre la fenêtre de réglages (voir
/// `openSettings(on:)`). Même patron que `MainWindowRegistrar`, posé aux deux
/// mêmes endroits : le panneau de la barre des menus vit dès le lancement, la
/// fenêtre principale peut n'avoir jamais existé. Rien à retenir sous
/// macOS 13, où l'action n'existe pas.
private struct SettingsWindowRegistrar: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            Registrar()
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    @available(macOS 14.0, *)
    private struct Registrar: View {
        @Environment(\.openSettings) private var openSettings

        var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                // L'action est LUE ICI, pendant que la vue est installée : un
                // `@Environment` lu plus tard, depuis la fermeture, rendrait la
                // valeur par défaut.
                .onAppear {
                    let action = openSettings
                    SettingsWindow.register { action() }
                }
        }
    }
}

/// Reçoit les liens `fouine://` et applique la décision de `DeepLinkRouter`
/// (lot INT-L1).
///
/// UN MODIFICATEUR, ET PAS DU CODE DANS LA SCÈNE : `openWindow` n'existe que
/// dans un contexte de vue, et c'est lui qui ouvre la fenêtre d'aperçu — la
/// MÊME que le double-clic sur un résultat, avec la même `HitKey`. Le lien
/// n'emprunte donc aucun chemin à lui : tout ce qui sait charger une page est
/// déjà là (`DetachedPreviewWindow`).
///
/// La DÉCISION est ailleurs et pure (`DeepLinkRouter`) ; il ne reste ici que
/// les gestes, qui ne se testent pas.
private struct DeepLinkReceiver: ViewModifier {
    /// Les journaux s'adressent aux dépanneurs : anglais, comme le reste.
    private static let log = Logger(subsystem: "io.github.basedpolymer.fouine",
                                    category: "deeplink")

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var search: SearchModel
    @Environment(\.openWindow) private var openWindow

    let service: StoreService

    func body(content: Content) -> some View {
        content
            // La MÊME boîte aux lettres que le délégué (lot DD2) : lequel des
            // deux chemins tire dépend du système, et la garde anti-doublon
            // d'`AppModel` écarte la seconde livraison du même geste.
            .onOpenURL { url in app.submitOpenedURLs([url]) }
            // Relever la boîte : à l'arrivée d'une URL, et à l'apparition de la
            // vue — un dépôt reçu fenêtre fermée (barre des menus, UX-08)
            // attend que la fenêtre revienne.
            .onChange(of: app.openedURLs) { _ in drainOpenedURLs() }
            .onAppear { drainOpenedURLs() }
            // Un résultat Spotlight cliqué (lot INT-S1). Il arrive par une
            // `NSUserActivity` et non par une URL, mais tout le reste est
            // commun : `SpotlightItemBuilder.link` en fait un `DeepLink`, et
            // la file d'attente « base pas encore ouverte » d'INT-L1 le
            // reprend telle quelle — macOS remet l'activité au lancement,
            // c'est-à-dire souvent avant que l'index soit ouvert.
            //
            // Ce modificateur est posé ICI, sur la vue de la fenêtre
            // principale et avec les `onOpenURL`, et surtout PAS sur la scène
            // de la barre des menus : un panneau qui n'est pas à l'écran ne
            // reçoit rien, et un modificateur posé après les
            // `.environmentObject` lit l'environnement de la scène et tue
            // l'application au lancement (pièges connus, 08/09/2026).
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                let info = activity.userInfo
                guard let link = SpotlightItemBuilder.link(
                    identifier: info?[CSSearchableItemActivityIdentifier] as? String,
                    query: info?[CSSearchQueryString] as? String)
                else {
                    Self.log.error("Spotlight handed over an unknown item")
                    return
                }
                if let now = app.submitDeepLink(link.url) { handle(now) }
            }
            // L'index vient de s'ouvrir : ce qui attendait se rejoue.
            .onChange(of: app.isReady) { ready in
                guard ready else { return }
                drainOpenedURLs()
                if let waiting = app.resumeDeepLink() { handle(waiting) }
            }
    }

    /// Ce que macOS a remis, trié : un fichier au dépôt sur le Dock (DD2), tout
    /// le reste au lien `fouine://`. La boîte ne rend rien tant que l'index
    /// n'est pas ouvert.
    private func drainOpenedURLs() {
        for url in app.takeOpenedURLs() {
            if url.isFileURL {
                openDroppedFolder(url)
            } else if let now = app.submitDeepLink(url) {
                handle(now)
            }
        }
    }

    /// Un dossier lâché sur l'icône du Dock (lot DD2).
    ///
    /// Le filtre est POSÉ, pas lancé : ce qu'on cherche dans ce dossier, seule
    /// la personne le sait, et une recherche vide n'aurait rien à montrer. Le
    /// champ prend donc le focus avec le filtre et son espace finale, prêt à
    /// recevoir la suite.
    private func openDroppedFolder(_ url: URL) {
        switch app.handleOpenedFolder(url: url) {
        case .search(let label):
            MainWindow.show(openWindow)
            search.text = FolderDropDecision.searchText(label: label)
            NotificationCenter.default.post(name: .fouineFocusSearch, object: nil)
            placeCursorAtEndOfSearchField()
        case .proposeAdd:
            // L'alerte est portée par la fenêtre principale (`ContentView`) :
            // il n'y a qu'à la faire venir devant.
            MainWindow.show(openWindow)
        case .ignore:
            // Un FICHIER déposé ne fait rien, et le dit seulement au journal :
            // Fouine n'ouvre pas les documents, et une alerte pour expliquer
            // qu'il ne s'est rien passé serait pire que le silence.
            Self.log.info("dropped item is not a folder — ignored")
        }
    }

    /// LE CURSEUR DERRIÈRE LE FILTRE, PAS SUR LUI. Un champ AppKit qui devient
    /// premier répondant SÉLECTIONNE tout son contenu : le filtre qu'on vient
    /// de poser aurait disparu au premier caractère tapé, ce qui est
    /// exactement le contraire du service rendu. La sélection est donc repliée
    /// sur la fin — après le tour de boucle où le focus s'applique, sinon elle
    /// serait posée avant lui et écrasée.
    private func placeCursorAtEndOfSearchField() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let editor = NSApp.keyWindow?
                .fieldEditor(false, for: nil) as? NSTextView else { return }
            let end = (editor.string as NSString).length
            editor.setSelectedRange(NSRange(location: end, length: 0))
        }
    }

    private func handle(_ url: URL) {
        guard let link = DeepLink(url: url) else {
            // Le journal, pas l'interface : un lien malformé vient d'un
            // programme, pas d'un geste, et il n'y a rien à faire faire à
            // qui que ce soit.
            Self.log.error("received a malformed fouine:// link")
            return
        }
        Task { @MainActor in
            let action = await resolve(link)
            apply(action, link: link)
        }
    }

    /// La seule partie qui touche la base : retrouver le document désigné, et
    /// son nombre de pages.
    private func resolve(_ link: DeepLink) async -> DeepLinkAction {
        var found: Int64?
        // `docs.n_pages` du document trouvé : c'est lui qui borne la page d'un
        // lien ancien (BU-18). Le routeur, lui, reste pur et ne lit rien.
        var pageCount: Int?
        if case .open(let target, _, _, _) = link {
            switch target {
            case .path(let path):
                found = try? await service.docID(forAbsolutePath: path)
            case .doc(let id):
                // Un identifiant qui ne désigne plus rien (index reconstruit)
                // doit sortir en « document inconnu », pas en aperçu vide.
                found = ((try? await service.docRow(id: id)) ?? nil).map(\.id)
            }
            if let found {
                pageCount = ((try? await service.docRow(id: found)) ?? nil)?
                    .record.nPages
            }
        }
        // LES RACINES SUIVIES SONT UNE PARTIE DE LA DÉCISION (BU-01) : sans
        // elles, « Ouvrir le fichier » ouvrait n'importe quel chemin choisi par
        // l'auteur du lien. Elles se lisent ici, où le modèle existe ; le
        // routeur, lui, reste pur.
        let roots = app.roots.compactMap(\.absolutePath)
        return DeepLinkRouter.action(
            for: link, resolve: { _ in found },
            probe: { DeepLinkRouter.probeFileSystem($0) },
            roots: roots,
            pages: { _ in pageCount })
    }

    private func apply(_ action: DeepLinkAction, link: DeepLink) {
        switch action {
        case .showPage(let key, let missing, let time):
            show(key, query: query(of: link), missingPage: missing, time: time)
        case .showDocument(let docID):
            // Pas de page dans le lien : la première, comme le ferait une
            // ouverture ordinaire du document.
            show(HitKey(docID: docID, page: 1), query: query(of: link))
        case .search(let text):
            MainWindow.show(openWindow)
            search.text = text
            search.submit()
        case .unknownDocument(let path, let canOpen):
            MainWindow.show(openWindow)
            app.sheet = .unknownDocument(path: path, canOpen: canOpen)
        case .invalid:
            Self.log.error("fouine:// link refused")
        }
    }

    /// Ouvre l'aperçu détaché sur la page, et — si le lien portait une requête
    /// — la rejoue DANS ce document : c'est ce qui repose les surlignages sur
    /// les mots de la citation.
    private func show(_ key: HitKey, query: String?, missingPage: Int? = nil,
                      time: Int? = nil) {
        MainWindow.show(openWindow)
        // UNE FENÊTRE PAR DOCUMENT, TROIS AU PLUS (BU-19) : trois liens vers
        // le même PDF de 400 pages ouvraient trois fenêtres et faisaient
        // passer l'application de 55 à 793 Mo.
        let notice = missingPage.map {
            String(localized: "Page \($0) no longer exists in this document.")
        }
        PreviewWindowsModel.shared.open(key, notice: notice, time: time,
                                        using: openWindow)
        guard let query, !query.isEmpty else { return }
        Task { @MainActor in
            let name = ((try? await service.docRow(id: key.docID)) ?? nil)
                .map { DocumentDisplay.name($0.record.relPath) } ?? ""
            search.text = query
            search.scope = .document(id: key.docID, name: name)
            search.submit()
        }
    }

    private func query(of link: DeepLink) -> String? {
        if case .open(_, _, let query, _) = link { return query }
        return nil
    }
}
