// GuideWindow.swift — la fenêtre « Guide de Fouine » (⌘?, BU-27).
// Propriété : A-App.
//
// Une `Window` et non un `WindowGroup` : il n'y a qu'un guide, en ouvrir deux
// n'aurait aucun sens — et SwiftUI ramène alors au premier plan celle qui
// existe déjà. `commandsRemoved()` la retire du menu Fenêtre : on y entre par
// le menu Aide, qui est justement l'endroit où l'on va la chercher.
//
// La page est du HTML rendu à partir de `docs/app.md` (MarkdownHTML) et
// affiché par WKWebView. Aucun accès au réseau : `loadHTMLString` sert une
// chaîne déjà en mémoire, la feuille de style est intégrée, et tout lien qui
// sort du guide part dans le NAVIGATEUR — une fenêtre d'aide qui se met à
// naviguer sur le Web est une fenêtre d'aide perdue.

import SwiftUI
import WebKit

struct GuideWindowScene: Scene {

    /// L'identifiant de la scène, partagé avec le menu Aide.
    static let id = "guide"

    var body: some Scene {
        Window("Fouine Guide", id: Self.id) {
            GuideView()
                .frame(minWidth: 520, minHeight: 400)
        }
        .defaultSize(width: 760, height: 640)
        .commandsRemoved()
    }
}

struct GuideView: View {

    /// Lu UNE fois, à la construction de la fenêtre : le guide ne change pas
    /// pendant qu'on le lit, et relire le fichier à chaque rendu SwiftUI
    /// coûterait une lecture disque par frappe.
    private let page = GuideLocator.page()

    var body: some View {
        if let page {
            GuideWebView(html: page.html, baseURL: page.baseURL)
        } else {
            // Hors bundle (`swift run FouineApp`) : le guide n'a pas été copié.
            // On le dit sans parler de bundle ni de chemin de fichier.
            VStack(spacing: 8) {
                Image(systemName: "book.closed")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("The guide is not included in this copy of Fouine.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("guide.missing")
        }
    }
}

private struct GuideWebView: NSViewRepresentable {

    let html: String
    let baseURL: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Rien à exécuter dans le guide : c'est du texte. Le désarmer coûte une
        // ligne et retire toute surface d'exécution à un document qu'on ouvre
        // depuis les ressources de l'application.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.underPageBackgroundColor = .textBackgroundColor
        view.allowsBackForwardNavigationGestures = false
        view.loadHTMLString(html, baseURL: baseURL)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url,
                  GuideLocator.opensInBrowser(url)
            else { return decisionHandler(.allow) }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }
}
