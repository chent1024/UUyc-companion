import AppKit
import ApplicationServices

/// 仅查询普通应用的窗口身份、几何和状态，不读取标题、文档或窗口内容。
/// 私有只读接口的声明参考 Hammerspoon extensions/spaces/private.h；不切换/创建/删除 Spaces。
final class AccessibilityWindows: WorkWindowAccess {
    private typealias WindowNumber = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias Connection = @convention(c) () -> Int32
    private typealias DisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias WindowSpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private let number = AccessibilityWindows.symbol("_AXUIElementGetWindow", WindowNumber.self)
    private let connection = AccessibilityWindows.symbol("SLSMainConnectionID", Connection.self)
    private let displays = AccessibilityWindows.symbol("SLSCopyManagedDisplaySpaces", DisplaySpaces.self)
    private let spaces = AccessibilityWindows.symbol("SLSCopySpacesForWindows", WindowSpaces.self)
    private struct Handle {
        let app: NSRunningApplication
        let element: AXUIElement
    }
    private var handles: [WorkWindowID: Handle] = [:]
    private(set) var captureFailure: String?

    private func fail(_ reason: String) -> [SavedWorkWindow]? {
        captureFailure = reason
        return nil
    }
    private let applications: () -> [NSRunningApplication]

    init(applications: @escaping () -> [NSRunningApplication] = { NSWorkspace.shared.runningApplications }) {
        self.applications = applications
    }

    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
    }

    func capture() -> [SavedWorkWindow]? {
        captureFailure = nil
        guard AXIsProcessTrusted(), number != nil, connection != nil, displays != nil, spaces != nil else { return fail("AX authorization or native window/desktop query unavailable") }
        handles = [:]
        guard let rows = Self.rows() else { return fail("CG window list unavailable") }
        var saved: [SavedWorkWindow] = []
        for app in applications() where app.activationPolicy == .regular && !app.isTerminated {
            guard app.processIdentifier != getpid() else { continue }
            let pid = app.processIdentifier
            let appRows = rows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }
            guard !appRows.isEmpty else { continue }
            guard let launch = Self.launchTime(pid) else { return fail("kernel process identity unavailable, pid=\(pid)") }
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, 0.2)
            guard let windows = Self.get(ax, kAXWindowsAttribute) as? [AXUIElement] else { return fail("AX window list unavailable, pid=\(pid)") }
            for element in windows {
                AXUIElementSetMessagingTimeout(element, 0.2)
                guard let role = Self.get(element, kAXRoleAttribute) as? String else {
                    return fail("window role unavailable, pid=\(pid)")
                }
                if role == kAXScrollAreaRole { continue } // Finder 桌面不是工作窗口。
                guard role == kAXWindowRole else { return fail("unexpected AXWindows role=\(role), pid=\(pid)") }
                guard let subrole = Self.get(element, kAXSubroleAttribute) as? String else {
                    return fail("window subrole unavailable, pid=\(pid)")
                }
                // 实测 AppKit 最小化后可报告 AXDialog；仍保存身份/状态，但绝不搬动。
                if subrole != kAXStandardWindowSubrole {
                    let minimized = Self.get(element, kAXMinimizedAttribute) as? Bool
                    let fullscreen = Self.get(element, "AXFullScreen") as? Bool
                    guard minimized == true || fullscreen == true else { continue }
                }
                var id: CGWindowID = 0
                guard number?(element, &id) == .success,
                      let row = appRows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }) else { return fail("AX/CG identity mismatch, pid=\(pid)") }
                let key = WorkWindowID(pid: pid, launch: launch, number: id)
                if let existing = handles[key] {
                    guard CFEqual(existing.element, element) else { return fail("duplicate window identity, id=\(id)") }
                    continue
                }
                handles[key] = Handle(app: app, element: element)
                guard case .window(let state) = read(key), state.frame.width > 0, state.frame.height > 0 else { return fail("window geometry/state unavailable, id=\(id)") }
                // 未知桌面归属不能生成一个声称可以精确恢复的普通窗口基线。
                guard state.minimized || state.fullscreen || state.desktop != nil else { return fail("ordinary window desktop ambiguous, id=\(id)") }
                saved.append(SavedWorkWindow(id: key, state: state,
                    visible: (row[kCGWindowIsOnscreen as String] as? Bool) == true && !app.isHidden))
            }
        }
        return saved
    }

    func read(_ id: WorkWindowID) -> WorkWindowRead {
        guard let h = handles[id], !h.app.isTerminated,
              let live = NSRunningApplication(processIdentifier: id.pid), !live.isTerminated,
              Self.launchTime(id.pid) == id.launch else { return .closed }
        guard let rows = Self.rows() else { return .unavailable }
        guard let row = rows.first(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id.number &&
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == id.pid
        }) else { return .closed }
        var actual: CGWindowID = 0
        guard number?(h.element, &actual) == .success, actual == id.number else { return .unavailable }
        let keys = [kAXMinimizedAttribute, "AXFullScreen"]
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(h.element, keys as CFArray,
                AXCopyMultipleAttributeOptions(rawValue: 0), &result) == .success,
              let values = result as? [Any], values.count == 2,
              let minimized = values[0] as? Bool, let fullscreen = values[1] as? Bool,
              let bounds = row[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return .unavailable }
        // 几何以 WindowServer 的实际边界为准；AX 负责身份、特殊状态和写入。
        guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else { return .unavailable }
        return .window(WorkWindowState(frame: frame, minimized: minimized, fullscreen: fullscreen, desktop: desktop(id.number)))
    }

    func move(_ id: WorkWindowID, to point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return set(id, kAXPositionAttribute, value)
    }

    func resize(_ id: WorkWindowID, to size: CGSize) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return set(id, kAXSizeAttribute, value)
    }

    private func set(_ id: WorkWindowID, _ name: String, _ value: AXValue) -> Bool {
        // 写前再次核对原实例及特殊状态，不激活/raise，不修改最小化或全屏标志。
        guard case .window(let now) = read(id), !now.minimized, !now.fullscreen,
              let h = handles[id] else { return false }
        return AXUIElementSetAttributeValue(h.element, name as CFString, value) == .success
    }

    private func desktop(_ id: UInt32) -> WindowDesktop? {
        guard let connection, let displays, let spaces,
              let membership = spaces(connection(), 7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber],
              membership.count == 1,
              let topology = displays(connection())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let sid = membership[0].uint64Value
        for display in topology {
            guard let key = display["Display Identifier"] as? String,
                  let list = display["Spaces"] as? [[String: Any]] else { continue }
            let normal = list.filter { ($0["type"] as? NSNumber)?.intValue == 0 }
            if let space = normal.first(where: { Self.spaceID($0) == sid }) {
                return WindowDesktop(display: key, space: sid, uuid: space["uuid"] as? String, soleUserSpace: normal.count == 1)
            }
        }
        return nil
    }

    func desktopAvailable(_ desktop: WindowDesktop) -> Bool {
        guard let connection, let displays,
              let topology = displays(connection())?.takeRetainedValue() as? [[String: Any]] else { return false }
        return topology.contains { ($0["Display Identifier"] as? String) == desktop.display }
    }

    /// LaunchServices 不总能提供系统应用的 launchDate；统一使用内核启动时间防止 PID 复用。
    private static func launchTime(_ pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    private static func spaceID(_ value: [String: Any]) -> UInt64? {
        (value["ManagedSpaceID"] as? NSNumber ?? value["id64"] as? NSNumber)?.uint64Value
    }

    private static func get(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func rows() -> [[String: Any]]? {
        (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]])?.filter {
            ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }
    }
}
