// TokenTide — tiny always-on-top meter for your Claude plan usage, macOS 13+.
// Unofficial; not affiliated with or endorsed by Anthropic.
//
// Security model (see SECURITY.md):
//   - Reads Claude Code's OAuth token the same way Claude Code does
//     (`security find-generic-password`), so there is no extra permission prompt.
//   - The token lives only in memory. It is never logged, displayed or written.
//   - The only network peer is https://api.anthropic.com. The URL session is
//     ephemeral (no disk cache, no cookies) and refuses redirects, so the
//     Authorization header can't be forwarded to another host.
//   - Persisted state (UserDefaults): widget position, and the last limit
//     percentages + reset times. Nothing else.
//
// Data sources:
//   1. Plan limits (% used / reset time): GET https://api.anthropic.com/api/oauth/usage
//      using the OAuth token Claude Code stores in Keychain ("Claude Code-credentials").
//      Same data as /usage in Claude Code and Settings > Usage on claude.ai.
//      Undocumented endpoint — may change. Only known limit keys are shown;
//      internal codename fields are ignored.
//   2. Token counts + per-model share: summed from Claude Code's local logs
//      (~/.claude/projects/**/*.jsonl). Only Claude Code traffic is logged locally;
//      claude.ai web/desktop chats are not. Token share != limit share
//      (Opus/Fable tokens weigh more against limits than Sonnet tokens).
//
// Build: ./build.sh   (needs Xcode Command Line Tools)

import SwiftUI
import AppKit
import Combine
import QuartzCore
import ServiceManagement

@main
struct TokenTideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

// MARK: - Window

private let windowMargin: CGFloat = 10   // transparent room around the shape for its shadow

// Hosting view that (a) lets you drag the window from anywhere and (b) reports
// hover even though the panel never becomes key (.activeAlways tracking).
// The hover rect excludes the transparent shadow margin.
final class DragHostingView<Content: View>: NSHostingView<Content> {
    var onHover: (@MainActor (Bool) -> Void)?
    private var area: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds.insetBy(dx: windowMargin, dy: windowMargin),
                               options: [.mouseEnteredAndExited, .activeAlways],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }
}

