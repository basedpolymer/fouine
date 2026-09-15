// MediaMetadata.swift — ce qu'un fichier son ou vidéo DIT DE LUI-MÊME
// (SPEC §5.3, lot INT-F3). Propriété : A-Ingest.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// PREMIER ÉTAGE de la famille « médias », et le seul qui coûte des
// millisecondes : titre, artiste, album, auteur, description, commentaire,
// paroles, date, durée, chapitres. C'est ce qui rend une bibliothèque
// cherchable sans transcrire une seule seconde de son — et pour beaucoup de
// fonds (conférences nommées, entretiens datés, cours numérotés), c'est déjà
// tout ce qu'on cherche.
//
// LE TEXTE PRODUIT EST ANGLAIS, et c'est délibéré : ce sont des lignes
// INDEXÉES, pas de l'interface. Elles suivent la même règle que les en-têtes
// « Subject: » / « From: » qu'`EMLExtractor` met en tête d'un courriel — la
// langue de l'app n'a pas à changer le contenu de l'index, sans quoi une base
// bâtie en français ne se chercherait plus en anglais.
//
// API MODERNE, PAS DÉPRÉCIÉE. `asset.metadata`, `asset.duration` et
// `item.stringValue` sont dépréciés depuis macOS 13 (notre cible minimale) au
// profit de `load(_:)`, qui est asynchrone. Le protocole `TextExtractor` étant
// synchrone, la traversée se fait par `MediaAsync.wait` — une fois, en haut, et
// non à chaque propriété lue.

import Foundation
import AVFoundation
import FouineCore

/// Ce qu'on a su lire d'un média, sous une forme indexable.
struct MediaMetadata {

    struct Field {
        let label: String
        let value: String
    }

    struct Chapter {
        let start: TimeInterval
        let title: String
    }

    /// Les champs, DANS L'ORDRE d'affichage — un dictionnaire les rendrait dans
    /// un ordre différent à chaque extraction, et deux passes sur le même
    /// fichier produiraient deux textes de page distincts pour rien.
    var fields: [Field] = []
    var chapters: [Chapter] = []
    /// Durée en secondes, 0 si le conteneur ne la donne pas.
    var duration: TimeInterval = 0

    var isEmpty: Bool { fields.isEmpty && chapters.isEmpty }

    /// La page 1 d'un média : « Title: … » ligne par ligne, puis les chapitres.
    /// La DURÉE n'y figure que si elle est connue : « Duration: 00:00 » sur un
    /// flux dont on n'a pas su lire la longueur serait un mensonge indexé.
    var text: String {
        var lines = fields.map { "\($0.label): \($0.value)" }
        if duration > 0 {
            lines.append("Duration: \(Self.timestamp(duration))")
        }
        if !chapters.isEmpty {
            lines.append("Chapters:")
            lines.append(contentsOf: chapters.map {
                "[\(Self.timestamp($0.start))] \($0.title)"
            })
        }
        return lines.joined(separator: "\n")
    }

    /// `mm:ss`, ou `h:mm:ss` au-delà de l'heure. Un cours de deux heures
    /// s'afficherait « 125:03 » sans ce second cas — lisible pour une machine,
    /// pas pour qui cherche le chapitre de la deuxième heure.
    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let (h, m, s) = (total / 3_600, (total % 3_600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }

    // MARK: - Lecture par AVFoundation

    /// Ce qu'AVFoundation a rendu : les métadonnées, et surtout SI le
    /// conteneur s'est ouvert. Les deux réponses sont distinctes — un `.mkv`
    /// qui ne s'ouvre pas doit basculer sur ffmpeg, un `.m4a` qui s'ouvre sans
    /// une balise doit être refusé « no metadata ».
    struct Reading {
        let opened: Bool
        let metadata: MediaMetadata
        /// Pistes son présentes ; sans elles, rien à transcrire.
        let hasAudio: Bool
    }

    /// Lit un média par AVFoundation. Ne LÈVE PAS quand le conteneur est
    /// illisible : c'est une réponse (`opened == false`), pas une erreur — le
    /// choix de basculer sur ffmpeg ou de refuser appartient à l'extracteur.
    static func read(url: URL, seconds: TimeInterval) -> Reading {
        (try? MediaAsync.wait(label: "media metadata \(url.lastPathComponent)",
                              seconds: seconds) { try await readAsync(url: url) })
            ?? Reading(opened: false, metadata: MediaMetadata(), hasAudio: false)
    }

    private static func readAsync(url: URL) async throws -> Reading {
        let asset = AVURLAsset(url: url)
        // `load(.tracks)` est le test d'ouverture : sur un conteneur
        // qu'AVFoundation ne connaît pas (mkv, avi, wmv…) il lève, alors que
        // `AVURLAsset(url:)` réussit toujours — l'objet est un descripteur, pas
        // un fichier ouvert.
        let tracks: [AVAssetTrack]
        do { tracks = try await asset.load(.tracks) } catch {
            return Reading(opened: false, metadata: MediaMetadata(), hasAudio: false)
        }
        var meta = MediaMetadata()
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            meta.duration = CMTimeGetSeconds(duration)
        }

        var items: [AVMetadataItem] = (try? await asset.load(.commonMetadata)) ?? []
        items += (try? await asset.load(.metadata)) ?? []
        meta.fields = await fields(from: items)
        meta.chapters = await chapters(of: asset)

        let hasAudio = tracks.contains { $0.mediaType == .audio }
        return Reading(opened: true, metadata: meta, hasAudio: hasAudio)
    }

