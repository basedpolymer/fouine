// IndexStatusCard.swift — la carte « Index » de la barre latérale (UX-03,
// épurée par IX2). Propriété : A-App. SPEC §5.6, amendements du 04/09/2026 et
// du 12/09/2026.
//
// Ce que cette carte REMPLACE : le bandeau de santé (quatre lignes dont deux
// parlaient d'indexation), la section « Indexation » (deux boutons et un
// interrupteur), le bloc de la passe manuelle, celui de l'agent avec sa
// fraîcheur en secondes, et le pied de barre. Cinq endroits pour un seul
// sujet, dont trois pouvaient se contredire — l'agent « au repos » pendant que
// le verrou disait « mise à jour en cours ».
//
// CE QU'ELLE A RENDU (IX2, demande du propriétaire du 12/09/2026). Elle avait
// regagné sept lignes : les comptes, les documents illisibles, les pages mal
// lues et leur geste, la place disque, la progression chiffrée, le nom du
// document en cours, et une confirmation de deux lignes sous l'interrupteur.
// Tout cela vit maintenant dans la fenêtre « Votre index » (`IndexDetailsView`),
// derrière le lien « Détails… ». Ne le faites pas revenir ici : ce que la carte
// peint est décidé par `IndexCardSummary`, testé état par état.
//
// La vue ne décide de rien, elle peint. C'est pour cela qu'elle n'a pas de
// test : ce qui se teste est en amont.

import SwiftUI
import FouineLicense

struct IndexStatusCard: View {
    @EnvironmentObject private var app: AppModel
    /// L'essai, la clé (lot L1C).
    @EnvironmentObject private var license: LicenseModel
    /// Ouvre la fenêtre « Votre index » (IX2).
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            card
            automaticToggle
            // Un PROBLÈME seulement (IX2) : l'interrupteur est revenu en
            // arrière tout seul, il doit dire pourquoi. Une confirmation
            // redirait ce que la carte dit déjà ; elle est dans la fenêtre.
            if let message = app.agentMessage, message.showsUnderCard {
                wrapping(Text(verbatim: message.text)
                    .font(.caption)
                    .foregroundStyle(.secondary))
                    .accessibilityIdentifier("sidebar.automatic.problem")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - La carte

    private var status: IndexStatus { app.indexStatus }

    private var card: some View {
        let summary = IndexCardSummary(
            status: status,
            disk: DiskSpaceNotice.decide(freeBytes: app.diskFreeBytes,
                                         forecast: app.diskBudget),
            // L'arrêt demandé mais pas encore abouti (ST1) : `indexing` le sait
            // avant que la passe n'ait rendu la main.
            stopping: app.indexing.running && app.indexing.cancelled)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: status.symbol)
                    .foregroundStyle(status.tint.color)
                    .imageScale(.medium)
                    .accessibilityHidden(true)      // la phrase le dit déjà
                wrapping(Text(verbatim: summary.headline)
                    .font(.callout.weight(.medium)))
            }

