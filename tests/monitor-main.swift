import Foundation

// 不访问真实 UU 或显示器，只替代 monitor 默认依赖。
enum UUReader {
    static var isTrusted: Bool { false }
    static func readControllers() -> [String]? { nil }
}
enum Log { static func info(_ message: String) {} }

@main struct MonitorTests {
    static func main() {
        let lock = NSLock()
        var reads = 0
        var overlay = true
        var connects = 0
        var disconnects = 0
        var pulses = 0
        let monitor = UUMonitor(trusted: { true }, readControllers: {
            lock.lock(); reads += 1; lock.unlock()
            Thread.sleep(forTimeInterval: 3)
            return ["stale controller"]
        }, hasOverlay: { overlay }, locked: { false })
        monitor.onConnect = { connects += 1 }
        monitor.onDisconnect = { disconnects += 1 }
        monitor.start()
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in pulses += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        precondition(connects == 1, "覆盖窗口检测不能等待 AX 返回")
        overlay = false
        RunLoop.main.run(until: Date().addingTimeInterval(1.9))
        precondition(disconnects == 1, "AX 阻塞时仍应按覆盖窗口缺席触发断开")
        lock.lock(); let count = reads; lock.unlock()
        precondition(count == 1, "AX 读取不能堆积或并发")
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        precondition(connects == 1, "过期的 AX 结果不能重新触发连接")
        precondition(pulses >= 30, "AX 读取不能阻塞主线程")
        heartbeat.invalidate()
        var screenLocked = true
        var unlockedReads = 0
        let lockedMonitor = UUMonitor(trusted: { true }, readControllers: { lock.lock(); unlockedReads += 1; lock.unlock(); return [] },
            hasOverlay: { false }, locked: { screenLocked })
        lockedMonitor.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        lock.lock(); let lockedCount = unlockedReads; lock.unlock()
        precondition(lockedCount == 0, "锁屏期间不能反复访问不可读的 AX 树")
        screenLocked = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        lock.lock(); let unlockedCount = unlockedReads; lock.unlock()
        precondition(unlockedCount > 0, "解锁后自动恢复控制端读取")
        print("PASS: blocked AX keeps main thread responsive; no overlapping reads; overlay disconnect; stale result rejected")
    }
}
