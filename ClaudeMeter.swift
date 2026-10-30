// ClaudeMeter — tiny always-on-top Claude usage meter for macOS 13+.
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
struct ClaudeMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

// MARK: - Window

// Hosting view that (a) lets you drag the window from anywhere and (b) reports
// hover even though the panel never becomes key (.activeAlways tracking).
final class DragHostingView<Content: View>: NSHostingView<Content> {
    var onHover: (@MainActor (Bool) -> Void)?
    private var area: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
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
// - `home` is the origin of the collapsed circle. It is the single source of truth
//   for position and only changes when the user drags the widget.
// - The expanded panel is derived from `home` + the corner of the circle nearest the
//   screen corner, so it grows toward the screen center and collapsing returns the
//   circle to exactly where it was (no drift).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var host: DragHostingView<MeterView>!
    private var measurer: NSHostingView<ExpandedPanel>!   // off-screen, sizes the expanded panel
    private let store = Store()
    private var bag: AnyCancellable?
    private var collapseTask: Task<Void, Never>?

    private var home = NSPoint.zero
    private var animating = false
    private var animGen = 0
    private static let homeKey = "ClaudeMeter.home"
    private static let animDuration = 0.22

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
        panel.hasShadow = true
        panel.contentView = host

        home = loadHome()
        panel.setFrame(circleFrame, display: false)
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.windowMoved() }
        }

        bag = store.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the change; hop twice so SwiftUI has applied it.
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

    private var circleFrame: NSRect {
        NSRect(origin: home, size: NSSize(width: gaugeSize, height: gaugeSize))
    }

    // Corner of the circle that stays put while the panel grows.
    private func pickCorner() -> Corner {
        let c = circleFrame, vf = visibleFrame
        let right = c.midX > vf.midX
        let top = c.midY > vf.midY
        switch (top, right) {
        case (true, true):   return .topTrailing
        case (true, false):  return .topLeading
        case (false, true):  return .bottomTrailing
        case (false, false): return .bottomLeading
        }
    }

    private func expandedFrame() -> NSRect {
        measurer.layoutSubtreeIfNeeded()
        let size = measurer.fittingSize
        let c = circleFrame, vf = visibleFrame
        var r = NSRect(origin: .zero, size: size)
        r.origin.x = store.corner.isRight ? c.maxX - size.width : c.minX
        r.origin.y = store.corner.isTop ? c.maxY - size.height : c.minY
        r.origin.x = min(max(r.origin.x, vf.minX), vf.maxX - size.width)
        r.origin.y = min(max(r.origin.y, vf.minY), vf.maxY - size.height)
        return r
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

    // A move we didn't animate = the user dragged it. Re-derive `home` from the
    // current frame and the anchored corner, then persist.
    private func windowMoved() {
        guard !animating else { return }
        let f = panel.frame
        if store.expanded {
            home.x = store.corner.isRight ? f.maxX - gaugeSize : f.minX
            home.y = store.corner.isTop ? f.maxY - gaugeSize : f.minY
        } else {
            home = f.origin
        }
        UserDefaults.standard.set(NSStringFromPoint(home), forKey: Self.homeKey)
    }

    // MARK: Expand / collapse

    // Expand immediately on hover; collapse after a short grace period so the
    // widget doesn't flicker when the pointer brushes the edge.
    private func hover(_ inside: Bool) {
        collapseTask?.cancel()
        if inside {
            if !store.expanded { expand() }
        } else {
            collapseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                self?.collapse()
            }
        }
    }

    private func expand() {
        store.corner = pickCorner()
        let target = expandedFrame()
        withAnimation(.easeOut(duration: Self.animDuration)) { store.expanded = true }
        animate(to: target)
    }

    private func collapse() {
        guard store.expanded else { return }
        withAnimation(.easeIn(duration: Self.animDuration * 0.8)) { store.expanded = false }
        animate(to: circleFrame)
    }

    private func animate(to target: NSRect) {
        animGen += 1
        let gen = animGen
        animating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.animDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.animGen == gen else { return }
                self.animating = false
                self.panel.invalidateShadow()
                self.relayout()
            }
        })
    }

    // Keeps the window matched to its state when content changes (e.g. a new limit
    // row appears while expanded). Never runs mid-animation.
    private func relayout() {
        guard !animating else { return }
        let target = store.expanded ? expandedFrame() : circleFrame
        guard panel.frame != target else { return }
        animating = true          // suppress windowMoved for this programmatic move
        panel.setFrame(target, display: true)
        animating = false
        panel.invalidateShadow()
    }
}

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

struct UsageWindow: Identifiable {
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

struct TokenStats {
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
    @Published var expanded = false
    @Published var corner: Corner = .topTrailing