// Window geometry model:
// - `home` is the origin of the collapsed circle (content rect, without margin). It is
//   the single source of truth for position and only changes when the user drags.
// - The expanded panel is anchored at the circle's corner nearest the screen corner,
//   so it grows toward the screen center and collapsing returns to exactly `home`.
//
// Animation: resizing an NSWindow every frame (and re-rendering its blur + shadow)
// is what made the previous version stutter. Now the window is resized exactly once
// per transition, and the morph itself is a SwiftUI animation of a shape inside the
// window, which Core Animation composites on the GPU at display refresh rate.
//   expand:   grow window to panel size instantly (circle stays pinned in its
//             corner, so nothing visibly moves) -> animate shape circle -> panel
//   collapse: animate shape panel -> circle -> shrink window to circle size
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var host: DragHostingView<MeterView>!
    private var measurer: NSHostingView<ExpandedPanel>!   // off-screen, sizes the expanded panel
    private let store = Store()
    private var bag: AnyCancellable?
    private var collapseTask: Task<Void, Never>?

    private var home = NSPoint.zero
    private var windowIsExpanded = false
    private var programmaticMove = false
    private var gen = 0
    private static let homeKey = "TokenTide.home"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon, no menu bar

        host = DragHostingView(rootView: MeterView(store: store))
        host.sizingOptions = []                  // we own the window size, not SwiftUI
        host.onHover = { [weak self] inside in self?.hover(inside) }
        measurer = NSHostingView(rootView: ExpandedPanel(store: store))

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: gaugeSize, height: gaugeSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar                 // above normal floating windows
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false                  // SwiftUI draws the shadow so it animates with the shape
        panel.contentView = host

        home = loadHome()
        setWindow(content: circleRect)
        panel.orderFrontRegardless()

        // queue: nil -> delivered synchronously during setFrame, so programmaticMove is accurate.
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: panel, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowMoved() }
        }

        bag = store.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the change; yield so SwiftUI has applied it.
            Task { @MainActor in
                await Task.yield()
                self?.relayout()
            }
        }
        store.start()
    }

    // MARK: Geometry

    private var visibleFrame: NSRect {
        (panel.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private var circleRect: NSRect {
        NSRect(origin: home, size: NSSize(width: gaugeSize, height: gaugeSize))
    }

    // Corner of the circle that stays put while the panel grows.
    private func pickCorner() -> Corner {
        let c = circleRect, vf = visibleFrame
        switch (c.midY > vf.midY, c.midX > vf.midX) {
        case (true, true):   return .topTrailing
        case (true, false):  return .topLeading
        case (false, true):  return .bottomTrailing
        case (false, false): return .bottomLeading
        }
    }

    private func measuredPanelSize() -> CGSize {
        measurer.layoutSubtreeIfNeeded()
        return measurer.fittingSize
    }

    private func panelRect(_ size: CGSize) -> NSRect {
        let c = circleRect, vf = visibleFrame
        var r = NSRect(origin: .zero, size: size)
        r.origin.x = store.corner.isRight ? c.maxX - size.width : c.minX
        r.origin.y = store.corner.isTop ? c.maxY - size.height : c.minY
        r.origin.x = min(max(r.origin.x, vf.minX), vf.maxX - size.width)
        r.origin.y = min(max(r.origin.y, vf.minY), vf.maxY - size.height)
        return r
    }

    private var contentRect: NSRect {
        panel.frame.insetBy(dx: windowMargin, dy: windowMargin)
    }

    private func setWindow(content r: NSRect) {
        let f = r.insetBy(dx: -windowMargin, dy: -windowMargin)
        guard panel.frame != f else { return }
        programmaticMove = true
        panel.setFrame(f, display: true)
        programmaticMove = false
    }

    private func loadHome() -> NSPoint {
        let vf = visibleFrame
        var p = NSPoint(x: vf.maxX - gaugeSize - 12, y: vf.maxY - gaugeSize - 12)
        if let s = UserDefaults.standard.string(forKey: Self.homeKey) {
            let q = NSPointFromString(s)
            if q != .zero { p = q }
        }
        p.x = min(max(p.x, vf.minX), vf.maxX - gaugeSize)
        p.y = min(max(p.y, vf.minY), vf.maxY - gaugeSize)
        return p
    }

    // Only user drags get here. Re-derive `home` from the anchored corner and persist.
    private func windowMoved() {
        guard !programmaticMove else { return }
        let r = contentRect
        if windowIsExpanded {
            home.x = store.corner.isRight ? r.maxX - gaugeSize : r.minX
            home.y = store.corner.isTop ? r.maxY - gaugeSize : r.minY
        } else {
            home = r.origin
        }
        UserDefaults.standard.set(NSStringFromPoint(home), forKey: Self.homeKey)
    }

    // MARK: Expand / collapse

    // Expand immediately on hover; collapse after a short grace period so the
    // widget doesn't flicker when the pointer brushes the edge.
    private func hover(_ inside: Bool) {
        collapseTask?.cancel()
        if inside {
            if !store.open { expand() }
        } else {
            collapseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                self?.collapse()
            }
        }
    }

    private func expand() {
        gen += 1
        if !windowIsExpanded {
            store.corner = pickCorner()
            store.panelSize = measuredPanelSize()
            setWindow(content: panelRect(store.panelSize))
            windowIsExpanded = true
        }
        store.scanTokens()   // freshest model mix the moment you look
        // Let SwiftUI lay out once at the new window size (circle still pinned in its
        // corner), then morph.
        Task { @MainActor [weak self] in
            await Task.yield()
            withAnimation(morph) { self?.store.open = true }
        }
    }

    private func collapse() {
        guard store.open else { return }
        gen += 1
        let g = gen
        withAnimation(morph) { store.open = false }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 420_000_000)   // let the spring settle
            guard let self, self.gen == g, !self.store.open else { return }
            self.setWindow(content: self.circleRect)
            self.windowIsExpanded = false
        }
    }

    // Keeps the window matched to content changes (e.g. a new limit row appears while
    // open). Skips mid-transition.
    private func relayout() {
        guard store.open == windowIsExpanded else { return }
        if windowIsExpanded {
            let size = measuredPanelSize()
            if size != store.panelSize {
                store.panelSize = size
                setWindow(content: panelRect(size))
            }
        } else {
            setWindow(content: circleRect)
        }
    }
}

let morph = Animation.spring(response: 0.34, dampingFraction: 0.86)

enum Corner {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var isTop: Bool { self == .topLeading || self == .topTrailing }
    var isRight: Bool { self == .topTrailing || self == .bottomTrailing }

