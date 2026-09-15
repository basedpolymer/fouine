// UnreadableDocumentsModel.swift — « Documents que Fouine n'a pas pu lire »
// (F10, UX-16). Propriété : A-App.
//
// POURQUOI CE FICHIER EXISTE. `stats()` annonce depuis toujours un nombre de
// documents en échec, et l'index de production en porte 22. Jusqu'ici, le seul
// moyen de savoir LESQUELS était d'ouvrir le journal d'indexation : 200 ko de
// phrases anglaises destinées à un dépanneur. Quelqu'un qui ne retrouve pas un
// document n'a aucun moyen d'apprendre que Fouine l'a rencontré, l'a refusé, et
// pour quelle raison.
//
// DEUX MORCEAUX, ET LA SÉPARATION EST LE POINT :
//   · `UnreadableReason` — la FAMILLE d'un échec, déduite du motif brut. Pur,
//     sans langue, testé sur les motifs que `FouineExtract`, `FouineCrawl` et
//     `FouineIndex` écrivent réellement dans `docs.err`.
//   · `UnreadableDocumentsModel` — la liste, lue hors du fil principal.
//
// LA RÉSERVE, ET ELLE EST ASSUMÉE. `LocalizedText.swift` pose une règle : rien
// dans l'app ne lit une phrase venue du cœur pour en déduire quoi que ce soit.
// Ici, on n'a pas le choix — `docs.err` est un TEXTE en base, écrit il y a
// peut-être des mois par une version antérieure, et il n'existe aucune colonne
// qui porterait le cas d'erreur. La classification est donc une
// reconnaissance de motifs, faite au mieux, et son échec est PRÉVU : un motif
// inconnu rend `nil`, et la fenêtre affiche alors le motif brut plutôt que
// d'inventer une phrase fausse. Si un jour `docs` gagne une colonne de cause,
// c'est `classify` qui disparaît, pas le reste.

import Foundation
import SwiftUI
import FouineCore

/// La famille d'un échec de lecture. Sans langue : le texte est dans
/// `UnreadableReasonText`.
enum UnreadableReason: String, CaseIterable, Sendable {
    /// Format qu'aucun extracteur ne prend (`unsupported format[: .ext]`).
    case unsupportedFormat
    /// `.doc`, `.xls`, `.ppt` d'avant 2007 (`unsupported binary OLE format`).
    case legacyOfficeFormat
    /// Un outil externe manque — aujourd'hui djvulibre, et lui seul
    /// (jeton `missing-tool:` du cœur).
    case missingTool
    /// Pages / Numbers / Keynote enregistré sans aperçu QuickLook.
    case iWorkWithoutPreview
    /// Au-dessus du plafond de taille.
    case fileTooLarge
    /// Trop de pages pour le rowid structuré (`document too long: …`).
    case tooManyPages
    /// Image sous le plancher de DIMENSIONS : rien de lisible à y chercher.
    case imageTooSmall
    /// Fichier image sous le plancher de POIDS (C2-02). Distinct du précédent :
    /// dire « trop petite » d'une page A4 bien compressée envoyait chercher une
    /// image qui n'existe pas.
    case imageFileTooLight
    /// Document numérisé sans couche texte — aujourd'hui un DjVu (C2-09).
    case scanWithoutTextLayer
    /// La reconnaissance vocale n'a rien rendu sur une piste qui dure (C2-05).
    case transcriptionEmpty
    /// La reconnaissance vocale s'est tue en pleine fenêtre (BT2).
    case transcriptionStopped
    /// iCloud / File Provider : le fichier n'est pas encore sur ce Mac.
    case notDownloaded
    /// PDF verrouillé par un mot de passe.
    case passwordProtected
    /// macOS a refusé la lecture.
    case readDenied
    /// Le fichier n'était plus là au moment de la lecture.
    case fileMissing
    /// Délai de garde dépassé (ouverture PDF, boucle de pages, outil externe).
    case tookTooLong
    /// Fichier abîmé : l'analyseur a rendu la main sans rien.
    case damagedFile
    /// Les pages scannées ont résisté à trois tentatives de reconnaissance.
    case scannedPagesUnreadable
    /// Lisible, mais rien à y chercher : source minifiée, XML sans texte
    /// (lot INT-F1).
    case nothingToIndex
    /// Un `.txt`, `.log`, `.json`… qui porte une suite de 2 000 caractères sans
    /// un blanc : un export de données, pas un texte (EX2).
    case dataDump
    /// Un `.mbox` qui ne contient aucun message (lot INT-F1).
    case notAMailbox
    /// Enregistrement sans titre ni description, lu pendant que la
    /// transcription était éteinte (`no metadata` exact, TR1).
    case recordingNotWrittenDown
    /// Enregistrement sans titre ni description, plus long que la durée
    /// maximale mise par écrit (`no metadata (longer than N min)`, TR1).
    case recordingTooLong
}

