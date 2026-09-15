// TrigramExpander.swift — expansion floue sur la table FTS5 `vocab_tri` (SPEC §5.5.2).
// Propriété : A-Core.
//
// Trois temps, dont deux en SQL :
//   1. fts5vocab lit le vocabulaire de page_fts ;
//   2. deux sondes ramènent les candidats (voir « Stratégie de sondes ») ;
//   3. Levenshtein exact avec abandon anticipé applique le plafond de distance.
//
// Plafond IMPOSÉ (§5.5.2) :   longueur ≤ 5 -> d = 0 (aucune expansion)
//                             longueur ≥ 6 -> d ≤ 2
//
// PLAFOND PAR PORTÉE (lot MC1, 13/09/2026). Le plafond ci-dessus est celui des
// fautes de la MACHINE : sur une page scannée, « rn » lu « m » et « l » lu « i »
// coûtent deux éditions sur un mot de six lettres, et la portée `ocr` le garde
// donc tel quel. Sur le REPLI en portée `all` (§5.5.3, C2-08), les fautes sont
// celles de l'UTILISATEUR, et deux éditions sur six lettres changent de mot :
// `Kenvue` rendait « Kenne » (mesuré sur la base de production). D'où
// `maxDistance(for:scope:)` : 1 de 6 à 8 lettres, 2 à partir de 9, où deux
// éditions restent une faute de frappe plausible (`Villeurbane` ->
// « Villeurbanne », 11 lettres, d = 1, inchangé).
//
// STRATÉGIE DE SONDES (corrigée après la recette de la tranche A, bogue 3).
// Un MATCH trigramme est une recherche de SOUS-CHAÎNE : le terme entier ne
// trouve jamais un voisin à distance ≥ 1, il faut sonder par morceaux. La
// v. précédente sondait 2-3 blocs contigus de ≥ 3 caractères ; sur le
// vocabulaire réel (1 486 739 termes, 10× l'échantillon du §5.5.2) un bloc de
// 3 lettres ramène des milliers de candidats et coûte 20 à 190 ms par terme
// (budget P8 : 10 ms). Mesuré sur la base complète, le coût dominant n'est pas
// le parcours des doclists (2-5 ms) mais la LECTURE de `term` pour chaque
// correspondance (~6 µs/ligne à travers xColumn de FTS5).
//
// D'où DEUX sondes par terme, chacune sur le chemin d'accès le moins cher :
//   · moitié-PRÉFIXE  (⌈n/2⌉ car.)  -> balayage de PLAGE sur le B-tree
//     `vocab_seen` (la table auxiliaire du §4.1, qui contient tout le
//     vocabulaire versé dans vocab_tri) : « commence par », ~0,5 ms ;
//   · moitié-SUFFIXE  (n-⌈n/2⌉ car., ≥ 3) -> MATCH trigramme sur vocab_tri,
//     rowids seuls, puis lecture des termes dans la table de contenu
//     `vocab_tri_content` (3 à 6× moins cher que `SELECT term FROM vocab_tri`,
//     mesuré : « mere » 1,5 ms contre 5 ms ; « ion » 53 ms contre 416 ms).
//
// GARANTIE DE RAPPEL, démontrable : les deux moitiés sont disjointes, donc une
// édition unique n'en touche qu'une — d = 1 est ENTIÈREMENT couvert (si les
// éditions sont toutes après la moitié-préfixe, le voisin COMMENCE par elle ;
// sinon il CONTIENT la moitié-suffixe). d = 2 est couvert dès que les deux
// éditions tombent dans la même moitié — ce qui inclut TOUS les cas du §5.5.2
// et les listes du §5.5.3, vérifiés sur la base réelle :
//   volume←volute (vol*) · enthalpie←estholpie (sonde « lpie ») ·
//   equilibre←lequilibre (« ibre ») · converslon→conversion (conve*) ·
//   catalyseur←calalyseur (« yseur ») ; catalyseur -> 9 voisins, polymere -> 7+2.
// Perdu par rapport aux 3 blocs de 3 : d = 2 avec UNE édition dans CHAQUE
// moitié (aucun cas de la spec) — c'était le prix des sondes de 3 lettres,
// 10 à 100× le budget P8.

import Foundation
import GRDB

public final class TrigramExpander: FuzzyExpander {

    /// Plafond de candidats ramenés de SQL (par sonde) avant filtrage Levenshtein.
    public static let candidateCap = 4_000

    private let store: GRDBStore

    public init(store: GRDBStore) { self.store = store }

