import Foundation

// 只替代显示写入和 UU 外部入口；真实 Coordinator、Monitor、配置存储执行完整事件链。
enum Log { static func info(_ message: String) {} }
enum UUReader {
    static var isTrusted = true
    static var opens = 0
    static func readControllers() -> [String]? { preconditionFailure("Coordinator 不应在主线程再读 AX") }
    static func showMainWindow() { opens += 1 }
}
enum PhysicalDisplays { static var available = true }
final class DisplayManager {
    var windowRecoveryFailed = false
    var windowStatusText: String?
    var virtualStatusText = "虚拟屏已上线 · 模式未确认 · 物理屏保持开启"
    var shouldDisablePhysical: () -> Bool = { false }
    var wedged = false, recoveryFailed = false, isActive = false, physicalOff = false
    var current: DeviceConfig?
    var creations: [String] = [], removals = 0
    func recoverIfNeeded() {}
    func observeIdleDisplays() {}
    func beginSession() {}
    func matches(_ cfg: DeviceConfig) -> Bool { current == cfg }
    func create(_ cfg: DeviceConfig) { current = cfg; isActive = true; creations.append(cfg.name) }
    func remove(completion: (() -> Void)? = nil) { current = nil; isActive = false; removals += 1; completion?() }
    func restorePhysicalNow(override: Bool = true) {}
    func disablePhysicalIfNeeded() {}
}
@main struct CoordinatorTests {
    static func main() {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = ConfigStore(dir: dir)
        store.config.devices = [DeviceConfig(name: "Redmi22081212C", kind: .phone, width: 488, height: 1084),
                                DeviceConfig(name: "QL", kind: .computer, width: 0, height: 0)]
        let lock = NSLock()
        var names: [String]? = nil
        var overlay = true
        let monitor = UUMonitor(trusted: { true }, readControllers: {
            lock.lock(); defer { lock.unlock() }; return names
        }, hasOverlay: { overlay })
        let display = DisplayManager()
        let coordinator = Coordinator(monitor: monitor, display: display, store: store)
        coordinator.start()
        RunLoop.main.run(until: Date().addingTimeInterval(31))
        precondition(display.creations.isEmpty, "名称未知时不能猜设备建屏")
        lock.lock(); names = ["Redmi22081212C"]; lock.unlock()
        RunLoop.main.run(until: Date().addingTimeInterval(1.6))
        precondition(display.creations == ["Redmi22081212C"], "超过 30 秒仍应处理真实红米名称")
        precondition(coordinator.statusText.contains("模式未确认") && !coordinator.statusText.contains("高清"))
        display.isActive = false  // 已分配但未激活的屏，也必须在切到电脑时收尾。
        lock.lock(); names = ["QL"]; lock.unlock()
        RunLoop.main.run(until: Date().addingTimeInterval(1.6))
        precondition(!display.isActive, "切到电脑必须移除虚拟屏")
        precondition(display.current == nil, "不能以尚未激活为由跳过移除/取消")
        lock.lock(); names = ["Redmi22081212C"]; lock.unlock()
        RunLoop.main.run(until: Date().addingTimeInterval(1.6))
        precondition(display.creations.count == 2)
        coordinator.setPaused(true)
        precondition(!display.isActive)
        lock.lock(); names = []; lock.unlock(); overlay = false
        RunLoop.main.run(until: Date().addingTimeInterval(2.8))
        precondition(!coordinator.connected && !display.isActive)
        coordinator.setPaused(false)
        precondition(UUReader.opens <= 3, "一次连接只尝试展开一次窗口")
        print("PASS: real connection event path; >30s delayed Redmi name; no AX reads on main; computer switch; reconnect; pause; disconnect")
    }
}