extension UnreadableReason {

    /// La famille d'un motif brut, ou `nil` s'il n'en relève d'aucune.
    ///
    /// L'ORDRE DES TESTS COMPTE et n'est pas alphabétique : « unsupported
    /// binary OLE format » contient « unsupported », « unreadable PDF »
    /// contient « unreadable ». Le plus spécifique passe d'abord ; le plus
    /// général ferme la marche.
    static func classify(_ raw: String?) -> UnreadableReason? {
        guard let raw, !raw.isEmpty else { return nil }
        // Le jeton du cœur, avant toute reconnaissance de phrase : c'est le
        // seul repère STRUCTURÉ que `docs.err` porte (constat A3-05), et il
        // survivra à une réécriture des phrases anglaises.
        if ExternalTool.missingTool(inSkipReason: raw) != nil { return .missingTool }

        let text = raw.lowercased()
        func has(_ needle: String) -> Bool { text.contains(needle) }

        if has("binary ole format") { return .legacyOfficeFormat }
        if has("quicklook preview") { return .iWorkWithoutPreview }
        // Les refus nommés du lot INT-F1 (`ExtractOutcome.skippedReasons`).
        // « no text » se compare en entier : c'est un motif de deux mots qu'une
        // autre phrase pourrait contenir par hasard.
        if has("minified source") || text == "no text" { return .nothingToIndex }
        // `no readable text: 48213-character run without a space — data dump?`
        // (EX2). La fin de phrase et non le début : « indd: no readable text —
        // export as PDF or IDML » commence presque pareil et dit autre chose.
        if has("-character run without a space") { return .dataDump }
        // Un `.djvu` est par construction une page NUMÉRISÉE : sans couche
        // texte, le motif brut (« extraction: djvu: no text layer (…) »)
        // s'affichait tel quel, en anglais, dans la fenêtre française (C2-09).
        if has("no text layer") { return .scanWithoutTextLayer }
        if has("speech recognition returned nothing") { return .transcriptionEmpty }
        if has("speech recognition stopped answering") { return .transcriptionStopped }
        // Les formes de « no metadata » (TR1), de la plus spécifique à la plus
        // générale. Le texte EXACT : lu transcription éteinte, le geste est de
        // l'allumer. Une parenthèse : elle était allumée — trop long (relever
        // la durée maximale), ou rien à écouter (pas de son, durée inconnue,
        // rien de dit).
        if text == "no metadata" { return .recordingNotWrittenDown }
        if text.hasPrefix("no metadata (longer than") { return .recordingTooLong }
        if text.hasPrefix("no metadata (") { return .nothingToIndex }
        if has("not a mailbox") { return .notAMailbox }
        if has("ole container without") { return .damagedFile }
        if has("password-protected") || has("document is locked") {
            return .passwordProtected
        }
        if has("not downloaded") { return .notDownloaded }
        // « file too large » (le plancher du §4.2), mais aussi les deux
        // plafonds d'archive : « uncompressed entry too large », « output too
        // large ». Trois phrases, un seul geste — le fichier est trop gros.
        if has("file too large") || has("entry too large")
            || has("output too large") { return .fileTooLarge }
        if has("document too long") { return .tooManyPages }
        // Deux planchers, deux gestes (C2-02) : le poids d'abord, il est le
        // plus spécifique des deux motifs.
        if has("below the ocr weight floor") { return .imageFileTooLight }
        if has("below the ocr size floor") { return .imageTooSmall }
        if has("gave up after") { return .scannedPagesUnreadable }
        if has("deadline exceeded") || has("did not return within") {
            return .tookTooLong
        }
        // « Permission denied » / « Operation not permitted » viennent de
        // `strerror` et sont donc en anglais quelle que soit la langue du
        // système ; `read denied` est la phrase du cœur pour un dossier refusé.
        if has("permission denied") || has("operation not permitted")
            || has("read denied") || has("unreadable root") { return .readDenied }
        if has("no such file or directory") { return .fileMissing }
        if has("unsupported format") { return .unsupportedFormat }
        if has("returned nil") || has("mojibake") || has("unrecognized encoding")
            || has("unrecognised encoding") { return .damagedFile }
        return nil
    }
}

