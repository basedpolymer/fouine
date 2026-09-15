// AccessibilityText.swift — ce que VoiceOver dit des lignes (audit U3).
// Propriété : A-App. SPEC §5.6.
//
// L'audit relevait zéro `accessibility*` dans l'application : les cinq familles
// de lignes (racines, facettes, en-têtes de groupe, résultats, historique) sont
// bâties en `Button(.plain)` avec un pictogramme et un fragment de texte, et
// VoiceOver annonçait donc « bouton » suivi d'un extrait tronqué — sans le nom
// du document, sans la page, sans dire d'où venait le résultat. Les `.help()`
// ne comblent rien : VoiceOver lit le HINT, jamais l'infobulle.
//
// Pourquoi des fonctions pures dans un fichier à part : un libellé parlé est de
// la logique, pas de la mise en page — il se teste (`AccessibilityTextTests`),
// et le tester est le seul moyen de vérifier ces phrases sans lancer VoiceOver.
//
// Deux règles tenues ici :
//   · les nombres parlés sont NUS. `Format.integer` groupe les milliers avec une
//     espace fine insécable (U+202F) ; « 1 203 » se prononce alors « un » puis
//     « deux cent trois ». L'affichage garde l'espace fine, le libellé non ;
//   · rien n'est inventé. Une racine ne connaît pas son nombre de documents
//     (`RootStatus` ne le porte pas) : son libellé dit son état, pas un compte
//     qui n'existe nulle part.
//
// ACCORD (palier 3.2, audit U1). `quantity(n, singulier, pluriel)` appliquait
// la règle FRANÇAISE en dur (« 0 et 1 au singulier ») ; l'anglais met 0 au
// pluriel. Les comptes passent donc par des clés à VARIATIONS de pluriel du
// catalogue, où chaque langue apporte sa propre règle — CLDR range bien 0 et 1
// dans « one » en français, l'ancien comportement est reproduit à l'identique.

import Foundation
import FouineCore

enum AccessibilityText {

    // MARK: - Nombres accordés

    /// Retire les séparateurs de milliers ESPACES d'un nombre parlé.
    ///
    /// Un entier interpolé dans un `String(localized:)` est formaté selon la
    /// locale : le français y met une espace fine insécable (U+202F), et
    /// « 1 203 » se prononce alors « un » puis « deux cent trois » (audit U3).
    /// C'est le séparateur, pas le nombre, qu'il faut retirer — et seulement
    /// s'il s'agit d'une espace : l'anglais groupe avec une virgule, que la
    /// synthèse vocale lit très bien.
    ///
    /// Pourquoi pas `format: .number.grouping(.never)` : cette interpolation-là
    /// fabrique une clé en `%@` et non en `%lld`, ce qui fait perdre la
    /// VARIATION DE PLURIEL (vérifié — « 1 pages »). L'accord vaut mieux qu'un
    /// détour élégant.
    /// Retire le séparateur de milliers QUELLE QUE SOIT LA LOCALE : l'espace
    /// fine (fr), la virgule (en — c'est ce que la CI, en `en_US`, a
    /// rendu : « 1,203 documents »), le point (de), l'apostrophe (fr_CH).
    /// Seul un séparateur ENTRE DEUX CHIFFRES est retiré : la ponctuation de
    /// la phrase reste.
    private static func bare(_ text: String) -> String {
        text.replacingOccurrences(
            of: "(?<=[0-9])[\u{202F}\u{00A0}\u{2009},.'’](?=[0-9])",
            with: "", options: .regularExpression)
    }

