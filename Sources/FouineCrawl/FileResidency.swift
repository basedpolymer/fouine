// FileResidency.swift — fichiers NON RÉSIDENTS : iCloud Drive et les File
// Providers tiers (Dropbox, OneDrive, Google Drive). Propriété : A-Ingest,
// audit F5.
//
// « Optimiser le stockage du Mac » remplace le CONTENU d'un fichier par un
// marqueur : `ls -l` montre la taille d'origine, `stat` aussi, l'aperçu Finder
// aussi. Les octets, eux, sont sur un serveur. Les LIRE — et un extracteur
// commence toujours par les lire — déclenche un téléchargement silencieux, sans
// barre de progression et sans consentement. Sur un ~/Documents de 40 Go dont
// 38 sont évincés, un `fouine index` rapatrie 38 Go sur le réseau et remplit le
// disque que l'utilisateur venait de libérer. Ce fichier est ce qui l'empêche.
//
// DEUX tests, dans cet ordre :
//
//   · `st_flags & SF_DATALESS` (`lstat(2)`) — le drapeau que le NOYAU pose sur
//     tout fichier matérialisable à la demande, quel que soit le fournisseur.
//     C'est le test générique : il couvre iCloud ET les File Providers tiers,
//     qui passent tous par la même extension du noyau depuis macOS 11 ;
//   · `isUbiquitousItemKey` + `ubiquitousItemDownloadingStatusKey != .current` —
//     spécifique à iCloud, gardé en SECOND parce qu'il voit un cas que le
//     premier ne voit pas : un fichier en cours de synchronisation descendante,
//     présent mais pas encore à jour.
//
// Aucun des deux n'OUVRE le fichier : `lstat` et les attributs d'URL lisent des
// métadonnées, jamais des octets. C'est toute la difficulté du point — le seul
// moyen naïf de savoir si un fichier est là est justement celui qui le fait
// descendre.

import Foundation

public enum FileResidency {

    /// Motif écrit dans `docs.err`, lu tel quel par la CLI, l'app et l'agent.
    ///
    /// Il dit la CAUSE et la SUITE : sans la seconde moitié, un utilisateur qui
    /// voit « non téléchargé » dans la liste des documents ignorés croit devoir
    /// intervenir, alors que le crawl suivant le reprendra tout seul.
    public static let skipReason =
        "not downloaded (iCloud/File Provider) — it will be indexed once present"

    /// `SF_DATALESS` (`<sys/stat.h>`, 0x4000_0000) : « file is dataless object ».
    /// Vérifié sur cette machine (macOS 15, SDK 15) : la constante est bien
    /// exposée à Swift, on la reprend telle quelle plutôt que de la recopier.
    public static let datalessFlag = UInt32(SF_DATALESS)

    /// Lecteur de `st_flags`, INJECTABLE.
    ///
    /// Un test ne peut pas fabriquer un fichier `SF_DATALESS` : le drapeau est
    /// posé par le noyau pour le compte d'un File Provider et `chflags` le
    /// refuse à un processus ordinaire. C'est donc le lecteur qu'on simule, et
    /// le reste du chemin — masquage, décision, enregistrement `.skipped` — est
    /// exercé pour de vrai.
    public typealias FlagsReader = @Sendable (URL) -> UInt32?

    /// Lecteur de service : `lstat(2)`, qui NE SUIT PAS les liens symboliques —
    /// le drapeau qui compte est celui du fichier nommé, pas celui de sa cible.
    public static let systemFlags: FlagsReader = { url in
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return st.st_flags
    }

    /// `true` si le noyau signale un fichier matérialisable à la demande.
    /// Un `lstat` en échec (fichier disparu entre-temps) rend `false` : le
    /// traitement normal suivra et échouera proprement.
    public static func isDataless(_ url: URL,
                                  flags: FlagsReader = systemFlags) -> Bool {
        guard let value = flags(url) else { return false }
        return value & datalessFlag != 0
    }

    /// `true` si l'élément est un élément iCloud qui n'est pas à jour localement.
    /// Un élément ubiquitaire dont le statut est illisible est tenu pour ABSENT :
    /// mieux vaut différer l'indexation d'un fichier présent que déclencher un
    /// téléchargement de 40 Go.
    public static func isEvictedUbiquitousItem(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey,
                                         .ubiquitousItemDownloadingStatusKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isUbiquitousItem == true else { return false }
        guard let status = values.ubiquitousItemDownloadingStatus else { return true }
        return status != .current
    }

    /// Le prédicat du crawl : `true` -> le fichier n'est PAS ouvert.
    public static func isNonResident(_ url: URL,
                                     flags: FlagsReader = systemFlags) -> Bool {
        isDataless(url, flags: flags) || isEvictedUbiquitousItem(url)
    }
}
