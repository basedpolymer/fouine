// Morphology.swift — singulier et pluriel d'un mot tapé, sans base et sans
// dictionnaire (SPEC §5.5.3, amendement du 05/09/2026, lot R1).
// Propriété : A-Core.
//
// LE CONSTAT, mesuré sur la base réelle le 05/09/2026 (404 103 pages) :
// `polymere` apparie 1 045 pages dans 108 documents, `polymeres` 1 219 pages
// dans 161 documents, et les deux ensemble 1 694 pages dans 192 documents. Le
// mot au singulier RATE donc 84 documents — près de la moitié de ceux qui
// parlent de polymères — parce que FTS5 `unicode61` ne connaît ni le pluriel ni
// le singulier, et parce que le flou (§5.5.2) ne s'applique par défaut qu'aux
// pages OCR, et seulement sous vingt pages exactes. `liaison` → +37 % de pages
// avec `liaisons`, `cristal` → +33 % avec `cristaux`, `catalyseur` → +29 %.
//
// LA RÉPONSE : à la requête, pas à l'index. Un vrai racineur (Snowball) exige
// de rebâtir `page_fts` (1,4 Go, des heures) et une dépendance C ; un mot tapé
// devient ici un groupe `(polymere OR polymeres)` que FTS5 évalue au même prix,
// et rien en base ne change. Ce sont des RÈGLES, pas un dictionnaire : elles
// produisent parfois une forme qui n'existe pas (`hess` → `hes`), ce qui ne
// coûte rien — un terme absent de l'index a une liste vide — et ne surligne
// rien non plus.
//
// CE QUE LES RÈGLES NE FONT PAS, à dessein : ni féminin, ni conjugaison, ni
// dérivation (`catalyseur` → `catalyse`). Le pluriel est la seule variation qui
// rate des DOCUMENTS entiers sur ce corpus ; le reste relève du préfixe
// (`catalys*`) ou du canal sémantique, et chaque règle de plus ajoute son
// bruit. Deux garde-fous de longueur, mesurés sur les pièges du français :
// on n'AJOUTE un s qu'à partir de quatre lettres (`ion` → `ions` échappe, mais
// `sel`, `gaz` aussi : rien de grave, ils se tapent au pluriel si besoin), et on
// n'en RETIRE un qu'à partir de cinq lettres — `mois`, `fois`, `pays`, `sens`,
// `bras`, `cas` sont des singuliers en -s dont la forme tronquée (`moi`, `foi`,
// `pay`, `sen`, `bra`) est un AUTRE mot, souvent fréquent ; le prix est que
// `lois` et `ions` ne trouvent pas leur singulier (ils se tapent au singulier).
// À cinq lettres, les mêmes pièges tiennent en une liste fermée (`temps`,
// `corps`, `cours`, `fonds` → `temp`, `corp`, `cour`, `fond`), et le seuil à
// six (lot R1) laissait `bases`, `ondes`, `types`, `zones`, `pages`, `notes`
// sans singulier alors que `base` trouvait `bases` — l'asymétrie relevée par
// l'audit du 05/09/2026 (AUDIT-R1 I3).
//
// DEUX MOTS TAPÉS QUI SE DÉCLINENT L'UN VERS L'AUTRE ne reçoivent pas la forme
// commune (AUDIT-R1 B1). `entropy entropie` donnait `(entropy OR entropies)
// AND (entropie OR entropies)`, que toute page ne portant QUE « entropies »
// satisfait : 77 pages devenaient 943, et six des dix premières ne portaient
// aucun des deux mots tapés. La règle : une forme qui est un autre mot tapé, ou
// une forme d'un autre mot tapé, est retirée des deux côtés — `variants(of:
// among:)`. C'est aussi ce qui fait de `polymere polymeres` un vrai ET.
//
// Les variantes se comparent REPLIÉES (sans accents, minuscules), comme le
// tokenizer de l'index : `Polymère` → `polymere` → `polymeres`. Le mot rendu
// est la forme repliée ; c'est celle que FTS5 cherche et celle que
// `HitExplanation` et le surlignage confrontent aux jetons de la page.

import Foundation

public enum Morphology {

