// MenuBarSearchView.swift — le panneau de la barre des menus (INT-M1).
// Propriété : A-App. SPEC §5.6, amendement « mini-recherche ».
//
// LE GESTE QUE CE PANNEAU SERT. La fenêtre est fermée ; on veut retrouver une
// page. Jusqu'ici il fallait rouvrir Fouine, attendre qu'elle se remonte, puis
// taper. Maintenant : cliquer l'icône, taper trois mots, cliquer la page. Le
// panneau ne remplace pas la fenêtre — huit lignes, pas de filtre, pas de
// facette, pas de recherche par le sens — il évite d'avoir à l'ouvrir.
//
// CE QUI RESTE DU MENU. « Ouvrir Fouine » et « Quitter Fouine », rien d'autre
// depuis IX2 (12/09/2026) : les lignes d'état, les gestes sur l'index et
// l'interrupteur sont partis — on ouvre ce panneau pour chercher, et l'état de
// l'index a sa carte dans la barre latérale et sa fenêtre « Votre index ». Le
// pied descend de `MenuBarModel.items`, testé.
//
// La vue ne décide de rien : le modèle `MenuBarSearchModel` construit les
// lignes, `MenuBarModel` construit le pied. Ne restent ici que les gestes, qui
// ne se testent pas.

import SwiftUI
import AppKit
import FouineCore

struct MenuBarSearchView: View {
    @EnvironmentObject private var app: AppModel
    /// La recherche de la GRANDE fenêtre : ⏎ la lui passe, et c'est la seule
    /// chose que le panneau lui fasse — il ne touche ni ses filtres ni sa
    /// sélection.
    @EnvironmentObject private var search: SearchModel
    @EnvironmentObject private var mini: MenuBarSearchModel
    @Environment(\.openWindow) private var openWindow

    /// Le focus part au champ dès l'ouverture : on ouvre ce panneau pour
    /// taper, jamais pour regarder un champ vide et cliquer dedans. Il est
    /// donné quand le panneau devient la fenêtre clé (`PanelKeyObserver`),
    /// JAMAIS dans `.task` ni `onAppear` — voir le commentaire du `body`.
    @FocusState private var fieldFocused: Bool

