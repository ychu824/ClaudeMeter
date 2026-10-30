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
import ServiceManagement

@main
struct ClaudeMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

// MARK: - Window

final class DragHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var host: DragHostingView<MeterView>!
    private let store = Store()
    private var bag: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon, no menu bar

        host = DragHostingView(rootView: MeterView(store: store))
        let size = host.fittingSize

        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
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

        if !panel.setFrameUsingName("ClaudeMeter"), let vf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 12, y: vf.maxY - size.height - 12))
        }
        panel.setFrameAutosaveName("ClaudeMeter")   // remembers where you dragged it
        panel.orderFrontRegardless()

        bag = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.fit() }
        }
        store.start()
    }

    // Resize to content, keeping the top edge fixed.
    private func fit() {
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        var f = panel.frame
        guard f.size != size else { return }
        let top = f.maxY
        f.size = size
        f.origin.y = top - size.height
        panel.setFrame(f, display: true)
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

struct MeterView: View {
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
                    Divider().opacity(0.5)
                    ModelShare(s: store.stats)
                }
                if let s = store.status {
                    Text(verbatim: s)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: "tok  5h \(fmt(store.stats.total5h)) · today \(fmt(store.stats.totalDay))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: contentWidth + 20, alignment: .leading)
            .background(VisualEffect())
            .help(store.updatedAt.map { "Updated \($0.formatted(date: .omitted, time: .standard))" } ?? "")
            .contextMenu {
                Button("Refresh") { store.refresh() }
                Button(SMAppService.mainApp.status == .enabled ? "✓ Launch at Login" : "Launch at Login") { toggleLogin() }
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            }
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
                Capsule().fill(color(left)).frame(width: 56 * left / 100)
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

    private func color(_ left: Double) -> Color {
        left > 50 ? .green : left > 20 ? .orange : .red
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

// Two stacked bars (5h window, today) showing each model family's share of
// Claude Code tokens, plus a legend with "5h% / today%".
struct ModelShare: View {
    let s: TokenStats
    private let barWidth: CGFloat = contentWidth - 58

    private var present: [String] {
        Family.order.filter { (s.byDay[$0] ?? 0) > 0 || (s.by5h[$0] ?? 0) > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            bar("5h", s.by5h, s.total5h)
            bar("today", s.byDay, s.totalDay)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 2) {
                ForEach(present, id: \.self) { f in
                    HStack(spacing: 4) {
                        Circle().fill(Family.color(f)).frame(width: 6, height: 6)
                        Text(verbatim: "\(f) \(pct(s.by5h[f], s.total5h))/\(pct(s.byDay[f], s.totalDay))")
                            .lineLimit(1)
                    }
                }
            }
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 10, design: .monospaced))
        .help("Share of Claude Code tokens by model (5h / today). Token share ≠ limit share: Opus and Fable tokens count more against limits. claude.ai chats aren't included.")
    }

    private func bar(_ label: String, _ by: [String: Int], _ total: Int) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 52, alignment: .leading)
            HStack(spacing: 0) {
                if total > 0 {
                    ForEach(present, id: \.self) { f in
                        Rectangle()
                            .fill(Family.color(f))
                            .frame(width: barWidth * CGFloat(by[f] ?? 0) / CGFloat(total))
                    }
                }
            }
            .frame(width: barWidth, height: 6, alignment: .leading)
            .background(Color.primary.opacity(0.15))
            .clipShape(Capsule())
        }
    }

    private func pct(_ v: Int?, _ total: Int) -> String {
        guard total > 0 else { return "–" }
        return "\(Int((Double(v ?? 0) / Double(total) * 100).rounded()))%"
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 10
        v.layer?.masksToBounds = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
