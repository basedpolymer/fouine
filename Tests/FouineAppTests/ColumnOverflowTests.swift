// ColumnOverflowTests.swift — aucune phrase de la fenêtre ne la fait déborder
// (24/09/2026). Propriété : A-App.
//
// Un texte figé en hauteur (`fixedSize(horizontal: false, vertical: true)`)
// hors d'une `List` et hors d'un `ScrollView` est mesuré par SwiftUI à largeur
// NULLE : une ligne par mot, et cette hauteur devient le minimum de toute la
// fenêtre. Dans une colonne de `NavigationSplitView`, le contenu déborde sous
// le titre — champ de recherche hors d'atteinte (requête vide le 11/09, avis de
// quorum le 24/09) ; à la racine d'une fenêtre, la fenêtre grandit au-delà de
// l'écran. Pièges connus, « la colonne des résultats qui déborde ».
//
// Ces tests mettent les VRAIES vues en page dans une fenêtre jamais affichée,
// et lisent la hauteur du `NSSplitView` que SwiftUI y pose — celle que l'arbre
// d'accessibilité donne pour `AXSplitGroup`. Le témoin prouve que le harnais
// voit le défaut : sans lui, un test vert ne dirait rien.

import XCTest
import SwiftUI
import AppKit
@testable import FouineApp

@MainActor
final class ColumnOverflowTests: XCTestCase {

    /// La fenêtre principale telle que filmée le 24/09 (build 918).
    private nonisolated static let mainWindow = CGSize(width: 1086, height: 691)
    /// Une phrase qui prend plusieurs lignes dans une colonne étroite.
    private static let sentence =
        "Few pages carry all your words: here are also the pages that carry most of them."

    // MARK: - Harnais

    private struct Layout {
        let content: CGSize
        let split: CGRect?
    }

    /// Met `root` en page dans une fenêtre de `size`, sans l'afficher.
    private func layout<V: View>(_ root: V, in size: CGSize = mainWindow) -> Layout {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: root)
        window.contentView = host
        for _ in 0..<5 {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return Layout(content: host.frame.size, split: Self.firstSplitView(in: host)?.frame)
    }

    private static func firstSplitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for child in view.subviews {
            if let split = firstSplitView(in: child) { return split }
        }
        return nil
    }

    /// Les trois colonnes de `ContentView`, avec leurs largeurs.
    private struct Columns<Content: View, Detail: View>: View {
        let content: Content
        let detail: Detail

        var body: some View {
            NavigationSplitView {
                List { Text(verbatim: "Documents") }
                    .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
            } content: {
                content.navigationSplitViewColumnWidth(min: 350, ideal: 540)
            } detail: {
                detail.navigationSplitViewColumnWidth(min: 300, ideal: 460)
            }
        }
    }

    private func column<V: View>(_ line: V) -> some View {
        VStack(spacing: 0) {
            Text(verbatim: "header")
            line
            ScrollView { Text(verbatim: "page") }
        }
    }

    /// `reference` est la même fenêtre SANS la phrase : la vue hôte compte la
    /// barre de titre, sa hauteur « normale » n'est donc pas celle demandée.
    private func assertFits(_ layout: Layout, reference: Layout, _ what: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(layout.content.height, reference.content.height + 0.5,
                                 "\(what) : la fenêtre a grandi (\(layout.content.height) pt "
                                 + "au lieu de \(reference.content.height))",
                                 file: file, line: line)
        guard let split = layout.split else { return }
        XCTAssertLessThanOrEqual(split.height, layout.content.height + 0.5,
                                 "\(what) : les colonnes débordent de la fenêtre "
                                 + "(\(split.height) pt dans \(layout.content.height))",
                                 file: file, line: line)
    }

    // MARK: - Témoin

    /// Le défaut lui-même, reproduit : si ce test tombe, le harnais ne voit
    /// plus rien et les suivants ne prouvent plus rien.
    func testTheHarnessSeesAFixedHeightOverflowTheColumns() throws {
        let fixed = layout(Columns(
            content: column(Text(Self.sentence).fixedSize(horizontal: false, vertical: true)),
            detail: Text(verbatim: "detail")))
        let split = try XCTUnwrap(fixed.split, "pas de NSSplitView dans la fenêtre")
        XCTAssertGreaterThan(split.height, fixed.content.height + 100,
                             "le harnais ne reproduit plus le débordement")

        assertFits(layout(Columns(
            content: column(Text(Self.sentence)
                .frame(maxWidth: .infinity, alignment: .leading)),
            detail: Text(verbatim: "detail"))),
                   reference: emptyColumns(), "témoin encadré")
    }

    private func emptyColumns() -> Layout {
        layout(Columns(content: column(EmptyView()), detail: column(EmptyView())))
    }

    // MARK: - Les vues de la fenêtre

    /// Une page scannée en mode Texte, tronquée et au surlignage plafonné :
    /// les trois lignes de l'en-tête de l'aperçu texte.
    func testTextPreviewNoticesStayInTheWindow() {
        let notices = TextPreviewNotices(fromOCR: true, truncated: true, capped: true)
        assertFits(layout(Columns(content: column(EmptyView()),
                                  detail: column(notices))),
                   reference: emptyColumns(), "en-tête de l'aperçu texte")
    }

    func testOfflineNoticeStaysInTheWindow() {
        let notice = "The disk holding “Archives 2019” is not plugged in. Here is the text Fouine kept."
        assertFits(layout(Columns(content: column(EmptyView()),
                                  detail: column(OfflineNoticeLine(notice: notice) {}))),
                   reference: emptyColumns(), "ligne « disque débranché »")
    }

    func testPermissionBannerDoesNotGrowTheWindow() throws {
        let db = try TempAppDB()
        let app = AppModel(service: db.service)
        let text = "Fouine cannot read “Documents” and “Desktop”. Results already indexed stay searchable, but preview and indexing are impossible. Open System Settings, then Privacy & Security, then Files and Folders, and allow Fouine."
        assertFits(layout(VStack(spacing: 0) {
            TCCBannerView(text: text).environmentObject(app)
            Columns(content: column(EmptyView()), detail: column(EmptyView()))
        }), reference: emptyColumns(), "bandeau d'autorisation")
    }

    /// La fenêtre d'aperçu détachée, à sa taille minimale.
    func testOutOfRangeNoticeDoesNotGrowTheDetachedWindow() {
        let size = CGSize(width: 480, height: 420)
        let notice = "Page 99,999 no longer exists in this document: here is page 1."
        let page = ScrollView { Text(verbatim: "page") }
        assertFits(layout(VStack(spacing: 0) {
            OutOfRangeNotice(notice: notice)
            page
        }, in: size), reference: layout(page, in: size), "avis de page introuvable")
    }
}
