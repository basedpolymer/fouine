// EMLExtractor.swift — eml, emlx, olk15MsgSource (SPEC §5.3, a3-08, INT-F1).
// Propriété : A-Ingest.
//
// Dépouillement des courriels RFC 822 / MIME :
// - En-têtes : From, To, Date, Subject (avec décodage RFC 2047 =?charset?B/Q?...?=)
// - Corps : text/plain prioritaire, repli sur text/html dépouillé par HTMLText.plainText
// - Décodages : 7bit, 8bit, quoted-printable, base64
// - Prise en charge des structures multipart (multipart/alternative, multipart/mixed)
// - PIÈCES JOINTES (lot EX1, constat C2-15) : décodées, déposées dans un dossier
//   temporaire et passées au registre d'extracteurs ; leurs pages s'ajoutent
//   APRÈS celles du corps, comme les images embarquées d'un `.docx`. Les
//   décisions (extensions retenues, nettoyage du nom, dépôt) sont dans
//   `Support/MailAttachments.swift`.

import Foundation
import FouineCore

public struct EMLExtractor: TextExtractor {
    /// `emlx` : le format de Apple Mail — le message RFC 822 precede d'une ligne
    /// donnant sa longueur et suivi d'une liste de proprietes de drapeaux.
    /// `olk15msgsource` : ce qu'Outlook 15/2016 range a cote de sa base, et qui
    /// est du RFC 822 BRUT, sans habillage (lot INT-F1).
    ///
    /// Le registre compare en minuscules ; le vrai nom du format Outlook porte
    /// des majuscules (`Courrier.olk15MsgSource`), et le crawler minuscule lui
    /// aussi l'extension avant de comparer.
    public static let supportedExtensions: Set<String> = [
        "eml", "emlx", "olk15msgsource",
    ]

    public init() {}

    public func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        try FileGuard.check(url, limits)
        let raw: Data
        do {
            raw = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw FouineError.extraction(
                "cannot read (\(url.lastPathComponent)): "
                + (error as NSError).localizedDescription)
        }

        let data = url.pathExtension.lowercased() == "emlx"
            ? EMLXFraming.message(in: raw)
            : raw

        var budget = TextBudget(maxBytes: limits.maxTextBytes)
        let parsed = EMLParser.parse(data: data)
        let rendered = EMLExtractor.render(parsed)

