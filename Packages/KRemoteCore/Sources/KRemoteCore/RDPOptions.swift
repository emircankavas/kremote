import Foundation

/// How the remote desktop is sized against the pane it is shown in.
///
/// Mirrors mRemoteNG's `Resolution` property. The legacy fixed pixel sizes
/// (`Res1366x768` and friends) were removed upstream; a bare pixel size that
/// turns up in an old file is kept as `.custom` rather than dropped.
public enum RDPResolutionMode: String, Codable, Sendable, CaseIterable {
    case smartSize = "SmartSize"
    case fitToWindow = "FitToWindow"
    case fullscreen = "Fullscreen"
    /// Connect at an explicit size (`customWidth` × `customHeight`).
    case custom = "Custom"

    public var displayName: String {
        switch self {
        case .smartSize: return "Smart size"
        case .fitToWindow: return "Fit to panel"
        case .fullscreen: return "Fullscreen"
        case .custom: return "Custom"
        }
    }

    /// Parses a value out of an mRemoteNG `Resolution` attribute.
    ///
    /// Accepts the mode names as well as any pixel size (`1920x1080`, and the
    /// `Res1920x1080` spelling older files used).
    public init(mRemoteNG raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = RDPResolutionMode(rawValue: value) {
            self = exact
            return
        }
        switch value.lowercased() {
        case "fittowindow", "fittopanel":
            self = .fitToWindow
        case "fullscreen":
            self = .fullscreen
        case "smartsize", "":
            self = .smartSize
        default:
            self = RDPResolutionMode.parsePixelSize(value) != nil ? .custom : .smartSize
        }
    }

    /// Reads `1920x1080` (or `Res1920x1080`) into a width/height pair.
    public static func parsePixelSize(_ string: String) -> (width: Int, height: Int)? {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("res") { text = String(text.dropFirst(3)) }
        let parts = text.split(separator: "x", omittingEmptySubsequences: true)
        guard parts.count == 2,
              let width = Int(parts[0]), let height = Int(parts[1]),
              width > 0, height > 0 else { return nil }
        return (width, height)
    }
}

/// How the remote desktop's pixel grid relates to the pane it is shown in.
///
/// The RDP desktop used to be requested in *backing* pixels (2× on a Retina
/// display) while the server was told the scale factor was 100%, so Windows
/// rendered a 1× UI into a 2× surface: correct on a normal monitor, unreadable
/// on a MacBook. The fix is a choice, because the two goals conflict:
///
///  * `.matchDisplay` — the desktop is the pane's size in *points*, so Windows'
///    100% UI has exactly the physical size it has on a 1× display. Text is
///    displayed 1:1 in points and is perfectly readable; on a Retina panel the
///    image is upscaled 2× by the compositor, so it is not pixel-sharp.
///  * `.native` — the desktop is the pane's size in backing pixels and the
///    server is told to render at 180% (the largest value the Display Control
///    channel accepts). Text is drawn by Windows at 1.8× and shown at half size:
///    crisp, and still readable (0.9× of a normal display's text).
public enum RDPDesktopMode: String, Codable, Sendable, CaseIterable {
    case matchDisplay = "MatchDisplay"
    case native = "Native"

    public var displayName: String {
        switch self {
        case .matchDisplay: return "Match panel (readable)"
        case .native: return "Native pixels (crisp)"
        }
    }

    /// The scale factor announced to the server. Display Control only accepts
    /// 100, 140 and 180 — anything else makes the client core data invalid.
    public var wireScaleFactor: Int {
        switch self {
        case .matchDisplay: return 100
        case .native: return 180
        }
    }
}

/// RDP-specific overrides set directly on a node.
///
/// Every field is optional and `nil` means "inherit from the parent folder",
/// exactly like an empty string or port `0` elsewhere in the tree. That lets a
/// folder carry the appearance/redirection defaults its connections share.
public struct RDPSettings: Equatable, Sendable, Codable {
    /// Windows domain (or `DOMAIN\user` split off by the editor).
    public var domain: String?
    public var resolution: RDPResolutionMode?
    public var customWidth: Int?
    public var customHeight: Int?
    /// Colour depth in bits: 8, 16, 24 or 32.
    public var colorDepth: Int?
    public var redirectClipboard: Bool?
    public var redirectDrives: Bool?
    public var redirectPrinters: Bool?
    public var redirectSound: Bool?
    public var redirectKeys: Bool?
    /// How the desktop maps onto the pane's pixels (Retina readability).
    public var desktopMode: RDPDesktopMode?
    /// Reverses the RDP wheel direction on top of macOS' own scroll setting.
    public var invertScroll: Bool?

