// ExtractorRegistry.swift — les extensions du §5.3, point d'entrée unique de
// FouineExtract.
// Propriété : A-Ingest.
//
// NOM PUBLIC IMPOSÉ : `DefaultExtractorRegistry` — la CLI (A-Core) s'y câble à
// l'intégration sans avoir à relire ce module.

import Foundation
import FouineCore

public final class DefaultExtractorRegistry: ExtractorRegistry {
    /// Union du §5.3, amendé le 08/09/2026 (INT-F1) : `xls` et `ppt` ne sont
    /// plus refusés d'office, les courriels ne se limitent plus à `.eml`, et
    /// les fichiers techniques (code source, XML) entrent. Amendé le même jour
    /// (INT-F2) : Illustrator, Sketch, Figma et InDesign. Les IMAGES restent
    /// hors de cette union — elles n'entrent que sous `extract.images`, et
    /// c'est `imageExtensions` qui les porte.
    ///
    /// La liste est CALCULÉE à partir des extracteurs, et non retapée : c'est
    /// la seule façon d'éviter qu'une extension existe dans un extracteur sans
    /// exister ici (le crawler ne la verrait jamais) ou l'inverse (le registre
    /// promettrait un extracteur absent).
    public static let supportedExtensions: Set<String> =
        PlainTextExtractor.supportedExtensions
            .union(SubtitleExtractor.supportedExtensions)
            .union(NotebookExtractor.supportedExtensions)
            .union(PDFExtractor.supportedExtensions)
            .union(RichTextExtractor.supportedExtensions)
            .union(OOXMLExtractor.supportedExtensions)
            .union(LegacyExcelExtractor.supportedExtensions)
            .union(LegacyPowerPointExtractor.supportedExtensions)
            .union(HTMLExtractor.supportedExtensions)
            .union(XMLDocumentExtractor.supportedExtensions)
            .union(EPUBExtractor.supportedExtensions)
            .union(ComicArchiveExtractor.supportedExtensions)
            .union(DjvuExtractor.supportedExtensions)
            .union(IWorkExtractor.supportedExtensions)
            .union(EMLExtractor.supportedExtensions)
            .union(MailboxExtractor.supportedExtensions)
            .union(IllustratorExtractor.supportedExtensions)
            .union(SketchExtractor.supportedExtensions)
            .union(DesignPreviewExtractor.supportedExtensions)

    private let table: [String: any TextExtractor]

    public init(extractImages: Bool? = nil,
                extractMedia: Bool? = nil,
                media: MediaOptions? = nil) {
        func armed(_ variable: String) -> Bool {
            guard let env = ProcessInfo.processInfo.environment[variable] else { return false }
            return ["1", "true", "yes", "on"].contains(env.lowercased())
        }
        let activeExtractImages = extractImages ?? armed("FOUINE_EXTRACT_IMAGES")
        let activeExtractMedia = extractMedia ?? armed("FOUINE_EXTRACT_MEDIA")
        let mediaOptions = media ?? MediaOptions.fromEnvironment()

        var table: [String: any TextExtractor] = [:]
        func register(_ extractor: any TextExtractor, _ exts: Set<String>) {
            for ext in exts { table[ext.lowercased()] = extractor }
        }
        register(PlainTextExtractor(), PlainTextExtractor.supportedExtensions)
        register(SubtitleExtractor(), SubtitleExtractor.supportedExtensions)
        register(NotebookExtractor(), NotebookExtractor.supportedExtensions)
        register(PDFExtractor(), PDFExtractor.supportedExtensions)
        register(RichTextExtractor(), RichTextExtractor.supportedExtensions)
        register(OOXMLExtractor(), OOXMLExtractor.supportedExtensions)
        register(LegacyExcelExtractor(), LegacyExcelExtractor.supportedExtensions)
        register(LegacyPowerPointExtractor(),
                 LegacyPowerPointExtractor.supportedExtensions)
        register(HTMLExtractor(), HTMLExtractor.supportedExtensions)
        register(XMLDocumentExtractor(), XMLDocumentExtractor.supportedExtensions)
        register(EPUBExtractor(), EPUBExtractor.supportedExtensions)
        register(ComicArchiveExtractor(), ComicArchiveExtractor.supportedExtensions)
        register(DjvuExtractor(), DjvuExtractor.supportedExtensions)
        register(IWorkExtractor(), IWorkExtractor.supportedExtensions)
        register(EMLExtractor(), EMLExtractor.supportedExtensions)
        register(MailboxExtractor(), MailboxExtractor.supportedExtensions)
        register(IllustratorExtractor(), IllustratorExtractor.supportedExtensions)
        // Sketch, Figma et InDesign sont inscrits DANS TOUS LES CAS : leur
        // refus nommé (« exportez en PDF ») vaut mieux que « format non pris en
        // charge », et il faut un extracteur pour le porter. Seul leur APERÇU
        // dépend du réglage, d'où l'injection.
        register(SketchExtractor(extractImages: activeExtractImages),
                 SketchExtractor.supportedExtensions)
        register(DesignPreviewExtractor(extractImages: activeExtractImages),
                 DesignPreviewExtractor.supportedExtensions)
        if activeExtractImages {
            register(ImageExtractor(), ImageExtractor.supportedExtensions)
        }
        // Sons et vidéos : inscription CONDITIONNELLE, comme les images, et
        // pour la même raison (INT-F3). Les inscrire toujours ferait entrer une
        // bibliothèque musicale entière dans l'index de qui cherchait ses cours.
        if activeExtractMedia {
            register(MediaExtractor(options: mediaOptions),
                     MediaExtractor.supportedExtensions)
        }
        self.table = table
    }

