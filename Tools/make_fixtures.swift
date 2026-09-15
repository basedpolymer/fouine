#!/usr/bin/env swift
// make_fixtures.swift — fabrique le CORPUS DE FIXTURES VERSIONNÉ (audit E5).
// Propriété : A-Recette.
//
//     swift Tools/make_fixtures.swift [dossier]
//     make fixtures                                 (dossier = Tests/Fixtures/corpus)
//
// ═══ POURQUOI CE FICHIER EXISTE, ET POURQUOI SES SORTIES SONT COMMITÉES ═════
//
// « Aucune fixture binaire versionnée » (audit D12/M23) : jusqu'ici, TOUT ce
// que la recette d'intégration savait faire sur un vrai document dépendait de
// `Tests/Fixtures/paths.json`, gitignoré, qui désigne le corpus PERSONNEL du
// mainteneur. Sur toute autre machine — un contributeur, un runner GitHub —
// ces tests se sautaient en vert. C'est la définition d'un projet qu'on ne peut
// pas contribuer (audit E5 : « condition de toute contribution »).
//
// Deux règles, tirées de ce constat :
//
//   1. LES FICHIERS GÉNÉRÉS SONT DANS LE DÉPÔT. Un `git clone` + `make test`
//      doit exercer chaque format du registre d'extraction sans rien lancer
//      d'autre. Les tests ne DOIVENT PAS appeler ce générateur : ils lisent
//      `Tests/Fixtures/corpus/` et son `manifest.json`, point.
//
//   2. LE GÉNÉRATEUR EST VERSIONNÉ QUAND MÊME. Une fixture binaire qu'on ne
//      sait plus refabriquer est une fixture qu'on n'ose plus corriger. Ajouter
//      un terme témoin, une page, un format : on édite ce fichier, on relance
//      `make fixtures`, on commite le tout.
//
// ═══ CE QU'IL N'EST PAS ═════════════════════════════════════════════════════
//
// Il n'est PAS reproductible à l'octet : CoreGraphics estampille chaque PDF
// d'une date de création, et `zip` d'une date de modification. Deux exécutions
// donnent des fichiers ÉQUIVALENTS (même texte, mêmes pages, mêmes termes
// témoins), pas identiques. `manifest.json` décrit donc le CONTENU attendu —
// termes, pages, provenance — et jamais une empreinte : c'est ce contenu que
// les tests vérifient, et il survit à une régénération.
//
// ═══ DÉPENDANCES ═══════════════════════════════════════════════════════════
//
// macOS et rien d'autre : Foundation, CoreGraphics, CoreText, ImageIO,
// /usr/bin/zip. Pas de Python (le dépôt en a déjà deux, ce n'est pas une raison
// pour en ajouter un troisième sur le chemin d'une contribution). djvulibre est
// FACULTATIF : sans lui, la fixture .djvu n'est pas produite, le manifeste le
// dit, et le test se saute en indiquant `brew install djvulibre`.

import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
// AVFoundation : seulement pour la cible « media » (lot INT-F3).
import AVFoundation

// MARK: - Sortie

let arguments = CommandLine.arguments

/// La racine du paquet, déduite de l'emplacement de CE fichier.
let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()      // Tools
    .deletingLastPathComponent()      // racine

/// CIBLE « media » (lot INT-F3) : `swift Tools/make_fixtures.swift media`.
///
/// Les sons et les vidéos ne vont PAS dans le corpus de recette et n'entrent
/// pas dans son manifeste — ils sont rangés à part, sous `Tests/Fixtures/media`.
/// Raison, la même que pour les images (INT-F2) : la famille est inscrite sous
/// un réglage ÉTEINT par défaut, que `Recette.makeIndexedCorpus` n'allume pas ;
/// une fixture média versionnée dans `corpus/` ne serait jamais indexée, et les
/// comptes du manifeste tomberaient faux.
let mediaMode = arguments.count > 1 && arguments[1] == "media"

let outputDirectory: URL = {
    if mediaMode {
        if arguments.count > 2 {
            return URL(fileURLWithPath: arguments[2]).standardizedFileURL
        }
        return packageRoot.appendingPathComponent("Tests/Fixtures/media")
    }
    if arguments.count > 1 {
        return URL(fileURLWithPath: arguments[1]).standardizedFileURL
    }
    // Défaut : Tests/Fixtures/corpus.
    return packageRoot.appendingPathComponent("Tests/Fixtures/corpus")
}()

let fm = FileManager.default

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make_fixtures : \(message)\n".utf8))
    exit(1)
}

// MARK: - Briques

/// Un répertoire de travail jetable.
func temporaryDirectory(_ label: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("fouine-mkfix-\(label)-\(UUID().uuidString)",
                                isDirectory: true)
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Premier exécutable `name` du PATH, nil sinon.
func which(_ name: String) -> URL? {
    let path = ProcessInfo.processInfo.environment["PATH"]
        ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
    for directory in path.split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(directory))
            .appendingPathComponent(name)
        if fm.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
}

@discardableResult
func run(_ tool: URL, _ args: [String], in directory: URL? = nil) throws -> Int32 {
    let process = Process()
    process.executableURL = tool
    process.arguments = args
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "make_fixtures", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey:
                                    "\(tool.lastPathComponent) a échoué"])
    }
    return process.terminationStatus
}

/// Archive ZIP aux noms d'entrée EXACTS (« word/document.xml », sans « ./ »).
/// Même brique que `Tests/FouineExtractTests/Fixtures.makeArchive`, et pour la
/// même raison : `-- ` sépare les options des opérandes, sans quoi l'entrée
/// piégée `--use-compress-program=…` ne peut pas être fabriquée.
func makeArchive(_ entries: [(name: String, data: Data)], at destination: URL) throws {
    let staging = try temporaryDirectory("zip")
    defer { try? fm.removeItem(at: staging) }
    for entry in entries {
        let file = staging.appendingPathComponent(entry.name)
        try fm.createDirectory(at: file.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try entry.data.write(to: file)
    }
    try? fm.removeItem(at: destination)
    try fm.createDirectory(at: destination.deletingLastPathComponent(),
                           withIntermediateDirectories: true)
    guard let zip = which("zip") ?? URL(string: "file:///usr/bin/zip") else {
        fail("/usr/bin/zip introuvable")
    }
    try run(zip, ["-q", "-X", destination.path, "--"] + entries.map(\.name),
            in: staging)
}

func xml(_ body: String) -> Data {
    Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + body).utf8)
}

// MARK: - Fixtures MÉDIAS (lot INT-F3, cible « media »)

/// La phrase dite dans les trois fixtures. Quatre mots TÉMOINS rares, choisis
/// pour qu'un test de transcription puisse les chercher sans risquer de les
/// trouver ailleurs dans le corpus.
let spokenSentence = "le polymère cristallise lentement"

/// Titre et artiste posés à l'écriture, pour l'étage MÉTADONNÉES.
let mediaTitle = "Cristallisation"
let mediaArtist = "Fouine Fixtures"

/// Attendre un travail asynchrone depuis le fil principal du script.
/// AVFoundation n'a plus d'API synchrone non dépréciée depuis macOS 13.
final class ResultBox<T>: @unchecked Sendable {
    var stored: Result<T, Error>?
}

func waitFor<T>(_ body: @escaping () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        do { box.stored = .success(try await body()) }
        catch { box.stored = .failure(error) }
        done.signal()
    }
    done.wait()
    switch box.stored {
    case .success(let value): return value
    case .failure(let error): throw error
    case nil: throw NSError(domain: "make_fixtures", code: -1)
    }
}

func metadataItem(_ identifier: AVMetadataIdentifier, _ value: String)
    -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = identifier
    item.value = value as NSString
    item.extendedLanguageTag = "und"
    return item
}

/// `voix.aiff` — une phrase française dite par la synthèse vocale du système.
///
/// `-v Thomas` : la voix française est OBLIGATOIRE. Lue par une voix anglaise,
/// « le polymère cristallise lentement » sort dans une prononciation qu'aucune
/// reconnaissance française ne retrouve, et le test de transcription échouerait
/// pour une raison qui n'a rien à voir avec Fouine. La voix est vérifiée : sur
/// une machine où elle manque, la fixture n'est pas produite plutôt que d'être
/// produite fausse.
func makeSpokenAIFF(at destination: URL) throws {
    let say = URL(fileURLWithPath: "/usr/bin/say")
    guard fm.isExecutableFile(atPath: say.path) else {
        fail("/usr/bin/say introuvable")
    }
    // `BEI16` et non `LEI16` : AIFF est un format BIG-ENDIAN, et `say` refuse
    // net (« Opening output file failed: fmt? », code 1, fichier de 0 octet)
    // qu'on lui demande du petit-boutiste dans un conteneur qui n'en veut pas.
    _ = try run(say, ["-v", "Thomas", "-o", destination.path,
                      "--data-format=BEI16@22050", spokenSentence])
}

/// `voix.m4a` — le même son en AAC, AVEC titre et artiste.
func makeTaggedM4A(from source: URL, at destination: URL) throws {
    try? fm.removeItem(at: destination)
    let asset = AVURLAsset(url: source)
    guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
        fail("AVAssetExportSession indisponible")
    }
    export.outputURL = destination
    export.outputFileType = .m4a
    export.metadata = [
        metadataItem(.iTunesMetadataSongName, mediaTitle),
        metadataItem(.iTunesMetadataArtist, mediaArtist),
    ]
    let done = DispatchSemaphore(value: 0)
    export.exportAsynchronously { done.signal() }
    done.wait()
    if export.status != .completed {
        fail("export m4a : \(export.error?.localizedDescription ?? "échec")")
    }
}

/// `clip.mp4` — une image NOIRE et la même piste son, avec titre et artiste.
///
/// Une vidéo minuscule (160 × 120, une image par seconde) : ce qu'on veut
/// prouver, c'est que le conteneur vidéo suit le même chemin que l'audio, pas
/// qu'on sait encoder une image. Le poids reste sous les 20 Kio.
func makeVideoClip(from source: URL, at destination: URL) throws {
    try? fm.removeItem(at: destination)
    let audio = AVURLAsset(url: source)
    let duration = try waitFor { try await audio.load(.duration) }
    let seconds = max(1.0, CMTimeGetSeconds(duration))

    let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
    writer.metadata = [
        metadataItem(.quickTimeMetadataTitle, mediaTitle),
        metadataItem(.quickTimeMetadataArtist, mediaArtist),
    ]

    let width = 160, height = 120
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    video.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: video,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
    let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 22_050.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
    ])
    sound.expectsMediaDataInRealTime = false
    writer.add(video)
    writer.add(sound)
    guard writer.startWriting() else {
        fail("AVAssetWriter : \(writer.error?.localizedDescription ?? "refus")")
    }
    writer.startSession(atSourceTime: .zero)

    // ── Les images : une par seconde, toutes noires ─────────────────────────
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
    guard let frame = buffer else { fail("CVPixelBufferCreate") }
    CVPixelBufferLockBaseAddress(frame, [])
    if let base = CVPixelBufferGetBaseAddress(frame) {
        memset(base, 0, CVPixelBufferGetBytesPerRow(frame) * height)
    }
    CVPixelBufferUnlockBaseAddress(frame, [])
    for second in 0...Int(seconds.rounded(.up)) {
        while !video.isReadyForMoreMediaData { usleep(2_000) }
        adaptor.append(frame, withPresentationTime:
                        CMTime(seconds: Double(second), preferredTimescale: 600))
    }
    video.markAsFinished()

    // ── Le son : recopié échantillon par échantillon depuis l'AIFF ──────────
    let reader = try AVAssetReader(asset: audio)
    let tracks = try waitFor { try await audio.loadTracks(withMediaType: .audio) }
    let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 22_050.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    guard reader.startReading() else { fail("AVAssetReader : lecture refusée") }
    while let sample = output.copyNextSampleBuffer() {
        while !sound.isReadyForMoreMediaData { usleep(2_000) }
        sound.append(sample)
    }
    sound.markAsFinished()

    let finished = DispatchSemaphore(value: 0)
    writer.finishWriting { finished.signal() }
    finished.wait()
    if writer.status != .completed {
        fail("clip.mp4 : \(writer.error?.localizedDescription ?? "échec")")
    }
}

