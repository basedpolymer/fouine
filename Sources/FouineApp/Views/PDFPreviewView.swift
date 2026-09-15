// PDFPreviewView.swift — PDFView + surlignage (SPEC §5.6). Propriété : A-App.
//
// Deux régimes, exclusifs, par page :
//   · page à couche texte NATIVE : `PDFPage.selection(for:)` sur les occurrences
//     trouvées dans `PDFPage.string`, `PDFSelection.setColor(_:)` — UNE COULEUR
//     PAR TERME de la requête, comme FoxTrot ;
//   · page OCRisée (page_src.src != 0) : la couche texte n'existe pas dans le
//     fichier — les boîtes `ocr_layout` sont dénormalisées vers le mediaBox
//     (OCRGeometry, rotation comprise) et posées en `PDFAnnotation(.highlight)`.
//     Les annotations vivent EN MÉMOIRE seulement : retirées à chaque changement
//     de sélection, jamais écrites dans le fichier (§1 : non-destructivité).
//
// Les deux régimes alimentent le MÊME curseur d'occurrences (PN1,
// `OccurrenceCursor`) : l'en-tête dit « 3 / 27 » et ⌘G / ⇧⌘G y passent.

import SwiftUI
import AppKit
import PDFKit
import FouineCore

struct PDFPreviewView: NSViewRepresentable {
    let box: PDFDocumentBox
    let page: Int                    // 1-indexé
    let terms: [HighlightTerm]
    /// nil = page native (surlignage par sélections) ; sinon boîtes OCR.
    let ocrLines: [OCRLine]?
    /// Le plafond de surlignages a-t-il mordu sur cette page ? Remonté à la vue
    /// pour être DIT (audit A12) — voir `Coordinator.highlightsPerTerm`.
    @Binding var highlightCapReached: Bool
    /// Reçoit le curseur d'occurrences de la page, et prête au coordinateur le
    /// geste « aller à » (PN1).
    let preview: PreviewModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .windowBackgroundColor
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        let coordinator = context.coordinator
        coordinator.preview = preview
        preview.occurrenceJump = { [weak coordinator, weak view] occurrence in
            guard let coordinator, let view else { return }
            coordinator.goTo(occurrence, in: view)
        }
        let outcome = coordinator.apply(to: view, box: box, page: page,
                                        terms: terms, ocrLines: ocrLines)
        // `PDFView` expose sa propre couche texte à VoiceOver, mais la vue
        // elle-même n'a pas de nom : le panneau se lisait « groupe » (audit
        // U3). Le numéro de page suit la sélection.
        view.setAccessibilityLabel(
            String(localized: "PDF preview, page \(page)"))
        // Pendant `updateNSView`, on est en plein cycle de mise à jour de
        // SwiftUI : écrire l'état tout de suite déclencherait un
        // « Modifying state during view update ». On le repousse d'un tour.
        if let outcome {
            let preview = preview
            DispatchQueue.main.async {
                if outcome.capped != highlightCapReached {
                    highlightCapReached = outcome.capped
                }
                preview.resetOccurrences(outcome.cursor,
                                         capped: outcome.cappedTerms)
            }
        }
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.removeAnnotations()
        // Le geste retenait cette vue : sans elle, les boutons de l'en-tête
        // n'ont plus rien à faire défiler.
        coordinator.preview?.occurrenceJump = nil
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        /// Occurrences surlignées PAR TERME sur une page.
        ///
        /// Le plafond existe parce que `PDFPage.selection(for:)` coûte cher et
        /// qu'un mot vide surligné 4 000 fois fige l'affichage. Il était
        /// SILENCIEUX (audit A12) : la page semblait simplement ne plus rien
        /// contenir après la 400ᵉ occurrence. Il est maintenant annoncé.
        static let highlightsPerTerm = 400

        private var appliedDocument: PDFDocument?
        private var appliedPage = 0
        private var appliedStamp = ""
        /// Annotations posées par NOUS, à retirer au prochain changement.
        private var annotations: [(page: PDFPage, annotation: PDFAnnotation)] = []
        weak var preview: PreviewModel?

        /// Où va chaque occurrence du curseur, rangée sous son `id`.
        private enum Target {
            case selection(PDFSelection)
            case box(page: PDFPage, bounds: CGRect)
        }
        private var targets: [Target] = []