    /// Le plafond de distance d'un terme pour cette portée (voir l'en-tête).
    public static func maxDistance(for term: String, scope: FuzzyScope) -> Int {
        guard scope != .ocrOnly else { return 2 }
        return normalize(term).count >= 9 ? 2 : 1
    }

    // MARK: - Alimentation

    /// Alimentation incrémentale et idempotente de vocab_tri + vocab_seen
    /// (Schema.vocabTriRefill). vocab_seen est aussi ce qui rend la
    /// moitié-préfixe sondable en B-tree (voir l'en-tête).
    ///
    /// BALAYAGE GLOBAL de fts5vocab : 18 à 25 s sur le vocabulaire réel
    /// (1 514 071 termes, mesuré). À réserver aux fins de passe d'indexation.
    public func warm() throws {
        try store.writeLocked { db in
            try db.execute(sql: Schema.vocabTriRefill)
        }
    }

    /// Alimentation CIBLÉE, depuis le texte fraîchement reconnu (audit A2 du
    /// 01/09/2026). Rend le nombre de termes réellement versés dans `vocab_tri`.
    ///
    /// La pompe OCR appelait `warm()` en fin de CHAQUE lot de 10 minutes : un
    /// balayage de 18-25 s, les quatre fils Vision à l'arrêt complet, pour
    /// insérer zéro ligne 99 fois sur 100. Or le run a le texte en main. On le
    /// verse donc dans une table FTS5 temporaire au tokenizer de `page_fts` —
    /// c'est SQLite qui tokenise, la normalisation est identique par
    /// construction — puis on ne sonde `vocab_seen` que sur ces quelques
    /// milliers de termes, par clé primaire : des millisecondes.
    ///
    /// Ne verser ici QUE du texte réellement entré dans `page_fts` : un terme
    /// dans `vocab_tri` que `page_fts` ne contient pas ferait proposer à
    /// l'expansion floue un voisin sans aucun résultat.
    @discardableResult
    public func warm(texts: [String]) throws -> Int {
        let usable = texts.filter { !$0.isEmpty }
        guard !usable.isEmpty else { return 0 }
        return try store.writeLocked { db in
            try db.execute(sql: Schema.ocrHarvestDDL)
            for text in usable {
                try db.execute(sql: "INSERT INTO temp.ocr_harvest(body) VALUES (?)",
                               arguments: [text])
            }
            try db.execute(sql: Schema.ocrHarvestRefillTri)
            let inserted = db.changesCount
            try db.execute(sql: Schema.ocrHarvestRefillSeen)
            // La table d'appoint ne garde rien entre deux récoltes : elle est
            // vidée par `ocrHarvestDDL` au tour suivant, mais autant ne pas
            // laisser le texte d'un lot en mémoire jusque-là.
            try db.execute(sql: "DELETE FROM temp.ocr_harvest")
            return inserted
        }
    }

    // MARK: - Expansion

    /// Le point d'entrée du protocole `FuzzyExpander` (gelé) : plafond 2,
    /// la règle du §5.5.2. Un paramètre par défaut ne satisfait pas une
    /// exigence de protocole en Swift — d'où cette surcharge, et non une
    /// signature unique.
    public func expand(_ term: String, cap: Int) throws
        -> [(distance: Int, term: String)] {
        try expand(term, cap: cap, maxDistance: 2)
    }

