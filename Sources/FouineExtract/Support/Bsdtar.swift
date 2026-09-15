// Bsdtar.swift — sous-processus /usr/bin/bsdtar (SPEC §2.2, §5.3).
// Propriété : A-Ingest.
//
// Voie IMPOSÉE pour toute archive (docx, odt, xlsx, pptx, epub, cbz, cbr) :
// `bsdtar -xOf` écrit sur la SORTIE STANDARD, donc rien n'atterrit sur disque et
// le garde-fou Zip Slip du §5.3 est acquis par construction — il n'y a pas de
// dossier de destination dont une entrée « ../… » ou « /… » pourrait sortir.
//
// libarchive 3.7.4 lit ZIP ET RAR (vérifié §2.2) : c'est ce qui couvre .cbr.
//
// UNE INVOCATION PAR ARCHIVE, pas une par entrée (A11.6) : chaque `bsdtar -xOf`
// re-balaye l'archive entière, et un EPUB de 45 Ko / 300 entrées coûtait 3,44 s
// contre 0,026 s pour un listage unique — facteur 130. `extract(archive:entries:)`
// demande donc TOUTES les entrées voulues d'un coup : bsdtar les écrit à la
// suite, dans l'ordre de l'ARCHIVE, et le flux se redécoupe sur les tailles
// décompressées déclarées par `-tvf`.

import Foundation
import FouineCore

public enum Bsdtar {
    public static let executable = "/usr/bin/bsdtar"

    /// SÉPARATEUR OBLIGATOIRE entre les options et les opérandes (audit S1).
    ///
    /// Les noms d'entrées viennent de `bsdtar -tf` sur l'archive de l'utilisateur,
    /// donc l'ARCHIVE contrôle l'opérande. Sans `--`, une entrée dont le nom
    /// commence par un tiret est lue comme une OPTION — et `bsdtar` en a une qui
    /// exécute une commande. Reproduit sur cette machine (bsdtar 3.5.3 /
    /// libarchive 3.7.4), zip dont une entrée s'appelle
    /// « --use-compress-program=/usr/bin/touch PWNED » :
    ///   · `bsdtar -xOf t.zip '--use…'`      -> rc 0, fichier PWNED CRÉÉ ;
    ///   · `bsdtar -xOf t.zip -- '--use…'`   -> rc 0, rend « contenu-ucp », rien créé.
    /// Idem « --exclude=a.txt » : sans `--`, a.txt disparaissait de la sortie.
    /// `globEscaped` n'y peut rien : elle n'échappe que `* ? [ ] \`.
    ///
    /// Placé JUSTE APRÈS `archive.path` — vérifié à cette position pour `-tf`,
    /// `-tvf` et `-xOf`. Les listages n'ont aujourd'hui aucun opérande, mais le
    /// séparateur y reste : c'est la forme unique, et rien ne pourra plus
    /// s'ajouter derrière sans être un opérande.
    static let operandSeparator = "--"

    /// Plafond sur le volume DÉCOMPRESSÉ lu d'une archive en un appel (A11.2).
    ///
    /// `FileGuard` ne voit que la taille COMPRESSÉE : un .docx de 1,8 Mo dont
    /// word/document.xml se décompresse en 645 Mo passait sans broncher, pour un
    /// pic mémoire de l'ordre du gigaoctet — multiplié par `--jobs`.
    ///
    /// Étalon mesuré sur le corpus (68 conteneurs, 01/09/2026) : la plus grosse
    /// entrée fait 4,7 Mo (un oleObject de .docx), la plus grosse entrée XML
    /// 1,4 Mo, et le conteneur le plus lourd totalise 16,1 Mo décompressés.
    /// 128 Mio laissent donc un facteur 8 au pire cas réel tout en refusant la
    /// bombe. Au-delà : FouineError.extraction, motif « entrée décompressée trop
    /// volumineuse » dans `docs.err`.
    public static let maxDecompressedBytes = 128 << 20

    /// Longueur cumulée d'opérandes au-delà de laquelle l'extraction groupée est
    /// scindée en plusieurs invocations : ARG_MAX vaut 1 Mio sur macOS, on reste
    /// très en deçà.
    static let maxOperandChars = 100_000

    /// Plafond du LISTAGE d'une archive, en octets de sortie (audit X1).
    ///
    /// `maxDecompressedBytes` borne le CONTENU lu ; rien ne bornait les NOMS.
    /// `list` et `declaredSizes` gardaient jusqu'à 128 Mio de texte en mémoire,
    /// par worker donc × `--jobs` : 512 Mio à 4 jobs, pour lire des noms de
    /// fichiers. Et c'est un plafond qu'un document piégé atteint sans effort :
    /// une entrée ZIP vide coûte une trentaine d'octets dans l'archive et rend
    /// une ligne entière au listage — une « bombe d'entrées », cousine de la
    /// bombe de décompression du point A11.2.
    ///
    /// 16 Mio, soit de l'ordre de 250 000 noms de 60 caractères. Le conteneur le
    /// plus riche du corpus est l'EPUB de 300 entrées de l'en-tête (A11.6) : son
    /// listage tient dans quelques dizaines de kilo-octets, le facteur est de
    /// l'ordre de mille.
    public static let maxListingBytes = 16 << 20

