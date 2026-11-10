import ApplicationServices
import Foundation

@main struct DisplaySessionTests {
    static func main() throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let file = dir.appendingPathComponent("session.json")
        let captured = DisplaySession.capture()!
        precondition(!captured.displays.isEmpty, "须有可读取模式的物理屏")
        precondition(captured.verified())
        let redmi = DeviceConfig(name: "Redmi22081212C", kind: .phone, width: 488, height: 1084)
        // 2026-11-06 实机 #7：在线、active、已设主屏，但当前模式和可用模式均为空。
        var readiness = VirtualDisplayReadiness(online: true, active: true, mode: nil)
        precondition(readiness.isOnline, "缺少模式元数据不能判定已在线的虚拟屏离线")
        precondition(!readiness.modeMatches(redmi), "模式缺失时不能关闭物理屏")
        precondition(!readiness.canKeepOnlyVirtual(redmi))
        let unknownStatus = readiness.status(for: redmi)
        precondition(unknownStatus.contains("模式未确认") && !unknownStatus.contains("高清") && !unknownStatus.contains("已匹配"))
        readiness.active = false
        precondition(!readiness.isOnline)
        precondition(!readiness.canKeepOnlyVirtual(redmi))
        readiness.active = true; readiness.online = false
        precondition(!readiness.isOnline)
        precondition(!readiness.canKeepOnlyVirtual(redmi))