    var alignment: Alignment {
        switch self {
        case .topLeading:     return .topLeading
        case .topTrailing:    return .topTrailing
        case .bottomLeading:  return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }
}

// MARK: - Model

struct UsageWindow: Identifiable, Codable {
    let id: String          // API key, e.g. "five_hour"
    let pct: Double         // % used, 0–100
    let resetsAt: Date?

    var label: String {
        switch id {
        case "five_hour": return "5h"
        case "seven_day": return "7d"
        case "seven_day_opus": return "7d Opus"
        case "seven_day_sonnet": return "7d Son."
        default: return id
        }
    }
}

struct TokenStats: Equatable {
    var total5h = 0
    var totalDay = 0
    var by5h: [String: Int] = [:]
    var byDay: [String: Int] = [:]
}

enum Family {
    static let order = ["Opus", "Sonnet", "Fable", "Haiku", "Other"]

    static func of(_ model: String?) -> String {
        let m = (model ?? "").lowercased()
        if m.contains("opus") { return "Opus" }
        if m.contains("sonnet") { return "Sonnet" }
        if m.contains("fable") || m.contains("mythos") { return "Fable" }
        if m.contains("haiku") { return "Haiku" }
        return "Other"
    }

    static func color(_ f: String) -> Color {
        switch f {
        // Observable 10 palette (designed to stay distinct on light and dark
        // backgrounds and for color-vision deficiency).
        case "Opus":   return hex(0xA463F2)   // purple
        case "Sonnet": return hex(0x4269D0)   // blue
        case "Fable":  return hex(0xEFB118)   // yellow
        case "Haiku":  return hex(0x6CC5B0)   // teal
        default:       return hex(0x9498A0)   // gray
        }
    }
}

func hex(_ v: UInt32) -> Color {
    Color(red: Double((v >> 16) & 0xFF) / 255,
          green: Double((v >> 8) & 0xFF) / 255,
          blue: Double(v & 0xFF) / 255)
}

enum Mood {
    case loading, happy, ok, worried, dead, offline

    var caption: String {
        switch self {
        case .loading: return "Checking…"
        case .happy:   return "All good"
        case .ok:      return "Pace yourself"
        case .worried: return "Running low"
        case .dead:    return "Limit hit"
        case .offline: return "Can't connect"
        }
    }

}

@MainActor
final class Store: ObservableObject {
    @Published var windows: [UsageWindow] = []
    @Published var stats = TokenStats()
    @Published var status: String?
    @Published var updatedAt: Date?
    @Published var plan: String?
    @Published var open = false                       // visual state (drives the morph)
    @Published var corner: Corner = .topTrailing
    @Published var panelSize = CGSize(width: 250, height: 150)

    private var token: String?
    private var profileTried = false
    private var timer: Timer?
    private var tokenTimer: Timer?
    private var busy = false
    private var notBefore = Date.distantPast           // backoff after a 429
    private static let cacheKey = "TokenTide.limits"   // minimal: [{id, pct, resetsAt}]
    private var scanning = false
    private let logIndex = LogIndex()

    // Driven by the tightest limit (lowest % left across all windows).
    var mood: Mood {
        guard let minLeft = windows.map({ 100 - $0.pct }).min() else {
            return status == nil ? .loading : .offline
        }
        switch minLeft {
        case ..<0.5: return .dead
        case ..<20:  return .worried
        case ..<50:  return .ok
        default:     return .happy
        }
    }

