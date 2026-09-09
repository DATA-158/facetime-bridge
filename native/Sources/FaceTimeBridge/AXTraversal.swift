import AppKit
import ApplicationServices
import Foundation

let knownBundleIDs: Set<String> = [
    "com.apple.mobilephone",
    "com.apple.FaceTime",
    "com.apple.CoreServicesUIAgent",
    "com.apple.UIKitSystem",
    "com.apple.notificationcenterui",
]

let knownProcessNames: Set<String> = [
    "Phone",
    "FaceTime",
    "CoreServicesUIAgent",
    "UIKitSystem",
    "FaceTimeNotificationViewBridge",
    "FaceTimeNotificationExtension",
    "NotificationCenter",
    "Notification Center",
]

private let maximumNodesPerProcess = 400
private let maximumDepth = 12
// Menus are never call UI; pruning them keeps banner rows inside the node budget
// (found live: Answer at BFS index 194 behind ~150 menu nodes).
private let prunedRoles: Set<String> = [kAXMenuBarRole as String, kAXMenuRole as String, kAXMenuBarItemRole as String]
private let messagingTimeout: Float = 0.35

private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value
}

private func textAttribute(_ element: AXUIElement, _ attribute: CFString) -> String {
    guard let value = copyAttribute(element, attribute) else { return "" }
    if let string = value as? String { return String(string.prefix(240)) }
    if let number = value as? NSNumber { return String(number.stringValue.prefix(240)) }
    return ""
}

private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool {
    (copyAttribute(element, attribute) as? NSNumber)?.boolValue ?? false
}

private func actionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return names as? [String] ?? []
}

private func children(_ element: AXUIElement) -> [AXUIElement] {
    copyAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
}

private func readNode(_ element: AXUIElement, parentIndex: Int?) -> AXNode {
    AXNode(
        element: element,
        role: textAttribute(element, kAXRoleAttribute as CFString),
        identifier: textAttribute(element, kAXIdentifierAttribute as CFString),
        title: textAttribute(element, kAXTitleAttribute as CFString),
        description: textAttribute(element, kAXDescriptionAttribute as CFString),
        value: textAttribute(element, kAXValueAttribute as CFString),
        help: textAttribute(element, kAXHelpAttribute as CFString),
        enabled: boolAttribute(element, kAXEnabledAttribute as CFString),
        actions: actionNames(element),
        parentIndex: parentIndex,
        frame: frameAttribute(element)
    )
}

/// kAXPositionAttribute (top-left, global screen points) + kAXSizeAttribute.
/// Returns nil when either half is unreadable — a partial frame would be a
/// lie that cliclick turns into a misaimed click.
private func frameAttribute(_ element: AXUIElement) -> Frame? {
    guard let position = copyAttribute(element, kAXPositionAttribute as CFString),
          let size = copyAttribute(element, kAXSizeAttribute as CFString) else { return nil }
    var origin: CGPoint = .zero
    var dimensions: CGSize = .zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
    return Frame(
        x: Double(origin.x),
        y: Double(origin.y),
        w: Double(dimensions.width),
        h: Double(dimensions.height)
    )
}

private struct DiscoveredApp {
    let pid: pid_t
    let executablePath: String
    let bundleID: String
    let name: String
}

// Bundle-ID resolution cache keyed by executable path (paths are stable for a
// running process; one-time NSBundle read per distinct binary). Swift 6
// concurrency: lock-protected global mutable state needs a final wrapper type.
private final class BundleIDCache: @unchecked Sendable {
    static let shared = BundleIDCache()
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    func value(for path: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = storage[path] { return cached }
        var bundleID = ""
        // ".../FaceTime.app/Contents/MacOS/FaceTime" → ".../FaceTime.app"
        var url = URL(fileURLWithPath: path)
        for _ in 0..<4 {
            url.deleteLastPathComponent()
            if let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier {
                bundleID = identifier
                break
            }
        }
        if bundleID.isEmpty {
            bundleID = nameToBundleID[(path as NSString).lastPathComponent] ?? ""
        }
        storage[path] = bundleID
        return bundleID
    }

    private init() {}
}

// Fallback for processes whose executable has no enclosing .app bundle
// (e.g. /usr/libexec/NotificationCenter): NSWorkspace used to supply these
// bundle IDs; now the classifier depends on getting the exact same values.
private let nameToBundleID: [String: String] = [
    "Phone": "com.apple.mobilephone",
    "FaceTime": "com.apple.FaceTime",
    "NotificationCenter": "com.apple.notificationcenterui",
    "Notification Center": "com.apple.notificationcenterui",
    "CoreServicesUIAgent": "com.apple.CoreServicesUIAgent",
    "UIKitSystem": "com.apple.UIKitSystem",
    "FaceTimeNotificationViewBridge": "com.apple.FaceTime",
    "FaceTimeNotificationExtension": "com.apple.FaceTime",
]

