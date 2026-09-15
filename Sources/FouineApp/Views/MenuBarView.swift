// MenuBarView.swift — le pied du panneau de la barre des menus (UX-07, INT-M1,
// IX2, AP1). Propriété : A-App.
//
// Une ligne d'état et deux gestes : « Ouvrir Fouine » et « Quitter Fouine ».
// La ligne d'état est revenue le 13/09/2026 (AP1) parce que l'icône change de
// nouveau selon ce que fait l'index : elle est ce qui l'explique. UNE seule —
// ni détail, ni progression, ni bouton. `MenuBarModel` décide (testé), ce
// fichier rend.
//
// LE RENDU EST CELUI D'UN PANNEAU, PAS D'UN MENU (INT-M1). La scène est en
// `.menuBarExtraStyle(.window)` pour porter la mini-recherche : les gestes sont
// des boutons pleine largeur, et macOS n'y dessine pas les glyphes des
// raccourcis — ⌘0 et ⌘Q marchent sans s'afficher.

import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject private var app: AppModel
    /// L'action SwiftUI qui rouvre la scène `Window` : depuis une vue, c'est
    /// elle qui sait la recréer (voir `MainWindow`).
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Toujours pas de relecture de l'état à l'ouverture : `app.indexStatus`
        // est publié et rafraîchi par `AppModel`, et le `.onAppear` d'avant IX2
        // ne tournait qu'une fois, au lancement, sur un panneau encore
        // invisible (pièges connus).
        VStack(alignment: .leading, spacing: 0) {
            ForEach(MenuBarModel.items(status: app.indexStatus), id: \.identifier) { item in
                row(item)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func row(_ item: MenuBarItem) -> some View {
        switch item {
        case .status(let text):
            // Grisée et sans geste : on la LIT. Le même alignement et les mêmes
            // marges que les deux boutons, pour que la colonne reste droite.
            Text(verbatim: text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        case .openWindow:
            button(MenuBarText.openWindow) { MainWindow.show(openWindow) }
                .keyboardShortcut("0", modifiers: .command)
        case .quit:
            // L'aide n'est posée que si elle est vraie (`MenuBarModel.quitHelp`).
            if let help = MenuBarModel.quitHelp(automatic: app.backgroundIndexing) {
                quitButton.help(Text(verbatim: help))
            } else {
                quitButton
            }
        }
    }

    private var quitButton: some View {
        button(MenuBarText.quit) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Un geste : toute la largeur est cliquable, comme une ligne de menu.
    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
