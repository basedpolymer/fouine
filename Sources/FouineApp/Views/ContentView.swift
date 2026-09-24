// ContentView.swift — fenêtre principale, trois panneaux (SPEC §5.6).
// Propriété : A-App.
//
// NavigationSplitView imposé : sources et facettes | résultats | aperçu.
// Le bandeau TCC (§7.1) est PERSISTANT : il reste tant que la sonde échoue, avec
// le geste exact et un bouton vers les Réglages Système.

import SwiftUI
import FouineCore

struct ContentView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var search: SearchModel
    @EnvironmentObject private var preview: PreviewModel

    /// Le corps se lit en trois étages (lot MN2) : l'écran, la feuille et les
    /// alertes, les réactions. D'un seul tenant il coûtait 3,5 s de
    /// vérification de types (mesure de BT1). Mêmes modificateurs, même ordre.
    var body: some View {
        folderAddAlert(noticeAlerts(screen))
            .onChange(of: search.selection) { selection in
                preview.load(hit: hit(for: selection), roots: app.roots)
            }
            // Les étiquettes des racines suivent la barre latérale : `dossier:Xyz`
            // est confronté à cette liste avant d'être envoyé au moteur, et une
            // étiquette inconnue est DITE au lieu de rendre zéro résultat (idée 5
            // de l'audit A1). `SearchModel` ne lit pas la base lui-même.
            .onChange(of: app.roots) { roots in
                search.knownFolders = roots.map(\.label)
            }
            .onAppear { search.knownFolders = app.roots.map(\.label) }
    }

    private var screen: some View {
        Group {
            if let error = app.openError {
                openFailureView(error)
            } else if !app.isReady {
                // RIEN tant que l'app n'a pas lu ses dossiers (UX-01). Avant,
                // `roots` était vide par construction pendant l'ouverture de la
                // base, et l'écran d'accueil « Bienvenue dans Fouine — ajoutez
                // un dossier » clignotait à CHAQUE lancement, sur un index de
                // quatre cent mille pages. Une fenêtre vide de la couleur du
                // fond ne dit rien de faux.
                StartupPlaceholder()
            } else if app.roots.isEmpty && app.rootsError == nil {
                // Aucun dossier : les trois panneaux n'auraient rien à montrer
                // et rien à proposer (audit D1). L'écran d'accueil prend toute
                // la fenêtre jusqu'au premier dossier ajouté.
                WelcomeView(style: .window)
            } else {
                VStack(spacing: 0) {
                    if let banner = app.tccBanner {
                        TCCBannerView(text: banner)
                    }
                    NavigationSplitView {
                        SidebarView()
                            .navigationSplitViewColumnWidth(min: 230, ideal: 270,
                                                            max: 360)
                    } content: {
                        // 350 et 300 (audit U6) : la fenêtre descend à 900 points
                        // de large, et 230 + 350 + 300 tient dedans. En dessous,
                        // le champ de recherche et le titre d'un résultat se
                        // tronquent au milieu d'un mot.
                        ResultsView()
                            .navigationSplitViewColumnWidth(min: 350, ideal: 540)
                    } detail: {
                        PreviewPane()
                            .navigationSplitViewColumnWidth(min: 300, ideal: 460)
                    }
                }
            }
        }
    }

    private func noticeAlerts<Content: View>(_ content: Content) -> some View {
        content
        // UNE seule feuille attachée à la vue (audit A10.6). Deux `.sheet` empilés
        // sur le même conteneur, avec des transitions qui basculaient les deux
        // drapeaux dans le même cycle de rafraîchissement (« Lancer l'OCR… » puis
        // « Lancer l'OCR »), sont le cas d'école où la seconde ne s'ouvre pas.
        // Ici l'enchaînement n'est qu'un changement de contenu DANS la feuille
        // déjà présentée : `isPresented` ne repasse jamais par `false`.
        .sheet(isPresented: Binding(get: { app.sheet != nil },
                                    set: { if !$0 { app.sheet = nil } })) {
            SheetHost()
        }
        // Refus de `RootPolicy` et avertissement « Téléchargements » : une alerte
        // au niveau de la fenêtre, parce que l'ajout part aussi bien de l'écran
        // d'accueil que de la barre latérale.
        .alert(app.rootNotice?.title ?? "", isPresented: Binding(
            get: { app.rootNotice != nil },
            set: { if !$0 { app.rootNotice = nil } }
        ), presenting: app.rootNotice) { notice in
            // Un refus de lecture se répare (AP-01) : les deux gestes de la
            // réparation sont ICI, dans l'alerte qui l'annonce. Sans eux, le
            // seul bouton était « OK » et l'on retombait sur l'écran d'accueil
            // vide — sans savoir que la case existe dans les Réglages Système,
            // ni que le dossier peut être proposé une seconde fois.
            // Le dossier d'Anki, de Notes ou de Bear : la case de l'application
            // est dans les réglages de Fouine, pas dans ceux du système.
            if notice.offersApplicationSettings {
                Button("Open Settings") { openSettings(on: .folders) }
            }
            if notice.offersRecovery {
                Button("Open System Settings") { app.openPrivacySettings() }
                Button("Retry") { app.chooseRootsToAdd() }
            }
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
        // Issue d'une restauration de sauvegarde (B1-14) : au niveau de la
        // fenêtre, parce qu'un succès fait DISPARAÎTRE l'écran d'échec qui l'a
        // lancée — le message doit survivre à ce changement de vue.
        .alert(app.restoreNotice?.title ?? "", isPresented: Binding(
            get: { app.restoreNotice != nil },
            set: { if !$0 { app.restoreNotice = nil } }
        ), presenting: app.restoreNotice) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
    }

    private func folderAddAlert<Content: View>(_ content: Content) -> some View {
        content
        // Un dossier lâché sur l'icône du Dock, que personne ne suit encore
        // (lot DD2). ON DEMANDE : sur l'icône du Dock, le même geste peut
        // vouloir dire « cherche là-dedans » comme « ajoute-le », et indexer
        // d'autorité serait une surprise. Le dépôt sur la barre latérale, lui,
        // vise la liste des dossiers et ajoute sans confirmation.
        .alert(folderAddTitle, isPresented: Binding(
            get: { app.folderAddRequest != nil },
            set: { if !$0 { app.folderAddRequest = nil } }
        ), presenting: app.folderAddRequest) { request in
            if request.urls.count == 1 {
                Button("Add this folder") { app.confirmFolderAdd() }
            } else {
                Button("Add these folders") { app.confirmFolderAdd() }
            }
            Button("Cancel", role: .cancel) { app.folderAddRequest = nil }
        } message: { request in
            if request.urls.count == 1 {
                Text("Fouine will index this folder and keep it up to date.")
            } else {
                Text("Fouine will index these folders and keep them up to date.")
            }
        }
    }

    /// Le titre de l'alerte du dépôt (DD2). Une `String` déjà traduite, comme
    /// pour les autres alertes de cette vue : `.alert(_:isPresented:)` ne
    /// localise pas ce qu'on lui donne en `String`.
    private var folderAddTitle: String {
        guard let request = app.folderAddRequest else { return "" }
        guard request.urls.count == 1 else {
            return String(localized: "Search these folders with Fouine?")
        }
        return String(localized: "Search “\(request.name)” with Fouine?")
    }

    private func hit(for key: HitKey?) -> Hit? {
        guard let key else { return nil }
        return search.hits.first {
            $0.docID == key.docID && $0.page == key.page
        }
    }

    private func openFailureView(_ message: String) -> some View {
        OpenFailureView(rawError: message)
    }
}