    func start() {
        // Show the last good response immediately (reset times are absolute, so
        // they stay correct); relaunching no longer means a blank widget.
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode([UsageWindow].self, from: data) {
            windows = cached
        }
        refresh()
        scanTokens()
        // Limits: 90s is plenty; the endpoint rate-limits aggressive polling.
        timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Local logs: cheap incremental tail, so poll often.
        tokenTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanTokens() }
        }
    }

    // force = the user chose Refresh; skips the 429 backoff.
    func refresh(force: Bool = false) {
        guard !busy, force || Date() >= notBefore else { return }
        busy = true
        Task {
            await fetchLimits()
            busy = false
            scanTokens()   // the 5h window start may have moved
        }
    }

    private func fetchLimits() async {
        if token == nil {
            // Read once and keep it in memory; re-read only after a 401.
            let c = await Task.detached(priority: .utility) { Credentials.read() }.value
            token = c?.token
            if let p = c?.plan { plan = p }
            if token == nil {
                status = "No Claude Code login — run `claude` once"
                return
            }
        }
        guard let t = token else { return }
        do {
            let (data, resp) = try await Net.get("/api/oauth/usage", token: t)
            let code = resp.statusCode
            switch code {
            case 200:
                let w = Parser.windows(from: try JSONSerialization.jsonObject(with: data))
                windows = w
                // Cache only what's displayed — never the raw response.
                if !w.isEmpty, let enc = try? JSONEncoder().encode(w) {
                    UserDefaults.standard.set(enc, forKey: Self.cacheKey)
                }
                if plan == nil && !profileTried {
                    profileTried = true
                    plan = await Profile.plan(token: t)
                }
                updatedAt = Date()
                status = w.isEmpty ? "No limit fields in response (API changed?)" : nil
            case 401, 403:
                token = nil   // re-read Keychain next round; Claude Code refreshes it when used
                status = "Token expired — open Claude Code to refresh"
            case 429:
                // Honor Retry-After (seconds), at least 2 minutes. Keep showing the
                // cached numbers; only complain if there's nothing to show.
                let ra = resp.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 0
                notBefore = Date().addingTimeInterval(max(ra, 120))
                status = windows.isEmpty ? "Rate limited, retrying in \(Int(max(ra, 120) / 60)) min" : nil
            default:
                status = "HTTP \(code)"
            }
        } catch {
            status = "Network error"
        }
    }

    // Independent of the network fetch. Reads only bytes appended to the logs since
    // the last scan, so a pass is milliseconds even with hundreds of MB of history.
    func scanTokens() {
        guard !scanning else { return }
        scanning = true
        let now = Date()
        var start5h = now.addingTimeInterval(-5 * 3600)
        if let r = windows.first(where: { $0.id == "five_hour" })?.resetsAt, r > now {
            start5h = r.addingTimeInterval(-5 * 3600)
        }
        let startDay = Calendar.current.startOfDay(for: now)
        let s5 = start5h
        let idx = logIndex
        Task {
            let s = await Task.detached(priority: .utility) { () -> TokenStats in
                idx.update(cutoff: min(s5, startDay))
                return idx.sum(since5h: s5, sinceDay: startDay)
            }.value
            if s != stats { stats = s }
            scanning = false
        }
    }
}

// MARK: - Credentials

struct Creds {
    let token: String
    let plan: String?
}

enum Credentials {
    static func read() -> Creds? {
        if let s = keychain(), let c = parse(s) { return c }
        // Linux-style fallback some setups use.
        let f = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let s = try? String(contentsOf: f, encoding: .utf8), let c = parse(s) { return c }
        return nil
    }

    // "max" + "default_claude_max_20x" -> "Max 20x"; "pro" -> "Pro"; etc.
    static func planName(sub: String?, tier: String?) -> String? {
        let t = (tier ?? "").lowercased()
        let s = (sub ?? "").lowercased()
        if t.contains("20x") { return "Max 20x" }
        if t.contains("5x") { return "Max 5x" }
        let both = s + " " + t
        if both.contains("enterprise") { return "Enterprise" }
        if both.contains("team") { return "Team" }
        if both.contains("max") { return "Max" }
        if both.contains("pro") { return "Pro" }
        if both.contains("free") { return "Free" }
        return s.isEmpty ? nil : s.capitalized
    }

    // Same mechanism Claude Code itself uses, so the item's ACL already trusts it
    // and there's no permission prompt. The token is passed over a pipe (never
    // argv/env) and kept only in memory.
    private static func keychain() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()   // read before wait: no pipe deadlock
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parse(_ s: String) -> Creds? {
        guard let d = s.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let oauth = o["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        let plan = planName(sub: oauth["subscriptionType"] as? String,
                            tier: oauth["rateLimitTier"] as? String)
        return Creds(token: token, plan: plan)
    }
}

// MARK: - Network

// The only code that talks to the network. One host, HTTPS only, ephemeral session
// (no disk cache, cookies or credential storage), redirects refused.
enum Net {
    static let host = "api.anthropic.com"

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        comps.path = path
        guard let url = comps.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.url?.host == host else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

// Fallback when the stored credentials carry no plan fields.
enum Profile {
    static func plan(token: String) async -> String? {
        guard let r = try? await Net.get("/api/oauth/profile", token: token),
              r.1.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: r.0) else { return nil }
        var found: [String: String] = [:]
        collect(obj, &found)
        let sub = found["subscription_type"] ?? found["subscriptionType"]
            ?? found["organization_type"] ?? found["plan"]
        let tier = found["rate_limit_tier"] ?? found["rateLimitTier"]
        return Credentials.planName(sub: sub, tier: tier)
    }