            if let detail = summary.detail {
                // Le tourniquet de l'arrêt (ST1) : la barre d'avancement, elle,
                // continue de dire ce qui se fait ; c'est ici qu'il faut dire
                // que le clic a été pris et qu'on attend.
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if summary.isStopping {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)  // la phrase le dit déjà
                    }
                    wrapping(Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary))
                }
            }

            if let bar = summary.bar {
                IndexProgressBar(bar: bar)
            }

            // L'ESSAI FINI PREND LA PLACE DU BOUTON DE MISE À JOUR (lot L1C).
            // Pas en plus de lui : proposer « Mettre à jour maintenant » à
            // quelqu'un dont l'index ne peut plus se mettre à jour serait une
            // promesse qui se casse au clic. L'interrupteur de mise à jour
            // automatique, lui, reste tel quel — l'agent se tait de lui-même,
            // et le rendre gris demanderait d'expliquer pourquoi.
            if !license.allowsIndexing {
                licenceBlock
            } else if let action = summary.action {
                Button(IndexStatusText.label(action)) {
                    app.performIndexAction(action)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                // Un bouton qui se réduit plutôt que de se couper : « Mettre à
                // jour maintenant » ne tenait pas dans 231 points (BU-04).
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.top, 1)
                // Un « Stop » déjà cliqué ne se reclique pas (ST1).
                .disabled(summary.isStopping)
                .accessibilityIdentifier("sidebar.index.action")
            }

            // Pendant l'essai : UNE ligne discrète, et rien d'autre. Pas de
            // fenêtre au lancement, pas de badge, pas de compte à rebours en
            // gros. Quelqu'un qui essaie un moteur de recherche veut chercher.
            if case .trial(let daysLeft) = license.state {
                trialLine(daysLeft: daysLeft)
            }

            // La place disque, seulement quand Fouine risque d'en manquer
            // (`.tight`). Aucun bouton, aucun arrêt (décision du 09/09/2026).
            if let disk = summary.diskSpace {
                wrapping(Text(verbatim: disk)
                    .font(.caption)
                    .foregroundStyle(.secondary))
                    .accessibilityIdentifier("sidebar.diskSpace")
            }

            detailsLink
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(cardBorder, lineWidth: 1))
        // `.contain` et non `.combine` : le bouton et le lien doivent rester
        // atteignables au clavier et à VoiceOver.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AccessibilityText.indexCard(summary))
        .accessibilityIdentifier("sidebar.index.card")
    }

    // MARK: - Ce que la licence ajoute à la carte (lot L1C)

    /// La phrase de fin d'essai (ou de clé désactivée) et les deux gestes.
    private var licenceBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            wrapping(Text(verbatim: LicenseStatusText.headline(license.state))
                .font(.caption)
                .foregroundStyle(.secondary))
            HStack(spacing: 6) {
                Button("Enter licence key…") { openLicenceSettings() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityIdentifier("sidebar.licence.enter")
                Button("Buy") { license.buy() }
                    .controlSize(.small)
                    .accessibilityIdentifier("sidebar.licence.buy")
            }
        }
        .padding(.top, 1)
    }

    /// « Trial: N days left · Buy » — un lien, pas un bouton : rien à faire
    /// aujourd'hui, tout marche.
    private func trialLine(daysLeft: Int) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: LicenseStatusText.cardTrialLine(daysLeft: daysLeft))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: "·")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Button("Buy") { license.buy() }
                .buttonStyle(.link)
                .font(.caption)
                // `.link` ne peint la teinte que sur un fond de fenêtre
                // ordinaire : sur celui de la carte, le libellé sortait en
                // blanc (BU-04, pièges connus).
                .foregroundStyle(.tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.licence.trial")
    }

    /// « Détails… » : la dernière ligne de la carte, et la porte vers tout ce
    /// qu'elle ne dit plus. Un lien, pas un bouton : un bouton bordé pèserait
    /// autant que le geste de l'état.
    private var detailsLink: some View {
        Button("Details…") {
            openWindow(id: IndexDetailsCommands.windowID)
        }
        .buttonStyle(.link)
        .font(.caption)
        // `.link` ne peint la teinte que sur un fond de fenêtre ordinaire : sur
        // celui de la carte, le libellé sortait en blanc (BU-04, pièges connus).
        .foregroundStyle(.tint)
        .help("Opens the window that shows what the index contains and what Fouine is doing.")
        .accessibilityLabel("Index details")
        .accessibilityHint("Opens the window that shows what the index contains and what Fouine is doing.")
        .accessibilityIdentifier("sidebar.index.details")
    }

    // MARK: - Sous la carte

    /// L'étiquette est POSÉE À CÔTÉ de l'interrupteur, pas dedans : le libellé
    /// d'un `Toggle` dans une `List` de barre latérale se tronque au lieu de
    /// passer à la ligne, quoi qu'on lui dise, et « Mettre l'index à jour
    /// autom… » n'est plus une phrase. Le libellé parlé est rendu à
    /// l'interrupteur par `accessibilityLabel`.
    private var automaticToggle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            wrapping(Text("Keep the index up to date automatically")
                .font(.callout))
            Toggle(isOn: Binding(
                get: { app.backgroundIndexing },
                set: { app.setBackgroundIndexing($0) }
            )) { EmptyView() }
            .labelsHidden()
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Keep the index up to date automatically")
        .disabled(!app.canToggleBackgroundIndexing)
        .help(app.backgroundIndexingHelp)
        // Un interrupteur grisé sans raison énoncée est le pire des cas : le
        // hint dit POURQUOI (aucun dossier, lecture non autorisée).
        .accessibilityHint(app.backgroundIndexingHelp)
        .accessibilityIdentifier("sidebar.automatic")
    }

    /// Une phrase qui passe à la ligne DANS une barre latérale.
    ///
    /// Une `List` de style `.sidebar` propose à ses lignes la hauteur d'une
    /// seule ligne de texte : `fixedSize(vertical:)` seul ne suffit pas quand
    /// le texte partage sa rangée avec autre chose (un pictogramme, un
    /// interrupteur), et la phrase se termine en « … ». Les trois modificateurs
    /// ensemble — largeur prise, pas de limite de lignes, hauteur idéale —
    /// sont ce qui la fait tenir sur deux ou trois lignes.
    ///
    /// Générique et non `(Text) -> …` : `Text.foregroundStyle(_:)` ne rend un
    /// `Text` qu'à partir de macOS 14, et Fouine s'installe depuis macOS 13.
    private func wrapping<V: View>(_ view: V) -> some View {
        view
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Couleurs

    private var cardBackground: Color {
        status.tint == .attention ? Color.orange.opacity(0.10)
                                  : Color.secondary.opacity(0.07)
    }

    private var cardBorder: Color {
        status.tint == .attention ? Color.orange.opacity(0.28)
                                  : Color.secondary.opacity(0.15)
    }
}

/// La couleur du pictogramme d'état, la même dans la carte et dans la fenêtre
/// « Votre index » : c'est elle qui porte à elle seule « tout va bien » / « à
/// toi de jouer ».
extension IndexStatus.Tint {
    var color: Color {
        switch self {
        case .working:   return .accentColor
        case .attention: return .orange
        case .upToDate:  return .green
        case .quiet:     return .secondary
        }
    }
}

/// La barre d'un travail en cours, dessinée de la même façon dans la carte et
/// dans la fenêtre « Votre index ». Déterminée ou non, cela se décide dans
/// `IndexCardSummary.bar(for:)`.
struct IndexProgressBar: View {
    let bar: IndexCardSummary.Bar

    var body: some View {
        switch bar {
        case .determinate(let fraction):
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
        case .indeterminate:
            ProgressView()
                .progressViewStyle(.linear)
        }
    }
}
