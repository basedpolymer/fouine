// SearchAdvice.swift — ce que le moteur a le droit de CONSEILLER à l'appelant.
// Propriété : A-Core. Audit A1m-08, idée 1.
//
// CES PHRASES SONT ÉCRITES ICI, en anglais, parce que trois surfaces les
// rendent — la sortie texte de `fouine search`, le champ `note` de
// `fouine_search` (MCP) et, TRADUITES, la ligne d'état de l'application. Trois
// copies d'une même phrase avaient déjà commencé à diverger ailleurs dans ce
// dépôt (§4.3).
//
// POURQUOI CE CONSEIL PLUTÔT QU'UNE OPTIMISATION. Mesuré le 04/09/2026 sur la
// base de production (390 114 pages), chaque ligne coup sur coup :
//
//   · `counts()` du mot « the » (borné au seuil)                       0,20 s
//   · parcours nu de sa doclist (343 982 pages)                        0,36 s
//   · `ORDER BY bm25 LIMIT 50` sur ces 343 982 pages                 9 à 14 s
//   · la même chose `ORDER BY rowid`                                   0,03 s
//   · `fouine search 'the' --limit 3`, binaire release                 7,08 s
//
// Le coût n'est ni la doclist ni `snippet()` : c'est l'évaluation de `bm25()`
// sur toutes les lignes appariées, plus le tri. Le borner rendrait un classement
// APPROCHÉ — un « meilleur résultat » qui n'en est pas un — pour une requête qui
// n'est de toute façon pas utile : un mot-outil seul ne cherche rien. Les vingt
// mots les plus fréquents du corpus sont des mots-outils anglais présents sur 58
// à 92 % des pages. On ORIENTE donc l'utilisateur plutôt que d'accélérer une
// requête qu'il ne voulait pas poser, et le classement reste exact (A1m-08).

import Foundation

public enum SearchAdvice {

    /// Le conseil qui accompagne un total BORNÉ (`SearchResults.totalsApproximate`).
    ///
    /// Le seuil `Schema.approximateCountThreshold` « sait » déjà que la requête
    /// est pathologique ; jusqu'ici il n'en tirait rien d'autre qu'un `>` devant
    /// deux nombres. Le deuxième mot d'une requête est ce qui répare le
    /// problème pour de bon : FTS5 intersecte, et le tri ne porte plus que sur
    /// l'intersection.
    ///
    /// ANGLAIS, comme tout ce que la CLI et le serveur MCP impriment
    /// (`docs/i18n.md`) ; l'application a sa propre phrase, traduite et sans
    /// jargon.
    public static let veryCommonWord =
        "very common word — add a second word to narrow the search"

    /// Le conseil qui accompagne un REPLI EN FLOU : la recherche exacte n'a rien
    /// rendu, Fouine a rejoué la requête en tolérant les fautes sur tout l'index
    /// (`SearchResults.fuzzyFallback`, lot MP1, C2-08).
    ///
    /// POURQUOI L'ANNONCER PLUTÔT QUE DE LE FAIRE EN SILENCE. Mesuré le
    /// 09/09/2026 sur la base de production : `Villeurbane` rendait zéro page
    /// alors que trois documents NATIFS portent « Villeurbanne » — la portée
    /// `ocr` du flou ne couvrait que les pages scannées, c'est-à-dire les fautes
    /// de la MACHINE, jamais celles de la requête. Le repli répare cela, mais il
    /// change la règle du jeu : ce qui est affiché n'est plus ce qui a été
    /// demandé, et le taire ferait lire « Villeurbanne » comme une réponse à
    /// « Villeurbane ».
    ///
    /// ANGLAIS, comme tout ce que la CLI et le serveur MCP impriment ;
    /// l'application a sa propre phrase, traduite et sans jargon.
    public static let fuzzyFallback =
        "No exact match — showing close spellings from every document."

    /// Le conseil qui accompagne une EXPANSION floue ordinaire (lot MC1,
    /// PM-13) : des résultats portent une orthographe proche du mot tapé, sans
    /// que la recherche ait eu à se replier.
    ///
    /// DEUX SITUATIONS, DEUX PHRASES. Le repli (`fuzzyFallback`) dit « rien
    /// d'exact, voici les orthographes proches » ; ici, la recherche a trouvé
    /// quelque chose, et une partie seulement de ce qu'elle rend est approché.
    /// Le taire revenait à laisser lire « Kenvue » dans onze pages qui portent
    /// « kene » et « cevue ».
    ///
    /// ANGLAIS, comme tout ce que la CLI et le serveur MCP impriment.
    public static let fuzzyExpanded =
        "some results carry a close spelling of your word, not the word itself "
        + "— see why.found"

    /// Le conseil qui accompagne un QUORUM : moins de dix pages portaient TOUS
    /// les mots, et la recherche montre aussi celles qui en portent la plupart
    /// (`SearchResults.quorum`, lot RK2, RK-04).
    ///
    /// POURQUOI L'ANNONCER. Le banc jugé du 09/09/2026 l'a établi : `comment
    /// mesurer la chaleur degagee par une reaction` rend 0 page, `la chaleur
    /// degagee par une reaction` en rend 10 — la bascule tient aux mots-outils,
    /// pas au sens. Relâcher le ET répare la requête, mais change la règle :
    /// une page qui suit la tête stricte ne porte PAS tous les mots demandés, et
    /// le taire ferait lire une réponse partielle comme une réponse complète.
    ///
    /// ANGLAIS, comme tout ce que la CLI et le serveur MCP impriment ;
    /// l'application a sa propre phrase, traduite et sans jargon.
    public static let quorum =
        "Few pages carry every word — also showing pages that carry most of them."
}
