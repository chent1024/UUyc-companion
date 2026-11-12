// 远程期间禁用物理屏（CGSConfigureDisplayEnabled 私有 API）及其兜底恢复
// 实测（macOS 27）：
//   - 禁用不受 .forAppOnly 约束，进程退出后不会自动恢复，必须由别的进程重新启用
//   - 被禁用的屏会从 CGGetOnlineDisplayList 中消失，所以禁用前必须先把 ID 写盘
//   - 物理屏全禁用且虚拟屏也移除时，系统会生成一块 1920×1080 占位屏；按 ID 重新启用即可恢复
import CoreGraphics
import Foundation

/// 同步执行一次显示器配置事务。GUI 进程中不可在主线程调用（会与自身重配置通知死锁）
@discardableResult
func applyDisplayConfig(_ body: (CGDisplayConfigRef?) -> CGError) -> CGError {
    var cfg: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&cfg)
    guard begin == .success else { return begin }
    let staged = body(cfg)
    guard staged == .success else { CGCancelDisplayConfiguration(cfg); return staged }
    // Complete 返回后 token 已失效，不能再次 Cancel。
    return CGCompleteDisplayConfiguration(cfg, .forSession)
}

enum PhysicalDisplays {
    private typealias EnableFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private static let setEnabled: EnableFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSConfigureDisplayEnabled")
        .map { unsafeBitCast($0, to: EnableFn.self) }

    static var available: Bool { setEnabled != nil }

    /// 已被禁用、待恢复的物理屏记录
    static let markerURL = ConfigStore.dir.appendingPathComponent("disabled-displays.json")

