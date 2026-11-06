import AppKit
import Foundation

enum Log { static func info(_ message: String) { print(message) } }
final class FlippedTestView: NSView { override var isFlipped: Bool { true } }

@main struct AboutTests {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        setvbuf(stdout, nil, _IOLBF, 0)
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        app.applicationIconImage = NSImage(contentsOfFile: CommandLine.arguments[3])!
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let imageURL = URL(fileURLWithPath: CommandLine.arguments[2])
        AboutPage.setUpDebugLabels()
        let map = dir.appendingPathComponent("ui-labels.txt")
        DebugLabels.fileURL = map
        precondition(!DebugLabels.enabled && !FileManager.default.fileExists(atPath: map.path))
        AboutPage.render(to: imageURL)
        let image = NSBitmapImageRep(data: try Data(contentsOf: imageURL))!
        precondition(image.pixelsWide >= 560 && image.pixelsHigh >= 620)
        precondition(image.pixelsWide * 620 == image.pixelsHigh * 560)
        // 通过真实关于入口打开，使用原生按钮派发 action。
        AboutPage.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let about = app.windows.first { $0.title == "关于 UU远程伴侣" }!
        func findButton(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title.contains("Debug") { return button }
            for child in view.subviews {
                if let button = findButton(child) { return button }
            }
            return nil
        }
        let debugButton = findButton(about.contentView!)!
        debugButton.performClick(nil)
        precondition(DebugLabels.enabled, "关于按钮必须实际打开编号")
        precondition(debugButton.title == "Debug：隐藏编号")
        DebugLabels.setEnabled(false)
        about.close()

        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 320, height: 160),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "设置 · 编号回归"
        window.contentView = FlippedTestView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        let button = NSButton(title: "导入设备列表", target: nil, action: nil)
        button.frame = NSRect(x: 24, y: 40, width: 160, height: 32)
        window.contentView!.addSubview(button)
        window.orderBack(nil)
        DebugLabels.setEnabled(true)
        let text = try String(contentsOf: map, encoding: .utf8)
        precondition(text.contains("S1") && text.contains("导入设备列表"), "编号必须来自真实控件")
        let overlay = window.contentView!.subviews.first { $0 !== button }!
        precondition(overlay.isFlipped == window.contentView!.isFlipped, "编号坐标系须跟随容器")
        precondition(overlay.hitTest(NSPoint(x: 30, y: 50)) == nil, "编号不能拦截点击")
        let menu = NSMenu()
        let item = NSMenuItem(title: "设置…", action: nil, keyEquivalent: ",")
        menu.addItem(item)
        DebugLabels.decorate(menu)
        precondition(item.title == "[M1] 设置…")
        DebugLabels.decorate(menu)
        precondition(item.title == "[M1] 设置…", "重复打开菜单不能叠加编号")
        let menuText = try String(contentsOf: map, encoding: .utf8)
        precondition(menuText.contains("M1"))
        DebugLabels.setEnabled(false)
        precondition(item.title == "设置…" && item.keyEquivalent == ",")
        precondition(overlay.superview == nil && button.title == "导入设备列表")
        window.close()
        DebugLabels.setEnabled(true)
        let closedText = try String(contentsOf: map, encoding: .utf8)
        precondition(!closedText.contains("导入设备列表"), "关闭窗口不能留下编号")
        DebugLabels.setEnabled(false)
        print("PASS: About PNG and real window/Debug action; debug disabled by default; real native control labels; click-through overlay; idempotent menu labels; disable/close cleanup")
    }
}