    /// Extensions des images seules, actives sous le réglage `extract.images` (audit E4).
    public static let imageExtensions: Set<String> = ImageExtractor.supportedExtensions

    /// Extensions des sons et vidéos, actives sous `extract.media` (INT-F3).
    /// HORS de `supportedExtensions`, exactement comme les images.
    public static let mediaExtensions: Set<String> = MediaExtractor.supportedExtensions

    /// Les extensions dont l'extracteur FABRIQUE ses pages en découpant du texte
    /// (`TextPagination.paginate`), et qui n'ont donc aucun plafond naturel de
    /// pages — contrairement au PDF, au DjVu, au CBZ, aux images et aux médias,
    /// dont le nombre de pages est celui du fichier.
    ///
    /// La liste est CALCULÉE depuis les extracteurs concernés, comme
    /// `supportedExtensions` : la retaper reviendrait à la voir se périmer au
    /// premier format ajouté.
    public static let repaginatedExtensions: Set<String> =
        PlainTextExtractor.supportedExtensions
            .union(SubtitleExtractor.supportedExtensions)
            .union(NotebookExtractor.supportedExtensions)
            .union(RichTextExtractor.supportedExtensions)
            .union(OOXMLExtractor.supportedExtensions)
            .union(LegacyExcelExtractor.supportedExtensions)
            .union(LegacyPowerPointExtractor.supportedExtensions)
            .union(HTMLExtractor.supportedExtensions)
            .union(XMLDocumentExtractor.supportedExtensions)
            .union(EPUBExtractor.supportedExtensions)
            .union(EMLExtractor.supportedExtensions)
            .union(MailboxExtractor.supportedExtensions)

    /// L'extracteur d'une extension, PLAFONNÉ en nombre de pages quand le format
    /// est re-paginé (MO-01).
    ///
    /// Le plafond est posé ICI, dans l'enveloppe, et non dans chacun des douze
    /// extracteurs : `IndexPass` demande son extracteur au registre puis
    /// l'appelle directement, et un plafond posé dans `extract(url:limits:)`
    /// seul n'aurait jamais servi en production.
    public func extractor(for ext: String) -> (any TextExtractor)? {
        guard let extractor = table[ext.lowercased()] else { return nil }
        guard Self.repaginatedExtensions.contains(ext.lowercased()) else {
            return extractor
        }
        return PageCappedExtractor(inner: extractor)
    }

    /// Raccourci de service : extrait, ou lève l'erreur du §4.2 que les pipelines
    /// mappent en `.failed` / `.skipped` via `ExtractOutcome`.
    public func extract(url: URL, limits: ExtractLimits = ExtractLimits())
        throws -> ExtractionResult {
        let ext = url.pathExtension.lowercased()
        guard let extractor = extractor(for: ext) else {
            throw FouineError.unsupported(ext: ext)
        }
        return try extractor.extract(url: url, limits: limits)
    }
}

/// Enveloppe qui borne le NOMBRE de pages d'un format re-paginé (MO-01).
struct PageCappedExtractor: TextExtractor {
    /// Jamais inscrite au registre par ses extensions : elle enveloppe un
    /// extracteur déjà inscrit, et n'a donc pas d'extensions à elle.
    static let supportedExtensions: Set<String> = []

    let inner: any TextExtractor

    func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        PageCap.apply(try inner.extract(url: url, limits: limits),
                      limit: limits.maxSplitPages)
    }
}

/// La règle du plafond, PURE — c'est elle que le test éprouve.
enum PageCap {
    /// Garde les pages 1…`limit`, pose `pageCount = limit` et une note
    /// `truncated` qui dit ce qui a été jeté. Le document reste INDEXÉ : un
    /// `.docx` de 13 108 pages de « A » est presque toujours un accident
    /// (export automatique, fichier corrompu) et son début a la même valeur que
    /// n'importe quel autre — c'est sa queue qui n'en a aucune.
    static func apply(_ result: ExtractionResult, limit: Int) -> ExtractionResult {
        guard limit > 0, result.pageCount > limit else { return result }
        var meta = result.meta
        meta["truncated"] =
            "pages beyond \(limit) dropped (\(result.pageCount) pages)"
        return ExtractionResult(
            pages: result.pages.filter { $0.page <= limit },
            pageCount: limit,
            ocrCandidates: result.ocrCandidates.filter { $0 <= limit },
            meta: meta)
    }
}