    private static let keys: Set<String> = ["subscription_type", "subscriptionType", "organization_type",
                                            "plan", "rate_limit_tier", "rateLimitTier"]

    private static func collect(_ obj: Any, _ out: inout [String: String]) {
        if let d = obj as? [String: Any] {
            for (k, v) in d {
                if keys.contains(k), let s = v as? String, out[k] == nil { out[k] = s }
                collect(v, &out)
            }
        } else if let a = obj as? [Any] {
            for v in a { collect(v, &out) }
        }
    }
}

// MARK: - Parsing

enum Parser {
    // Only these keys are shown, in this order. Anything else in the response
    // (internal codenames like "iguana_necktie", extra_usage, ...) is ignored.
    private static let known = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func iso(_ s: String) -> Date? { isoFrac.date(from: s) ?? isoPlain.date(from: s) }

    // Walks the whole response and treats any object carrying a numeric "utilization"
    // as a limit window (handles both the flat {five_hour:{...}} shape and an
    // array-of-limits shape), then keeps only known keys.
    static func windows(from obj: Any) -> [UsageWindow] {
        var out: [String: UsageWindow] = [:]
        walk(obj, key: nil, &out)
        return known.compactMap { out[$0] }
    }

    private static func walk(_ obj: Any, key: String?, _ out: inout [String: UsageWindow]) {
        if let d = obj as? [String: Any] {
            if let u = (d["utilization"] as? NSNumber)?.doubleValue {
                let name = (d["name"] as? String) ?? (d["type"] as? String) ?? (d["claim"] as? String)
                    ?? (d["id"] as? String) ?? key ?? "limit"
                if out[name] == nil {
                    out[name] = UsageWindow(id: name, pct: u, resetsAt: date(d["resets_at"] ?? d["reset_at"]))
                }
                return
            }
            for (k, v) in d { walk(v, key: k, &out) }
        } else if let a = obj as? [Any] {
            for v in a { walk(v, key: key, &out) }
        }
    }

    private static func date(_ v: Any?) -> Date? {
        if let n = v as? NSNumber {
            let x = n.doubleValue
            return Date(timeIntervalSince1970: x > 1e12 ? x / 1000 : x)
        }
        guard let s = v as? String else { return nil }
        return iso(s)
    }
}

// MARK: - Local Claude Code logs

// Incremental index over Claude Code's session logs (~/.claude/projects/**/*.jsonl).
// Remembers a byte offset per file and parses only newly appended complete lines.
// Not thread-safe: Store calls it from one detached task at a time (`scanning` guard).
final class LogIndex: @unchecked Sendable {
    private struct Entry {
        let t: Date
        let fam: String
        let n: Int
        let key: String
    }

    private var offsets: [String: UInt64] = [:]
    private var entries: [Entry] = []
    private var seen = Set<String>()
    private var lastCutoff = Date.distantPast
    private static let usageMarker = Data("\"usage\"".utf8)