/// La fenêtre pendant l'ouverture de la base (UX-01).
///
/// Elle ne montre RIEN — pas de titre, pas de logo, pas de « Chargement… » :
/// un lancement normal dure quelques dizaines de millisecondes, et tout ce qui
/// s'affiche pendant ce temps-là est un clignotement. L'anneau n'apparaît
/// qu'après 400 ms, c'est-à-dire seulement quand quelque chose traîne
/// réellement — une base sur disque externe, un volume qui se réveille — et
/// c'est le seul moment où il renseigne.
struct StartupPlaceholder: View {
    @State private var slow = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            if slow {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Opening your index…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            slow = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Opening your index…")
        .accessibilityIdentifier("window.startup")
    }
}

/// Bandeau persistant de refus TCC (§7.1) : nomme les racines bloquées, rappelle
/// que les résultats restent consultables, donne le geste exact.
struct TCCBannerView: View {
    @EnvironmentObject private var app: AppModel
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)     // le libellé du texte le dit
            // Un cadre, pas `fixedSize` : au-dessus du `NavigationSplitView`,
            // la phrase figée en hauteur était mesurée à largeur nulle et
            // faisait grandir la fenêtre au-delà de l'écran
            // (`ColumnOverflowTests`, 24/09/2026).
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Le fond orange et le cadenas portaient seuls la nature du
                // bandeau : le libellé nomme l'alerte avant de la lire.
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(
                    String(localized: "Access permission denied. \(text)"))
                .accessibilityIdentifier("tcc.banner.text")
            Spacer(minLength: 8)
            Button("Open Settings") { app.openPrivacySettings() }
                // Une chaîne visible ne se coupe PAS avec `+` : la
                // concaténation produit un `String`, que SwiftUI affiche tel
                // quel au lieu de le chercher dans le catalogue. Les longues
                // phrases tiennent donc sur une ligne (docs/i18n.md).
                .accessibilityHint("Opens Privacy & Security, File Access pane.")
                .accessibilityIdentifier("tcc.banner.settings")
            Button("Retry") {
                Task { await app.refreshRoots(probe: true) }
            }
            .accessibilityHint("Checks again whether every folder can be read.")
            .accessibilityIdentifier("tcc.banner.retry")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14))
        .overlay(Divider(), alignment: .bottom)
        // `.contain` : le bandeau est un groupe nommé dont les deux boutons
        // restent atteignables — un `.combine` les avalerait.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission banner")
        .accessibilityIdentifier("tcc.banner")
    }
}
