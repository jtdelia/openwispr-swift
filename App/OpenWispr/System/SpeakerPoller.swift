import AppKit
import ApplicationServices
import OpenWisprCore

/// Polls meeting apps for who is talking and reports each change, so the call audio can be attributed to
/// names. Reads off the main thread: Accessibility calls into a busy browser can take a while.
@MainActor
final class SpeakerPoller: SpeakerDetector {
    private static let interval = Duration.milliseconds(300)
    private var task: Task<Void, Never>?

    func startPolling(markers: MeetTileMarkers, report: @escaping @MainActor (SpeakersReport) -> Void) {
        task?.cancel()
        let tileMarkers = TileMarkers(speakingClasses: Set(markers.speakingClasses), selfLabels: Set(markers.selfLabels))
        task = Task.detached(priority: .utility) {
            var last: SpeakerSnapshot?
            while !Task.isCancelled {
                let snapshot = MeetingSpeakers.read(markers: tileMarkers)
                if snapshot != last {
                    last = snapshot
                    let platform = snapshot.platform.flatMap(MeetingPlatform.init(rawValue:))
                    await report(SpeakersReport(platform: platform, speaking: snapshot.speaking, timestamp: Date().timeIntervalSince1970 * 1000))
                }
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stopPolling() {
        task?.cancel()
        task = nil
    }
}

struct SpeakerSnapshot: Equatable, Sendable {
    var platform: String?
    var speaking: [String] = []
    var selfSpeaking = false
}

/// How a web meeting marks tiles: classes present only while that participant talks, and labels of
/// controls that only appear on the user's own tile.
struct TileMarkers: Sendable {
    let speakingClasses: Set<String>
    let selfLabels: Set<String>
}

enum MeetingSpeakers {
    private static let browsers: Set<String> = [
        "com.apple.safari", "com.brave.browser", "com.google.chrome", "com.google.chrome.beta",
        "com.google.chrome.canary", "com.google.chrome.dev", "org.chromium.chromium", "com.microsoft.edgemac",
        "com.operasoftware.opera", "com.vivaldi.vivaldi", "company.thebrowser.browser", "company.thebrowser.dia",
    ]
    private static let timeBudget: TimeInterval = 0.25

    static func read(markers: TileMarkers) -> SpeakerSnapshot {
        for app in NSWorkspace.shared.runningApplications {
            guard let bundle = app.bundleIdentifier?.lowercased() else { continue }
            let platform: String
            switch bundle {
            case "us.zoom.xos": platform = "zoom"
            case "com.microsoft.teams2", "com.microsoft.teams": platform = "teams"
            case "com.tinyspeck.slackmacgap": platform = "slack"
            case _ where browsers.contains(bundle): platform = "meet"
            default: continue
            }
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.2)
            // Chromium and Electron build their web accessibility tree only for assistive clients.
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if platform == "meet" {
                AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
            if let snapshot = readApp(appElement, platform: platform, markers: markers) { return snapshot }
        }
        return SpeakerSnapshot()
    }

    private static func readApp(_ appElement: AXUIElement, platform: String, markers: TileMarkers) -> SpeakerSnapshot? {
        guard let windows = copy(appElement, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        let deadline = Date().addingTimeInterval(timeBudget)
        for window in windows {
            let roots: [AXUIElement]
            if platform == "meet" {
                roots = webAreas(in: window, deadline: deadline).filter(isMeetRoom)
            } else if platform == "zoom" {
                let title = (copy(window, kAXTitleAttribute) as? String ?? "").lowercased()
                roots = title.contains("zoom meeting") || title.contains("zoom webinar") ? [window] : []
            } else {
                roots = [window]
            }
            for root in roots {
                let tree = Tree(root: root, deadline: deadline)
                if platform == "teams" && !tree.domIds.contains("hangup-button") { continue }
                if platform == "slack" && !tree.domIds.contains(where: { $0.hasPrefix("calling-roster-item-") }) { continue }
                var snapshot = SpeakerSnapshot(platform: platform)
                tree.collectSpeakers(markers: markers, into: &snapshot)
                snapshot.speaking.sort()
                return snapshot
            }
        }
        return nil
    }

    private static func webAreas(in window: AXUIElement, deadline: Date) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while let item = stack.popLast(), visited < 500, Date() < deadline {
            let (element, depth) = item
            visited += 1
            if copy(element, kAXRoleAttribute) as? String == "AXWebArea" {
                found.append(element)
                continue
            }
            guard depth < 25, let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            stack.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return found
    }

    private static func isMeetRoom(_ webArea: AXUIElement) -> Bool {
        guard let url = copy(webArea, "AXURL") as? URL, url.host == "meet.google.com" else { return false }
        return url.path.range(of: #"^/[a-z]{3}-[a-z]{4}-[a-z]{3}"#, options: .regularExpression) != nil
    }

    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}

/// A bounded snapshot of an accessibility subtree, flattened with parent links.
private struct Tree {
    struct Node {
        let parent: Int?
        let role: String
        let labels: [String]
        let classes: [String]
    }

    nonisolated(unsafe) private static let attributes = [
        kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute, "AXDOMClassList", "AXDOMIdentifier", kAXChildrenAttribute,
    ] as CFArray
    /// Text content (chat, captions) is never a tile label.
    private static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink"]
    private static let maxNodes = 4000
    private static let maxDepth = 60
    /// How far up from a speaking indicator to look for the tile's name.
    private static let tileDepth = 8

    private(set) var nodes: [Node] = []
    private(set) var domIds: Set<String> = []

    init(root: AXUIElement, deadline: Date) {
        var stack: [(AXUIElement, Int?, Int)] = [(root, nil, 0)]
        while let item = stack.popLast(), nodes.count < Self.maxNodes, Date() < deadline {
            let (element, parent, depth) = item
            var valuesRef: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, Self.attributes, [], &valuesRef) == .success,
                  let values = valuesRef as? [Any], values.count == 7
            else { continue }
            let labels = [values[1], values[2], values[3]].compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if let id = values[5] as? String, !id.isEmpty { domIds.insert(id) }
            let index = nodes.count
            nodes.append(Node(parent: parent, role: values[0] as? String ?? "", labels: labels, classes: values[4] as? [String] ?? []))
            guard depth < Self.maxDepth, let children = values[6] as? [AXUIElement] else { continue }
            for child in children.reversed() { stack.append((child, index, depth + 1)) }
        }
    }

    func collectSpeakers(markers: TileMarkers, into snapshot: inout SpeakerSnapshot) {
        var names = Set<String>()
        for node in nodes where !Self.textRoles.contains(node.role) {
            for label in node.labels {
                switch SpeakerLabel.parse(label) {
                case let .speaking(name): names.insert(name)
                case .selfSpeaking: snapshot.selfSpeaking = true
                case .none: break
                }
            }
        }
        if !markers.speakingClasses.isEmpty {
            let tileNames = namesBySubtree()
            let ownTile = ancestors(ofNodesLabelled: markers.selfLabels)
            for (index, node) in nodes.enumerated() where !markers.speakingClasses.isDisjoint(with: node.classes) {
                switch tileName(above: index, tileNames, ownTile: ownTile) {
                case .some(SpeakerLabel.selfName): snapshot.selfSpeaking = true
                case let .some(name): names.insert(name)
                case .none: break
                }
            }
        }
        snapshot.speaking = Array(names)
    }

    /// For each node, the plausible display names among its static texts within `tileDepth` levels below.
    private func namesBySubtree() -> [Int: Set<String>] {
        var result: [Int: Set<String>] = [:]
        for (index, node) in nodes.enumerated() where node.role == "AXStaticText" {
            guard let name = node.labels.lazy.compactMap(SpeakerLabel.displayName).first else { continue }
            var current: Int? = index
            for _ in 0...Self.tileDepth {
                guard let at = current else { break }
                result[at, default: []].insert(name)
                current = nodes[at].parent
            }
        }
        return result
    }

    /// Nodes within `tileDepth` levels above any node carrying one of `labels`.
    private func ancestors(ofNodesLabelled labels: Set<String>) -> Set<Int> {
        var result = Set<Int>()
        for (index, node) in nodes.enumerated() where !labels.isDisjoint(with: node.labels) {
            var current: Int? = index
            for _ in 0...Self.tileDepth {
                guard let at = current else { break }
                result.insert(at)
                current = nodes[at].parent
            }
        }
        return result
    }

    /// The nearest ancestor naming exactly one person is the indicator's tile; one naming several is a grid.
    private func tileName(above index: Int, _ tileNames: [Int: Set<String>], ownTile: Set<Int>) -> String? {
        var current: Int? = index
        for _ in 0...Self.tileDepth {
            guard let at = current else { return nil }
            if let names = tileNames[at] {
                guard names.count == 1 else { return nil }
                return ownTile.contains(at) ? SpeakerLabel.selfName : names.first
            }
            current = nodes[at].parent
        }
        return nil
    }
}

enum SpeakerLabel: Equatable {
    case speaking(String)
    case selfSpeaking

    static let selfName = "\u{0}self"

    private static let speakingParts: Set<String> = ["speaking", "talking", "active speaker", "is speaking", "is talking"]
    private static let noise: Set<String> = [
        "muted", "unmuted", "talking", "speaking", "video", "presenting", "camera", "microphone", "active speaker",
        "guest", "external", "unverified", "host", "co-host", "organizer", "presenter", "attendee",
    ]

    /// Reads tile labels such as "Alice Smith, Organizer, speaking" or "Bob is talking".
    static func parse(_ label: String) -> SpeakerLabel? {
        if label.lowercased().hasPrefix("you are speaking") { return .selfSpeaking }
        var parts = label.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first == "In this meeting" { parts.removeFirst() }
        guard var head = parts.first else { return nil }
        if let range = head.range(of: #"\s+is\s+(speaking|talking)$"#, options: [.regularExpression, .caseInsensitive]) {
            head.removeSubrange(range)
        } else if !parts.dropFirst().contains(where: { speakingParts.contains($0.lowercased()) }) {
            return nil
        }
        guard let name = displayName(head) else { return nil }
        return name == selfName ? .selfSpeaking : .speaking(name)
    }

    /// The person a tile label names, `selfName` for the user's own tile, or nil for anything else.
    static func displayName(_ text: String) -> String? {
        var name = text.precomposedStringWithCanonicalMapping
        let lower = name.lowercased()
        if lower == "you" || lower.hasSuffix("(you)") || lower.hasSuffix("(me)") { return selfName }
        name = name.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard (1...60).contains(name.count),
              name.split(separator: " ").count <= 5,
              name.rangeOfCharacter(from: .letters) != nil,
              !noise.contains(name.lowercased()),
              name.range(of: #"^\+?\d+\s+(more|others?|participants?)$"#, options: [.regularExpression, .caseInsensitive]) == nil
        else { return nil }
        return name
    }
}