    private var token: String?
    private var profileTried = false
    private var timer: Timer?
    private var busy = false

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
        refresh()
        // 90s is plenty; the endpoint rate-limits aggressive polling.
        timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        Task {
            await fetchLimits()
            await scanTokens()
            busy = false
        }
    }

    private func fetchLimits() async {
        if token == nil {
            // Off the main thread: the first Keychain read may show an "Allow" dialog.
            let c = await Task.detached(priority: .utility) { Credentials.read() }.value
            token = c?.token
            if let p = c?.plan { plan = p }
        }
        guard let t = token else {
            status = "No Claude Code login — run `claude` once"
            return
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                let w = Parser.windows(from: try JSONSerialization.jsonObject(with: data))
                windows = w
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
                status = "Rate limited, will retry"
            default:
                status = "HTTP \(code)"
            }
        } catch {
            status = "Network error"
        }
    }

    private func scanTokens() async {
        let now = Date()
        var start5h = now.addingTimeInterval(-5 * 3600)
        if let r = windows.first(where: { $0.id == "five_hour" })?.resetsAt, r > now {
            start5h = r.addingTimeInterval(-5 * 3600)
        }
        let startDay = Calendar.current.startOfDay(for: now)
        let s5 = start5h
        stats = await Task.detached(priority: .utility) {
            LocalLogs.sum(since5h: s5, sinceDay: startDay)
        }.value
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

// Fallback when the stored credentials carry no plan fields.
enum Profile {
    static func plan(token: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        guard let r = try? await URLSession.shared.data(for: req),
              (r.1 as? HTTPURLResponse)?.statusCode == 200,
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

enum LocalLogs {
    private static func roots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var r = [home.appendingPathComponent(".claude/projects"),
                 home.appendingPathComponent(".config/claude/projects")]
        if let c = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            r.insert(URL(fileURLWithPath: c).appendingPathComponent("projects"), at: 0)
        }
        return r
    }

    // Counts input + output + cache-write tokens. Cache reads are excluded:
    // they dwarf everything else and don't reflect real work.
    static func sum(since5h: Date, sinceDay: Date) -> TokenStats {
        let cutoff = min(since5h, sinceDay)
        let fm = FileManager.default
        var seen = Set<String>()
        var s = TokenStats()

        for root in roots() {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard mod >= cutoff, let text = try? String(contentsOf: url, encoding: .utf8) else { continue }

                text.enumerateLines { line, _ in
                    guard line.contains("\"usage\""),
                          let d = line.data(using: .utf8),
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
                    let fam = Family.of(msg["model"] as? String)
                    if t >= since5h {
                        s.total5h += n
                        s.by5h[fam, default: 0] += n
                    }
                    if t >= sinceDay {
                        s.totalDay += n
                        s.byDay[fam, default: 0] += n
                    }
                }
            }
        }
        return s
    }
}

// MARK: - UI

private let contentWidth: CGFloat = 230
private let gaugeSize: CGFloat = 44

func leftColor(_ left: Double) -> Color {
    left > 50 ? .green : left > 20 ? .orange : .red
}

// Root view. The window frame is animated by AppKit; this view fills it, pins its
// content to the anchored corner, and cross-fades gauge <-> panel. The background's
// corner radius animates from circle to rounded rect in step with the frame.
struct MeterView: View {
    @ObservedObject var store: Store

    var body: some View {
        ZStack(alignment: store.corner.alignment) {
            if store.expanded {
                ExpandedPanel(store: store)
                    .transition(.opacity)
            } else {
                Gauge(fiveHour: store.windows.first { $0.id == "five_hour" },
                      sevenDay: store.windows.first { $0.id == "seven_day" },
                      failed: store.windows.isEmpty && store.status != nil)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: store.corner.alignment)
        .clipped()
        .background(VisualEffect(cornerRadius: store.expanded ? 10 : gaugeSize / 2))
        .contentShape(Rectangle())
        .help(store.updatedAt.map { "Updated \($0.formatted(date: .omitted, time: .standard))" } ?? "")
        .contextMenu {
            Button("Refresh") { store.refresh() }
            Button(SMAppService.mainApp.status == .enabled ? "✓ Launch at Login" : "Launch at Login") { toggleLogin() }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
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

struct VisualEffect: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }

    // Animate the radius change so circle -> rounded rect morphs with the frame.
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        guard let layer = v.layer, layer.cornerRadius != cornerRadius else { return }
        let anim = CABasicAnimation(keyPath: "cornerRadius")
        anim.fromValue = layer.cornerRadius
        anim.toValue = cornerRadius
        anim.duration = 0.22
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.cornerRadius = cornerRadius
        layer.add(anim, forKey: "cornerRadius")
    }
}
