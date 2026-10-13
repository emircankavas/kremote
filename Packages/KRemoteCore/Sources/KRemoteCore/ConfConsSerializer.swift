import Foundation

/// Writes KRemote's connection tree back out as an mRemoteNG `confCons.xml`.
///
/// The output is a valid schema-2.6 file that mRemoteNG (and `ConfConsImporter`)
/// can read. Passwords are encrypted with `ConfConsCrypto`. Only the attributes
/// mRemoteNG needs to reconstruct the tree are emitted; the dozens of
/// RDP/VNC-specific attributes mRemoteNG writes are omitted, which it tolerates.
public enum ConfConsSerializer {

    public static func serialize(
        _ roots: [ConnectionNode],
        passphrase: String = ConfConsCrypto.defaultPassphrase,
        iterations: Int = ConfConsCrypto.defaultKdfIterations,
        confVersion: String = "2.6"
    ) throws -> String {
        let protectedField = try ConfConsCrypto.encrypt(
            ConfConsCrypto.notProtectedMarker,
            passphrase: passphrase,
            iterations: iterations
        )

        var out = """
        <?xml version="1.0" encoding="utf-8"?>
        <mrng:Connections xmlns:mrng="http://mremoteng.org" Name="Connections" Export="false" EncryptionEngine="AES" BlockCipherMode="GCM" KdfIterations="\(iterations)" FullFileEncryption="false" Protected="\(protectedField)" ConfVersion="\(confVersion)">
        """
        for node in roots {
            out += "\n" + element(for: node, passphrase: passphrase, iterations: iterations, indent: 1)
        }
        out += "\n</mrng:Connections>\n"
        return out
    }

    private static func element(
        for node: ConnectionNode,
        passphrase: String,
        iterations: Int,
        indent: Int
    ) -> String {
        let pad = String(repeating: "    ", count: indent)
        let type = node.isFolder ? "Container" : "Connection"

        var passwordField = ""
        if !node.isFolder, !node.password.isEmpty {
            passwordField = (try? ConfConsCrypto.encrypt(
                node.password,
                passphrase: passphrase,
                iterations: iterations
            )) ?? ""
        }

        var attributes: [(String, String)] = [
            ("Name", node.name),
            ("Type", type),
            ("Descr", ""),
            ("Icon", node.isFolder ? "mRemoteNG" : "Remote Desktop"),
            ("Panel", "General"),
            ("Id", node.id.uuidString),
            ("Username", node.username),
            ("Domain", ""),
            ("Password", passwordField),
            ("Hostname", node.host),
            ("Protocol", node.protocolName.isEmpty ? "SSH2" : node.protocolName),
            ("PuttySession", "Default Settings"),
            ("Port", String(node.port)),
        ]
        if node.isFolder { attributes.removeAll { $0.0 == "Password" } }

        let attrText = attributes.map { "\($0.0)=\"\(escape($0.1))\"" }.joined(separator: " ")

        guard !node.children.isEmpty else { return "\(pad)<Node \(attrText) />" }
        var out = "\(pad)<Node \(attrText) >"
        for child in node.children {
            out += "\n" + element(for: child, passphrase: passphrase, iterations: iterations, indent: indent + 1)
        }
        out += "\n\(pad)</Node>"
        return out
    }

    private static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }
}
