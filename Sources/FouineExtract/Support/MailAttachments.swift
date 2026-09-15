// MailAttachments.swift — les pièces jointes d'un courriel : ce qu'on retient,
// sous quel nom, et où on le dépose (lot EX1, constat C2-15).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Ingest.
//
// Une facture reçue par courriel est souvent le SEUL exemplaire que son
// destinataire en ait : sans les pièces jointes, un fonds de courriels indexé
// ne rend que les politesses du corps. Les pièces deviennent donc des pages du
// même document, exactement comme les images embarquées d'un `.docx`
// (`OOXMLCore.result`) — numérotées APRÈS le corps.
//
// Ce fichier ne porte que les DÉCISIONS, toutes pures et testables : quelles
// extensions on accepte, comment un nom venu du courriel est nettoyé avant de
// toucher le disque, et où les octets sont déposés. L'assemblage des pages est
// dans `EMLExtractor`.

import Foundation
import FouineCore

/// Une partie de courriel retenue comme pièce jointe.
struct EMLAttachment {
    /// Ce qu'il faut lire pour en faire des pages.
    enum Payload {
        /// Octets décodés (base64, quoted-printable, 7/8bit), à déposer dans un
        /// fichier temporaire et à passer au registre d'extracteurs.
        case file(Data)
        /// Un courriel joint (`message/rfc822`, ou une pièce qui porte une
        /// extension de courrier), DÉJÀ rendu en texte dans le processus : pas
        /// de fichier temporaire, et ses PROPRES pièces ne sont pas suivies.
        /// C'est là qu'est bornée la profondeur — sans cela, dix pièces `.eml`
        /// portant chacune dix pièces `.eml` feraient exploser une passe.
        case message(String)
        /// Une pièce nommée qu'aucun lecteur ne lit (une archive, une image, un
        /// format inconnu). Ses octets ne sont même pas DÉCODÉS : une photo de
        /// 20 Mio jointe ne coûte pas 20 Mio de base64 pour finir en note.
        case unread
    }

    /// Nom nettoyé par `MailAttachments.sanitized(name:)` : jamais de `/`, de
    /// `..`, ni de caractère de contrôle. C'est lui qui s'écrit en première
    /// ligne de la première page de la pièce, pour qu'une recherche
    /// « facture.pdf » la retrouve.
    let name: String
    let payload: Payload
}

enum MailAttachments {
    /// Plafond du nombre de pièces LUES par courriel. Un courriel légitime en
    /// porte une à trois ; au-delà de dix, c'est une liste de diffusion ou un
    /// fichier fabriqué, et chaque pièce coûte une extraction complète.
    static let maxPerMessage = 10

    /// Longueur maximale du nom déposé sur disque, en octets. HFS+/APFS
    /// acceptent 255 octets par composant ; 120 laisse de la marge sans jamais
    /// faire échouer l'écriture sur un nom fabriqué.
    static let maxNameBytes = 120

    /// Nom de repli d'une pièce dont le nom ne survit pas au nettoyage
    /// (« ../.. », un nom fait de caractères de contrôle).
    static let fallbackName = "attachment"

    /// Extensions de courrier : une pièce qui en porte une est lue DANS le
    /// processus (`Payload.message`), jamais rendue au registre — c'est ce qui
    /// borne la profondeur à un.
    static let mailExtensions: Set<String> =
        EMLExtractor.supportedExtensions.union(MailboxExtractor.supportedExtensions)

    /// Archives : jamais ouvertes DEPUIS un courriel. bsdtar sur une archive
    /// arbitraire est le sujet de sécurité tranché par le lot SI1 ; une pièce
    /// jointe est exactement l'entrée non fiable qu'on ne lui donne pas. Les
    /// conteneurs identifiés (`docx`, `xlsx`, `epub`…) restent lus : bsdtar y
    /// est appelé sur des entrées NOMMÉES, bornées en volume décompressé
    /// (`Bsdtar.maxDecompressedBytes`).
    ///
    /// La plupart de ces extensions ne sont de toute façon pas dans
    /// `DefaultExtractorRegistry.supportedExtensions` ; la liste est écrite en
    /// entier pour que l'entrée d'un futur extracteur d'archives ne rouvre pas
    /// cette porte en silence.
    static let archiveExtensions: Set<String> = [
        "zip", "cbz", "cbr", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz",
        "xz", "txz", "zst", "lz", "lzh", "arj", "cab", "cpio", "iso", "dmg",
    ]

    /// Ce qu'une pièce jointe peut porter comme extension pour être lue : les
    /// formats du registre, moins les archives, moins les sons et vidéos, moins
    /// les courriels (lus dans le processus).
    ///
    /// Les IMAGES n'y sont pas, et pas par oubli : elles ne sont pas dans
    /// `supportedExtensions` (elles ont `imageExtensions`, sous `extract.images`),
    /// et surtout leur seule valeur serait l'OCR — que le rendu de page ne sait
    /// pas produire pour un courriel (voir `docs/architecture.md`).
    static let readableExtensions: Set<String> =
        DefaultExtractorRegistry.supportedExtensions
            .subtracting(archiveExtensions)
            .subtracting(DefaultExtractorRegistry.mediaExtensions)
            .subtracting(mailExtensions)

