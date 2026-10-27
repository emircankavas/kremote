import AppKit
import Foundation
import UniformTypeIdentifiers
import KRemoteCore

/// The drag type for a connection-tree node.
///
/// A dedicated type, not `public.utf8-plain-text`: with a plain string, a drop
/// also accepts any text dragged from another app (a URL, a paragraph), and a
/// `List` row that advertises plain text competes with AppKit's own text
/// services — which is part of why dragging a sidebar row never started.
/// Declared in `Info.plist` as an exported type so the pasteboard carries a real
/// UTI rather than an unregistered string.
extension UTType {
    static let kremoteNode = UTType(exportedAs: "com.emircankavas.kremote.node")
}

/// The payload of one sidebar drag: the node ids, one per line.
///
/// Multiple ids so a future multi-selection drags as one operation, and so the
/// receiver never has to guess whether a newline is part of an id.
enum NodeDragPayload {
    static func encode(_ ids: [ConnectionNode.ID]) -> Data {
        Data(ids.map(\.uuidString).joined(separator: "\n").utf8)
    }

    static func decode(_ data: Data) -> [ConnectionNode.ID] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n")
            .compactMap { UUID(uuidString: String($0)) }
    }

    /// Builds the item provider for a drag that started on `dragged`.
    ///
    /// `ownProcess` visibility: the only legitimate receiver is this app's own
    /// sidebar, and restricting it stops the payload from being offered to other
    /// applications (where it would be meaningless ids).
    static func provider(for ids: [ConnectionNode.ID]) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.kremoteNode.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(encode(ids), nil)
            return nil
        }
        return provider
    }
}
