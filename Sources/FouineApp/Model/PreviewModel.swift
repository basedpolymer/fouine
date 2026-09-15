// PreviewModel.swift — panneau d'aperçu (SPEC §5.6). Propriété : A-App.
//
// Règle du §5.6 : « Racine indisponible : les résultats restent consultables,
// l'aperçu affiche un état explicite nommant la racine et l'action à faire. Ne
// jamais planter, ne jamais vider l'affichage. » Tout ce fichier est écrit autour
// de cette phrase — aucun chemin d'erreur ne remonte en exception à la vue.

import Foundation
import SwiftUI
import AppKit
import PDFKit
import FouineCore
import FouineExtract
import FouineIndex
import FouineOCR

/// PDFDocument n'est pas `Sendable` : il traverse la frontière de tâche dans
/// cette boîte, et une seule fois (chargement en tâche de fond -> vue).
final class PDFDocumentBox: @unchecked Sendable, Equatable {
    let document: PDFDocument
    let url: URL
    init(document: PDFDocument, url: URL) {
        self.document = document
        self.url = url
    }
    static func == (a: PDFDocumentBox, b: PDFDocumentBox) -> Bool { a === b }
}

final class ImageBox: @unchecked Sendable, Equatable {
    let image: NSImage
    init(image: NSImage) { self.image = image }
    static func == (a: ImageBox, b: ImageBox) -> Bool { a === b }
}

/// Texte d'une page, tel qu'il est EN BASE (audit U4).
///
/// Ni `txt`, ni `md`, ni `html`, ni `epub`, ni `docx`, ni `rtf`, ni `djvu`
/// n'ont de rendu par page ; l'aperçu tombait donc en « aperçu non disponible »
/// alors que le texte de la page trouvée était déjà indexé, à un `SELECT` de
/// distance. C'est ce `SELECT` que ce cas affiche — jamais le fichier : aucun
/// accès disque, donc aucune invite TCC et rien à ré-extraire.
struct PageTextContent: Equatable {
    let text: String
    /// Toutes les pages du document qui portent du texte, triées : la
    /// navigation « précédente / suivante » saute les pages vides.
    let pages: [Int]
    /// Le texte vient de l'OCR : l'interface le DIT (ce n'est pas le fichier
    /// qu'on lit, c'est ce que Vision a cru y voir).
    let fromOCR: Bool
    /// Rendu en chasse fixe : formats de code ou à balises, où l'indentation
    /// et les retours à la ligne portent du sens.
    let monospaced: Bool
    /// Les images de la carte Anki affichée, lues dans le dossier de médias
    /// d'Anki (lot AN1). Vide pour tout autre document.
    var images: [URL] = []
}

extension PageTextContent {
    /// La clé qui relance le surlignage de l'aperçu Texte (lot MN2).
    ///
    /// Elle portait la LONGUEUR du texte et les termes : deux cartes Anki
    /// jumelles, deux feuilles de tableur de même longueur ne relançaient pas
    /// le rendu, et l'aperçu gardait le texte surligné de la page d'avant. Elle
    /// porte maintenant la page affichée et une empreinte du texte ;
    /// `hashValue` change d'un lancement à l'autre, ce qui ne gêne pas une clé
    /// qui ne vit que le temps de la vue.
    func renderKey(identity: HitKey?, terms: [HighlightTerm]) -> String {
        let shown = identity.map { "\($0.docID)#\($0.page)" } ?? "-"
        let termIDs = terms.map(\.id).joined(separator: "·")
        return "\(shown)|\(text.count)|\(text.hashValue)|\(monospaced)|\(termIDs)"
    }
}

/// Le geste proposé sous un aperçu indisponible.
///
/// L'ACTION VOYAGE AVEC LA CAUSE (A2-11), comme `HealthAction` le fait déjà
/// pour le bandeau de santé. Avant, les six causes — racine refusée, fichier
/// déplacé, volume démonté, document absent de l'index, disposition OCR
/// illisible, aperçu impossible — affichaient toutes les deux mêmes boutons,
/// « Ouvrir les Réglages Système » et « Retester les dossiers ». Envoyer
/// chercher une autorisation de confidentialité pour un fichier que
/// l'utilisateur a lui-même déplacé la veille, c'est le détourner du seul
/// geste utile. Le §5.6 demande « un état explicite nommant la racine ET
/// l'action à faire » : la moitié y était.
enum PreviewAction: Hashable, Sendable {
    /// Réglages Système ▸ Confidentialité et sécurité ▸ Fichiers et dossiers.
    case openPrivacySettings
    /// Resonder les racines : après avoir rebranché un disque, par exemple.
    case retestRoots
    /// « Indexer maintenant » : le seul geste qui rattrape un fichier déplacé.
    case indexNow
    /// Le Finder, sur le dossier où le fichier DEVRAIT être. Le chemin voyage
    /// avec l'action — le fichier n'est plus là, on ne peut pas le sélectionner.
    case revealExpectedLocation(path: String)
}

enum PreviewContent: Equatable {
    case empty
    case loading
    case pdf(PDFDocumentBox)
    case image(ImageBox)
    case text(PageTextContent)
    /// Le document tel que macOS le dessine (lot PV1), et le texte indexé de la
    /// page quand il existe : l'en-tête laisse passer de l'un à l'autre, et
    /// seul le texte porte la mise en évidence des mots cherchés.
    case quickLook(url: URL, text: PageTextContent?)
    /// Un son ou une vidéo : le lecteur, et la transcription horodatée.
    case media(url: URL, text: PageTextContent?)
    /// Racine absente, volume démonté, TCC révoqué : titre, geste à faire, et
    /// les boutons qui vont avec CETTE cause (A2-11). `actions` vide = il n'y a
    /// rien à cliquer, et on n'affiche alors aucun bouton.
    case unavailable(title: String, detail: String, actions: [PreviewAction])
    case unsupported(String)
}

