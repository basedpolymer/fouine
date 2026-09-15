// QuickLook.swift — Espace sur un résultat ouvre le Coup d'œil (PR-16).
// Propriété : A-App.
//
// POURQUOI CE FICHIER EXISTE. Presser Espace sur un fichier désigné est un
// geste que tout utilisateur de Mac fait sans y penser — le Finder, Mail,
// Photos, et toutes les applications de recherche concurrentes le servent.
// Fouine ne le servait pas : `grep -n 'quickLook\|QLPreview'` ne rendait rien.
//
// CE QUE COÛTE LE COUP D'ŒIL EN APPKIT. `QLPreviewPanel` n'a ni source ni
// délégué à lui : il les DEMANDE à la chaîne des répondeurs, au premier objet
// qui répond « oui » à `acceptsPreviewPanelControl`. SwiftUI n'expose rien de
// tel. D'où la vue de zéro point posée en arrière-plan de la liste : elle
// existe pour être ce répondeur-là, et pour rien d'autre.
//
// ELLE REND LE FOCUS. Prendre le premier répondeur pour montrer le panneau et
// le garder à la fermeture, ce serait casser les flèches ↑↓ de la liste juste
// après un Coup d'œil. Le répondeur précédent est donc retenu et rendu à la
// fin du contrôle du panneau.

import SwiftUI
import AppKit
import QuickLookUI

/// Ce que la vue tient pour ouvrir le panneau : un pont vers la vue AppKit
/// cachée, qui seule peut entrer dans la chaîne des répondeurs.
@MainActor
final class QuickLookController: ObservableObject {
    fileprivate weak var host: QuickLookHostView?

    /// Montre — ou referme — le Coup d'œil sur ce fichier.
    func show(_ url: URL) { host?.show(url) }
}

/// La vue de zéro point qui porte le contrôle du panneau.
struct QuickLookAnchor: NSViewRepresentable {
    let controller: QuickLookController

    func makeNSView(context: Context) -> QuickLookHostView {
        let view = QuickLookHostView(frame: .zero)
        controller.host = view
        return view
    }

    func updateNSView(_ nsView: QuickLookHostView, context: Context) {
        controller.host = nsView
    }
}

final class QuickLookHostView: NSView {

    private var url: URL?
    /// À qui rendre le focus clavier quand le panneau se referme.
    private weak var previousResponder: NSResponder?

    override var acceptsFirstResponder: Bool { true }

    func show(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        // Espace referme le panneau ouvert : c'est le comportement du Finder,
        // et sans lui la seule sortie serait la souris.
        if panel.isVisible, self.url == url {
            panel.orderOut(nil)
            return
        }
        self.url = url
        if !panel.isVisible {
            previousResponder = window?.firstResponder
            window?.makeFirstResponder(self)
        }
        panel.updateController()
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - Chaîne des répondeurs

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        url != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        if let previousResponder {
            window?.makeFirstResponder(previousResponder)
            self.previousResponder = nil
        }
    }
}

extension QuickLookHostView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!,
                      previewItemAt index: Int) -> QLPreviewItem! {
        url as NSURL?
    }
}

/// Espace sur la liste de résultats : le Coup d'œil du document désigné.
///
/// `onKeyPress` n'existe qu'à partir de macOS 14 et le paquet cible macOS 13
/// (`Package.swift`) — même arbitrage que `OpenSelectionOnReturn`, et pour la
/// même raison : un bouton invisible portant `.keyboardShortcut(.space)`
/// prendrait la barre d'espace dans TOUTE la fenêtre, y compris au milieu d'un
/// mot tapé dans le champ de recherche.
struct QuickLookOnSpace: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onKeyPress(.space) {
                action()
                return .handled
            }
        } else {
            content
        }
    }
}
