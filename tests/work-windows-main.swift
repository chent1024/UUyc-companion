import Foundation
import CoreGraphics

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
private let left = WindowDesktop(display: "external", space: 48, uuid: "external-desktop", soleUserSpace: true)
private let right = WindowDesktop(display: "builtin", space: 1, uuid: "builtin-desktop", soleUserSpace: true)
private let virtual = WindowDesktop(display: "virtual", space: 60, uuid: "remote-desktop", soleUserSpace: true)

private final class Windows: WorkWindowAccess {
    var originals: [SavedWorkWindow]
    var current: [WorkWindowID: WorkWindowState]
    var events: [String] = []
    var writes: [(WorkWindowID, Bool)] = []
    var pending: [() -> Void] = []
    var ignoreWrites = false
    var unreadable: Set<WorkWindowID> = []
    var destinationIsVirtual = false
    var minimumWidth: CGFloat = 0
    var missingDisplays: Set<String> = []
    init(_ frames: [CGRect]) {
        originals = frames.enumerated().map { i, frame in
            SavedWorkWindow(id: WorkWindowID(pid: 100 + Int32(i), launch: Date(timeIntervalSince1970: 100), number: UInt32(i + 1)),
                state: WorkWindowState(frame: frame, minimized: false, fullscreen: false,
                                       desktop: frame.minX < 0 ? left : right), visible: true)
        }
        current = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0.state) })
    }
    func capture() -> [SavedWorkWindow]? { originals }
    func desktopAvailable(_ desktop: WindowDesktop) -> Bool { !missingDisplays.contains(desktop.display) }
    func read(_ id: WorkWindowID) -> WorkWindowRead {
        if unreadable.contains(id) { return .unavailable }
        return current[id].map(WorkWindowRead.window) ?? .closed
    }
    func move(_ id: WorkWindowID, to point: CGPoint) -> Bool {
        writes.append((id, false)); events.append("position")
        guard !ignoreWrites else { return true }
        pending.append { [self] in
            guard current[id] != nil else { return }
            current[id]!.frame.origin = point
            current[id]!.desktop = destinationIsVirtual ? virtual : (point.x < 0 ? left : right)
        }
        return true
    }
    func resize(_ id: WorkWindowID, to size: CGSize) -> Bool {
        writes.append((id, true)); events.append("size")
        guard !ignoreWrites else { return true }
        // 模拟跨屏后要等一轮才能使用目标屏尺寸：即时 position/size/position 会被旧屏钳制。
        let limit: CGFloat = current[id]!.desktop?.display == "virtual" ? 488 :
            (current[id]!.desktop?.display == "external" ? 2048 : 1728)
        pending.append { [self] in
            current[id]!.frame.size = CGSize(width: max(minimumWidth, min(size.width, limit)), height: size.height)
        }
        return true
    }
    func settle() {
        let work = pending; pending = []
        work.forEach { $0() }
    }
    func remote() {
        for key in current.keys {
            current[key]!.frame = CGRect(x: 0, y: 30, width: 488, height: 1008)
            current[key]!.desktop = virtual
        }
    }
}

private func run(_ session: WorkWindowSession, _ windows: Windows, _ goal: WorkWindowSession.Goal) -> WorkWindowSession.Progress {
    for _ in 0..<20 {
        let result = session.advance(goal)
        windows.settle()
        if result != .pending { return result }
    }
    fatalError("unbounded window convergence")
}