    /// Les comptes parlés. Un par unité : le catalogue ne peut pas accorder un
    /// nom qu'on lui passerait en paramètre.
    static func items(_ n: Int) -> String {
        bare(String(localized: "\(n) items"))
    }
    static func pages(_ n: Int) -> String {
        bare(String(localized: "\(n) pages"))
    }
    static func documents(_ n: Int) -> String {
        bare(String(localized: "\(n) documents"))
    }
    static func seconds(_ n: Int) -> String {
        bare(String(localized: "\(n) seconds"))
    }
    static func indexedPages(_ n: Int) -> String {
        bare(String(localized: "\(n) indexed pages"))
    }
    static func waitingPages(_ n: Int) -> String {
        bare(String(localized: "\(n) pages waiting"))
    }
    static func loadedPages(_ n: Int, unit: PageUnit = .page) -> String {
        unit == .card ? bare(String(localized: "\(n) loaded cards"))
                      : bare(String(localized: "\(n) loaded pages"))
    }
    static func matchedPages(_ n: Int, unit: PageUnit = .page) -> String {
        unit == .card ? bare(String(localized: "\(n) matched cards"))
                      : bare(String(localized: "\(n) matched pages"))
    }
    static func foundPages(_ n: Int) -> String {
        bare(String(localized: "\(n) pages found"))
    }
    static func mergedPages(_ n: Int) -> String {
        bare(String(localized: "\(n) merged pages"))
    }
    static func semanticOnlyPages(_ n: Int) -> String {
        bare(String(localized: "\(n) pages found by meaning alone"))
    }

    // `agentStatus(_:)` a été retiré (UX-03) : le bloc de progression de
    // l'agent n'existe plus dans la barre latérale. Ce que VoiceOver dit de
    // l'index se lit maintenant dans `indexCard(_:)` ci-dessous, qui part de
    // l'état unique et non de l'enregistrement brut de l'agent.

    // MARK: - Carte « Index » (UX-03)

    /// Ce que VoiceOver dit de la carte, en UNE phrase : l'état, puis sa
    /// précision — exactement ce que la carte montre (IX2). Lus séparément,
    /// ses textes font des annonces décousues.
    ///
    /// Plus de nom de document ni de « 1 203 / 4 000 pages » : la carte ne les
    /// montre plus, et les annoncer à VoiceOver seul lui ferait lire une autre
    /// carte que celle qu'on voit. Ils sont dans la fenêtre « Votre index »
    /// (`progressLine(_:)`).
    static func indexCard(_ summary: IndexCardSummary) -> String {
        var parts = [summary.headline]
        if let detail = summary.detail { parts.append(detail) }
        return parts.joined(separator: ", ")
    }

    /// La ligne d'avancement de la fenêtre « Votre index », en nombres NUS :
    /// « 1 203 / 4 000 » groupé à l'espace fine se prononce « un, deux cent
    /// trois ».
    static func progressLine(_ progress: IndexProgress) -> String {
        bare(IndexStatusText.progressLine(progress))
    }

    /// Une phrase qui porte un compte (« 3 157 pages scannées… »), séparateurs
    /// de milliers retirés, pour la même raison.
    static func spokenCount(_ text: String) -> String {
        bare(text)
    }

    // MARK: - Modèle sémantique (audit D6)

    /// Ce que VoiceOver dit d'un transfert en cours.
    ///
    /// La barre de progression annonce seule un pourcentage sans unité ; ce qui
    /// manque, et qui compte quand on attend 220 Mo, c'est l'ÉTAPE (le
    /// téléchargement n'est pas la décompression) et les octets déjà là.
    ///
    /// Le pourcentage passe par `Format.percent` et non par un « % » écrit dans
    /// la clé : un `%` littéral dans une clé de String Catalog est un
    /// spécificateur de format, et l'espace qui le précède en français vient de
    /// la locale, pas de la traduction.
    static func modelTransfer(phase: String, fraction: Double?,
                              received: Int64, expected: Int64) -> String {
        guard let fraction, expected > 0 else { return phase }
        return String(localized: "\(phase), \(Format.percent(fraction)) — \(Format.bytes(Int(received))) of \(Format.bytes(Int(expected)))")
    }

    /// Ce que VoiceOver dit du modèle installé : la ligne visible est un
    /// numéro de révision et une taille, que rien ne rattache au modèle.
    static func installedModel(id: String, revision: Int, bytes: Int64) -> String {
        String(localized: "\(id), revision \(String(revision)), \(Format.bytes(Int(bytes))) on disk")
    }

