// 项目自己的关于窗口；不依赖未公开的 AboutKit。
import AppKit
import SwiftUI

@MainActor
enum AboutPage {
    private static let controller = AboutWindowController()

    static func show() {
        controller.updateDebugButton()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 与现有 --render-about 入口保持一致，只渲染关于界面。
    static func render(to url: URL) {
        guard let view = controller.window?.contentView else { return }
        // Link 使用 AppKit 原生视图，ImageRenderer 无法绘制；复用项目的 NSHostingView 截图方式。
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Log.info("❌ 关于窗口渲染失败")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        do { try data.write(to: url) }
        catch { Log.info("❌ 无法保存关于窗口：\(error)") }
    }

    static func setUpDebugLabels() {
        DebugLabels.fileURL = ConfigStore.dir.appendingPathComponent("ui-labels.txt")
        DebugLabels.windowPrefix = { window in
            if window.className.contains("TourKit") { return "T" }
            if window.title.contains("权限") || window.title.contains("授权") { return "P" }
            if window.title.contains("设置") { return "S" }
            if window.title.contains("关于") { return "A" }
            return nil
        }
        DebugLabels.start()
    }
}

private final class AboutWindowController: NSWindowController {
    private let debugButton = NSButton(title: "Debug：显示编号", target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "关于 UU远程伴侣"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        let content = AboutContentView(frame: NSRect(x: 0, y: 0, width: 560, height: 620))
        let view = NSHostingView(rootView: AboutView())
        view.frame = NSRect(x: 0, y: 64, width: 560, height: 556)
        content.addSubview(view)
        let copyright = NSTextField(labelWithString: "© 2026 AoyamaShou · MIT")
        copyright.font = .systemFont(ofSize: 11)
        copyright.textColor = .secondaryLabelColor
        copyright.frame = NSRect(x: 24, y: 24, width: 250, height: 18)
        content.addSubview(copyright)
        debugButton.bezelStyle = .rounded
        debugButton.frame = NSRect(x: 392, y: 18, width: 144, height: 28)
        debugButton.target = self
        debugButton.action = #selector(toggleDebug)
        content.addSubview(debugButton)
        window.contentView = content
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateDebugButton() {
        debugButton.title = DebugLabels.enabled ? "Debug：隐藏编号" : "Debug：显示编号"
    }

    @objc private func toggleDebug() {
        DebugLabels.setEnabled(!DebugLabels.enabled)
        updateDebugButton()
    }
}

private final class AboutContentView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}

private struct AboutView: View {
    private let credits: [(name: String, url: String, detail: String)] = [
        ("FreeDisplay", "https://github.com/huberdf/FreeDisplay", "作者 huberdf · MIT 协议 · 虚拟屏接口声明"),
        ("PermissionFlow", "https://github.com/jaywcjlove/PermissionFlow", "作者 小弟调调（jaywcjlove） · MIT 协议 · 授权引导"),
        ("TourKit", "https://github.com/rampatra/TourKit", "作者 Ram Patra（rampatra） · MIT 协议 · 功能介绍页"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSImage(named: NSImage.Name("AppIcon")) ?? NSApp.applicationIconImage)
                    .resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("UU远程伴侣").font(.title2.bold())
                    Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link("项目仓库", destination: URL(string: "https://github.com/aoyamashou/UUyc-companion")!)
            }
            Text("改善 Mac 版 UU远程 的使用体验，自动提供与您的设备同分辨率的虚拟屏幕，告别上下大黑边。")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Text("作者").font(.headline)
                HStack(spacing: 16) {
                    Link("作者主页", destination: URL(string: "https://ryou.im")!)
                    Link("X 主页", destination: URL(string: "https://x.com/corndogjpn2")!)
                    Link("小红书", destination: URL(string: "https://xhslink.cn/o/2M9LOaUzn01")!)
                    Link("GitHub 主页", destination: URL(string: "https://github.com/aoyamashou")!)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("致谢开源项目").font(.headline)
                ForEach(credits, id: \.name) { credit in
                    VStack(alignment: .leading, spacing: 3) {
                        Link(credit.name, destination: URL(string: credit.url)!)
                        Text(credit.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("声明").font(.headline)
                Text("本应用与 UU远程 及其开发商没有任何直接、间接或连带关系，仅为作者自己使用方便而开发。如果将来 UU远程 官方在 Mac 版中内置了同样的功能，删掉本应用即可。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 560, height: 556)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