/// Petit `Result` maison à échec textuel — `String` ne conforme pas à `Error`,
/// et l'aperçu ne veut justement JAMAIS d'exception (§5.6).
enum Loaded<T> {
    case success(T)
    case failure(String)
}

struct Provenance: Equatable {
    let source: PageSource
    let engine: OCREngineID

    var symbol: String {
        switch (source, engine) {
        case (.native, _): return "doc.text"
        case (.transcript, _): return "waveform"
        case (_, .external): return "square.and.arrow.down.on.square"
        default: return "text.viewfinder"
        }
    }

    /// UNE SEULE TABLE pour les quatre surfaces (AP-03) : la facette, le
    /// pictogramme d'une ligne, cet en-tête et le libellé parlé disaient la
    /// même chose de quatre façons — « texte tapé » ici, « texte natif » là,
    /// sur le même écran et pour la même page.
    var label: String { LanguageNames.sourceLabel(source, engine: engine) }

    /// Vrai pour les seules provenances SCANNÉES. Une page transcrite n'est pas
    /// de l'OCR : elle n'a pas d'image, donc pas de cadres de lignes à surligner
    /// ni de couleur « reconnu » à porter (INT-F3). `source != .native` la
    /// faisait passer pour un scan et l'aperçu cherchait des rectangles qui
    /// n'existent pas.
    var isOCR: Bool { PageSource.scanned.contains(source) }
}

/// Le document affiché vient-il d'une application, et laquelle (lot INT-F4) ?
///
/// PUR et hors de `PreviewModel` : trois entrées textuelles, un cas en sortie.
/// C'est ce que le test interroge — une vue ne se teste pas, un choix de bouton
/// se teste.
enum SourceOpenTarget: Equatable {
    /// Une note recopiée par Fouine : le lien vient de l'en-tête du fichier.
    case notes(URL)
    case bear(URL)
    /// Un paquet Anki recopié (lot AN1). Anki pour Mac n'a pas de lien vers une
    /// note : le bouton ouvre l'APPLICATION, retrouvée par son identifiant de
    /// paquet — jamais par un chemin lu dans le fichier, qu'un document
    /// quelconque pourrait imiter.
    case anki(URL)
    /// Un export Notion : le lien vient du NOM du fichier (Notion y colle
    /// l'identifiant de la page).
    case notion(URL)

    var url: URL {
        switch self {
        case .notes(let url), .bear(let url), .anki(let url), .notion(let url):
            return url
        }
    }

    /// Le libellé du bouton. Le nom de l'application ne se traduit pas ; la
    /// phrase, si — d'où trois chaînes plutôt qu'une à trous.
    var label: String {
        switch self {
        case .notes:  return Self.label(forSource: AppleNotesSource.identifier)
        case .bear:   return Self.label(forSource: BearSource.identifier)
        case .anki:   return Self.label(forSource: AnkiSource.identifier)
        case .notion: return String(localized: "Open in Notion")
        }
    }

    /// Le libellé du bouton d'une source, avant d'avoir relu son lien : le
    /// menu contextuel de la liste le montre sans ouvrir le fichier.
    static func label(forSource sourceID: String) -> String {
        switch sourceID {
        case AppleNotesSource.identifier: return String(localized: "Open in Notes")
        case BearSource.identifier:       return String(localized: "Open in Bear")
        default:                          return String(localized: "Open in Anki")
        }
    }

    var symbol: String {
        switch self {
        case .notes:  return "note.text"
        case .bear:   return "pawprint"
        case .anki:   return "rectangle.stack"
        case .notion: return "square.on.square"
        }
    }

    /// Le lien de réouverture d'un document, ou `nil` s'il n'en a pas.
    ///
    /// L'EMPLACEMENT DÉCIDE, PAS CE QUE LE FICHIER DIT (lot AN2). Seul un
    /// fichier du dossier des copies de Fouine (`document` non nul) est une
    /// note recopiée ; son en-tête ne fait plus que porter le lien, et ce lien
    /// doit être du schéma de SON application (`notes:`, `bear:`). Avant, un
    /// `.md` quelconque d'une racine qui écrivait `fouine-source: notes` et
    /// `fouine-open: file:///…/x.app` en tête obtenait un bouton qui ouvrait
    /// ce qu'il voulait (rapport AN1, § 5).
    ///
    /// `ankiApplication` rend l'Anki installé, ou `nil` : sans lui, pas de
    /// bouton. Injecté pour que le test ne dépende pas de ce qui est installé
    /// sur la machine.
    static func from(document: SourceDocument?, fileName: String, fileHead: String?,
                     ankiApplication: () -> URL? = SourceOpenTarget.installedAnki)
        -> SourceOpenTarget? {
        if let document {
            switch document.sourceID {
            case AnkiSource.identifier:
                return ankiApplication().map { .anki($0) }
            case AppleNotesSource.identifier, BearSource.identifier:
                guard let head = fileHead,
                      SourceLinks.sourceID(inMarkdown: head) == document.sourceID,
                      let url = SourceLinks.openURL(inMarkdown: head),
                      let scheme = document.source?.openURLTemplate
                        .components(separatedBy: ":").first,
                      url.scheme?.lowercased() == scheme.lowercased()
                else { return nil }
                return document.sourceID == AppleNotesSource.identifier
                    ? .notes(url) : .bear(url)
            default:
                return nil
            }
        }
        guard fileName.lowercased().hasSuffix(".md")
                || fileName.lowercased().hasSuffix(".html"),
              let url = SourceLinks.notionURL(forFileName: fileName) else {
            return nil
        }
        return .notion(url)
    }

