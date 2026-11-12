// 虚拟屏与物理屏的显示拓扑管理：目标状态 + 逐步收敛
// 调用方只声明「应该是什么样」（desired），执行器一次只做一步拓扑变化，每步之后等待系统稳定再做下一步。
// 原因（实测）：重新启用物理屏的热插拔事件尚未处理完时又新建虚拟屏，applySettings 失败，
//              随后 WindowServer 在 GenerateModeListForDisplay 中 abort，系统注销重启。
//      另：虚拟屏创建后约 1 秒、尚未完全上线时就释放，会让 WindowServer 显示配置卡死（所有事务 10 秒超时，
//      需重启恢复），因此释放前必须已上线且存活 ≥ 2.5 秒；超时后不再提交配置事务，
//      仅在物理屏已可用并稳定时释放本进程持有的虚拟屏，避免残留虚拟主屏。
// 其他要点：虚拟屏只给一个模式且不改；GUI 主线程不能调 CGCompleteDisplayConfiguration（放 cgQueue）；
//          物理屏是否被禁用以磁盘记录为准（看门狗可能在别的进程里已恢复）。
import CGVirtualDisplayBridge
import CoreGraphics
import Foundation
import AppKit

final class DisplayManager {
    static let vendorID: UInt32 = 0x5555

    // 目标状态
    private var desired: DeviceConfig?
    private var shutdownCompletion: (() -> Void)?
    /// 是否应禁用物理屏（由 Coordinator 按设置与看门狗状态决定）
    var shouldDisablePhysical: () -> Bool = { false }
    /// 用户手动恢复后，本次连接内不再禁用
    private var physicalOverride = false
    private var disableAttempted = false
    private var physicalModeRestorePending = false

    // 实际状态
    private var vd: CGVirtualDisplay?
    private(set) var current: DeviceConfig?
    private var mainSet = false
    /// 换设备时的旧屏，等新屏成为主屏后释放
    private var retiring: [CGVirtualDisplay] = []
    /// 配置失败的虚拟屏，稳定后再释放（立即释放曾触发 WindowServer 崩溃）
    private var broken: [CGVirtualDisplay] = []
    /// 同一配置创建失败后不再重试，直到目标变化
    private var failedCfg: DeviceConfig?
    private var savedSession: DisplaySession?
    private var idleSession: DisplaySession?
    private var connectionBaseline: DisplaySession?
    private var idleWindowBaseline: (displays: DisplaySession, windows: WorkWindowSession, sampledAt: TimeInterval)?
    private var connectionWindows: WorkWindowSession?
    private var idleWindowReadInFlight = false
    private var idleWindowEpoch = 0
    private var lastIdleWindowReadAt: TimeInterval = -Double.infinity
    private var idleWindowFailure: String?
    private var displayRecovery = DisplayRecovery()
    private var restoreAttempts = 0
    private(set) var recoveryFailed = false
    private var unreadableSession = false
    private var legacyOrigins: [String: [Double]]?
    private var windowSession: WorkWindowSession?
    private var collectedDisplay: CGDirectDisplayID?
    private var endingWindowSession = false
    private(set) var windowRecoveryFailed = false
    private(set) var windowStatusText: String?
    private var waitingForUnlock = false
    private let windowQueue = DispatchQueue(label: "uudisplay.window-layout", autoreleaseFrequency: .workItem)

    // 执行器
    private var busy = false
    /// 启动时先把残留状态恢复干净，期间忽略目标设备
    private var recovering = false
    private var waitOnlineTries = 0
    private var modeProbeTries = 0
    private var bornAt: [CGDirectDisplayID: Date] = [:]
    private var releaseWaitStart: Date?
    /// WindowServer 配置超时：停止配置事务；物理屏可用时仍收尾所属虚拟屏。
    private(set) var wedged = false
    static let minLifetime: TimeInterval = 2.5
    private let cgQueue = DispatchQueue(label: "uudisplay.display-config")