    /// Longueur minimale (repliée) pour AJOUTER une marque de pluriel.
    public static let minLengthToPluralize = 4
    /// Longueur minimale (repliée) pour RETIRER une marque de pluriel.
    public static let minLengthToSingularize = 5
    /// Singuliers en -s d'au moins cinq lettres dont la troncature est un autre
    /// mot courant : ils ne perdent jamais leur s. Sous cinq lettres, la
    /// longueur seule protège (`mois`, `fois`, `pays`, `sens`, `bras`, `cas`).
    public static let singularsEndingInS: Set<String> = ["temps", "corps", "cours", "fonds"]

    /// Les autres formes du mot, repliées, SANS le mot lui-même, sans doublon,
    /// dans un ordre stable. Vide quand le mot est trop court ou n'a aucune
    /// forme à proposer (il finit par « z », il porte un chiffre…).
    public static func variants(of word: String) -> [String] {
        let w = fold(word)
        guard !w.isEmpty, w.allSatisfy({ $0.isLetter }) else { return [] }
        var out: [String] = []
        func add(_ form: String) {
            guard form != w, !form.isEmpty, !out.contains(form) else { return }
            out.append(form)
        }
        let n = w.count

        // Vers le pluriel. Un mot déjà en -s ne reçoit pas de s (il est le
        // pluriel, ou un singulier en -s) ; seul un radical en -ss, -x, -z,
        // -ch, -sh prend « es » (process → processes, box → boxes).
        if n >= minLengthToPluralize {
            if w.hasSuffix("al") {
                add(String(w.dropLast(2)) + "aux")          // metal → metaux
                add(w + "s")                                 // festival → festivals
            } else if w.hasSuffix("eau") || w.hasSuffix("au") || w.hasSuffix("eu") {
                add(w + "x")                                 // reseau → reseaux, noyau → noyaux
                add(w + "s")                                 // pneu → pneus
            } else if w.hasSuffix("y"),
                      let before = w.dropLast().last, !"aeiou".contains(before) {
                add(String(w.dropLast()) + "ies")            // energy → energies
                add(w + "s")
            } else if w.hasSuffix("aux") || w.hasSuffix("eux") || w.hasSuffix("oux")
                        || w.hasSuffix("ix") {
                // Déjà des pluriels français (`metaux`, `deux`, `taux`), ou
                // invariables (`prix`) : « metauxes » n'existe pas (AUDIT-R1 M2).
            } else if w.hasSuffix("ss") || w.hasSuffix("x") || w.hasSuffix("z")
                        || w.hasSuffix("ch") || w.hasSuffix("sh") {
                add(w + "es")                                // process → processes
            } else if !w.hasSuffix("s") {
                add(w + "s")                                 // acide → acides
            }
        }

        // Vers le singulier. Retirer le s est la règle ; « es » ne tombe en
        // entier que devant un radical en -s, -x, -z, -ch, -sh (processes →
        // process, boxes → box) — jamais « acides » → « acid ».
        if n >= minLengthToSingularize, !singularsEndingInS.contains(w) {
            if w.hasSuffix("aux") {
                add(String(w.dropLast(3)) + "al")            // metaux → metal
                add(String(w.dropLast(1)))                   // noyaux → noyau, reseaux → reseau
            } else if w.hasSuffix("ies") {
                add(String(w.dropLast(3)) + "y")             // energies → energy
                add(String(w.dropLast(1)))                   // energies → energie, series → serie
            } else if w.hasSuffix("s"), !w.hasSuffix("ss") {
                // « process », « stress » : un -ss final est un singulier.
                add(String(w.dropLast(1)))                   // liaisons → liaison, phases → phase
                if w.hasSuffix("es") {
                    let stem = String(w.dropLast(2))
                    if stem.hasSuffix("ss") || stem.hasSuffix("x") || stem.hasSuffix("z")
                        || stem.hasSuffix("ch") || stem.hasSuffix("sh") {
                        add(stem)                            // processes → process, boxes → box
                    }
                }
            } else if w.hasSuffix("eux") || w.hasSuffix("oux") {
                // Seuls les pluriels français en -eux/-oux perdent leur x
                // (`cheveux`, `milieux`, `genoux`) ; `complex`, `index`, `flux`,
                // `prix` n'ont pas de singulier à retrouver (AUDIT-R1 M2).
                add(String(w.dropLast(1)))                   // cheveux → cheveu
            }
        }
        return out
    }

