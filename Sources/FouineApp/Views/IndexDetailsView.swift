// IndexDetailsView.swift — la fenêtre « Votre index » (IX2). Propriété : A-App.
// SPEC §5.6, amendement du 12/09/2026.
//
// POURQUOI UNE FENÊTRE. Demande du propriétaire du 12/09/2026 : la carte
// « Index » ne garde que l'essentiel, et « le reste dans un menu dédié à
// l'indexation, en détaillant ». Pas l'onglet Réglages ▸ Indexation — ce sont
// des réglages, pas un état ; pas un menu système — il ne porte pas
// d'explication. Une fenêtre unique, sur le patron de « Tous vos documents » et
// de « Documents que Fouine n'a pas pu lire », ouverte par « Détails… » sous la
// carte ou par Fenêtre ▸ Votre index.
//
// CE QU'ELLE DIT, DANS CET ORDRE. Ce que fait Fouine — l'état complet, nom du
// document et « 312 / 1 200 pages » compris, et les deux gestes de l'état ; la
// mise à jour automatique — le même interrupteur que sous la carte, et ce qu'il
// a répondu, confirmations comprises ; ce que l'index contient — comptes,
// documents illisibles, nouveautés depuis la dernière visite, place disque ;
// les pages scannées sans texte lisible, s'il y en a, SANS geste (une relecture
// en masse rend le même résultat, `ScannedPagesWithoutText`).
//
// La vue ne décide de rien : `IndexStatus`, `DocumentCountAffordance`,
// `DiskSpaceNotice`, `ScannedPagesWithoutText` et `IndexAction.needsMainWindow`
// sont purs et testés.
//
// MISE EN PAGE. Un `Form` groupé, et des phrases qui passent à la ligne par un
// CADRE (`frame(maxWidth: .infinity, alignment: .leading)`), jamais par
// `fixedSize` seul : hors d'une `List` de barre latérale, un texte figé en
// hauteur fait mesurer la vue à une largeur nulle et déborder la fenêtre
// (pièges connus, « la colonne des résultats qui déborde »). Les liens portent
// leur couleur explicitement : une ligne de `Form` groupé a son propre fond,
// comme la carte, et `.link` y sortait en blanc (BU-04).

import SwiftUI
import AppKit

/// Menu Fenêtre ▸ « Votre index ».
///
/// Le patron exact d'`AllDocumentsCommands` : `openWindow` ne se prend que dans
/// l'environnement des COMMANDES pour faire naître une scène `Window` jamais
/// construite. SANS raccourci : la fenêtre se consulte, elle ne sert pas à
/// chaque recherche.
struct IndexDetailsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    static let windowID = "indexDetails"

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Your index") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: Self.windowID)
            }
            .help("Shows what the index contains and what Fouine is doing.")
        }
    }
}