    // MARK: - Racines (barre latérale)

    static func rootState(_ root: RootStatus) -> String {
        if !root.mounted { return String(localized: "disk not plugged in") }
        if !root.record.enabled { return String(localized: "paused") }
        if !root.readable { return String(localized: "read denied") }
        return String(localized: "active")
    }

    static func rootLabel(_ root: RootStatus) -> String {
        String(localized: "Folder \(root.label), \(rootState(root))")
    }

    /// Reprend ce que dit le `.help()` de la ligne — chemin ou motif du refus —
    /// précédé de l'effet du clic, que rien d'autre n'annonce.
    static func rootHint(_ root: RootStatus, filtering: Bool) -> String {
        let action = filtering
            ? String(localized: "Removes the filter on this folder.")
            : String(localized: "Filters results on this folder.")
        // Une phrase localisée suivie d'une donnée : rien à traduire dans le
        // collage lui-même, et une clé « %@ %@ » n'aurait rien voulu dire.
        if let reason = root.reason { return "\(action) \(reason)" }
        if let path = root.absolutePath { return "\(action) \(path)" }
        return action
    }

    // MARK: - Facettes

    /// Nom parlé d'une famille de facettes, au singulier de la chose filtrée.
    static func facetSection(_ key: FacetKey) -> String {
        switch key {
        case .folder: return String(localized: "folders")
        case .ext:    return String(localized: "file types")
        case .year:   return String(localized: "years")
        case .source: return String(localized: "text origin")
        case .lang:   return String(localized: "languages")
        // La date que le document PORTE, par opposition à « years », qui parle
        // de la date du fichier (schéma v9, constat PR-07).
        case .docYear: return String(localized: "document dates")
        }
    }

    static func facetLabel(_ value: String) -> String {
        String(localized: "Facet \(value)")
    }

    /// Les comptes de facette sont des PAGES (`GRDBStore.facets` regroupe par
    /// doc_id + page), pas des documents.
    static func facetValue(pages n: Int) -> String { pages(n) }

    static func facetHint(_ key: FacetKey, selected: Bool) -> String {
        selected
            ? String(localized: "Removes this value from the \(facetSection(key)) filter.")
            : String(localized: "Adds this value to the \(facetSection(key)) filter.")
    }

    // MARK: - En-tête de groupe de résultats

    static func groupLabel(fileName: String, path: String) -> String {
        String(localized: "Document \(fileName), \(path)")
    }

    /// Le même arbitrage honnête que `pageCountLabel` (audit A12) : « chargées »
    /// tant que le comptage différé n'a pas répondu, « touchées » ensuite.
    static func groupValue(loaded: Int, matched: Int?,
                           unit: PageUnit = .page) -> String {
        guard let matched else { return loadedPages(loaded, unit: unit) }
        if matched > loaded {
            return String(localized: "\(loadedPages(loaded, unit: unit)) of \(matchedPages(matched, unit: unit))")
        }
        return matchedPages(loaded, unit: unit)
    }

    static func groupHint(collapsed: Bool) -> String {
        collapsed
            ? String(localized: "Expands the pages found in this document.")
            : String(localized: "Collapses the pages found in this document.")
    }

    /// Le compte de pages est un GESTE quand la liste n'en montre qu'une part
    /// (PERSP-Q4). Sans cette phrase, VoiceOver annonce un bouton qui ne dit
    /// pas où il mène : il faut savoir que le clic RESTREINT la recherche.
    static let seeAllPagesHint = String(localized: "Restricts the search to this document and shows every page found in it.")

    // MARK: - Lignes de résultat

    /// Par quel canal cette page est arrivée. L'insigne « ≈ » et le pictogramme
    /// de provenance sont, sans cette phrase, purement visuels (audit U3).
    static func channel(semanticOnly: Bool, fuzzyDistance: Int) -> String {
        if semanticOnly {
            return String(localized: "approximate result, found by meaning")
        }
        if fuzzyDistance > 0 {
            // « distance 2 » ne se lit pas à haute voix (lot J2) : on dit
            // combien de lettres séparent le mot trouvé du mot cherché.
            return bare(String(localized: "approximate result, close spelling, \(fuzzyDistance) letters apart"))
        }
        return String(localized: "found by exact search")
    }

