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

    init() {
        showsMenuBarIcon = Prefs.showsMenuBarIcon
        searchesAsYouType = Prefs.searchesAsYouType
        refreshLoginItem()
    }

    /// Hors bundle (`swift run FouineApp`), il n'y a pas d'application à
    /// enregistrer : la case est présente mais désactivée, et son aide dit
    /// pourquoi — la faire disparaître laisserait croire que Fouine ne sait pas
    /// s'ouvrir toute seule.
    var canOpenAtLogin: Bool { Uninstaller.bundleToTrash() != nil }

    var openAtLoginHelp: String {
        canOpenAtLogin
            ? String(localized: "Fouine starts with your session and stays in the menu bar, without opening a window.")
            : String(localized: "Only available from the installed application: “swift run FouineApp” cannot register itself.")
    }

    func refreshLoginItem() {
        guard canOpenAtLogin else {
            opensAtLogin = false
            return
        }
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            opensAtLogin = true
        default:
            opensAtLogin = false
        }
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
            if wanted, SMAppService.mainApp.status == .requiresApproval {
                loginNotice = String(localized: "macOS is asking you to confirm this in System Settings ▸ General ▸ Login Items & Extensions.")
            }
        } catch {
            // On ne fait PAS mentir la case : on la remet où le système la
            // laisse, et on dit la cause à la fin, entre parenthèses.
            refreshLoginItem()
            loginNotice = String(localized: "Fouine could not change this setting (\((error as NSError).localizedDescription)).")
        }
    }
}