    public init(
        domain: String? = nil,
        resolution: RDPResolutionMode? = nil,
        customWidth: Int? = nil,
        customHeight: Int? = nil,
        colorDepth: Int? = nil,
        redirectClipboard: Bool? = nil,
        redirectDrives: Bool? = nil,
        redirectPrinters: Bool? = nil,
        redirectSound: Bool? = nil,
        redirectKeys: Bool? = nil,
        desktopMode: RDPDesktopMode? = nil,
        invertScroll: Bool? = nil
    ) {
        self.domain = domain
        self.resolution = resolution
        self.customWidth = customWidth
        self.customHeight = customHeight
        self.colorDepth = colorDepth
        self.redirectClipboard = redirectClipboard
        self.redirectDrives = redirectDrives
        self.redirectPrinters = redirectPrinters
        self.redirectSound = redirectSound
        self.redirectKeys = redirectKeys
        self.desktopMode = desktopMode
        self.invertScroll = invertScroll
    }

    /// True when nothing is set, so `nil` folders are not written to disk.
    public var isEmpty: Bool { self == RDPSettings() }

    private enum CodingKeys: String, CodingKey {
        case domain, resolution, customWidth, customHeight, colorDepth
        case redirectClipboard, redirectDrives, redirectPrinters, redirectSound, redirectKeys
        case desktopMode, invertScroll
    }

    /// Only the fields that are actually set are written, keeping the JSON (and
    /// the confCons round-trip) free of noise.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(domain, forKey: .domain)
        try container.encodeIfPresent(resolution, forKey: .resolution)
        try container.encodeIfPresent(customWidth, forKey: .customWidth)
        try container.encodeIfPresent(customHeight, forKey: .customHeight)
        try container.encodeIfPresent(colorDepth, forKey: .colorDepth)
        try container.encodeIfPresent(redirectClipboard, forKey: .redirectClipboard)
        try container.encodeIfPresent(redirectDrives, forKey: .redirectDrives)
        try container.encodeIfPresent(redirectPrinters, forKey: .redirectPrinters)
        try container.encodeIfPresent(redirectSound, forKey: .redirectSound)
        try container.encodeIfPresent(redirectKeys, forKey: .redirectKeys)
        try container.encodeIfPresent(desktopMode, forKey: .desktopMode)
        try container.encodeIfPresent(invertScroll, forKey: .invertScroll)
    }

    /// Tolerant decode: a malformed `resolution` falls back to the mode names'
    /// own spelling, and any casing is accepted (the file may have been written
    /// by hand or by an older build).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.domain = try container.decodeIfPresent(String.self, forKey: .domain)
        if let raw = try container.decodeIfPresent(String.self, forKey: .resolution) {
            self.resolution = RDPResolutionMode(mRemoteNG: raw)
        } else {
            self.resolution = nil
        }
        self.customWidth = try container.decodeIfPresent(Int.self, forKey: .customWidth)
        self.customHeight = try container.decodeIfPresent(Int.self, forKey: .customHeight)
        self.colorDepth = try container.decodeIfPresent(Int.self, forKey: .colorDepth)
        self.redirectClipboard = try container.decodeIfPresent(Bool.self, forKey: .redirectClipboard)
        self.redirectDrives = try container.decodeIfPresent(Bool.self, forKey: .redirectDrives)
        self.redirectPrinters = try container.decodeIfPresent(Bool.self, forKey: .redirectPrinters)
        self.redirectSound = try container.decodeIfPresent(Bool.self, forKey: .redirectSound)
        self.redirectKeys = try container.decodeIfPresent(Bool.self, forKey: .redirectKeys)
        // Decoded leniently: a value written by a newer build must degrade to
        // "inherit" rather than failing the whole settings block.
        self.desktopMode = (try? container.decodeIfPresent(RDPDesktopMode.self, forKey: .desktopMode)) ?? nil
        self.invertScroll = try container.decodeIfPresent(Bool.self, forKey: .invertScroll)
    }
}

/// The resolved RDP settings of a node, after inheritance is folded in.
public struct RDPOptions: Equatable, Sendable {
    public var domain: String
    public var resolution: RDPResolutionMode
    public var customWidth: Int
    public var customHeight: Int
    /// 8, 16, 24 or 32.
    public var colorDepth: Int
    public var redirectClipboard: Bool
    public var redirectDrives: Bool
    public var redirectPrinters: Bool
    public var redirectSound: Bool
    public var redirectKeys: Bool
    /// Retina readability: panel-sized desktop at 100%, or backing-pixel desktop
    /// at 180%.
    public var desktopMode: RDPDesktopMode
    /// Reverses the wheel direction on top of whatever macOS's "natural
    /// scrolling" setting already does.
    public var invertScroll: Bool