if mediaMode {
    do {
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let aiff = outputDirectory.appendingPathComponent("voix.aiff")
        let m4a = outputDirectory.appendingPathComponent("voix.m4a")
        let mp4 = outputDirectory.appendingPathComponent("clip.mp4")
        try makeSpokenAIFF(at: aiff)
        try makeTaggedM4A(from: aiff, at: m4a)
        try makeVideoClip(from: aiff, at: mp4)
        var total = 0
        for file in [aiff, m4a, mp4] {
            let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int ?? 0
            total += size
            print(String(format: "  %@  %.1f Kio", file.lastPathComponent,
                         Double(size) / 1024))
        }
        print(String(format: "medias : 3 fichiers, %.1f Kio -> %@",
                     Double(total) / 1024, outputDirectory.path))
        exit(0)
    } catch {
        fail("\(error)")
    }
}

// MARK: - PDF à couche texte (vectoriel)

let bodyFont = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
let titleFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 16, nil)

/// PDF réel, une page par élément, chaque ligne dessinée en TEXTE VECTORIEL :
/// `PDFPage.string` le rend comme sur un document acheté.
func makeTextPDF(pages: [[String]], at url: URL) throws {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
        fail("CGDataConsumer")
    }
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        fail("CGContext PDF")
    }
    for lines in pages {
        context.beginPDFPage(nil)
        var y: CGFloat = 740
        for (index, line) in lines.enumerated() {
            let font = index == 0 ? titleFont : bodyFont
            let attributed = NSAttributedString(
                string: line,
                attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 48, y: y)
            CTLineDraw(ctLine, context)
            y -= index == 0 ? 28 : 18
            if y < 48 { break }
        }
        context.endPDFPage()
    }
    context.closePDF()
    try data.write(to: url)
}

// MARK: - Page « scannée » : du texte RENDU EN IMAGE

/// Une page A4 à 150 dpi en niveaux de gris, texte noir sur fond blanc, dessiné
/// GROS (24 pt à 150 dpi = ~50 px de haut) : c'est ce que Vision lit le mieux,
/// et c'est aussi ce à quoi ressemble une page de livre passée au scanner.
///
/// Aucune couche texte n'existe dans le résultat : c'est un bitmap. C'est tout
/// l'intérêt — l'OCR est le SEUL moyen de retrouver ces mots, ce que la recette
/// vérifie en cherchant les termes témoins et en exigeant `source == ocr`.
func renderPageImage(lines: [String], width: Int = 1240, height: Int = 1754)
    -> CGImage {
    let space = CGColorSpaceCreateDeviceGray()
    guard let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { fail("CGContext bitmap") }

    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(gray: 0, alpha: 1)
    context.setShouldAntialias(true)
    context.setShouldSmoothFonts(true)

    let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
    var y = CGFloat(height) - 220
    for line in lines {
        let attributed = NSAttributedString(
            string: line,
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                         kCTForegroundColorAttributeName as NSAttributedString.Key:
                            CGColor(gray: 0, alpha: 1)])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 110, y: y)
        CTLineDraw(ctLine, context)
        y -= 96
        if y < 120 { break }
    }
    guard let image = context.makeImage() else { fail("makeImage") }
    return image
}

func pngData(_ image: CGImage) -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
    else { fail("CGImageDestination png") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("finalize png") }
    return data as Data
}

/// PDF SCANNÉ : chaque page est l'image, et rien d'autre. `PDFPage.string` rend
/// une chaîne vide, le pipeline met la page en file d'OCR (§6.1, seuil de 100
/// caractères natifs).
func makeScannedPDF(pages: [[String]], at url: URL) throws {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
        fail("CGDataConsumer")
    }
    // 595 × 842 pt = A4. L'image de 1240 × 1754 px s'y étale à ~150 dpi.
    var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        fail("CGContext PDF")
    }
    for lines in pages {
        let image = renderPageImage(lines: lines)
        context.beginPDFPage(nil)
        context.draw(image, in: mediaBox)
        context.endPDFPage()
    }
    context.closePDF()
    try data.write(to: url)
}

// MARK: - DjVu (facultatif : djvulibre)

/// DjVu multipage réel : une image bitonale par page (cjb2 + djvm) puis une
/// couche `TXTz` posée par djvused. Rend `false` si djvulibre est absent — la
/// fixture n'est alors pas produite et le manifeste porte `"requires"`.
func makeDjvu(pages: [String], at destination: URL) throws -> Bool {
    guard let cjb2 = which("cjb2"), let djvm = which("djvm"),
          let djvused = which("djvused"), !pages.isEmpty else { return false }

    let staging = try temporaryDirectory("djvu")
    defer { try? fm.removeItem(at: staging) }

    let pbm = staging.appendingPathComponent("page.pbm")
    var bitmap = Data("P4\n64 64\n".utf8)
    bitmap.append(Data(repeating: 0xFF, count: 64 * 8))
    try bitmap.write(to: pbm)

    var singles: [String] = []
    for index in pages.indices {
        let single = staging.appendingPathComponent("p\(index + 1).djvu")
        try run(cjb2, [pbm.path, single.path])
        singles.append(single.path)
    }
    try? fm.removeItem(at: destination)
    try run(djvm, ["-c", destination.path] + singles)

    var script: [String] = []
    for (index, text) in pages.enumerated() where !text.isEmpty {
        let layer = staging.appendingPathComponent("t\(index + 1).txt")
        try Data("(page 0 0 64 64\n (line 0 0 64 64 \"\(text)\"))\n".utf8)
            .write(to: layer)
        script.append("select \(index + 1); set-txt \(layer.path)")
    }
    if !script.isEmpty {
        try run(djvused, [destination.path, "-e",
                          script.joined(separator: "; ") + "; save"])
    }
    return true
}

// MARK: - Manifeste

/// Un terme témoin : le mot, les pages où il doit ressortir, et par quel canal.
struct Witness: Encodable {
    let term: String
    let pages: [Int]
    /// `native` ou `ocr` — la colonne `page_src.src` du §4.1.
    let source: String
    /// Requête `fouine search` exacte, si elle diffère du terme.
    let query: String?
    let note: String?

    init(_ term: String, pages: [Int], source: String = "native",
         query: String? = nil, note: String? = nil) {
        self.term = term
        self.pages = pages
        self.source = source
        self.query = query
        self.note = note
    }
}

struct Entry: Encodable {
    /// Chemin RELATIF au dossier du corpus.
    let name: String
    let ext: String
    /// `text` (couche texte native) · `scanned` (OCR obligatoire) ·
    /// `trap` (piège de sécurité ou format refusé) · `ignored` (le crawler ne
    /// doit même pas le voir).
    let kind: String
    /// Nombre de pages attendu dans `docs.n_pages`, ou `nil` si l'extracteur en
    /// décide (pagination par `pageSplitChars`).
    let pages: Int?
    /// `extracted` · `skipped` · `failed` — la valeur attendue de `docs.state`.
    let state: String
    /// Outil externe requis pour que la fixture EXISTE (`djvulibre`), nil sinon.
    let requires: String?
    /// Fragment ATTENDU de `docs.err`, pour les fixtures `state: "failed"` :
    /// un refus se juge sur son MOTIF, pas seulement sur son existence.
    let err: String?
    let witnesses: [Witness]
    let note: String

    init(_ name: String, ext: String, kind: String, pages: Int?,
         state: String = "extracted", requires: String? = nil,
         err: String? = nil, witnesses: [Witness] = [], note: String) {
        self.name = name
        self.ext = ext
        self.kind = kind
        self.pages = pages
        self.state = state
        self.requires = requires
        self.err = err
        self.witnesses = witnesses
        self.note = note
    }
}

struct Manifest: Encodable {
    let schema: Int
    let generator: String
    let note: String
    /// Nombre de fichiers que le crawler doit INDEXER (kind != "ignored").
    let indexedFiles: Int
    let files: [Entry]

    enum CodingKeys: String, CodingKey {
        case schema, generator, note, files
        case indexedFiles = "indexed_files"
    }
}

var entries: [Entry] = []