    private static func roots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var r = [home.appendingPathComponent(".claude/projects"),
                 home.appendingPathComponent(".config/claude/projects")]
        if let c = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            r.insert(URL(fileURLWithPath: c).appendingPathComponent("projects"), at: 0)
        }
        return r
    }

    func update(cutoff: Date) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        for root in Self.roots() {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                let rv = try? url.resourceValues(forKeys: Set(keys))
                let mod = rv?.contentModificationDate ?? .distantPast
                let size = UInt64(rv?.fileSize ?? 0)
                let path = url.path
                // Never-read files untouched since the cutoff hold nothing we need.
                if offsets[path] == nil && mod < cutoff { continue }
                var off = offsets[path] ?? 0
                if size < off { off = 0 }                  // truncated or rewritten
                guard size > off, let fh = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? fh.close() }
                guard (try? fh.seek(toOffset: off)) != nil,
                      let data = try? fh.readToEnd(),
                      let lastNL = data.lastIndex(of: 0x0A) else { continue }
                // Only consume complete lines; a half-written last line is read next time.
                let complete = data[data.startIndex...lastNL]
                for line in complete.split(separator: 0x0A) {
                    ingest(Data(line), cutoff: cutoff)
                }
                offsets[path] = off + UInt64(complete.count)
            }
        }
        if cutoff > lastCutoff {
            entries.removeAll { $0.t < cutoff }
            seen = Set(entries.map(\.key))
            lastCutoff = cutoff
        }
    }

    // Counts input + output + cache-write tokens. Cache reads are excluded:
    // they dwarf everything else and don't reflect real work.
    private func ingest(_ d: Data, cutoff: Date) {
        guard d.range(of: Self.usageMarker) != nil,
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let msg = o["message"] as? [String: Any],
              let u = msg["usage"] as? [String: Any],
              let ts = o["timestamp"] as? String,
              let t = Parser.iso(ts), t >= cutoff else { return }
        // Streaming writes the same message several times; dedupe.
        let key = "\(msg["id"] as? String ?? "")|\(o["requestId"] as? String ?? UUID().uuidString)"
        guard seen.insert(key).inserted else { return }
        let n = ["input_tokens", "output_tokens", "cache_creation_input_tokens"]
            .reduce(0) { $0 + ((u[$1] as? NSNumber)?.intValue ?? 0) }
        guard n > 0 else { return }
        entries.append(Entry(t: t, fam: Family.of(msg["model"] as? String), n: n, key: key))
    }

    func sum(since5h: Date, sinceDay: Date) -> TokenStats {
        var s = TokenStats()
        for e in entries {
            if e.t >= since5h {
                s.total5h += e.n
                s.by5h[e.fam, default: 0] += e.n
            }
            if e.t >= sinceDay {
                s.totalDay += e.n
                s.byDay[e.fam, default: 0] += e.n
            }
        }
        return s
    }
}

// MARK: - UI

private let contentWidth: CGFloat = 230
private let gaugeSize: CGFloat = 44

// Claude brand clay. Used for every healthy bar/ring; only a nearly-exhausted
// limit (<= 20% left) switches to red so the warning still reads at a glance.
let claudeAccent = hex(0xD97757)
let warnRed = hex(0xE5484D)

func leftColor(_ left: Double) -> Color {
    left > 20 ? claudeAccent : warnRed
}

// Root view. The window is resized once per transition; this view morphs a single
// shape between the 44pt circle and the panel size, pinned to the anchored corner,
// while the gauge and panel cross-fade. Shadow is drawn here so it tracks the shape.
struct MeterView: View {
    @ObservedObject var store: Store

    var body: some View {
        let w = store.open ? store.panelSize.width : gaugeSize
        let h = store.open ? store.panelSize.height : gaugeSize
        let shape = RoundedRectangle(cornerRadius: store.open ? 10 : gaugeSize / 2, style: .continuous)

        ZStack(alignment: store.corner.alignment) {
            if store.open {
                ExpandedPanel(store: store)
                    .transition(.opacity)
            } else {
                Gauge(fiveHour: store.windows.first { $0.id == "five_hour" },
                      sevenDay: store.windows.first { $0.id == "seven_day" },
                      failed: store.windows.isEmpty && store.status != nil)
                    .transition(.opacity)
            }
        }
        .frame(width: w, height: h, alignment: store.corner.alignment)
        .clipShape(shape)
        .background(
            // Shadow on the backing shape only, so text and rings don't get their own.
            // Claude-clay tinted glass: material for the blur, a clay wash on top.
            ZStack {
                shape.fill(.regularMaterial)
                shape.fill(claudeAccent.opacity(0.18))
            }
            .shadow(color: claudeAccent.opacity(0.25), radius: 6, y: 2)
        )
        .overlay(shape.strokeBorder(claudeAccent.opacity(0.6), lineWidth: 1))
        .contentShape(shape)
        .help(store.updatedAt.map { "Updated \($0.formatted(date: .omitted, time: .standard))" } ?? "")
        .contextMenu {
            Button("Refresh") { store.refresh(force: true) }
            Button(SMAppService.mainApp.status == .enabled ? "✓ Launch at Login" : "Launch at Login") { toggleLogin() }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: store.corner.alignment)
        .padding(windowMargin)
    }

    private func toggleLogin() {
        let s = SMAppService.mainApp
        do {
            if s.status == .enabled { try s.unregister() } else { try s.register() }
        } catch {
            NSSound.beep()
        }
    }
}

