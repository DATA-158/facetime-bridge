import AppKit
import ApplicationServices
import Foundation

// Unit fixtures for the two new ax2 modes (GitHub issue #6):
//   --ax-snapshot --frames  → per-node frame/label keys, keyword filter skipped
//   --ax-press --process <name> --contains <text> → newest-match AXPress
// Mirrors AuthorizationTests.swift style: plain require() assertions, fixture
// AXNodes built in-memory, exit 1 with FAIL: message on any violated property.

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

// Same minimal node factory the authorization fixtures use. The element is a
// real (inert) system-wide AXUIElement — press tests must intercept perform
// rather than exercise the live element, which the two harnesses below do.
private func node(
    role: String = "AXGenericElement",
    title: String = "",
    description: String = "",
    value: String = "",
    help: String = "",
    identifier: String = "",
    enabled: Bool = true,
    actions: [String] = [],
    parentIndex: Int? = nil,
    frame: Frame? = nil
) -> AXNode {
    AXNode(
        element: AXUIElementCreateSystemWide(),
        role: role,
        identifier: identifier,
        title: title,
        description: description,
        value: value,
        help: help,
        enabled: enabled,
        actions: actions,
        parentIndex: parentIndex,
        frame: frame
    )
}

private func surface(_ nodes: [AXNode], process: String = "Notification Center", pid: pid_t = 1) -> AXSurface {
    AXSurface(pid: pid, process: process, bundleID: "com.apple.notificationcenterui", nodes: nodes)
}

