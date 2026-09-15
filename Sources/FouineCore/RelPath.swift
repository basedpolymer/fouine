// RelPath.swift — UNE seule forme Unicode pour les chemins stockés et cherchés.
// Propriété : A-Core. Lot K6 du 04/09/2026 (constat A3-10).
//
// LE PROBLÈME, mesuré. `docs.rel_path` est comparé en SQLite par égalité
// d'OCTETS (`rel_path = :path`) et par préfixe (`substr(rel_path, 1, n)`).
// Or « é » s'écrit de deux façons parfaitement légitimes : U+00E9 (précomposé,
// NFC — ce que produisent le web, JSON, Linux et le clavier français) ou
// U+0065 U+0301 (décomposé, NFD — ce que rendent historiquement HFS+ et
// l'énumérateur de FileManager). Les deux s'affichent « é », ne se distinguent
// à l'œil sur AUCUN écran, et ne sont PAS égales pour SQLite.
//
// La conséquence était silencieuse et donc coûteuse : trois documents de la base
// de production (dont « mise sur le marché… ») ne se retrouvaient ni par
// `docID(volUUID:relPath:)`, ni par le filtre de racine, ni par `--only` — sans
// le moindre message, puisque « aucune correspondance » n'est pas une erreur.
//
// LA RÈGLE. Tout `rel_path` est mis en NFC (`precomposedStringWithCanonicalMapping`)
// À L'ENTRÉE : quand le crawler le fabrique, quand `root add` le résout, et quand
// une recherche par chemin le reçoit. La base ne contient donc qu'une forme, et
// la comparaison d'octets redevient la comparaison de chemins.
//
// NFC ET NON NFD, alors qu'APFS et HFS+ penchent pour NFD : c'est la forme
// d'échange (JSON du contrat `--json`, MCP, tout ce qui sort du produit), et
// c'est celle qu'un chemin saisi à la main portera. Le système de fichiers, lui,
// se moque de la forme qu'on lui présente — APFS est insensible à la
// normalisation à la recherche, HFS+ normalise lui-même — donc le sens de
// conversion n'a de conséquence que sur nos propres comparaisons.

import Foundation

public enum RelPath {

    /// La forme canonique d'un chemin relatif stocké dans `docs.rel_path` ou
    /// `roots.rel_path`. Idempotente : normaliser deux fois ne change rien.
    public static func normalized(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
    }

    /// Vrai si le chemin n'est PAS déjà sous forme canonique — c'est-à-dire
    /// s'il diffère EN OCTETS de sa forme NFC. Sert à éprouver que ce qui entre
    /// en base est bien normalisé (`CrawlTests`).
    ///
    /// COMPARAISON D'OCTETS, ET SURTOUT PAS `!=`. `String` de Swift compare
    /// selon l'ÉQUIVALENCE CANONIQUE Unicode : « é » précomposé et « é »
    /// décomposé y sont égaux, et `normalized(p) != p` est donc TOUJOURS faux.
    /// C'est précisément l'inverse de ce que fait SQLite, qui compare les
    /// octets — d'où le problème qu'on répare. Le piège s'est refermé une fois
    /// (test rouge au premier jet, 04/09/2026).
    public static func needsNormalization(_ path: String) -> Bool {
        !normalized(path).utf8.elementsEqual(path.utf8)
    }
}
