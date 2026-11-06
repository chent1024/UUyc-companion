// 只记录本次连接前的物理屏；UUID 用于跨热插拔/重启匹配，模式 ID 不能单独标识模式。
import CoreGraphics
import ApplicationServices
import Foundation

struct SavedDisplayMode: Codable, Equatable {
    var id: Int32
    var width: Int
    var height: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var refreshRate: Double
    var flags: UInt32
    var usable: Bool

    init(_ mode: CGDisplayMode) {
        id = mode.ioDisplayModeID
        width = mode.width; height = mode.height
        pixelWidth = mode.pixelWidth; pixelHeight = mode.pixelHeight
        refreshRate = mode.refreshRate; flags = mode.ioFlags
        usable = mode.isUsableForDesktopGUI()
    }

    func matches(_ other: SavedDisplayMode) -> Bool {
        width == other.width && height == other.height && pixelWidth == other.pixelWidth &&
        pixelHeight == other.pixelHeight && abs(refreshRate - other.refreshRate) < 0.01 &&
        flags == other.flags && usable == other.usable
    }

    func resolve(in modes: [CGDisplayMode]) -> CGDisplayMode? {
        // 零刷新率也必须精确匹配；不能把动态刷新率或 HiDPI 换成相近的固定模式。
        let exact = modes.filter { matches(SavedDisplayMode($0)) }
        return exact.first { $0.ioDisplayModeID == id } ?? exact.first
    }
}

struct SavedDisplay: Codable, Equatable {
    var uuid: String
    var mode: SavedDisplayMode
    var x: Int32
    var y: Int32
    var mirror: String?
}

struct DisplaySession: Codable {
    var version = 1
    var displays: [SavedDisplay]
    static let url = ConfigStore.dir.appendingPathComponent("display-session.json")

    static func uuid(_ id: CGDirectDisplayID) -> String? {
        guard let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, value) as String
    }

    static func online() -> [CGDirectDisplayID] {
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &n) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        guard CGGetOnlineDisplayList(n, &ids, &n) == .success else { return [] }
        return Array(ids.prefix(Int(n)))
    }

    static func capture() -> DisplaySession? {
        let ids = online().filter { CGDisplayVendorNumber($0) != 0x5555 }
        var saved: [SavedDisplay] = []
        for id in ids {
            guard let key = uuid(id), let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            let origin = CGDisplayBounds(id).origin
            let master = CGDisplayMirrorsDisplay(id)
            saved.append(SavedDisplay(uuid: key, mode: SavedDisplayMode(mode),
                                      x: Int32(origin.x), y: Int32(origin.y),
                                      mirror: master == kCGNullDirectDisplay ? nil : uuid(master)))
        }
        guard !saved.isEmpty, Set(saved.map(\.uuid)).count == saved.count else { return nil }
        return DisplaySession(displays: saved)
    }

    func save(to url: URL = Self.url) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    static func load(from url: URL = Self.url) throws -> DisplaySession {
        let session = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard session.version == 1, !session.displays.isEmpty,
              Set(session.displays.map(\.uuid)).count == session.displays.count,
              session.displays.allSatisfy({ saved in
                  UUID(uuidString: saved.uuid) != nil &&
                  [saved.mode.width, saved.mode.height, saved.mode.pixelWidth, saved.mode.pixelHeight]
                    .allSatisfy { (1...65536).contains($0) } &&
                  saved.mode.refreshRate.isFinite && saved.mode.refreshRate >= 0 &&
                  Int64(saved.x) + Int64(saved.mode.width) <= Int64(Int32.max) &&
                  (saved.mirror == nil || (saved.mirror != saved.uuid && UUID(uuidString: saved.mirror!) != nil))
              }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return session
    }

    /// 缺席屏不以复用的数字 ID 替代；保留其记录，允许当前在线屏恢复。
    func verified(includeLayout: Bool = true) -> Bool {
        let ids = Self.online()
        return displays.allSatisfy { saved in
            guard let id = ids.first(where: { Self.uuid($0) == saved.uuid }) else { return true }
            guard let current = CGDisplayCopyDisplayMode(id) else { return false }
            let p = CGDisplayBounds(id).origin
            let master = CGDisplayMirrorsDisplay(id)
            let mirror = master == kCGNullDirectDisplay ? nil : Self.uuid(master)
            return saved.mode.matches(SavedDisplayMode(current)) && (!includeLayout ||
                (Int32(p.x) == saved.x && Int32(p.y) == saved.y && mirror == saved.mirror))
        }
    }

    func offline() -> DisplaySession? {
        let onlineKeys = Set(Self.online().compactMap(Self.uuid))
        let missing = displays.filter { !onlineKeys.contains($0.uuid) }
        return missing.isEmpty ? nil : DisplaySession(displays: missing)
    }

    /// 必须在配置队列执行。已有正确配置时不提交空事务。
    func restore(includeLayout: Bool = true, retaining virtualIDs: [CGDirectDisplayID] = []) -> CGError {
        if verified(includeLayout: includeLayout) { return .success }
        let ids = Self.online()
        var targets: [(SavedDisplay, CGDirectDisplayID, CGDisplayMode)] = []
        for saved in displays {
            guard let id = ids.first(where: { Self.uuid($0) == saved.uuid }) else { continue }
            let modes = CGDisplayCopyAllDisplayModes(id,
                [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] ?? []
            guard let mode = saved.mode.resolve(in: modes) else {
                Log.info("⚠️ 原显示模式暂不可用，保留恢复记录：\(saved.uuid)")
                return .cannotComplete
            }
            if let mirror = saved.mirror, !ids.contains(where: { Self.uuid($0) == mirror }) { return .cannotComplete }
            targets.append((saved, id, mode))
        }
        guard !targets.isEmpty else { return .success }
        return applyDisplayConfig { cfg in
            for (_, id, mode) in targets {
                let err = CGConfigureDisplayWithDisplayMode(cfg, id, mode, nil)
                if err != .success { return err }
            }
            if !includeLayout { return .success }
            // 先解除/恢复镜像，再放置独立屏；设置镜像从屏的原点会解除镜像。
            for (saved, id, _) in targets {
                let master = saved.mirror.flatMap { key in ids.first { Self.uuid($0) == key } } ?? kCGNullDirectDisplay
                let err = CGConfigureDisplayMirrorOfDisplay(cfg, id, master)
                if err != .success { return err }
            }
            for (saved, id, _) in targets where saved.mirror == nil {
                let err = CGConfigureDisplayOrigin(cfg, id, saved.x, saved.y)
                if err != .success { return err }
            }
            // 虚拟屏仍存活时先交还原主屏，避免释放主屏后立即向变动中的拓扑提交事务。
            if let edge = targets.filter({ $0.0.mirror == nil }).max(by: {
                Int($0.0.x) + $0.0.mode.width < Int($1.0.x) + $1.0.mode.width
            }) {
                var right = Int64(edge.0.x) + Int64(edge.0.mode.width)
                for id in virtualIDs where ids.contains(id) {
                    guard right <= Int64(Int32.max) else { return .rangeCheck }
                    let err = CGConfigureDisplayOrigin(cfg, id, Int32(right), edge.0.y)
                    if err != .success { return err }
                    right += Int64(CGDisplayBounds(id).width)
                }
            }
            return .success
        }
    }
}
