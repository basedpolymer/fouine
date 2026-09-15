// MediaDecoder.swift — le son d'un média, en petits morceaux (lot INT-F3).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Ingest.
//
// DEUX RESPONSABILITÉS, et rien d'autre : découper un enregistrement en
// FENÊTRES de dix minutes, et rendre le son de chaque fenêtre sous une forme
// que la reconnaissance sait avaler.
//
// POURQUOI DES FENÊTRES. Une reconnaissance sur l'appareil garde en mémoire
// tout ce qu'elle a entendu depuis le début de la requête ; sur un cours de
// deux heures, cela finit par peser, et un échec en fin de course perdrait les
// deux heures. Dix minutes bornent les deux : la mémoire, et ce qu'on perd.
// Elles donnent aussi son sens à la PAGE — une page de média, c'est dix minutes
// d'enregistrement, unité qu'un lecteur retrouve dans son fichier.
//
// POURQUOI PAS DE FICHIER TEMPORAIRE. La voie évidente — exporter chaque
// fenêtre en `.caf` puis la donner à `SFSpeechURLRecognitionRequest` — écrit
// des dizaines de mégaoctets par heure d'audio et fait dépendre l'extraction de
// la place disponible. `AVAssetReader` rend les mêmes échantillons en flux, et
// `SFSpeechAudioBufferRecognitionRequest.appendAudioSampleBuffer` les prend
// TELS QUELS : pas de conversion à la main, pas de `AVAudioPCMBuffer`
// intermédiaire, rien sur le disque. Seule exception, ci-dessous : les
// conteneurs qu'AVFoundation n'ouvre pas, qui passent par ffmpeg et donc, eux,
// par un fichier.

import Foundation
import AVFoundation
import FouineCore

enum MediaDecoder {

    /// Longueur d'une fenêtre, en secondes : UNE PAGE de média.
    static let windowSeconds: TimeInterval = 600