    /// Plafond du listage en NOMBRE d'entrées, la borne qui mord la première.
    ///
    /// Le coût mémoire d'une entrée n'est pas sa longueur : c'est un `String` de
    /// plus dans un tableau, et chaque appelant en refait des copies filtrées.
    /// 100 000 entrées coûtent quelques Mo par worker et laissent un facteur de
    /// l'ordre de 300 aux deux cas réels connus — l'EPUB de 300 entrées
    /// ci-dessus et un cbz d'album complet, une entrée par planche. Au-delà,
    /// l'archive est REFUSÉE — même style que la bombe zip A11 : une
    /// `FouineError.extraction` lisible dans `docs.err`, pas un dépassement
    /// mémoire silencieux.
    public static let maxListingEntries = 100_000

    /// Entrées de l'archive (`bsdtar -tf`), dans l'ordre rendu par libarchive.
    /// Les entrées de dossier (suffixe « / ») sont conservées telles quelles :
    /// chaque appelant filtre ce qu'il cherche.
    ///
    /// `maxEntries` et `maxBytes` ne sont paramétrables que pour les tests : les
    /// valeurs de service sont `maxListingEntries` et `maxListingBytes`.
    public static func list(archive: URL,
                            maxEntries: Int = maxListingEntries,
                            maxBytes: Int = maxListingBytes) throws -> [String] {
        let data = try Subprocess.run(executable,
                                      ["-tf", archive.path, operandSeparator],
                                      what: archive.lastPathComponent,
                                      maxOutputBytes: maxBytes)
        // Le comptage se fait sur les OCTETS, avant de décoder : c'est ce qui
        // évite de construire les 100 001 chaînes qu'on s'apprête à refuser.
        let lines = data.withUnsafeBytes { raw -> Int in
            var count = 0
            for byte in raw where byte == 0x0A { count += 1 }
            return count
        }
        guard lines <= maxEntries else {
            throw FouineError.extraction(
                "archive refused (\(archive.lastPathComponent)): "
                + "\(lines) entries listed, cap \(maxEntries)")
        }
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .map(String.init)
    }

    /// Contenu brut d'une entrée. RIEN n'est écrit sur disque (`-O`).
    /// `maxBytes` n'est paramétrable que pour les tests : la valeur de service est
    /// `maxDecompressedBytes`.
    public static func extract(archive: URL, entry: String,
                               maxBytes: Int = maxDecompressedBytes) throws -> Data {
        try Subprocess.run(executable,
                           ["-xOf", archive.path, operandSeparator,
                            globEscaped(entry)],
                           what: "\(archive.lastPathComponent)!\(entry)",
                           maxOutputBytes: maxBytes)
    }

    /// Contenu brut de PLUSIEURS entrées, en une seule invocation (A11.6).
    ///
    /// Le total décompressé déclaré est vérifié AVANT de lire quoi que ce soit :
    /// c'est la borne mémoire du point A11.2, la seule qui puisse s'appliquer
    /// avant la décompression. Le repli — listage verbeux inexploitable — est
    /// l'ancien comportement, une invocation par entrée : plus lent, jamais faux.
    public static func extract(archive: URL, entries wanted: [String],
                               maxBytes: Int = maxDecompressedBytes)
        throws -> [String: Data] {
        var unique: [String] = []
        var seen = Set<String>()
        for entry in wanted where seen.insert(entry).inserted { unique.append(entry) }
        guard unique.count > 1 else {
            guard let only = unique.first else { return [:] }
            return [only: try extract(archive: archive, entry: only, maxBytes: maxBytes)]
        }

        guard let ordered = try declaredSizes(archive: archive, wanted: Set(unique)),
              ordered.count >= unique.count
        else {
            var out: [String: Data] = [:]
            for entry in unique {
                out[entry] = try extract(archive: archive, entry: entry,
                                         maxBytes: maxBytes)
            }
            return out
        }

        let total = ordered.reduce(0) { $0 + $1.size }
        guard total <= maxBytes else {
            throw FouineError.extraction(
                "uncompressed entry too large (\(archive.lastPathComponent)): "
                + "\(total >> 20) MiB to read, cap \(maxBytes >> 20) MiB")
        }

        var out: [String: Data] = [:]
        for chunk in operandChunks(ordered) {
            let arguments = ["-xOf", archive.path, operandSeparator]
                + chunk.map { globEscaped($0.name) }
            let expected = chunk.reduce(0) { $0 + $1.size }
            let data = try Subprocess.run(
                executable, arguments,
                what: "\(archive.lastPathComponent) (\(chunk.count) entries)",
                maxOutputBytes: maxBytes)
            // bsdtar écrit les entrées bout à bout, sans séparateur : la seule
            // façon de les redécouper est la taille déclarée. Si le compte n'y est
            // pas (en-têtes menteurs, tailles inconnues d'un zip écrit en flux),
            // on ne rend SURTOUT PAS des morceaux décalés : retour à l'ancienne
            // voie, une invocation par entrée.
            guard data.count == expected else {
                for item in chunk where out[item.name] == nil {
                    out[item.name] = try extract(archive: archive, entry: item.name,
                                                 maxBytes: maxBytes)
                }
                continue
            }
            var offset = data.startIndex
            for item in chunk {
                let end = data.index(offset, offsetBy: item.size)
                if out[item.name] == nil { out[item.name] = Data(data[offset..<end]) }
                offset = end
            }
        }
        return out
    }