/// Classement d'un refus d'extraction : `.skipped` ou `.failed`, et motif exact
/// écrit dans `docs.err`. RÈGLE UNIQUE — la CLI, l'agent et l'app l'appellent au
/// lieu d'en garder chacun une copie (recette A7 : la copie de l'app avait perdu
/// le cas djvu et écrivait « format non pris en charge » aux 5 fichiers .djvu).
public enum ExtractOutcome {

    /// Motif de `docs.err` pour un refus `.unsupported` (SPEC §5.3). Les
    /// extracteurs exposent la chaîne imposée : ne PAS l'écraser par le libellé
    /// générique (bogue 4 — `djvu|format non pris en charge` au lieu de
    /// `djvu: djvulibre absent`).
    public static func skipReason(ext: String) -> String {
        let lower = ext.lowercased()
        if DjvuExtractor.supportedExtensions.contains(lower) {
            return DjvuExtractor.reason           // « djvu: djvulibre absent »
        }
        // Conteneurs étrangers (mkv, avi, wmv, webm, ogg) : même règle que
        // djvu ci-dessus, et pour la même raison — c'est l'extracteur qui
        // décide de lever `.unsupported`, et il ne le fait QUE quand ffmpeg
        // manque vraiment. Vérifier une seconde fois la présence de l'outil
        // ici rendrait le motif dépendant de l'instant où on le compose.
        if MediaDecoder.ffmpegContainers.contains(lower) {
            return MediaExtractor.ffmpegMissingReason(lower)
        }
        return "unsupported format"
    }

    /// Refus qui NE SONT PAS des échecs : le document est lisible, mais il n'y
    /// a rien à en indexer (ou rien qu'on puisse indexer sans la clé de
    /// déchiffrement). Ils tombent en `.skipped`, jamais en `.failed` — un
    /// classeur protégé par mot de passe n'est pas un classeur cassé, et la
    /// carte « documents illisibles » de l'app ne doit pas l'y ranger.
    public static let skippedReasons: Set<String> = [
        ImageExtractor.belowFloorReason,
        PlainTextExtractor.minifiedReason,
        XMLDocumentExtractor.noTextReason,
        MailboxExtractor.notAMailboxReason,
        LegacyExcelExtractor.passwordReason,
        LegacyExcelExtractor.noWorkbookReason,
        LegacyPowerPointExtractor.passwordReason,
        LegacyPowerPointExtractor.noDocumentStreamReason,
        IllustratorExtractor.noPDFLayerReason,
        SketchExtractor.noDocumentReason,
        DesignPreviewExtractor.figNoTextReason,
        DesignPreviewExtractor.inddNoTextReason,
        MediaExtractor.noMetadataReason,
        SpeechTranscriber.notAuthorisedReason,
    ]

    /// Refus de la famille « médias » qui portent une VARIABLE (les langues
    /// demandées, la durée) et ne peuvent donc pas figurer dans l'ensemble
    /// ci-dessus. Ce sont des `.skipped` au même titre : un enregistrement dont
    /// on n'a pas la langue de dictée n'est pas un fichier cassé.
    ///
    /// « no metadata » par PRÉFIXE (TR1) : le motif exact, et ses formes à
    /// parenthèse qui disent pourquoi une transcription allumée n'a rien écrit
    /// (« no metadata (no audio track) », « … (longer than 120 min) »…).
    static func isMediaSkip(_ message: String) -> Bool {
        message.hasPrefix(SpeechTranscriber.notInstalledPrefix)
            || message.hasPrefix(MediaExtractor.noMetadataReason)
    }

    /// Motif de `docs.err` si l'erreur relève de `.skipped` — les deux cas que le
    /// §4.2 documente comme tels (`DocState.skipped` : « trop gros, format non
    /// pris en charge ») —, `nil` si le document doit passer en `.failed`.
    /// `fileTooLarge` tombait jusqu'ici en `.failed` dans les trois pipelines
    /// (A11.3).
    public static func skipReason(for error: FouineError) -> String? {
        switch error {
        case .unsupported(let ext):     return skipReason(ext: ext)
        case .fileTooLarge(let bytes):  return "file too large (\(bytes) B)"
        // Les deux planchers d'image portent leur MESURE (« …: 100x100 px »,
        // « …: 2048 bytes », constat C2-02) : un ensemble exact ne peut pas les
        // contenir, et une vignette refusée serait comptée comme un ÉCHEC.
        // La suite sans blanc porte sa longueur (EX2) : par préfixe aussi.
        case .extraction(let msg) where skippedReasons.contains(msg)
                                    || isMediaSkip(msg)
                                    || PlainTextExtractor.isDataDump(msg)
                                    || ImageExtractor.isBelowFloor(msg):
            return msg
        default:                        return nil
        }
    }
}
