// IndexingSheets.swift — feuilles d'indexation manuelle et d'OCR (SPEC §5.6).
// Propriété : A-App.
//
// « Indexer maintenant » : crawl delta + extraction en tâche de fond, barre de
// progression, annulable. À la fin, si des pages sont en file, proposer l'OCR
// avec l'avertissement batterie/secteur (§5.7 : l'OCR sature les 8 fils et fait
// tomber CPU_Speed_Limit à 46 % en 90 s — mesuré).

import SwiftUI

/// Hôte de l'UNIQUE feuille de la fenêtre (audit A10.6).
///
/// La vue principale ne porte qu'un `.sheet` ; c'est ce commutateur qui décide de
/// son contenu. Passer de l'indexation à la proposition d'OCR (et retour) est
/// donc un simple changement d'état observé, sans fermeture ni réouverture — la
/// séquence qui laissait la seconde feuille ne pas s'ouvrir.
struct SheetHost: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        switch app.sheet {
        case .some(.indexing): IndexingSheet()
        case .some(.ocrPrompt): OCRPromptSheet()
        case .some(.prepareMeaning): PrepareMeaningSheet()
        case .some(.uninstall): UninstallSheet()
        case .some(.unknownDocument(let path, let canOpen)):
            UnknownDocumentSheet(path: path, canOpen: canOpen)
        case .none: EmptyView()
        }
    }
}