    private static let markerURL = ConfigStore.dir.appendingPathComponent("session.json")

    var isActive: Bool {
        mainSet && readiness.isOnline
    }

    private var readiness: VirtualDisplayReadiness {
        guard let vd else { return VirtualDisplayReadiness(online: false, active: false, mode: nil) }
        return VirtualDisplayReadiness(online: Self.onlineDisplays().contains(vd.displayID),
            active: CGDisplayIsActive(vd.displayID) != 0,
            mode: CGDisplayCopyDisplayMode(vd.displayID).map(SavedDisplayMode.init))
    }

    var virtualStatusText: String {
        guard let current else { return "虚拟屏没有调整" }
        let state = readiness
        let text = state.status(for: current)
        if state.canKeepOnlyVirtual(current) {
            return text + (physicalOff ? " · 物理屏幕已软关闭" : "") + (windowStatusText.map { " · " + $0 } ?? "")
        }
        return text + ((physicalOff || physicalModeRestorePending) ? " · 物理屏正在恢复" : " · 物理屏保持开启")
    }
    var physicalOff: Bool { PhysicalDisplays.pending != nil }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func isVirtual(_ id: CGDirectDisplayID) -> Bool { CGDisplayVendorNumber(id) == vendorID }

    private static func same(_ a: DeviceConfig?, _ b: DeviceConfig?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.width == b.width && a.height == b.height && a.hiDPI == b.hiDPI
    }

    /// 已是同规格虚拟屏则不动
    func matches(_ cfg: DeviceConfig) -> Bool { DisplayManager.same(desired, cfg) && vd != nil }

    // MARK: - 对外接口：只改目标状态

    func create(_ cfg: DeviceConfig) {
        guard !unreadableSession else { return }
        if !DisplayManager.same(desired, cfg) { failedCfg = nil; disableAttempted = false }
        restoreAttempts = 0
        recoveryFailed = false
        desired = cfg
        kick()
    }

    /// 空闲时采样，连接事件到达后冻结；名称延迟期间不能覆盖连接前的基线。
    func observeIdleDisplays() {
        guard desired == nil, savedSession == nil, !recovering, !busy, vd == nil else { return }
        // 缺席屏回来后再恢复它；缺席期间保留记录但不阻塞下一次连接。
        if let deferred = try? DisplaySession.load(), deferred.offline()?.displays != deferred.displays {
            savedSession = deferred
            recovering = true
            restoreAttempts = 0
            recoveryFailed = false
            kick()
            return
        }
        if let current = DisplaySession.capture() {
            if idleSession?.sameConfiguration(as: current) != true {
                idleWindowBaseline = nil
                idleWindowEpoch += 1
            }
            idleSession = current
        } else {
            idleSession = nil; idleWindowBaseline = nil; idleWindowEpoch += 1
        }
        observeIdleWindows()
    }