        // 合成可读模式用于边界测试，不作为红米实际 HiDPI 已启用的证据。
        var readable = captured.displays[0].mode
        readable.width = 244; readable.height = 542
        readable.pixelWidth = 488; readable.pixelHeight = 1084; readable.usable = true
        readiness = VirtualDisplayReadiness(online: true, active: true, mode: readable)
        precondition(readiness.modeMatches(redmi))
        precondition(readiness.canKeepOnlyVirtual(redmi))
        precondition(readiness.status(for: redmi).contains("高清"))
        readable.width = 488; readable.height = 1084
        readiness.mode = readable
        precondition(readiness.isOnline && !readiness.modeMatches(redmi), "实际为 1x 时保留屏幕，但不能宣称符合 HiDPI 配置")
        precondition(readiness.canKeepOnlyVirtual(redmi), "11/8 红米复现：实际 1x 可用且像素正确时，也应只保留虚拟屏")
        precondition(readiness.status(for: redmi).contains("标准模式") && readiness.status(for: redmi).contains("HiDPI 未启用"))
        precondition(!readiness.status(for: redmi).contains("高清"))
        var standard = redmi; standard.hiDPI = false
        precondition(readiness.modeMatches(standard) && !readiness.status(for: standard).contains("高清"))
        readable.pixelWidth = 976; readiness.mode = readable
        precondition(readiness.isOnline && !readiness.modeMatches(standard))
        precondition(!readiness.canKeepOnlyVirtual(standard), "像素尺寸错误不能关闭物理屏")
        readable.pixelWidth = 488; readable.usable = false; readiness.mode = readable
        precondition(readiness.isOnline && !readiness.modeMatches(standard), "桌面模式核验失败不能关闭物理屏")
        precondition(!readiness.canKeepOnlyVirtual(standard))
        readable.usable = true; readable.width = 244; readable.height = 542
        readiness.mode = readable
        precondition(readiness.canKeepOnlyVirtual(standard) && !readiness.modeMatches(standard), "可用像素匹配与请求的逻辑缩放是独立条件")
        readable.pixelHeight = 1080; readiness.mode = readable
        precondition(!readiness.canKeepOnlyVirtual(standard), "像素高度错误不能关闭物理屏")
        readable.pixelHeight = 1084; readable.width = 0; readiness.mode = readable
        precondition(!readiness.canKeepOnlyVirtual(standard), "无有效逻辑画布不能关闭物理屏")
        readiness.mode = nil
        precondition(readiness.isOnline && !readiness.modeMatches(redmi), "模式证据消失后仍保留屏幕，并收回禁用物理屏的条件")
        precondition(!readiness.canKeepOnlyVirtual(redmi))
        try captured.save(to: file)
        let loaded = try DisplaySession.load(from: file)
        precondition(loaded.displays == captured.displays, "快照必须无损保存每屏模式与布局")
        for saved in loaded.displays {
            let id = DisplaySession.online().first { DisplaySession.uuid($0) == saved.uuid }!
            let modes = CGDisplayCopyAllDisplayModes(id,
                [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as! [CGDisplayMode]
            precondition(saved.mode.resolve(in: modes) != nil, "实际当前模式必须可精确选回")
            var wrong = saved.mode
            wrong.id += 1
            precondition(saved.mode.matches(wrong), "模式 ID 变化不能改变模式语义")
            wrong.refreshRate += 1
            precondition(!saved.mode.matches(wrong), "不能使用相近刷新率替代")
            wrong = saved.mode; wrong.pixelWidth *= 2
            precondition(!saved.mode.matches(wrong), "同逻辑尺寸不同像素尺寸不是同一模式")
            wrong = saved.mode; wrong.usable.toggle()
            precondition(!saved.mode.matches(wrong))
            wrong = saved.mode; wrong.flags ^= 1
            precondition(!saved.mode.matches(wrong))
        }
        var unplugged = loaded
        unplugged.displays[0].uuid = UUID().uuidString
        precondition(unplugged.verified(), "缺席屏不能阻塞在线屏恢复")
        precondition(unplugged.offline()?.displays.count == 1, "缺席屏记录不能丢弃")
        var bad = loaded; bad.version = 99
        try bad.save(to: file)
        do { _ = try DisplaySession.load(from: file); preconditionFailure("不接受未知记录格式") }
        catch {}
        bad = loaded; bad.displays[0].mode.width = Int.max
        try bad.save(to: file)
        do { _ = try DisplaySession.load(from: file); preconditionFailure("拒绝溢出的模式值") }
        catch {}
        bad = loaded; bad.displays += [bad.displays[0]]
        try bad.save(to: file)
        do { _ = try DisplaySession.load(from: file); preconditionFailure("拒绝重复身份") }
        catch {}
        try Data("{broken".utf8).write(to: file)
        do { _ = try DisplaySession.load(from: file); preconditionFailure("不接受损坏记录") }
        catch {}

        func targets(_ data: Data, boot: Int = 100, modified: Double = 200,
                     active: @escaping (UInt32) -> Bool = { _ in false },
                     uuid: @escaping (UInt32) -> String? = { _ in "physical-a" }) -> [UInt32] {
            PhysicalDisplays.restoreTargets(data: data, modified: Date(timeIntervalSince1970: modified),
                currentBoot: boot, active: active, uuid: uuid)
        }
        let old = Data("[2,1]".utf8)
        precondition(targets(old, active: { _ in true }).isEmpty, "已恢复的旧记录不能再发启用事务")
        precondition(targets(old, modified: 99).isEmpty, "跨重启不能使用旧 ID")
        precondition(Set(targets(old, uuid: { _ in nil })) == Set([1,2]), "同开机旧记录的禁用屏可能读不到 UUID")
        precondition(Set(targets(old)) == Set([1,2]))
        let record = PhysicalDisplays.Record(boot: 100, displays: [.init(id: 2, uuid: "physical-a")])
        let data = try JSONEncoder().encode(record)
        precondition(targets(data) == [2])
        precondition(targets(data, uuid: { _ in nil }) == [2], "实机关屏后 UUID=nil，不能从恢复队列丢弃")
        precondition(targets(data, boot: 101).isEmpty)
        precondition(targets(data, uuid: { _ in "unrelated-display" }).isEmpty, "复用 ID 不能操作另一块屏")
        precondition(targets(data, active: { _ in true }).isEmpty)
        precondition(targets(Data("invalid".utf8)).isEmpty)
        let two = PhysicalDisplays.Record(boot: 100, displays: [.init(id: 1, uuid: "internal"), .init(id: 3, uuid: "external")])
        let twoData = try JSONEncoder().encode(two)
        precondition(targets(twoData, uuid: { _ in nil }) == [1,3], "两块软禁用屏必须都保留")
        precondition(targets(twoData, active: { $0 == 1 }, uuid: { $0 == 1 ? "internal" : nil }) == [3], "已经启用的一块不能重复提交 enable")
        let merged = PhysicalDisplays.mergedRecord(ids: [1,3,1], previous: two, currentBoot: 100,
                                                  uuid: { $0 == 1 ? "internal" : nil })!
        precondition(merged.displays.map(\.id) == [1,3] && merged.displays.map(\.uuid) == ["internal","external"], "后续禁用不能覆盖掉读不到 UUID 的外接屏记录")
        precondition(PhysicalDisplays.mergedRecord(ids: [1,3], previous: two, currentBoot: 101, uuid: { _ in nil }) == nil)
        let modified = Date(timeIntervalSince1970: 200)
        precondition(!PhysicalDisplays.recordIsRestored(data: twoData, modified: modified, currentBoot: 100,
                                                       active: { _ in false }, uuid: { _ in nil }))
        precondition(!PhysicalDisplays.recordIsRestored(data: twoData, modified: modified, currentBoot: 100,
                                                       active: { $0 == 1 }, uuid: { $0 == 1 ? "internal" : nil }))
        precondition(!PhysicalDisplays.recordIsRestored(data: twoData, modified: modified, currentBoot: 100,
                                                       active: { _ in true }, uuid: { _ in "different" }))
        precondition(PhysicalDisplays.recordIsRestored(data: twoData, modified: modified, currentBoot: 100,
                                                      active: { _ in true }, uuid: { $0 == 1 ? "internal" : "external" }))
        let bootA = "00000000-0000-0000-0000-000000000001"
        let bootB = "00000000-0000-0000-0000-000000000002"
        var stableBootRecord = two; stableBootRecord.bootSession = bootA
        let stableBootData = try JSONEncoder().encode(stableBootRecord)
        precondition(PhysicalDisplays.restoreTargets(data: stableBootData, modified: modified, currentBoot: 101,
             active: { _ in false }, uuid: { _ in nil }, currentBootSession: bootA) == [1,3], "时钟调整不得丢弃同开机的禁用屏")
        precondition(PhysicalDisplays.restoreTargets(data: stableBootData, modified: modified, currentBoot: 100,
             active: { _ in false }, uuid: { _ in nil }, currentBootSession: bootB).isEmpty, "不同启动 UUID 不能复用旧 ID")
        precondition(PhysicalDisplays.restoreTargets(data: stableBootData, modified: modified, currentBoot: 100,
             active: { _ in false }, uuid: { _ in nil }).isEmpty, "启动身份未知时不使用新记录的旧 ID")
        let stableMerge = PhysicalDisplays.mergedRecord(ids: [1,3], previous: stableBootRecord, currentBoot: 101,
             uuid: { _ in nil }, currentBootSession: bootA)!
        precondition(stableMerge.displays.count == 2 && stableMerge.bootSession == bootA)
        print("PASS: real \(captured.displays.count)-display snapshot/roundtrip/exact mode selection; HiDPI/refresh/flags; unplugged retention; stale/reboot/reused ID recovery; corrupt records")
        print("PASS: Redmi virtual-only independent of HiDPI; online/active; missing mode; valid 1x/2x; wrong width/height; GUI unavailable; metadata loss; truthful status")
        print("PASS: disabled-display UUID=nil regression; partial restore skips active display; record merge preserves both displays; identity verified before clearing")
        print("PASS: stable kernel boot identity survives clock change and rejects previous/unknown boot")
    }
}
