// HelpMenu.swift — le menu Aide et « À propos » (BU-27, BU-28, PR-13).
// Propriété : A-App.
//
// Le menu Aide de macOS, laissé au système, contient « Aide Fouine » — et cet
// élément ouvre une alerte : « Aucune aide n'est disponible pour Fouine. »
// C'est le PREMIER endroit où va quelqu'un qui ne s'en sort pas, dans un
// produit fait pour des gens peu à l'aise avec l'informatique. On y met donc
// le guide, qui existe déjà et qui est bon (`docs/app.md`), plutôt que de
// retirer le menu.
//
// ⌘? reste sur ce bouton : c'est le raccourci d'aide de macOS, et il ne doit
// pas mener ailleurs que dans l'aide.

import SwiftUI
import AppKit

struct HelpCommands: Commands {

    /// `openWindow` est PRIS DANS L'ENVIRONNEMENT DES COMMANDES : c'est le seul
    /// endroit d'où un élément de menu sait faire naître une scène `Window`
    /// que SwiftUI n'a pas encore construite (voir `MainWindow`).
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Fouine Guide") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: GuideWindowScene.id)
            }
            .keyboardShortcut("?", modifiers: .command)
            .help("Opens the Fouine guide: the window, the index, the settings and the keyboard shortcuts.")
        }

        // « À propos » remplacé (BU-28) : le panneau standard nommait la licence
        // sans donner accès à quoi que ce soit. Le nôtre est le même panneau,
        // avec ses mentions — licence, composants tiers, code source.
        CommandGroup(replacing: .appInfo) {
            Button("About Fouine") {
                AboutCredits.show()
            }
        }
    }
}