    /// D'où vient la couche texte de la page (`page_src.engine`).
    ///
    /// LA MÊME PHRASE QU'À L'ÉCRAN (AP-03) : la facette, l'en-tête de l'aperçu
    /// et le pictogramme d'une ligne passent tous par `LanguageNames`, et ce
    /// que VoiceOver dit ne doit pas être une cinquième formulation.
    static func textSource(_ source: PageSource, engine: OCREngineID) -> String {
        LanguageNames.sourceLabel(source, engine: engine)
    }

    /// Une page sémantique pure n'a pas de provenance connue sans un balayage de
    /// `page_src` : on ne l'annonce pas plutôt que de l'inventer — c'est la même
    /// raison qui fait afficher l'insigne « ≈ » à la place du pictogramme.
    ///
    /// `timestamp` est le moment d'un passage ENTENDU (lot PV1) : sur une page
    /// de son ou de vidéo, « page 3 » ne dit rien — « à 12:40 » situe.
    static func hitLabel(fileName: String, page: Int, source: PageSource,
                         engine: OCREngineID, semanticOnly: Bool,
                         fuzzyDistance: Int, timestamp: String? = nil,
                         unit: PageUnit = .page) -> String {
        var parts = [bare(Citation.label(fileName: fileName, page: page, unit: unit))]
        if let timestamp { parts.append(bare(String(localized: "at \(timestamp)"))) }
        if !semanticOnly { parts.append(textSource(source, engine: engine)) }
        parts.append(channel(semanticOnly: semanticOnly,
                             fuzzyDistance: fuzzyDistance))
        return parts.joined(separator: ", ")
    }

    /// Extrait débarrassé des marqueurs « » du snippet FTS5 : lus tels quels,
    /// ils font annoncer un guillemet à chaque occurrence trouvée. Les « … » de
    /// coupure restent — ils disent quelque chose.
    static func snippetValue(_ snippet: String) -> String {
        let plain = SnippetParser.segments(snippet)
            .map(\.text)
            .joined()
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? String(localized: "empty snippet")
                             : String(localized: "snippet: \(plain)")
    }

    /// Ce que VoiceOver dit du CONTENU d'une ligne : l'extrait, puis — sur la
    /// ligne sélectionnée seulement — la phrase « pourquoi ce résultat »
    /// (lot U1, R-06). Elle est en VALEUR et non en annonce séparée : lue à
    /// part, elle serait coupée de l'extrait qu'elle explique.
    ///
    /// Deux phrases déjà localisées mises bout à bout : rien à traduire dans le
    /// collage lui-même, et une clé « %@ %@ » n'aurait rien voulu dire (même
    /// arbitrage que `rootHint`).
    static func hitValue(snippet: String, why: String?) -> String {
        guard let why, !why.isEmpty else { return snippetValue(snippet) }
        return "\(snippetValue(snippet)) \(why)"
    }

    // MARK: - Historique

    static func historyLabel(_ entry: String) -> String {
        String(localized: "Recent query: \(entry)")
    }

    /// Une recherche enregistrée se dit comme telle : sans ce mot, VoiceOver
    /// ne lirait qu'un nom au milieu d'une barre latérale qui en porte déjà
    /// beaucoup (dossiers, langues, types de fichiers).
    static func savedSearchLabel(_ name: String) -> String {
        String(localized: "\(name), saved search")
    }

    // MARK: - Compteurs affichés

    /// La ligne d'état affiche « 1 203 page(s) dans 12 document(s) » avec
    /// l'espace fine insécable : ce libellé la redit en nombres nus.
    static func resultCounts(pages n: Int, docs: Int, hybrid: Bool) -> String {
        let p = hybrid ? mergedPages(n) : foundPages(n)
        return String(localized: "\(p) in \(documents(docs))")
    }
}