    /// 只在没有托管虚拟屏/恢复任务，且当前物理配置仍等于安全空闲配置时采样。
    /// 电脑远控在线也可采样；UU 临时改模式之后的布局不能覆盖连接前的窗口基线。
    func observeIdleWindows() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !ScreenLock.isLocked, desired == nil, savedSession == nil, windowSession == nil, connectionBaseline == nil,
              !recovering, !busy, !endingWindowSession, vd == nil, let expected = idleSession,
              let before = DisplaySession.capture() else { return }
        if !expected.sameConfiguration(as: before) {
            // UU 可能先换物理模式、稍后才在 AX 表里给出手机名；在最早的变化处冻结旧配对。
            if let sample = idleWindowBaseline, expected.sameConfiguration(as: sample.displays),
               now - sample.sampledAt <= 5 {
                idleWindowEpoch += 1
                connectionBaseline = sample.displays
                connectionWindows = sample.windows.forConnection()
                Log.info("检测到物理模式变化，提前冻结连接前配对基线，等待控制端识别")
            }
            return
        }
        guard !idleWindowReadInFlight, now - lastIdleWindowReadAt >= 1 else { return }
        idleWindowReadInFlight = true
        lastIdleWindowReadAt = now
        let epoch = idleWindowEpoch
        windowQueue.async {
            let access = AccessibilityWindows(diagnostics: { message in DispatchQueue.main.async { Log.info(message) } })
            let windows = WorkWindowSession(access: access)
            let after = DisplaySession.capture()
            DispatchQueue.main.async {
                self.idleWindowReadInFlight = false
                guard epoch == self.idleWindowEpoch, self.desired == nil, self.savedSession == nil,
                      self.windowSession == nil, self.connectionBaseline == nil, !self.recovering,
                      !self.busy, !self.endingWindowSession, self.vd == nil, !ScreenLock.isLocked else { return }
                guard let windows, let after, before.sameConfiguration(as: after),
                      self.idleSession?.sameConfiguration(as: before) == true else {
                    self.idleWindowFailure = access.captureFailure ?? "采样期间物理屏配置变化"
                    return
                }
                let first = self.idleWindowBaseline == nil
                self.idleWindowBaseline = (before, windows, ProcessInfo.processInfo.systemUptime)
                self.idleWindowFailure = nil
                if first {
                    let desktops = windows.windows.map { item -> String in
                        guard let desktop = item.state.desktop else { return "#\(item.id.number):unknown" }
                        return "#\(item.id.number):\(desktop.display)@\(desktop.space),single=\(desktop.soleUserSpace)"
                    }.joined(separator: ";")
                    Log.info("连接前配对基线已就绪：\(windows.windows.count) 个窗口，物理模式和排列在采样前后一致；桌面归属 \(desktops)")
                }
            }
        }
    }

    func beginSession() {
        guard connectionBaseline == nil else { return }
        idleWindowEpoch += 1 // 连接到来后，未完成的空闲读取不得再发布。
        connectionBaseline = idleSession ?? DisplaySession.capture()
        if let sample = idleWindowBaseline,
           connectionBaseline?.sameConfiguration(as: sample.displays) == true,
           ProcessInfo.processInfo.systemUptime - sample.sampledAt <= 5 || endingWindowSession || recovering {
            connectionWindows = sample.windows.forConnection()
        } else { connectionWindows = nil }
    }

    func remove(completion: (() -> Void)? = nil) {
        desired = nil
        if !endingWindowSession { displayRecovery.retry() }
        endingWindowSession = true
        failedCfg = nil
        physicalOverride = false
        disableAttempted = false
        connectionBaseline = nil
        connectionWindows = nil
        idleWindowEpoch += 1
        restoreAttempts = 0
        recoveryFailed = false
        if unreadableSession { recoveryFailed = true }
        if let completion { shutdownCompletion = completion }
        kick()
    }

    func disablePhysicalIfNeeded() { disableAttempted = false; modeProbeTries = 0; kick() }

    /// 快捷键 / 菜单 / 关闭开关：立即恢复物理屏，虚拟屏保留
    func restorePhysicalNow(override: Bool = true) {
        if override { physicalOverride = true }
        displayRecovery.retry()
        restoreAttempts = 0
        recoveryFailed = false
        kick()
    }

    /// 启动时：读回上次未收尾的布局记录；残留的物理屏禁用记录由执行器按「目标=无」自动恢复
    func recoverIfNeeded() {
        if FileManager.default.fileExists(atPath: DisplaySession.url.path) {
            do { savedSession = try DisplaySession.load() }
            catch {
                unreadableSession = true
                recoveryFailed = true
                Log.info("⚠️ 无法读取显示恢复记录，保留文件并停止自动调整：\(error)")
            }
        }
        // 旧版只有 ID/原点。跨启动不可应用，且没有模式数据可补回；保留原文件供诊断。
        if savedSession == nil, let data = try? Data(contentsOf: DisplayManager.markerURL),
           let modified = (try? FileManager.default.attributesOfItem(atPath: DisplayManager.markerURL.path))?[.modificationDate] as? Date,
           modified.timeIntervalSince1970 >= Double(PhysicalDisplays.boot),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [Double]] {
            legacyOrigins = dict
        }
        if savedSession != nil || legacyOrigins != nil || physicalOff {
            Log.info("发现上次异常退出的残留状态，先恢复物理屏与显示器布局")
            recovering = true
        }
        kick()
    }

    // MARK: - 执行器

    private func kick() {
        guard !busy else { return }
        step()
    }

    /// 完成一步后等待 settle 秒再评估下一步
    private func finish(settle: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self else { return }
            self.busy = false
            self.step()
        }
    }

    /// 在 cgQueue 执行配置事务，回到主线程后进入稳定等待；事务超时则进入保护状态
    private func runCG(settle: TimeInterval, completion: ((CGError) -> Void)? = nil, _ work: @escaping () -> CGError) {
        busy = true
        cgQueue.async {
            let err = work()
            DispatchQueue.main.async {
                // cannotComplete 也可能表示模式暂不可用，不能直接宣告 WindowServer 卡死。
                if err.rawValue == 1014 { self.enterWedged(err) }
                completion?(err)
                self.finish(settle: settle)
            }
        }
    }

    private func enterWedged(_ err: CGError) {
        guard !wedged else { return }
        wedged = true
        Log.info("⛔️ 显示配置事务超时（CGError=\(err.rawValue)），停止后续配置事务；物理屏可用时收尾虚拟屏，保留记录待核验")
    }

    /// 释放前确认每块屏已上线且存活足够久；最多等 8 秒
    private func readyToRelease(_ displays: [CGVirtualDisplay]) -> Bool {
        let online = Set(DisplayManager.onlineDisplays())
        let young = displays.contains { d in
            !online.contains(d.displayID) || Date().timeIntervalSince(bornAt[d.displayID] ?? .distantPast) < DisplayManager.minLifetime
        }
        guard young else { releaseWaitStart = nil; return true }
        let start = releaseWaitStart ?? Date()
        releaseWaitStart = start
        if Date().timeIntervalSince(start) > 8 { releaseWaitStart = nil; return true }
        return false
    }

    private func step() {
        guard !busy else { return }
        PhysicalDisplays.clearResolvedRecord()
        guard !recoveryFailed else {
            if let done = shutdownCompletion { shutdownCompletion = nil; done() }
            return
        }
        // 1. 配置失败的屏：稳定后释放
        if !broken.isEmpty {
            guard readyToRelease(broken) else { busy = true; return finish(settle: 0.5) }
            busy = true
            release(&broken)
            return finish(settle: 1.5)
        }

        guard let want = (recovering || endingWindowSession || wedged) ? nil : desired else {
            // 原模式不可用时也必须先安全释放虚拟屏，不能形成“恢复成功才可释放”的循环。
            if let origins = legacyOrigins, savedSession == nil {
                // 旧版禁用屏先上线，之后才能把旧原点绑定到当前身份。
                if var legacy = DisplaySession.capture() {
                    legacyOrigins = nil
                    for (key, value) in origins where value.count == 2 {
                        guard let id = UInt32(key), let uuid = DisplaySession.uuid(id),
                              let index = legacy.displays.firstIndex(where: { $0.uuid == uuid }),
                              value.allSatisfy({ $0.isFinite && $0 >= Double(Int32.min) && $0 <= Double(Int32.max) }) else { continue }
                        legacy.displays[index].x = Int32(value[0]); legacy.displays[index].y = Int32(value[1])
                    }
                    savedSession = legacy
                    Log.info("旧版记录只可恢复布局，原分辨率与刷新率未知")
                }
            }
            if advanceDisplayRecovery() { return }
            if let session = savedSession {
                guard session.verified() else { busy = true; return finish(settle: 0.5) }
                do {
                    if let offline = session.offline() {
                        try offline.save()
                        Log.info("缺席物理屏的恢复记录已保留，待重新接入后恢复")
                    } else if FileManager.default.fileExists(atPath: DisplaySession.url.path) {
                        try FileManager.default.removeItem(at: DisplaySession.url)
                    }
                    if FileManager.default.fileExists(atPath: DisplayManager.markerURL.path) {
                        try FileManager.default.removeItem(at: DisplayManager.markerURL)
                    }
                } catch {
                    recoveryFailed = true
                    Log.info("⚠️ 显示配置已核验，但恢复记录未清理：\(error)")
                    return
                }
                savedSession = nil
                displayRecovery = DisplayRecovery()
                restoreAttempts = 0
                Log.info("✅ 已核验物理屏模式、刷新率、镜像关系与布局")
            }
            // 必须在虚拟屏释放、原显示布局稳定之后恢复，否则系统的热插拔排布会覆盖 AX 写入。
            if windowSession != nil, !windowRecoveryFailed {
                return advanceWindows(.restore)
            }
            endingWindowSession = false
            if recovering {
                recovering = false
                Log.info("残留状态已恢复")
                if desired != nil, !wedged { return step() }
            }
            physicalModeRestorePending = false
            // 断开恢复中又连入：先完成旧窗口归位，之后才允许采集下一轮基线。
            if desired != nil, !windowRecoveryFailed, !wedged { return step() }
            if let done = shutdownCompletion {
                shutdownCompletion = nil
                done()
            }
            return
        }

        // 目标=某设备的虚拟屏
        if vd == nil || !DisplayManager.same(current, want) {
            guard !windowRecoveryFailed else { return }
            guard !DisplayManager.same(failedCfg, want) else { return }
            if windowSession == nil {
                guard let original = connectionWindows else {
                    failedCfg = want
                    windowStatusText = "连接前窗口基线未就绪，请断开后重连"
                    Log.info("⚠️ 缺少连接前完整配对基线，未建屏、未关屏；\(idleWindowFailure ?? "预采样尚未完成或过期")")
                    return
                }
                windowSession = original
                windowStatusText = nil
                Log.info("已冻结连接前配对窗口基线：\(original.windows.count) 个，采样 \(original.captureAttempts) 次；未采纳 UU 连接后的临时布局")
            }
            busy = true
            if savedSession == nil {
                guard var baseline = connectionBaseline ?? idleSession ?? DisplaySession.capture() else {
                    busy = false
                    failedCfg = want
                    Log.info("⚠️ 无法取得物理屏完整快照，放弃建屏")
                    return
                }
                if let deferred = try? DisplaySession.load() {
                    let currentKeys = Set(baseline.displays.map(\.uuid))
                    baseline.displays += deferred.displays.filter { !currentKeys.contains($0.uuid) }
                }
                do { try baseline.save(); savedSession = baseline }
                catch { busy = false; failedCfg = want; Log.info("⚠️ 无法保存显示配置，放弃建屏：\(error)"); return }
                displayRecovery = DisplayRecovery()
            }
            if let old = vd { retiring.append(old) }
            vd = nil
            current = nil
            mainSet = false
            waitOnlineTries = 0
            modeProbeTries = 0
            collectedDisplay = nil
            if !createDisplay(want) { failedCfg = want }
            return finish(settle: 1.0)
        }

        if !mainSet, let id = vd?.displayID {
            let online = DisplayManager.onlineDisplays()
            guard online.contains(id) else {
                waitOnlineTries += 1
                if waitOnlineTries > 20 {
                    Log.info("⚠️ 虚拟屏 5 秒内未上线，结束本次调整")
                    desired = nil
                    return step()
                }
                busy = true
                return finish(settle: 0.25)
            }
            return runCG(settle: 0.5, completion: { err in
                self.mainSet = err == .success
                if err != .success { self.desired = nil }
            }) {
                let err = applyDisplayConfig { cfg in
                    let t = CGDisplayBounds(id).origin
                    for d in online where CGDisplayMirrorsDisplay(d) == kCGNullDirectDisplay {
                        let o = CGDisplayBounds(d).origin
                        let err = CGConfigureDisplayOrigin(cfg, d, Int32(o.x - t.x), Int32(o.y - t.y))
                        if err != .success { return err }
                    }
                    return .success
                }
                Log.info(err == .success ? "✅ 虚拟屏已设为主屏" : "⚠️ 设主屏失败 CGError=\(err.rawValue)")
                return err
            }
        }

        // 只因未上线/未激活撤回；公开模式元数据缺失不代表虚拟屏离线。
        if !isActive {
            waitOnlineTries += 1
            if waitOnlineTries > 20 {
                Log.info("⚠️ 虚拟屏未进入在线活动状态，保留物理屏并结束本次调整")
                desired = nil
                return step()
            }
            busy = true
            return finish(settle: 0.25)
        }

        let state = readiness
        let requestedOff = shouldDisablePhysical() && !physicalOverride
        let modeVerified = state.canKeepOnlyVirtual(want)
        let wantOff = requestedOff && modeVerified
        // 换设备或模式证据丢失时，先恢复物理屏，再释放旧虚拟屏或等待新模式。
        if !wantOff, physicalOff {
            physicalModeRestorePending = true
            guard allowRestoreAttempt() else { return }
            return runCG(settle: 1.5) { PhysicalDisplays.restore(reason: "物理屏不再满足禁用条件") }
        }
        if !wantOff, (physicalModeRestorePending || physicalOverride), let session = savedSession {
            if !session.verified(includeLayout: false) {
                guard allowRestoreAttempt() else { return }
                return runCG(settle: 1.5) { session.restore(includeLayout: false) }
            }
            physicalModeRestorePending = false
        }
        if requestedOff, !modeVerified {
            if modeProbeTries < 20 {
                modeProbeTries += 1
                busy = true
                return finish(settle: 0.25)
            }
            if modeProbeTries == 20 {
                modeProbeTries += 1
                Log.info("⚠️ \(state.status(for: want))；保留虚拟屏和物理屏，未执行物理屏禁用")
            }
        }

        if !retiring.isEmpty {
            guard readyToRelease(retiring) else { busy = true; return finish(settle: 0.5) }
            busy = true
            release(&retiring)
            return finish(settle: 1.5)
        }

        if wantOff, !physicalOff, !disableAttempted, let id = vd?.displayID {
            let physical = DisplayManager.onlineDisplays().filter { !DisplayManager.isVirtual($0) }
            if !physical.isEmpty {
                disableAttempted = true
                return runCG(settle: 1.5) {
                    let err = PhysicalDisplays.disable(physical)
                    Log.info(err == .success ? "已提交物理屏 \(physical) 禁用配置，虚拟屏 #\(id)" : "⚠️ 关闭物理屏失败 CGError=\(err.rawValue)")
                    return err
                }
            }
        }
        if wantOff, physicalOff, let id = vd?.displayID, collectedDisplay != id, windowSession != nil {
            // AppKit 是左下原点；AX/CG 是主屏左上原点。主屏已是虚拟屏，但仍按真实高度转换。
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }), let main = NSScreen.screens.first else { return }
            let visible = screen.visibleFrame
            let area = CGRect(x: visible.minX, y: main.frame.maxY - visible.maxY,
                              width: visible.width, height: visible.height)
            return advanceWindows(.collect(area), display: id)
        }
    }

    /// 返回 true 表示本轮仍在恢复或失败；false 才允许清理记录及恢复窗口。
    private func advanceDisplayRecovery() -> Bool {
        let owned = retiring + [vd].compactMap { $0 }
        guard savedSession != nil || legacyOrigins != nil || physicalOff || !owned.isEmpty ||
              !displayRecovery.releasedVirtual.isEmpty else { return false }
        let online = Set(Self.onlineDisplays())
        let hasActivePhysical = online.contains { id in
            !Self.isVirtual(id) && CGDisplayIsActive(id) != 0 && DisplaySession.uuid(id) != nil &&
                CGDisplayCopyDisplayMode(id)?.isUsableForDesktopGUI() == true
        }
        let canReadModes = owned.isEmpty && displayRecovery.releasedVirtual.isDisjoint(with: online)
        let action = displayRecovery.next(.init(
            pendingEnable: physicalOff, hasActivePhysical: hasActivePhysical,
            physical: DisplaySession.capture()?.displays, ownedVirtual: Set(owned.map(\.displayID)),
            virtualReadyToRelease: owned.isEmpty || readyToRelease(owned), online: online,
            modesAvailable: canReadModes && (savedSession?.modesAvailable() ?? true),
            configurationVerified: savedSession?.verified() ?? true,
            transactionTimedOut: wedged, now: ProcessInfo.processInfo.systemUptime))
        switch action {
        case .enablePhysical:
            runCG(settle: 1.5, completion: { error in
                self.displayRecovery.didEnableResult(accepted: error == .success, now: ProcessInfo.processInfo.systemUptime)
                if error == .success, self.physicalOff {
                    Log.info("物理屏启用事务已接受，等待活动状态落地，期间不重复提交启用")
                }
            }) { PhysicalDisplays.restore(reason: "远程结束") }
        case .releaseVirtual:
            busy = true
            var all = owned
            retiring = []; vd = nil; current = nil; mainSet = false
            release(&all)
            finish(settle: 1.5)
        case .restoreConfiguration:
            guard let session = savedSession else { return false }
            runCG(settle: 1.5) {
                let err = session.restore()
                Log.info(err == .success ? "已提交原物理屏模式、主屏和排列恢复，等待连续核验" : "⚠️ 原物理屏配置恢复 CGError=\(err.rawValue)")
                return err
            }
        case .wait:
            busy = true
            finish(settle: 0.5)
        case .failed(let reason):
            recoveryFailed = true
            Log.info("⚠️ \(reason)")
            if let done = shutdownCompletion { shutdownCompletion = nil; done() }
        case .complete: return false
        }
        return true
    }

    private func advanceWindows(_ goal: WorkWindowSession.Goal, display: CGDirectDisplayID? = nil) {
        guard let session = windowSession else { return }
        if ScreenLock.isLocked {
            session.suspendForLockedScreen()
            windowStatusText = goal == .restore ? "物理屏已恢复，等待解锁后恢复窗口" : "等待解锁后收拢窗口"
            if !waitingForUnlock { waitingForUnlock = true; Log.info(windowStatusText!) }
            busy = true
            return finish(settle: 1)
        }
        if waitingForUnlock {
            waitingForUnlock = false
            Log.info("Mac 已解锁，继续原会话窗口收尾；不更改原位基线")
        }
        busy = true
        windowQueue.async {
            let progress = session.advance(goal)
            DispatchQueue.main.async {
                switch progress {
                case .pending: break
                case .waitingForMetadata:
                    self.windowStatusText = "等待窗口信息稳定"
                    Log.info("等待窗口可用元数据，不消耗搬窗预算：\(session.mismatchReasons)")
                case .complete(let verified, let skipped):
                    if goal == .restore {
                        self.windowSession = nil
                        if let sample = self.idleWindowBaseline,
                           DisplaySession.capture()?.sameConfiguration(as: sample.displays) == true {
                            self.idleWindowBaseline = (sample.displays, sample.windows, ProcessInfo.processInfo.systemUptime)
                        }
                        self.collectedDisplay = nil
                        self.windowStatusText = nil
                        Log.info("✅ 窗口原位读回核验完成：\(verified) 个，关闭或特殊状态跳过 \(skipped) 个")
                    } else {
                        self.collectedDisplay = display
                        self.windowStatusText = "工作窗口已收拢"
                        Log.info("工作窗口已收拢并读回核验：\(verified) 个；其他桌面/特殊状态/已关闭跳过 \(skipped) 个")
                    }
                case .failed(let ids):
                    if goal == .restore {
                        self.windowRecoveryFailed = true
                        self.windowStatusText = "窗口归位未完成，已停止自动调整"
                    } else {
                        self.collectedDisplay = display
                        self.windowStatusText = "部分窗口未收拢，断开后仍将恢复原位"
                    }
                    Log.info("⚠️ \(self.windowStatusText!)；未通过读回核验的窗口 ID：\(ids)；原因：\(session.mismatchReasons)")
                }
                self.finish(settle: 0.35)
            }
        }
    }

    // MARK: - 单步操作

    private func createDisplay(_ cfg: DeviceConfig) -> Bool {
        let w = cfg.width, h = cfg.height
        let desc = CGVirtualDisplayDescriptor()
        desc.name = "UUyc companion · \(cfg.name)"  // 显示在 UU 的多显示屏列表、系统显示器设置中
        desc.maxPixelsWide = UInt32(w)
        desc.maxPixelsHigh = UInt32(h)
        desc.sizeInMillimeters = CGSize(width: Double(w) / 220 * 25.4, height: Double(h) / 220 * 25.4)
        desc.vendorID = DisplayManager.vendorID
        desc.productID = 0x0001
        // 每次随机序列号：与残留虚拟屏同序列号时 CGVirtualDisplay 会返回 nil
        desc.serialNum = UInt32.random(in: 1...0xFFFF_FFF0)

        let created: CGVirtualDisplay? = autoreleasepool { CGVirtualDisplay(descriptor: desc) }
        guard let display = created else {
            Log.info("❌ 创建虚拟屏失败（CGVirtualDisplay 返回 nil）")
            return false
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = cfg.hiDPI
        let mw = cfg.hiDPI ? w / 2 : w, mh = cfg.hiDPI ? h / 2 : h
        guard let mode = CGVirtualDisplayMode(width: UInt(mw), height: UInt(mh), refreshRate: 60) else {
            bornAt[display.displayID] = Date()
            broken.append(display)
            Log.info("❌ 无法创建虚拟屏模式，稳定后释放")
            return false
        }
        settings.modes = [mode]
        guard autoreleasepool(invoking: { display.apply(settings) }) else {
            Log.info("❌ 虚拟屏 applySettings 失败，稳定后释放")
            bornAt[display.displayID] = Date()
            broken.append(display)
            return false
        }
        vd = display
        current = cfg
        bornAt[display.displayID] = Date()
        Log.info("已创建虚拟屏对象 #\(display.displayID) \(cfg.name)，请求像素 \(w)×\(h)，HiDPI 请求=\(cfg.hiDPI ? "开启" : "关闭")；等待实际模式核验")
        return true
    }

    private func release(_ displays: inout [CGVirtualDisplay]) {
        guard !displays.isEmpty else { return }
        let ids = displays.map { "#\($0.displayID)" }.joined(separator: " ")
        displayRecovery.didRelease(Set(displays.map(\.displayID)))
        autoreleasepool { displays.removeAll() }
        Log.info("✅ 已移除虚拟屏 \(ids)")
    }

    private func allowRestoreAttempt() -> Bool {
        guard restoreAttempts < 3 else {
            recoveryFailed = true
            Log.info("⚠️ 显示恢复未完成，已停止自动重试并保留恢复记录；可手动恢复后重连")
            return false
        }
        restoreAttempts += 1
        return true
    }

}