    public init(
        domain: String = "",
        resolution: RDPResolutionMode = .smartSize,
        customWidth: Int = 1920,
        customHeight: Int = 1080,
        colorDepth: Int = 32,
        redirectClipboard: Bool = true,
        redirectDrives: Bool = false,
        redirectPrinters: Bool = false,
        redirectSound: Bool = true,
        redirectKeys: Bool = false,
        desktopMode: RDPDesktopMode = .matchDisplay,
        invertScroll: Bool = false
    ) {
        self.domain = domain
        self.resolution = resolution
        self.customWidth = customWidth
        self.customHeight = customHeight
        self.colorDepth = colorDepth
        self.redirectClipboard = redirectClipboard
        self.redirectDrives = redirectDrives
        self.redirectPrinters = redirectPrinters
        self.redirectSound = redirectSound
        self.redirectKeys = redirectKeys
        self.desktopMode = desktopMode
        self.invertScroll = invertScroll
    }

    /// What a root node starts from before any folder contributes.
    public static let `default` = RDPOptions()

    /// `DOMAIN\user` as Windows clients spell it, or just the user when no
    /// domain resolved.
    public func qualifiedUser(_ username: String) -> String {
        let domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domain.isEmpty, !username.isEmpty else { return username }
        // A `user@domain` style name already carries its realm.
        if username.contains("@") { return username }
        return "\(domain)\\\(username)"
    }

    /// The desktop size to request, or nil when the client decides (fullscreen
    /// and fit-to-panel negotiate against the pane).
    public var explicitDesktopSize: (width: Int, height: Int)? {
        switch resolution {
        case .custom: return (max(640, customWidth), max(480, customHeight))
        case .fullscreen, .fitToWindow, .smartSize: return nil
        }
    }

    /// The desktop to ask the server for, given the pane's size in points and the
    /// display's backing scale, plus the scale factor to announce with it.
    ///
    /// `desktopMode` is the whole point of this function: the pane's *points* are
    /// what Windows' 100% UI should occupy, and the backing pixels are how many of
    /// them the panel really has. Requesting backing pixels while announcing 100%
    /// is the combination that made a Retina MacBook unreadable.
    ///
    /// An explicit custom size is honoured exactly and never multiplied: the user
    /// named a pixel count, so guessing a scale on top of it would contradict it.
    public func desktopRequest(
        panePoints: CGSize,
        backingScale: CGFloat
    ) -> (width: Int, height: Int, scaleFactor: Int) {
        if let explicit = explicitDesktopSize {
            return (explicit.width, explicit.height, 100)
        }
        let scale = backingScale > 0 ? backingScale : 1
        let points = (max(1, Int(panePoints.width.rounded())), max(1, Int(panePoints.height.rounded())))
        switch desktopMode {
        case .matchDisplay:
            return (points.0, points.1, 100)
        case .native:
            // On a 1x display "native" and "match display" are the same grid, and
            // announcing 180% there would blow the UI up for nothing. Only a
            // genuinely high-density panel gets the doubled grid.
            guard scale >= 1.5 else { return (points.0, points.1, 100) }
            return (Int((Double(points.0) * scale).rounded()),
                    Int((Double(points.1) * scale).rounded()),
                    RDPDesktopMode.native.wireScaleFactor)
        }
    }

    /// Folds `settings` over what was inherited; a `nil` field keeps `base`.
    public func merging(_ settings: RDPSettings) -> RDPOptions {
        var merged = self
        if let domain = settings.domain, !domain.isEmpty { merged.domain = domain }
        if let resolution = settings.resolution { merged.resolution = resolution }
        if let width = settings.customWidth, width > 0 { merged.customWidth = width }
        if let height = settings.customHeight, height > 0 { merged.customHeight = height }
        if let depth = settings.colorDepth, depth > 0 { merged.colorDepth = depth }
        if let value = settings.redirectClipboard { merged.redirectClipboard = value }
        if let value = settings.redirectDrives { merged.redirectDrives = value }
        if let value = settings.redirectPrinters { merged.redirectPrinters = value }
        if let value = settings.redirectSound { merged.redirectSound = value }
        if let value = settings.redirectKeys { merged.redirectKeys = value }
        if let mode = settings.desktopMode { merged.desktopMode = mode }
        if let value = settings.invertScroll { merged.invertScroll = value }
        return merged
    }

