// 一次连接的窗口原位记录。只存在于内存，不以标题匹配，不写最小化/全屏或切换 Spaces。
import Foundation
import CoreGraphics

struct WorkWindowID: Hashable {
    var pid: Int32
    var launch: Date
    var number: UInt32
}

struct WorkWindowState {
    var frame: CGRect
    var minimized: Bool
    var fullscreen: Bool
    var desktop: WindowDesktop?
}

/// 数字 Space ID 在屏幕热插拔后可能重建；只允许原 UUID，或同显示器唯一普通桌面的确定映射。
struct WindowDesktop: Equatable {
    var display: String
    var space: UInt64
    var uuid: String?
    var soleUserSpace: Bool

    func matches(_ other: Self) -> Bool {
        guard display == other.display else { return false }
        if space == other.space { return true }
        if let uuid, !uuid.isEmpty, let otherUUID = other.uuid, uuid == otherUUID { return true }
        return soleUserSpace && other.soleUserSpace
    }
}

struct SavedWorkWindow {
    var id: WorkWindowID
    var state: WorkWindowState
    /// 只收拢原先可见的普通工作窗口，其他桌面的窗口保持原状态。
    var visible: Bool
}

enum WorkWindowRead {
    case window(WorkWindowState)
    case closed
    case unavailable(String)
}

/// 原生边界集中于此；测试用隔离窗口替身，不接触用户桌面。
protocol WorkWindowAccess: AnyObject {
    func capture() -> [SavedWorkWindow]?
    func read(_ id: WorkWindowID) -> WorkWindowRead
    func move(_ id: WorkWindowID, to: CGPoint) -> Bool
    func resize(_ id: WorkWindowID, to: CGSize) -> Bool
    func desktopAvailable(_ desktop: WindowDesktop) -> Bool
}

final class WorkWindowSession {
    enum Goal: Equatable {
        case collect(CGRect)
        case restore
    }
    enum Progress: Equatable {
        case pending
        case waitingForMetadata
        case complete(verified: Int, skipped: Int)
        case failed([UInt32])
    }
    private let access: WorkWindowAccess
    let windows: [SavedWorkWindow]
    private var goal: Goal?
    private var pass = 0
    private var stable = 0
    private var finished: Progress?
    private(set) var mismatches: [UInt32] = []
    private(set) var mismatchReasons: [UInt32: String] = [:]
    private var metadataWaitSince: TimeInterval?
    private var metadataWaitReported = false

    /// 锁屏不是窗口恢复失败；不丢弃原位，解锁后从换屏阶段重新核对。
    func suspendForLockedScreen() {
        pass = 0; stable = 0; finished = nil
        metadataWaitSince = nil; metadataWaitReported = false
    }

    let captureAttempts: Int

    init?(access: WorkWindowAccess, retryDelay: () -> Void = { Thread.sleep(forTimeInterval: 0.5) }) {
        // UU 切换连接/模式时 AX 窗口表可能暂不可读。仅重采样，不写任何窗口或显示配置。
        var captured: [SavedWorkWindow]?
        var attempts = 0
        for attempt in 0..<3 {
            attempts += 1
            captured = access.capture()
            if captured != nil { break }
            if attempt < 2 { retryDelay() }
        }
        guard let windows = captured else { return nil }
        self.access = access
        self.windows = windows
        self.captureAttempts = attempts
    }

    /// 空闲采样的原始几何不可被活动会话的收拢/归位进度覆盖。
    func forConnection() -> WorkWindowSession {
        WorkWindowSession(access: access, windows: windows, captureAttempts: captureAttempts)
    }

    private init(access: WorkWindowAccess, windows: [SavedWorkWindow], captureAttempts: Int) {
        self.access = access
        self.windows = windows
        self.captureAttempts = captureAttempts
    }