func write(_ text: String, to name: String) throws {
    let url = outputDirectory.appendingPathComponent(name)
    try fm.createDirectory(at: url.deletingLastPathComponent(),
                           withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

func url(_ name: String) throws -> URL {
    let url = outputDirectory.appendingPathComponent(name)
    try fm.createDirectory(at: url.deletingLastPathComponent(),
                           withIntermediateDirectories: true)
    return url
}

// ═══ BUREAUTIQUE ANCIENNE : conteneur OLE, classeur BIFF, présentation PPT ══
//
// DUPLIQUÉ, EXPRÈS, depuis `Tests/FouineExtractTests/LegacyOfficeBuilder.swift`
// (lot INT-F1) : ce générateur est un script `swift` autonome, il ne peut pas
// importer une cible de test et `Package.swift` est gelé. Même raison, même
// règle que `makeArchive`. Les deux copies doivent rester équivalentes.

enum OLEWriter {

    static let sectorSize = 512
    static let miniSectorSize = 64
    static let miniCutoff = 4_096
    static let endOfChain: UInt32 = 0xFFFF_FFFE
    static let freeSector: UInt32 = 0xFFFF_FFFF
    static let fatSector: UInt32 = 0xFFFF_FFFD
    static let noStream: UInt32 = 0xFFFF_FFFF

    /// Un conteneur OLE2 portant ces flux, dans cet ordre.
    static func compoundFile(streams: [(name: String, data: Data)]) -> Data {
        // — Mini-flux : les flux de moins de 4 096 octets, bout à bout ————
        var miniStream = Data()
        var miniStart: [Int: Int] = [:]          // index de flux -> mini-secteur
        for (index, stream) in streams.enumerated()
        where !stream.data.isEmpty && stream.data.count < miniCutoff {
            miniStart[index] = miniStream.count / miniSectorSize
            miniStream.append(stream.data)
            let padding = (miniSectorSize - miniStream.count % miniSectorSize)
                % miniSectorSize
            miniStream.append(Data(repeating: 0, count: padding))
        }

        // — Allocation des secteurs ————————————————————————————————————
        let entryCount = streams.count + 1                    // + l'entrée racine
        let directorySectors = (entryCount + 3) / 4
        let miniSectorCount = miniStream.count / miniSectorSize
        let miniFATSectors = miniSectorCount == 0
            ? 0 : (miniSectorCount * 4 + sectorSize - 1) / sectorSize
        let miniStreamSectors = (miniStream.count + sectorSize - 1) / sectorSize

        var next = 1                                          // le secteur 0 = FAT
        let directoryStart = next; next += directorySectors
        let miniFATStart = miniFATSectors > 0 ? next : Int(endOfChain)
        next += miniFATSectors
        let miniStreamStart = miniStreamSectors > 0 ? next : Int(endOfChain)
        next += miniStreamSectors

        var bigStart: [Int: Int] = [:]
        var bigSectors: [Int: Int] = [:]
        for (index, stream) in streams.enumerated() where stream.data.count >= miniCutoff {
            let count = (stream.data.count + sectorSize - 1) / sectorSize
            bigStart[index] = next
            bigSectors[index] = count
            next += count
        }
        let totalSectors = next
        precondition(totalSectors <= sectorSize / 4,
                     "fixture trop grosse pour un seul secteur de FAT")

        // — FAT ————————————————————————————————————————————————————————
        var fat = [UInt32](repeating: freeSector, count: sectorSize / 4)
        fat[0] = fatSector
        func chain(_ start: Int, _ count: Int) {
            guard count > 0 else { return }
            for offset in 0..<count {
                fat[start + offset] = offset + 1 < count
                    ? UInt32(start + offset + 1) : endOfChain
            }
        }
        chain(directoryStart, directorySectors)
        if miniFATSectors > 0 { chain(miniFATStart, miniFATSectors) }
        if miniStreamSectors > 0 { chain(miniStreamStart, miniStreamSectors) }
        for (index, start) in bigStart { chain(start, bigSectors[index] ?? 0) }

        // — Mini-FAT ————————————————————————————————————————————————————
        var miniFAT = [UInt32]()
        for (index, stream) in streams.enumerated() {
            guard let start = miniStart[index] else { continue }
            let count = (stream.data.count + miniSectorSize - 1) / miniSectorSize
            for offset in 0..<count {
                miniFAT.append(offset + 1 < count
                               ? UInt32(start + offset + 1) : endOfChain)
            }
        }

        // — Répertoire ——————————————————————————————————————————————————
        var directory = Data()
        directory.append(entry(name: "Root Entry", type: 5,
                               start: UInt32(miniStreamStart),
                               size: UInt64(miniStream.count),
                               child: streams.isEmpty ? noStream : 1,
                               right: noStream))
        for (index, stream) in streams.enumerated() {
            let start = miniStart[index].map { UInt32($0) }
                ?? bigStart[index].map { UInt32($0) } ?? endOfChain
            directory.append(entry(name: stream.name, type: 2, start: start,
                                   size: UInt64(stream.data.count),
                                   child: noStream,
                                   right: index + 2 <= streams.count
                                       ? UInt32(index + 2) : noStream))
        }

        // — En-tête ————————————————————————————————————————————————————
        var header = Data()
        header.append(contentsOf: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        header.append(Data(repeating: 0, count: 16))          // CLSID
        header.append(u16(0x003E))                            // version mineure
        header.append(u16(0x0003))                            // version majeure
        header.append(u16(0xFFFE))                            // petit-boutien
        header.append(u16(9))                                 // secteurs de 512
        header.append(u16(6))                                 // mini-secteurs de 64
        header.append(Data(repeating: 0, count: 6))
        header.append(u32(0))                                 // secteurs de répertoire
        header.append(u32(1))                                 // secteurs de FAT
        header.append(u32(UInt32(directoryStart)))
        header.append(u32(0))                                 // signature de transaction
        header.append(u32(UInt32(miniCutoff)))
        header.append(u32(UInt32(miniFATStart)))
        header.append(u32(UInt32(miniFATSectors)))
        header.append(u32(endOfChain))                        // DIFAT
        header.append(u32(0))
        header.append(u32(0))                                 // DIFAT[0] = secteur 0
        for _ in 1..<109 { header.append(u32(freeSector)) }

        // — Assemblage ————————————————————————————————————————————————
        var file = header
        var body = Data()
        for value in fat { body.append(u32(value)) }           // secteur 0
        body.append(pad(directory, to: directorySectors * sectorSize))
        if miniFATSectors > 0 {
            var table = Data()
            for value in miniFAT { table.append(u32(value)) }
            body.append(pad(table, to: miniFATSectors * sectorSize))
        }
        if miniStreamSectors > 0 {
            body.append(pad(miniStream, to: miniStreamSectors * sectorSize))
        }
        for (index, stream) in streams.enumerated() where bigStart[index] != nil {
            body.append(pad(stream.data, to: (bigSectors[index] ?? 0) * sectorSize))
        }
        file.append(body)
        return file
    }

    /// Une entrée de répertoire de 128 octets.
    private static func entry(name: String, type: UInt8, start: UInt32,
                              size: UInt64, child: UInt32, right: UInt32) -> Data {
        var data = Data()
        var utf16 = Data()
        for unit in Array(name.utf16) { utf16.append(u16(unit)) }
        utf16.append(u16(0))                                   // terminateur
        data.append(pad(utf16, to: 64))
        data.append(u16(UInt16(utf16.count)))
        data.append(type)
        data.append(1)                                         // couleur : noir
        data.append(u32(noStream))                             // frère gauche
        data.append(u32(right))
        data.append(u32(child))
        data.append(Data(repeating: 0, count: 16))             // CLSID
        data.append(u32(0))                                    // drapeaux
        data.append(Data(repeating: 0, count: 16))             // horodatages
        data.append(u32(start))
        data.append(u64(size))
        return data
    }

    static func pad(_ data: Data, to length: Int) -> Data {
        var copy = data
        if copy.count < length {
            copy.append(Data(repeating: 0, count: length - copy.count))
        }
        return copy.prefix(length)
    }

    static func u16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    static func u32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
              UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }

    static func u64(_ value: UInt64) -> Data {
        var data = Data()
        for byte in 0..<8 { data.append(UInt8((value >> (8 * byte)) & 0xFF)) }
        return data
    }
}

/// Un classeur BIFF8 minimal, mais VRAI : sous-flux des globales, table des
/// chaînes partagées, un sous-flux par feuille, offsets recalés.
enum BIFFBuilder {

    enum Cell {
        /// Texte, par la table des chaînes partagées. `wide` force l'UTF-16.
        case text(String, wide: Bool)
        case number(Double)
        /// Entier court, encodé en `RK`.
        case integer(Int32)
    }

    struct Sheet {
        let name: String
        /// (ligne, colonne, contenu), en base 0.
        let cells: [(row: Int, column: Int, cell: Cell)]
    }

    static func record(_ type: UInt16, _ body: Data) -> Data {
        var data = OLEWriter.u16(type)
        data.append(OLEWriter.u16(UInt16(body.count)))
        data.append(body)
        return data
    }

    static func bof(kind: UInt16) -> Data {
        var body = OLEWriter.u16(0x0600)          // BIFF8
        body.append(OLEWriter.u16(kind))
        body.append(Data(repeating: 0, count: 12))
        return record(0x0809, body)
    }

    static let eof = record(0x000A, Data())

    /// Chaîne BIFF8 : longueur en caractères, drapeaux, données.
    static func string(_ text: String, wide: Bool) -> Data {
        let units = Array(text.utf16)
        var data = OLEWriter.u16(UInt16(units.count))
        if wide || units.contains(where: { $0 > 0xFF }) {
            data.append(UInt8(0x01))
            for unit in units { data.append(OLEWriter.u16(unit)) }
        } else {
            data.append(UInt8(0x00))
            for unit in units { data.append(UInt8(unit & 0xFF)) }
        }
        return data
    }

    static func workbook(_ sheets: [Sheet]) -> Data {
        // Chaînes partagées, dans l'ordre de première rencontre.
        var shared: [(text: String, wide: Bool)] = []
        var indexOf: [String: Int] = [:]
        for sheet in sheets {
            for cell in sheet.cells {
                guard case .text(let text, let wide) = cell.cell else { continue }
                if indexOf[text] == nil {
                    indexOf[text] = shared.count
                    shared.append((text, wide))
                }
            }
        }

        // — Globales ————————————————————————————————————————————————————
        var globals = bof(kind: 0x0005)
        var sst = OLEWriter.u32(UInt32(shared.count))
        sst.append(OLEWriter.u32(UInt32(shared.count)))
        for entry in shared { sst.append(string(entry.text, wide: entry.wide)) }
        globals.append(record(0x00FC, sst))

        var boundsheetOffsets: [Int] = []
        for sheet in sheets {
            var body = OLEWriter.u32(0)                        // lbPlyPos, recalé
            body.append(OLEWriter.u16(0))                      // visible, feuille
            let name = Array(sheet.name.utf16)
            body.append(UInt8(name.count))
            body.append(UInt8(0))                              // non compressée : non
            for unit in name { body.append(UInt8(unit & 0xFF)) }
            boundsheetOffsets.append(globals.count + 4)        // corps du record
            globals.append(record(0x0085, body))
        }
        globals.append(eof)

        // — Sous-flux des feuilles ————————————————————————————————————
        var body = Data()
        var starts: [Int] = []
        for sheet in sheets {
            starts.append(globals.count + body.count)
            body.append(bof(kind: 0x0010))
            for cell in sheet.cells {
                let head = OLEWriter.u16(UInt16(cell.row))
                    + OLEWriter.u16(UInt16(cell.column)) + OLEWriter.u16(0)
                switch cell.cell {
                case .text(let text, _):
                    var record = head
                    record.append(OLEWriter.u32(UInt32(indexOf[text] ?? 0)))
                    body.append(Self.record(0x00FD, record))
                case .number(let value):
                    var record = head
                    record.append(OLEWriter.u64(value.bitPattern))
                    body.append(Self.record(0x0203, record))
                case .integer(let value):
                    var record = head
                    record.append(OLEWriter.u32(UInt32(bitPattern: (value << 2) | 0x02)))
                    body.append(Self.record(0x027E, record))
                }
            }
            body.append(eof)
        }

        // Recalage des offsets de feuille dans les `BOUNDSHEET`.
        var workbook = globals
        for (index, offset) in boundsheetOffsets.enumerated() {
            let value = OLEWriter.u32(UInt32(starts[index]))
            workbook.replaceSubrange(offset..<(offset + 4), with: value)
        }
        workbook.append(body)
        return workbook
    }

    /// Un classeur CHIFFRÉ : `FILEPASS` juste après le `BOF`.
    static func encryptedWorkbook() -> Data {
        var data = bof(kind: 0x0005)
        data.append(record(0x002F, Data([0x01, 0x00])))
        data.append(eof)
        return data
    }
}

/// Une présentation PPT minimale : une `SlideListWithText` dont les
/// `SlidePersistAtom` séparent les diapositives.
enum PPTBuilder {

    enum Text {
        /// `TextCharsAtom`, UTF-16LE.
        case chars(String)
        /// `TextBytesAtom`, un octet par caractère.
        case bytes(String)
    }

    static func atom(_ type: UInt16, instance: UInt16 = 0, _ body: Data) -> Data {
        var data = OLEWriter.u16(instance << 4)
        data.append(OLEWriter.u16(type))
        data.append(OLEWriter.u32(UInt32(body.count)))
        data.append(body)
        return data
    }

    static func container(_ type: UInt16, instance: UInt16 = 0, _ body: Data) -> Data {
        var data = OLEWriter.u16((instance << 4) | 0x0F)
        data.append(OLEWriter.u16(type))
        data.append(OLEWriter.u32(UInt32(body.count)))
        data.append(body)
        return data
    }

    static func text(_ item: Text) -> Data {
        switch item {
        case .chars(let value):
            var data = Data()
            for unit in Array(value.utf16) { data.append(OLEWriter.u16(unit)) }
            return atom(0x0FA0, data)
        case .bytes(let value):
            var data = Data()
            for unit in Array(value.utf16) { data.append(UInt8(unit & 0xFF)) }
            return atom(0x0FA8, data)
        }
    }

    /// Le flux `PowerPoint Document` : une entrée de liste par diapositive.
    static func document(slides: [[Text]], notes: [[Text]] = []) -> Data {
        var data = container(0x0FF0, instance: 0, list(slides))
        if !notes.isEmpty {
            data.append(container(0x0FF0, instance: 2, list(notes)))
        }
        return data
    }

    private static func list(_ pages: [[Text]]) -> Data {
        var body = Data()
        for (index, page) in pages.enumerated() {
            var persist = OLEWriter.u32(UInt32(index + 1))
            persist.append(Data(repeating: 0, count: 16))
            body.append(atom(0x03F3, persist))
            for item in page { body.append(text(item)) }
        }
        return body
    }

    /// Une présentation CHIFFRÉE : le conteneur de session de chiffrement.
    static func encryptedDocument() -> Data {
        container(0x2F14, Data(repeating: 0, count: 8))
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// LE CORPUS
// ═══════════════════════════════════════════════════════════════════════════
//
// VOCABULAIRES DISJOINTS. Chaque fichier porte des termes témoins qui
// n'apparaissent NULLE PART ailleurs dans le corpus : c'est ce qui permet à un
// test d'affirmer « ce terme sort à cette page de ce document », et rien
// d'autre. Les seules répétitions volontaires sont celles que la recette
// exerce (le mot « markovnikov » sur deux pages du même PDF, pour que la
// recherche d'EXPRESSION ait quelque chose à départager).

do {
    if let items = try? fm.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil) {
        for item in items where item.lastPathComponent != "README.md" {
            try? fm.removeItem(at: item)
        }
    } else {
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    // ── 1. PDF à couche texte, 4 pages ──────────────────────────────────────
    //
    // Le document central de la recette : il porte à lui seul le terme exact,
    // l'expression, le préfixe, la proximité, l'exclusion et le flou.
    try makeTextPDF(pages: [
        // p1 — « chromatographie » (préfixe), « enthalpie » et « gibbs » ÉLOIGNÉS
        //      l'un de l'autre (contre-épreuve de pres:), « polymere » SANS
        //      « reticulation » (contre-épreuve de l'exclusion).
        ["Chimie organique — corpus de fixtures de Fouine",
         "Chapitre premier. La chromatographie en phase gazeuse sert ici de",
         "premier terme temoin, choisi assez long pour qu'un prefixe de quatre",
         "lettres ait un sens. L'enthalpie de reaction ouvre le chapitre et ne",
         "sera reprise que bien plus loin ; entre les deux viennent la pression,",
         "la temperature, le volume molaire, la constante des gaz parfaits, le",
         "coefficient de compressibilite, le facteur d'accentricite et la",
         "fugacite, soit largement plus de dix mots. Gibbs n'arrive qu'ici, en",
         "fin de page, et c'est voulu. Le polymere lineaire clot le chapitre."],

        // p2 — l'EXPRESSION exacte, avec ses accents.
        ["Chapitre deux. Additions electrophiles",
         "La règle de Markovnikov gouverne l'addition électrophile des",
         "hydracides sur un alcène dissymétrique : le proton se fixe sur le",
         "carbone le plus hydrogéné. L'énoncé date de 1870 et reste exact tant",
         "qu'aucun péroxyde n'entre en jeu.",
         "Cette page porte l'expression exacte que la recette recherche."],

        // p3 — proximité (enthalpie + gibbs adjacents), préfixe
        //      (chromatographique), et le mot RARE du test flou.
        ["Chapitre trois. Grandeurs thermodynamiques",
         "L'enthalpie libre de Gibbs decide du sens spontane d'une reaction :",
         "les deux mots sont ici a trois mots l'un de l'autre, et c'est ce que",
         "la recherche de proximite doit savoir distinguer de la page un.",
         "La separation chromatographique des enantiomeres en decoule.",
         "La sublimation du diiode illustre le meme raisonnement applique a un",
         "changement d'etat : c'est le mot rare de ce corpus, celui sur lequel",
         "la recherche floue est mise a l'epreuve."],

        // p4 — « markovnikov » et « regle » PRÉSENTS mais NON ADJACENTS (la
        //      recherche d'expression ne doit pas rendre cette page), et
        //      « polymere » AVEC « reticulation » (cible de l'exclusion).
        ["Chapitre quatre. Effet des peroxydes",
         "Markovnikov avait enonce sa loi avant qu'on ne sache la contourner :",
         "une regle, disait-il, souffre toujours son exception. En presence de",
         "peroxydes l'addition s'inverse et le proton se fixe sur le carbone le",
         "moins hydrogene.",
         "Le polymere obtenu par reticulation radicalaire en est l'application",
         "industrielle la plus courante."],
    ], at: try url("chimie-organique.pdf"))

    entries.append(Entry(
        "chimie-organique.pdf", ext: "pdf", kind: "text", pages: 4,
        witnesses: [
            Witness("markovnikov", pages: [2, 4],
                    note: "terme exact ; deux pages, dont une SANS l'expression"),
            Witness("regle de markovnikov", pages: [2],
                    query: "\"regle de markovnikov\"",
                    note: "expression exacte : la page 4 porte les deux mots "
                        + "mais pas cote a cote"),
            Witness("chromatograph", pages: [1, 3], query: "chromatograph*",
                    note: "prefixe (>= 4 caracteres, contrainte du §4.1)"),
            Witness("enthalpie gibbs", pages: [3], query: "pres:5 enthalpie gibbs",
                    note: "proximite : la page 1 porte les deux mots, a plus de "
                        + "dix mots l'un de l'autre"),
            Witness("polymere", pages: [1, 4],
                    note: "le mot est AUSSI dans memo.rtf : trois pages, deux "
                        + "documents"),
            Witness("reticulation", pages: [4],
                    note: "cible de l'exclusion : n'existe que sur cette page, "
                        + "donc que dans ce document"),
            Witness("sublimation", pages: [3],
                    query: "sublimatlon",
                    note: "mot rare ; la requete est une FAUTE de frappe a "
                        + "distance 1, a chercher avec --fuzzy on "
                        + "--fuzzy-scope all"),
        ],
        note: "PDF vectoriel a couche texte, 4 pages. Porte a lui seul les six "
            + "formes de requete de la recette : terme exact, expression, "
            + "prefixe, proximite, exclusion, flou."))

    // ── 2. PDF SCANNÉ : pages image, aucune couche texte ────────────────────
    //
    // Les mots sont écrits en CAPITALES et isolés : ils doivent survivre à
    // Vision sans ambiguïté. Les termes témoins retenus dans le manifeste ont
    // été confirmés par une passe `fouine ocr` réelle (voir README.md).
    try makeScannedPDF(pages: [
        ["NOTES DE LABORATOIRE",
         "PAGE UNE",
         "TELLURIUM",
         "mesure du rendement massique",
         "apres recristallisation"],
        ["NOTES DE LABORATOIRE",
         "PAGE DEUX",
         "SPECTROMETRE",
         "etalonnage de la source",
         "avant chaque serie"],
    ], at: try url("notes-scannees.pdf"))

    entries.append(Entry(
        "notes-scannees.pdf", ext: "pdf", kind: "scanned", pages: 2,
        witnesses: [
            Witness("tellurium", pages: [1], source: "ocr_accurate"),
            Witness("spectrometre", pages: [2], source: "ocr_accurate"),
        ],
        note: "PDF SCANNE : deux pages purement bitmap, zero caractere natif. "
            + "Les deux pages entrent en file d'OCR (seuil de 100 caracteres "
            + "du §6.1) et les termes temoins ne sortent QUE par Vision."))

    // ── 3. Textes simples ───────────────────────────────────────────────────
    try write("""
        Note de laboratoire du 14 mars.

        L'isotherme d'adsorption de Langmuir decrit le recouvrement d'une
        surface a temperature constante. Le terme temoin de ce fichier est
        « isotherme », et il n'apparait nulle part ailleurs dans le corpus.

        Suivent quelques lignes de remplissage pour que la page depasse
        largement le seuil de cent caracteres natifs du §6.1 et ne soit donc
        jamais mise en file d'OCR : masse, volume molaire, pression partielle,
        tension superficielle, angle de contact.
        """, to: "note-de-laboratoire.txt")
    entries.append(Entry(
        "note-de-laboratoire.txt", ext: "txt", kind: "text", pages: 1,
        witnesses: [Witness("isotherme", pages: [1])],
        note: "texte brut UTF-8, une page."))

    try write("""
        # Lisez-moi

        La **cinétique** du premier ordre est le terme témoin de ce fichier
        Markdown : il porte un accent, que le tokenizer FTS5 du projet
        (`unicode61 remove_diacritics 2`) replie — « cinetique » et
        « cinétique » trouvent donc la même page.

        - vitesse de réaction
        - constante de vitesse
        - temps de demi-réaction
        """, to: "lisezmoi.md")
    entries.append(Entry(
        "lisezmoi.md", ext: "md", kind: "text", pages: 1,
        witnesses: [
            Witness("cinetique", pages: [1],
                    note: "ecrit « cinétique » dans le fichier : le repli "
                        + "d'accents du tokenizer doit rendre les deux formes "
                        + "equivalentes"),
        ],
        note: "Markdown : indexe comme du texte brut (PlainTextExtractor)."))

    try write("""
        identifiant,grandeur,valeur,unite
        1,refractometrie,1.3330,sans unite
        2,masse volumique,998.2,kg/m3
        3,capacite thermique,4185,J/kg/K
        """, to: "donnees.csv")
    entries.append(Entry(
        "donnees.csv", ext: "csv", kind: "text", pages: 1,
        witnesses: [Witness("refractometrie", pages: [1])],
        note: "CSV : traite comme du texte brut, aucun analyseur de colonnes."))

    try write("""
        2026-03-14 09:12:04 info  demarrage de la campagne
        2026-03-14 09:12:07 info  stoechiometrie verifiee sur les six lots
        2026-03-14 09:41:55 warn  ecart de temperature de 0,4 K
        """, to: "journal.log")
    entries.append(Entry(
        "journal.log", ext: "log", kind: "text", pages: 1,
        witnesses: [Witness("stoechiometrie", pages: [1])],
        note: "journal : extension .log du registre, texte brut."))

    try write("""
        \\documentclass{article}
        \\begin{document}
        \\section{Materiaux}
        Le comportement piezoelectrique du quartz est le terme temoin de ce
        fichier \\LaTeX{}.
        \\end{document}
        """, to: "article.tex")
    entries.append(Entry(
        "article.tex", ext: "tex", kind: "text", pages: 1,
        witnesses: [Witness("piezoelectrique", pages: [1])],
        note: "source LaTeX : texte brut, les commandes ne sont pas interpretees."))

    try write("""
        {
          "campagne": "fixtures",
          "grandeur": "hygrometrie",
          "points": [40, 45, 52]
        }
        """, to: "configuration.json")
    entries.append(Entry(
        "configuration.json", ext: "json", kind: "text", pages: 1,
        witnesses: [Witness("hygrometrie", pages: [1])],
        note: "JSON : texte brut, aucune analyse de structure."))

    // ── 4. HTML ─────────────────────────────────────────────────────────────
    try write("""
        <!doctype html>
        <html lang="fr"><head><meta charset="utf-8"><title>Mésomérie</title>
        <style>body { color: #222 }</style>
        <script>var ignore = "ce script ne doit pas entrer dans l'index";</script>
        </head><body>
        <h1>Mésomérie</h1>
        <p>La <em>mesomerie</em> decrit la delocalisation des electrons pi sur
        plusieurs formes limites. C'est le terme temoin de ce fichier HTML.</p>
        <p>Le contenu des balises &lt;script&gt; et &lt;style&gt; ne doit pas
        etre indexe.</p>
        </body></html>
        """, to: "fiche.html")
    entries.append(Entry(
        "fiche.html", ext: "html", kind: "text", pages: 1,
        witnesses: [
            Witness("mesomerie", pages: [1]),
            Witness("ce script ne doit pas entrer", pages: [],
                    query: "\"ce script ne doit pas\"",
                    note: "CONTRE-EPREUVE : zero page. Le contenu de <script> "
                        + "et <style> est retire par HTMLText."),
        ],
        note: "HTML : balises retirees, <script> et <style> ecartes."))

    try write("""
        <html><body><h1>Tautomérie</h1>
        <p>L'equilibre ceto-enolique illustre la tautomerie : c'est le terme
        temoin de ce fichier, dont l'extension est .htm et non .html.</p>
        </body></html>
        """, to: "vieille-page.htm")
    entries.append(Entry(
        "vieille-page.htm", ext: "htm", kind: "text", pages: 1,
        witnesses: [Witness("tautomerie", pages: [1])],
        note: "variante .htm du registre : meme extracteur que .html."))

    // ── 5. RTF ──────────────────────────────────────────────────────────────
    //
    // RTF minimal, écrit à la main : NSAttributedString le lit sans broncher.
    // TOUT EN ASCII, volontairement : l'en-tête déclare `\ansicpg1252`, et des
    // octets UTF-8 bruts s'y liraient en mojibake (« Â« »). Un accent, dans un
    // RTF, s'écrit \'xx — ce n'est pas ce que cette fixture teste, les accents
    // sont couverts par lisezmoi.md.
    //
    // Le texte NE DOIT PAS contenir le mot « reticulation » : c'est le terme
    // exclu par la recette, et ce document est justement celui qui doit
    // SURVIVRE a l'exclusion.
    try write("""
        {\\rtf1\\ansi\\ansicpg1252\\cocoartf2761
        {\\fonttbl\\f0\\fswiss Helvetica;}
        \\f0\\fs24 \\
        Memo interne.\\
        \\
        L'azeotrope eau-ethanol bloque la distillation simple a 95,6 % en masse.\\
        C'est le terme temoin de ce fichier RTF.\\
        \\
        Ce memo parle aussi d'un polymere : c'est le SECOND document du corpus\\
        a porter ce mot, et c'est ce qui rend l'exclusion observable, puisque\\
        l'exclusion porte sur le DOCUMENT (arbitrage T5) et non sur la page.\\
        }
        """, to: "memo.rtf")
    entries.append(Entry(
        "memo.rtf", ext: "rtf", kind: "text", pages: 1,
        witnesses: [
            Witness("azeotrope", pages: [1]),
            Witness("polymere", pages: [1],
                    note: "second porteur du mot, exprès : voir l'exclusion "
                        + "decrite dans chimie-organique.pdf"),
        ],
        note: "RTF : lu par NSAttributedString (RichTextExtractor). Porte aussi "
            + "le mot « polymere », pour que l'exclusion PAR DOCUMENT ait "
            + "quelque chose a laisser passer."))

    // ── 5 bis. `.doc` : le vrai, les deux mal nommés, et le piégé ───────────
    //
    // Le registre couvrait toutes ses extensions SAUF `.doc` (audit B1-34) —
    // celle-là même par laquelle un document piégé faisait sortir Fouine sur le
    // réseau (A1-01, D2-01, D2-02). Les quatre fixtures qui suivent décrivent
    // le contrat du tri par octets de tête, et chacune répond à une question :
    //
    //   · `vrai-word97.doc`   — un VRAI Word 97 (OLE Compound File), produit
    //     par `textutil -convert doc`. C'est le seul moyen d'en fabriquer un ;
    //     il doit rester indexé, sinon le durcissement aurait coûté le format ;
    //   · `faux-nom.doc`      — un vrai OOXML renommé. Mesuré par D2 : le tri
    //     par EXTENSION le perdait (`extracted` → `failed`), accents compris.
    //     Il doit rester indexé, avec son témoin et ses accents ;
    //   · `rtf-nomme-doc.doc` — un vrai RTF renommé. Même raison ;
    //   · `pieges/balise-reseau.doc` — du HTML dans un `.doc`. C'est la balise
    //     de traçage : `<img>` et `<link>` en `http:` ET en `https:` vers un
    //     port fermé, plus une adresse NOIRE (10.255.255.1) qui faisait
    //     attendre 62 s. Attendu : REFUSÉ (`docs.state = failed`, err
    //     « unrecognised format »), sans une seule connexion, tout de suite.
    //     Le test de silence réseau est dans
    //     Tests/FouineExtractTests/NetworkSilenceTests.swift.
    let textutil = which("textutil") ?? URL(fileURLWithPath: "/usr/bin/textutil")
    guard fm.isExecutableFile(atPath: textutil.path) else {
        fail("/usr/bin/textutil est introuvable : impossible de fabriquer un "
             + "vrai document Word 97")
    }
    let docStaging = try temporaryDirectory("doc")
    defer { try? fm.removeItem(at: docStaging) }
    let docSource = docStaging.appendingPathComponent("source.txt")
    try Data("""
        Note de service.

        La spectrophotometrie UV-visible est le terme temoin de ce document
        Word 97 : il est ecrit dans un vrai conteneur OLE (D0 CF 11 E0), le
        seul que `textutil -convert doc` sache produire.

        Un second paragraphe, pour depasser le seuil de cent caracteres
        natifs du paragraphe 6.1.
        """.utf8).write(to: docSource)
    try run(textutil, ["-convert", "doc", "-output",
                       try url("vrai-word97.doc").path, docSource.path])
    entries.append(Entry(
        "vrai-word97.doc", ext: "doc", kind: "text", pages: 1,
        witnesses: [Witness("spectrophotometrie", pages: [1])],
        note: "VRAI Word 97 (OLE Compound File, en-tete D0 CF 11 E0), produit "
            + "par `textutil -convert doc`. C'est la fixture .doc qui manquait "
            + "au registre (audit B1-34), et la contre-epreuve du tri par "
            + "octets de tete : le format doit rester indexe."))

    // Un vrai OOXML, sous une extension `.doc`. Meme structure que
    // rapport.docx, et des ACCENTS : c'est ce que le tri par extension perdait.
    try makeArchive([
        ("[Content_Types].xml", xml("<Types/>")),
        ("word/document.xml", xml("""
            <w:document xmlns:w="w"><w:body>
            <w:p><w:r><w:t>Rapport quinquennal</w:t></w:r></w:p>
            <w:p><w:r><w:t>Le QUINQUENNAT est le terme temoin de ce \
            conteneur OOXML mal nomme, avec ses accents : éàçûî.</w:t></w:r></w:p>
            <w:p><w:r><w:t>Un second paragraphe, pour que la page depasse \
            le seuil de cent caracteres natifs du §6.1.</w:t></w:r></w:p>
            </w:body></w:document>
            """)),
    ], at: try url("faux-nom.doc"))
    entries.append(Entry(
        "faux-nom.doc", ext: "doc", kind: "text", pages: 1,
        witnesses: [Witness("quinquennat", pages: [1],
                            note: "temoin de D2-01 : ce document s'indexait "
                                + "avant le durcissement et doit continuer")],
        note: "un vrai .docx RENOMME .doc — piece jointe renommee, export "
            + "d'application metier, scanner reseau. Le tri par EXTENSION le "
            + "perdait (mesure D2-01) ; le tri par octets de tete le delegue a "
            + "OOXMLExtractor, qui tranche a son tour sur les entrees de "
            + "l'archive. Porte des accents, exprès."))

    try write("""
        {\\rtf1\\ansi\\ansicpg1252\\cocoartf2761
        {\\fonttbl\\f0\\fswiss Helvetica;}
        \\f0\\fs24 \\
        Fiche de mesure.\\
        \\
        La coulometrie a potentiel impose est le terme temoin de ce fichier :\\
        c'est un vrai RTF, sous une extension .doc.\\
        \\
        Un second paragraphe, pour depasser le seuil de cent caracteres\\
        natifs du paragraphe 6.1.\\
        }
        """, to: "rtf-nomme-doc.doc")
    entries.append(Entry(
        "rtf-nomme-doc.doc", ext: "doc", kind: "text", pages: 1,
        witnesses: [Witness("coulometrie", pages: [1])],
        note: "un vrai RTF RENOMME .doc : second cas perdu par le tri par "
            + "extension (D2-01). Les octets de tete (« {\\rtf ») imposent "
            + "l'analyseur RTF, et le document reste indexe."))

    try write("""
        <html><head><title>Compte rendu</title>
        <link rel="stylesheet" href="http://127.0.0.1:9/BALISE_CSS">
        <link rel="stylesheet" href="https://127.0.0.1:9/BALISE_CSS_TLS">
        </head><body>
        <p>Compte rendu de reunion. Ce fichier porte l'extension .doc mais son
        contenu est du HTML : c'est exactement le piege de l'audit A1-01.</p>
        <img src="http://127.0.0.1:9/BALISE_IMG">
        <img src="https://127.0.0.1:9/BALISE_IMG_TLS">
        <img src="http://10.255.255.1/BALISE_TROU_NOIR">
        </body></html>
        """, to: "pieges/balise-reseau.doc")
    entries.append(Entry(
        "pieges/balise-reseau.doc", ext: "doc", kind: "trap", pages: 0,
        state: "failed", err: "unrecognised format",
        note: "PIEGE A1-01 / D2-01 / D2-02 : du HTML dans un .doc. AppKit "
            + "choisissait l'importateur WebKit, qui telechargeait <img> et "
            + "<link> — en http: ET en https: — et attendait 62 s sur "
            + "l'adresse noire 10.255.255.1. Attendu desormais : REFUS sur les "
            + "octets de tete (ni OLE, ni RTF, ni OOXML), docs.state = failed, "
            + "aucune connexion, immediat. Les deux ports 9 (discard) sont "
            + "fermes : meme une regression ne ferait fuir que du bruit vers "
            + "la boucle locale."))

    // ── 6. OOXML : docx, xlsx, pptx, odt ────────────────────────────────────
    //
    // AUCUN média embarqué dans ces quatre archives, volontairement : une
    // entrée `word/media/*` deviendrait une page SUPPLÉMENTAIRE en file d'OCR
    // (§5.3), et le décompte de la file cesserait d'être prévisible. Les
    // médias OOXML sont couverts par les tests unitaires de FouineExtractTests.
    try makeArchive([
        ("[Content_Types].xml", xml("<Types/>")),
        ("word/document.xml", xml("""
            <w:document xmlns:w="w"><w:body>
            <w:p><w:r><w:t>Rapport de stage</w:t></w:r></w:p>
            <w:p><w:r><w:t>La solvatation des ions en milieu aqueux est le \
            terme temoin de ce document Word.</w:t></w:r></w:p>
            <w:p><w:r><w:t>Un second paragraphe, pour que la page depasse \
            le seuil de cent caracteres natifs du §6.1.</w:t></w:r></w:p>
            </w:body></w:document>
            """)),
    ], at: try url("rapport.docx"))
    entries.append(Entry(
        "rapport.docx", ext: "docx", kind: "text", pages: 1,
        witnesses: [Witness("solvatation", pages: [1])],
        note: "docx sans media : word/document.xml seul, une page."))

    try makeArchive([
        ("[Content_Types].xml", xml("<Types/>")),
        ("xl/sharedStrings.xml", xml("""
            <sst xmlns="s" count="3" uniqueCount="3">
            <si><t>viscosite</t></si><si><t>temperature</t></si>\
            <si><t>densite</t></si></sst>
            """)),
        ("xl/worksheets/sheet1.xml", xml("""
            <worksheet xmlns="s"><sheetData>
            <row r="1"><c r="A1" t="s"><v>0</v></c>\
            <c r="B1" t="s"><v>1</v></c></row>
            <row r="2"><c r="A2"><v>1.002</v></c>\
            <c r="B2" t="inlineStr"><is><t>293 K</t></is></c></row>
            </sheetData></worksheet>
            """)),
        ("xl/worksheets/sheet2.xml", xml("""
            <worksheet xmlns="s"><sheetData>
            <row r="1"><c r="A1" t="s"><v>2</v></c></row>
            </sheetData></worksheet>
            """)),
    ], at: try url("classeur.xlsx"))
    entries.append(Entry(
        "classeur.xlsx", ext: "xlsx", kind: "text", pages: 2,
        witnesses: [
            Witness("viscosite", pages: [1],
                    note: "resolu depuis xl/sharedStrings.xml"),
            Witness("densite", pages: [2],
                    note: "seconde feuille = seconde page (§5.3)"),
        ],
        note: "xlsx a deux feuilles, sans media : une page par feuille."))

    func slide(_ text: String) -> Data {
        xml("""
            <p:sld xmlns:p="p" xmlns:a="a"><p:cSld><p:spTree>
            <p:sp><p:txBody><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></p:txBody></p:sp>
            </p:spTree></p:cSld></p:sld>
            """)
    }
    try makeArchive([
        ("[Content_Types].xml", xml("<Types/>")),
        ("ppt/slides/slide1.xml", slide("Diffraction des rayons X")),
        ("ppt/slides/slide2.xml", slide("Loi de Bragg et distance reticulaire")),
        ("ppt/slides/slide10.xml", slide("Conclusion et perspectives")),
    ], at: try url("diapositives.pptx"))
    entries.append(Entry(
        "diapositives.pptx", ext: "pptx", kind: "text", pages: 3,
        witnesses: [
            Witness("diffraction", pages: [1]),
            Witness("bragg", pages: [2],
                    note: "l'ordre des pages suit le NUMERO de diapositive, "
                        + "pas l'ordre alphabetique des entrees : slide10 est "
                        + "la troisieme page, pas la deuxieme"),
        ],
        note: "pptx a trois diapositives (1, 2, 10) : une page par diapositive, "
            + "triees numeriquement."))

    try makeArchive([
        ("mimetype", Data("application/vnd.oasis.opendocument.text".utf8)),
        ("content.xml", xml("""
            <office:document-content xmlns:office="o" xmlns:text="t">
            <office:body><office:text>
            <text:h>Memoire</text:h>
            <text:p>L'attaque nucleophile sur un carbone electrophile est le \
            terme temoin de ce document OpenDocument.</text:p>
            <text:p>Une seconde phrase, assez longue pour depasser le seuil de \
            cent caracteres natifs du §6.1 et ne pas partir en OCR.</text:p>
            </office:text></office:body></office:document-content>
            """)),
    ], at: try url("memoire.odt"))
    entries.append(Entry(
        "memoire.odt", ext: "odt", kind: "text", pages: 1,
        witnesses: [Witness("nucleophile", pages: [1])],
        note: "odt : content.xml, aucun gisement de media."))

    // ── 7. EPUB ─────────────────────────────────────────────────────────────
    try makeArchive([
        ("mimetype", Data("application/epub+zip".utf8)),
        ("META-INF/container.xml", xml("""
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf"
            media-type="application/oebps-package+xml"/></rootfiles></container>
            """)),
        ("OEBPS/content.opf", xml("""
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Proprietes colligatives</dc:title>
            <dc:creator>Corpus de fixtures</dc:creator>
            <dc:language>fr</dc:language></metadata>
            <manifest>
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
            </package>
            """)),
        ("OEBPS/ch1.xhtml", xml("""
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
            <h1>Premier chapitre</h1>
            <p>La cryoscopie mesure l'abaissement du point de fusion d'un \
            solvant par un solute non volatil. C'est le terme temoin du premier \
            chapitre de ce livre.</p>
            </body></html>
            """)),
        ("OEBPS/ch2.xhtml", xml("""
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
            <h1>Second chapitre</h1>
            <p>L'ebullioscopie en est la contrepartie a l'autre bout du \
            domaine liquide : c'est le terme temoin du second chapitre, et il \
            doit sortir a la page deux, pas a la page une.</p>
            </body></html>
            """)),
    ], at: try url("proprietes-colligatives.epub"))
    entries.append(Entry(
        "proprietes-colligatives.epub", ext: "epub", kind: "text", pages: 2,
        witnesses: [
            Witness("cryoscopie", pages: [1]),
            Witness("ebullioscopie", pages: [2],
                    note: "l'ordre des pages est celui du SPINE de l'OPF"),
        ],
        note: "epub a deux fichiers de spine : une page chacun (chaque fichier "
            + "tient sous pageSplitChars)."))

    // ── 8. CBZ : images à OCRiser ───────────────────────────────────────────
    try makeArchive([
        ("001.png", pngData(renderPageImage(
            lines: ["PLANCHE UNE", "MAGNETRON", "essai de mise sous vide"],
            width: 1000, height: 1400))),
        ("002.png", pngData(renderPageImage(
            lines: ["PLANCHE DEUX", "BOLOMETRE", "mesure du flux incident"],
            width: 1000, height: 1400))),
    ], at: try url("planches.cbz"))
    entries.append(Entry(
        "planches.cbz", ext: "cbz", kind: "scanned", pages: 2,
        witnesses: [
            Witness("magnetron", pages: [1], source: "ocr_accurate"),
            Witness("bolometre", pages: [2], source: "ocr_accurate"),
        ],
        note: "cbz de deux images PNG : aucune couche texte, les deux pages "
            + "entrent en file d'OCR et les termes temoins ne sortent que par "
            + "Vision."))

    // ── 9. DjVu (facultatif) ────────────────────────────────────────────────
    let djvuMade = try makeDjvu(
        pages: ["electrolyse de l'eau en milieu alcalin",
                "surtension cathodique et rendement faradique"],
        at: try url("notice.djvu"))
    entries.append(Entry(
        "notice.djvu", ext: "djvu", kind: "text", pages: 2,
        // TOUJOURS « djvulibre », que la fixture ait été produite ou non : le
        // champ dit ce que l'EXTRACTION exige à l'exécution, et c'est lui qui
        // fait sauter le test sur un runner sans djvused (CI du 02/09/2026).
        requires: "djvulibre",
        witnesses: [
            Witness("electrolyse", pages: [1]),
            Witness("faradique", pages: [2]),
        ],
        note: djvuMade
            ? "DjVu a deux pages, couche texte TXTz posee par djvused."
            : "NON PRODUIT sur cette machine : djvulibre absent au moment de "
            + "la generation. `brew install djvulibre` puis `make fixtures`. "
            + "Les tests qui en dependent se sautent."))

    // ── 10. iWork (.pages, .numbers) ─────────────────────────────────────────
    //
    // Deux formes nominales (audit D2 § 5.12, SPEC §5.3) :
    // - .pages sous forme d'archive ZIP avec QuickLook/Preview.pdf (2 pages)
    // - .numbers sous forme de paquet-répertoire avec QuickLook/Preview.pdf (1 page)
    let tempPagesDir = try temporaryDirectory("pages-preview")
    defer { try? fm.removeItem(at: tempPagesDir) }
    let tempPagesPDF = tempPagesDir.appendingPathComponent("Preview.pdf")
    try makeTextPDF(pages: [
        [
            "Rapport Pages — Mesure de turbidite",
            "La turbidite caracterise la presence de particules en suspension dans un liquide.",
            "Cette mesure optique a ete calibree a l'aide d'une cellule nephelometrique standard.",
        ],
        [
            "Rapport Pages — Releve barometrique",
            "La pression barometrique a ete enregistree toutes les dix minutes durant l'experience.",
            "Les donnees confirment la stabilite de la pression durant l'ensemble du cycle thermique.",
        ],
    ], at: tempPagesPDF)
    let pagesPDFData = try Data(contentsOf: tempPagesPDF)
    try makeArchive([
        ("Index/Document.iwa", Data("pages protobuf".utf8)),
        ("QuickLook/Preview.pdf", pagesPDFData),
    ], at: try url("rapport.pages"))
    entries.append(Entry(
        "rapport.pages", ext: "pages", kind: "text", pages: 2,
        witnesses: [
            Witness("turbidite", pages: [1]),
            Witness("barometrique", pages: [2]),
        ],
        note: "Document Pages (archive ZIP) avec QuickLook/Preview.pdf sur deux pages."))

    // Paquet-répertoire .numbers
    let numbersDir = try url("budget.numbers")
    try fm.createDirectory(at: numbersDir, withIntermediateDirectories: true)
    let numbersQL = numbersDir.appendingPathComponent("QuickLook", isDirectory: true)
    try fm.createDirectory(at: numbersQL, withIntermediateDirectories: true)
    let numbersIndex = numbersDir.appendingPathComponent("Index", isDirectory: true)
    try fm.createDirectory(at: numbersIndex, withIntermediateDirectories: true)
    try Data("numbers protobuf".utf8).write(to: numbersIndex.appendingPathComponent("Document.iwa"))
    let numbersPDF = numbersQL.appendingPathComponent("Preview.pdf")
    try makeTextPDF(pages: [
        [
            "Budget du laboratoire — Pyrometrie optique",
            "La pyrometrie optique permet la mesure sans contact des temperatures tres elevees.",
            "Les investissements en capteurs et optiques sont detailles dans le tableau ci-apres.",
        ],
    ], at: numbersPDF)
    entries.append(Entry(
        "budget.numbers", ext: "numbers", kind: "text", pages: 1,
        witnesses: [
            Witness("pyrometrie", pages: [1]),
        ],
        note: "Document Numbers (paquet repertoire) avec QuickLook/Preview.pdf sur une page."))

    // ── 10 bis. Bureautique ancienne, courriels, fichiers techniques (INT-F1) ─

    // .xls RÉEL : deux feuilles, une chaîne partagée COMPRESSÉE (un octet par
    // caractère, accents compris) et une en UTF-16 (le « μ » l'impose), un
    // nombre et un entier RK. C'est la fixture qui prouve que le format n'est
    // plus refusé d'office.
    try OLEWriter.compoundFile(streams: [
        ("Workbook", BIFFBuilder.workbook([
            BIFFBuilder.Sheet(name: "Mesures", cells: [
                (0, 0, .text("Ébulliométrie du solvant", wide: false)),
                (0, 1, .number(12.5)),
                (1, 0, .text("Seuil retenu", wide: false)),
                (1, 1, .integer(42)),
            ]),
            BIFFBuilder.Sheet(name: "Calculs", cells: [
                (0, 0, .text("Granulométrie laser, en μm", wide: true)),
            ]),
        ])),
    ]).write(to: try url("feuille-ancienne.xls"))
    entries.append(Entry(
        "feuille-ancienne.xls", ext: "xls", kind: "text", pages: 2,
        witnesses: [
            Witness("ebulliometrie", pages: [1],
                    note: "chaine partagee COMPRESSEE : un octet par caractere, "
                        + "accent compris"),
            Witness("granulometrie", pages: [2],
                    note: "chaine partagee UTF-16 (le « μm » l'impose) ; "
                        + "seconde feuille = seconde page (§5.3)"),
        ],
        note: "classeur Excel 97-2003 (conteneur OLE, flux Workbook, BIFF8) : "
            + "une page par feuille, cellules en ordre ligne puis colonne. "
            + "Refuse d'office jusqu'au lot INT-F1."))

    // .ppt RÉEL : trois diapositives, un TextCharsAtom (UTF-16), un
    // TextBytesAtom (un octet par caractère) et une note de présentateur.
    try OLEWriter.compoundFile(streams: [
        ("PowerPoint Document", PPTBuilder.document(
            slides: [
                [.chars("Thermoluminescence des minéraux")],
                [.bytes("Anémométrie à fil chaud")],
                [.chars("Tribologie des contacts secs")],
            ],
            notes: [[.chars("Rappeler le protocole")], [], []])),
    ]).write(to: try url("expose-ancien.ppt"))
    entries.append(Entry(
        "expose-ancien.ppt", ext: "ppt", kind: "text", pages: 3,
        witnesses: [
            Witness("thermoluminescence", pages: [1],
                    note: "TextCharsAtom (UTF-16)"),
            Witness("anemometrie", pages: [2],
                    note: "TextBytesAtom : un octet par caractere, "
                        + "Windows-1252"),
            Witness("tribologie", pages: [3]),
        ],
        note: "presentation PowerPoint 97-2003 (flux « PowerPoint Document », "
            + "SlideListWithText) : une page par diapositive, la note du "
            + "presentateur rejoint SA diapositive. Refusee d'office jusqu'au "
            + "lot INT-F1."))

    // Courriel Apple Mail : compteur d'octets, message, liste de drapeaux.
    let emlxMessage = """
    From: Amelie Roux <amelie@example.org>
    To: Bruno Vidal <bruno@example.org>
    Subject: Convocation du jeudi
    Date: Mon, 08 Sep 2026 09:00:00 +0200
    Content-Type: text/plain; charset=utf-8

    L'actinometrie chimique sera revue jeudi matin.
    """
    var emlx = Data("\(emlxMessage.utf8.count)\n".utf8)
    emlx.append(Data(emlxMessage.utf8))
    emlx.append(Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        + "<plist version=\"1.0\"><dict><key>flags</key>"
        + "<integer>8623620</integer></dict></plist>\n").utf8))
    try emlx.write(to: try url("message.emlx"))
    entries.append(Entry(
        "message.emlx", ext: "emlx", kind: "text", pages: 1,
        witnesses: [Witness("actinometrie", pages: [1])],
        note: "courriel Apple Mail : la premiere ligne donne la longueur du "
            + "message, la liste de proprietes de fin porte les drapeaux de "
            + "Mail et n'est PAS indexee."))

    // Courriel Outlook 15/2016 : du RFC 822 brut, sous une extension à
    // majuscules que le registre doit reconnaitre en minuscules.
    try write("""
    From: Bruno Vidal <bruno@example.org>
    To: Amelie Roux <amelie@example.org>
    Subject: Compte rendu
    Date: Mon, 08 Sep 2026 11:00:00 +0200
    Content-Type: text/plain; charset=utf-8

    L'ellipsometrie spectroscopique confirme l'epaisseur du depot.
    """, to: "courriel.olk15MsgSource")
    entries.append(Entry(
        "courriel.olk15MsgSource", ext: "olk15msgsource", kind: "text", pages: 1,
        witnesses: [Witness("ellipsometrie", pages: [1])],
        note: "source RFC 822 brute d'Outlook 15/2016. L'extension porte des "
            + "MAJUSCULES : le registre et le crawler comparent en minuscules."))

    // Archive mbox : trois messages, une page chacun. Le deuxieme porte une
    // ligne « >From » dans son corps — l'echappement du format, qui ne doit
    // surtout pas etre pris pour une frontiere de message.
    func mboxMessage(_ subject: String, _ body: String, _ hour: Int) -> String {
        """
        From amelie@example.org Mon Sep  8 \(hour):00:00 2026
        From: Amelie Roux <amelie@example.org>
        To: Bruno Vidal <bruno@example.org>
        Subject: \(subject)
        Date: Mon, 08 Sep 2026 \(hour):00:00 +0200
        Content-Type: text/plain; charset=utf-8

        \(body)

        """
    }
    try write(mboxMessage("Premier releve", "La colorimetrie du bain est stable.", 9)
              + mboxMessage("Deuxieme releve",
                            ">From le message precedent :\nLa conductimetrie a double.", 10)
              + mboxMessage("Troisieme releve", "La gravimetrie confirme le depot.", 11),
              to: "archive.mbox")
    entries.append(Entry(
        "archive.mbox", ext: "mbox", kind: "text", pages: 3,
        witnesses: [
            Witness("colorimetrie", pages: [1]),
            Witness("conductimetrie", pages: [2],
                    note: "le corps porte une ligne « >From » : l'echappement "
                        + "mboxrd ne doit PAS couper le message"),
            Witness("gravimetrie", pages: [3]),
        ],
        note: "archive mbox de trois messages : une page par message (§5.3)."))

    // Fichiers techniques : code source, TypeScript, XML, liste de proprietes.
    try write("""
    # Mesures de polarimetrie
    def mesurer(angle):
        \"\"\"Rend l'angle de rotation optique.\"\"\"
        return angle * 1.5
    """, to: "script.py")
    entries.append(Entry(
        "script.py", ext: "py", kind: "text", pages: 1,
        witnesses: [Witness("polarimetrie", pages: [1])],
        note: "code source Python : lu comme du texte brut, commentaires "
            + "compris (lot INT-F1)."))

    try write("""
    export const Fiche = () => (
      <section>
        <h1>Tensiometrie de surface</h1>
      </section>
    );
    """, to: "composant.tsx")
    entries.append(Entry(
        "composant.tsx", ext: "tsx", kind: "text", pages: 1,
        witnesses: [Witness("tensiometrie", pages: [1])],
        note: "source TypeScript/JSX : texte brut (lot INT-F1)."))

    try write("""
    <?xml version="1.0" encoding="UTF-8"?>
    <mesures identifiant="ne-doit-pas-entrer">
      <titre>Nephelometrie des suspensions</titre>
      <valeur unite="NTU">12</valeur>
    </mesures>
    """, to: "configuration.xml")
    entries.append(Entry(
        "configuration.xml", ext: "xml", kind: "text", pages: 1,
        witnesses: [Witness("nephelometrie", pages: [1])],
        note: "XML quelconque : texte des NŒUDS par SAX, attributs ignores "
            + "(« ne-doit-pas-entrer » ne doit pas ressortir)."))

    try write("""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>titre</key>
      <string>Sonometrie du local</string>
      <key>seuil</key>
      <integer>85</integer>
    </dict>
    </plist>
    """, to: "reglages.plist")
    entries.append(Entry(
        "reglages.plist", ext: "plist", kind: "text", pages: 1,
        witnesses: [Witness("sonometrie", pages: [1])],
        note: "liste de proprietes : rendue en « cle : valeur » par ligne."))

    // ── 11. Adobe et maquettes (lot INT-F2) ─────────────────────────────────
    //
    // Quatre fichiers, deux comportements. `.ai` et `.sketch` portent du TEXTE
    // et s'indexent ; `.fig` et `.indd` n'ont au mieux qu'un aperçu image, donc
    // rien à indexer tant que `extract.images` est éteint — c'est le cas par
    // défaut, et c'est celui que la recette exerce. Ils sont là pour prouver
    // que le refus est NOMMÉ (« exportez en PDF ») et classé `skipped`, et non
    // un « format non pris en charge » qui ferait croire à un oubli.
    //
    // Les IMAGES (heic, webp, gif, bmp, psd, RAW) ne sont PAS dans ce corpus,
    // et c'est délibéré : elles n'entrent dans l'index que sous
    // `extract.images`, que la recette d'intégration n'allume pas, et chacune
    // devrait peser plus de 64 Kio pour franchir le plancher d'OCR — de quoi
    // tripler un corpus qu'on veut menu. Elles sont couvertes par
    // `ImageExtractorTests`, qui les fabrique dans un dossier temporaire.

    // `.ai` : un PDF, avec l'en-tête PostScript que pose Illustrator quand on
    // demande la compatibilité.
    let aiPDF = try temporaryDirectory("ai").appendingPathComponent("layer.pdf")
    try makeTextPDF(pages: [[
        "Plan de travail 1",
        "Cette planche porte le terme temoin serigraphie, et c'est la couche",
        "PDF du fichier Illustrator qui le rend lisible : le format .ai est un",
        "PDF des qu'on laisse cochee la case « Creer un fichier compatible PDF ».",
    ]], at: aiPDF)
    var aiData = Data("%!PS-Adobe-3.0\n%%Creator: Adobe Illustrator(R)\n".utf8)
    aiData.append(try Data(contentsOf: aiPDF))
    try aiData.write(to: try url("dessin.ai"))
    entries.append(Entry(
        "dessin.ai", ext: "ai", kind: "text", pages: 1,
        witnesses: [Witness("serigraphie", pages: [1])],
        note: "Illustrator : en-tete PostScript puis couche PDF. L'extraction "
            + "delegue a PDFExtractor apres avoir retrouve « %PDF- »."))

    // `.sketch` : ZIP de JSON, une page Sketch = une page Fouine.
    try makeArchive([
        ("document.json", Data("""
            {"_class":"document","do_objectID":"D1","name":"Maquette Fouine",
             "pages":[{"_class":"MSJSONFileReference","_ref":"pages/A"},
                      {"_class":"MSJSONFileReference","_ref":"pages/B"}]}
            """.utf8)),
        ("meta.json", Data(#"{"app":"com.bohemiancoding.sketch3"}"#.utf8)),
        ("pages/A.json", Data("""
            {"_class":"page","do_objectID":"A","name":"Accueil","layers":[
              {"_class":"artboard","name":"Ecran de connexion","layers":[
                {"_class":"text","name":"titre",
                 "attributedString":{"_class":"attributedString",
                                     "string":"Anemometrie du hall"}}]}]}
            """.utf8)),
        ("pages/B.json", Data("""
            {"_class":"page","do_objectID":"B","name":"Reglages","layers":[
              {"_class":"symbolMaster","name":"Bouton principal","layers":[
                {"_class":"text","name":"etiquette",
                 "attributedString":{"_class":"attributedString",
                                     "string":"Piezoelectricite du capteur"}}]}]}
            """.utf8)),
    ], at: try url("maquette.sketch"))
    entries.append(Entry(
        "maquette.sketch", ext: "sketch", kind: "text", pages: 2,
        witnesses: [
            Witness("anemometrie", pages: [1]),
            Witness("piezoelectricite", pages: [2],
                    note: "l'ordre des pages est celui de document.json"),
        ],
        note: "Sketch : une page par page du document, texte = nom de la page, "
            + "noms des planches, puis les calques texte."))

    // `.fig` : ZIP Figma. Le canevas n'est pas lu ; la vignette n'est une page
    // que sous `extract.images`, éteint par défaut -> refus nommé.
    try makeArchive([
        ("meta.json", Data(#"{"client_meta":{"file_name":"Maquette"}}"#.utf8)),
        ("canvas.fig", Data(repeating: 0x00, count: 1_024)),
        ("thumbnail.png", pngData(renderPageImage(
            lines: ["FIGMA", "vignette"], width: 640, height: 480))),
    ], at: try url("maquette.fig"))
    entries.append(Entry(
        "maquette.fig", ext: "fig", kind: "trap", pages: 0,
        state: "skipped",
        err: "fig: no text layer readable — export the frames as PDF or SVG",
        note: "Figma : le canevas est un binaire « kiwi » non documente, jamais "
            + "analyse. Sans `extract.images`, refus NOMME et classe skipped."))

    // `.indd` : conteneur InDesign synthétique — en-tête, puis un aperçu PNG.
    var inddData = Data("Adobe InDesign Document".utf8)
    inddData.append(Data(repeating: 0x00, count: 2_048))
    inddData.append(pngData(renderPageImage(lines: ["INDESIGN", "apercu"],
                                            width: 480, height: 640)))
    try inddData.write(to: try url("mise-en-page.indd"))
    entries.append(Entry(
        "mise-en-page.indd", ext: "indd", kind: "trap", pages: 0,
        state: "skipped",
        err: "indd: no readable text — export as PDF or IDML",
        note: "InDesign : le texte est dans un conteneur proprietaire, jamais "
            + "lu. Un apercu integre existe, mais il ne devient une page qu'avec "
            + "`extract.images` ; sinon refus NOMME et classe skipped."))

    // ── 12. Pièges ──────────────────────────────────────────────────────────
    //
    // Le nom d'entrée piégé de l'audit S1 : sans le `--` de `Bsdtar`, bsdtar
    // lisait « --use-compress-program=… » comme une OPTION et exécutait le
    // programme désigné à l'indexation. La fixture VERSIONNÉE désigne
    // /usr/bin/false — inerte par construction : si l'injection revenait, elle
    // ferait échouer l'extraction au lieu d'exécuter quoi que ce soit de
    // dangereux sur la machine d'un contributeur. Le test qui vérifie qu'AUCUN
    // programme n'est exécuté (marqueur sur disque) reste dans GuardTests, où
    // le chemin du marqueur peut être temporaire.
    //
    // « --exclude=001.png » est le second piège, et le plus insidieux : sans
    // `--`, il RETIRAIT 001.png de la sortie. Le manifeste attend donc DEUX
    // pages, pas une.
    try makeArchive([
        ("001.png", pngData(renderPageImage(
            lines: ["PLANCHE PIEGEE", "PERMEABILITE"], width: 1000, height: 1400))),
        ("--use-compress-program=/usr/bin/false", Data("charge utile".utf8)),
        ("--exclude=001.png", pngData(renderPageImage(
            lines: ["SECONDE PLANCHE", "CALORIMETRE"], width: 1000, height: 1400))),
    ], at: try url("pieges/archive-piegee.cbz"))
    entries.append(Entry(
        "pieges/archive-piegee.cbz", ext: "cbz", kind: "trap", pages: 2,
        witnesses: [
            Witness("calorimetre", pages: [1], source: "ocr_accurate",
                    note: "entree « --exclude=001.png ». Elle est PREMIERE : "
                        + "les entrees image sont triees naturellement et "
                        + "« - » precede « 0 »"),
            Witness("permeabilite", pages: [2], source: "ocr_accurate",
                    note: "entree « 001.png ». Sans le `--` de Bsdtar, "
                        + "« --exclude=001.png » l'aurait RETIREE de la sortie "
                        + "et cette page n'existerait pas"),
        ],
        note: "PIEGE S1 : deux entrees dont le NOM ressemble a une option de "
            + "bsdtar. Attendu : deux pages image (« --exclude=001.png » ne "
            + "doit PAS retirer 001.png), extraction reussie, et rien "
            + "d'execute. L'entree « --use-compress-program » designe "
            + "/usr/bin/false, inerte : le test de non-execution avec marqueur "
            + "est dans Tests/FouineExtractTests/GuardTests.swift."))

    // Deux documents CHIFFRÉS (lot INT-F1). `.xls` et `.ppt` ne sont plus
    // refusés d'office : ces deux pièges prouvent le refus qui RESTE, celui
    // qu'aucun lecteur ne peut lever — un classeur et une présentation protégés
    // par mot de passe. Ils doivent apparaître dans `docs` en `skipped`, avec
    // LEUR motif, et non manquer en silence.
    try OLEWriter.compoundFile(streams: [
        ("Workbook", BIFFBuilder.encryptedWorkbook()),
    ]).write(to: try url("pieges/tableur-ancien.xls"))
    entries.append(Entry(
        "pieges/tableur-ancien.xls", ext: "xls", kind: "trap", pages: 0,
        state: "skipped", err: "password-protected workbook",
        note: "classeur BIFF CHIFFRE (enregistrement FILEPASS) : refuse "
            + "proprement (docs.state = skipped, docs.err nomme le motif), et "
            + "non ignore en silence. C'est le seul refus qui reste sur .xls "
            + "depuis le lot INT-F1."))
    try OLEWriter.compoundFile(streams: [
        ("PowerPoint Document", PPTBuilder.encryptedDocument()),
    ]).write(to: try url("pieges/presentation-ancienne.ppt"))
    entries.append(Entry(
        "pieges/presentation-ancienne.ppt", ext: "ppt", kind: "trap", pages: 0,
        state: "skipped", err: "password-protected presentation",
        note: "presentation CHIFFREE (CryptSession10Container) : meme cas que "
            + "le classeur ci-dessus, docs.state = skipped."))

    // Source MINIFIEE : du texte, mais du texte que personne ne lit et dont
    // chaque « mot » polluerait le vocabulaire de la recherche floue (§5.5.2).
    try write(String(repeating: "var a=1;function b(c){return c+1}", count: 40),
              to: "pieges/page.min.js")
    entries.append(Entry(
        "pieges/page.min.js", ext: "js", kind: "trap", pages: 0,
        state: "skipped", err: "minified source",
        note: "source minifiee : refusee sur son NOM (.min.js) avant meme la "
            + "forme du texte, docs.state = skipped."))

    // iWork sans preview : échec explicite exigé dans docs.err
    try makeArchive([
        ("Index/Document.iwa", Data("keynote protobuf".utf8)),
    ], at: try url("pieges/presentation-sans-preview.key"))
    entries.append(Entry(
        "pieges/presentation-sans-preview.key", ext: "key", kind: "trap", pages: 0,
        state: "failed",
        err: "iWork document without a QuickLook preview — open it once in Pages to generate one",
        note: "iWork sans QuickLook/Preview.pdf : echec explicite dans docs.err."))

    // Extension HORS registre : le crawler ne doit même pas la voir.
    try pngData(renderPageImage(lines: ["HORS REGISTRE"], width: 400, height: 300))
        .write(to: try url("pieges/photo.png"))
    entries.append(Entry(
        "pieges/photo.png", ext: "png", kind: "ignored", pages: nil,
        state: "absent",
        note: "extension HORS du registre d'extraction : ce fichier ne doit "
            + "PAS apparaitre dans `docs` du tout — ni extrait, ni saute."))

    // ── Manifeste ───────────────────────────────────────────────────────────
    let manifest = Manifest(
        schema: 1,
        generator: "Tools/make_fixtures.swift",
        note: "Corpus de fixtures VERSIONNE (audit E5). Regenere par "
            + "`make fixtures`. Les fichiers decrits ici sont dans le depot : "
            + "les tests les lisent tels quels et n'appellent JAMAIS le "
            + "generateur. Le manifeste decrit le CONTENU attendu (termes "
            + "temoins, pages, provenance) et jamais une empreinte : une "
            + "regeneration donne des fichiers equivalents, pas identiques.",
        indexedFiles: entries.filter { $0.kind != "ignored" }.count,
        files: entries)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(manifest)
    try data.write(to: outputDirectory.appendingPathComponent("manifest.json"))

    // ── Compte rendu ────────────────────────────────────────────────────────
    var total = 0
    var produced = 0
    for entry in entries {
        let file = outputDirectory.appendingPathComponent(entry.name)
        if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int {
            total += size
            produced += 1
        }
    }
    let kib = Double(total) / 1024
    print(String(format: "corpus : %d fichiers, %.1f Kio -> %@",
                 produced, kib, outputDirectory.path))
    if !djvuMade {
        print("  djvulibre absent : notice.djvu NON produit "
              + "(brew install djvulibre, puis make fixtures)")
    }
    if produced != entries.count {
        print("  \(entries.count - produced) fixture(s) non produite(s)")
    }
} catch {
    fail("\(error)")
}