    /// Une entrée d'archive et sa taille décompressée déclarée.
    struct Entry {
        let name: String
        let size: Int
    }

    /// Tailles décompressées déclarées des entrées demandées, DANS L'ORDRE DE
    /// L'ARCHIVE — c'est-à-dire l'ordre dans lequel `-xOf` les écrira.
    ///
    /// `bsdtar -tvf` est le seul listage qui porte la taille. Ses colonnes n'ont
    /// pas de largeur garantie, mais les noms cherchés sont exacts (ils viennent
    /// d'un `-tf`) : on reconnaît donc chaque ligne par sa FIN, puis la taille se
    /// lit juste avant les trois champs de date. Rend nil si une seule entrée
    /// demandée n'a pas pu être appariée — l'appelant retombe alors sur l'ancienne
    /// voie, une invocation par entrée.
    static func declaredSizes(archive: URL, wanted: Set<String>) throws -> [Entry]? {
        // Même plafond que `list` : `-tvf` est le listage le PLUS bavard (une
        // soixantaine d'octets de permissions et de date par entrée en plus du
        // nom), c'est donc lui qui coûterait le plus cher sans borne.
        let data = try Subprocess.run(executable,
                                      ["-tvf", archive.path, operandSeparator],
                                      what: archive.lastPathComponent,
                                      maxOutputBytes: maxListingBytes)
        var found: [Entry] = []
        var matched = Set<String>()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let text = String(line)
            // Plus long nom demandé dont la ligne se termine par « <espace>nom » :
            // départage « b.xml » de « a/b.xml » quand les deux sont demandés.
            var name: String?
            for candidate in wanted where text.hasSuffix(" " + candidate) {
                if candidate.count > (name?.count ?? 0) { name = candidate }
            }
            guard let entry = name else { continue }
            // « -rw-r--r--  0 0      0          11 Sep  1 12:49 dossier/a.txt » :
            // la taille est le champ qui PRÉCÈDE la date, et la date en occupe
            // exactement trois (mois, quantième, heure ou année).
            let fields = text.dropLast(entry.count + 1).split(separator: " ")
            guard fields.count >= 4,
                  let size = Int(fields[fields.count - 4]), size >= 0,
                  Int(fields[fields.count - 3]) == nil        // le nom du mois
            else { return nil }
            found.append(Entry(name: entry, size: size))
            matched.insert(entry)
        }
        return matched.count == wanted.count ? found : nil
    }

    /// Découpe la liste d'opérandes pour ne jamais approcher ARG_MAX.
    static func operandChunks(_ entries: [Entry]) -> [[Entry]] {
        var chunks: [[Entry]] = []
        var current: [Entry] = []
        var length = 0
        for entry in entries {
            let cost = entry.name.count + 3          // échappements + séparateur
            if !current.isEmpty, length + cost > maxOperandChars {
                chunks.append(current)
                current = []
                length = 0
            }
            current.append(entry)
            length += cost
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// bsdtar interprète ses opérandes comme des MOTIFS glob (vérifié sur la
    /// machine : `image[1].png` ne trouve pas l'entrée littérale du même nom,
    /// `image\[1\].png` la trouve). On échappe donc les métacaractères pour que
    /// le nom rendu par `-tf` désigne exactement l'entrée voulue.
    static func globEscaped(_ entry: String) -> String {
        var out = String()
        out.reserveCapacity(entry.count + 8)
        for ch in entry {
            if ch == "*" || ch == "?" || ch == "[" || ch == "]" || ch == "\\" {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }
}
