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
        parentIndex: parentIndex
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