private func bundleIdentifier(forExecutablePath path: String) -> String {
    BundleIDCache.shared.value(for: path)
}

/// Kernel-level process discovery. NSWorkspace.shared.runningApplications from
/// a long-lived launchd daemon context goes stale/blind (2026-09-06: daemon
/// missed every ring banner while fresh one-shot scanners saw them; 15:22-15:32
/// probe-split-brain flight). sysctl KERN_PROC_ALL is context-free and cannot
/// go stale; bundle IDs resolve from the executable path on disk.
private func discoverApplications() -> [DiscoveredApp] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    var ok: Int32 = sysctl(&mib, u_int(mib.count), nil, &size, nil, 0)
    guard ok == 0, size > 0 else { return [] }
    // Headroom for processes spawned between the two sysctl calls.
    size += 64 * MemoryLayout<kinfo_proc>.stride
    var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
    var actualSize = size
    ok = sysctl(&mib, u_int(mib.count), &buffer, &actualSize, nil, 0)
    guard ok == 0 else { return [] }
    let count = actualSize / MemoryLayout<kinfo_proc>.stride

    var seen = Set<pid_t>()
    var apps: [DiscoveredApp] = []
    for index in 0..<count {
        let pid = buffer[index].kp_proc.p_pid
        guard pid > 0, seen.insert(pid).inserted else { continue }
        let pathBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
        defer { pathBuffer.deallocate() }
        guard proc_pidpath(pid, pathBuffer, UInt32(MAXPATHLEN)) != 0 else { continue }
        let executablePath = String(cString: pathBuffer)
        let name = (executablePath as NSString).lastPathComponent
        // Cheap name filter first; bundle-ID resolution only for unknown names.
        guard knownProcessNames.contains(name) || knownBundleIDs.contains(bundleIdentifier(forExecutablePath: executablePath)) else { continue }
        apps.append(
            DiscoveredApp(
                pid: pid,
                executablePath: executablePath,
                bundleID: bundleIdentifier(forExecutablePath: executablePath),
                name: name
            )
        )
    }
    return apps
}

func scanAccessibility() -> AXSnapshot {
    let surfaces = discoverApplications().map { application -> AXSurface in
        let root = AXUIElementCreateApplication(application.pid)
        AXUIElementSetMessagingTimeout(root, messagingTimeout)
        var queue: [(AXUIElement, Int, Int?)] = [(root, 0, nil)]
        var cursor = 0
        var nodes: [AXNode] = []
        while cursor < queue.count && nodes.count < maximumNodesPerProcess {
            let (element, depth, parentIndex) = queue[cursor]
            cursor += 1
            let nodeIndex = nodes.count
            let node = readNode(element, parentIndex: parentIndex)
            nodes.append(node)
            if depth >= maximumDepth || prunedRoles.contains(node.role) { continue }
            for child in children(element) where queue.count < maximumNodesPerProcess {
                queue.append((child, depth + 1, nodeIndex))
            }
        }
        return AXSurface(
            pid: application.pid,
            process: application.name,
            bundleID: application.bundleID,
            nodes: nodes
        )
    }
    return AXSnapshot(surfaces: surfaces)
}

func sanitizedAccessibilitySnapshot(target: TargetIdentity) -> [[String: Any]] {
    let keywords = ["accept", "answer", "audio", "call", "facetime", "decline", "voicemail", "communication", "<authorized-e164>"]
    return scanAccessibility().surfaces.flatMap { surface in
        surface.nodes.compactMap { node -> [String: Any]? in
            let redacted = node.texts.map { text in
                text
                    .replacingOccurrences(of: target.handle, with: "<authorized-e164>")
                    .replacingOccurrences(of: target.digits, with: "<authorized-e164>")
            }
            let matchingTexts = redacted.filter { text in
                keywords.contains { semanticContains(text, $0) }
            }
            guard !matchingTexts.isEmpty else { return nil }
            return [
                "bundleID": surface.bundleID,
                "process": surface.process,
                "role": node.role,
                "identifier": node.identifier,
                "enabled": node.enabled,
                "texts": matchingTexts,
                "actions": node.actions,
            ]
        }
    }
}