        let body = Assembler.paginatedResult(text: budget.take(rendered.text),
                                             limits: limits, meta: rendered.meta)
        // Le chemin SANS pièce jointe est celui d'avant, au résultat près : un
        // courriel ordinaire ne doit rien changer, ni en pages, ni en durée.
        guard !parsed.attachments.isEmpty else { return body }
        return Self.appending(parsed.attachments, to: body,
                             budget: &budget, limits: limits)
    }

    // MARK: - Les pièces jointes deviennent des pages (EX1, C2-15)

    /// Les pages des pièces jointes, AJOUTÉES après celles du corps et dans
    /// l'ordre des parties du courriel.
    ///
    /// Numérotation : la pièce garde SES numéros de page, décalés du total
    /// courant (`décalage + n`) — comme les médias d'un `.docx`. Une pièce sans
    /// une once de texte (un PDF scanné, un `.svg` de tracés) rend tout de même
    /// UNE page, celle de son nom : le courriel dira honnêtement qu'il porte
    /// cette pièce, et une recherche « attestation.pdf » la trouvera.
    ///
    /// Aucune page de pièce n'est mise en file OCR, même quand l'extracteur de
    /// la pièce en réclame : le rendu de page (`FouinePageRenderer`) ne sait pas
    /// produire l'image d'une page de courriel, et une page en file sans rendu
    /// possible n'est qu'un échec nommé répété à chaque passe.
    static func appending(_ attachments: [EMLAttachment], to body: ExtractionResult,
                          budget: inout TextBudget,
                          limits: ExtractLimits) -> ExtractionResult {
        var pages = body.pages
        var pageCount = body.pageCount
        var notes: [String] = []
        var read = 0

        // Un seul dossier pour tout le courriel, créé à la PREMIÈRE pièce qui a
        // besoin du disque, détruit ici quoi qu'il arrive.
        var scratch: URL?
        defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
        // Ni images ni médias : une pièce jointe n'a pas à dépendre des réglages
        // d'indexation du poste, et l'OCR ne peut de toute façon pas la suivre.
        let registry = DefaultExtractorRegistry(extractImages: false,
                                                extractMedia: false)
        // SEUIL OCR À ZÉRO pour les pièces, et c'est la conséquence directe du
        // point précédent. Le seuil des 100 caractères du §6.1 ne JETTE pas le
        // texte d'une page pauvre : il le laisse à l'OCR, qui fera mieux. Une
        // pièce jointe n'a pas d'OCR — le rendu de page ne sait pas produire
        // l'image d'une page de courriel — donc le laisser à l'OCR revient à le
        // perdre. Mesuré sur le courriel du constat C2-15 : la facture jointe
        // porte 46 caractères (« Attestation Malinot 2026 », un numéro de
        // police), et sans cette ligne la recherche ne la retrouvait pas.
        var pieceLimits = limits
        pieceLimits.ocrThresholdChars = 0

        for attachment in attachments {
            guard read < MailAttachments.maxPerMessage else {
                let ignored = attachments.count - read
                notes.append("\(ignored) more attachment(s) ignored "
                             + "(limit \(MailAttachments.maxPerMessage))")
                break
            }
            guard !budget.isExhausted else {
                notes.append("\(attachment.name) (text budget exhausted)")
                continue
            }

            let piece: ExtractionResult
            switch attachment.payload {
            case .unread:
                notes.append("\(attachment.name) "
                             + "(\(MailAttachments.skipReason(name: attachment.name)))")
                continue
            case .message(let text):
                let slots = TextPagination.paginate(budget.take(text),
                                                    limit: limits.pageSplitChars)
                piece = Assembler.result(slots: slots, meta: [:])
            case .file(let data):
                // La taille est celle des octets DÉCODÉS : `FileGuard` la
                // reverrait après écriture, mais écrire 2 Gio pour se les faire
                // refuser serait absurde.
                guard data.count <= limits.maxFileBytes else {
                    notes.append("\(attachment.name) (too large)")
                    continue
                }
                do {
                    if scratch == nil { scratch = try MailAttachments.makeScratch() }
                    let file = try MailAttachments.deposit(
                        data, named: attachment.name, rank: read, in: scratch!)
                    piece = try registry.extract(url: file, limits: pieceLimits)
                } catch {
                    // Une pièce illisible n'emporte PAS le courriel : le corps
                    // reste indexé, et le motif est écrit dans la note.
                    notes.append("\(attachment.name) (\(Self.reason(of: error)))")
                    continue
                }
            }

            read += 1
            pages += Self.renumbered(piece, name: attachment.name,
                                     offset: pageCount, budget: &budget)
            pageCount += max(piece.pageCount, 1)
        }

        var meta = body.meta
        if read > 0 { meta["attachments"] = String(read) }
        if !notes.isEmpty { meta["attachments_skipped"] = notes.joined(separator: ", ") }
        return ExtractionResult(pages: pages, pageCount: pageCount,
                                ocrCandidates: body.ocrCandidates, meta: meta)
    }

    /// Les pages d'une pièce, décalées de `offset`, la première portant le NOM
    /// du fichier en tête. Le nom seul, sans libellé : le texte indexé n'a pas
    /// de langue d'interface, et « Pièce jointe : » ne se cherche pas.
    ///
    /// Le texte de la pièce passe par le budget DU COURRIEL. L'extracteur de la
    /// pièce a le sien, aux mêmes 50 Mio : sans ce second passage, dix pièces
    /// vaudraient dix fois le plafond d'un document.
    static func renumbered(_ piece: ExtractionResult, name: String, offset: Int,
                           budget: inout TextBudget) -> [PageText] {
        let header = name.isEmpty ? "" : name + "\n"
        guard let first = piece.pages.map(\.page).min() else {
            // Aucune page de texte — un PDF scanné, un `.svg` de tracés purs :
            // la pièce existe quand même, et son nom se cherche.
            return [PageText(page: offset + 1, text: budget.take(header),
                             source: .native)]
        }
        return piece.pages.map { page in
            let raw = page.page == first ? header + page.text : page.text
            return PageText(page: offset + page.page, text: budget.take(raw),
                            source: .native)
        }
    }

    /// Motif lisible d'un refus de pièce jointe, pour la note d'extraction.
    /// `ExtractOutcome` ne nomme que les refus « rien à indexer » ; un vrai
    /// échec (PDF corrompu) tombe sur son message.
    static func reason(of error: Error) -> String {
        guard let fouine = error as? FouineError else {
            return (error as NSError).localizedDescription
        }
        if let named = ExtractOutcome.skipReason(for: fouine) { return named }
        switch fouine {
        case .extraction(let message), .ocr(let message): return message
        case .fileTooLarge(let bytes): return "file too large (\(bytes) B)"
        default: return "unreadable"
        }
    }

    /// Le texte d'UN message — quatre en-tetes puis le corps — et ses metadonnees.
    /// Partage avec `MailboxExtractor` : une boite aux lettres n'est qu'une
    /// suite de messages, et ils doivent se lire exactement pareil.
    static func render(_ parsed: EMLParsedMessage) -> (text: String,
                                                       meta: [String: String]) {
        var headerLines: [String] = []
        if let subject = parsed.subject, !subject.isEmpty {
            headerLines.append("Subject: \(subject)")
        }
        if let from = parsed.from, !from.isEmpty {
            headerLines.append("From: \(from)")
        }
        if let to = parsed.to, !to.isEmpty {
            headerLines.append("To: \(to)")
        }
        if let date = parsed.date, !date.isEmpty {
            headerLines.append("Date: \(date)")
        }

        var fullText = ""
        if !headerLines.isEmpty {
            fullText += headerLines.joined(separator: "\n") + "\n\n"
        }
        if let body = parsed.body, !body.isEmpty {
            fullText += body
        }

        var meta: [String: String] = [:]
        if let subject = parsed.subject { meta["subject"] = subject }
        if let from = parsed.from { meta["from"] = from }
        if let to = parsed.to { meta["to"] = to }
        if let date = parsed.date { meta["date"] = date }
        return (fullText, meta)
    }
}