    /// L'extension nettoyée d'un nom de pièce, en minuscules, sans point.
    static func fileExtension(of name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    /// Vrai si un extracteur du registre sait lire cette pièce.
    static func isReadable(name: String) -> Bool {
        readableExtensions.contains(fileExtension(of: name))
    }

    /// Vrai si la pièce est elle-même du courrier (lue dans le processus).
    static func isMail(name: String) -> Bool {
        mailExtensions.contains(fileExtension(of: name))
    }

    /// Motif de refus d'une pièce qu'aucun extracteur ne lit, tel qu'il est
    /// écrit dans `meta.attachments_skipped`.
    static func skipReason(name: String) -> String {
        archiveExtensions.contains(fileExtension(of: name)) ? "archive" : "no reader"
    }

    /// Le nom sous lequel une pièce est déposée sur disque.
    ///
    /// Le nom vient du courriel : c'est une chaîne hostile. Trois choses ne
    /// doivent pas arriver — sortir du dossier temporaire (`../../etc/passwd`),
    /// écrire un nom que le système refuse (caractère de contrôle, 4 Kio de
    /// lettres), passer pour une option d'un outil (`-o`, même si tous nos
    /// sous-processus reçoivent un chemin ABSOLU et un `--`).
    static func sanitized(name raw: String) -> String {
        // Les deux séparateurs : `\` est celui de l'expéditeur Windows, et
        // `lastPathComponent` ne le connaît pas.
        let unified = raw.replacingOccurrences(of: "\\", with: "/")
        var name = (unified as NSString).lastPathComponent

        // Caractères de contrôle et deux-points (séparateur hérité de Mac OS,
        // que le Finder affiche en `/`).
        name = String(name.unicodeScalars.map { scalar -> Character in
            if scalar.value < 0x20 || scalar.value == 0x7F { return "_" }
            if scalar == ":" || scalar == "/" { return "_" }
            return Character(scalar)
        })
        name = name.trimmingCharacters(in: .whitespaces)

        // `.` et `..` ne sont pas des noms de fichiers ; un nom vide non plus.
        if name.isEmpty || name == "." || name == ".." { return fallbackName }
        // Un nom qui commence par un tiret ne partira jamais comme option.
        if name.hasPrefix("-") { name = "_" + name.dropFirst() }
        return truncated(name)
    }

    /// Nom ramené à `maxNameBytes` octets, EXTENSION CONSERVÉE : c'est elle qui
    /// décide de l'extracteur, la perdre reviendrait à perdre la pièce.
    static func truncated(_ name: String) -> String {
        guard name.utf8.count > maxNameBytes else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        // Une « extension » de 40 caractères n'en est pas une : on la laisse
        // tomber avec le reste plutôt que de ne garder qu'elle.
        let suffix = ext.isEmpty || ext.utf8.count > 16 ? "" : "." + ext
        let room = maxNameBytes - suffix.utf8.count
        var base = ext.isEmpty ? name : ns.deletingPathExtension
        var bytes = base.utf8.count
        while bytes > room, !base.isEmpty {
            base.removeLast()
            bytes = base.utf8.count
        }
        let out = base + suffix
        return out.isEmpty || out == suffix ? fallbackName + suffix : out
    }

    /// Dossier temporaire d'un courriel, à lui seul, en 0700. Le nom porte un
    /// UUID : deux extractions en parallèle (`--jobs`) ne se croisent pas, et
    /// rien de ce qui traîne dans `/tmp` ne peut être écrasé ni suivi.
    /// L'APPELANT le détruit en `defer`, succès ou erreur.
    static func makeScratch() throws -> URL {
        // Le pid dans le nom : les tests comptent LEURS dossiers avant et après
        // une extraction, et `make ci-unit --parallel` fait tourner d'autres
        // processus de test qui créent et détruisent les leurs au même moment
        // (gate du 10/09/2026 : « 2 n'est pas égal à 3 », faux positif).
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fouine-eml-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return directory
    }

    /// Dépose les octets d'une pièce et rend son chemin.
    ///
    /// UN SOUS-DOSSIER PAR PIÈCE, numéroté : deux pièces d'un même courriel
    /// portent souvent le même nom (`facture.pdf` deux fois), et la seconde
    /// écraserait la première.
    static func deposit(_ data: Data, named name: String, rank: Int,
                        in scratch: URL) throws -> URL {
        let folder = scratch.appendingPathComponent(String(rank), isDirectory: true)
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try data.write(to: file)
        return file
    }
}