    struct Disabled: Codable {
        var id: CGDirectDisplayID
        var uuid: String
    }
    struct Record: Codable {
        var boot: Int
        var displays: [Disabled]
        var bootSession: String? = nil
    }
    static var boot: Int {
        var value = timeval(); var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return 0 }
        return value.tv_sec
    }

    static var bootSession: String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
        return UUID(uuidString: String(cString: bytes))?.uuidString
    }

    private static func sameBoot(_ record: Record, currentBoot: Int, currentBootSession: String?) -> Bool {
        if let session = record.bootSession { return session == currentBootSession }
        return currentBoot != 0 && record.boot == currentBoot
    }

    // 同一启动内才能使用禁用前的 ID；跨启动只有 UUID 确认在线的屏才可视为已恢复。
    static func restoreTargets(data: Data, modified: Date, currentBoot: Int,
                               active: (CGDirectDisplayID) -> Bool,
                               uuid: (CGDirectDisplayID) -> String?, currentBootSession: String? = nil) -> [CGDirectDisplayID] {
        if let record = try? JSONDecoder().decode(Record.self, from: data) {
            guard sameBoot(record, currentBoot: currentBoot, currentBootSession: currentBootSession) else { return [] }
            return record.displays.filter { saved in
                guard saved.id != 0, !active(saved.id) else { return false }
                // 软禁用后系统不再提供 UUID；同开机的禁用前记录仍是恢复依据。
                // 一旦能读到不同 UUID 则拒绝，不能操作复用该 ID 的其他屏幕。
                if let current = uuid(saved.id) { return current == saved.uuid }
                return true
            }.map(\.id)
        }
        // 旧记录没有身份；开机前的 ID 不得用于当前屏。已启用屏不再提交 enable。
        guard currentBoot != 0, modified.timeIntervalSince1970 >= Double(currentBoot),
              let ids = try? JSONDecoder().decode([CGDirectDisplayID].self, from: data) else { return [] }
        return ids.filter { $0 != 0 && !active($0) }
    }

    static func mergedRecord(ids: [CGDirectDisplayID], previous: Record?, currentBoot: Int,
                             uuid: (CGDirectDisplayID) -> String?, currentBootSession: String? = nil) -> Record? {
        guard (currentBoot != 0 || currentBootSession != nil), !ids.isEmpty else { return nil }
        var displays: [Disabled] = []
        for id in Set(ids).sorted() {
            guard id != 0 else { return nil }
            let saved = previous.flatMap { old in
                sameBoot(old, currentBoot: currentBoot, currentBootSession: currentBootSession)
                    ? old.displays.first { $0.id == id } : nil
            }
            guard let key = uuid(id) ?? saved?.uuid else { return nil }
            displays.append(Disabled(id: id, uuid: key))
        }
        return Record(boot: currentBoot, displays: displays, bootSession: currentBootSession)
    }

    static func recordIsRestored(data: Data, modified: Date, currentBoot: Int,
                                 active: (CGDirectDisplayID) -> Bool,
                                 uuid: (CGDirectDisplayID) -> String?) -> Bool {
        if let record = try? JSONDecoder().decode(Record.self, from: data) {
            return !record.displays.isEmpty && record.displays.allSatisfy {
                $0.id != 0 && active($0.id) && uuid($0.id) == $0.uuid
            }
        }
        guard currentBoot != 0, modified.timeIntervalSince1970 >= Double(currentBoot),
              let ids = try? JSONDecoder().decode([CGDirectDisplayID].self, from: data), !ids.isEmpty else { return false }
        return ids.allSatisfy { $0 != 0 && active($0) && uuid($0) != nil }
    }

    /// 启用后的热插拔事件可能晚于事务返回；稳定后按实际身份核验再清理。
    @discardableResult
    static func clearResolvedRecord() -> Bool {
        guard let data = try? Data(contentsOf: markerURL),
              let modified = (try? FileManager.default.attributesOfItem(atPath: markerURL.path))?[.modificationDate] as? Date,
              recordIsRestored(data: data, modified: modified, currentBoot: boot,
                active: { CGDisplayIsActive($0) != 0 }, uuid: DisplaySession.uuid),
              (try? Data(contentsOf: markerURL)) == data else { return false }
        do { try FileManager.default.removeItem(at: markerURL); return true }
        catch { Log.info("⚠️ 物理屏已核验，但禁用记录未清理：\(error)"); return false }
    }

    static var pending: [CGDirectDisplayID]? {
        guard let data = try? Data(contentsOf: markerURL),
              let modified = (try? FileManager.default.attributesOfItem(atPath: markerURL.path))?[.modificationDate] as? Date else { return nil }
        let ids = restoreTargets(data: data, modified: modified, currentBoot: boot,
                                 active: { CGDisplayIsActive($0) != 0 },
                                 uuid: DisplaySession.uuid, currentBootSession: bootSession)
            .filter { CGDisplayVendorNumber($0) != 0x5555 }
        return ids.isEmpty ? nil : ids
    }

    /// 先记账再禁用。须在后台队列调用
    static func disable(_ ids: [CGDirectDisplayID]) -> CGError {
        guard let setEnabled, !ids.isEmpty else { return .failure }
        let previous = (try? Data(contentsOf: markerURL)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        guard let record = mergedRecord(ids: (pending ?? []) + ids, previous: previous,
                                       currentBoot: boot, uuid: DisplaySession.uuid, currentBootSession: bootSession),
              (try? JSONEncoder().encode(record).write(to: markerURL, options: .atomic)) != nil else {
            Log.info("❌ 无法写入物理屏记录，放弃禁用")
            return .failure
        }
        return applyDisplayConfig { cfg in
            for id in ids { let err = setEnabled(cfg, id, false); if err != .success { return err } }
            return .success
        }
    }

    /// 按记录重新启用物理屏；保留原始 CGError，让调用方区分超时和等待启用。
    @discardableResult
    static func restore(reason: String) -> CGError {
        guard let ids = pending else { return .success }
        guard let setEnabled else { return .failure }
        let err = applyDisplayConfig { cfg in
            for id in ids where CGDisplayIsActive(id) == 0 {
                let err = setEnabled(cfg, id, true); if err != .success { return err }
            }
            return .success
        }
        if err == .success, clearResolvedRecord() {
            Log.info("✅ 已恢复物理屏 \(ids)（\(reason)）")
            return err
        }
        if err == .success {
            Log.info("已提交物理屏 \(ids) 恢复，等待启用及身份核验（\(reason)）")
            return err
        }
        Log.info("⚠️ 恢复物理屏失败 CGError=\(err.rawValue)（\(reason)），保留恢复记录")
        return err
    }
}
