// 仅为本应用窗口和菜单生成调试编号；读取自身 AppKit accessibility，不需要额外权限。
import AppKit

@MainActor
enum DebugLabels {
    static var fileURL: URL?
    static var windowPrefix: (NSWindow) -> String? = { _ in nil }
    private(set) static var enabled = false
    private static var timer: Timer?
    private static var menuLines: [String] = []
    private static let overlays = NSMapTable<NSWindow, DebugLabelOverlay>.weakToWeakObjects()
    private static let menuTitles = NSMapTable<NSMenuItem, NSString>.weakToStrongObjects()

    static func start() {
        // 默认关闭；只有用户打开编号时才遍历界面和写对照表。
        if enabled { setEnabled(true) }
    }

    static func setEnabled(_ value: Bool) {
        enabled = value
        timer?.invalidate()
        timer = nil
        if value {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated { refresh() }
            }
        } else {
            for overlay in overlays.objectEnumerator()?.allObjects as? [DebugLabelOverlay] ?? [] {
                overlay.removeFromSuperview()
            }
            overlays.removeAllObjects()
            for item in menuTitles.keyEnumerator().allObjects as? [NSMenuItem] ?? [] {
                if let title = menuTitles.object(forKey: item) { item.title = title as String }
            }
            menuTitles.removeAllObjects()
            menuLines = []
        }
    }

    static func decorate(_ menu: NSMenu) {
        var lines: [String] = []
        for (index, item) in menu.items.filter({ !$0.isSeparatorItem }).enumerated() {
            let title = (menuTitles.object(forKey: item) as String?) ?? item.title
            if enabled {
                menuTitles.setObject(title as NSString, forKey: item)
                item.title = "[M\(index + 1)] \(title)"
                lines.append("M\(index + 1)\t菜单项\t「\(title)」")
            } else {
                item.title = title
            }
        }
        menuLines = lines
        if enabled { refresh() }
    }

    private static func refresh() {
        var lines: [String] = []
        for window in NSApp.windows {
            guard window.isVisible, let prefix = windowPrefix(window), let content = window.contentView else {
                overlays.object(forKey: window)?.removeFromSuperview()
                overlays.removeObject(forKey: window)
                continue
            }
            let overlay = overlays.object(forKey: window) ?? DebugLabelOverlay(frame: content.bounds)
            overlay.autoresizingMask = [.width, .height]
            if overlay.superview == nil { content.addSubview(overlay) }
            overlays.setObject(overlay, forKey: window)
            var labels: [(String, NSPoint)] = []
            var visited = Set<ObjectIdentifier>()
            func walk(_ element: NSAccessibilityProtocol, depth: Int = 0) {
                guard depth < 30, visited.count < 1000,
                      visited.insert(ObjectIdentifier(element)).inserted else { return }
                let role = element.accessibilityRole()
                if role == .button || role == .checkBox || role == .textField || role == .staticText || role == .link {
                    let frame = window.convertFromScreen(element.accessibilityFrame())
                    let local = content.convert(frame, from: nil)
                    if !local.isEmpty, content.bounds.intersects(local) {
                        let key = "\(prefix)\(labels.count + 1)"
                        let text = element.accessibilityLabel() ?? (element.accessibilityValue() as? String) ?? ""
                        let y = content.isFlipped ? local.minY : local.maxY - 12
                        labels.append((key, NSPoint(x: max(0, local.minX), y: max(0, y))))
                        lines.append("\(key)\t\(role?.rawValue ?? "")\t「\(text)」")
                    }
                }
                for child in element.accessibilityChildren() ?? [] {
                    if let child = child as? NSAccessibilityProtocol { walk(child, depth: depth + 1) }
                }
            }
            lines.append("== \(prefix)：\(window.title)")
            walk(content)
            overlay.labels = labels
            overlay.needsDisplay = true
        }
        if !menuLines.isEmpty { lines += ["== M：菜单栏菜单"] + menuLines }
        if let fileURL { try? lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8) }
    }
}

private final class DebugLabelOverlay: NSView {
    var labels: [(String, NSPoint)] = []
    override var isFlipped: Bool { superview?.isFlipped ?? false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white, .backgroundColor: NSColor.systemRed,
        ]
        for (label, point) in labels { (label as NSString).draw(at: point, withAttributes: attributes) }
    }
}