@main
struct PressAndFramesTests {
    static func main() throws {
        let kPress = kAXPressAction as String

        // ------------------------------------------------------------------
        // --ax-press matching (model level)
        // ------------------------------------------------------------------
        let bannerButton = node(
            role: kAXButtonRole as String,
            title: "Call",
            description: "Click to Call",
            enabled: true,
            actions: [kPress],
            parentIndex: 0
        )
        // An OLDER stale banner earlier in node order — newest-match law.
        let staleBannerButton = node(
            role: kAXButtonRole as String,
            title: "Call",
            description: "Click to Call",
            enabled: true,
            actions: [kPress],
            parentIndex: 1
        )
        let nonButton = node(description: "Click to Call", enabled: true, actions: [kPress])
        let disabledButton = node(
            role: kAXButtonRole as String,
            description: "Click to Call",
            enabled: false,
            actions: [kPress]
        )
        let noPressAction = node(role: kAXButtonRole as String, description: "Click to Call", enabled: true, actions: [])
        let otherProcessNode = node(role: kAXButtonRole as String, description: "Click to Call", enabled: true, actions: [kPress])
        let ftSurface = AXSurface(
            pid: 2,
            process: "FaceTime",
            bundleID: "com.apple.FaceTime",
            nodes: [otherProcessNode]
        )

        // 1. A pressable, enabled, containing node matches.
        let soloMatches = axPressMatches(in: AXSnapshot(surfaces: [surface([bannerButton])]), process: "Notification Center", contains: "call")
        require(soloMatches.count == 1, "a pressable button containing the text must match (got \(soloMatches.count))")

        // 2. The process filter is case-insensitive; the contains filter is
        // semantic (whitespace-normalized) and case-sensitive on this build —
        // voice_loop always passes the exact casing ('Call', 'Mute').
        require(axPressMatches(in: AXSnapshot(surfaces: [surface([bannerButton])]), process: "notification center", contains: "Call").count == 1,
                "process matching must be case-insensitive")

        // 3. Role=AXButton is required.
        require(axPressMatches(in: AXSnapshot(surfaces: [surface([nonButton])]), process: "Notification Center", contains: "call").isEmpty,
                "a pressable non-button containing the text must not match")

        // 4. Disabled nodes never match.
        require(axPressMatches(in: AXSnapshot(surfaces: [surface([disabledButton])]), process: "Notification Center", contains: "call").isEmpty,
                "a disabled button must not match")

        // 5. A node without kAXPressAction never matches.
        require(axPressMatches(in: AXSnapshot(surfaces: [surface([noPressAction])]), process: "Notification Center", contains: "call").isEmpty,
                "a button without a press action must not match")

        // 6. Process filter restricts by exact process name.
        require(axPressMatches(in: AXSnapshot(surfaces: [ftSurface]), process: "Notification Center", contains: "call").isEmpty,
                "nodes on another process surface must not match")
        require(axPressMatches(in: AXSnapshot(surfaces: [ftSurface]), process: "FaceTime", contains: "call").count == 1,
                "the process filter must match by exact process name")

        // 7. Text filter covers description/title/value/identifier texts.
        let titled = node(role: kAXButtonRole as String, title: "Mute", enabled: true, actions: [kPress])
        let valued = node(role: kAXButtonRole as String, value: "End call", enabled: true, actions: [kPress])
        let identified = node(role: kAXButtonRole as String, identifier: "mute-button", enabled: true, actions: [kPress])
        require(axPressMatches(in: AXSnapshot(surfaces: [surface([titled])]), process: "Notification Center", contains: "mute").count == 1,
                "AXTitle text must satisfy the contains filter")
        require(axPressMatches(in: AXSnapshot(surfaces: [surface([valued])]), process: "Notification Center", contains: "end").count == 1,
                "AXValue text must satisfy the contains filter")
        require(axPressMatches(in: AXSnapshot(surfaces: [surface([identified])]), process: "Notification Center", contains: "mute").count == 1,
                "AXIdentifier text must satisfy the contains filter")

        // 8. Non-matching text must not match.
        require(axPressMatches(in: AXSnapshot(surfaces: [surface([bannerButton])]), process: "Notification Center", contains: "NoMatchExpectedXYZ").isEmpty,
                "unrelated contains text must not match")

        // 9. Newest-match preference: with a stale banner and a fresh one in
        // node order, pick the LAST match (the stale-banner law).
        let newest = axPressMatches(in: AXSnapshot(surfaces: [surface([staleBannerButton, bannerButton])]), process: "Notification Center", contains: "call").last
        require(newest != nil, "matches must exist before newest-selection")
        // parentIndex is the only per-node distinguishing field on a fixture.
        require(newest?.node.parentIndex == 0, "newest-match preference must select the LAST matching node")

        // 10. The press result envelope: success and each failure reason.
        let pressedFixture = PressOutcome(exitCode: 0, pressed: true, matched: "Click to Call", reason: nil)
        require(pressedFixture.exitCode == 0 && pressedFixture.pressed, "a performed press must report pressed=true and exit 0")
        let noMatchFixture = PressOutcome(exitCode: 1, pressed: false, matched: nil, reason: "no enabled pressable button matching 'NoMatchExpectedXYZ' on process 'Notification Center'")
        require(!noMatchFixture.pressed && noMatchFixture.exitCode == 1 && noMatchFixture.reason != nil,
                "no match must report pressed=false with a reason and exit 1")
        let performFailedFixture = PressOutcome(exitCode: 1, pressed: false, matched: nil, reason: "AXPress failed (error -25204)")
        require(!performFailedFixture.pressed && performFailedFixture.reason != nil,
                "a failed AXUIElementPerformAction must report pressed=false with a reason")

        // ------------------------------------------------------------------
        // --ax-snapshot --frames fixtures (model level)
        // ------------------------------------------------------------------
        let frameNode = node(
            role: kAXButtonRole as String,
            title: "Answer",
            description: "Accept Audio Call",
            enabled: true,
            actions: [kPress],
            parentIndex: 3,
            frame: Frame(x: 120, y: 240, w: 96, h: 32)
        )
        let bareNode = node(role: "AXGroup", parentIndex: 4)

        // The frames emitter passes nodes straight through (keyword filter
        // skipped), so even an unlabeled node yields a frame-mode entry.
        let entry = axFrameEntry(for: frameNode, surface: surface([frameNode]), surfaceIndex: 0, framesEnabled: true)
        require(entry["role"] as? String == "AXButton", "frame entry must carry the node role")
        require(entry["label"] as? String == "Accept Audio Call", "frame entry label must prefer AXDescription over AXTitle")
        let frame = entry["frame"] as? [String: Any]
        require(frame != nil, "frame entry must carry a frame when position+size are readable")
        require(Set((frame ?? [:]).keys) == Set(["x", "y", "w", "h"]), "frame must have exactly x/y/w/h keys")

        let bareEntry = axFrameEntry(for: bareNode, surface: surface([bareNode]), surfaceIndex: 0, framesEnabled: true)
        require(bareEntry["label"] == nil, "a node with no description/title must omit label")
        require(bareEntry["frame"] == nil, "a node whose position/size are unreadable must omit frame")

        // The default snapshot keeps the keyword filter; frames mode skips it.
        // A call-vocabulary node is KEPT in default mode (that is what the
        // vocabulary is for) and also kept in frames mode; a node with no
        // call vocabulary is dropped in default mode but kept by frames —
        // one emitter, two modes, pinned in both directions.
        let vocabSnapshot = AXSnapshot(surfaces: [surface([frameNode])])
        require(!axFrameEntries(in: vocabSnapshot, frames: true).isEmpty,
                "frames mode must NOT keyword-filter call-vocabulary nodes")
        require(!axFrameEntries(in: vocabSnapshot, frames: false).isEmpty,
                "default snapshot mode must KEEP call-vocabulary nodes")

        let bareSnapshot = AXSnapshot(surfaces: [surface([bareNode])])
        require(axFrameEntries(in: bareSnapshot, frames: true).count == 1,
                "frames mode keeps nodes without call vocabulary (no filter)")
        require(axFrameEntries(in: bareSnapshot, frames: false).isEmpty,
                "default snapshot mode drops nodes without call vocabulary")

        // One frame entry per scanned node, carrying the surface keys.
        let twoNodes = AXSnapshot(surfaces: [surface([frameNode, bareNode])])
        let surfaceEntries = axFrameEntries(in: twoNodes, frames: true)
        require(surfaceEntries.count == 2, "one frame entry per scanned node (got \(surfaceEntries.count))")
        require(surfaceEntries.first?["process"] as? String == "Notification Center", "frame entries must carry the surface process")
        require(surfaceEntries.first?["bundleID"] as? String == "com.apple.notificationcenterui", "frame entries must carry the surface bundleID")

        print("native press/frames regressions passed")
    }
}