    /// Les formes d'un mot PARMI les mots tapés : `variants(of:)` moins toute
    /// forme qui est un autre mot de la requête ou l'une de ses formes. Deux
    /// mots qui se déclinent l'un vers l'autre (`entropy entropie` → « entropies »)
    /// perdent tous deux la forme commune ; sans cela, une page qui ne porte que
    /// cette forme satisfaisait le ET des deux mots (AUDIT-R1 B1). Un mot tapé
    /// deux fois n'est pas « un autre mot ».
    public static func variants(of word: String, among words: [String]) -> [String] {
        let w = fold(word)
        let others = Set(words.map(fold)).subtracting([w])
        guard !others.isEmpty else { return variants(of: word) }
        var taken = others
        for other in others { taken.formUnion(variants(of: other)) }
        return variants(of: word).filter { !taken.contains($0) }
    }

    /// Le mot et ses formes : ce que FTS5 doit chercher, ce que l'affichage
    /// doit surligner. Le mot tapé vient en tête, replié. `among` : les autres
    /// mots tapés, pour la règle de `variants(of:among:)`.
    public static func forms(of word: String, among words: [String] = []) -> [String] {
        let w = fold(word)
        return w.isEmpty ? [] : [w] + variants(of: word, among: words)
    }

    /// Repliement d'accents et de casse, celui du tokenizer de l'index
    /// (`unicode61 remove_diacritics 2`) — le même que `HitExplanation.fold`
    /// et `TrigramExpander.normalize`, avec une locale fixe pour que le résultat
    /// ne dépende pas du Mac.
    public static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive],
                  locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Chaînes FTS5

    /// Les mots NUS d'une chaîne FTS5 déjà normalisée : hors guillemets, hors
    /// `NEAR(…)`, sans les opérateurs ni les préfixes `mot*`. C'est exactement
    /// l'ensemble que `GRDBStore.substitute` sait réécrire — la même grammaire,
    /// parcourue de la même façon, pour que les deux ne divergent jamais.
    public static func bareWords(in fts: String) -> [String] {
        var out: [String] = []
        var word = ""
        var inQuotes = false
        var nearDepth = 0
        var parenStack: [Bool] = []
        var index = fts.startIndex

        func flush(followedBy next: Character?) {
            defer { word = "" }
            guard !word.isEmpty, !inQuotes, nearDepth == 0 else { return }
            guard next != "*", next != "(" else { return }   // préfixe, NEAR(
            let upper = word.uppercased()
            guard !["AND", "OR", "NOT", "NEAR"].contains(upper) else { return }
            if !out.contains(word) { out.append(word) }
        }

        while index < fts.endIndex {
            let ch = fts[index]
            let next: Character? = {
                let after = fts.index(after: index)
                return after < fts.endIndex ? fts[after] : nil
            }()
            if ch == "\"" {
                flush(followedBy: ch)
                inQuotes.toggle()
            } else if inQuotes {
                // rien : le contenu d'une phrase ne se réécrit pas
            } else if ch.isLetter || ch.isNumber || ch == "_" {
                word.append(ch)
                if next == nil { flush(followedBy: nil) }
            } else if ch == "(" {
                let isNear = word.uppercased() == "NEAR"
                flush(followedBy: ch)
                parenStack.append(isNear)
                if isNear { nearDepth += 1 }
            } else if ch == ")" {
                flush(followedBy: ch)
                if let wasNear = parenStack.popLast(), wasNear { nearDepth -= 1 }
            } else {
                flush(followedBy: ch)
            }
            index = fts.index(after: index)
        }
        return out
    }

    /// Les variantes de chaque mot nu d'une chaîne FTS5, prêtes pour
    /// `GRDBStore.substitute` : `["polymere": ["polymeres"]]`. Les mots sans
    /// variante n'y figurent pas, et une forme partagée par deux mots nus
    /// n'est donnée à aucun (`variants(of:among:)`).
    public static func expansions(forBareWordsIn fts: String) -> [String: [String]] {
        var table: [String: [String]] = [:]
        let words = bareWords(in: fts)
        for word in words {
            let forms = variants(of: word, among: words)
            if !forms.isEmpty { table[word.lowercased()] = forms }
        }
        return table
    }
}