/// Le cadre d'un `.emlx` : « longueur, message, liste de proprietes ».
///
/// La liste de proprietes de fin porte les drapeaux de Mail (lu, marque, boite
/// d'origine) : ce sont des NOMBRES et des noms de cles, jamais du texte que
/// l'utilisateur ait ecrit ou cherche. On la laisse dehors.
enum EMLXFraming {
    /// Le message RFC 822 seul. Un fichier dont la premiere ligne n'est pas un
    /// entier plausible est rendu TEL QUEL : un `.emlx` sans compteur est un
    /// `.eml`, et le perdre pour un octet d'en-tete serait absurde.
    static func message(in data: Data) -> Data {
        guard let newline = data.firstIndex(of: 0x0A) else { return data }
        let head = data[data.startIndex..<newline]
        guard head.count <= 20,
              let line = String(data: Data(head), encoding: .ascii),
              let count = Int(line.trimmingCharacters(in: .whitespaces)),
              count > 0 else { return data }
        let start = data.index(after: newline)
        let available = data.distance(from: start, to: data.endIndex)
        let end = data.index(start, offsetBy: min(count, available))
        return Data(data[start..<end])
    }
}

struct EMLParsedMessage {
    var subject: String?
    var from: String?
    var to: String?
    var date: String?
    var body: String?
    /// Pièces jointes retenues, dans l'ordre des parties (EX1). Vide quand
    /// l'appelant ne les demande pas — c'est le cas de `MailboxExtractor`.
    var attachments: [EMLAttachment] = []
}