    /// L'application Anki de ce Mac, la plus récente d'abord.
    static func installedAnki() -> URL? {
        AnkiSource.bundleIdentifiers.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    /// Le bouton d'un document, fichier relu au besoin : les premiers octets
    /// seulement, et seulement pour une note recopiée (son lien est dans
    /// l'en-tête, que l'index ne garde plus). Un paquet Anki et un export
    /// Notion n'ont rien à lire.
    static func resolve(relPath: String, fileURL: URL?) -> SourceOpenTarget? {
        let document = DocumentDisplay.source(relPath)
        let head = document.flatMap { $0.isAnkiDeck ? nil : fileURL.flatMap(Self.fileHead) }
        return from(document: document,
                    fileName: (relPath as NSString).lastPathComponent,
                    fileHead: head)
    }

    /// Les 2 Kio de tête d'un fichier : l'en-tête d'une note recopiée tient
    /// en deux lignes.
    static func fileHead(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2_048) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class PreviewModel: ObservableObject {

    @Published private(set) var content: PreviewContent = .empty {
        // Le curseur décrit la page QUE MONTRAIT le PDF : il se vide dès que
        // le contenu change, et `PDFPreviewView` le remplit de nouveau au tour
        // suivant (PN1). Sans cela, l'en-tête d'un nouveau PDF montrait une
        // image le « 3 / 27 » du précédent. Seulement sur un vrai changement :
        // une réaffectation à l'identique ne rappelle pas `apply`, et le
        // curseur resterait vide.
        didSet { if oldValue != content { clearPDFOccurrences() } }
    }
    @Published private(set) var docRow: DocRow?
    @Published private(set) var page = 1 {
        didSet { if oldValue != page { clearPDFOccurrences() } }
    }
    /// Les occurrences des mots cherchés sur la page du PDF, dans l'ordre de
    /// lecture, et celle où l'on est (PN1). Vide hors PDF.
    @Published private(set) var occurrenceCursor = OccurrenceCursor()
    /// Les termes dont le surlignage du PDF a buté sur son plafond de 400.
    @Published private(set) var occurrenceCapped: Set<Int> = []
    /// Les comptes par terme de l'aperçu TEXTE. Pas de curseur là : un `Text`
    /// SwiftUI ne défile pas jusqu'à une plage, et un « 3 / 27 » sans geste
    /// possible promettrait un saut qui ne viendrait pas.
    @Published private(set) var textOccurrences = OccurrenceTally.Counts()
    @Published private(set) var provenance: Provenance?
    @Published private(set) var ocrLines: [OCRLine]?
    @Published private(set) var fileURL: URL?
    /// L'application d'où vient le document, quand il en vient d'une (INT-F4).
    @Published private(set) var sourceTarget: SourceOpenTarget?
    /// Ce que « Relire cette page » a répondu — une phrase sous l'aperçu, ou
    /// `nil` (constat PR-24). Effacée dès qu'on change de page : un accusé de
    /// réception qui survivrait à la navigation parlerait de la page d'avant.
    @Published private(set) var rereadNotice: String?
    /// Le disque du document n'est pas branché et l'aperçu montre le texte
    /// gardé (lot PV1). Une phrase, ou `nil` — l'aperçu texte seul ne disait
    /// pas pourquoi la mise en page avait disparu.
    @Published private(set) var offlineNotice: String?
    /// Où poser la tête de lecture du prochain média affiché : une pastille de
    /// la liste des résultats, ou un lien `fouine://…&t=`. `nil` = au début du
    /// passage trouvé.
    @Published private(set) var requestedTime: Int?
    @Published var insideText = ""

    private let service: StoreService
    private var loadTask: Task<Void, Never>?
    private(set) var loadedKey: HitKey?
    /// La page à laquelle `requestedTime` se rapporte : une demande posée
    /// AVANT le chargement (clic sur une pastille) ne doit pas survivre au
    /// résultat suivant.
    private var requestedTimeKey: HitKey?
    /// La position du lecteur, en secondes. Pas `@Published` : elle change à
    /// chaque seconde de lecture, et republier autant referait tout le panneau.
    private(set) var mediaPlayhead: Int?

    /// Comment aller à une occurrence : posé par `PDFPreviewView.Coordinator`,
    /// qui seul tient les sélections et les annotations de la page. Pas
    /// `@Published` : c'est un geste, pas un état à afficher.
    var occurrenceJump: ((OccurrenceCursor.Occurrence) -> Void)?

    init(service: StoreService) { self.service = service }

    // MARK: - Occurrences (PN1)

    /// Le PDF vient de surligner sa page : le curseur repart de la première
    /// occurrence, là où l'aperçu s'est placé.
    func resetOccurrences(_ cursor: OccurrenceCursor, capped: Set<Int>) {
        if cursor != occurrenceCursor { occurrenceCursor = cursor }
        if capped != occurrenceCapped { occurrenceCapped = capped }
    }

    func noteTextOccurrences(_ counts: OccurrenceTally.Counts) {
        if counts != textOccurrences { textOccurrences = counts }
    }

    private func clearPDFOccurrences() {
        if !occurrenceCursor.isEmpty { occurrenceCursor = OccurrenceCursor() }
        if !occurrenceCapped.isEmpty { occurrenceCapped = [] }
    }

    /// Les pastilles de l'en-tête : celles du PDF, ou celles de l'aperçu
    /// texte quand c'est lui qui est à l'écran.
    func occurrenceChips(terms: [HighlightTerm], showsText: Bool) -> [OccurrenceTally.Chip] {
        if case .pdf = content {
            return OccurrenceTally.chips(
                terms: terms,
                counts: .init(byTerm: occurrenceCursor.countsByTerm,
                              capped: occurrenceCapped))
        }
        return showsText ? OccurrenceTally.chips(terms: terms, counts: textOccurrences) : []
    }

    /// Le curseur a-t-il un geste à offrir ? L'en-tête, les boutons et le menu
    /// Édition lisent la même réponse.
    var canStepOccurrences: Bool {
        guard case .pdf = content else { return false }
        return !occurrenceCursor.isEmpty && occurrenceJump != nil
    }

    func nextOccurrence() {
        guard canStepOccurrences, let target = occurrenceCursor.next() else { return }
        occurrenceJump?(target)
    }

    func previousOccurrence() {
        guard canStepOccurrences, let target = occurrenceCursor.previous() else { return }
        occurrenceJump?(target)
    }

    var title: String {
        guard let row = docRow else { return String(localized: "No document") }
        return DocumentDisplay.name(row.record.relPath)
    }

    /// Le document affiché est-il une copie de Fouine — une note, un paquet
    /// Anki (lot AN2) ? C'est ce qui efface le fichier de l'écran : nom, fil
    /// d'Ariane au lieu du chemin, pas de mode « Document », pas de Finder.
    var sourceDocument: SourceDocument? {
        docRow.flatMap { DocumentDisplay.source($0.record.relPath) }
    }

    /// Page ou carte.
    var pageUnit: PageUnit {
        sourceDocument?.isAnkiDeck == true ? .card : .page
    }

    /// Le chemin ABRÉGÉ, celui de la liste de résultats (AP-15, BU-12).
    ///
    /// L'en-tête affichait `row.record.relPath` tel quel — « Users/mathis/
    /// Livres/Chimie/… » —, à trois centimètres d'une liste qui affiche
    /// « Livres/Chimie/… » du même document : deux rendus du même chemin dans
    /// la même fenêtre, dont l'un livre le nom de session. La règle du projet
    /// (« pas de chemin de fichier sauf à la demande ») est tenue partout
    /// ailleurs ; le chemin entier passe en infobulle, à la demande.
    var subtitle: String {
        guard let row = docRow else { return "" }
        return Self.subtitle(path: SearchModel.displayPath(row.record.relPath),
                             docDate: row.record.docDate)
    }

    /// Le sous-titre de l'en-tête : le chemin abrégé, et la date que le
    /// DOCUMENT porte quand il en porte une (schéma v9, constat PR-07).
    ///
    /// Fonction PURE : c'est la seule façon d'éprouver la règle du 1ᵉʳ janvier
    /// ci-dessous, une vue SwiftUI ne se testant pas.
    static func subtitle(path: String, docDate: Double?) -> String {
        guard let docDate, let note = dateNote(docDate) else { return path }
        return path.isEmpty ? note : path + " · " + note
    }

    /// « daté du 12 avril 2003 », ou « daté de 2003 » quand on ne connaît que
    /// l'année.
    ///
    /// POURQUOI LE 1ᵉʳ JANVIER SE DIT EN ANNÉE SEULE. La colonne ne porte qu'un
    /// instant : la PRÉCISION de la métadonnée d'origine — « 2003 » nu, ou
    /// « 2003-04 » — est perdue, et une année seule y est écrite au 1ᵉʳ janvier
    /// (`DocumentDate`). Afficher « daté du 1ᵉʳ janvier 2003 » pour un ouvrage
    /// dont l'EPUB dit seulement « 2003 » serait une précision INVENTÉE, et
    /// c'est le genre de détail qu'on cite ensuite de bonne foi. Le prix est
    /// qu'un document réellement daté du 1ᵉʳ janvier s'annonce à l'année : un
    /// jour de l'an sur 365 jours, contre une majorité de dates d'ouvrage
    /// tronquées à l'année.
    static func dateNote(_ seconds: Double) -> String? {
        let civil = DocumentDate.civil(seconds)
        guard civil.year > 0 else { return nil }
        if civil.month == 1 && civil.day == 1 {
            return String(localized: "dated in \(String(civil.year))")
        }
        return String(localized: "dated \(longDay(seconds))")
    }

    /// Le jour en toutes lettres, dans la langue de l'utilisateur, LU EN UTC :
    /// `doc_date` est un jour civil écrit à midi UTC, et le rendre dans le
    /// fuseau de la machine le décalerait d'un jour aux antipodes.
    private static func longDay(_ seconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    /// La voie d'aperçu du document affiché (lot PV1) : elle décide du mode
    /// proposé d'emblée par le sélecteur « Document | Texte ».
    var route: PreviewRoute {
        sourceDocument != nil ? .text : PreviewRouting.route(ext: docRow?.record.ext ?? "")
    }

    /// Le chemin entier, pour l'infobulle de l'en-tête et rien d'autre. Une
    /// copie de Fouine n'en a pas à montrer : son fil d'Ariane est déjà le
    /// sous-titre, et le chemin ne mène qu'au dossier de travail de Fouine.
    var fullPath: String {
        if let sourceDocument { return sourceDocument.breadcrumb }
        if let fileURL { return fileURL.path }
        guard let row = docRow else { return "" }
        return "/" + row.record.relPath
    }

    // MARK: - Chargement

    /// `time` : la seconde où poser la tête de lecture, quand le lien ou la
    /// pastille cliquée en nomme une (lot PV1). `nil` ne l'efface pas si une
    /// demande vient d'être posée pour CETTE page : l'ordre des deux gestes —
    /// changer la sélection, demander un moment — dépend de qui appelle.
    func load(hit: Hit?, roots: [RootStatus], time: Int? = nil) {
        loadTask?.cancel()
        guard let hit else {
            content = .empty; docRow = nil; provenance = nil
            ocrLines = nil; fileURL = nil; loadedKey = nil
            sourceTarget = nil; rereadNotice = nil
            offlineNotice = nil; requestedTime = nil; requestedTimeKey = nil
            mediaPlayhead = nil
            return
        }
        sourceTarget = nil
        rereadNotice = nil
        offlineNotice = nil
        mediaPlayhead = nil
        let key = HitKey(docID: hit.docID, page: hit.page)
        if let time {
            requestedTime = time
            requestedTimeKey = key
        } else if requestedTimeKey != key {
            requestedTime = nil
            requestedTimeKey = nil
        }
        let sameDocument = loadedKey?.docID == hit.docID
        loadedKey = key
        page = hit.page
        if !sameDocument {
            content = .loading
            insideText = ""
        }

        loadTask = Task { [weak self] in
            guard let self else { return }
            let row = try? await self.service.docRow(id: hit.docID)
            if Task.isCancelled { return }
            self.docRow = row
            guard let row else {
                self.content = .unavailable(
                    title: String(localized: "Document not found in the index"),
                    detail: String(localized: "Document \(String(hit.docID)) no longer exists. Run an indexing pass to refresh the list."),
                    actions: [.indexNow])
                return
            }

            // Provenance : une seule interrogation par sélection (cf. StoreService).
            if let meta = try? await self.service.provenance(docID: hit.docID,
                                                             page: hit.page) {
                self.provenance = Provenance(source: meta.source, engine: meta.engine)
            } else {
                self.provenance = Provenance(source: hit.source, engine: .none)
            }
            if Task.isCancelled { return }

            // Boîtes OCR : seulement si la page vient de l'OCR (§5.6). Sur une page
            // native, la couche texte du fichier suffit et fait mieux.
            if hit.source != .native {
                do {
                    self.ocrLines = try await self.service.ocrLayout(docID: hit.docID,
                                                                      page: hit.page)
                } catch {
                    self.ocrLines = nil
                    // Une erreur de base ne se répare par aucun bouton : ne
                    // rien proposer vaut mieux que proposer au hasard.
                    self.content = .unavailable(
                        title: String(localized: "This page cannot be shown"),
                        detail: String(localized: "Fouine could not read where the words are on this scanned page: \(error.localizedDescription)"),
                        actions: [])
                    return
                }
            } else {
                self.ocrLines = nil
            }
            if Task.isCancelled { return }

            await self.resolveFile(row: row, page: hit.page, roots: roots,
                                   reuseDocument: sameDocument)
        }
    }

    private func resolveFile(row: DocRow, page: Int, roots: [RootStatus],
                             reuseDocument: Bool) async {
        let record = row.record
        let rootLabel = record.topFolder
        let ext = record.ext.lowercased()
        let url: URL
        do {
            url = try VolumeResolver.absolutePath(volUUID: record.volUUID,
                                                  relPath: record.relPath)
        } catch {
            fileURL = nil
            // Volume débranché : le texte indexé, lui, est toujours là. On le
            // montre plutôt qu'un panneau vide (audit U4) — seuls « Afficher
            // dans le Finder » et « Ouvrir » restent impossibles, faute de
            // fichier, et la vue les masque.
            if let indexed = await loadPageText(docID: row.id, page: page, ext: ext),
               !Task.isCancelled {
                content = .text(indexed)
                // SANS CETTE PHRASE, le texte nu passait pour l'aperçu normal
                // du document (lot PV1) : une lettre mise en page s'affichait
                // en caractères bruts, sans que rien ne dise que le disque est
                // débranché ni que Fouine montre ce qu'elle avait gardé.
                offlineNotice = String(localized: "The disk holding “\(rootLabel)” is not plugged in. Here is the text Fouine kept.")
                return
            }
            if Task.isCancelled { return }
            // Le geste est de rebrancher le disque — aucun bouton ne le fait.
            // Celui qu'on propose est celui d'APRÈS : resonder les dossiers.
            content = .unavailable(
                title: String(localized: "Volume not mounted"),
                detail: String(localized: "The disk holding “\(rootLabel)” is not plugged in. Plug it back in: results stay searchable without it, only the preview is missing."),
                actions: [.retestRoots])
            return
        }
        fileURL = url

        // Aperçu déjà chargé pour ce document : on ne rouvre pas le PDF, on change
        // seulement de page (piège n°1 : PDFDocument retient tout ce qu'il analyse).
        if reuseDocument, case .pdf = content { return }

        // La voie du format est une décision PURE (lot PV1) : elle vit dans
        // `PreviewRouting`, où un test peut l'interroger sans base ni fichier.
        //
        // UNE COPIE DE FOUINE SE MONTRE EN TEXTE, ET EN TEXTE SEUL (lot AN2) :
        // le mode « Document » dessinait le fichier Markdown brut — en-tête
        // technique, sauts de page, lignes d'images —, c'est-à-dire la cuisine
        // de Fouine au lieu de la carte.
        if DocumentDisplay.source(record.relPath) != nil {
            let indexed = await loadPageText(docID: row.id, page: page, ext: ext)
            if Task.isCancelled { return }
            content = indexed.map(PreviewContent.text)
                ?? Self.unavailableState(url: url, rootLabel: rootLabel,
                                         fallback: String(localized: "unreadable file"),
                                         roots: roots)
            return
        }
        let route = PreviewRouting.route(ext: ext)
        switch route {

        // Le PDF garde `PDFPreviewView` : c'est le seul format dont le rendu
        // fidèle vaut le détour par le fichier (couche texte, boîtes OCR).
        case .pdf:
            let outcome = await Self.openPDF(url: url)
            if Task.isCancelled { return }
            switch outcome {
            case .success(let box): content = .pdf(box)
            case .failure(let message):
                await fallback(row: row, page: page, ext: ext, url: url,
                               rootLabel: rootLabel, reason: message, roots: roots)
            }

        case .image:
            let outcome = await Self.renderPage(url: url, page: page)
            if Task.isCancelled { return }
            switch outcome {
            case .success(let box): content = .image(box)
            case .failure(let message):
                // Une page de docx sans image à rendre, une archive illisible :
                // le texte indexé reste un aperçu utile (audit U4).
                await fallback(row: row, page: page, ext: ext, url: url,
                               rootLabel: rootLabel, reason: message, roots: roots)
            }

        case .media:
            let indexed = await loadPageText(docID: row.id, page: page, ext: ext)
            if Task.isCancelled { return }
            // Le lecteur même sans texte : une page de balises sans
            // transcription reste un enregistrement qu'on veut écouter.
            content = FileManager.default.isReadableFile(atPath: url.path)
                ? .media(url: url, text: indexed)
                : indexed.map(PreviewContent.text)
                    ?? Self.unavailableState(
                        url: url, rootLabel: rootLabel,
                        fallback: String(localized: "unreadable file"), roots: roots)

        case .quickLook, .text:
            let indexed = await loadPageText(docID: row.id, page: page, ext: ext)
            if Task.isCancelled { return }
            // LE TEXTE RESTE LE REPLI, et c'est ce qui garde l'aperçu
            // insensible aux refus d'accès (audit U4) : `isReadableFile` ne
            // demande rien à personne — il rend faux quand la confidentialité
            // barre le fichier, et l'aperçu montre alors ce qu'il a en base.
            if FileManager.default.isReadableFile(atPath: url.path) {
                // NI TEXTE EN BASE, NI RENDU DU SYSTÈME : le Coup d'œil n'en
                // montrerait que l'icône générique du format, ce qui n'apprend
                // rien. L'état explicite du §5.6, lui, dit quoi faire.
                content = indexed == nil && route == .text
                    ? .unsupported(ext)
                    : .quickLook(url: url, text: indexed)
            } else if let indexed {
                content = .text(indexed)
            } else {
                content = Self.unavailableState(
                    url: url, rootLabel: rootLabel,
                    fallback: String(localized: "unreadable file"), roots: roots)
            }
        }
    }

    /// Rendu impossible : le texte indexé plutôt que rien, et l'état explicite
    /// du §5.6 seulement si la base n'a rien non plus.
    private func fallback(row: DocRow, page: Int, ext: String, url: URL,
                          rootLabel: String, reason: String,
                          roots: [RootStatus]) async {
        if let indexed = await loadPageText(docID: row.id, page: page, ext: ext),
           !Task.isCancelled {
            content = .text(indexed)
            return
        }
        if Task.isCancelled { return }
        content = Self.unavailableState(url: url, rootLabel: rootLabel,
                                        fallback: reason, roots: roots)
    }

    /// Le texte indexé de la page, s'il y en a. `nil` = rien en base (document
    /// scanné pas encore OCRisé, page vide) : l'appelant retombe alors sur son
    /// état « aperçu non disponible », qui reste juste dans ce cas-là.
    private func loadPageText(docID: Int64, page: Int,
                              ext: String) async -> PageTextContent? {
        guard let text = try? await service.pageText(docID: docID, page: page),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        // Le bouton « Ouvrir dans … » : décidé par l'EMPLACEMENT du document,
        // le lien d'une note relu dans l'en-tête de son fichier (lot AN2) —
        // l'index ne garde plus cet en-tête, et toutes les pages d'une note ou
        // d'un paquet ont donc le même bouton, la 17ᵉ carte comme la première.
        let relPath = docRow?.record.relPath ?? ""
        let url = fileURL
        let target = await Task.detached(priority: .userInitiated) {
            SourceOpenTarget.resolve(relPath: relPath, fileURL: url)
        }.value
        if let target { sourceTarget = target }
        // Une page indexée AVANT le lot AN2 porte encore les deux commentaires
        // techniques en tête : ils sont retirés à l'affichage, en attendant que
        // la passe suivante relise le fichier.
        let visible = SourceLinks.strippingHeader(text)
        let pages = (try? await service.textPages(docID: docID)) ?? [page]
        let images = await ankiImages(page: page, ext: ext)
        return PageTextContent(text: visible, pages: pages,
                               fromOCR: provenance?.isOCR ?? false,
                               // Une carte, une note sont de la prose : la
                               // chasse fixe du Markdown ne leur apprend rien.
                               monospaced: sourceDocument == nil
                                   && Self.monospacedExtensions.contains(ext),
                               images: images)
    }

    /// Le chemin d'un paquet Anki recopié SOUS le dossier « Anki » des copies,
    /// ou `nil`. Décidé par son EMPLACEMENT, pas par ce que dit le fichier.
    private func ankiRelativePath(ext: String) -> String? {
        guard ext == "md", let document = sourceDocument, document.isAnkiDeck,
              let fileURL else { return nil }
        return (document.folders + [fileURL.lastPathComponent]).joined(separator: "/")
    }

    /// Les images de la carte de la page `page` (lot AN1).
    ///
    /// Les noms sont relus dans le FICHIER recopié, par `MaterializedText.pages`
    /// — la fonction même de l'extracteur, donc la même numérotation, cartes
    /// longues comprises —, puisque l'index n'en garde rien. Les images, elles,
    /// viennent du dossier `collection.media` d'Anki, en lecture : si Anki les a
    /// effacées, la carte s'affiche sans elles. Hors du fil principal : un
    /// paquet de mille cartes se relit en quelques millisecondes, mais se relit.
    private func ankiImages(page: Int, ext: String) async -> [URL] {
        guard let relative = ankiRelativePath(ext: ext), let fileURL else { return [] }
        return await Task.detached(priority: .userInitiated) {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
                  MaterializedText.isMaterialized(text) else { return [] }
            let pages = MaterializedText.pages(text, limit: ExtractLimits().pageSplitChars)
            guard page >= 1, page <= pages.count,
                  let media = AnkiSource().mediaFolder(forCopiedDeck: relative)
            else { return [] }
            return pages[page - 1].images.compactMap {
                AnkiSource.mediaFile(named: $0, in: media)
            }
        }.value
    }

    /// Formats où la disposition du texte porte du sens : balisage, code,
    /// tableaux. Les autres (epub, docx, rtf, djvu, pdf) sont de la prose et se
    /// lisent mieux dans la police de lecture du système.
    private static let monospacedExtensions: Set<String> =
        ["html", "htm", "xml", "md", "markdown", "csv", "json", "txt", "log"]

    /// Le texte de la page affichée, par quelque voie qu'elle se montre
    /// (lot PV1) : c'est lui que le navigateur de pages parcourt, et lui que
    /// « Copier ce texte » copie quand le disque est débranché.
    var pageTextContent: PageTextContent? {
        switch content {
        case .text(let page):            return page
        case .quickLook(_, let page):    return page
        case .media(_, let page):        return page
        default:                         return nil
        }
    }

    /// Change de page SANS repartir du document : le texte vient de la base,
    /// c'est un `SELECT` par rowid. Utilisé par les flèches de l'aperçu texte,
    /// du Coup d'œil et de la transcription d'un enregistrement.
    func goToPage(_ target: Int) {
        guard let current = pageTextContent, let row = docRow,
              current.pages.contains(target) else { return }
        loadTask?.cancel()
        page = target
        rereadNotice = nil
        // Une tête de lecture demandée valait pour la page qu'on quitte.
        requestedTime = nil
        requestedTimeKey = nil
        loadedKey = HitKey(docID: row.id, page: target)
        loadTask = Task { [weak self] in
            guard let self else { return }
            // La provenance est propre à la PAGE : une page peut être native et
            // la suivante OCRisée dans le même document.
            if let meta = try? await self.service.provenance(docID: row.id,
                                                             page: target) {
                self.provenance = Provenance(source: meta.source, engine: meta.engine)
            }
            if Task.isCancelled { return }
            if let loaded = await self.loadPageText(
                docID: row.id, page: target,
                ext: row.record.ext.lowercased()), !Task.isCancelled {
                // La VOIE ne change pas d'une page à l'autre : on ne repasse
                // pas un enregistrement en texte brut parce qu'on a cliqué sur
                // la flèche « page suivante ».
                switch self.content {
                case .quickLook(let url, _): self.content = .quickLook(url: url, text: loaded)
                case .media(let url, _):     self.content = .media(url: url, text: loaded)
                default:                     self.content = .text(loaded)
                }
            }
        }
    }

    /// La tête de lecture, que le lecteur rapporte à chaque seconde.
    func notePlayhead(_ seconds: Int) { mediaPlayhead = seconds }

    /// Demande, depuis la liste des résultats, que la page `key` s'ouvre à ce
    /// moment (lot PV1). Posée AVANT le chargement : `load` la garde quand
    /// c'est bien cette page qui arrive.
    func requestTime(_ seconds: Int, for key: HitKey) {
        requestedTime = seconds
        requestedTimeKey = key
    }

    /// Le moment que porteront la référence et le lien de cette page.
    ///
    /// La tête de lecture d'abord — c'est là qu'est la personne qui cite —,
    /// puis le moment demandé à l'ouverture, et zéro faute des deux.
    var citedTime: Int? {
        guard case .media = content else { return nil }
        return mediaPlayhead ?? requestedTime ?? 0
    }

    /// Le texte de la page, dans le presse-papiers (bandeau « disque
    /// débranché », lot PV1).
    func copyPageText() {
        guard let text = pageTextContent?.text, !text.isEmpty else { return }
        Citation.copy(text)
    }

    /// Distingue « racine indisponible » (le cas du §5.6, qui appelle un geste
    /// utilisateur) d'une simple erreur de lecture du fichier.
    /// `internal` et non `private` : c'est la fonction que `PreviewActionTests`
    /// interroge, et elle est pure — trois entrées, un état en sortie.
    static func unavailableState(url: URL, rootLabel: String,
                                         fallback: String,
                                         roots: [RootStatus]) -> PreviewContent {
        let root = roots.first { $0.label == rootLabel }
        if let root, !root.readable {
            let reason = root.reason ?? String(localized: "read denied")
            return .unavailable(
                title: String(localized: "Folder “\(rootLabel)” unavailable"),
                detail: String(localized: "\(reason)\n\n\(TCCText.guidance)"),
                actions: [.openPrivacySettings, .retestRoots])
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            // Un fichier que l'utilisateur a déplacé n'a RIEN à voir avec une
            // autorisation de confidentialité (A2-11).
            return .unavailable(
                title: String(localized: "File not found"),
                detail: String(localized: "\(url.path)\n\nThe document has been moved, renamed or deleted since the last indexing pass. Run “Index now” to bring the index up to date; the other results stay usable."),
                actions: [.revealExpectedLocation(path: url.path), .indexNow])
        }
        // Le fichier est là et se refuse : c'est bien une histoire de droits.
        return .unavailable(
            title: String(localized: "Preview impossible"),
            detail: String(localized: "\(url.lastPathComponent) — \(fallback)"),
            actions: [.openPrivacySettings, .retestRoots])
    }

    private static func openPDF(url: URL) async -> Loaded<PDFDocumentBox> {
        await Task.detached(priority: .userInitiated) { () -> Loaded<PDFDocumentBox> in
            // Lecture EFFECTIVE avant PDFKit : c'est elle qui révèle un refus TCC,
            // là où PDFDocument(url:) rendrait un nil muet (piège n°2).
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                _ = try handle.read(upToCount: 1)
            } catch {
                return .failure((error as NSError).localizedDescription)
            }
            guard let document = PDFDocument(url: url) else {
                return .failure(
                    String(localized: "Unreadable PDF: PDFDocument(url:) returned nil"))
            }
            return .success(PDFDocumentBox(document: document, url: url))
        }.value
    }

    private static func renderPage(url: URL, page: Int) async -> Loaded<ImageBox> {
        await Task.detached(priority: .userInitiated) { () -> Loaded<ImageBox> in
            do {
                let cg = try FouinePageRenderer().render(
                    url: url, page: page, dpi: FouinePageRenderer.defaultDPI)
                let image = NSImage(cgImage: cg,
                                    size: NSSize(width: cg.width, height: cg.height))
                return .success(ImageBox(image: image))
            } catch {
                return .failure(ErrorText.describe(error))
            }
        }.value
    }

    // MARK: - Actions

    func revealInFinder() {
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    /// « Ouvrir le document » : dans son application, et À LA PAGE TROUVÉE
    /// quand cette application sait y aller (lot OP1).
    ///
    /// Le geste ne change pas — un bouton, la même place, le même lecteur que
    /// le double-clic du Finder. Ce qui change est ce qu'on lui dit en chemin.
    /// La décision est pure et vit dans `ExternalOpen` ; il ne reste ici que
    /// LaunchServices, qui seul sait quel lecteur ouvrira ce fichier.
    func openExternally() {
        guard let fileURL else { return }
        ExternalOpen.perform(fileURL: fileURL, page: page)
    }

    /// Rouvre la note dans SON application (lot INT-F4).
    ///
    /// C'est ce que remplace « Afficher dans le Finder » pour une note : le
    /// fichier Markdown que Fouine a recopié n'intéresse personne — ce que
    /// l'utilisateur veut, c'est sa note dans Notes ou dans Bear, là où il peut
    /// la modifier.
    func openInSourceApp() {
        guard let sourceTarget else { return }
        NSWorkspace.shared.open(sourceTarget.url)
    }

    // MARK: - Relire cette page (lot BR1, constat PR-24)

    /// La page affichée a-t-elle été LUE SUR UNE IMAGE ? C'est la seule qui
    /// puisse être relue : une page dont le texte vient du document n'a pas
    /// d'image, et une page transcrite n'en a pas davantage — `Provenance.isOCR`
    /// fait déjà cette distinction pour les cadres de surlignage (INT-F3).
    ///
    /// Le geste n'apparaît QUE dans ce cas : proposer « Relire cette page » sur
    /// une page native promettrait un travail que le cœur refuse.
    var canRereadPage: Bool { docRow != nil && (provenance?.isOCR ?? false) }

    /// Remet la page affichée en file de reconnaissance, puis dit ce qui s'est
    /// passé, sous l'aperçu.
    ///
    /// RIEN NE SE LANCE ICI : la relecture aura lieu à la prochaine lecture des
    /// scans (mise à jour automatique, ou « Lire les scans »), et la phrase le
    /// dit. Démarrer Vision depuis un clic dans l'aperçu prendrait le verrou
    /// d'écriture au milieu d'une consultation.
    func rereadCurrentPage() {
        guard let docID = docRow?.id else { return }
        let target = page
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.service.requeueOCRPage(docID: docID, page: target)
                // La MÊME phrase que la page vienne d'entrer en file ou qu'elle
                // y fût déjà : dans les deux cas elle sera relue, et distinguer
                // les deux n'apprendrait rien à qui vient de cliquer.
                //
                // SANS PROMESSE (IX2) : la relecture passe par le même moteur,
                // avec les mêmes réglages, et rend le même texte — sauf si la
                // langue de la page vient d'être cochée. La phrase le dit.
                self.rereadNotice = String(localized: "This page will be read again next time the scans are read. Its text will only change if you have just ticked its language in Settings ▸ Indexing.")
            } catch {
                // Le verrou d'écriture est le refus ATTENDU (une passe tourne) :
                // il a sa phrase, qui dit le geste — attendre un instant. Tout
                // le reste est un accident, et on ne fait pas lire à quelqu'un
                // le message anglais du cœur.
                self.rereadNotice = WriteLock.isBusy(error)
                    ? String(localized: "The index is being updated. Try again in a moment.")
                    : String(localized: "Fouine could not schedule this page to be read again.")
            }
        }
    }

    // MARK: - Citer cette page (lot INT-L1)

    /// Le lien `fouine://` de la page affichée. `nil` quand aucun document
    /// n'est chargé : il n'y a alors rien à citer.
    ///
    /// `fileURL` est nul quand le volume est débranché, et l'aperçu montre
    /// alors le texte indexé (audit U4) : la page reste citable, sous la forme
    /// de repli `doc`.
    var pageLink: URL? {
        guard let docRow else { return nil }
        return DeepLink.link(absolutePath: fileURL?.path, docID: docRow.id,
                             page: page, time: citedTime)
    }

    /// Les deux lignes à coller : « nom du fichier, page N » puis le lien.
    ///
    /// UNE PAGE D'ENREGISTREMENT SE CITE PAR SON MOMENT (lot PV1) : « page 2 »
    /// d'un cours de deux heures ne renvoie personne nulle part, « 12:40 » si.
    func copyReference() {
        guard let pageLink else { return }
        if let time = citedTime {
            Citation.copy(Citation.reference(fileName: title,
                                             timestamp: TranscriptMarkers.timestamp(time),
                                             link: pageLink))
        } else {
            Citation.copy(Citation.reference(fileName: title, page: page,
                                             unit: pageUnit, link: pageLink))
        }
    }

    func copyLink() {
        guard let pageLink else { return }
        Citation.copy(Citation.linkOnly(pageLink))
    }
}