    /// 360 points : la largeur d'un nom de fichier lisible sans que le panneau
    /// masque le tiers de la barre des menus.
    private static let width: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            Divider()
            content
            Divider()
            MenuBarView()
                .environmentObject(app)
        }
        .frame(width: Self.width)
        // Le focus et la relance de la requête suivent la FENÊTRE, pas la vue.
        // Une scène `MenuBarExtra` en style `.window` héberge ce contenu dès le
        // lancement, panneau invisible : `.task` et `onAppear` tournent alors
        // une fois, à vide, et un `fieldFocused = true` écrit là crée un état
        // que SwiftUI ne peut pas honorer (le champ n'est dans aucune fenêtre
        // clé) et qu'il remet en cause à CHAQUE mise à jour de l'app — un
        // « AttributeGraph: cycle detected » toutes les 2 s, tant que l'app
        // tourne (mesuré le 08/09/2026 : 0 cycle sans cette écriture, 17 à 34
        // par minute avec ; `docs/pitfalls.md`). Le moment juste est celui
        // où le panneau devient la fenêtre clé.
        .background(PanelKeyObserver(
            onBecomeKey: {
                fieldFocused = true
                // Le panneau se rouvre sur la question d'hier : ses résultats,
                // eux, ont pu vieillir (une passe d'indexation a tourné
                // entre-temps). On la rejoue — huit lignes lexicales, c'est le
                // prix d'un clin d'œil.
                if !mini.text.isEmpty { mini.execute() }
            },
            onResignKey: { fieldFocused = false }))
        // Échap ferme le panneau, comme il ferme un menu. `onExitCommand` et
        // non un `keyboardShortcut(.escape)` : le champ a le focus, et c'est
        // lui qui reçoit la touche.
        .onExitCommand { MenuBarPanel.dismiss() }
        // ↑↓ désignent une ligne. Posé sur le conteneur : le champ de texte
        // laisse passer les flèches verticales (il est mono-ligne).
        .onMoveCommand { direction in
            switch direction {
            case .down: mini.moveSelection(by: 1)
            case .up:   mini.moveSelection(by: -1)
            default:    break
            }
        }
    }

    // MARK: - Champ

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            // Le libellé passe en PLACEHOLDER : `TextField(_:text:)` avec une
            // `String` (et non une `LocalizedStringKey`) ne retraduit rien —
            // `MenuBarText` a déjà fait le travail.
            TextField(MenuBarText.searchPrompt, text: $mini.text)
            .textFieldStyle(.plain)
            .font(.title3)
            .focused($fieldFocused)
            .onChange(of: mini.text) { _ in mini.textChanged() }
            .onSubmit(runSelectionOrWindow)
            .accessibilityLabel("Search")
            .accessibilityHint(Text(verbatim: MenuBarText.searchHint))
            .accessibilityIdentifier("menubar.search.field")
            if !mini.text.isEmpty {
                Button {
                    mini.reset()
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the query")
                .accessibilityIdentifier("menubar.search.clear")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Résultats

    @ViewBuilder
    private var content: some View {
        switch mini.state {
        case .idle:
            EmptyView()
        case .searching:
            message(String(localized: "searching…"))
        case .error(let text):
            message(text, warning: true)
        case .indexNotOpen:
            message(String(localized: "Fouine has not opened your index yet. Open Fouine."))
        case .empty:
            message(String(localized: "No result for “\(mini.text)”"))
        case .results:
            results
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            // NI `ScrollView`, NI `LazyVStack` : la hauteur est déjà bornée par
            // les huit lignes du modèle, et ces deux conteneurs coûtent cher
            // ici — le premier avale le défilement destiné à la fenêtre qui est
            // dessous, et aucun des deux ne se dessine hors écran, ce qui
            // interdisait toute copie d'écran de contrôle du panneau
            // (`ImageRenderer` n'en rendait qu'une zone vide, mesuré le
            // 08/09/2026).
            VStack(alignment: .leading, spacing: 0) {
                ForEach(mini.rows) { row in
                    line(row)
                }
            }
            // « Voir tous les résultats » : la liste s'arrête à huit pages, et
            // taire les autres laisserait croire qu'il n'y en a pas.
            if mini.hasMore {
                Divider()
                Button(action: openInWindow) {
                    HStack(spacing: 6) {
                        Text(verbatim: MenuBarText.showAll)
                        Spacer(minLength: 0)
                        Text(verbatim: countLine)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("menubar.search.all")
            }
        }
    }

    /// « 132 page(s) dans 12 document(s) » — la MÊME phrase que la ligne d'état
    /// de la fenêtre : un compte qui change de forme d'un endroit à l'autre se
    /// lit comme deux comptes différents.
    private var countLine: String {
        guard case .results(let pages, let docs) = mini.state else { return "" }
        return String(localized: "\(pages) page(s) in \(docs) document(s)")
    }

    /// Scindée en deux (lot MN2) : d'un tenant, 1,1 s de vérification de
    /// types, pour l'essentiel les deux ternaires sans type. Même arbre.
    private func line(_ row: MenuBarSearchRow) -> some View {
        let selected = mini.selection == row.key
        let traits: AccessibilityTraits = selected ? [.isSelected] : []
        return Button { open(row) } label: {
            lineLabel(row, selected: selected)
        }
        .buttonStyle(.plain)
        // Le nom du fichier, la page, l'extrait : une seule annonce, dans
        // l'ordre où l'œil les lit.
        .accessibilityLabel(Text(verbatim: MenuBarText.rowLabel(
            fileName: row.fileName, page: row.page, snippet: row.snippet)))
        .accessibilityHint(Text(verbatim: MenuBarText.rowHint))
        .accessibilityAddTraits(traits)
        .accessibilityIdentifier("menubar.search.hit.\(row.docID).\(row.page)")
    }

    private func lineLabel(_ row: MenuBarSearchRow, selected: Bool) -> some View {
        let background: Color = selected ? Color.accentColor.opacity(0.18) : Color.clear
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(verbatim: row.fileName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: String(localized: "page \(row.page)"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(verbatim: row.snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .contentShape(Rectangle())
    }

    private func message(_ text: String, warning: Bool = false) -> some View {
        HStack(spacing: 6) {
            if warning {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
            Text(verbatim: text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("menubar.search.message")
    }

    // MARK: - Gestes

    /// ⏎ : sur une ligne désignée au clavier, elle s'ouvre ; sinon la question
    /// part à la grande fenêtre, qui sait tout en faire.
    private func runSelectionOrWindow() {
        if let row = mini.selectedRow {
            open(row)
        } else if mini.returnSearchesHere {
            // « Chercher pendant que je tape » éteint (AP1) : rien n'a encore
            // été cherché, et ⏎ est le geste qui cherche. Le ⏎ suivant, la
            // question étant déjà posée, ouvre la fenêtre comme toujours.
            mini.submit()
        } else {
            openInWindow()
        }
    }

    /// Une page : la fenêtre d'aperçu détachée, celle du double-clic sur un
    /// résultat (UX-17) — le panneau n'a aucun chemin d'ouverture à lui.
    /// ⌘-clic ouvre le FICHIER dans son application, pour qui veut le document
    /// entier plutôt que la page.
    private func open(_ row: MenuBarSearchRow) {
        if NSEvent.modifierFlags.contains(.command),
           let url = mini.fileURL(for: row) {
            NSWorkspace.shared.open(url)
        } else {
            // La MÊME table de fenêtres que le double-clic et les liens
            // `fouine://` (BU-19) : une par document, trois au plus.
            PreviewWindowsModel.shared.open(row.key, using: openWindow)
        }
        MenuBarPanel.dismiss()
    }

    private func openInWindow() {
        MainWindow.show(openWindow)
        search.text = mini.text
        search.submit()
        MenuBarPanel.dismiss()
    }
}

/// Prévient la vue quand la fenêtre qui l'héberge devient — ou cesse d'être —
/// la fenêtre clé. C'est le seul signal fiable d'« ouverture » du panneau d'un
/// `MenuBarExtra` en style `.window` : sa vue vit dès le lancement, cachée, et
/// n'« apparaît » donc qu'une fois ; ce que l'utilisateur voit s'ouvrir, c'est
/// la fenêtre qui prend le focus.
private struct PanelKeyObserver: NSViewRepresentable {
    let onBecomeKey: () -> Void
    let onResignKey: () -> Void

    func makeNSView(context: Context) -> Probe {
        Probe(onBecomeKey: onBecomeKey, onResignKey: onResignKey)
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.onBecomeKey = onBecomeKey
        view.onResignKey = onResignKey
    }

    final class Probe: NSView {
        var onBecomeKey: () -> Void
        var onResignKey: () -> Void
        private var observers: [NSObjectProtocol] = []

        init(onBecomeKey: @escaping () -> Void, onResignKey: @escaping () -> Void) {
            self.onBecomeKey = onBecomeKey
            self.onResignKey = onResignKey
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                   object: window, queue: .main) { [weak self] _ in
                    self?.onBecomeKey()
                },
                center.addObserver(forName: NSWindow.didResignKeyNotification,
                                   object: window, queue: .main) { [weak self] _ in
                    self?.onResignKey()
                },
            ]
            // La vue peut rejoindre une fenêtre DÉJÀ clé (SwiftUI attache
            // parfois le contenu au moment de l'afficher) : le signal est alors
            // passé, on le rejoue — au tour suivant, jamais pendant la mise en
            // place de la hiérarchie.
            if window.isKeyWindow {
                DispatchQueue.main.async { [weak self] in self?.onBecomeKey() }
            }
        }
    }
}

/// Fermer le panneau de la barre des menus.
///
/// CE QUI NE MARCHE PAS, ET POURQUOI. `MenuBarExtra` en style `.window` n'a ni
/// action `dismiss` (l'environnement `\.dismiss` d'une scène `MenuBarExtra` ne
/// la ferme pas) ni fenêtre publique : son panneau est une `NSPanel` privée,
/// que `close()` laisse à l'écran — SwiftUI la remonte au tour suivant. Ce qui
/// la retire est la PERTE DU FOCUS : c'est ainsi qu'elle disparaît quand on
/// clique ailleurs.
///
/// Les trois gestes du panneau la font donc tomber d'eux-mêmes (ils activent
/// une autre fenêtre : la fenêtre principale, l'aperçu détaché, une autre
/// application) ; Échap, lui, n'active rien, d'où `resignKey()` — la seule
/// manière trouvée de dire au panneau qu'il n'est plus la fenêtre clé sans
/// détruire ce que SwiftUI reconstruira.
@MainActor
enum MenuBarPanel {
    static func dismiss() {
        // La fenêtre clé qui ne peut pas devenir « principale » est un
        // panneau : celui du `MenuBarExtra`, puisque c'est lui qui a le focus
        // quand ce code s'exécute. Aucune fenêtre de Fouine ne répond à cette
        // description (la fenêtre principale, l'aperçu et les réglages sont
        // toutes `canBecomeMain`).
        guard let panel = NSApp.keyWindow, !panel.canBecomeMain else { return }
        panel.resignKey()
    }
}