struct IndexingSheet: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Le titre nomme CE QUI TOURNE : la même feuille sert la mise à
            // jour, la lecture des pages scannées et la préparation de la
            // recherche par le sens (UX-12), et « Mise à jour de l'index »
            // au-dessus d'une préparation de vingt heures serait faux.
            Text(verbatim: IndexingSheet.title(app.indexing))
                .font(.title3.weight(.semibold))

            if app.indexing.running {
                if app.indexing.total > 0 {
                    ProgressView(value: app.indexing.fraction) {
                        Text(app.indexing.phase)
                    } currentValueLabel: {
                        // `verbatim` : deux nombres et une barre oblique, rien
                        // à traduire — et rien à chercher dans le catalogue.
                        Text(verbatim: "\(Format.integer(app.indexing.done)) / "
                             + "\(Format.integer(app.indexing.total))")
                            .monospacedDigit()
                    }
                } else {
                    ProgressView { Text(app.indexing.phase) }
                        .progressViewStyle(.linear)
                }
                // Les compteurs sont ceux d'une passe d'extraction : « 0
                // extrait · 0 page · 0 page scannée à lire » sous une
                // préparation ne dit rien, et fait douter que quelque chose
                // avance.
                if app.indexing.activity != .preparingMeaning { countersRow }
            } else {
                if let summary = app.indexing.summary {
                    Label(summary, systemImage: app.indexing.cancelled
                          ? "xmark.circle" : "checkmark.circle")
                        .foregroundStyle(app.indexing.cancelled ? .orange : .green)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = app.indexing.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if app.indexing.queued > 0 {
                    Text("\(app.indexing.queued) scanned page(s) are waiting to be read.")
                        .font(.callout)
                }
            }

            HStack {
                Spacer()
                if app.indexing.running {
                    // Le bouton agit RÉELLEMENT sur l'OCR depuis l'audit A10.2 :
                    // la pompe consulte l'annulation entre deux pages.
                    Button("Cancel", role: .cancel) { app.cancelIndexing() }
                        .disabled(app.indexing.cancelled)
                        .help("The current page finishes cleanly and the queue stays intact: resuming will pick up here.")
                    // Une feuille SwiftUI est MODALE à la fenêtre : sans ce
                    // bouton, une passe d'OCR de vingt heures rendait
                    // l'application entière — recherche comprise —
                    // inutilisable, et le seul geste offert était « Annuler »
                    // (A2-07). La passe continue ; la progression bascule dans
                    // la barre latérale, qui porte « Arrêter ».
                    Button("Continue in the background") { app.sheet = nil }
                        .keyboardShortcut(.defaultAction)
                        .help("The pass goes on. Its progress moves to the sidebar, where you can stop it.")
                } else {
                    if app.indexing.queued > 0 || app.ocrQueueLength > 0 {
                        // Une seule affectation, pas deux drapeaux (audit A10.6).
                        Button("Read scanned pages…") { app.sheet = .ocrPrompt }
                    }
                    Button("Close") { app.sheet = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// Le titre, par activité. PUR : c'est ce que le test lit.
    static func title(_ state: IndexingState) -> String {
        guard state.running else { return String(localized: "Index update") }
        return IndexStatusText.name(state.activity)
    }

    private var countersRow: some View {
        HStack(spacing: 14) {
            counter("extracted", app.indexing.extracted)
            counter("pages", app.indexing.pages)
            counter("scanned pages to read", app.indexing.queued)
            if app.indexing.skipped > 0 { counter("skipped", app.indexing.skipped) }
            if app.indexing.failed > 0 { counter("failures", app.indexing.failed) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func counter(_ label: LocalizedStringKey,
                         _ value: Int) -> some View {
        HStack(spacing: 3) {
            Text(verbatim: Format.integer(value))
                .monospacedDigit().fontWeight(.medium)
            Text(label)
        }
    }
}

/// CE QUE LA LECTURE VA COÛTER, selon ce qu'il y a à lire (BU-12).
///
/// La même phrase servait pour cinq pages — douze secondes mesurées — et pour
/// quatre cent mille : « occupe le Mac un bon moment : branchez-le sur
/// secteur » devant cinq pages est un avertissement qui fait renoncer à un
/// geste sans risque. La décision est PURE et testée ; la vue n'en garde que
/// l'affichage.
enum OCRPromptText {
    /// Sous ce nombre de pages, la lecture se compte en minutes : la machine de
    /// référence (i5 4 cœurs) lit une page scannée en 2 à 3 secondes, soit une
    /// vingtaine de minutes au pire à ce seuil.
    static let shortQueue = 500

    static func effort(queued: Int) -> String {
        queued < shortQueue
            ? String(localized: "Reading them takes a few minutes.")
            : String(localized: "Reading them keeps the Mac busy for a while: plug it in. You can stop at any time and resume later.")
    }
}

/// Proposition d'OCR : avertissement batterie/secteur et budget (§5.6, §6.3).
struct OCRPromptSheet: View {
    @EnvironmentObject private var app: AppModel
    // 30 minutes par défaut, PAS « sans limite » (A2-07). La file compte des
    // dizaines de milliers de pages, soit une vingtaine d'heures : le bouton
    // radio pré-sélectionné décidait donc de bloquer la machine pour la nuit.
    // Qui veut plus le demande — et « Continuer en arrière-plan » rend la
    // fenêtre pendant ce temps.
    /// La valeur pré-sélectionnée, nommée pour que le test la lise plutôt que
    /// de la recopier.
    static let defaultBudgetMinutes = 30

    @State private var budget: Int = OCRPromptSheet.defaultBudgetMinutes

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Read the scanned pages", systemImage: "text.viewfinder")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("\(app.ocrQueueLength) scanned page(s) are waiting.")
                Text(verbatim: OCRPromptText.effort(queued: app.ocrQueueLength))
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            Picker("Stop after", selection: $budget) {
                Text("30 minutes").tag(30)
                Text("2 hours").tag(120)
                Text("when everything is read").tag(0)
            }
            .pickerStyle(.radioGroup)

            HStack {
                Spacer()
                Button("Later", role: .cancel) { app.sheet = nil }
                Button("Read") {
                    app.startOCR(budgetMinutes: budget == 0 ? nil : budget)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        // Le compte affiché ici décide de ce que l'utilisateur lance : il doit
        // être frais, pas hérité du démarrage (audit A10.5).
        .task { await app.refreshStats() }
    }
}

/// « Préparer la recherche par le sens » (UX-12) : ce que ça fait, où on en
/// est, ce que ça coûte, et combien de temps on y consacre.
///
/// Le pendant exact d'`OCRPromptSheet`, et pour la même raison : un travail de
/// plusieurs heures qui monopolise la machine ne se lance pas d'un bouton sans
/// que rien n'ait été dit. Les deux phrases qui comptent sont « rien ne quitte
/// ce Mac » — c'est la question que pose un traitement nommé « par le sens » —
/// et « vous pouvez arrêter et reprendre », qui est ce qui rend le geste sans
/// risque.
struct PrepareMeaningSheet: View {
    @EnvironmentObject private var app: AppModel

    /// 30 minutes par défaut, comme l'OCR (A2-07) : la campagne complète se
    /// compte en dizaines d'heures sur un corpus réel, et un bouton radio
    /// pré-sélectionné n'a pas à décider de bloquer la machine pour la nuit.
    static let defaultBudgetMinutes = 30

    @State private var budget: Int = PrepareMeaningSheet.defaultBudgetMinutes

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Prepare search by meaning", systemImage: "wand.and.stars")
                .font(.title3.weight(.semibold))

            Text("Fouine reads every page once more to make search by meaning possible. Nothing leaves this Mac.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let meaning = app.meaning {
                Text("\(Format.integer(meaning.ready)) of \(Format.integer(meaning.total)) pages are ready")
                    .font(.callout)
                    .monospacedDigit()
                if let hours = meaning.remainingHours {
                    Text(verbatim: IndexStatusText.workload(hours: hours))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Text("It keeps the Mac busy for a while: plug it in. You can stop at any time and resume later.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Stop after", selection: $budget) {
                Text("30 minutes").tag(30)
                Text("2 hours").tag(120)
                Text("when everything is ready").tag(0)
            }
            .pickerStyle(.radioGroup)

            HStack {
                Spacer()
                Button("Later", role: .cancel) { app.sheet = nil }
                Button("Prepare") {
                    app.startPrepareMeaning(budgetMinutes: budget == 0 ? nil : budget)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        // Les comptes affichés ici décident de ce que l'utilisateur lance : ils
        // doivent être frais, pas hérités du démarrage (audit A10.5).
        .task { await app.refreshMeaningReadiness() }
    }
}
