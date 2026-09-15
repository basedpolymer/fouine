// WindowLifecycle.swift — que devient Fouine quand on ferme sa fenêtre ?
// (session UX du 04/09/2026, UX-08/UX-09). Propriété : A-App.
//
// Pourquoi. Jusqu'ici, fermer la fenêtre TUAIT l'application : la mise à jour
// automatique continuait bien (c'est l'agent launchd qui la porte), mais plus
// rien ne le disait, et rouvrir Fouine demandait de retrouver l'icône dans le
// dossier Applications. Avec l'icône de la barre des menus (UX-07), l'usage
// macOS est l'inverse : la fenêtre se ferme, l'app reste, son icône du Dock
// s'efface, et « Ouvrir Fouine » ramène la fenêtre.
//
// La DÉCISION est ici, pure et testée (`WindowLifecycleTests`) ; les gestes
// AppKit qui l'appliquent sont dans `FouineDesktopApp.swift` et dans
// `MainWindow` ci-dessous. Une politique qui se lit en trois lignes vaut mieux
// qu'une poignée de `if` semés dans le délégué d'application.

import AppKit
import SwiftUI

/// Les trois questions que le délégué d'application pose, et leurs réponses.
enum WindowLifecyclePolicy {

    /// Fermer la dernière fenêtre doit-il quitter Fouine ?
    ///
    /// Non quand l'icône de la barre des menus est là : elle serait le seul
    /// vestige d'une application morte. Oui sinon — c'est le comportement
    /// d'avant, et une app sans aucune trace visible qui reste en mémoire est
    /// exactement ce qu'un utilisateur ne pardonne pas.
    static func terminatesAfterLastWindowClosed(menuBarShown: Bool) -> Bool {
        !menuBarShown
    }

    /// Faut-il une icône dans le Dock ?
    ///
    /// `.accessory` (pas d'icône, pas de barre de menus de l'app) dès que la
    /// dernière fenêtre est fermée et que l'icône de la barre des menus prend
    /// le relais ; `.regular` dans tous les autres cas.
    static func activationPolicy(menuBarShown: Bool,
                                 hasWindow: Bool) -> NSApplication.ActivationPolicy {
        (menuBarShown && !hasWindow) ? .accessory : .regular
    }

    /// Ouverte par le système à l'ouverture de session, faut-il montrer la
    /// fenêtre ? Non : l'utilisateur n'a rien demandé, il a réglé « ouvrir
    /// Fouine à l'ouverture de session » pour que l'index soit tenu à jour, pas
    /// pour qu'une fenêtre lui saute au visage à chaque démarrage.
    static func startsWithoutWindow(menuBarShown: Bool,
                                    launchedBySystem: Bool) -> Bool {
        menuBarShown && launchedBySystem
    }

    /// Par quel chemin montrer la fenêtre principale ?
    ///
    /// Deux moyens, et aucun ne couvre tous les cas : l'action SwiftUI
    /// `openWindow(id:)` sait FAIRE NAÎTRE la scène, mais elle n'existe que si
    /// une vue l'a retenue ; la `NSWindow` que SwiftUI garde en réserve, elle,
    /// n'existe que si la fenêtre est apparue au moins une fois.
    ///
    /// `.nothing` est le défaut BU-02 : sans fenêtre jamais ouverte et sans
    /// action retenue, « Fenêtre ▸ Ouvrir Fouine » et le clic sur l'icône du
    /// Dock ne faisaient RIEN. C'est pour cela que le panneau de la barre des
    /// menus — qui, lui, vit dès le lancement — retient l'action à son tour.
    enum ShowWindowRoute: Equatable {
        case openScene
        case orderFrontExisting
        case nothing
    }

    static func showWindowRoute(hasOpener: Bool, hasWindow: Bool) -> ShowWindowRoute {
        if hasOpener { return .openScene }
        return hasWindow ? .orderFrontExisting : .nothing
    }

    /// Lancement par le système (élément d'ouverture de session) ou par un
    /// humain ?
    ///
    /// macOS pose `NSApplicationLaunchIsDefaultLaunchKey` à `false` dans le
    /// `userInfo` de `applicationDidFinishLaunching` quand le lancement vient
    /// d'un élément d'ouverture de session. La clé est ABSENTE sur les vieilles
    /// versions et hors bundle : absence = lancement humain, le cas le moins
    /// surprenant (une fenêtre s'ouvre).
    static func launchedBySystem(_ userInfo: [AnyHashable: Any]?) -> Bool {
        guard let isDefault = userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool
        else { return false }
        return isDefault == false
    }
}

