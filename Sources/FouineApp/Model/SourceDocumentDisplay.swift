// SourceDocumentDisplay.swift — un document recopié d'Anki, de Notes ou de Bear
// se montre comme dans son application : son nom, son paquet, l'icône de
// l'application, des cartes plutôt que des pages (lot AN2). Propriété : A-App.
//
// Relevé par le propriétaire le 14/09/2026, capture à l'appui : la liste
// montrait « 625 Physico-chimie macromoléculaire.md » sous « Library/
// Application Support/Fouine…ysico-chimie macromoléculaire.md », avec « p. 1 »
// et « 74 p. ». Rien de faux, et rien de ce qu'il connaît : ce sont ses cartes,
// rangées dans ses paquets. Le fichier `.md` est un détail de fabrication de
// Fouine (`AppSource`), il ne doit plus paraître nulle part dans l'app.
//
// UNE SEULE PORTE pour toutes les surfaces — liste, aperçu, fenêtre détachée,
// « Tous vos documents », barre des menus, citations, export — : c'est le
// patron de `SearchModel.displayPath` (AP-15), dont deux copies avaient
// divergé. La reconnaissance elle-même est dans `SourceDocumentLocator`
// (FouineIndex), par l'emplacement du fichier et rien d'autre.

import SwiftUI
import AppKit
import FouineCore
import FouineIndex

/// Ce qu'une « page » est dans le document qui la porte : une page, ou une
/// carte d'un paquet Anki (une carte par page, `MaterializedText`).
///
/// UNE CARTE PLUS LONGUE QU'UNE PAGE ORDINAIRE (4 000 caractères) en occupe
/// deux, et les numéros des cartes suivantes suivent alors les pages. Mesuré
/// le 14/09/2026 sur la collection du propriétaire : 0 carte sur 3 352, la plus
/// longue fait 2 885 caractères. Le numéro reste celui qu'ouvre le lien.
enum PageUnit: Equatable, Sendable {
    case page
    case card

    /// « p. 12 » / « carte 12 » : la colonne de gauche d'une ligne de résultat.
    func short(_ number: Int) -> String {
        switch self {
        case .page: return String(localized: "p. \(number)")
        case .card: return String(localized: "card \(number)")
        }
    }

    /// « page 12 » / « carte 12 ».
    func single(_ number: Int) -> String {
        switch self {
        case .page: return String(localized: "page \(number)")
        case .card: return String(localized: "card \(number)")
        }
    }

    /// « page 12 of 40 » / « card 12 of 40 ».
    func position(_ number: Int, of count: Int) -> String {
        switch self {
        case .page: return String(localized: "page \(number) of \(count)")
        case .card: return String(localized: "card \(number) of \(count)")
        }
    }
}

/// Le nom, le fil d'Ariane et l'unité d'un document, qu'il vienne d'une
/// application ou non.
enum DocumentDisplay {

    /// Le document recopié que désigne ce chemin, ou `nil`.
    static func source(_ relPath: String) -> SourceDocument? {
        SourceDocumentLocator.standard.document(relPath: relPath)
    }

    /// Le nom à montrer : celui de la note ou du paquet, sinon celui du fichier.
    static func name(_ relPath: String) -> String {
        source(relPath)?.title ?? (relPath as NSString).lastPathComponent
    }

    static func unit(_ relPath: String) -> PageUnit {
        source(relPath)?.isAnkiDeck == true ? .card : .page
    }
}

/// L'icône de l'application d'une source — le vrai logo d'Anki, de Notes ou de
/// Bear, pris dans l'application installée —, et un pictogramme du système
/// quand elle ne l'est pas (des notes de Bear survivent à sa désinstallation).
///
/// L'icône vient de LaunchServices, par identifiant de paquet : Fouine
/// n'embarque aucun logo, et celui qu'on voit est toujours celui de la version
/// installée.
struct SourceAppIcon: View {
    let sourceID: String
    var size: CGFloat = 16

    var body: some View {
        if let image = SourceAppIcons.icon(for: sourceID) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: SourceAppIcons.symbol(for: sourceID))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

@MainActor
enum SourceAppIcons {
    /// Une recherche LaunchServices par source et par lancement : une liste de
    /// deux cents lignes redessinée à chaque frappe ne la refait pas.
    private static var cache: [String: NSImage?] = [:]

    static func icon(for sourceID: String) -> NSImage? {
        if let cached = cache[sourceID] { return cached }
        let image = applicationURL(for: sourceID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[sourceID] = image
        return image
    }

    /// L'application installée d'une source, la plus récente d'abord.
    static func applicationURL(for sourceID: String) -> URL? {
        guard let source = AppSources.source(id: sourceID) else { return nil }
        return source.bundleIdentifiers.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    nonisolated static func symbol(for sourceID: String) -> String {
        switch sourceID {
        case AppleNotesSource.identifier: return "note.text"
        case BearSource.identifier:       return "pawprint"
        case AnkiSource.identifier:       return "rectangle.stack"
        default:                          return "app"
        }
    }
}