enum EMLParser {
    /// `attachments: false` ne collecte rien : une boîte aux lettres de mille
    /// messages n'a pas à décoder mille pièces pour les jeter (MailboxExtractor).
    static func parse(data: Data, attachments collect: Bool = true)
        -> EMLParsedMessage {
        let (rawHeaders, bodyData) = splitHeaderAndBody(data)
        let headers = parseHeaders(rawHeaders)

        let subject = headers["subject"].map { decodeMIMEWords($0) }
        let from = headers["from"].map { decodeMIMEWords($0) }
        let to = headers["to"].map { decodeMIMEWords($0) }
        let date = headers["date"].map { decodeMIMEWords($0) }

        let body = extractBody(headers: headers, bodyData: bodyData,
                               attachments: collect)

        return EMLParsedMessage(
            subject: subject,
            from: from,
            to: to,
            date: date,
            body: body.text,
            attachments: body.attachments
        )
    }

    /// Sépare les en-têtes bruts du corps (délimités par une ligne vide \r\n\r\n ou \n\n).
    static func splitHeaderAndBody(_ data: Data) -> (String, Data) {
        let bytes = [UInt8](data)
        var headerEnd = data.count
        var bodyStart = data.count

        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0A { // \n
                if i + 1 < bytes.count && bytes[i + 1] == 0x0A { // \n\n
                    headerEnd = i
                    bodyStart = i + 2
                    break
                }
            } else if bytes[i] == 0x0D { // \r
                if i + 3 < bytes.count && bytes[i + 1] == 0x0A && bytes[i + 2] == 0x0D && bytes[i + 3] == 0x0A { // \r\n\r\n
                    headerEnd = i
                    bodyStart = i + 4
                    break
                }
            }
            i += 1
        }

