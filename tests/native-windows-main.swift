// 原生边界验收：只读写本测试子进程窗口，两个普通窗口及一个最小化窗口。
import AppKit
import ApplicationServices

@main enum NativeWindowTests {
    enum Failure: Error { case failed(String) }
    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    static func run() throws {
        if CommandLine.arguments.contains("--capture-only") {
            let access = AccessibilityWindows()
            guard let snapshot = access.capture() else {
                throw Failure.failed("read-only live capture: \(access.captureFailure ?? "unknown")")
            }
            print("PASS: read-only current workspace capture: \(snapshot.count) windows, \(snapshot.filter { $0.visible }.count) visible, \(snapshot.filter { $0.state.minimized }.count) minimized, \(snapshot.filter { $0.state.fullscreen }.count) fullscreen; no window writes")
            return
        }
        if CommandLine.arguments.contains("--fixture") {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            var windows: [NSWindow] = []
            for i in 0..<3 {
                let screen = NSScreen.screens[i % NSScreen.screens.count]
                let visible = screen.visibleFrame
                let frame = CGRect(x: visible.minX + 100, y: visible.minY + 100,
                                   width: CGFloat(650 + i * 90), height: CGFloat(400 + i * 50))
                let window = NSWindow(contentRect: frame,
                    styleMask: [.titled, .resizable, .miniaturizable], backing: .buffered, defer: false)
                window.title = "Window restoration fixture"
                window.isReleasedWhenClosed = false
                window.isRestorable = false
                window.orderBack(nil)
                windows.append(window)
            }
            let minimized = windows[2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                app.unhideWithoutActivation()
                minimized.miniaturize(nil)
            }
            withExtendedLifetime(windows) { app.run() }
            return
        }
        guard AXIsProcessTrusted() else {
            fputs("Native window test unavailable: test runner has no Accessibility grant; no permission was requested.\n", stderr)
            exit(77)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--fixture"]
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        var launched: NSRunningApplication?
        var launchError: Error?
        var launching = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: CommandLine.arguments[1]), configuration: configuration) { app, error in
            launched = app; launchError = error; launching = false
        }
        let launchDeadline = Date().addingTimeInterval(5)
        while launching && Date() < launchDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        guard let child = launched else { throw Failure.failed("fixture launch: \(String(describing: launchError))") }
        defer {
            child.terminate()
            let deadline = Date().addingTimeInterval(2)
            while !child.isTerminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            if !child.isTerminated { kill(child.processIdentifier, SIGTERM) }
        }
        let stop = Date().addingTimeInterval(5)
        var source: AccessibilityWindows?
        var session: WorkWindowSession?
        var reason = "fixture not registered as a launched application"
        while Date() < stop {
            if let app = NSRunningApplication(processIdentifier: child.processIdentifier), app.launchDate != nil {
                let access = AccessibilityWindows(applications: { [app] })
                let captured = WorkWindowSession(access: access)
                if let captured, captured.windows.count == 3,
                   captured.windows.filter({ !$0.state.minimized }).allSatisfy({ $0.visible }),
                   captured.windows.filter({ $0.state.minimized }).count == 1 {
                    source = access; session = captured; break
                }
                reason = access.captureFailure ?? "fixture states: \(captured?.windows.map { "visible=\($0.visible), min=\($0.state.minimized)" } ?? [])"
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let source, let session else {
            let app = AXUIElementCreateApplication(child.processIdentifier)
            var value: CFTypeRef?
            let code = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            let elements = value as? [AXUIElement] ?? []
            print("fixture AX windows code=\(code.rawValue), count=\(elements.count)")
            for element in elements {
                var values: CFArray?
                AXUIElementCopyMultipleAttributeValues(element, [kAXSubroleAttribute, kAXMinimizedAttribute] as CFArray,
                    AXCopyMultipleAttributeOptions(rawValue: 0), &values)
                print("fixture AX window flags: \(String(describing: values))")
            }
            throw Failure.failed("cannot capture the native fixture windows: \(reason)")
        }
        for saved in session.windows where !saved.state.minimized {
            _ = source.move(saved.id, to: CGPoint(x: saved.state.frame.minX + 40, y: saved.state.frame.minY + 40))
            _ = source.resize(saved.id, to: CGSize(width: 480, height: 320))
        }
        Thread.sleep(forTimeInterval: 0.4)
        var sawChanged = false
        for saved in session.windows {
            if case .window(let now) = source.read(saved.id), now.frame != saved.state.frame { sawChanged = true }
        }
        guard sawChanged else { throw Failure.failed("fixture perturbation did not reach native windows") }
        for _ in 0..<20 {
            let result = session.advance(.restore)
            switch result {
            case .pending: Thread.sleep(forTimeInterval: 0.35)
            case .complete(let verified, let skipped):
                guard verified == 2, skipped == 1 else { throw Failure.failed("unexpected native counts") }
                for saved in session.windows where saved.state.minimized {
                    guard case .window(let now) = source.read(saved.id), now.minimized else {
                        throw Failure.failed("native minimized state was changed")
                    }
                }
                print("PASS: native AX capture and staged geometry/desktop readback for 2 isolated work windows; 1 minimized window preserved")
                return
            case .failed(let ids):
                for saved in session.windows {
                    print("fixture original (visible=\(saved.visible)): \(saved.state); actual: \(source.read(saved.id))")
                }
                throw Failure.failed("native window readback mismatch: \(ids)")
            }
        }
        throw Failure.failed("native convergence did not terminate")
    }
}
