// MediaPreviewView.swift — écouter le passage trouvé (lot PV1).
// Propriété : A-App.
//
// CE QUE FOUINE SAVAIT DÉJÀ, ET NE MONTRAIT PAS. Un son ou une vidéo s'indexe
// en fenêtres de dix minutes ; chaque fenêtre est une page, et son texte est
// coupé en paragraphes qui s'ouvrent sur leur moment — « [12:40] ». Trouver le
// mot dans un cours de deux heures ne servait pourtant à rien : il fallait
// ouvrir l'enregistrement ailleurs et retrouver le passage à la main.
//
// D'où cette vue : le lecteur au-dessus, la transcription dessous, et chaque
// moment cliquable. Le passage trouvé est sous la tête de lecture dès
// l'ouverture — mais RIEN NE DÉMARRE : un son qui part tout seul dans une
// bibliothèque partagée ou une salle de cours est une mauvaise surprise, et
// c'est la seule chose que le panneau d'aperçu ne peut pas défaire.

import SwiftUI
import AVKit
import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// Le lecteur, et ce qu'il faut retenir de lui entre deux évaluations de `body`.
///
/// Un objet, et non un `@State` : `AVPlayer` doit survivre au redessin, et
/// c'est aussi lui qui tient l'observateur de temps — posé une fois, retiré une
/// fois. Recréer le lecteur à chaque `body` relancerait le décodage à chaque
/// survol de bouton.
@MainActor
final class TranscriptPlayer: ObservableObject {

    let player = AVPlayer()

    /// L'enregistrement porte-t-il une image ? La réponse d'abord DEVINÉE sur
    /// l'extension (le type déclaré par macOS), puis corrigée quand les pistes
    /// du fichier ont répondu : `mkv`, `webm` et `opus` n'ont pas de type
    /// déclaré, et un son qu'on prendrait pour une vidéo s'afficherait dans un
    /// grand rectangle noir.
    @Published private(set) var hasVideo = false

    private var timeObserver: Any?
    private var loadedURL: URL?

    /// Prépare la lecture et pose la tête au début du passage. `onTime` reçoit
    /// la position, à la seconde : c'est elle que « Copier la référence » cite.
    func load(url: URL, startingAt seconds: Int, onTime: @escaping (Int) -> Void) {
        guard loadedURL != url else { return }
        loadedURL = url
        hasVideo = Self.looksLikeVideo(url)
        let asset = AVURLAsset(url: url)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        seek(to: seconds, thenPlay: false)
        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 1, preferredTimescale: 1),
                queue: .main) { time in
                    onTime(max(0, Int(time.seconds.isFinite ? time.seconds : 0)))
                }
        }
        Task { [weak self] in
            let tracks = try? await asset.loadTracks(withMediaType: .video)
            self?.hasVideo = !(tracks?.isEmpty ?? true)
        }
    }

    func seek(to seconds: Int, thenPlay: Bool) {
        // Tolérance nulle : à une demi-seconde près, la lecture reprend au
        // milieu du mot précédent, et le repère cliqué n'aurait pas tenu sa
        // promesse.
        player.seek(to: CMTime(seconds: Double(max(0, seconds)), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        if thenPlay { player.play() }
    }

    func pause() { player.pause() }

    /// Le type déclaré par macOS, quand il en connaît un.
    private static func looksLikeVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased())
        else { return false }
        if type.conforms(to: .audio) { return false }
        return type.conforms(to: .audiovisualContent)
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }
}

/// `AVPlayerView` d'AVKit : la barre de transport du système, celle que tout le
/// monde sait manier — un lecteur écrit à la main perdrait le volume, la
/// vitesse, le plein écran et le sous-titrage.
private struct TransportView: NSViewRepresentable {
    let player: AVPlayer
    let compact: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = compact ? .inline : .floating
        view.showsFullScreenToggleButton = !compact
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        let style: AVPlayerViewControlsStyle = compact ? .inline : .floating
        if view.controlsStyle != style { view.controlsStyle = style }
    }
}

struct MediaPreviewView: View {

    let url: URL
    /// Le texte de la page affichée, s'il y en a un : la transcription d'une
    /// fenêtre de dix minutes, ou la page de balises de l'enregistrement.
    let page: PageTextContent?
    let terms: [HighlightTerm]
    /// Où poser la tête de lecture à l'ouverture.
    let start: Int
    /// Ce que le lecteur doit retenir à chaque seconde : `PreviewModel` le cite.
    let onPlayhead: (Int) -> Void

    @StateObject private var transcript = TranscriptPlayer()
    /// Surlignage calculé une fois par (page, jeu de termes) — même raison que
    /// `TextPreviewView` : `body` est réévalué pour un simple survol.
    @State private var rendered: [Int: AttributedString] = [:]

    private var blocks: [TranscriptMarkers.Block] {
        TranscriptMarkers.blocks(page?.text ?? "")
    }

    private var renderKey: String {
        "\(url.path)|\(page?.text.count ?? 0)|" + terms.map(\.id).joined(separator: "·")
    }

    var body: some View {
        VStack(spacing: 0) {
            TransportView(player: transcript.player, compact: !transcript.hasVideo)
                .frame(height: transcript.hasVideo ? 280 : 44)
                .frame(maxWidth: .infinity)
                .background(transcript.hasVideo ? Color.black
                                                : Color(nsColor: .windowBackgroundColor))
                .accessibilityLabel("Recording")
                .accessibilityIdentifier("preview.media.player")
            Divider()
            transcriptList
        }
        .task(id: renderKey) {
            transcript.load(url: url, startingAt: start, onTime: onPlayhead)
            rendered = Dictionary(uniqueKeysWithValues: blocks.map {
                ($0.id, TextHighlighter.attributed($0.text, terms: terms,
                                                   monospaced: false).text)
            })
        }
        // Une demande venue d'ailleurs — la pastille d'une ligne de résultat,
        // un lien `fouine://…&t=` — pose la tête de lecture sans recharger.
        .onChange(of: start) { seconds in
            transcript.seek(to: seconds, thenPlay: false)
        }
        .onDisappear { transcript.pause() }
    }

    @ViewBuilder
    private var transcriptList: some View {
        if blocks.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("No text was written down for this passage.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .accessibilityElement(children: .combine)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(blocks) { block in
                        paragraph(block)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    /// Un paragraphe : son moment en pastille cliquable, puis ce qui se dit.
    private func paragraph(_ block: TranscriptMarkers.Block) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let seconds = block.seconds {
                Button {
                    transcript.seek(to: seconds, thenPlay: true)
                } label: {
                    Label(TranscriptMarkers.timestamp(seconds),
                          systemImage: "play.fill")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Play the recording from this point")
                .accessibilityLabel(String(localized: "Play from \(TranscriptMarkers.timestamp(seconds))"))
                .accessibilityIdentifier("preview.media.marker")
            }
            Text(rendered[block.id] ?? AttributedString(block.text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .lineSpacing(3)
                // Le surlignage est un fond coloré : il ne s'entend pas. Le
                // libellé rend le texte nu (même règle que `TextPreviewView`).
                .accessibilityLabel(block.text)
        }
    }
}
