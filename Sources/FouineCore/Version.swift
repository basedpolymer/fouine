// Version.swift — source de vérité unique du numéro de version (audit D19).
// Propriété : A-Pack.
//
// Avant cet ajout, le numéro vivait à deux endroits qui divergeaient :
// `CFBundleShortVersionString` de Packaging/Info.plist (1.0) contre le
// `version:` de CommandsRoot.swift (1.1) — et rien du tout côté dépôt.
// Désormais :
//
//   VERSION                          fichier d'une ligne, lu par le Makefile
//                                    et par la CI
//   Sources/FouineCore/Version.swift la même chaîne, lue par la CLI (et
//                                    disponible pour l'app)
//   Packaging/Info.plist             valeurs de REPLI (1.0.0 / 1), réécrites
//                                    par `make bundle` avec `plutil -replace`
//
// `make check-version` échoue si les deux premières divergent ; la cible
// `bundle` l'appelle, la CI aussi, et `release.yml` exige en plus que le tag
// `vX.Y.Z` soit égal à VERSION. Toute release passe donc par une modification
// simultanée des deux fichiers — c'est le point (1) de RELEASING.md.
//
// Pourquoi un fichier ET une constante, plutôt qu'une génération de code : la
// génération imposerait une étape de build avant toute compilation (y compris
// `swift build` nu, dans Xcode ou depuis un éditeur), pour une chaîne qui
// change trois fois par an. Un garde-fou de 4 lignes dans le Makefile coûte
// moins cher et échoue plus clairement.

public enum FouineVersion {
    /// Version marketing, telle qu'elle part dans `CFBundleShortVersionString`
    /// et dans `fouine --version` (SemVer, sans le « v » du tag git).
    public static let string = "1.0.3"
}