        let headerData = data.prefix(headerEnd)
        let headerStr = String(data: headerData, encoding: .utf8)
            ?? String(data: headerData, encoding: .isoLatin1)
            ?? ""
        let bodyData = (bodyStart < data.count) ? data.suffix(from: bodyStart) : Data()
        return (headerStr, Data(bodyData))
    }

    /// Déplie et parse les en-têtes RFC 822 en dictionnaire [nom_minuscule: valeur].
    static func parseHeaders(_ rawHeaders: String) -> [String: String] {
        var dict: [String: String] = [:]
        var unfoldedLines: [String] = []
        let rawLines = rawHeaders.components(separatedBy: .newlines)
        for line in rawLines {
            if line.isEmpty { continue }
            if (line.hasPrefix(" ") || line.hasPrefix("\t")) && !unfoldedLines.isEmpty {
                let last = unfoldedLines.removeLast()
                unfoldedLines.append(last + " " + line.trimmingCharacters(in: .whitespaces))
            } else {
                unfoldedLines.append(line)
            }
        }

        for line in unfoldedLines {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            if dict[name] == nil {
                dict[name] = value
            } else {
                dict[name]! += ", " + value
            }
        }
        return dict
    }

    /// Extrait la valeur d'un paramètre (ex. boundary="...", charset=utf-8) dans une valeur d'en-tête.
    static func extractParameter(named param: String, from headerValue: String) -> String? {
        let quotedPattern = #"(?:^|[;\s])"# + NSRegularExpression.escapedPattern(for: param) + #"\s*=\s*"([^"]*)""#
        if let regex = try? NSRegularExpression(pattern: quotedPattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: headerValue, range: NSRange(headerValue.startIndex..., in: headerValue)),
           let range = Range(match.range(at: 1), in: headerValue) {
            return String(headerValue[range])
        }
        let unquotedPattern = #"(?:^|[;\s])"# + NSRegularExpression.escapedPattern(for: param) + #"\s*=\s*([^;\s]+)"#
        if let regex = try? NSRegularExpression(pattern: unquotedPattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: headerValue, range: NSRange(headerValue.startIndex..., in: headerValue)),
           let range = Range(match.range(at: 1), in: headerValue) {
            return String(headerValue[range])
        }
        return nil
    }

    /// Mappe un nom de jeu de caractères vers String.Encoding.
    static func stringEncoding(from charsetName: String?) -> String.Encoding {
        guard let name = charsetName?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .utf8
        }
        if name.contains("utf-8") || name.contains("utf8") { return .utf8 }
        if name.contains("iso-8859-1") || name.contains("latin1") { return .isoLatin1 }
        if name.contains("windows-1252") || name.contains("cp1252") { return .windowsCP1252 }
        if name.contains("ascii") || name.contains("us-ascii") { return .ascii }
        if name.contains("utf-16le") { return .utf16LittleEndian }
        if name.contains("utf-16be") { return .utf16BigEndian }
        if name.contains("utf-16") { return .utf16 }
        return .utf8
    }

    /// Décode un flux quoted-printable selon le jeu de caractères spécifié.
    static func decodeQuotedPrintable(_ data: Data, encoding: String.Encoding) -> String? {
        let outData = quotedPrintableBytes(data)
        return String(data: outData, encoding: encoding)
            ?? String(data: outData, encoding: .utf8)
            ?? String(data: outData, encoding: .isoLatin1)
    }

    /// Les OCTETS d'un flux quoted-printable — la moitié du décodage qui ne
    /// dépend d'aucun jeu de caractères, partagée avec les pièces jointes
    /// (une pièce est binaire : la décoder en `String` la détruirait).
    static func quotedPrintableBytes(_ data: Data) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count)
        let count = data.count
        var i = 0

        while i < count {
            let b = data[i]
            if b == 0x3D { // '='
                if i + 1 < count && data[i + 1] == 0x0A { // =\n
                    i += 2
                    continue
                } else if i + 2 < count && data[i + 1] == 0x0D && data[i + 2] == 0x0A { // =\r\n
                    i += 3
                    continue
                } else if i + 2 < count {
                    let c1 = data[i + 1]
                    let c2 = data[i + 2]
                    if let h1 = hexVal(c1), let h2 = hexVal(c2) {
                        bytes.append((h1 << 4) | h2)
                        i += 3
                        continue
                    }
                }
            }
            bytes.append(b)
            i += 1
        }
        return Data(bytes)
    }

    private static func hexVal(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30        // 0-9
        case 0x41...0x46: return c - 0x41 + 10   // A-F
        case 0x61...0x66: return c - 0x61 + 10   // a-f
        default: return nil
        }
    }

    /// Décode le corps ou une partie de message selon le Content-Transfer-Encoding.
    static func decodeContent(data: Data, transferEncoding: String, charset: String?) -> String? {
        let enc = stringEncoding(from: charset)
        let lowerEncoding = transferEncoding.lowercased().trimmingCharacters(in: .whitespaces)

        if lowerEncoding.contains("quoted-printable") {
            return decodeQuotedPrintable(data, encoding: enc)
        } else if lowerEncoding.contains("base64") {
            if let str = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .utf8),
               let base64Data = Data(base64Encoded: str, options: [.ignoreUnknownCharacters]) {
                return String(data: base64Data, encoding: enc)
                    ?? String(data: base64Data, encoding: .utf8)
                    ?? String(data: base64Data, encoding: .isoLatin1)
            }
            return nil
        } else {
            if let str = String(data: data, encoding: enc) {
                return str
            }
            // SANS URL (lot MN1) : ces octets sont une PARTIE du message, dont
            // le jeu de caractères est déclaré par ses propres en-têtes MIME
            // (`charset`, lu juste au-dessus). L'attribut `com.apple.TextEncoding`
            // du fichier `.eml` décrit l'enveloppe, pas cette partie.
            return PlainTextExtractor.decode(data)
        }
    }

    /// Décode les mots encodés RFC 2047 (=?charset?B/Q?...?=).
    static func decodeMIMEWords(_ input: String) -> String {
        guard input.contains("=?") else { return input }

        let adjacentPattern = #"(\=\?[^?]+\?[bBqQ]\?[^?]*\?\=)\s+(?=\=\?[^?]+\?[bBqQ]\?[^?]*\?\=)"#
        let cleanedInput: String
        if let adjRegex = try? NSRegularExpression(pattern: adjacentPattern) {
            cleanedInput = adjRegex.stringByReplacingMatches(
                in: input,
                range: NSRange(input.startIndex..., in: input),
                withTemplate: "$1"
            )
        } else {
            cleanedInput = input
        }

        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return cleanedInput }
        let nsString = cleanedInput as NSString
        let matches = regex.matches(in: cleanedInput, range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return cleanedInput }

        var result = ""
        var lastIndex = 0

        for match in matches {
            if match.range.location > lastIndex {
                result += nsString.substring(with: NSRange(location: lastIndex, length: match.range.location - lastIndex))
            }
            let charset = nsString.substring(with: match.range(at: 1))
            let encType = nsString.substring(with: match.range(at: 2)).lowercased()
            let encodedText = nsString.substring(with: match.range(at: 3))
            let encoding = stringEncoding(from: charset)

            var decoded: String? = nil
            if encType == "b" {
                if let data = Data(base64Encoded: encodedText) {
                    decoded = String(data: data, encoding: encoding)
                        ?? String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1)
                }
            } else if encType == "q" {
                var bytes = [UInt8]()
                var i = encodedText.startIndex
                while i < encodedText.endIndex {
                    let c = encodedText[i]
                    if c == "_" {
                        bytes.append(0x20)
                        i = encodedText.index(after: i)
                    } else if c == "=" {
                        if let next2 = encodedText.index(i, offsetBy: 3, limitedBy: encodedText.endIndex) {
                            let hexStart = encodedText.index(after: i)
                            let hexStr = String(encodedText[hexStart..<next2])
                            if let b = UInt8(hexStr, radix: 16) {
                                bytes.append(b)
                                i = next2
                                continue
                            }
                        }
                        bytes.append(UInt8(ascii: "="))
                        i = encodedText.index(after: i)
                    } else {
                        if let ascii = c.asciiValue {
                            bytes.append(ascii)
                        }
                        i = encodedText.index(after: i)
                    }
                }
                let data = Data(bytes)
                decoded = String(data: data, encoding: encoding)
                    ?? String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
            }

            result += decoded ?? nsString.substring(with: match.range)
            lastIndex = match.range.location + match.range.length
        }

        if lastIndex < nsString.length {
            result += nsString.substring(with: NSRange(location: lastIndex, length: nsString.length - lastIndex))
        }

        return result
    }

    /// Extrait le corps d'un message complet selon son type MIME, et ses pièces
    /// jointes si on les demande.
    static func extractBody(headers: [String: String], bodyData: Data,
                            attachments collect: Bool = false)
        -> (text: String?, attachments: [EMLAttachment]) {
        let contentType = headers["content-type"] ?? "text/plain"
        let lowerCT = contentType.lowercased()

        if lowerCT.contains("multipart/") {
            guard let boundary = extractParameter(named: "boundary", from: contentType) else {
                return (nil, [])
            }
            return extractMultipart(boundary: boundary, bodyData: bodyData,
                                    attachments: collect)
        }
        return (singlePartBody(headers: headers, bodyData: bodyData,
                               contentType: contentType), [])
    }

    /// Le corps d'un message qui n'est pas multipart — la voie d'avant les
    /// pièces jointes, inchangée.
    private static func singlePartBody(headers: [String: String], bodyData: Data,
                                       contentType: String) -> String? {
        let lowerCT = contentType.lowercased()
        if lowerCT.contains("text/html") {
            let encoding = headers["content-transfer-encoding"]?.lowercased() ?? "7bit"
            let charset = extractParameter(named: "charset", from: contentType)
            guard let decoded = decodeContent(data: bodyData, transferEncoding: encoding, charset: charset) else {
                return nil
            }
            return HTMLText.plainText(from: decoded)
        } else {
            let encoding = headers["content-transfer-encoding"]?.lowercased() ?? "7bit"
            let charset = extractParameter(named: "charset", from: contentType)
            return decodeContent(data: bodyData, transferEncoding: encoding, charset: charset)
        }
    }

    /// Parcourt les sous-parties d'un conteneur multipart en extrayant le texte,
    /// et les pièces jointes quand on les demande.
    static func extractMultipart(boundary: String, bodyData: Data,
                                 attachments collect: Bool = false)
        -> (text: String?, attachments: [EMLAttachment]) {
        let delimiter = "--" + boundary
        guard let bodyString = String(data: bodyData, encoding: .isoLatin1) else {
            return (nil, [])
        }

        let parts = bodyString.components(separatedBy: delimiter)
        var plainTexts: [String] = []
        var htmlTexts: [String] = []
        var attachments: [EMLAttachment] = []

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "--" { continue }

            guard let partData = part.data(using: .isoLatin1) else { continue }
            let (rawHeaders, partBodyData) = splitHeaderAndBody(partData)
            let partHeaders = parseHeaders(rawHeaders)
            let partCT = (partHeaders["content-type"] ?? "text/plain").lowercased()

            if partCT.contains("multipart/") {
                if let subBoundary = extractParameter(named: "boundary", from: partHeaders["content-type"] ?? "") {
                    let sub = extractMultipart(boundary: subBoundary,
                                               bodyData: partBodyData,
                                               attachments: collect)
                    if let subText = sub.text { plainTexts.append(subText) }
                    attachments += sub.attachments
                }
                continue
            }

            // La PIÈCE JOINTE se décide avant le texte : une partie
            // `text/plain; filename="notes.txt"` en `Content-Disposition:
            // attachment` est une pièce, pas la suite du corps.
            if collect, let piece = attachment(headers: partHeaders,
                                               bodyData: partBodyData) {
                attachments.append(piece)
                continue
            }

            if partCT.contains("text/html") {
                let encoding = partHeaders["content-transfer-encoding"]?.lowercased() ?? "7bit"
                let charset = extractParameter(named: "charset", from: partHeaders["content-type"] ?? "")
                if let decoded = decodeContent(data: partBodyData, transferEncoding: encoding, charset: charset) {
                    let plain = HTMLText.plainText(from: decoded).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !plain.isEmpty {
                        htmlTexts.append(plain)
                    }
                }
            } else if partCT.contains("text/plain") || !partCT.contains("/") {
                let encoding = partHeaders["content-transfer-encoding"]?.lowercased() ?? "7bit"
                let charset = extractParameter(named: "charset", from: partHeaders["content-type"] ?? "")
                if let decoded = decodeContent(data: partBodyData, transferEncoding: encoding, charset: charset) {
                    let plain = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !plain.isEmpty {
                        plainTexts.append(plain)
                    }
                }
            }
        }

        if !plainTexts.isEmpty {
            return (plainTexts.joined(separator: "\n\n"), attachments)
        } else if !htmlTexts.isEmpty {
            return (htmlTexts.joined(separator: "\n\n"), attachments)
        }
        return (nil, attachments)
    }

    // MARK: - Pièces jointes (EX1, C2-15)

    /// La pièce jointe d'une partie de courriel, ou `nil` si cette partie n'en
    /// est pas une.
    ///
    /// Une partie est une pièce jointe si son `Content-Disposition` porte
    /// `attachment`, ou si son type n'est ni `text/*` ni `multipart/*` et qu'elle
    /// porte un `name=` / `filename=`. Un nom est INDISPENSABLE : c'est
    /// l'extension qui décide de l'extracteur, et une partie anonyme reste
    /// traitée comme avant (repliée dans le corps si elle est du texte, ignorée
    /// sinon).
    static func attachment(headers: [String: String], bodyData: Data)
        -> EMLAttachment? {
        let contentType = headers["content-type"] ?? "text/plain"
        let lowerCT = contentType.lowercased()
        if lowerCT.contains("multipart/") { return nil }

        let disposition = headers["content-disposition"] ?? ""
        let isAttachment = disposition.lowercased().contains("attachment")
        let isText = lowerCT.hasPrefix("text/") || !lowerCT.contains("/")
        let isMessage = lowerCT.contains("message/rfc822")
        guard isAttachment || isMessage || !isText else { return nil }

        let raw = extractParameter(named: "filename", from: disposition)
            ?? extractParameter(named: "name", from: contentType)
        // Un `message/rfc822` sans nom garde le sien : ses en-têtes `Subject:`
        // et `From:` ouvrent déjà sa première page.
        guard let raw else { return isMessage ? nestedMessage(bodyData: bodyData,
                                                              headers: headers,
                                                              name: "") : nil }
        let name = MailAttachments.sanitized(name: decodeMIMEWords(raw))

        if isMessage || MailAttachments.isMail(name: name) {
            return nestedMessage(bodyData: bodyData, headers: headers, name: name)
        }
        // Le refus se décide sur le NOM, avant tout décodage.
        guard MailAttachments.isReadable(name: name) else {
            return EMLAttachment(name: name, payload: .unread)
        }
        let encoding = headers["content-transfer-encoding"] ?? "7bit"
        guard let bytes = decodeBinaryContent(data: bodyData,
                                              transferEncoding: encoding) else {
            return nil
        }
        return EMLAttachment(name: name, payload: .file(bytes))
    }

    /// Un courriel joint, rendu DANS le processus : ses en-têtes et son corps,
    /// et rien de plus — ses propres pièces ne sont pas suivies (`attachments:
    /// false`). C'est la borne de profondeur : elle vaut un.
    private static func nestedMessage(bodyData: Data, headers: [String: String],
                                      name: String) -> EMLAttachment? {
        let encoding = headers["content-transfer-encoding"] ?? "7bit"
        guard let bytes = decodeBinaryContent(data: bodyData,
                                              transferEncoding: encoding) else {
            return nil
        }
        let framed = MailAttachments.fileExtension(of: name) == "emlx"
            ? EMLXFraming.message(in: bytes)
            : bytes
        let texts: [String]
        if MailboxExtractor.supportedExtensions.contains(
            MailAttachments.fileExtension(of: name)) {
            // Une boîte jointe : un texte par message, comme le fait
            // `MailboxExtractor` (une page par message).
            texts = MailboxExtractor.split(framed).map {
                EMLExtractor.render(EMLParser.parse(data: $0, attachments: false)).text
            }
        } else {
            texts = [EMLExtractor.render(
                EMLParser.parse(data: framed, attachments: false)).text]
        }
        let text = texts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !text.isEmpty else { return nil }
        return EMLAttachment(name: name, payload: .message(text))
    }

    /// Les OCTETS d'une partie, décodés selon son `Content-Transfer-Encoding`.
    ///
    /// `decodeContent` rend une CHAÎNE : elle convient au texte et détruirait un
    /// PDF. Le décodage d'octets est donc une fonction à part, et le
    /// quoted-printable leur est commun (`quotedPrintableBytes`).
    static func decodeBinaryContent(data: Data, transferEncoding: String) -> Data? {
        let encoding = transferEncoding.lowercased()
            .trimmingCharacters(in: .whitespaces)
        if encoding.contains("base64") {
            guard let ascii = String(data: data, encoding: .ascii)
                    ?? String(data: data, encoding: .isoLatin1) else { return nil }
            return Data(base64Encoded: ascii, options: [.ignoreUnknownCharacters])
        }
        if encoding.contains("quoted-printable") {
            return quotedPrintableBytes(data)
        }
        // 7bit, 8bit, binary : les octets tels quels. La partie est arrivée
        // ici par un aller-retour ISO-8859-1, qui préserve les 256 valeurs.
        return data
    }
}