// The frames mode is the coordinate-locating variant voice_loop uses to aim a
// cliclick fallback: keyword filtering must be SKIPPED here (a muted-mic or
// Mute toggle carries none of the call keywords), while the node budget stays
// enforced by scanAccessibility. The default snapshot above is untouched.
func axFrameEntry(
    for node: AXNode,
    surface: AXSurface,
    surfaceIndex: Int,
    framesEnabled: Bool
) -> [String: Any] {
    var entry: [String: Any] = [
        "surfaceIndex": surfaceIndex,
        "bundleID": surface.bundleID,
        "process": surface.process,
        "role": node.role,
        "identifier": node.identifier,
        "enabled": node.enabled,
        "actions": node.actions,
    ]
    // AXDescription first (macOS 26 renders button state here, e.g.
    // the banner's "Muted" mic), falling back to AXTitle.
    if !node.description.isEmpty {
        entry["label"] = node.description
    } else if !node.title.isEmpty {
        entry["label"] = node.title
    }
    if framesEnabled, let frame = node.frame {
        entry["frame"] = ["x": frame.x, "y": frame.y, "w": frame.w, "h": frame.h]
    }
    return entry
}

func axFrameEntries(in snapshot: AXSnapshot, frames: Bool) -> [[String: Any]] {
    let keywords = ["accept", "answer", "audio", "call", "facetime", "decline", "voicemail", "communication"]
    return snapshot.surfaces.enumerated().flatMap { surfaceIndex, surface -> [[String: Any]] in
        surface.nodes.compactMap { node in
            if !frames {
                // Default mode keeps the keyword filter: a node with no
                // call-vocabulary text is dropped, exactly as the redacting
                // default snapshot does (redaction itself stays in
                // sanitizedAccessibilitySnapshot, which owns the target).
                let hit = keywords.contains { kw in
                    node.texts.contains { semanticContains($0, kw) }
                }
                guard hit else { return nil }
            }
            return axFrameEntry(for: node, surface: surface, surfaceIndex: surfaceIndex, framesEnabled: frames)
        }
    }
}

func frameAccessibilitySnapshot() -> [[String: Any]] {
    axFrameEntries(in: scanAccessibility(), frames: true)
}

// One press candidate: the newest match wins (2026-09-07 stale-banner law —
// each failed attempt leaves a dead banner in the tray, and pressing the first
// one presses a stale prompt while the fresh one expires).
struct PressMatch {
    let surface: AXSurface
    let node: AXNode
    var label: String {
        node.description.isEmpty ? (node.title.isEmpty ? node.value : node.title) : node.description
    }
}

func axPressMatches(in snapshot: AXSnapshot, process: String, contains: String) -> [PressMatch] {
    let needle = normalizedSemanticText(contains)
    // Process name matching is case- and whitespace-insensitive: NSWorkspace
    // reports NC's executable name "NotificationCenter", while humans (and
    // voice_loop's CLI arg) naturally write "Notification Center".
    func sameProcess(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
            || a.replacingOccurrences(of: " ", with: "").caseInsensitiveCompare(
                b.replacingOccurrences(of: " ", with: "")) == .orderedSame
    }
    return snapshot.surfaces
        .filter { sameProcess($0.process, process) }
        .flatMap { surface in
            surface.nodes.compactMap { node -> PressMatch? in
                guard node.role == (kAXButtonRole as String),
                      node.enabled,
                      node.actions.contains(kAXPressAction as String) else { return nil }
                let hit = node.texts.contains { text in
                    normalizedSemanticText(text).range(
                        of: needle,
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) != nil
                }
                return hit ? PressMatch(surface: surface, node: node) : nil
            }
        }
}

struct PressOutcome {
    var exitCode: Int
    var pressed: Bool
    var matched: String?
    var reason: String?
}

/// `--ax-press --process <name> --contains <text>`: press the NEWEST enabled
/// pressable button whose texts contain <text> on the named process. Output
/// (stdout): {"pressed": true, "matched": "<text>"} or
/// {"pressed": false, "reason": "<why>"}. Exit 0 only on a performed press.
func performAXPress(process: String, contains: String) -> PressOutcome {
    func fail(_ reason: String) -> PressOutcome {
        PressOutcome(exitCode: 1, pressed: false, matched: nil, reason: reason)
    }
    let matches = axPressMatches(in: scanAccessibility(), process: process, contains: contains)
    guard let match = matches.last else {
        return fail("no enabled pressable button matching '\(contains)' on process '\(process)'")
    }
    let result = AXUIElementPerformAction(match.node.element, kAXPressAction as CFString)
    guard result == .success else {
        return fail("AXPress failed (error \(result.rawValue)) on '\(match.label)'")
    }
    ftbLog("ax-press: pressed '\(match.label)' on process '\(process)'")
    return PressOutcome(exitCode: 0, pressed: true, matched: match.label, reason: nil)
}
