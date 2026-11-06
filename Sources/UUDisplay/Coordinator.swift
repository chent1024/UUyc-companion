// 连入/断开 → 选设备配置 → 建屏/还原
// 只处理 UU 设备列表里、且填了分辨率的设备；读不到名字或认不出就不调整，交给 UU远程 自己处理
import AppKit

final class Coordinator {
    let monitor: UUMonitor
    let display: DisplayManager
    private let store: ConfigStore

    init(monitor: UUMonitor = UUMonitor(), display: DisplayManager = DisplayManager(), store: ConfigStore = .shared) {
        self.monitor = monitor; self.display = display; self.store = store
    }

    /// 状态变化时通知菜单栏刷新
    var onChange: (() -> Void)?

    private(set) var controllerName: String?
    private var namePoll: Timer?
    private var connectedAt = Date.distantPast
    private var openedUUWindow = false

    /// 调试：模拟连入的控制端名称（不读 UU）
    var simulatedName: String?

    var connected: Bool { monitor.connected || simulatedName != nil }

    func start() {
        display.shouldDisablePhysical = { [weak self] in self?.physicalDisableAllowed ?? false }
        display.recoverIfNeeded()
        monitor.onConnect = { [weak self] in self?.handleConnect() }
        monitor.onDisconnect = { [weak self] in self?.handleDisconnect() }
        monitor.onIdle = { [weak self] in self?.display.observeIdleDisplays() }
        display.observeIdleDisplays()
        monitor.start()
    }

    /// 开关打开且私有 API 可用时关闭物理屏；看门狗是可选兜底（快捷键 ⌃⌥⌘9 始终可用）
    var physicalDisableAllowed: Bool {
        store.config.shouldDisablePhysical && PhysicalDisplays.available
    }

    var statusText: String {
        if display.wedged { return "⛔️ 显示事务失败，已停止自动调整，请检查恢复记录" }
        if display.recoveryFailed { return "⚠️ 显示恢复未完成，记录已保留，请手动恢复" }
        if store.config.paused { return "虚拟屏已暂停：连接时不做调整" }
        guard connected else { return "等待其它设备连接中" }
        let who = controllerName ?? "未知设备"
        if display.current != nil, display.isActive {
            return "\(who) 已连接 · \(display.virtualStatusText)"
        }
        return "\(who) 已连接 · 虚拟屏没有调整"
    }

    // MARK: - 事件

    func handleConnect() {
        namePoll?.invalidate()
        namePoll = nil
        display.beginSession()
        connectedAt = Date()
        controllerName = nil
        openedUUWindow = false
        onChange?()
        guard !store.config.paused else { return }
        if pollName() { return }
        namePoll?.invalidate()
        namePoll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            if self.pollName() { t.invalidate() }
        }
    }

    func handleDisconnect() {
        namePoll?.invalidate()
        namePoll = nil
        display.remove()
        controllerName = nil
        onChange?()
    }

    /// 返回 true 表示已拿到名称、无需继续轮询
    private func pollName() -> Bool {
        guard connected, !store.config.paused else { return true }
        let elapsed = Date().timeIntervalSince(connectedAt)

        if let name = simulatedName ?? readControllerName() {
            resolve(name)
            return true
        }
        // UU 页面或窗口可在连接期间才出现；连接结束/暂停才停止，不猜测上次设备。
        if elapsed >= 30 { connectedAt = Date(); Log.info("尚未读到控制端名称，连接期间继续等待") }
        return false
    }

    private func readControllerName() -> String? {
        guard UUReader.isTrusted else { return nil }
        switch monitor.currentControllers {
        case .none:
            // 未获得可用快照：只尝试展开一次窗口，不能把缓存缺失当成窗口不存在。
            if !openedUUWindow {
                openedUUWindow = true
                Log.info("尚无可用的控制端读取结果，尝试展开 UU 主界面")
                UUReader.showMainWindow()
            }
            return nil
        case .some(let names):
            return names.first
        }
    }

    private func resolve(_ name: String) {
        controllerName = name
        Log.info("控制端：\(name)")
        let cfg: DeviceConfig?
        if let known = store.device(named: name) {
            cfg = known
        } else if simulatedName != nil {
            // 调试模拟：未配置的名称用固定测试尺寸
            cfg = DeviceConfig(name: name, kind: .tablet, width: 2360, height: 1640)
        } else {
            cfg = nil
            Log.info("「\(name)」不在设备列表里，不调整")
        }
        apply(cfg)
    }

    private func apply(_ cfg: DeviceConfig?) {
        defer { onChange?() }
        guard let cfg, cfg.kind != .computer, cfg.hasSize else {
            display.remove()
            Log.info(cfg == nil ? "无可用配置，不切换" : "「\(cfg!.name)」不指定分辨率或还没填写，不切换")
            return
        }
        if display.matches(cfg) { return }
        display.create(cfg)
    }

    // MARK: - 菜单操作

    func setPaused(_ paused: Bool) {
        store.config.paused = paused
        if paused {
            namePoll?.invalidate()
            display.remove()
        } else if connected {
            handleConnect()
        }
        onChange?()
    }

    /// 配置变更后，若正在被控则按新配置重新应用
    func configChanged() {
        if connected, !store.config.paused {
            if let name = controllerName { resolve(name) } else { handleConnect() }
        }
        onChange?()
    }

    /// 快捷键 ⌃⌥⌘9 / 菜单：立即恢复物理屏
    func restorePhysical() {
        Log.info("手动恢复物理屏")
        display.restorePhysicalNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.onChange?() }
    }

    func setDisablePhysical(_ on: Bool) {
        store.config.disablePhysical = on
        if on { display.disablePhysicalIfNeeded() } else { display.restorePhysicalNow(override: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.onChange?() }
    }

    func shutdown(completion: @escaping () -> Void) {
        display.remove(completion: completion)
    }
}