    /// `maxDistance` : 2 pour la portée `ocr` (fautes de la machine), 1 sur les
    /// mots de 6 à 8 lettres du REPLI, où la faute vient de l'utilisateur —
    /// voir `maxDistance(for:scope:)`.
    public func expand(_ term: String, cap: Int,
                       maxDistance: Int) throws -> [(distance: Int, term: String)] {
        let normalized = Self.normalize(term)
        guard !normalized.isEmpty else { return [] }

        // Règle imposée : sous 6 lettres, AUCUNE expansion (T15).
        guard normalized.count >= 6 else { return [(distance: 0, term: normalized)] }

        let (prefix, suffix) = Self.probes(for: normalized)
        // `length()` de SQLite compte les points de code : même unité que
        // les scalaires Unicode utilisés par la distance de Levenshtein.
        let width = normalized.unicodeScalars.count
        let lo = width - maxDistance
        let hi = width + maxDistance

        let candidates: [String] = try store.read { db in
            var seen = Set<String>()
            var out: [String] = []

            // Sonde 1 — moitié-préfixe : « commence par », plage B-tree.
            if let upper = Self.rangeUpperBound(after: prefix) {
                let rows = try String.fetchAll(db, sql: """
                    SELECT term FROM vocab_seen
                    WHERE term >= ? AND term < ? AND length(term) BETWEEN ? AND ?
                    LIMIT ?
                    """, arguments: [prefix, upper, lo, hi, Self.candidateCap])
                for r in rows where seen.insert(r).inserted { out.append(r) }
            }

            // Sonde 2 — moitié-suffixe : « contient », trigramme, lecture des
            // termes via la table de contenu de vocab_tri (voir l'en-tête ;
            // vocab_tri est une table FTS5 ordinaire, sa table de contenu
            // `vocab_tri_content(id, c0)` existe toujours).
            let rows = try String.fetchAll(db, sql: """
                SELECT c.c0 FROM vocab_tri_content c
                WHERE c.id IN (SELECT rowid FROM vocab_tri WHERE vocab_tri MATCH ?)
                  AND length(c.c0) BETWEEN ? AND ?
                LIMIT ?
                """,
                arguments: [QueryParser.quote(suffix), lo, hi, Self.candidateCap])
            for r in rows where seen.insert(r).inserted { out.append(r) }
            return out
        }

        let source = Array(normalized.unicodeScalars.map(\.value))
        var scratch = LevenshteinScratch(capacity: hi + 1)
        var scored: [(distance: Int, term: String)] = []
        scored.reserveCapacity(min(candidates.count, cap))

        for candidate in candidates {
            if candidate == normalized { continue }
            let target = Array(candidate.unicodeScalars.map(\.value))
            if let d = scratch.distance(source, target, maxDistance: maxDistance) {
                scored.append((distance: d, term: candidate))
            }
        }

        scored.sort { $0.distance == $1.distance ? $0.term < $1.term
                                                 : $0.distance < $1.distance }
        // Terme exact toujours en tête (§4.2 : « terme exact inclus en tête »).
        var out: [(distance: Int, term: String)] = [(distance: 0, term: normalized)]
        if cap > 1 { out.append(contentsOf: scored.prefix(cap - 1)) }
        return out
    }

    // MARK: - Outils

    /// Le vocabulaire de page_fts est déjà désaccentué et en minuscules
    /// (unicode61 remove_diacritics 2) : on normalise le terme de la même façon.
    ///
    /// `en_US_POSIX` et non `fr_FR` (palier 3.2, audit U1) : le repliement doit
    /// être celui du TOKENIZER, qui ne connaît aucune locale, et il doit donner
    /// le même index quel que soit l'utilisateur qui l'interroge. `en_US_POSIX`
    /// est la locale invariable prévue pour ce genre de traitement ; le
    /// comportement sur les accents français est inchangé (seuls le turc et
    /// l'azéri, avec le « i » sans point, changent le repliement de casse).
    static func normalize(_ term: String) -> String {
        term.folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Les deux sondes d'un terme de ≥ 6 caractères : moitié-préfixe de
    /// ⌈n/2⌉ caractères (sondée en « commence par ») et moitié-suffixe du
    /// reste, ≥ 3 caractères (sondée en « contient »). Disjointes : une édition
    /// n'en touche qu'une (voir la garantie de rappel en tête de fichier).
    /// La coupe ⌈n/2⌉ (et non ⌊n/2⌋) est ce qui donne la sonde « lpie » à
    /// `enthalpie` — celle qui rattrape `estholpie` (§5.5.2).
    static func probes(for term: String) -> (prefix: String, suffix: String) {
        let chars = Array(term)
        let cut = (chars.count + 1) / 2
        return (String(chars[..<cut]), String(chars[cut...]))
    }

    /// Borne supérieure EXCLUSIVE de la plage « commence par `prefix` » :
    /// le préfixe dont le dernier scalaire est incrémenté. La comparaison
    /// BINARY de SQLite sur UTF-8 suit l'ordre des points de code.
    static func rangeUpperBound(after prefix: String) -> String? {
        var scalars = Array(prefix.unicodeScalars)
        while let last = scalars.last {
            // +1, en sautant la plage des seizets (0xD800-0xDFFF, invalide).
            let next = last.value == 0xD7FF ? 0xE000 : last.value + 1
            if next <= 0x10FFFF, let bumped = Unicode.Scalar(next) {
                scalars[scalars.count - 1] = bumped
                var v = String.UnicodeScalarView()
                v.append(contentsOf: scalars)
                return String(v)
            }
            scalars.removeLast()   // scalaire non incrémentable : on raccourcit
        }
        return nil
    }
}