        struct Outcome {
            /// Les termes (place dans `terms`) sur lesquels le plafond de
            /// surlignages a mordu : leur pastille dit « 400+ », pas « 400 ».
            let cappedTerms: Set<Int>
            let cursor: OccurrenceCursor
            var capped: Bool { !cappedTerms.isEmpty }
        }

        /// - Returns: le plafond et le curseur réévalués, `nil` si rien n'a
        ///   changé et qu'il n'y a rien à annoncer.
        @discardableResult
        func apply(to view: PDFView, box: PDFDocumentBox, page: Int,
                   terms: [HighlightTerm], ocrLines: [OCRLine]?) -> Outcome? {
            if view.document !== box.document {
                removeAnnotations()
                view.document = box.document
                appliedDocument = box.document
                appliedPage = 0
                appliedStamp = ""
            }

            let stamp = terms.map(\.id).joined(separator: "|")
                + "§" + (ocrLines.map { "ocr\($0.count)" } ?? "native")
            guard appliedPage != page || appliedStamp != stamp else { return nil }
            guard page >= 1, page <= box.document.pageCount,
                  let pdfPage = box.document.page(at: page - 1) else { return nil }

            removeAnnotations()
            view.highlightedSelections = nil
            targets = []
            appliedPage = page
            appliedStamp = stamp

            var occurrences: [OccurrenceCursor.Occurrence] = []
            var cappedTerms: Set<Int> = []
            if let lines = ocrLines, !lines.isEmpty {
                occurrences = annotate(page: pdfPage, lines: lines, terms: terms)
            } else if !terms.isEmpty {
                let outcome = highlightNative(view: view, page: pdfPage,
                                              terms: terms)
                occurrences = outcome.occurrences
                cappedTerms = outcome.cappedTerms
            }
            let cursor = OccurrenceCursor(occurrences, rotation: pdfPage.rotation)

            // Aller à la page du hit, puis à la première occurrence DANS
            // L'ORDRE DE LECTURE — celle que l'en-tête annonce « 1 / 27 ».
            // Avant PN1, c'était la première du premier terme, où qu'elle soit.
            view.go(to: PDFDestination(
                page: pdfPage,
                at: CGPoint(x: kPDFDestinationUnspecifiedValue,
                            y: kPDFDestinationUnspecifiedValue)))
            if let first = cursor.current { scroll(to: first, in: view) }
            return Outcome(cappedTerms: cappedTerms, cursor: cursor)
        }

        /// Le geste de ⌘G / ⇧⌘G. La sélection native devient en plus la
        /// sélection COURANTE, animée : parmi vingt surlignages de la même
        /// couleur, c'est ce qui dit à l'œil lequel est « 3 / 27 ».
        func goTo(_ occurrence: OccurrenceCursor.Occurrence, in view: PDFView) {
            guard targets.indices.contains(occurrence.id) else { return }
            scroll(to: occurrence, in: view)
            if case .selection(let selection) = targets[occurrence.id] {
                view.setCurrentSelection(selection, animate: true)
            }
        }

        private func scroll(to occurrence: OccurrenceCursor.Occurrence,
                            in view: PDFView) {
            guard targets.indices.contains(occurrence.id) else { return }
            switch targets[occurrence.id] {
            case .selection(let selection):
                view.go(to: selection)
            case .box(let page, let bounds):
                // Le point d'une destination est posé EN HAUT de la vue : sans
                // marge, la ligne trouvée collerait au bord supérieur.
                let top = min(bounds.maxY + Self.boxTopMargin,
                              page.bounds(for: .mediaBox).maxY)
                view.go(to: PDFDestination(page: page,
                                           at: CGPoint(x: bounds.minX, y: top)))
            }
        }

        /// En points de page : de quoi lire la ligne au-dessus de celle trouvée.
        private static let boxTopMargin: CGFloat = 36

        // MARK: Page native — sélections colorées