    /// Découpage d'une durée en fenêtres. Une fenêtre finale plus courte est
    /// gardée telle quelle — la tronquer perdrait la fin de l'enregistrement,
    /// et l'arrondir ferait lire du silence.
    static func windows(duration: TimeInterval,
                        length: TimeInterval = windowSeconds) -> [CMTimeRange] {
        guard duration > 0, length > 0 else { return [] }
        var ranges: [CMTimeRange] = []
        var start: TimeInterval = 0
        while start < duration {
            let span = min(length, duration - start)
            ranges.append(CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: span, preferredTimescale: 600)))
            start += length
        }
        return ranges
    }

    // MARK: - Lecture des échantillons

    /// Réglages de sortie : PCM linéaire, mono, 16 kHz, 16 bits.
    ///
    /// 16 kHz parce que c'est le taux d'échantillonnage de la dictée d'Apple :
    /// donner du 48 kHz stéréo ne rendrait pas la reconnaissance meilleure, il
    /// la ferait rééchantillonner elle-même — trois fois plus d'octets copiés
    /// pour le même résultat.
    static let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    /// Un lecteur ARMÉ sur une fenêtre, prêt à rendre ses échantillons.
    struct Window {
        let reader: AVAssetReader
        let output: AVAssetReaderOutput

        /// L'échantillon suivant, ou `nil` à la fin de la fenêtre.
        func next() -> CMSampleBuffer? { output.copyNextSampleBuffer() }

        /// À appeler DANS TOUS LES CAS, y compris sur un abandon : sans lui, le
        /// lecteur garde le fichier ouvert et ses tampons jusqu'au ramasse-miettes.
        func cancel() { reader.cancelReading() }
    }

    /// Arme un lecteur sur une fenêtre. `nil` si le média n'a aucune piste son
    /// (une vidéo muette) ou si le lecteur refuse de démarrer.
    ///
    /// La construction passe par `MediaAsync` : `loadTracks` est la seule forme
    /// non dépréciée depuis macOS 13, et elle est asynchrone.
    static func window(url: URL, range: CMTimeRange,
                       seconds: TimeInterval) throws -> Window? {
        try MediaAsync.wait(label: "audio window \(url.lastPathComponent)",
                            seconds: seconds) {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else { return nil }
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = range
            let output = AVAssetReaderAudioMixOutput(audioTracks: tracks,
                                                     audioSettings: audioSettings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { return nil }
            return Window(reader: reader, output: output)
        }
    }

    // MARK: - Conteneurs étrangers : ffmpeg

    /// Les conteneurs qu'AVFoundation N'OUVRE PAS sur macOS et que ffmpeg sait
    /// lire. La liste sert à deux choses et pas une de plus : décider si l'on
    /// tente ffmpeg, et nommer le refus quand ffmpeg est absent.
    static let ffmpegContainers: Set<String> =
        ["mkv", "avi", "wmv", "webm", "ogg", "oga", "opus"]

    static let ffmpegExecutable = "ffmpeg"
    static let ffprobeExecutable = "ffprobe"

    /// Chemin de ffmpeg s'il est installé. Mêmes répertoires explicites que
    /// djvused (`ExternalTool.searchPaths`), et pour la même raison : sous
    /// launchd et sous le Finder, `PATH` est minimal ou absent.
    /// `directories` n'est paramétrable QUE pour les tests : le refus « ffmpeg
    /// absent » ne se prouve pas sur une machine où ffmpeg est installé, et
    /// déplacer le binaire du système pour le vérifier serait pire.
    static func ffmpeg(directories: [String] = ExternalTool.searchPaths) -> String? {
        Subprocess.tool(ffmpegExecutable,
                        overrideVariable: ExternalTool.overrideVariable(
                            for: ffmpegExecutable),
                        directories: directories)
    }

    /// ffprobe est cherché À CÔTÉ de ffmpeg, et non indépendamment : les deux
    /// viennent du même paquet, et un ffprobe d'une autre version que le ffmpeg
    /// retenu n'apporterait rien qu'une incohérence possible.
    static func ffprobe(besides ffmpegPath: String) -> String? {
        let candidate = (ffmpegPath as NSString)
            .deletingLastPathComponent
            .appending("/" + ffprobeExecutable)
        return FileManager.default.isExecutableFile(atPath: candidate)
            ? candidate : nil
    }

    /// LA LISTE BLANCHE DES PROTOCOLES (constat CM-23), à poser AVANT `-i` :
    /// elle borne ce que l'entrée a le droit d'ouvrir. Sans elle, un `.mkv` qui
    /// est en réalité une playlist HLS ou un script `ffconcat` fait ouvrir à
    /// ffmpeg l'adresse `http://…` qu'il porte — c'est-à-dire une balise, dans
    /// un produit qui promet le silence réseau.
    ///
    /// L'audit a mesuré que ffmpeg 9.0.1 refuse ces deux pièges DE LUI-MÊME
    /// (auto-détection HLS désarmée hors extension standard, `safe` du
    /// démultiplexeur concat). C'est précisément le problème : la protection
    /// venait de l'outil, pas de Fouine, et un ffmpeg plus ancien ou compilé
    /// autrement la retirerait sans que rien ne le dise.
    static let protocolWhitelist = ["-protocol_whitelist", "file"]

    /// Convertit un conteneur étranger en WAV mono 16 kHz dans `destination`.
    ///
    /// `-nostdin` : sans lui, ffmpeg lit l'entrée standard du processus père et
    /// peut consommer ce qui ne lui appartient pas (la même précaution que
    /// `standardInput = nullDevice` côté `Subprocess`, ceinture et bretelles).
    /// `-vn` jette la vidéo : on ne veut que le son, et décoder les images
    /// coûterait le plus clair du temps de conversion.
    static func convertArguments(url: URL, to destination: URL) -> [String] {
        ["-nostdin", "-v", "error", "-y"] + protocolWhitelist
            + ["-i", url.path,
               "-vn", "-ac", "1", "-ar", "16000", "-f", "wav", destination.path]
    }

    static func convert(url: URL, ffmpeg: String, to destination: URL,
                        timeout: TimeInterval) throws {
        _ = try Subprocess.run(
            ffmpeg,
            convertArguments(url: url, to: destination),
            what: url.lastPathComponent,
            maxOutputBytes: 1 << 20,   // ffmpeg écrit dans le FICHIER, pas sur stdout
            timeout: timeout)
    }
}