// Expanded content at its natural size (no background). Also used off-screen to
// measure the expanded window size.
struct ExpandedPanel: View {
    @ObservedObject var store: Store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: store.plan ?? "Claude")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(claudeAccent)
                    Spacer(minLength: 0)
                    Text(verbatim: store.mood.caption)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                ForEach(store.windows) { WindowRow(w: $0, now: ctx.date) }
                if store.stats.totalDay > 0 {
                    Divider().opacity(0.4)
                    ModelShare(s: store.stats)
                }
                if let s = store.status {
                    Text(verbatim: s)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: "tok  5h \(fmt(store.stats.total5h)) · today \(fmt(store.stats.totalDay))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: contentWidth + 20, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// Collapsed state: two concentric rings, filled clockwise by % left.
// Outer ring = 5h window, inner ring = 7d window, center = 5h % left.
struct Gauge: View {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let failed: Bool

    var body: some View {
        ZStack {
            ring(fiveHour, diameter: 36)
            ring(sevenDay, diameter: 24)
            Text(verbatim: center)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(failed ? Color.secondary : Color.primary)
        }
        .frame(width: gaugeSize, height: gaugeSize)
    }

    private var center: String {
        if failed { return "!" }
        guard let w = fiveHour else { return "–" }
        return "\(Int(left(w).rounded()))"
    }

    private func left(_ w: UsageWindow) -> Double { min(100, max(0, 100 - w.pct)) }

    private func ring(_ w: UsageWindow?, diameter: CGFloat) -> some View {
        let l = w.map(left) ?? 0
        return ZStack {
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: 4)
            Circle()
                .trim(from: 0, to: l / 100)
                .stroke(leftColor(l), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}

func fmt(_ n: Int) -> String {
    switch n {
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1e6)
    case 1_000...:     return String(format: "%.0fk", Double(n) / 1e3)
    default:           return "\(n)"
    }
}

struct WindowRow: View {
    let w: UsageWindow
    let now: Date

    var body: some View {
        let left = min(100, max(0, 100 - w.pct))
        HStack(spacing: 6) {
            Text(verbatim: w.label)
                .frame(width: 52, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                Capsule().fill(leftColor(left)).frame(width: 56 * left / 100)
            }
            .frame(width: 56, height: 6)
            Text(verbatim: "\(Int(left.rounded()))% left")
                .frame(width: 60, alignment: .trailing)
            Text(verbatim: countdown())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .lineLimit(1)
    }

    private func countdown() -> String {
        guard let r = w.resetsAt else { return "" }
        let s = Int(r.timeIntervalSince(now))
        if s <= 0 { return "↻now" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "↻\(d)d\(h)h" }
        if h > 0 { return "↻\(h)h\(m)m" }
        return "↻\(m)m"
    }
}

// Compact model mix: two thin stacked bars (5h, today) and a one-line legend
// with "5h% / today%" per model family.
struct ModelShare: View {
    let s: TokenStats
    private let barWidth: CGFloat = contentWidth - 40

    private var present: [String] {
        Family.order.filter { (s.byDay[$0] ?? 0) > 0 || (s.by5h[$0] ?? 0) > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            bar("5h", s.by5h, s.total5h)
            bar("day", s.byDay, s.totalDay)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4, alignment: .leading), count: 3),
                      alignment: .leading, spacing: 1) {
                ForEach(present, id: \.self) { f in
                    HStack(spacing: 3) {
                        Circle().fill(Family.color(f)).frame(width: 5, height: 5)
                        Text(verbatim: "\(f) \(pct(s.by5h[f], s.total5h))/\(pct(s.byDay[f], s.totalDay))%")
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.secondary)
        .help("Share of Claude Code tokens by model (5h / today). Token share ≠ limit share: Opus and Fable tokens count more against limits. claude.ai chats aren't included.")
    }

    private func bar(_ label: String, _ by: [String: Int], _ total: Int) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: label)
                .frame(width: 34, alignment: .leading)
            HStack(spacing: 0) {
                if total > 0 {
                    ForEach(present, id: \.self) { f in
                        Rectangle()
                            .fill(Family.color(f))
                            .frame(width: barWidth * CGFloat(by[f] ?? 0) / CGFloat(total))
                    }
                }
            }
            .frame(width: barWidth, height: 4, alignment: .leading)
            .background(Color.primary.opacity(0.15))
            .clipShape(Capsule())
        }
    }

    private func pct(_ v: Int?, _ total: Int) -> String {
        guard total > 0 else { return "–" }
        return "\(Int((Double(v ?? 0) / Double(total) * 100).rounded()))"
    }
}