@main enum WindowTests {
    static func main() {
        // 实测失配的五个几何形态：Terminal、两个浏览器窗口、Codex、外屏聊天窗口。
        let frames = [CGRect(x: 0, y: 33, width: 1280, height: 768),
                      CGRect(x: -2048, y: 30, width: 2048, height: 1122),
                      CGRect(x: -2048, y: 30, width: 2048, height: 1122),
                      CGRect(x: 0, y: 33, width: 1728, height: 1028),
                      CGRect(x: -1268, y: 30, width: 488, height: 1028)]
        do {
            let windows = Windows(frames)
            let session = WorkWindowSession(access: windows)!
            windows.remote()
            expect(run(session, windows, .restore) == .complete(verified: 5, skipped: 0), "staged restore must converge")
            for original in windows.originals {
                expect(windows.current[original.id]!.frame == original.state.frame, "must restore exact geometry")
                expect(windows.current[original.id]!.desktop == original.state.desktop, "must restore correct physical display/desktop")
            }
            expect(windows.events.first == "position" && windows.events.contains("size"), "must move before resizing")
        }
        do {
            let windows = Windows([frames[1]])
            windows.remote()
            let id = windows.originals[0].id
            _ = windows.move(id, to: frames[1].origin)
            _ = windows.resize(id, to: frames[1].size)
            _ = windows.move(id, to: frames[1].origin)
            windows.settle()
            expect(windows.current[id]!.frame.width == 488, "counterexample: immediate setters report success but preserve wrong size")
        }
        do {
            let windows = Windows([frames[0]])
            let session = WorkWindowSession(access: windows)!
            windows.remote(); windows.ignoreWrites = true
            expect(run(session, windows, .restore) == .failed([1]), "successful AX return cannot hide a mismatching readback")
            let writes = windows.writes.count
            _ = session.advance(.restore)
            expect(windows.writes.count == writes, "failed restoration must not retry forever")
        }
        do {
            let windows = Windows([frames[0], frames[1], frames[2], frames[3]])
            windows.originals[0].state.minimized = true
            windows.originals[1].state.fullscreen = true
            windows.originals[2].visible = false
            windows.current = Dictionary(uniqueKeysWithValues: windows.originals.map { ($0.id, $0.state) })
            let session = WorkWindowSession(access: windows)!
            windows.destinationIsVirtual = true
            let area = CGRect(x: 0, y: 30, width: 488, height: 1008)
            expect(run(session, windows, .collect(area)) == .complete(verified: 1, skipped: 3), "only visible ordinary work windows collect")
            expect(windows.writes.allSatisfy { $0.0 == windows.originals[3].id }, "minimized/fullscreen/other Spaces must never receive a write")
            windows.destinationIsVirtual = false
            expect(run(session, windows, .restore) == .complete(verified: 2, skipped: 2), "ordinary other-Space window remains verified in place")
        }
        do {
            let windows = Windows([frames[1]])
            let session = WorkWindowSession(access: windows)!
            windows.current.removeAll()
            expect(run(session, windows, .restore) == .complete(verified: 0, skipped: 1), "closed window must not be replaced by a new same-title window")
            expect(windows.writes.isEmpty, "closed window no write")
        }
        do {
            let windows = Windows([frames[1]])
            let session = WorkWindowSession(access: windows)!
            windows.unreadable.insert(windows.originals[0].id)
            expect(run(session, windows, .restore) == .failed([1]), "AX unavailable must not mean closed/successful")
        }
        do {
            let windows = Windows([frames[1]])
            let session = WorkWindowSession(access: windows)!
            windows.current[windows.originals[0].id]!.desktop = WindowDesktop(display: "external", space: 62, uuid: "rebuilt", soleUserSpace: true)
            expect(run(session, windows, .restore) == .complete(verified: 1, skipped: 0), "unique user desktop can be recreated")
            var multi = left; multi.soleUserSpace = false
            let changed = WindowDesktop(display: "external", space: 62, uuid: "different", soleUserSpace: false)
            expect(!multi.matches(changed), "must not guess amongst multiple Spaces")
            multi.uuid = ""
            var empty = changed; empty.uuid = ""
            expect(!multi.matches(empty), "empty UUIDs are not matching desktop identities")
            expect(!left.matches(right), "must not accept a matching frame on wrong display")
        }
        do {
            let windows = Windows([frames[1]])
            windows.minimumWidth = 600
            let session = WorkWindowSession(access: windows)!
            windows.destinationIsVirtual = true
            expect(run(session, windows, .collect(CGRect(x: 0, y: 30, width: 488, height: 1008))) == .complete(verified: 1, skipped: 0), "allow app minimum size while keeping top-left reachable")
            expect(windows.current[windows.originals[0].id]!.frame.minX == 0, "never align oversized window to negative left edge")
            windows.destinationIsVirtual = false
            expect(run(session, windows, .restore) == .complete(verified: 1, skipped: 0), "collect then restore must reset phase and use immutable original")
        }
        do {
            let windows = Windows([frames[1]])
            let session = WorkWindowSession(access: windows)!
            windows.remote(); windows.missingDisplays.insert("external")
            expect(run(session, windows, .restore) == .failed([1]), "missing original display is not a successful restore")
            expect(windows.writes.isEmpty, "must not move a window into an absent screen")
        }
        do {
            let windows = Windows([frames[0]])
            windows.originals[0].state.minimized = true
            windows.current[windows.originals[0].id]!.minimized = false
            let session = WorkWindowSession(access: windows)!
            expect(run(session, windows, .restore) == .failed([1]), "system-changed special state must be reported, never silently verified")
            expect(windows.writes.isEmpty, "never force original minimized/fullscreen state")
        }
        print("PASS: 10 window-session groups (no live application or display writes)")
    }
}
