// FilePermissions.swift — droits POSIX de ce que Fouine écrit chez vous.
// Propriété : A-Core. Audit A1-06, amendé par D2-09.
//
// ═══ CE QUE ÇA CORRIGE ═════════════════════════════════════════════════════
//
// La base, son `-wal`, son `-shm`, `fouine.lock` et `models/` étaient créés
// avec les droits par défaut (0644 / 0755) : le contenu indexé de tous vos
// documents — 380 000 pages de texte en clair sur la machine de recette —
// n'était protégé que par le mode de `~/Library`, qui n'appartient pas à
// Fouine. Un autre compte de la même machine, une sauvegarde qui ne conserve
// pas les modes, un partage réseau : rien de tout cela n'est du ressort de
// `~/Library`.
//
// ═══ TROIS RÈGLES, TIRÉES DE LA CONTRE-EXPERTISE D2-09 ═════════════════════
//
//   1. BEST-EFFORT, TOUJOURS. Un `chmod` qui échoue n'est JAMAIS une raison de
//      refuser d'ouvrir la base. Le contre-exemple d'A1 (« exFAT perd les
//      droits ») est faux — macOS y synthétise 0700, donc PLUS fermé que le
//      répertoire personnel, et `chmod` y réussit sans rien changer —, mais un
//      volume monté `noowners`, un partage SMB ou une restauration existent, et
//      là le `chmod` échoue pour de bon. Perdre l'accès à son index parce qu'un
//      durcissement n'a pas pu s'appliquer serait un remède pire que le mal.
//
//   2. LES EMPLACEMENTS PAR DÉFAUT SEULEMENT, pour les RÉPERTOIRES. Un
//      utilisateur qui pose `FOUINE_DB` ou `FOUINE_MODEL_DIR` peut désigner un
//      dossier partagé, dont les droits sont sa décision et pas la nôtre. On ne
//      referme donc jamais un répertoire qu'on ne nous a pas donné. Les
//      FICHIERS de Fouine, eux, sont les nôtres où qu'ils soient.
//
//   3. LE POINT D'ACCROCHE EST APRÈS `DatabasePool(path:)`, pas dans
//      `prepareDatabase` : celui-là s'exécute par connexion, et à la première
//      les `-wal`/`-shm` n'existent pas encore. SQLite recopie le mode du
//      fichier principal sur les deux fichiers qu'il crée, donc poser 0600 sur
//      le `.db` suffit dans le cas nominal ; le rattrapage explicite des trois
//      reste nécessaire pour les installations existantes.

import Foundation

public enum FilePermissions {

    /// Ce que Fouine écrit n'est lisible que par son propriétaire.
    public static let file: mode_t = 0o600
    /// Idem pour les répertoires (il faut le bit `x` pour les traverser).
    public static let directory: mode_t = 0o700

    /// `~/Library/Application Support/Fouine` — l'emplacement par défaut, celui
    /// dont les droits nous regardent. Dupliqué depuis `Support.swift` (CLI) et
    /// `AppPaths.swift` (app) : le cœur ne peut dépendre d'aucun des deux, et
    /// c'est ici que le durcissement doit vivre.
    public static var defaultSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Fouine",
                                    isDirectory: true)
    }

    /// Le répertoire est-il celui que Fouine s'est choisi ? Comparaison sur les
    /// chemins normalisés : `FOUINE_DB=~/Library/Application Support/Fouine/x.db`
    /// est le cas par défaut, `FOUINE_DB=/Volumes/Partage/x.db` ne l'est pas.
    public static func isDefaultSupport(_ url: URL) -> Bool {
        url.standardizedFileURL.resolvingSymlinksInPath().path
            == defaultSupportDirectory.standardizedFileURL
                .resolvingSymlinksInPath().path
    }

    /// Referme un FICHIER existant, sans bruit et sans conséquence en cas
    /// d'échec. Rend le mode obtenu, ou `nil` si le fichier n'existe pas / n'a
    /// pas pu être lu — les tests s'en servent pour se sauter eux-mêmes sur un
    /// système de fichiers qui ne porte pas les droits POSIX (D2-09).
    @discardableResult
    public static func restrictFile(_ url: URL) -> mode_t? {
        restrict(url, to: file)
    }

    /// Referme un RÉPERTOIRE existant. À n'appeler que sur un emplacement par
    /// défaut (règle 2).
    @discardableResult
    public static func restrictDirectory(_ url: URL) -> mode_t? {
        restrict(url, to: directory)
    }

    private static func restrict(_ url: URL, to mode: mode_t) -> mode_t? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        let current = info.st_mode & 0o7777
        if current != mode { _ = chmod(url.path, mode) }
        var after = stat()
        guard stat(url.path, &after) == 0 else { return nil }
        return after.st_mode & 0o7777
    }

    /// La base et ses deux compagnons SQLite, plus le verrou du répertoire.
    /// Appelé juste après l'ouverture du pool, et sans jamais lever.
    public static func restrictDatabase(at url: URL) {
        restrictFile(url)
        for suffix in ["-wal", "-shm"] {
            restrictFile(URL(fileURLWithPath: url.path + suffix))
        }
        let directory = url.deletingLastPathComponent()
        // Le verrou porte le nom de la base depuis BU-30 : le refermer par un
        // nom écrit en dur laissait celui d'une copie en 0644.
        restrictFile(FouinePaths.lockURL(for: url))
        // Le RÉPERTOIRE n'est refermé que s'il est le nôtre (règle 2).
        if isDefaultSupport(directory) { restrictDirectory(directory) }
    }
}
