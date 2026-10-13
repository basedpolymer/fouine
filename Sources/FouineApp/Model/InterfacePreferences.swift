// InterfacePreferences.swift — les deux réglages qui décident de la PRÉSENCE de
// Fouine sur le Mac (UX-07, UX-09). Propriété : A-App.
//
//   · « Garder Fouine dans la barre des menus » : une préférence d'interface
//     pure, donc `UserDefaults` et non la table `settings` — l'agent n'a rien
//     à en faire (SettingsModel.swift, « ce qui va où »).
//   · « Ouvrir Fouine à l'ouverture de session » : là, il n'y a PAS de
//     préférence à nous. La vérité est l'enregistrement `SMAppService.mainApp`,
//     que macOS peut défaire tout seul (l'utilisateur décoche la case dans
//     Réglages Système). On la relit à chaque affichage, exactement comme
//     `AppModel.refreshAgentStatus` le fait pour la mise à jour automatique :
//     une préférence parallèle n'aurait pu que mentir.

import Foundation
import SwiftUI
import ServiceManagement

@MainActor
final class InterfacePreferences: ObservableObject {

    /// L'icône dans la barre des menus. Allumée par défaut : c'est elle qui
    /// permet à la fenêtre de se fermer sans que Fouine disparaisse, et c'est
    /// le seul endroit où l'on voit l'index travailler sans ouvrir l'app.
    @Published var showsMenuBarIcon: Bool {
        didSet {
            guard showsMenuBarIcon != oldValue else { return }
            Prefs.showsMenuBarIcon = showsMenuBarIcon
            // Éteindre l'icône alors que l'app tourne sans fenêtre visible la
            // rendrait invisible et inarrêtable : on rend l'icône du Dock.
            if !showsMenuBarIcon { NSApp.setActivationPolicy(.regular) }
        }
    }

    /// « Chercher pendant que je tape » (AP1, demande du propriétaire du
    /// 13/09/2026). Allumé par défaut : c'est ce que Fouine fait depuis
    /// toujours. Éteint, la frappe ne propose plus que des mots et c'est ⏎ qui
    /// cherche — ce que demande qui tape lentement, ou dont l'attention est
    /// hachée par une liste qui se refait à chaque quart de seconde.
    ///
    /// Comme l'icône, c'est une préférence d'INTERFACE (`UserDefaults`) : ni
    /// l'agent ni l'index n'en savent rien. Les deux modèles de recherche la
    /// relisent au moment où l'on tape, ils ne la retiennent pas — le réglage
    /// se change dans une autre fenêtre et doit valoir dès la touche suivante.
    @Published var searchesAsYouType: Bool {
        didSet {
            guard searchesAsYouType != oldValue else { return }
            Prefs.searchesAsYouType = searchesAsYouType
        }
    }

    /// Fouine s'ouvre-t-elle à l'ouverture de session ? Relu, jamais deviné.
    @Published private(set) var opensAtLogin = false

    /// Ce qu'il s'est passé au dernier geste, s'il y a quelque chose à en dire.
    @Published var loginNotice: String?

    /// D'où vient l'état d'ouverture à la session.
    ///
    /// UNE FERMETURE, ET JAMAIS SUR LE FIL PRINCIPAL (PI-03, même mesure que
    /// BU-03 pour l'agent, `AppModel.readServiceStatus`) :
    /// `SMAppService.mainApp.status` est un aller-retour XPC SYNCHRONE vers
    /// `smd`, et il était joué ici depuis `init()`, c'est-à-dire depuis
    /// `FouineDesktopApp.init()` — avant toute fenêtre. Sur une machine où
    /// `smd` traîne (un enregistrement `launchd` orphelin suffit : plus de
    /// 100 s mesurées), le lancement se figeait entièrement muet, sans fenêtre
    /// ni icône. Le test y branche un faux qui note son fil.
    let readMainAppStatus: @Sendable () -> SMAppService.Status

    /// Hors bundle (`swift run FouineApp`), il n'y a pas d'application à
    /// enregistrer : la case est présente mais désactivée, et son aide dit
    /// pourquoi — la faire disparaître laisserait croire que Fouine ne sait pas
    /// s'ouvrir toute seule.
    ///
    /// Décidé une fois, à la naissance : un bundle n'apparaît pas en cours de
    /// route, et les vues le lisent à chaque rendu.
    let canOpenAtLogin: Bool

    init(canOpenAtLogin: Bool = Uninstaller.bundleToTrash() != nil,
         readMainAppStatus: @escaping @Sendable () -> SMAppService.Status
            = { SMAppService.mainApp.status }) {
        self.canOpenAtLogin = canOpenAtLogin
        self.readMainAppStatus = readMainAppStatus
        showsMenuBarIcon = Prefs.showsMenuBarIcon
        searchesAsYouType = Prefs.searchesAsYouType
        // La DERNIÈRE VALEUR CONNUE en attendant la réponse de `smd` : partir
        // de « non » faisait basculer l'interrupteur sous les yeux de
        // l'utilisateur, et disait faux tant que la lecture n'avait pas
        // répondu. Ce n'est pas une préférence parallèle — elle n'est jamais
        // consultée pour décider quoi que ce soit, seulement affichée, et la
        // lecture qui suit la corrige.
        opensAtLogin = canOpenAtLogin && Prefs.lastKnownOpensAtLogin
        Task { await refreshLoginItem() }
    }

    var openAtLoginHelp: String {
        canOpenAtLogin
            ? String(localized: "Fouine starts with your session and stays in the menu bar, without opening a window.")
            : String(localized: "Only available from the installed application: “swift run FouineApp” cannot register itself.")
    }

    /// La lecture, hors du fil principal.
    private func mainAppStatus() async -> SMAppService.Status {
        let read = readMainAppStatus
        return await Task.detached(priority: .utility) { read() }.value
    }

    func refreshLoginItem() async {
        guard canOpenAtLogin else {
            opensAtLogin = false
            return
        }
        switch await mainAppStatus() {
        case .enabled, .requiresApproval:
            opensAtLogin = true
        default:
            opensAtLogin = false
        }
        Prefs.lastKnownOpensAtLogin = opensAtLogin
    }

    func setOpensAtLogin(_ wanted: Bool) {
        loginNotice = nil
        guard canOpenAtLogin else { return }
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            opensAtLogin = wanted
            Prefs.lastKnownOpensAtLogin = wanted
            // Le geste est FAIT : la case n'attend pas que `smd` dise si macOS
            // réclame en plus une confirmation (PI-03). La phrase arrive quand
            // la réponse arrive, et le geste reste instantané.
            if wanted {
                Task { [weak self] in
                    guard let self, await self.mainAppStatus() == .requiresApproval,
                          self.loginNotice == nil else { return }
                    self.loginNotice = String(localized: "macOS is asking you to confirm this in System Settings ▸ General ▸ Login Items & Extensions.")
                }
            }
        } catch {
            // On ne fait PAS mentir la case : on la remet où le système la
            // laisse, et on dit la cause à la fin, entre parenthèses.
            loginNotice = String(localized: "Fouine could not change this setting (\((error as NSError).localizedDescription)).")
            Task { await refreshLoginItem() }
        }
    }
}