    /// 每次只做一个阶段，调用方须让出运行循环等待后再调用。
    /// 先换屏，再改尺寸，再校正位置；不能把 AX 返回 success 当成落地成功。
    func advance(_ next: Goal, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Progress {
        if goal != next {
            goal = next; pass = 0; stable = 0; finished = nil
            metadataWaitSince = nil; metadataWaitReported = false
        }
        if let finished { return finished }
        let observations = windows.map { ($0, access.read($0.id)) }
        var notReady: [UInt32: String] = [:]
        for (saved, result) in observations {
            switch result {
            case .closed: break
            case .unavailable(let reason): notReady[saved.id.number] = reason
            case .window(let now):
                guard !saved.state.minimized, !saved.state.fullscreen, !now.minimized, !now.fullscreen else { continue }
                if next == .restore {
                    if now.desktop == nil { notReady[saved.id.number] = "current desktop metadata unavailable" }
                    else if let desktop = saved.state.desktop, !access.desktopAvailable(desktop) {
                        notReady[saved.id.number] = "original display absent from desktop metadata: \(desktop.display)"
                    }
                }
            }
        }
        if !notReady.isEmpty {
            mismatchReasons = notReady
            mismatches = notReady.keys.sorted()
            stable = 0
            let start = metadataWaitSince ?? now
            metadataWaitSince = start
            if now - start >= 15 {
                let result = Progress.failed(mismatches)
                finished = result
                return result
            }
            if !metadataWaitReported { metadataWaitReported = true; return .waitingForMetadata }
            return .pending
        }
        metadataWaitSince = nil; metadataWaitReported = false
        mismatchReasons = [:]
        var bad: [UInt32] = []
        var verified = 0
        var skipped = 0
        for (saved, result) in observations {
            switch result {
            case .closed: skipped += 1
            case .unavailable(let reason): bad.append(saved.id.number); mismatchReasons[saved.id.number] = reason
            case .window(let now):
                // 用户在连接期间改变的特殊状态也不强行还原。
                if saved.state.minimized || saved.state.fullscreen {
                    if saved.state.minimized != now.minimized || saved.state.fullscreen != now.fullscreen {
                        bad.append(saved.id.number)
                        mismatchReasons[saved.id.number] = "minimized/fullscreen state changed; not forced"
                    } else { skipped += 1 }
                    continue
                }
                guard !now.minimized, !now.fullscreen else { skipped += 1; continue }
                let target: CGRect
                let matches: Bool
                switch next {
                case .collect(let area):
                    guard saved.visible else { skipped += 1; continue }
                    target = CGRect(origin: area.origin, size: CGSize(
                        width: min(saved.state.frame.width, area.width),
                        height: min(saved.state.frame.height, area.height)))
                    // 应用的最小尺寸可能大于手机宽度；保住左上角和标题栏，不假报精确缩小。
                    matches = pass >= 2 && abs(now.frame.minX - area.minX) <= 1 && abs(now.frame.minY - area.minY) <= 1 &&
                        now.frame.intersects(area)
                case .restore:
                    target = saved.state.frame
                    guard let originalDesktop = saved.state.desktop, let desktop = now.desktop,
                          access.desktopAvailable(originalDesktop) else {
                        bad.append(saved.id.number); mismatchReasons[saved.id.number] = "original/current desktop metadata missing"; continue
                    }
                    matches = Self.near(now.frame, target) && originalDesktop.matches(desktop)
                    // 非当前桌面的窗口不主动跨桌面移动；仍核验原归属，不能把跳过当成已恢复。
                    if !saved.visible && !matches {
                        bad.append(saved.id.number)
                        mismatchReasons[saved.id.number] = "other desktop retained; geometry/desktop differs"
                        continue
                    }
                }
                if matches { verified += 1; continue }
                bad.append(saved.id.number)
                let geometry = Self.near(now.frame, target)
                let desktop = saved.state.desktop.map { original in now.desktop.map { original.matches($0) } ?? false } ?? false
                mismatchReasons[saved.id.number] = "geometry=\(geometry), desktop=\(desktop), originalDisplay=\(saved.state.desktop?.display ?? "unknown"), currentDisplay=\(now.desktop?.display ?? "unknown"), originalSpace=\(String(describing: saved.state.desktop?.space)), currentSpace=\(String(describing: now.desktop?.space)), originalSingle=\(String(describing: saved.state.desktop?.soleUserSpace)), currentSingle=\(String(describing: now.desktop?.soleUserSpace))"
                // 第 3/4 个阶段只读取，连续两次一致后才完成；最多三轮写入。
                if pass < 15 {
                    switch pass % 5 {
                    case 0, 2: _ = access.move(saved.id, to: target.origin)
                    case 1: _ = access.resize(saved.id, to: target.size)
                    default: break
                    }
                }
            }
        }
        mismatches = bad
        pass += 1
        if bad.isEmpty { stable += 1 } else { stable = 0 }
        if stable >= 2 {
            let result = Progress.complete(verified: verified, skipped: skipped)
            finished = result
            return result
        }
        if pass >= 17, stable == 0 {
            let result = Progress.failed(bad)
            finished = result
            return result
        }
        return .pending
    }

    private static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 &&
        abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }
}