/// Retrouver, montrer ou masquer la fenêtre principale.
///
/// Deux chemins, et c'est voulu. Depuis une VUE (le menu de la barre des menus,
/// les commandes du menu Fenêtre), l'action SwiftUI `openWindow(id:)` est la
/// bonne : c'est elle qui sait recréer la scène `Window` si SwiftUI l'a
/// libérée. Depuis le DÉLÉGUÉ d'application (clic sur l'icône du Dock), il n'y
/// a pas d'environnement SwiftUI : on retrouve alors la `NSWindow` — elle
/// existe toujours, une scène `Window` fermée n'est qu'une fenêtre ordonnée
/// hors écran.
@MainActor
enum MainWindow {

    /// L'identifiant de la scène `Window` de `FouineDesktopApp`.
    static let id = "main"

    /// L'identifiant que SwiftUI donne à la fenêtre de réglages ⌘, : elle
    /// compte comme une fenêtre ouverte (on ne repasse pas en `.accessory`
    /// tant qu'elle est là), mais « Ouvrir Fouine » ne doit jamais la ramener
    /// à la place de la fenêtre principale.
    private static let settingsWindowIdentifier = "com_apple_SwiftUI_Settings_window"

    /// L'action SwiftUI, retenue à la première apparition de la fenêtre : le
    /// délégué d'application et les commandes de menu n'ont pas
    /// d'environnement SwiftUI où la prendre.
    private static var opener: OpenWindowAction?

    static func register(_ open: OpenWindowAction) { opener = open }

    /// Montre la fenêtre principale et rend l'icône du Dock.
    ///
    /// D'abord l'action SwiftUI (elle sait recréer la scène), puis, au tour de
    /// boucle suivant et seulement si rien n'est apparu, la `NSWindow` fermée
    /// que SwiftUI garde en réserve. Les deux chemins sont là parce qu'aucun
    /// des deux ne couvre tous les cas : l'action n'existe pas tant que la
    /// fenêtre n'est jamais apparue, la `NSWindow` n'existe plus si SwiftUI l'a
    /// libérée.
    @discardableResult
    static func show(_ open: OpenWindowAction? = nil) -> WindowLifecyclePolicy.ShowWindowRoute {
        NSApp.setActivationPolicy(.regular)
        let action = open ?? opener
        let route = WindowLifecyclePolicy.showWindowRoute(
            hasOpener: action != nil,
            hasWindow: !documentWindows().isEmpty)
        switch route {
        case .openScene:
            action?(id: id)
            Task { @MainActor in
                if !documentWindows().contains(where: { $0.isVisible }) { restore() }
            }
        case .orderFrontExisting:
            restore()
        case .nothing:
            break
        }
        NSApp.activate(ignoringOtherApps: true)
        return route
    }

    /// Ferme la fenêtre principale et retire l'icône du Dock (ouverture de
    /// session). `close()` et non `orderOut` : c'est ce que fait le bouton
    /// rouge, et c'est ce que la scène `Window` sait rouvrir.
    static func hideForLoginLaunch() {
        for window in documentWindows() { window.close() }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Reste-t-il une fenêtre visible (la fenêtre de réglages comprise) ?
    static func hasVisibleWindow(excluding closing: NSWindow? = nil) -> Bool {
        NSApp.windows.contains {
            $0 !== closing && $0.isVisible && $0.canBecomeMain
        }
    }

    private static func restore() {
        let candidates = documentWindows()
        let window = candidates.first { $0.identifier?.rawValue == id }
            ?? candidates.first
        window?.makeKeyAndOrderFront(nil)
    }

    /// Les fenêtres « de contenu » : ni les panneaux (menus, palettes), ni la
    /// fenêtre de réglages.
    private static func documentWindows() -> [NSWindow] {
        NSApp.windows.filter {
            $0.canBecomeMain && !($0 is NSPanel)
                && $0.identifier?.rawValue != settingsWindowIdentifier
        }
    }
}
