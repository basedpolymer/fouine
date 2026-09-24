// ResultsView.swift — panneau central : champ de recherche et résultats groupés.
// Propriété : A-App. SPEC §5.6.
//
// Contraintes tenues ici :
//   · champ de recherche principal en tête de fenêtre, historique et
//     autocomplétion (< 20 ms : complétion en mémoire, cf. StoreService) ;
//   · résultats groupés par document, dépliables vers les pages ;
//   · PAS de `List` : `LazyVStack` dans un `ScrollView` — le jeu peut dépasser
//     2 000 lignes via « charger plus » ;
//   · les « … » du snippet FTS5 restent, les marqueurs « » deviennent une mise
//     en évidence typographique colorée par terme ;
//   · elapsed_ms et compte total affichés, comme la CLI.

import SwiftUI
import AppKit
import FouineCore

extension Hit {
    /// Identifiant unique d'une ligne de résultat dans TOUTE la liste — voir
    /// l'usage dans `resultsScroll`.
    var rowIdentity: Int64 { Schema.ftsRowID(docID: docID, page: page) }
}

struct ResultsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var search: SearchModel
    @EnvironmentObject private var preview: PreviewModel
    /// Ouvre une fenêtre d'aperçu détachée (UX-17).
    @Environment(\.openWindow) private var openWindow

    @FocusState private var searchFocused: Bool
    /// La liste de résultats a-t-elle le focus clavier ? C'est elle qui reçoit
    /// alors les flèches ↑↓ et ⏎ (audit U3, volet clavier) ; sans ce focus, les
    /// flèches ne feraient que défiler la vue.
    @FocusState private var resultsFocused: Bool
    /// Groupes repliés (par défaut : tout est déplié).
    @State private var collapsed: Set<Int64> = []
    /// Le pont vers le panneau de Coup d'œil (PR-16).
    @StateObject private var quickLook = QuickLookController()
    /// Largeur de la colonne des résultats, mesurée (AP-12).
    @State private var columnWidth: CGFloat = 0
    /// « Enregistrer cette recherche… » est-il en train de demander un nom
    /// (PR-17) ? Une alerte d'une ligne, comme le renommage d'un dossier de la
    /// barre latérale — c'est le même geste, et il se lit déjà.
    @State private var namingSearch = false
    @State private var draftSavedName = ""

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider()
            statusBar
            if search.hasFilters { filterChips }
            Divider()
            resultsScroll
        }
        .onReceive(NotificationCenter.default.publisher(for: .fouineFocusSearch)) { _ in
            searchFocused = true
        }
        .alert("Save this search", isPresented: $namingSearch) {
            TextField("Name", text: $draftSavedName)
            Button("Save") { search.saveCurrentSearch(name: draftSavedName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will appear in the sidebar, under “Saved searches”. Only what you typed is kept, not the filters you clicked.")
        }
        .background(detachShortcut)
        // Zéro point, et posée là pour une seule raison : être le répondeur
        // que `QLPreviewPanel` cherche dans la chaîne (PR-16).
        .background(QuickLookAnchor(controller: quickLook)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true))
    }

    /// Espace : le Coup d'œil du document de la ligne désignée.
    private func quickLookSelection() {
        guard let key = search.selection,
              let url = fileURL(docID: key.docID) else { return }
        quickLook.show(url)
    }

    /// Le fichier d'un document, pour les gestes QUI MONTRENT LE FICHIER — le
    /// Coup d'œil, le glisser-déposer, le Finder, « Ouvrir ». `nil` pour une
    /// copie de Fouine (lot AN2) : ce fichier-là est un détail de fabrication,
    /// et chacun de ces gestes montrait la cuisine au lieu de la carte.
    private func fileURL(docID: Int64) -> URL? {
        guard let row = search.docRow(docID),
              DocumentDisplay.source(row.record.relPath) == nil else { return nil }
        return search.absoluteURL(docID: docID)
    }

    // MARK: - Aperçu détaché (UX-17)

    /// ⌘⏎ : le pendant clavier du double-clic.
    ///
    /// Un bouton invisible portant le raccourci, et non `onKeyPress` : celui-ci
    /// n'existe qu'à partir de macOS 14 alors que le paquet cible macOS 13
    /// (`Package.swift`). Le risque que redoutait `OpenSelectionOnReturn` — le
    /// raccourci volerait ⏎ au champ de recherche — n'existe pas ici : ⌘⏎ n'est
    /// la validation d'aucun champ de texte de la fenêtre.
    private var detachShortcut: some View {
        Button("Open the preview in its own window") {
            if let key = search.selection { openDetachedPreview(key) }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(search.selection == nil)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// La sélection SUIT le double-clic : la fenêtre détachée montre la page
    /// qu'on vient de désigner, et le panneau de droite aussi — sans quoi les
    /// deux aperçus se contrediraient dès le premier geste.
    private func openDetachedPreview(_ key: HitKey) {
        search.selection = key
        // UNE FENÊTRE PAR DOCUMENT, TROIS AU PLUS (BU-19) : deux pages du même
        // ouvrage ne font plus deux `PDFView` du même fichier de 400 pages.
        PreviewWindowsModel.shared.open(key, using: openWindow)
    }

    /// L'infobulle qui ANNONCE le double-clic. Sans elle, la fenêtre détachée
    /// n'existe pour personne : aucun autre élément de l'interface ne la
    /// mentionne, et un geste que rien ne signale n'est pas une fonction.
    private var detachHelp: String {
        String(localized: "Double-click to open this page in its own window (⌘↩)")
    }

    // MARK: - Champ de recherche (tête de fenêtre)

    private var searchHeader: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                // La loupe était décorative ; elle porte maintenant ⌘F, qui
                // n'existait nulle part — seul ⌥⌘F (menu Édition, et raccourci
                // global) ramenait au champ. ⌘F est ce que la main cherche.
                // Le bouton n'ajoute rien à l'écran : même pictogramme, même
                // place, style effacé.
                Button {
                    searchFocused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: .command)
                .accessibilityLabel("Go to the search field")
                .accessibilityIdentifier("search.focus")
                // L'INVITE DIT CE QU'ON CHERCHE, PAS COMMENT L'ÉCRIRE
                // (AP-16, BU-34). Elle annonçait la grammaire des requêtes —
                // « Rechercher ("phrase exacte", préfixe*, -exclu, pres:…) » —
                // à la première personne qui ouvre Fouine. Le panneau de la
                // barre des menus disait déjà la bonne phrase : c'est la
                // même, au mot près, et la syntaxe passe en infobulle, où
                // elle double l'aide parlée qui la portait déjà.
                TextField(MenuBarText.searchPrompt, text: $search.text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit { search.submit() }
                    .onChange(of: search.text) { _ in search.textChanged() }
                    .help("Quotes for an exact phrase, asterisk for a prefix, hyphen before a term to exclude it. Return runs the search.")
                    .accessibilityLabel("Search")
                    .accessibilityHint("Quotes for an exact phrase, asterisk for a prefix, hyphen before a term to exclude it. Return runs the search.")
                    .accessibilityIdentifier("search.field")
                if !search.text.isEmpty {
                    Button {
                        search.text = ""
                        // Effacer, c'est aussi effacer ce que Fouine rouvrira
                        // (R-11) : vider le champ avant de quitter est le geste
                        // de qui veut repartir de zéro.
                        search.forgetLastSession()
                        search.execute(remember: false)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the query")
                    .accessibilityIdentifier("search.clear")
                }
                historyMenu
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, suggestionsRow == nil ? 8 : 2)

            // CE QUI CLOCHE DANS CE QUI EST TAPÉ (BU-33), sous le champ et
            // pendant la frappe : un guillemet ouvert, `pres:` sans ses deux
            // mots, une requête qui ne fait qu'exclure. Trois cas exactement,
            // et rien pour une requête simplement infructueuse — la décision
            // est dans `QueryDiagnosis`, qui est pur et testé.
            if let diagnosis = QueryDiagnosis.describe(text: search.text) {
                Text(verbatim: diagnosis)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .accessibilityIdentifier("search.diagnosis")
            }

            if let row = suggestionsRow { row.padding(.bottom, 6) }
        }
    }

    private var historyMenu: some View {
        Menu {
            // EN TÊTE : c'est le seul geste du menu qui regarde vers l'avenir,
            // et celui qu'on cherche juste après une recherche réussie (PR-17).
            Button("Save this search…") {
                draftSavedName = search.suggestedSavedName
                namingSearch = true
            }
            .disabled(search.suggestedSavedName
                          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Divider()
            if search.history.isEmpty {
                Text("No recent query")
            } else {
                ForEach(search.history, id: \.self) { entry in
                    // `Text(verbatim:)` et non `Button("…")` : une requête
                    // enregistrée est une donnée, pas une clé de catalogue.
                    Button {
                        search.text = entry
                        search.submit()
                    } label: {
                        Text(verbatim: entry)
                    }
                    .accessibilityLabel(AccessibilityText.historyLabel(entry))
                    .accessibilityHint("Runs this query again.")
                    .accessibilityIdentifier("history.entry.\(entry)")
                }
                Divider()
                Button("Clear history") { search.clearHistory() }
            }
        } label: {
            // UN `Label`, PAS UNE `Image` NUE (BU-13). Un `Menu` dont le
            // contenu est une image rend un `AXPopUpButton` dont le TITRE est
            // le nom du symbole SF : VoiceOver lisait « clock point arrow
            // point circlepath ». Le titre du `Label` devient ce titre-là ;
            // `.iconOnly` garde le pictogramme seul à l'écran.
            Label("Query history", systemImage: "clock.arrow.circlepath")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Query history")
        .accessibilityLabel("Query history")
        .accessibilityHint("The last \(search.history.count) queries run, each one click away.")
        .accessibilityIdentifier("search.history")
    }

    /// Autocomplétion depuis le vocabulaire de l'index : suggestions du dernier
    /// mot saisi, complétées en mémoire (cf. StoreService.suggestions).
    private var suggestionsRow: AnyView? {
        guard searchFocused, !search.suggestions.isEmpty else { return nil }
        return AnyView(
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(search.suggestions, id: \.self) { term in
                        Button { search.applySuggestion(term) } label: {
                            Text(verbatim: term)
                        }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .font(.callout)
                            .accessibilityLabel(String(localized: "Suggestion \(term)"))
                            .accessibilityHint("Replaces the last word of the query and runs the search again.")
                            .accessibilityIdentifier("search.suggestion.\(term)")
                    }
                }
                .padding(.horizontal, 12)
            }
            // `.contain` et non un simple libellé : posé seul sur un conteneur,
            // un `accessibilityLabel` DESCEND sur chaque enfant et écrase le
            // leur. Ici le groupe est nommé, les boutons restent atteignables.
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Suggestions from the index vocabulary")
        )
    }

    // MARK: - Ligne d'état

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // LE COMPTE D'ABORD (AP-12). Il partageait sa rangée avec le temps
            // écoulé, le tri, l'export et la portée : mesuré, cela faisait
            // deux lignes à 1 200 pt de fenêtre, quatre à 1 309 pt avec
            // « document( / s) » coupé au milieu, et CINQ à 900 pt — la
            // largeur minimale documentée. La colonne respectait pourtant son
            // minimum de 350 pt : c'est le contenu qui n'y tenait pas. Le
            // compte garde donc la priorité de mise en page, et les trois
            // commandes passent sur une seconde rangée dès que la première ne
            // suffit plus.
            //
            // PAS DE `ViewThatFits` ICI. Il faisait exactement ce qu'on lui
            // demande, mais chacune de ses mesures rouvrait une boucle dans le
            // graphe de SwiftUI : 27 « AttributeGraph: cycle detected » au
            // premier redimensionnement de la fenêtre et 186 après une
            // recherche, là où la même manœuvre n'en produisait AUCUN sans lui
            // (mesuré le 10/09/2026, `scenario.sh`, deux binaires de débogage
            // successifs). La largeur de la colonne, elle, ne dépend pas de ce
            // qu'on met dedans : elle vient du séparateur de la fenêtre. On la
            // mesure donc une fois, et on choisit.
            if columnWidth > 0, columnWidth < Self.commandsOnTheirOwnRowBelow {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) { countsRow; Spacer(minLength: 0) }
                    HStack(spacing: 8) { commandsRow; Spacer(minLength: 0) }
                }
            } else {
                HStack(spacing: 8) {
                    countsRow.layoutPriority(1)
                    Spacer(minLength: 8)
                    commandsRow
                }
            }
            if search.totalsApproximate, !search.isSearching,
               !search.executedText.isEmpty {
                veryCommonNotice
            }
            // LE REPLI EN FLOU, avant tout le reste : ce qui est affiché n'est
            // pas ce qui a été tapé, et c'est le contexte dans lequel se lisent
            // les comptes juste au-dessus (C2-08). Il vaut aussi pour l'hybride
            // depuis le lot RK1 : le canal lexical de la fusion repliait déjà.
            if search.fuzzyFallback, !search.isSearching {
                fuzzyFallbackNotice
            }
            // Peu de pages portent TOUS les mots : la liste en montre aussi qui
            // n'en portent qu'une partie (RK2, RK-04). Même place et même
            // raison que la ligne du repli : ce qui est affiché ne répond pas
            // exactement à ce qui a été tapé.
            if search.quorum, !search.isSearching {
                quorumNotice
            }
            // Le sens n'a pas été consulté (RK-01) : l'interrupteur est armé,
            // mais la requête demande une phrase exacte.
            if search.semanticDisarmed, !search.isSearching {
                semanticDisarmedNotice
            }
            if search.noLexicalMatch {
                noLexicalNotice
            }
            // PR-08 : pendant que les tranches suivantes arrivent, puis — si
            // le plafond a coupé — ce sur quoi le tri a porté. Quand tout est
            // chargé, il n'y a plus rien à dire : le classement est complet.
            if search.isLoadingForSort {
                sortLoadingNotice
            } else if search.sortCapReached {
                sortCapNotice
            } else if search.sortIsPartial {
                partialSortNotice
            }
            if let notice = search.semanticNotice {
                // Repli sur le lexical : discret, jamais bloquant — les
                // résultats affichés dessous sont bons, seul le canal
                // sémantique manque.
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // La largeur de la COLONNE, mesurée une fois : elle vient du
        // séparateur de la fenêtre, jamais du contenu de cette rangée — la
        // mesure ne peut donc pas se remettre en cause elle-même.
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ColumnWidthKey.self,
                                   value: proxy.size.width)
        })
        .onPreferenceChange(ColumnWidthKey.self) { columnWidth = $0 }
    }

    /// Sous cette largeur de colonne, tri, export et portée passent sur leur
    /// propre rangée : le compte français (« 29 037 pages dans 776
    /// documents ») en occupe déjà 200 à 250 points.
    private static let commandsOnTheirOwnRowBelow: CGFloat = 450

    /// Ce que la recherche a trouvé, et en combien de temps.
    @ViewBuilder
    private var countsRow: some View {
        HStack(spacing: 8) {
            if search.isSearching {
                ProgressView().controlSize(.small)
                // Le premier coup charge le modèle et l'index : on le DIT,
                // sinon l'attente passe pour une recherche qui traîne (§12).
                // AUCUN CHIFFRE dans la phrase (audit A2-04) : elle
                // annonçait « ~3,5 s » là où l'audit A1 a mesuré 11,7 s de
                // bout en bout sur une machine chargée, dont 8,8 s pour le
                // seul modèle — et le lot K1 les a depuis ramenés à ~1,1 s.
                // Trois valeurs en deux jours : c'est bien la preuve qu'un
                // chiffre n'a rien à faire là, et il dépend de toute façon
                // de la machine, de sa charge et du cache disque.
                Text(search.semanticPreparing
                     ? "preparing the meaning search: the first one takes a few seconds…"
                     : "searching…")
                    .foregroundStyle(.secondary)
            } else if !search.executedText.isEmpty {
                if search.isHybrid {
                    hybridCounts
                } else {
                    // Deux phrases pour deux natures de nombre. Le compte
                    // EXACT passe l'ENTIER : la règle de pluriel du
                    // catalogue lit `%lld`, et Foundation groupe déjà les
                    // milliers selon la locale — `Format.integer` ici
                    // rendait une chaîne face à un `%lld`, et l'app
                    // affichait l'adresse mémoire de cette chaîne. Le total
                    // APPROCHÉ (« 50 k+ ») ne peut être qu'une chaîne : sa
                    // clé n'a donc pas de variation de pluriel, et n'en a
                    // pas besoin — une approximation est toujours plurielle.
                    let counts = search.totalsApproximate
                        ? String(localized: "\(Format.approximate(search.totalPages)) pages in \(Format.approximate(search.totalDocs)) documents")
                        : String(localized: "\(search.totalPages) page(s) in \(search.totalDocs) document(s)")
                    // Un `Text` NOMMÉ et de rôle explicite : la rangée
                    // sortait en `AXUnknown` (BU-15), c'est-à-dire sans
                    // rôle du tout pour VoiceOver.
                    Text(counts)
                        .lineLimit(1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityLabel(AccessibilityText.resultCounts(
                            pages: search.totalPages,
                            docs: search.totalDocs, hybrid: false))
                        .accessibilityIdentifier("results.counts")
                }
                Text(verbatim: "· \(Format.milliseconds(search.elapsedMS))")
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel(String(localized: "in \(Format.milliseconds(search.elapsedMS))"))
                exclusionBadge
                // Le sens cherche encore (ST1) : les comptes lexicaux sont là,
                // la liste va être reclassée. On le DIT, plutôt que de laisser
                // croire que la recherche est finie — et le tourniquet montre
                // que quelque chose travaille encore.
                if search.semanticPending {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(search.semanticPreparing
                         ? "preparing the meaning search: the first one takes a few seconds…"
                         : "searching by meaning…")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("results.semanticPending")
                }
            } else {
                // Cette phrase passe à la ligne par un CADRE, jamais par
                // `fixedSize(horizontal: false, vertical: true)`. Dans cette
                // colonne (hors `List`, hors `ScrollView`), un texte figé en
                // hauteur fait mesurer la colonne entière à une largeur nulle :
                // le `NavigationSplitView` prenait alors 1 053 pt de haut dans
                // une fenêtre de 676 et se centrait en débordant — carte
                // « Index » sous les feux, champ de recherche derrière le titre
                // (mesuré à l'arbre d'accessibilité le 11/09/2026, build 604,
                // à requête vide ; 856 pt avec la ligne du repli en flou).
                // Ici la place ne manque jamais en hauteur : le cadre suffit.
                // Pièges connus, « la colonne des résultats qui déborde ».
                Text("Type a query: the index stays searchable even when a folder is unavailable.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Tri, export, portée — les trois commandes du jeu affiché.
    @ViewBuilder
    private var commandsRow: some View {
        if !search.hits.isEmpty {
            sortMenu
            Button {
                ResultExporter.present(search)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .controlSize(.small)
            .help("Export the loaded results (CSV, JSON or Markdown)…")
            .accessibilityLabel("Export results")
            .accessibilityHint("Saves the loaded results as CSV, JSON or Markdown.")
            .accessibilityIdentifier("results.export")
            // « Search inside the results » se coupait en « Search inside the
            // r… », et « Searc… » à 900 pt (AP-11) — le français, plus long,
            // se coupait plus tôt encore. Deux mots sur le bouton, la phrase
            // entière dans l'infobulle et dans l'aide parlée.
            Button("Within results") {
                search.searchInsideResults()
                searchFocused = true
            }
            .controlSize(.small)
            .lineLimit(1)
            .help("Limits the next searches to the documents now in the list")
            .accessibilityLabel("Search inside the results")
            .accessibilityHint("Limits the next searches to the documents now in the list.")
            .accessibilityIdentifier("results.scope")
        }
    }

    /// Le total est BORNÉ : le mot est sur des dizaines de milliers de pages,
    /// et c'est ce qui vient de coûter plusieurs secondes (audit A1m-08). On
    /// dit le geste — un second mot —, jamais le seuil ni le classement.
    ///
    /// Cette ligne et les suivantes passent à la ligne par un cadre, PAS par
    /// `fixedSize` : voir le texte d'invite de `countsRow` (la colonne
    /// débordait de la fenêtre, 11/09/2026).
    private var veryCommonNotice: some View {
        Text("This word is very common. Add a second word to narrow the search.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("results.veryCommon")
    }

    /// AUCUNE page ne porte les mots tapés, et il y a pourtant des résultats :
    /// ils viennent du sens seul. Le dire est la seule chose honnête à faire —
    /// ce n'est PAS un filtre, et c'est une mesure : un seuil de cosinus
    /// éteindrait d'abord les requêtes que le canal sert le mieux (R-04,
    /// docs/search.md § 3).
    private var noLexicalNotice: some View {
        // DEUX PHRASES (lot MC1) : « aucune page ne les porte TOUS » n'est pas
        // « aucun de vos mots n'existe ». Dire la seconde quand la première
        // est vraie fait conclure à un fonds muet, et arrêter de chercher.
        Text(search.wordsPresentInIndex.isEmpty
             ? String(localized: "None of your words appears in your documents: these results are suggested by meaning only.")
             : String(localized: "Your words are in your documents, but never together on the same page: these results are suggested by meaning only."))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("results.noLexicalMatch")
    }

    /// La recherche exacte n'a rien rendu : Fouine a rejoué la requête en
    /// tolérant les fautes, sur tous les documents (C2-08). Aucun mot de
    /// technicien — ni « flou », ni « portée », ni « index ».
    private var fuzzyFallbackNotice: some View {
        Text("No exact match: here are the closest spellings, in every document.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("results.fuzzyFallback")
    }

    /// Peu de pages portent tous les mots demandés : après celles qui les
    /// portent tous, la liste montre celles qui en portent la plupart (RK-04).
    /// Aucun mot de technicien — ni « quorum », ni « ET », ni « requête ».
    ///
    /// Cadre et non `fixedSize`, comme ses voisines : figée en hauteur, cette
    /// ligne faisait mesurer le `NavigationSplitView` à 973 pt dans une
    /// fenêtre de 691 — champ de recherche remonté derrière le titre, hors
    /// d'atteinte (build 918, arbre d'accessibilité, 24/09/2026).
    private var quorumNotice: some View {
        Text("Few pages carry all your words: here are also the pages that carry most of them.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("results.quorum")
    }

    /// L'interrupteur « Chercher aussi par le sens » est armé, mais la requête
    /// demande une phrase entre guillemets, que le sens ne sait pas honorer : il
    /// proposait des pages qui ne portent pas l'expression (RK-01, jugé le
    /// 09/09/2026). Une LIGNE, pas une alerte : rien n'est en panne, les
    /// résultats affichés sont bons, et l'interrupteur reste où il est.
    private var semanticDisarmedNotice: some View {
        Text("Meaning is not used when you ask for an exact phrase.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("results.semanticDisarmed")
    }

    /// Le tri ne peut porter que sur le jeu chargé (voir SortOrder) : le dire,
    /// plutôt que de laisser croire au tri de tout l'index.
    private var partialSortNotice: some View {
        Text("Sorted by \(search.sortOrder.shortLabel) over the first \(Format.integer(search.hits.count)) results loaded. Load more to sort wider.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Le jeu entier est en route pour que le tri soit vrai (PR-08). Le
    /// sélecteur reste ACTIF pendant ce temps : revenir à « pertinence »
    /// interrompt le chargement, et c'est la seule façon de renoncer.
    ///
    /// Cadre et non `fixedSize` : voir les pièges connus, « la colonne des
    /// résultats qui déborde de la fenêtre » (11/09/2026).
    private var sortLoadingNotice: some View {
        Text("Loading every result before sorting them…")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("results.sortLoading")
    }

    /// Le plafond a coupé : on dit sur quoi le tri porte, et sur quel total.
    ///
    /// Les deux nombres passent par `Format.integer` — « 2 000 » et « 29 037 »,
    /// groupés comme partout ailleurs dans la fenêtre — et non par une
    /// variation de pluriel : `xcstringstool` refuse un `%@` dans un pluriel,
    /// et les deux nombres sont ici toujours au-delà de deux mille, donc
    /// toujours au pluriel.
    private var sortCapNotice: some View {
        Text("Sorted by \(search.sortOrder.shortLabel) over the first \(Format.integer(search.hits.count)) results, out of \(Format.integer(search.totalPages)) pages found.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("results.sortCapped")
    }

    /// Menu de tri (audit U4 : « pas de tri, toujours le score »).
    ///
    /// Le tri porte sur les GROUPES de documents, pas sur les pages : le
    /// regroupement par document est la forme d'affichage du §5.1, et trier les
    /// pages en travers le casserait.
    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $search.sortOrder) {
                ForEach(SortOrder.allCases) { order in
                    Label(order.label, systemImage: order.symbol).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(search.sortOrder.shortLabel, systemImage: search.sortOrder.symbol)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .help("Display order of the documents found")
        // Le libellé court affiché (« date ↓ ») porte une flèche que VoiceOver
        // épelle : la valeur parlée est le libellé long de `SortOrder`.
        .accessibilityLabel("Sort the documents")
        .accessibilityValue(search.sortOrder.label)
        .accessibilityHint("Display order of the documents found.")
        .accessibilityIdentifier("results.sort")
    }

    /// Exclusions actives (`-terme`).
    ///
    /// Elles ne sont PAS des pastilles révocables — elles vivent dans le texte
    /// de la requête, on les retire en l'éditant. Mais elles doivent se voir :
    /// une exclusion écarte le DOCUMENT entier (arbitrage T5), donc raccourcit
    /// beaucoup la liste, et l'audit F1 relevait qu'« rien ne trahit la
    /// cause ». Ce libellé est ce qui la trahit.
    @ViewBuilder
    private var exclusionBadge: some View {
        if !search.excludedTerms.isEmpty {
            Text("· except \(search.excludedTerms.map { String(localized: "“\($0)”") }.joined(separator: ", "))")
                .foregroundStyle(.orange)
                .help("Any document containing one of these terms is discarded entirely, including its pages that answer the query.")
                // La couleur orange portait seule le fait qu'une exclusion
                // raccourcit la liste : le libellé le dit.
                .accessibilityLabel(String(localized: "Exclusions: \(search.excludedTerms.joined(separator: ", "))"))
                .accessibilityHint("Any document containing one of these terms is discarded entirely, including its pages that answer the query.")
                .accessibilityIdentifier("results.exclusions")
        }
    }

    /// Comptes du mode hybride : ce qui est affiché vient d'une fusion de deux
    /// top-k ; le seul total exhaustif disponible est celui du canal lexical.
    @ViewBuilder
    private var hybridCounts: some View {
        Text("\(search.totalPages) merged page(s) in \(search.totalDocs) document(s)")
            .accessibilityLabel(AccessibilityText.resultCounts(
                pages: search.totalPages, docs: search.totalDocs, hybrid: true))
            .accessibilityIdentifier("results.counts")
        if search.semanticOnlyCount > 0 {
            Text("· \(Format.integer(search.semanticOnlyCount)) sem.")
                .foregroundStyle(Color.purple)
                .help("Pages found by meaning alone: none of the words you typed appears on them.")
                .accessibilityLabel(
                    AccessibilityText.semanticOnlyPages(search.semanticOnlyCount))
                .accessibilityHint("No term of the query appears on them.")
        }
        Text("· by words: \(Format.integer(search.lexTotalPages)) p. / \(Format.integer(search.lexTotalDocs)) doc.")
            .foregroundStyle(.secondary)
            .help("Total of the word search alone. The meaning search only adds its best pages: it has no total to announce.")
            .accessibilityLabel(String(localized: "Word search alone: \(AccessibilityText.resultCounts(pages: search.lexTotalPages, docs: search.lexTotalDocs, hybrid: false))"))
            .accessibilityHint("The meaning search only adds its best pages: it has no total to announce.")
        // La COUVERTURE, dite là où les comptes se lisent (audit C2-02) : une
        // page sur deux du top-10 peut venir d'un canal qui ne voit que 16 %
        // du corpus, et rien ne le disait.
        // Le seuil était à 0,5 : à 67 % de couverture — l'état réel du fonds
        // le 09/09/2026, 274 244 pages sur 408 951 — un tiers du fonds
        // échappait au canal sans qu'un mot le dise (AP-05). Il se dit
        // désormais dès que la couverture n'est pas COMPLÈTE, et il se dit en
        // nombres de pages : un pourcentage se lisait comme une qualité de
        // résultat, deux comptes se lisent comme ce qu'ils sont.
        if search.semanticPagesIndexed > 0, semanticCoverage < 0.99 {
            Text("· meaning search sees only \(Format.integer(search.semanticVectors)) pages out of \(Format.integer(search.semanticPagesIndexed))")
                .foregroundStyle(.secondary)
                .help("The meaning search only covers the pages prepared for it. Settings ▸ Meaning search explains how to extend it.")
                .accessibilityLabel(String(localized: "Meaning search sees only \(AccessibilityText.pages(search.semanticVectors)) out of \(AccessibilityText.indexedPages(search.semanticPagesIndexed))"))
                .accessibilityHint("The meaning search only covers the pages prepared for it.")
                .accessibilityIdentifier("results.coverage")
        }
    }

    /// Part des pages indexées que le canal sémantique voit réellement, de 0 à
    /// 1 (`Format.percent` attend une fraction).
    private var semanticCoverage: Double {
        search.semanticPagesIndexed > 0
            ? Double(search.semanticVectors) / Double(search.semanticPagesIndexed)
            : 0
    }

    // MARK: - Filtres actifs, visibles et révocables (§5.6)

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let label = search.scope.label {
                    chip(label, systemImage: "scope") { search.clearScope() }
                }
                ForEach(Array(search.selectedFolders).sorted(), id: \.self) { f in
                    chip(String(localized: "folder: \(f)")) {
                        search.selectedFolders.remove(f)
                    }
                }
                ForEach(Array(search.selectedExts).sorted(), id: \.self) { e in
                    chip(".\(e)") { search.selectedExts.remove(e) }
                }
                ForEach(Array(search.selectedYears).sorted(), id: \.self) { y in
                    chip(String(localized: "year: \(y)")) {
                        search.selectedYears.remove(y)
                    }
                }
                ForEach(Array(search.selectedSources).sorted(), id: \.self) { s in
                    chip(String(localized: "origin: \(LanguageNames.sourceLabel(s))")) {
                        search.selectedSources.remove(s)
                    }
                }
                ForEach(Array(search.selectedLangs).sorted(), id: \.self) { l in
                    chip(String(localized: "language: \(LanguageNames.label(l))")) {
                        search.selectedLangs.remove(l)
                    }
                }
                if search.dateFilter != .any {
                    chip(LanguageNames.dateLabel(search.dateFilter),
                         systemImage: "calendar") {
                        search.dateFilter = .any
                    }
                }
                Button("Clear all") { search.clearFilters() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHint("Removes every active filter.")
                    .accessibilityIdentifier("filters.clear")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Active filters")
    }

    private func chip(_ label: String, systemImage: String = "line.3.horizontal.decrease",
                      remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 3) {
                Image(systemName: systemImage).imageScale(.small)
                Text(verbatim: label)
                Image(systemName: "xmark").imageScale(.small)
            }
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .help("Remove this filter")
        // La croix est un pictogramme : sans libellé, la pastille se lit
        // « dossier : Thèse, croix ».
        .accessibilityLabel(String(localized: "Filter \(label)"))
        .accessibilityHint("Removes this filter.")
        .accessibilityIdentifier("filter.chip.\(label)")
    }

    // MARK: - Résultats

    /// La pile des résultats, sortie de `resultsScroll` (lot MN2) : d'un seul
    /// tenant, 1,6 s de vérification de types. Même contenu, même ordre.
    private var resultsStack: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
            if let error = search.errorText {
                errorRow(error)
            }
            // LES NOMS DE FICHIER EN TÊTE (PR-02), avant les pages : ce
            // sont des DOCUMENTS, et c'est le premier réflexe de qui
            // vient du Finder. Ils ne se mêlent pas aux résultats.
            if !search.nameMatches.isEmpty, !search.isSearching {
                nameMatchesBanner
            }
            ForEach(search.groups, id: \.docID) { group in
                groupRows(group)
            }
            if search.canLoadMore {
                loadMoreRow
            }
            if search.isHybrid, !search.groups.isEmpty {
                hybridFooter
            }
            if search.groups.isEmpty, !search.executedText.isEmpty,
               !search.isSearching, search.errorText == nil {
                emptyState
            }
        }
    }

    /// L'en-tête d'un document, ses pages, le séparateur : trois vues que le
    /// `LazyVStack` aplatit, comme quand elles étaient écrites dans la boucle.
    @ViewBuilder
    private func groupRows(_ group: DocGroup) -> some View {
        groupHeader(group)
        if !collapsed.contains(group.docID) {
            // Identité GLOBALE de la ligne, pas seulement locale
            // au groupe. Le `LazyVStack` aplatit les vues émises
            // par la boucle extérieure (en-tête, pages,
            // séparateur) : deux pages n° 1 de deux DOCUMENTS
            // différents portaient donc le même identifiant dans
            // la même pile, et SwiftUI recyclait la ligne sans la
            // redessiner — une nouvelle recherche affichait
            // l'extrait de la PRÉCÉDENTE (relevé en exécutant
            // l'app : « thermodynamique » montrait l'extrait
            // d'« alpha »). doc_id + page est unique.
            ForEach(group.hits, id: \.rowIdentity) { hit in
                hitRow(hit).id(hit.rowIdentity)
            }
        }
        Divider().padding(.leading, 12)
    }

    private var resultsScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                resultsStack
            }
            // Clavier (audit U3) : la liste devient une cible de focus — donc
            // atteignable au Tab depuis le champ de recherche — et reçoit alors
            // ↑↓ pour déplacer la sélection et ⏎ pour ouvrir le document.
            // Aucune touche n'est capturée tant qu'elle n'a PAS le focus : les
            // flèches continuent d'appartenir au champ de saisie.
            .focusable()
            .focused($resultsFocused)
            .onMoveCommand { direction in
                switch direction {
                case .up:   moveSelection(by: -1, proxy: proxy)
                case .down: moveSelection(by: 1, proxy: proxy)
                default:    break
                }
            }
            .modifier(OpenSelectionOnReturn(action: openSelection))
            .modifier(QuickLookOnSpace(action: quickLookSelection))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Results")
            .accessibilityHint("Up and down arrows to move from one page found to the next, Space for a Quick Look, Return to open the document.")
            .accessibilityIdentifier("results.list")
        }
    }

    // MARK: - Documents trouvés par leur nom (PR-02)

    /// Le bandeau des noms de fichier. Un nom ne désigne aucune page — le
    /// résultat de Fouine est une page —, donc chaque ligne ouvre l'aperçu à la
    /// PAGE 1, et ces documents ne comptent pas dans les totaux affichés
    /// au-dessus.
    ///
    /// `search.selection` n'est PAS touchée : elle désigne une page du jeu de
    /// résultats, et le document nommé n'en a aucune. L'aperçu est chargé
    /// directement, avec un hit fabriqué pour la page 1 — c'est ce que fait
    /// `ContentView` à chaque changement de sélection, ici sans sélection.
    private var nameMatchesBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: NameMatchText.banner(count: search.nameMatches.count,
                                                query: search.executedText))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(search.nameMatches, id: \.id) { doc in
                Button {
                    preview.load(hit: Self.firstPageHit(of: doc), roots: app.roots)
                } label: {
                    HStack(spacing: 6) {
                        if let source = DocumentDisplay.source(doc.relPath) {
                            SourceAppIcon(sourceID: source.sourceID, size: 14)
                        } else {
                            Image(systemName: "doc.text.magnifyingglass")
                                .foregroundStyle(.secondary)
                        }
                        Text(verbatim: DocumentDisplay.name(doc.relPath))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .buttonStyle(.link)
                .help("Show the beginning of this document")
                .accessibilityLabel(String(localized: "Open \(DocumentDisplay.name(doc.relPath))"))
                .accessibilityHint("Shows the first page of this document.")
                .accessibilityIdentifier("results.nameMatch.\(doc.id)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("results.nameMatches")
    }

    /// Le hit fabriqué qui désigne la PAGE 1 d'un document nommé. Aucun score,
    /// aucun extrait : il n'a pas été trouvé par son texte, et en inventer un
    /// mettrait un chiffre faux sous les yeux de l'utilisateur.
    private static func firstPageHit(of doc: DocumentListing) -> Hit {
        Hit(docID: doc.id, path: doc.relPath, page: 1, score: 0, snippet: "",
            source: .native, fuzzyDistance: 0)
    }

    // MARK: - Rien trouvé (AP-07)

    /// La phrase, les gestes, puis le conseil.
    ///
    /// Les gestes viennent d'`EmptyStateAdvice`, qui est pur : ce qui se
    /// décide ici, c'est ce que chacun FAIT — et chacun relance la recherche
    /// tout seul, par le `didSet` du réglage qu'il change. Aucun ne fait
    /// silencieusement autre chose que ce qu'il annonce (C2-08).
    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No result for “\(search.executedText)”")
                .foregroundStyle(.secondary)
            let gestures = EmptyStateAdvice.gestures(
                fuzzy: search.fuzzy,
                semanticReady: search.semanticAvailability.isReady,
                semanticOn: search.semanticEnabled,
                filtersActive: search.hasFilters)
            if !gestures.isEmpty {
                HStack(spacing: 14) {
                    ForEach(gestures) { gesture in
                        Button(action: { perform(gesture) }) {
                            Text(verbatim: gesture.label)
                        }
                        .buttonStyle(.link)
                        .accessibilityIdentifier(gesture.identifier)
                    }
                }
            }
            Text(verbatim: EmptyStateAdvice.sentence)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("results.empty.advice")
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private func perform(_ gesture: EmptyStateGesture) {
        switch gesture {
        case .tolerateTypos:   search.fuzzy = .on
        case .searchByMeaning: search.semanticEnabled = true
        case .removeFilters:   search.clearFilters()
        }
    }

    // MARK: - Clavier (audit U3)

    /// Lignes de résultat effectivement affichées, dans l'ordre de la liste :
    /// les pages d'un groupe replié n'en font pas partie, sous peine de faire
    /// « disparaître » la sélection sous une flèche.
    private var visibleHits: [HitKey] {
        search.groups.flatMap { group -> [HitKey] in
            guard !collapsed.contains(group.docID) else { return [] }
            return group.hits.map { HitKey(docID: $0.docID, page: $0.page) }
        }
    }

    private func moveSelection(by delta: Int, proxy: ScrollViewProxy) {
        let keys = visibleHits
        guard !keys.isEmpty else { return }
        let target: Int
        if let current = search.selection,
           let index = keys.firstIndex(of: current) {
            target = min(max(index + delta, 0), keys.count - 1)
        } else {
            // Première flèche sans sélection : on entre par le bout d'où l'on
            // vient (↓ → premier résultat, ↑ → dernier).
            target = delta > 0 ? 0 : keys.count - 1
        }
        let key = keys[target]
        search.selection = key
        proxy.scrollTo(Schema.ftsRowID(docID: key.docID, page: key.page),
                       anchor: .center)
    }

    /// ⏎ : ouvre le document sélectionné dans son application par défaut.
    ///
    /// Le chemin est reconstruit depuis `docRows`, PAS pris dans
    /// `PreviewModel.fileURL` : celui-ci n'est renseigné qu'à la fin du
    /// chargement de l'aperçu, et une flèche suivie d'une entrée rapide
    /// ouvrirait alors le document précédent.
    private func openSelection() {
        guard let key = search.selection, let row = search.docRow(key.docID),
              let url = try? VolumeResolver.absolutePath(
                volUUID: row.record.volUUID, relPath: row.record.relPath)
        else { return }
        // Une copie de Fouine s'ouvre dans SON application, jamais comme le
        // fichier Markdown qu'elle est sur le disque (lot AN2).
        if DocumentDisplay.source(row.record.relPath) != nil {
            if let target = SourceOpenTarget.resolve(relPath: row.record.relPath,
                                                     fileURL: url) {
                NSWorkspace.shared.open(target.url)
            }
            return
        }
        // À la page trouvée quand le lecteur sait y aller (OP1), comme le
        // bouton de l'aperçu : la page est ici, dans `key`.
        ExternalOpen.perform(fileURL: url, page: key.page)
    }

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(verbatim: message).font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(String(localized: "Error: \(message)"))
        .accessibilityIdentifier("results.error")
    }

    /// En-tête d'un document : plier / déplier à gauche, compte de pages à
    /// droite.
    ///
    /// Le compte est SORTI du bouton de pliage (PERSP-Q4) : quand il devient un
    /// geste, c'est un bouton, et deux boutons imbriqués ne se cliquent pas
    /// séparément — le bouton extérieur avale tout. Les deux sont donc frères
    /// dans la même ligne, qui garde sa marge, son menu contextuel et son
    /// double-clic.
    private func groupHeader(_ group: DocGroup) -> some View {
        HStack(spacing: 6) {
            Button {
                if collapsed.contains(group.docID) {
                    collapsed.remove(group.docID)
                } else {
                    collapsed.insert(group.docID)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed.contains(group.docID)
                          ? "chevron.right" : "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    if let source = DocumentDisplay.source(group.path) {
                        SourceAppIcon(sourceID: source.sourceID)
                    } else {
                        Image(systemName: iconForExtension(of: group.path))
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: search.fileName(group.path))
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text(verbatim: search.displayPath(group.path))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Le chevron portait seul l'état plié/déplié, et le compte de pages
            // arrivait en « slash » au milieu de deux nombres à espace fine.
            .accessibilityLabel(AccessibilityText.groupLabel(
                fileName: search.fileName(group.path),
                path: search.displayPath(group.path)))
            .accessibilityValue(AccessibilityText.groupValue(
                loaded: group.hits.count, matched: group.matchedPageCount,
                unit: DocumentDisplay.unit(group.path)))
            .accessibilityHint(AccessibilityText.groupHint(
                collapsed: collapsed.contains(group.docID)))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("results.group.\(group.docID)")
            // `simultaneousGesture` : le simple clic du bouton (plier / déplier)
            // reste, le double-clic ouvre EN PLUS la fenêtre détachée sur la
            // première page trouvée de ce document.
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if let first = group.hits.first {
                    openDetachedPreview(HitKey(docID: first.docID, page: first.page))
                }
            })
            .help(Text(verbatim: detachHelp))
            pageCountLabel(group)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .modifier(DraggableFile(url: fileURL(docID: group.docID)))
        .contextMenu { documentMenu(docID: group.docID) }
    }

    /// Compte de pages d'un document — HONNÊTE (audit A12), et cliquable
    /// quand il manque des pages (PERSP-Q4).
    ///
    /// `DocGroup.pageCount` ne connaît que les pages REÇUES : une recherche
    /// rend 200 pages en tout, un ouvrage dont 400 pages répondent en affichait
    /// donc « 200 p. » sous l'étiquette « pages touchées ». Le texte et la
    /// décision sont dans `PageCountAffordance`, testés ; il ne reste ici que
    /// la forme et l'action.
    @ViewBuilder
    private func pageCountLabel(_ group: DocGroup) -> some View {
        let affordance = PageCountAffordance.decide(
            loaded: group.hits.count,
            matched: group.matchedPageCount,
            scopedToThisDocument: isScoped(to: group.docID))
        let unit = DocumentDisplay.unit(group.path)
        if affordance.isGesture {
            Button {
                search.scopeToDocument(id: group.docID,
                                       name: search.fileName(group.path))
            } label: {
                Text(verbatim: affordance.label(unit: unit))
                    .font(.caption)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help(Text(verbatim: affordance.help(unit: unit)))
            .accessibilityLabel(Text(verbatim: affordance.accessibilityLabel(unit: unit)))
            .accessibilityHint(Text(verbatim: affordance.accessibilityHint ?? ""))
            .accessibilityIdentifier("results.group.\(group.docID).seeAll")
        } else {
            Text(verbatim: affordance.label(unit: unit))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(Text(verbatim: affordance.help(unit: unit)))
        }
    }

    /// La recherche est-elle déjà bornée à ce document ?
    private func isScoped(to docID: Int64) -> Bool {
        if case .document(let id, _) = search.scope { return id == docID }
        return false
    }

    /// Menu contextuel d'un document : les trois gestes du Finder, puis la
    /// lecture des scans quand il y en a en attente (AP-10, PR-15).
    ///
    /// CE QU'IL Y AVAIT AVANT : « OCRiser ce document d'abord » — un verbe qui
    /// n'existe pour personne — ou, quand rien n'attendait, la phrase INERTE
    /// « Aucune page de ce document n'attend l'OCR ». Un clic droit dont la
    /// seule entrée n'est pas cliquable est une impasse, et c'est le geste
    /// réflexe de tout utilisateur du Finder.
    ///
    /// Les deux premiers visent le document de LA LIGNE, par son chemin, et
    /// non `PreviewModel` : un clic droit ne change pas la sélection, et
    /// l'aperçu montre peut-être un autre document.
    ///
    /// La file OCR se consomme dans l'ordre des `doc_id` (priorités
    /// dégénérées, audit A9) : sans la dernière entrée, obtenir un ouvrage
    /// précis demande d'attendre plusieurs jours. Elle n'est là que si le
    /// document a des pages en attente, et pas pendant qu'une autre opération
    /// tourne (`guard !indexing.running`, `AppModel.startOCR`).
    @ViewBuilder
    private func documentMenu(docID: Int64) -> some View {
        let url = search.absoluteURL(docID: docID)
        if let row = search.docRow(docID),
           let source = DocumentDisplay.source(row.record.relPath) {
            // Une copie de Fouine : son application, pas le Finder (lot AN2).
            // Le lien d'une note est relu dans son fichier au clic seulement —
            // ouvrir un menu contextuel ne doit pas lire le disque.
            Button(SourceOpenTarget.label(forSource: source.sourceID)) {
                guard let target = SourceOpenTarget.resolve(
                    relPath: row.record.relPath, fileURL: url) else { return }
                NSWorkspace.shared.open(target.url)
            }
            .disabled(url == nil)
        } else {
            Button("Show in Finder") {
                guard let url else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .disabled(url == nil)
            Button("Open") {
                guard let url else { return }
                NSWorkspace.shared.open(url)
            }
            .disabled(url == nil)
        }
        Button("Search inside this document") {
            guard let row = search.docRow(docID) else { return }
            search.scopeToDocument(id: docID,
                                   name: search.fileName(row.record.relPath))
        }
        .disabled(search.docRow(docID) == nil)
        if let row = search.docRow(docID), app.hasQueuedOCR(row) {
            Divider()
            Button {
                app.startOCR(document: row)
            } label: {
                Label("Read its scanned pages first", systemImage: "text.viewfinder")
            }
            .disabled(app.indexing.running)
        }
    }

    /// Une ligne de résultat.
    ///
    /// SCINDÉE EN MORCEAUX TYPÉS (lot MN2, mesure de BT1) : d'un seul tenant,
    /// ce corps coûtait 8,6 s de vérification de types à chaque compilation de
    /// l'app — les ternaires sans type (`selected ? [.isSelected] : []`,
    /// `?? (… ? .none : .vision)`) et la longue chaîne de modificateurs. Même
    /// arbre de vues, mêmes modificateurs dans le même ordre.
    private func hitRow(_ hit: Hit) -> some View {
        let key = HitKey(docID: hit.docID, page: hit.page)
        let selected = search.selection == key
        let info = search.hybridInfo[key]
        let semanticOnly = info?.semanticOnly ?? false
        let unit = DocumentDisplay.unit(hit.path)
        let traits: AccessibilityTraits = selected ? [.isSelected] : []
        return Button {
            selectHit(hit, key: key)
        } label: {
            hitLabel(hit, key: key, selected: selected, info: info,
                     semanticOnly: semanticOnly, unit: unit)
        }
        .buttonStyle(.plain)
        // Tout ce qui n'était que visuel entre ici : le pictogramme de
        // provenance, l'insigne « ≈ » (flou ou sémantique), le fond de
        // sélection. L'extrait passe en VALEUR — VoiceOver le lit après le
        // libellé, ce qui laisse le nom du document et la page en tête.
        .accessibilityLabel(hitAccessibilityLabel(hit, key: key,
                                                  semanticOnly: semanticOnly,
                                                  unit: unit))
        .accessibilityValue(hitAccessibilityValue(hit, selected: selected))
        .accessibilityHint("Shows this page in the preview. Double-click, or Command-Return, to open it in its own window.")
        .accessibilityAddTraits(traits)
        .accessibilityIdentifier("results.hit.\(hit.docID).\(hit.page)")
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            openDetachedPreview(key)
        })
        // Tirer un résultat vers Mail, Zotero ou un dossier (PR-16) : c'est le
        // FICHIER qui part, pas la page — aucune application ne sait recevoir
        // « la page 87 de ce PDF ».
        .modifier(DraggableFile(url: fileURL(docID: hit.docID)))
        .help(Text(verbatim: detachHelp))
        .contextMenu { hitContextMenu(hit, key: key) }
    }

    private func selectHit(_ hit: Hit, key: HitKey) {
        // LE MOMENT AVANT LA SÉLECTION (lot PV1) : c'est la sélection qui
        // déclenche le chargement de l'aperçu (`ContentView`), et la
        // demande doit être posée quand il arrive. Elle porte la clé de sa
        // page — une demande d'une autre ligne ne la suit pas.
        if hit.source == .transcript {
            preview.requestTime(Self.hitSeconds(hit), for: key)
        }
        search.selection = key
        // Un clic donne aussi le focus clavier à la liste : les flèches
        // continuent le parcours là où la souris l'a laissé.
        resultsFocused = true
    }

    private func hitLabel(_ hit: Hit, key: HitKey, selected: Bool,
                          info: HybridInfo?, semanticOnly: Bool,
                          unit: PageUnit) -> some View {
        let background: Color = selected ? Color.accentColor.opacity(0.16) : Color.clear
        return VStack(alignment: .leading, spacing: 2) {
            hitLine(hit, key: key, selected: selected, info: info,
                    semanticOnly: semanticOnly, unit: unit)
            // POURQUOI CE RÉSULTAT (lot U1, R-06) — sous la ligne SÉLECTIONNÉE
            // seulement. Une phrase sous chacune des deux cents lignes ferait
            // un mur, et il faudrait lire autant de pages qu'il y a de
            // résultats affichés. Elle paraît quand la lecture a répondu, et
            // pas du tout s'il n'y a rien d'honnête à dire.
            if selected, let explanation = search.selectionExplanation {
                whyLine(explanation)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .contentShape(Rectangle())
    }

    private func hitLine(_ hit: Hit, key: HitKey, selected: Bool,
                         info: HybridInfo?, semanticOnly: Bool,
                         unit: PageUnit) -> some View {
        let pageStyle: HierarchicalShapeStyle = selected ? .primary : .secondary
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: unit.short(hit.page))
                .font(.caption.monospacedDigit())
                .foregroundStyle(pageStyle)
                // « carte 642 » est plus long que « p. 642 » (lot AN2) :
                // la colonne garde sa largeur, le texte se resserre plutôt
                // que de passer à la ligne.
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 56, alignment: .trailing)
            if semanticOnly {
                // La provenance d'un hit sémantique pur n'est pas connue
                // sans un balayage de page_src : on n'affiche donc PAS un
                // pictogramme qui mentirait, mais l'insigne du canal.
                semanticBadge(info)
            } else {
                provenanceIcon(hit: hit, key: key)
            }
            if hit.source == .transcript {
                timestampChip(hit: hit)
            }
            hitSnippet(hit, semanticOnly: semanticOnly)
            if hit.fuzzyDistance > 0 {
                fuzzyMark(hit.fuzzyDistance)
            }
            // PLUS DE POURCENTAGE PAR LIGNE (AP-08, décision du
            // 09/09/2026). Il rapportait le score de la page au meilleur
            // score du jeu CHARGÉ : « Charger plus » changeait tous les
            // chiffres déjà affichés, et dans un groupe — dont les pages
            // sont rangées par NUMÉRO, pas par score — la colonne
            // descendait puis remontait, ce qui se lit comme un défaut de
            // tri. Le classement des documents dit la pertinence ; la
            // ligne « Trouvé parce que… » dit le reste.
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func hitSnippet(_ hit: Hit, semanticOnly: Bool) -> some View {
        if semanticOnly {
            // Début brut de la page : surtout PAS `attributedSnippet`,
            // dont les marqueurs sont « et » — omniprésents dans un
            // texte français, ils surligneraient n'importe quoi.
            Text(verbatim: hit.snippet)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        } else {
            Text(attributedSnippet(hit.snippet))
                .font(.callout)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
    }

    private func fuzzyMark(_ distance: Int) -> some View {
        Text("≈\(distance)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.orange)
            // « distance 2 » est du vocabulaire d'informaticien
            // (lot J2) : on dit ce que ça VEUT dire — combien de
            // lettres séparent le mot trouvé de celui cherché.
            .help(String(localized: "Close spelling: \(distance) letters apart from your search"))
    }

    private func whyLine(_ explanation: HitExplanation) -> some View {
        Text(verbatim: HitExplanationText.sentence(explanation))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 64)
            // VoiceOver la lit dans la VALEUR de la ligne, avec
            // l'extrait : deux annonces séparées la couperaient de ce
            // qu'elle explique.
            .accessibilityHidden(true)
            .accessibilityIdentifier("results.why")
    }

    private func hitAccessibilityLabel(_ hit: Hit, key: HitKey, semanticOnly: Bool,
                                       unit: PageUnit) -> String {
        let engine: OCREngineID = search.engines[key]
            ?? (hit.source == .native ? .none : .vision)
        let timestamp: String? = hit.source == .transcript
            ? TranscriptMarkers.timestamp(Self.hitSeconds(hit)) : nil
        return AccessibilityText.hitLabel(
            fileName: search.fileName(hit.path),
            page: hit.page,
            source: hit.source,
            engine: engine,
            semanticOnly: semanticOnly,
            fuzzyDistance: hit.fuzzyDistance,
            timestamp: timestamp,
            unit: unit)
    }

    private func hitAccessibilityValue(_ hit: Hit, selected: Bool) -> String {
        let why: String? = selected
            ? search.selectionExplanation.map(HitExplanationText.sentence) : nil
        return AccessibilityText.hitValue(snippet: hit.snippet, why: why)
    }

    @ViewBuilder
    private func hitContextMenu(_ hit: Hit, key: HitKey) -> some View {
        Button("Open the preview in its own window") {
            openDetachedPreview(key)
        }
        // Citer CETTE page (lot INT-L1). Le même menu que la barre d'outils
        // de l'aperçu, aux mêmes mots : le geste ne doit pas s'appeler
        // autrement selon l'endroit d'où on le fait.
        Menu("Copy a reference to this page") {
            Button("Copy the reference") {
                Citation.copy(search.pageReference(docID: hit.docID,
                                                   page: hit.page,
                                                   path: hit.path))
            }
            Button("Copy the link") {
                Citation.copy(Citation.linkOnly(
                    search.pageLink(docID: hit.docID, page: hit.page)))
            }
        }
        Divider()
        documentMenu(docID: hit.docID)
    }

    /// « ▶ 12:40 » sur la ligne d'un passage ENTENDU (lot PV1).
    ///
    /// Ce que la pastille annonce : le repère porté par l'extrait quand il en
    /// porte un — ils sont absolus, comptés depuis le début de
    /// l'enregistrement —, sinon le début de la page.
    ///
    /// PAS UN BOUTON DANS UN BOUTON : toute la ligne en est déjà un, et c'est
    /// son action qui pose la tête de lecture. Un second bouton imbriqué se
    /// disputerait le clic avec elle.
    ///
    /// CE QU'UNE LIGNE DE RÉSULTAT NE PEUT PAS SAVOIR : si l'enregistrement
    /// s'ouvre sur une page de balises. La numérotation des pages est compacte
    /// (`MediaExtractor`), et l'écart possible vaut une fenêtre — dix minutes.
    /// L'aperçu, lui, a les repères de la page sous les yeux : il refuse un
    /// moment qui ne tombe pas dedans et se replace sur le passage trouvé
    /// (`TranscriptMarkers.covers`).
    private func timestampChip(hit: Hit) -> some View {
        Label(TranscriptMarkers.timestamp(Self.hitSeconds(hit)),
              systemImage: "play.fill")
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
            .foregroundStyle(Color.accentColor)
            .help("Click the line to hear this passage")
            // La ligne entière porte déjà « à 12:40 » dans son libellé parlé :
            // un second élément à parcourir ferait annoncer le moment deux fois.
            .accessibilityHidden(true)
    }

    /// Le moment d'un résultat de transcription (voir `timestampChip`).
    private static func hitSeconds(_ hit: Hit) -> Int {
        TranscriptMarkers.extractStart(
            snippet: hit.snippet,
            pageStart: TranscriptMarkers.startSeconds(page: hit.page,
                                                      firstWindowPage: 1))
    }

    /// Insigne d'un hit sémantique pur : aucun terme de la requête n'est sur
    /// cette page, elle vient de la proximité vectorielle seule. Le cosinus et
    /// le rang du canal partent dans l'infobulle — l'insigne, lui, reste un
    /// signe discret.
    private func semanticBadge(_ info: HybridInfo?) -> some View {
        var help = String(localized: "Found by meaning: none of your words is on this page.")
        // La MARGE, pas le cosinus (audit C2-01/C2-13) : sur ce corpus tous les
        // cosinus tiennent entre 0,78 et 0,88, et « Cosine 0.85 » se lisait
        // comme « 85 % de pertinence ». Mais « +2,4 σ » ne se lit pas non plus :
        // σ est l'écart-type, un mot que le public ne connaît pas (lot J2). La
        // marge se DIT, par paliers — le nombre exact n'aidait personne, et le
        // rang du canal sémantique encore moins.
        if let z = info?.z {
            help += " " + SemanticMarginText.describe(z)
        }
        return Text(verbatim: "≈")
            .font(.caption.bold())
            .foregroundStyle(Color.purple)
            .help(help)
    }

    /// Pictogramme de provenance : texte tapé / scanné / scanné avant Fouine.
    ///
    /// Le libellé vient de `LanguageNames`, seule table des provenances
    /// (AP-03) : cette infobulle disait « texte natif » à trois centimètres de
    /// la facette qui disait « texte tapé ».
    private func provenanceIcon(hit: Hit, key: HitKey) -> some View {
        let engine = search.engines[key] ?? (hit.source == .native ? .none : .vision)
        let symbol: String
        switch (hit.source, engine) {
        case (.native, _):   symbol = "doc.text"
        case (_, .external): symbol = "square.and.arrow.down.on.square"
        default:             symbol = "text.viewfinder"
        }
        let help = LanguageNames.sourceLabel(hit.source, engine: engine)
        return Image(systemName: symbol)
            .imageScale(.small)
            .foregroundStyle(hit.source == .native ? Color.secondary : Color.teal)
            .help(help)
    }

    /// « Charger plus » — le chargement automatique à l'apparition n'a lieu que si
    /// le dernier chargement a rendu des résultats VISIBLES (audit A10.3) : sinon
    /// un filtre d'affichage qui vide la liste rendrait cette ligne visible
    /// d'emblée et rejouerait la requête par tranches de 200 jusqu'à épuisement.
    /// Pourquoi il n'y a pas de « Charger plus » en hybride : le RRF fusionne
    /// deux top-k de profondeur fixe, il ne pagine pas — une seconde tranche
    /// obtenue par offset n'aurait aucun sens dans le classement fusionné.
    private var hybridFooter: some View {
        Text("Word search and meaning search combined: the \(Format.integer(search.hits.count)) best pages, and no more. Refine the query or the filters to see other pages, or turn “Also search by meaning” off to browse the whole list.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadMoreRow: some View {
        VStack(spacing: 2) {
            HStack {
                Spacer()
                Button {
                    search.loadMore()
                } label: {
                    if search.isSearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Load more (\(Format.integer(search.hits.count)) / \(Format.integer(search.totalPages)))")
                    }
                }
                .padding(.vertical, 10)
                .accessibilityLabel("Load more results")
                .accessibilityValue(String(localized: "\(AccessibilityText.loadedPages(search.hits.count)) out of \(search.totalPages)"))
                .accessibilityIdentifier("results.loadMore")
                Spacer()
            }
            if !search.autoLoadMore, !search.isSearching, search.hasDisplayFilters {
                Text("The display filter hides the last pages loaded: the rest loads on demand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
        .onAppear { if search.autoLoadMore { search.loadMore() } }
    }

    // MARK: - Extrait marqué

    /// Le snippet FTS5 arrive avec « » autour des occurrences et … aux coupures.
    /// Les guillemets deviennent une surbrillance colorée PAR TERME (§5.6) ; les
    /// points de suspension restent.
    private func attributedSnippet(_ snippet: String) -> AttributedString {
        var out = AttributedString()
        for segment in SnippetParser.segments(snippet) {
            var run = AttributedString(segment.text)
            if segment.marked {
                let term = QueryTerms.match(segment.text, in: search.terms)
                run.backgroundColor = TermPalette.wash(term?.colorIndex ?? 0)
                run.font = .callout.bold()
            }
            out += run
        }
        return out
    }

    private func iconForExtension(of path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "cbz", "cbr": return "book"
        case "docx", "doc", "rtf", "odt": return "doc.text"
        case "pptx": return "rectangle.on.rectangle"
        case "xlsx", "csv": return "tablecells"
        case "epub": return "books.vertical"
        default: return "doc"
        }
    }
}

/// La largeur de la colonne des résultats, portée jusqu'à la barre d'état.
private struct ColumnWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Rend une ligne de résultat glissable, quand le fichier est atteignable
/// (PR-16). Un volume débranché n'a pas de chemin : la ligne reste alors une
/// ligne ordinaire plutôt qu'une source de dépôt qui ne déposerait rien.
private struct DraggableFile: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let url {
            content.draggable(url)
        } else {
            content
        }
    }
}

/// ⏎ sur la liste de résultats ouvre le document sélectionné.
///
/// `onKeyPress` n'existe qu'à partir de macOS 14, et le paquet cible macOS 13
/// (`Package.swift`) : en dessous, le clic et le menu contextuel restent les
/// chemins d'ouverture. Un bouton invisible portant `.keyboardShortcut(.return)`
/// aurait marché partout — mais il aurait pris ⏎ dans TOUTE la fenêtre, y
/// compris dans le champ de recherche, dont ⏎ est justement la validation.
private struct OpenSelectionOnReturn: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onKeyPress(.return) {
                action()
                return .handled
            }
        } else {
            content
        }
    }
}