    /// One-line description for the editor footer and the pane status bar.
    public var summary: String {
        var parts = ["\(resolution.displayName)", "\(colorDepth)-bit"]
        if desktopMode != .matchDisplay { parts.append(desktopMode.displayName) }
        if resolution == .custom { parts[0] = "\(resolution.displayName) \(customWidth)×\(customHeight)" }
        var redirects: [String] = []
        if redirectClipboard { redirects.append("clipboard") }
        if redirectDrives { redirects.append("drives") }
        if redirectPrinters { redirects.append("printers") }
        if redirectSound { redirects.append("sound") }
        if redirectKeys { redirects.append("keys") }
        if !redirects.isEmpty { parts.append(redirects.joined(separator: ", ")) }
        if !domain.isEmpty { parts.append("domain \(domain)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - mRemoteNG spellings

extension RDPSettings {
    /// Reads mRemoteNG's RDP attributes off a `<Node>`. Case is already
    /// canonicalised by the importer; unknown values fall back to `nil`
    /// (inherit) so a file with an exotic setting still imports.
    public static func fromConfConsAttributes(_ attributes: [String: String]) -> RDPSettings {
        var settings = RDPSettings()

        let domain = attributes["Domain"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !domain.isEmpty { settings.domain = domain }

        if let rawResolution = attributes["Resolution"], !rawResolution.isEmpty {
            settings.resolution = RDPResolutionMode(mRemoteNG: rawResolution)
            if settings.resolution == .custom,
               let size = RDPResolutionMode.parsePixelSize(rawResolution) {
                settings.customWidth = size.width
                settings.customHeight = size.height
            } else if settings.resolution == .custom,
                      let width = Int(attributes["ResolutionWidth"] ?? ""),
                      let height = Int(attributes["ResolutionHeight"] ?? "") {
                settings.customWidth = width
                settings.customHeight = height
            }
        }

        if let depth = Self.colorDepth(fromConfCons: attributes["Colors"]) {
            settings.colorDepth = depth
        }

        settings.redirectClipboard = Self.bool(fromConfCons: attributes["RedirectClipboard"])
        settings.redirectDrives = Self.bool(fromConfCons: attributes["RedirectDrives"])
        settings.redirectPrinters = Self.bool(fromConfCons: attributes["RedirectPrinters"])
        // mRemoteNG writes `RedirectSound` in some versions and `RedirectAudio`
        // in others, both as a boolean.
        settings.redirectSound = Self.bool(fromConfCons: attributes["RedirectSound"])
            ?? Self.bool(fromConfCons: attributes["RedirectAudio"])
        settings.redirectKeys = Self.bool(fromConfCons: attributes["RedirectKeys"])
        // No mRemoteNG attribute exists for these two; they are KRemote's own and
        // are written with KRemote* keys so a round-trip through mRemoteNG does not
        // silently reset them to the default.
        if let raw = attributes["KRemoteDesktopMode"] {
            settings.desktopMode = RDPDesktopMode(rawValue: raw)
        }
        settings.invertScroll = Self.bool(fromConfCons: attributes["KRemoteInvertScroll"])

        return settings
    }

    /// mRemoteNG writes the colour depth as `32bit`, `24bit`, … (older files
    /// used a bare number).
    static func colorDepth(fromConfCons raw: String?) -> Int? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        let digits = value.hasSuffix("bit") ? String(value.dropLast(3)) : value
        guard let depth = Int(digits), [8, 16, 24, 32].contains(depth) else { return nil }
        return depth
    }

    /// mRemoteNG booleans are `"true"` / `"false"`; empty means "not set".
    static func bool(fromConfCons raw: String?) -> Bool? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// The attributes to write back out, so `ConfConsSerializer` round-trips
    /// what the importer read.
    public var confConsAttributes: [(String, String)] {
        var attributes: [(String, String)] = []
        if let domain, !domain.isEmpty { attributes.append(("Domain", domain)) }
        if let resolution {
            switch resolution {
            case .custom:
                let width = customWidth ?? 1920
                let height = customHeight ?? 1080
                attributes.append(("Resolution", "\(width)x\(height)"))
            default:
                attributes.append(("Resolution", resolution.rawValue))
            }
        }
        if let colorDepth { attributes.append(("Colors", "\(colorDepth)bit")) }
        if let redirectClipboard { attributes.append(("RedirectClipboard", "\(redirectClipboard)")) }
        if let redirectDrives { attributes.append(("RedirectDrives", "\(redirectDrives)")) }
        if let redirectPrinters { attributes.append(("RedirectPrinters", "\(redirectPrinters)")) }
        if let redirectSound { attributes.append(("RedirectSound", "\(redirectSound)")) }
        if let redirectKeys { attributes.append(("RedirectKeys", "\(redirectKeys)")) }
        if let desktopMode { attributes.append(("KRemoteDesktopMode", desktopMode.rawValue)) }
        if let invertScroll { attributes.append(("KRemoteInvertScroll", "\(invertScroll)")) }
        return attributes
    }
}
