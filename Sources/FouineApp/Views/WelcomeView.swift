// WelcomeView.swift — écran d'accueil et état vide des sources (audit D1).
// Propriété : A-App. SPEC §5.6.
//
// Avant, une base sans racine ouvrait une fenêtre à trois panneaux vides et une
// ligne « Aucune racine enregistrée » sans le moindre bouton : l'app était
// inutilisable par quiconque n'avait pas `~/Livres` sur son disque. Ce composant
// est le seul geste possible dans cet état, et il sert DEUX fois — plein cadre
// tant qu'aucune racine n'existe, et en tête de la section « Sources » de la
// barre latérale.
//
// Trois phrases, pas quatre : ce que fait Fouine, ce qu'elle ne fait jamais
// (modifier les fichiers, sortir sur le réseau), et l'invite système à venir.
// La dernière est ce qui évite le mode d'échec n°1 du projet : un utilisateur
// qui refuse l'invite TCC parce qu'il ne l'attendait pas.

import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {
    @EnvironmentObject private var app: AppModel

    enum Style {
        /// Plein cadre, à la place des trois panneaux.
        case window
        /// Compact, dans la section « Sources » de la barre latérale.
        case sidebar
    }
    let style: Style

    @State private var targeted = false
    @State private var copiedRequest = false

    var body: some View {
        Group {
            switch style {
            case .window: windowBody
            case .sidebar: sidebarBody
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            app.handleDrop(providers: providers)
        }
    }

    // MARK: - Plein cadre

    private var windowBody: some View {
        VStack(spacing: 18) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 46))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)      // décoratif : le titre suit

            Text("Welcome to Fouine")
                .font(.title.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 8) {
                // Par INDICE : `LocalizedStringKey` n'est pas `Hashable`, il
                // ne peut donc pas servir d'identité à `ForEach`.
                ForEach(Self.pitch.indices, id: \.self) { index in
                    Label {
                        Text(Self.pitch[index])
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 6)
                            .accessibilityHidden(true)   // puce de liste
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 520, alignment: .leading)

            addButton
                .controlSize(.large)

            dropZone
                .frame(maxWidth: 520)

            assistantHint
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Barre latérale

    private var sidebarBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No folder indexed yet. Fouine only searches the folders you give it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isStaticText)
            dropZone
        }
        .padding(.vertical, 4)
    }

    // MARK: - Éléments partagés

    private var addButton: some View {
        Button {
            app.chooseRootsToAdd()
        } label: {
            Label("Add a folder…", systemImage: "folder.badge.plus")
        }
        .accessibilityHint("Opens the folder chooser. macOS will then ask for permission to access the chosen folder. Without that permission, Fouine cannot index it.")
        .accessibilityIdentifier("welcome.addRoot")
    }

    private var dropZone: some View {
        VStack(spacing: 4) {
            Image(systemName: "arrow.down.doc")
                .foregroundStyle(.secondary)
            Text("…or drop folders here")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(targeted ? Color.accentColor.opacity(0.12) : Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        // Une zone en pointillés ne se voit pas à l'oreille : elle est nommée,
        // et son état de survol est dit — c'est la seule fonction du cadre
        // coloré. Le dépôt lui-même vaut sur toute la barre latérale.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Folder drop zone")
        .accessibilityValue(targeted ? String(localized: "folder over the zone")
                                     : "")
        .accessibilityHint("Drop folders from the Finder here to have them indexed.")
        .accessibilityIdentifier("welcome.dropZone")
    }

    /// La ligne de l'assistant IA (demande du propriétaire du 14/09/2026). HORS
    /// des trois phrases et SOUS le geste : ce n'est pas ce qu'il faut savoir
    /// avant d'ajouter un dossier, c'est ce qu'on pourra faire ensuite. « MCP »
    /// reste en toutes lettres, par exception au vocabulaire de l'app : la
    /// phrase est faite pour être répétée à l'assistant, et c'est le mot qu'il
    /// reconnaît.
    private var assistantHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text("To use Fouine with your AI assistant (Claude, Codex, Antigravity…), ask it to install the Fouine MCP!")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)      // décoratif : la phrase suffit
            }
            .accessibilityIdentifier("welcome.assistant")

            // Le bouton met dans le presse-papiers la demande COMPLÈTE, chemin
            // du binaire compris (`AssistantRequest`) : « installe le MCP de
            // Fouine » ne suffit pas à un assistant tant que `fouine` n'est
            // pas sur son PATH, et rien à l'écran ne doit montrer ce chemin.
            Button {
                AssistantRequest.copy()
                copiedRequest = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    copiedRequest = false
                }
            } label: {
                Label(copiedRequest ? "Request copied — paste it to your assistant"
                                    : "Copy the request for your assistant",
                      systemImage: copiedRequest ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.link)
            .padding(.leading, 22)   // sous le texte, aligné après l'icône
            .accessibilityIdentifier("welcome.assistant.copy")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// Les trois phrases, résolues dans le catalogue à l'affichage : le tableau
    /// porte des `LocalizedStringKey`, que `Text` cherche dans `Bundle.main`.
    private static let pitch: [LocalizedStringKey] = [
        "Fouine searches the text inside your documents (PDF, EPUB, DOCX, scanned pages) and takes you to the exact page.",
        // La promesse d'accueil, réécrite le 02/09/2026 (audit B1-03) :
        // « n'ouvre aucune connexion réseau » était faux — le téléchargement
        // du modèle et la recherche de mise à jour en ouvrent, à la demande.
        // Ce qui est vrai, et ce qui compte pour l'utilisateur, c'est que
        // rien de SES données ne sort. Le silence réseau à l'indexation est
        // tenu par NetworkSilenceTests, pas par cette phrase.
        "It reads your files without ever modifying them: no document and no search query ever leaves this Mac.",
        "When you add your first folder, macOS will ask for permission to access it. Without that permission, Fouine cannot index it.",
    ]
}