        /// Cherche chaque terme dans `PDFPage.string` (insensible à la casse et
        /// aux accents, comme le tokenizer FTS5) et pose des sélections colorées.
        private func highlightNative(view: PDFView, page: PDFPage,
                                     terms: [HighlightTerm])
            -> (occurrences: [OccurrenceCursor.Occurrence], cappedTerms: Set<Int>) {
            guard let text = page.string, !text.isEmpty else { return ([], []) }
            var selections: [PDFSelection] = []
            var marks: [OccurrenceCursor.Occurrence] = []
            var cappedTerms: Set<Int> = []

            for (termIndex, term) in terms.enumerated() {
                var searchRange = text.startIndex..<text.endIndex
                var occurrences = 0
                while let found = text.range(of: term.text,
                                             options: [.caseInsensitive,
                                                       .diacriticInsensitive],
                                             range: searchRange) {
                    // FRONTIÈRES DE JETON (audit A2-17) : la recherche compte
                    // des jetons FTS5, ce surlignage cherchait des
                    // SOUS-CHAÎNES. Un terme de trois lettres marquait donc
                    // l'intérieur des mots — « or » dans « sort », « pour »,
                    // « corps » —, ce que le plafond de 400 occurrences par
                    // terme essayait de contenir. Un préfixe (`spectro*`), lui,
                    // a le droit de mordre sur la suite du mot.
                    guard TokenBoundary.startsToken(text, at: found.lowerBound),
                          term.kind == .prefix
                            || TokenBoundary.endsToken(text, at: found.upperBound)
                    else {
                        searchRange = text.index(after: found.lowerBound)..<text.endIndex
                        continue
                    }
                    guard occurrences < Self.highlightsPerTerm else {
                        // Le plafond a mordu ET il reste des occurrences : la
                        // distinction compte, un terme trouvé exactement 400
                        // fois est entièrement surligné (audit A12).
                        cappedTerms.insert(termIndex)
                        break
                    }
                    let nsRange = NSRange(found, in: text)
                    if let selection = page.selection(for: nsRange) {
                        selection.color = term.nsColor.withAlphaComponent(0.55)
                        selections.append(selection)
                        marks.append(.init(term: term.text,
                                           termIndex: termIndex,
                                           rect: selection.bounds(for: page),
                                           id: targets.count))
                        targets.append(.selection(selection))
                    }
                    occurrences += 1
                    guard found.upperBound < text.endIndex else { break }
                    searchRange = found.upperBound..<text.endIndex
                }
            }
            view.highlightedSelections = selections.isEmpty ? nil : selections
            return (marks, cappedTerms)
        }

        // MARK: Page OCRisée — annotations en mémoire

        /// Une occurrence par LIGNE reconnue : la boîte OCR est celle de la
        /// ligne entière, et elle revient au premier terme qu'elle contient.
        private func annotate(page: PDFPage, lines: [OCRLine],
                              terms: [HighlightTerm]) -> [OccurrenceCursor.Occurrence] {
            guard !terms.isEmpty else { return [] }
            let mediaBox = page.bounds(for: .mediaBox)
            let rotation = page.rotation
            var occurrences: [OccurrenceCursor.Occurrence] = []

            for line in lines {
                guard let term = QueryTerms.matchInText(line.text, terms: terms),
                      let termIndex = terms.firstIndex(of: term)
                else { continue }
                let bounds = OCRGeometry.denormalize(line, mediaBox: mediaBox,
                                                     rotation: rotation)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight,
                                               withProperties: nil)
                annotation.color = term.nsColor.withAlphaComponent(0.45)
                // Quad points relatifs aux bounds : haut-gauche, haut-droit,
                // bas-gauche, bas-droit (ordre PDF).
                let w = bounds.width, h = bounds.height
                annotation.quadrilateralPoints = [
                    NSValue(point: NSPoint(x: 0, y: h)),
                    NSValue(point: NSPoint(x: w, y: h)),
                    NSValue(point: NSPoint(x: 0, y: 0)),
                    NSValue(point: NSPoint(x: w, y: 0)),
                ]
                page.addAnnotation(annotation)
                annotations.append((page, annotation))
                occurrences.append(.init(term: term.text, termIndex: termIndex,
                                         rect: bounds, id: targets.count))
                targets.append(.box(page: page, bounds: bounds))
            }
            return occurrences
        }

        /// N'écrit JAMAIS dans le fichier : les annotations ne vivent que dans le
        /// PDFDocument en mémoire, et sont retirées ici.
        func removeAnnotations() {
            for (page, annotation) in annotations {
                page.removeAnnotation(annotation)
            }
            annotations.removeAll()
        }
    }
}