    /// Les clés retenues, DANS L'ORDRE du texte produit. Volontairement
    /// courte : un mp3 d'iTunes porte parfois quarante balises (identifiant de
    /// magasin, numéro de piste, gain de lecture) dont aucune ne se cherche.
    private static let commonKeys: [(AVMetadataKey, String)] = [
        (.commonKeyTitle, "Title"),
        (.commonKeyArtist, "Artist"),
        // QuickTime range l'interprète du morceau sous « contributor » et non
        // sous « artist » (mesuré sur un `.mp4` écrit par `AVAssetWriter`) :
        // les deux clés portent la même chose et donnent donc la même ligne.
        // `add` garde la PREMIÈRE valeur non vide, donc `artist` gagne quand
        // les deux sont là.
        (.commonKeyContributor, "Artist"),
        (.commonKeyAlbumName, "Album"),
        (.commonKeyAuthor, "Author"),
        (.commonKeyCreator, "Creator"),
        (.commonKeyDescription, "Description"),
        (.commonKeyPublisher, "Publisher"),
        (.commonKeyCreationDate, "Date"),
    ]

    private static func fields(from items: [AVMetadataItem]) async -> [Field] {
        var byLabel: [String: String] = [:]
        var order: [String] = []
        func add(_ label: String, _ value: String?) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // PREMIÈRE valeur gagnante : `commonMetadata` est lu avant
            // `metadata`, et c'est la forme normalisée par AVFoundation qu'on
            // préfère à la balise brute du conteneur.
            guard !trimmed.isEmpty, byLabel[label] == nil else { return }
            byLabel[label] = trimmed
            order.append(label)
        }

