// TextPreviewView.swift — aperçu du texte INDEXÉ d'une page (SPEC §5.6).
// Propriété : A-App.
//
// Pourquoi ce panneau existe (audit U4) : `txt`, `md`, `html`, `epub`, `docx`,
// `rtf`, `djvu` n'ont pas de rendu par page, et l'aperçu affichait « aperçu non
// disponible pour ce format » alors que le texte de la page trouvée était déjà
// en base, à un SELECT de distance. C'était la fonction manquante la plus
// rentable du produit : chercher sans pouvoir lire ce qu'on a trouvé oblige à
// ouvrir chaque document dans une autre application.
//
// Trois règles tenues ici :
//   · AUCUN accès disque pour le TEXTE — il vient de `page_fts`, donc l'aperçu
//     marche aussi quand le volume est débranché ou l'autorisation TCC refusée.
//     Les images d'une carte Anki (lot AN1) sont la seule lecture de fichier,
//     et une image absente laisse la carte lisible ;
//   · les termes de la requête sont surlignés avec LES MÊMES couleurs que
//     l'extrait et que le PDF (§5.6) ;
//   · le texte est sélectionnable et copiable — c'est un lecteur, pas une
//     image.

import SwiftUI

struct TextPreviewView: View {
    let page: PageTextContent
    let terms: [HighlightTerm]
    /// Le document et la page affichés, qui entrent dans la clé de rendu.
    var identity: HitKey?
    /// Les comptes par terme, pour l'en-tête de l'aperçu (PN1).
    var onCounts: (OccurrenceTally.Counts) -> Void = { _ in }

    /// Surlignage calculé une fois par (page, jeu de termes), et non à chaque
    /// évaluation de `body` : celui-ci est réévalué pour un simple survol de
    /// bouton, alors qu'une page dense coûte jusqu'à 120 000 caractères de
    /// parcours PAR TERME.
    @State private var rendered: TextHighlighter.Result?

    private var renderKey: String {
        page.renderKey(identity: identity, terms: terms)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let rendered, page.fromOCR || rendered.truncated || rendered.capped {
                TextPreviewNotices(fromOCR: page.fromOCR,
                                   truncated: rendered.truncated,
                                   capped: rendered.capped)
            }
            ScrollView {
                // Les coupures invisibles valent AUSSI pour le premier rendu,
                // avant que le surlignage ait rendu la main : c'est lui que
                // CoreText met en page d'abord (EX2).
                Text(rendered?.text ?? AttributedString(TextSoftBreaks.insert(page.text)))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(page.monospaced ? 1 : 3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    // Le surlignage est un `AttributedString` à fonds colorés :
                    // le libellé rend le texte NU, sans quoi la mise en
                    // évidence ne se lit pas — elle ne s'entend pas non plus.
                    .accessibilityLabel(spokenText)
                    .accessibilityIdentifier("preview.text")
                if !page.images.isEmpty {
                    CardImagesView(urls: page.images)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .task(id: renderKey) {
            let shown = TextSoftBreaks.insert(page.text)
            rendered = TextHighlighter.attributed(shown, terms: terms,
                                                  monospaced: page.monospaced)
            // Sur le texte AFFICHÉ — coupures invisibles comprises, tronqué
            // comme le surlignage : un compte qui inclurait la partie coupée
            // annoncerait des mots qu'on ne peut pas trouver à l'écran.
            onCounts(OccurrenceTally.counts(
                in: rendered?.truncated == true
                    ? String(shown.prefix(TextHighlighter.maxCharacters)) : shown,
                terms: terms))
        }
    }

    /// Le texte réellement affiché, sans les attributs : c'est lui qu'il faut
    /// lire, y compris quand le rendu a tronqué la page (le bandeau le dit).
    private var spokenText: String {
        String((rendered?.text ?? AttributedString(page.text)).characters)
    }
}

/// Tout ce que l'aperçu doit AVOUER : d'où vient ce texte, et ce qu'il ne
/// montre pas. Une troncature muette est le défaut reproché au surlignage
/// du PDF (audit A12) ; on ne le reproduit pas ici.
///
/// Sans `fixedSize(horizontal: false, vertical: true)` : hors du `ScrollView`,
/// il faisait mesurer la colonne de l'aperçu à largeur nulle, et une page
/// scannée en mode Texte poussait le contenu de la fenêtre sous le titre
/// (`ColumnOverflowTests`, 24/09/2026). Vue à part pour que ce test la mette en
/// page sans attendre le surlignage, qui décide de son affichage.
struct TextPreviewNotices: View {
    let fromOCR: Bool
    let truncated: Bool
    let capped: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if fromOCR {
                Label("text read from the scan: it may differ from what the page shows",
                      systemImage: "text.viewfinder")
                    .foregroundStyle(Color.teal)
            }
            if truncated {
                Label("page truncated to \(Format.integer(TextHighlighter.maxCharacters)) characters for display; the whole text stays searchable",
                      systemImage: "scissors")
                    .foregroundStyle(.secondary)
            }
            if capped {
                Label("first \(Format.integer(TextHighlighter.maxOccurrences)) occurrences highlighted",
                      systemImage: "highlighter")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
        // Les trois aveux sont posés sur des `Label` à pictogramme, dans des
        // teintes qui portent du sens : combinés en un seul élément parlé, ils
        // se lisent d'une traite avant le texte de la page.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("preview.text.notices")
    }
}

/// Les images d'une carte Anki, sous son texte (lot AN1).
///
/// Chargées hors du fil principal, une fois par jeu d'images : une capture de
/// page de cours pèse quelques centaines de kilo-octets, et `body` est
/// réévalué au moindre survol. Une image illisible (effacée dans Anki, format
/// que macOS ne sait pas dessiner) est simplement absente.
private struct CardImagesView: View {
    let urls: [URL]
    @State private var images: [LoadedImage] = []

    private struct LoadedImage: Identifiable {
        let id: URL
        let image: NSImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(images) { item in
                Image(nsImage: item.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: min(item.image.size.width, 720), alignment: .leading)
                    .accessibilityLabel(Text("Picture from the card"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .task(id: urls) {
            let loaded = await Task.detached(priority: .userInitiated) {
                urls.map { url in (url, try? Data(contentsOf: url)) }
            }.value
            images = loaded.compactMap { url, data in
                data.flatMap(NSImage.init(data:)).map { LoadedImage(id: url, image: $0) }
            }
        }
    }
}
