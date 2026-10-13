import Foundation

/// Reads mRemoteNG `confCons.xml` files into KRemote's connection tree.
///
/// The format is documented and independently reimplemented here (no mRemoteNG
/// code or assets are used). See `ConfConsCrypto` for the password scheme.
public enum ConfConsImporter {

    public struct ImportResult: Sendable {
        public var roots: [ConnectionNode]
        /// Node ids in `roots` mapped to their decrypted password, so the caller
        /// can push them into the Keychain.
        public var passwords: [UUID: String]
        public var version: String?
        public var kdfIterations: Int
        public var usedCustomPassphrase: Bool
    }

    public enum ImportError: Error, CustomStringConvertible {
        case notXML
        case missingRootElement
        case fullFileEncryptionUnsupported
        case wrongPassphrase
        case unsupportedCipher(String)

        public var description: String {
            switch self {
            case .notXML: return "File is not valid XML."
            case .missingRootElement: return "File has no <Connections> root element."
            case .fullFileEncryptionUnsupported:
                return "This file uses FullFileEncryption, which KRemote cannot import yet."
            case .wrongPassphrase:
                return "Wrong master passphrase for this file."
            case .unsupportedCipher(let mode):
                return "Unsupported cipher mode '\(mode)'. Only AES-GCM files are supported."
            }
        }
    }

    /// Passphrase resolution order: explicit argument, then mRemoteNG's default.
    public static func importTree(
        from data: Data,
        passphrase: String? = nil
    ) throws -> ImportResult {
        let delegate = RootAttributesDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let attributes = delegate.rootAttributes else {
            throw parser.parserError == nil ? ImportError.missingRootElement : ImportError.notXML
        }

        let iterations = Int(attributes["KdfIterations"] ?? "") ?? ConfConsCrypto.defaultKdfIterations
        let cipherMode = attributes["BlockCipherMode"] ?? "GCM"
        guard cipherMode.uppercased() == "GCM" else {
            throw ImportError.unsupportedCipher(cipherMode)
        }
        if (attributes["FullFileEncryption"] ?? "false").lowercased() == "true" {
            throw ImportError.fullFileEncryptionUnsupported
        }

        let protectedField = attributes["Protected"] ?? ""
        let resolvedPassphrase = passphrase ?? ConfConsCrypto.defaultPassphrase
        if !protectedField.isEmpty,
           !ConfConsCrypto.verifyPassphrase(resolvedPassphrase, protectedField: protectedField, iterations: iterations) {
            throw ImportError.wrongPassphrase
        }
        let usedCustom = passphrase != nil && passphrase != ConfConsCrypto.defaultPassphrase

        let roots = delegate.rootNodes.map { makeNode(from: $0, passphrase: resolvedPassphrase, iterations: iterations) }

        var passwords: [UUID: String] = [:]
        collectPasswords(in: roots, into: &passwords)

        return ImportResult(
            roots: roots,
            passwords: passwords,
            version: attributes["ConfVersion"],
            kdfIterations: iterations,
            usedCustomPassphrase: usedCustom
        )
    }

    // MARK: - Node conversion

    private static func makeNode(
        from parsed: ParsedNode,
        passphrase: String,
        iterations: Int
    ) -> ConnectionNode {
        // mRemoteNG: Type="Container" is a folder; everything else is a leaf.
        let isContainer = (parsed.attributes["Type"] ?? "Connection") == "Container"
        let id = parsed.attributes["Id"].flatMap(UUID.init(uuidString:)) ?? UUID()

        // Keep the node's *own* values only — blanks stay blank so KRemote's
        // inheritance resolves them from the parent folder, matching mRemoteNG.
        let name = parsed.attributes["Name"] ?? "Unnamed"
        let host = parsed.attributes["Hostname"] ?? ""
        let port = Int(parsed.attributes["Port"] ?? "") ?? 0
        let username = parsed.attributes["Username"] ?? ""
        let protocolName = parsed.attributes["Protocol"] ?? ""

        var password = ""
        if !isContainer, let field = parsed.attributes["Password"], !field.isEmpty {
            password = (try? ConfConsCrypto.decrypt(field, passphrase: passphrase, iterations: iterations))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }

        let children = parsed.children.map { makeNode(from: $0, passphrase: passphrase, iterations: iterations) }

        return ConnectionNode(
            id: id,
            kind: isContainer ? .folder : .connection,
            name: name,
            host: host,
            port: port,
            username: username,
            protocolName: protocolName,
            password: password,
            children: children
        )
    }

    private static func collectPasswords(in nodes: [ConnectionNode], into map: inout [UUID: String]) {
        for node in nodes {
            if !node.isFolder, !node.password.isEmpty { map[node.id] = node.password }
            collectPasswords(in: node.children, into: &map)
        }
    }
}

// MARK: - XML parsing

private final class ParsedNode {
    var attributes: [String: String] = [:]
    var children: [ParsedNode] = []
}

/// Minimal `XMLParser` delegate that reads the root `<Connections>` attributes and
/// builds the `<Node>` tree. Element and attribute names are matched
/// case-insensitively and with any namespace prefix stripped, because mRemoteNG
/// files vary (`Node` vs `mrng:Node`, `protected` on export).
private final class RootAttributesDelegate: NSObject, XMLParserDelegate {
    var rootAttributes: [String: String]?
    var rootNodes: [ParsedNode] = []

    private var stack: [ParsedNode] = []

    private static func localName(_ name: String) -> String {
        if let colon = name.lastIndex(of: ":") { return String(name[name.index(after: colon)...]) }
        return name
    }

    private static func canonicalAttributes(_ attributes: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in attributes {
            result[localName(key)] = value
        }
        return result
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let name = Self.localName(elementName)
        let attrs = Self.canonicalAttributes(attributeDict)

        if name.caseInsensitiveCompare("Connections") == .orderedSame, rootAttributes == nil {
            rootAttributes = attrs
            return
        }
        if name.caseInsensitiveCompare("Node") == .orderedSame {
            let node = ParsedNode()
            node.attributes = attrs
            if let parent = stack.last {
                parent.children.append(node)
            } else {
                rootNodes.append(node)
            }
            stack.append(node)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard Self.localName(elementName).caseInsensitiveCompare("Node") == .orderedSame else { return }
        if !stack.isEmpty { stack.removeLast() }
    }
}