        for item in items {
            let value = try? await item.load(.stringValue)
            if let common = item.commonKey,
               let label = commonKeys.first(where: { $0.0 == common })?.1 {
                add(label, value)
                continue
            }
            switch item.identifier {
            case AVMetadataIdentifier.iTunesMetadataLyrics,
                 AVMetadataIdentifier.id3MetadataUnsynchronizedLyric:
                add("Lyrics", value)
            case AVMetadataIdentifier.iTunesMetadataUserComment,
                 AVMetadataIdentifier.id3MetadataComments,
                 AVMetadataIdentifier.quickTimeMetadataComment:
                add("Comment", value)
            case AVMetadataIdentifier.quickTimeMetadataDescription,
                 AVMetadataIdentifier.iTunesMetadataDescription:
                add("Description", value)
            default:
                continue
            }
        }
        // L'ordre de sortie est celui de `commonKeys`, puis les trois clés
        // spécifiques : il ne dépend donc pas de l'ordre des balises du
        // fichier, et deux extractions du même média donnent le même texte.
        let preferred = commonKeys.map(\.1) + ["Description", "Comment", "Lyrics"]
        let ranked = order.sorted {
            (preferred.firstIndex(of: $0) ?? .max) < (preferred.firstIndex(of: $1) ?? .max)
        }
        return ranked.compactMap { label in
            byLabel[label].map { Field(label: label, value: $0) }
        }
    }

    private static func chapters(of asset: AVURLAsset) async -> [Chapter] {
        let groups = (try? await asset.loadChapterMetadataGroups(
            bestMatchingPreferredLanguages: Locale.preferredLanguages)) ?? []
        var result: [Chapter] = []
        for group in groups {
            var title: String?
            for item in group.items where item.commonKey == .commonKeyTitle {
                title = try? await item.load(.stringValue)
                break
            }
            guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { continue }
            result.append(Chapter(start: CMTimeGetSeconds(group.timeRange.start),
                                  title: title))
        }
        return result
    }

    // MARK: - Lecture par ffprobe (conteneurs qu'AVFoundation ignore)

    /// Métadonnées d'un conteneur étranger, par `ffprobe -show_format`.
    ///
    /// Une SEULE invocation, et pas de `-show_streams` : le format porte la
    /// durée et les balises (`tags`), les flux ne porteraient que des débits et
    /// des codecs — rien qui se cherche.
    /// Les arguments de la sonde, à part pour être éprouvés sans ffprobe.
    /// `-protocol_whitelist file` AVANT `-i` : voir `MediaDecoder`, c'est la
    /// même borne pour la même raison (CM-23). ffprobe est le PREMIER des deux
    /// à voir un média étranger — il tourne dès `extract.media`, sans
    /// transcription — donc c'est lui qui compte le plus.
    static func probeArguments(url: URL) -> [String] {
        ["-v", "error"] + MediaDecoder.protocolWhitelist
            + ["-show_format", "-print_format", "json", "-i", url.path]
    }

    static func probe(url: URL, ffprobe: String) -> MediaMetadata? {
        let name = url.lastPathComponent
        guard let data = try? Subprocess.run(
                ffprobe, probeArguments(url: url),
                what: name, maxOutputBytes: 1 << 20, timeout: 30),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = root["format"] as? [String: Any]
        else { return nil }

        var meta = MediaMetadata()
        if let duration = format["duration"] as? String, let value = Double(duration) {
            meta.duration = value
        } else if let duration = format["duration"] as? Double {
            meta.duration = duration
        }
        // Les balises de ffprobe sont libres et leur CASSE varie d'un conteneur
        // à l'autre (« TITLE » en Matroska, « title » en Ogg) : on compare en
        // minuscules plutôt que d'énumérer les deux formes.
        let tags = (format["tags"] as? [String: Any]) ?? [:]
        var lowered: [String: String] = [:]
        for (key, value) in tags {
            if let text = value as? String { lowered[key.lowercased()] = text }
        }
        let wanted: [(String, String)] = [
            ("title", "Title"), ("artist", "Artist"), ("album", "Album"),
            ("author", "Author"), ("description", "Description"),
            ("comment", "Comment"), ("lyrics", "Lyrics"), ("date", "Date"),
        ]
        for (tag, label) in wanted {
            guard let value = lowered[tag]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            meta.fields.append(Field(label: label, value: value))
        }
        return meta
    }
}

// MARK: - Traversée asynchrone

/// Attendre, depuis un appelant SYNCHRONE, un travail asynchrone borné.
///
/// POURQUOI CE PONT EXISTE. `TextExtractor.extract` est synchrone (le protocole
/// est partagé par vingt extracteurs, dont aucun autre n'a besoin de `async`),
/// et toute l'API moderne d'AVFoundation ne l'est pas. Les propriétés
/// synchrones existent encore mais sont DÉPRÉCIÉES depuis macOS 13 — les
/// employer, c'est écrire du code qui ne compilera plus sur la prochaine cible.
///
/// LE DANGER, ET SA BORNE. Bloquer un fil pendant qu'une tâche tourne sur le
/// pool coopératif est sûr TANT QUE L'APPELANT N'EST PAS LUI-MÊME sur ce pool.
/// Ici il ne l'est jamais : l'extraction tourne sur une `OperationQueue`
/// (`IndexPass`), les tests sur le fil XCTest. Le délai de garde est la seconde
/// borne : au-delà, la tâche est annulée et l'erreur remonte comme n'importe
/// quel dépassement d'extraction.
enum MediaAsync {

    static func wait<T>(label: String, seconds: TimeInterval,
                        _ body: @escaping () async throws -> T) throws -> T {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        let task = Task {
            do { box.set(.success(try await body())) }
            catch { box.set(.failure(error)) }
            done.signal()
        }
        if done.wait(timeout: .now() + seconds) == .timedOut {
            task.cancel()
            throw FouineError.extraction(
                "deadline exceeded (\(Int(seconds)) s): \(label)")
        }
        switch box.take() {
        case .success(let value): return value
        case .failure(let error): throw error
        case nil: throw FouineError.extraction("no result: \(label)")
        }
    }

    /// Même motif que `Deadline.ResultBox` : le résultat traverse deux fils, il
    /// lui faut un verrou, et `T` n'est pas toujours `Sendable`.
    private final class Box<T>: @unchecked Sendable {
        private let mutex = NSLock()
        private var stored: Result<T, Error>?
        func set(_ value: Result<T, Error>) {
            mutex.lock(); stored = value; mutex.unlock()
        }
        func take() -> Result<T, Error>? {
            mutex.lock(); defer { mutex.unlock() }; return stored
        }
    }
}
