import Foundation

final class ProgressDisplay {

    // MARK: - ANSI

    private enum C {
        static let reset    = "\u{001B}[0m"
        static let bold     = "\u{001B}[1m"
        static let dim      = "\u{001B}[2m"
        static let cyan     = "\u{001B}[36m"
        static let green    = "\u{001B}[32m"
        static let red      = "\u{001B}[31m"
        static let blue     = "\u{001B}[34m"
        static let magenta  = "\u{001B}[35m"
        static let yellow   = "\u{001B}[33m"
    }

    // MARK: - State

    private enum SlotState {
        case empty
        case active(network: String, title: String, startedAt: Date)
        case done(network: String, title: String, count: Int)
        case failed(network: String, title: String, error: String)
    }

    private let total: Int
    private let concurrency: Int
    private var slots: [SlotState]
    private var completed = 0
    private var failed = 0
    private let startTime = Date()
    private var hasDrawn = false
    private var chatToSlot: [Int: Int] = [:]
    private var freeSlots: [Int]
    private let isTTY: Bool
    private let barWidth = 30

    init(total: Int, concurrency: Int) {
        self.total = total
        self.concurrency = concurrency
        self.slots = Array(repeating: .empty, count: concurrency)
        // reversed so popLast() returns 0 first, 1 second, etc.
        self.freeSlots = Array(stride(from: concurrency - 1, through: 0, by: -1))
        self.isTTY = isatty(STDOUT_FILENO) != 0
    }

    // MARK: - Public API

    func startChat(idx: Int, network: String, title: String) {
        guard isTTY else {
            print("  [\(idx)/\(total)] \(network): \(title)...")
            return
        }
        guard let slot = freeSlots.popLast() else { return }
        chatToSlot[idx] = slot
        slots[slot] = .active(network: network, title: title, startedAt: Date())
        redraw()
    }

    func completeChat(idx: Int, count: Int) {
        guard isTTY else {
            print("  [\(idx)/\(total)] done: \(count) messages")
            return
        }
        guard let slot = chatToSlot.removeValue(forKey: idx) else { return }
        if case .active(let net, let ttl, _) = slots[slot] {
            slots[slot] = .done(network: net, title: ttl, count: count)
        }
        completed += 1
        freeSlots.append(slot)
        redraw()
    }

    func failChat(idx: Int, error: String) {
        guard isTTY else {
            print("  [\(idx)/\(total)] ERROR: \(error)")
            return
        }
        guard let slot = chatToSlot.removeValue(forKey: idx) else { return }
        if case .active(let net, let ttl, _) = slots[slot] {
            slots[slot] = .failed(network: net, title: ttl, error: error)
        }
        failed += 1
        freeSlots.append(slot)
        redraw()
    }

    func finish() {
        guard isTTY else { return }
        print()
    }

    // MARK: - Rendering

    private func redraw() {
        let output = buildDisplay()
        if hasDrawn {
            let lineCount = 2 + concurrency
            for _ in 0..<lineCount {
                print("\u{001B}[1A\u{001B}[2K", terminator: "")
            }
        }
        print(output, terminator: "")
        fflush(stdout)
        hasDrawn = true
    }

    private func buildDisplay() -> String {
        let done = completed + failed
        let pct = total > 0 ? Double(done) / Double(total) : 0
        let filled = Int(pct * Double(barWidth))
        let bar = String(repeating: "█", count: filled)
              + String(repeating: "░", count: barWidth - filled)
        let elapsed = fmt(Date().timeIntervalSince(startTime))

        let okStr  = "\(C.green)\(C.bold)✓\(completed)\(C.reset)"
        let errStr = failed > 0 ? "  \(C.red)\(C.bold)✗\(failed)\(C.reset)" : ""
        let pctStr = "\(C.dim)\(Int(pct * 100))%\(C.reset)"

        let header = "\(C.bold)\(C.blue)Backfill\(C.reset)"
                   + "  \(C.cyan)\(bar)\(C.reset)"
                   + "  \(C.bold)\(done)/\(total)\(C.reset)  \(pctStr)"
                   + "  \(okStr)\(errStr)"
                   + "  \(C.dim)\(elapsed)\(C.reset)"

        let sep = "\(C.dim)" + String(repeating: "─", count: 66) + C.reset

        var lines = [header, sep]
        for slot in slots { lines.append(renderSlot(slot)) }
        return lines.joined(separator: "\n") + "\n"
    }

    private func renderSlot(_ state: SlotState) -> String {
        switch state {
        case .empty:
            return "   \(C.dim)·\(C.reset)"

        case .active(let network, let title, let startedAt):
            let t = fmt(Date().timeIntervalSince(startedAt))
            return "  \(C.cyan)⟳\(C.reset)"
                 + "  \(C.dim)\(col(network, 14))\(C.reset)"
                 + "  \(C.bold)\(col(title, 26))\(C.reset)"
                 + "  \(C.dim)syncing… \(t)\(C.reset)"

        case .done(let network, let title, let count):
            return "  \(C.green)✓\(C.reset)"
                 + "  \(C.dim)\(col(network, 14))\(C.reset)"
                 + "  \(col(title, 26))"
                 + "  \(C.bold)\(C.green)\(count)\(C.reset)\(C.dim) msgs\(C.reset)"

        case .failed(let network, let title, let error):
            return "  \(C.red)✗\(C.reset)"
                 + "  \(C.dim)\(col(network, 14))\(C.reset)"
                 + "  \(col(title, 26))"
                 + "  \(C.red)\(C.dim)\(col(error, 28))\(C.reset)"
        }
    }

    // Fit string to exact visible width: pad with spaces or truncate with ellipsis
    private func col(_ s: String, _ width: Int) -> String {
        if s.count <= width { return s + String(repeating: " ", count: width - s.count) }
        return String(s.prefix(width - 1)) + "…"
    }

    private func fmt(_ t: TimeInterval) -> String {
        let s = Int(t)
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}
