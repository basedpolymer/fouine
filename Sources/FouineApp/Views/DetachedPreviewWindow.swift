// DetachedPreviewWindow.swift — l'aperçu d'une page dans SA PROPRE fenêtre
// (F6, UX-17). Propriété : A-App.
//
// POURQUOI CETTE FENÊTRE EXISTE, ET POURQUOI ELLE NE PEUT PAS ÊTRE REMPLACÉE
// PAR APERÇU.APP. Le geste naturel, quand un résultat mérite d'être lu en
// grand, est « ouvrir le document ». Mais ni Aperçu ni aucune application de
// macOS ne sait ouvrir un PDF À UNE PAGE DONNÉE : le lecteur arrive page 1 d'un
// ouvrage de 1 300 pages et doit retrouver seul celle que Fouine avait trouvée
// — et il y arrive sans le surlignage des mots cherchés, que seule Fouine sait
// poser (couche texte native, ou boîtes de la reconnaissance de texte).
//
// D'où cette fenêtre : le MÊME `PreviewPane`, à la MÊME page, avec les MÊMES
// surlignages, mais détachée — on peut en ouvrir plusieurs, les poser côte à
// côte, en garder une ouverte pendant qu'on continue de chercher.
//
// CHAQUE FENÊTRE A SON `PreviewModel`. Partager celui du panneau de droite
// ferait sauter les deux aperçus à la même page dès qu'on cliquerait un
// résultat, ce qui est exactement le contraire du besoin. Le modèle naît avec
// la fenêtre et meurt avec elle ; c'est ce qui libère le `PDFDocument` (piège
// n°1 : PDFKit retient tout ce qu'il analyse).

import SwiftUI
import FouineCore

struct DetachedPreviewWindow: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var search: SearchModel

    /// La page à montrer. `nil` = fenêtre restaurée par macOS sans sa valeur
    /// (restauration d'état après un redémarrage) : on le dit plutôt que
    /// d'afficher un panneau vide et muet.
    let key: HitKey?

    /// Propre à CETTE fenêtre (voir l'en-tête). `@StateObject` et non
    /// `@EnvironmentObject` : SwiftUI le crée une fois par fenêtre et le libère
    /// à sa fermeture.
    @StateObject private var preview: PreviewModel

    /// La table des fenêtres (BU-19). La fenêtre est identifiée par la clé de
    /// sa PREMIÈRE ouverture ; ce qu'elle montre, lui, change — un second lien
    /// vers le même document, ou le réemploi de la fenêtre la moins récente
    /// pour un autre document.
    @ObservedObject private var windows = PreviewWindowsModel.shared

    init(key: HitKey?, service: StoreService) {
        self.key = key
        _preview = StateObject(wrappedValue: PreviewModel(service: service))
    }

    /// Ce que cette fenêtre montre en ce moment, et ce qu'elle a à dire.
    private var target: PreviewTarget {
        guard let key else { return PreviewTarget(key: HitKey(docID: 0, page: 1),
                                                  notice: nil, time: nil) }
        return windows.target(for: key)
    }

    var body: some View {
        Group {
            if key == nil {
                unavailable
            } else {
                VStack(spacing: 0) {
                    if let notice = target.notice {
                        outOfRangeNotice(notice)
                    }
                    PreviewPane()
                        .environmentObject(preview)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .navigationTitle(Text(verbatim: title))
        // `.task(id:)` : une fenêtre restaurée, une valeur qui changerait, ou
        // un lien qui redirige CETTE fenêtre vers une autre page rechargent —
        // et l'ancien chargement est annulé, pas empilé.
        .task(id: target.key) { load() }
        .onDisappear {
            if let key { windows.closed(identity: key) }
        }
    }

    /// « La page 99 999 n'existe plus dans ce document » (BU-18). Une citation
    /// d'il y a un an dont le document a été raccourci ouvrait une fenêtre vide
    /// qui affirmait « page 99 999 » ; elle ouvre maintenant la page 1 et le
    /// dit.
    private func outOfRangeNotice(_ notice: String) -> some View {
        Label(notice, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(Divider(), alignment: .bottom)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("detachedPreview.outOfRange")
    }

    private var unavailable: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("This preview window has nothing to show.")
                .font(.callout)
            Text("Double-click a result again to open it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detachedPreview.empty")
    }

    /// « rapport-2024.pdf — page 87 » : le titre de la fenêtre doit suffire à
    /// la reconnaître dans le menu Fenêtre et sous ⌘tab, sans la ramener au
    /// premier plan.
    private var title: String {
        guard key != nil else { return String(localized: "Preview") }
        // Le titre suit ce que la fenêtre MONTRE, pas la clé qui l'a ouverte :
        // une fenêtre réemployée pour un autre document (BU-19) garderait
        // sinon le nom du précédent dans le menu Fenêtre et sous ⌘tab.
        let shown = target.key
        let relPath = search.docRow(shown.docID)?.record.relPath
        let name = relPath.map(DocumentDisplay.name) ?? preview.title
        if relPath.map(DocumentDisplay.unit) == .card {
            return String(localized: "\(name) — card \(shown.page)")
        }
        return String(localized: "\(name) — page \(shown.page)")
    }

    /// Retrouve le résultat dans le jeu chargé et le donne au modèle.
    ///
    /// Le `Hit` porte la PROVENANCE de la page (`source`), dont dépend
    /// l'affichage des boîtes de reconnaissance de texte : le reconstruire à
    /// partir de la seule clé le poserait à `.native` et une page scannée
    /// perdrait ses surlignages. On le prend donc dans `search.hits`, et on ne
    /// se rabat sur une reconstruction que si la recherche a changé entre le
    /// double-clic et l'ouverture — auquel cas `PreviewModel` corrigera la
    /// provenance lui-même, en lisant `page_src`.
    private func load() {
        guard key != nil else { return }
        let shown = target.key
        let hit = search.hits.first {
            $0.docID == shown.docID && $0.page == shown.page
        } ?? Hit(docID: shown.docID, path: "", page: shown.page, score: 0,
                 snippet: "", source: .native, fuzzyDistance: 0)
        // Le moment porté par un lien `fouine://…&t=` voyage avec la page :
        // c'est la fenêtre qui pose la tête de lecture, pas le lecteur.
        preview.load(hit: hit, roots: app.roots, time: target.time)
    }
}