struct IndexDetailsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("What Fouine is doing") { activity }
            Section("Automatic updates") { automatic }
            Section("What the index holds") { holdings }
            if let scans = app.scannedPagesWithoutText {
                Section("Scanned pages without readable text") {
                    scannedPages(scans)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 360)
        // À l'ouverture, on relit TOUT ce que la fenêtre montre : elle a pu
        // rester fermée des heures, et la sonde de statut ne relit ni les
        // comptes ni la santé à chaque battement. Ensuite les sondes suivent
        // `NSApp.isActive` : la fenêtre au premier plan reste vivante.
        //
        // `start()` d'abord : une fenêtre restaurée au lancement peut paraître
        // avant que l'index soit ouvert, et `start()` attend l'ouverture en
        // cours au lieu d'en rejouer une (BU-02).
        .task {
            await app.start()
            guard app.isReady else { return }
            await app.refreshStats()
            countsRefresh.noteRead(at: Date())
            await app.refreshAgentActivity()
            await app.refreshHealth()
        }
        // PENDANT UNE MISE À JOUR, LES COMPTES SUIVENT (lot MN2). Au rythme de
        // la sonde du modèle, qui republie l'état de l'index, et selon
        // `IndexCountsRefresh` : une relecture toutes les dix secondes au plus,
        // et une à la fin. Fenêtre fermée, la vue n'existe plus : rien ne relit.
        .onChange(of: app.indexStatus) { status in
            guard countsRefresh.shouldRead(working: status.isWorking, now: Date())
            else { return }
            Task { await app.refreshStats() }
        }
    }

    @State private var countsRefresh = IndexCountsRefresh()

    private var status: IndexStatus { app.indexStatus }

    // MARK: - Ce que fait Fouine

    @ViewBuilder
    private var activity: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.tint.color)
                .accessibilityHidden(true)      // la phrase le dit déjà
            sentence(Text(verbatim: IndexStatusText.headline(status))
                .font(.body.weight(.medium)))
        }
        .accessibilityIdentifier("indexDetails.status")

        // La ligne COMPLÈTE, nom du document compris : la carte l'a laissée
        // ici, c'est ici qu'on vient la lire.
        if let detail = IndexStatusText.detail(status) {
            sentence(Text(verbatim: detail)
                .foregroundStyle(.secondary))
        }

        if let bar = IndexCardSummary.bar(for: status) {
            VStack(alignment: .leading, spacing: 4) {
                IndexProgressBar(bar: bar)
                if case .working(_, let progress?, _, _) = status, progress.isDeterminate {
                    Text(verbatim: IndexStatusText.progressLine(progress))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        // « 1 203 / 4 000 » groupé à l'espace fine se prononce
                        // « un, deux cent trois » : VoiceOver lit des nombres nus.
                        .accessibilityLabel(Text(verbatim: AccessibilityText.progressLine(progress)))
                }
            }
        }

        if status.primaryAction != nil || status.secondaryAction != nil {
            actions
        }
    }

    /// Le geste de l'état en bouton, le second en lien — « Lire les pages
    /// scannées… » compris, que la carte ne porte plus. L'un SOUS l'autre, comme
    /// dans la carte : côte à côte, deux libellés français ne tiennent pas dans
    /// une fenêtre rétrécie (BU-04).
    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let action = status.primaryAction {
                Button(IndexStatusText.label(action)) { perform(action) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("indexDetails.action")
            }
            if let action = status.secondaryAction {
                Button(IndexStatusText.label(action)) { perform(action) }
                    .buttonStyle(.link)
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("indexDetails.secondary")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Un geste qui s'accroche à la fenêtre principale la ramène d'abord :
    /// sans elle, « Lire les pages scannées… » n'ouvrirait aucune feuille.
    private func perform(_ action: IndexAction) {
        if action.needsMainWindow { MainWindow.show(openWindow) }
        app.performIndexAction(action)
    }

    // MARK: - Mise à jour automatique

    @ViewBuilder
    private var automatic: some View {
        // Le MÊME interrupteur que sous la carte : même libellé, même liaison,
        // mêmes règles. Deux interrupteurs qui ne se comporteraient pas pareil
        // passeraient pour deux réglages.
        Toggle(isOn: Binding(
            get: { app.backgroundIndexing },
            set: { app.setBackgroundIndexing($0) }
        )) {
            Text("Keep the index up to date automatically")
        }
        .toggleStyle(.switch)
        .disabled(!app.canToggleBackgroundIndexing)
        .help(app.backgroundIndexingHelp)
        .accessibilityHint(app.backgroundIndexingHelp)
        .accessibilityIdentifier("indexDetails.automatic")

        sentence(Text(verbatim: app.backgroundIndexingHelp)
            .font(.callout)
            .foregroundStyle(.secondary))

        // Ce qu'a répondu le dernier geste, CONFIRMATIONS COMPRISES : la carte
        // n'en garde que les problèmes, c'est ici le lieu du détail.
        if let message = app.agentMessage {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if message.kind == .problem {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                sentence(Text(verbatim: message.text)
                    .font(.callout))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("indexDetails.automatic.message")
        }

        sentence(Text("When Fouine may work on its own is set in Settings ▸ Indexing ▸ When to update automatically.")
            .font(.callout)
            .foregroundStyle(.secondary))
    }

    // MARK: - Ce que contient l'index

    @ViewBuilder
    private var holdings: some View {
        countsRow

        if unreadableCount > 0 {
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    openWindow(id: "unreadable")
                } label: {
                    // « 23 non lus » se lisait comme vingt-trois messages en
                    // attente (AP-18) : on nomme la chose.
                    Text("\(unreadableCount) unreadable documents")
                }
                .buttonStyle(.link)
                .foregroundStyle(.tint)
                .help("Shows the documents Fouine found in your folders but could not read.")
                .accessibilityIdentifier("indexDetails.unreadable")
                // Ce que c'est, dans les mots de l'en-tête de la fenêtre qu'il
                // ouvre : deux phrases pour le même échec se liraient comme
                // deux échecs.
                sentence(Text("These files are in your folders, but Fouine could not read them. Your files are untouched.")
                    .font(.callout)
                    .foregroundStyle(.secondary))
            }
        }

        // « Depuis votre dernière visite » (UX-06), sans croix : on ouvre
        // cette fenêtre pour lire, la nouvelle n'y gêne rien.
        if let added = app.sinceLastVisitPages {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                sentence(Text("Since your last visit: \(added) new page(s)"))
            }
            .accessibilityIdentifier("indexDetails.sinceLastVisit")
        }

        // La place disque dès qu'elle se fait rare (MO-03) : ici les deux
        // seuils, la carte ne garde que le second.
        if let disk = DiskSpaceNotice.decide(freeBytes: app.diskFreeBytes,
                                             forecast: app.diskBudget).text {
            sentence(Text(verbatim: disk))
                .accessibilityIdentifier("indexDetails.diskSpace")
        }
    }

    /// La ligne des comptes, qui est aussi le geste « Tous vos documents »
    /// (PR-06), décidée par `DocumentCountAffordance` avec son rôle
    /// d'accessibilité : un bouton dit « bouton », un texte reste un texte
    /// statique (BU-15) — et dans les deux cas les comptes sont ANNONCÉS.
    @ViewBuilder
    private var countsRow: some View {
        let affordance = DocumentCountAffordance.decide(
            documents: app.stats.isEmpty ? nil : (app.stats["docs_total"] ?? 0),
            pages: app.stats.isEmpty ? nil : (app.stats["pages_indexed"] ?? 0))
        if affordance.isGesture {
            Button {
                openWindow(id: AllDocumentsCommands.windowID)
            } label: {
                Text(verbatim: affordance.label)
            }
            .buttonStyle(.link)
            .foregroundStyle(.tint)
            .help(affordance.help ?? "")
            .accessibilityLabel(affordance.accessibilityLabel)
            .accessibilityValue(countsSpoken)
            .accessibilityHint("Opens the list of every document Fouine has indexed.")
            .accessibilityIdentifier("indexDetails.stats")
        } else {
            Text(verbatim: affordance.label)
                // Deux nombres groupés à l'espace fine insécable : lus tels
                // quels, ils deviennent une suite de nombres sans rapport.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(countsSpoken)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityIdentifier("indexDetails.stats")
        }
    }

    /// Les documents que Fouine n'a pas pu lire (UX-16) : les deux états
    /// d'échec comptent pour la même chose aux yeux du lecteur — son document
    /// n'est pas dans l'index. Rien quand il n'y en a pas.
    private var unreadableCount: Int {
        (app.stats["docs_failed"] ?? 0) + (app.stats["docs_skipped"] ?? 0)
    }

    private var countsSpoken: String {
        guard !app.stats.isEmpty else {
            return String(localized: "Statistics unavailable")
        }
        return String(localized: "\(AccessibilityText.documents(app.stats["docs_total"] ?? 0)), \(AccessibilityText.indexedPages(app.stats["pages_indexed"] ?? 0))")
    }

    // MARK: - Pages scannées sans texte lisible

    @ViewBuilder
    private func scannedPages(_ scans: ScannedPagesWithoutText) -> some View {
        ForEach(scans.lines, id: \.title) { line in
            VStack(alignment: .leading, spacing: 2) {
                sentence(Text(verbatim: line.title))
                sentence(Text(verbatim: line.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary))
            }
            // Une annonce par population, le compte en nombres nus.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: AccessibilityText.spokenCount(line.title)
                                     + ". " + line.explanation))
            .accessibilityAddTraits(.isStaticText)
        }
        // AUCUN bouton : relire en masse donnerait le même texte. La phrase dit
        // le seul geste qui change quelque chose.
        sentence(Text(verbatim: ScannedPagesWithoutText.closing)
            .font(.callout)
            .foregroundStyle(.secondary))
            .accessibilityIdentifier("indexDetails.scans.closing")
    }

    // MARK: - Mise en page

    /// Une phrase qui passe à la ligne dans une ligne de `Form` : un cadre, pas
    /// `fixedSize` (pièges connus).
    private func sentence<V: View>(_ view: V) -> some View {
        view
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