/// Une ligne de la fenêtre : ce qui s'affiche, et de quoi ouvrir le Finder.
struct UnreadableDocument: Identifiable, Equatable {
    let id: Int64
    /// Nom du fichier, seul — le chemin complet reste dans l'infobulle.
    let fileName: String
    /// Étiquette du dossier surveillé (`docs.top_folder`), le premier repère.
    let folder: String
    /// Chemin RELATIF, pour l'infobulle. Jamais affiché en clair (public visé).
    let relPath: String
    let ext: String
    let modified: Date
    /// Motif brut de `docs.err`, tel qu'il est en base.
    let rawReason: String?
    /// Famille reconnue, `nil` = motif inconnu (on montrera `rawReason`).
    let reason: UnreadableReason?
    /// Chemin absolu, quand le volume est monté : sans lui, « Afficher dans le
    /// Finder » ne peut rien faire et le bouton ne s'affiche pas.
    let fileURL: URL?

    init(listing: DocumentListing) {
        id = listing.id
        fileName = (listing.relPath as NSString).lastPathComponent
        folder = listing.topFolder
        relPath = listing.relPath
        ext = listing.ext.lowercased()
        modified = Date(timeIntervalSince1970: listing.mtime)
        rawReason = listing.err
        reason = UnreadableReason.classify(listing.err)
        // `try?` : un volume débranché n'est pas une erreur à signaler ici —
        // la ligne reste utile, seul le bouton Finder disparaît.
        fileURL = try? VolumeResolver.absolutePath(volUUID: listing.volUUID,
                                                   relPath: listing.relPath)
    }
}

@MainActor
final class UnreadableDocumentsModel: ObservableObject {

    /// `nil` = pas encore lu (la fenêtre affiche « Recherche… »), `[]` = lu et
    /// vide. Les distinguer est ce qui évite d'annoncer « rien à signaler »
    /// pendant les 200 ms où la lecture n'a pas encore rendu la main.
    @Published private(set) var documents: [UnreadableDocument]?
    @Published private(set) var errorText: String?
    @Published private(set) var isLoading = false

    /// Garde-fou d'affichage. Une liste plus longue ne se parcourt pas à l'œil,
    /// et la fenêtre le dit alors en toutes lettres plutôt que de faire semblant.
    static let displayLimit = 500

    private let service: StoreService

    init(service: StoreService) { self.service = service }

    /// La lecture est-elle tronquée ? (Le total, lui, vient de `stats()`.)
    var isTruncated: Bool { (documents?.count ?? 0) >= Self.displayLimit }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let rows = try await service.unreadableDocuments(
                limit: Self.displayLimit)
            documents = rows.map(UnreadableDocument.init(listing:))
            errorText = nil
        } catch {
            // Une base illisible ne doit pas laisser la fenêtre muette : on
            // garde ce qu'on avait et on dit ce qui s'est passé.
            errorText = ErrorText.describe(error)
            if documents == nil { documents = [] }
        }
    }
}
