// 在线状态与模式核验是独立证据：模式缺失不能用来判定屏幕离线。
struct VirtualDisplayReadiness {
    var online: Bool
    var active: Bool
    var mode: SavedDisplayMode?

    var isOnline: Bool { online && active }

    func modeMatches(_ config: DeviceConfig) -> Bool {
        guard isOnline, let mode, mode.usable else { return false }
        let scale = config.hiDPI ? 2 : 1
        return mode.width == config.width / scale && mode.height == config.height / scale &&
            mode.pixelWidth == config.width && mode.pixelHeight == config.height
    }

    func status(for config: DeviceConfig) -> String {
        guard isOnline else { return "虚拟屏等待上线" }
        guard let mode else { return "虚拟屏已上线 · 模式未确认" }
        guard modeMatches(config) else {
            return "虚拟屏已上线 · 模式未通过核验（逻辑 \(mode.width)×\(mode.height)，像素 \(mode.pixelWidth)×\(mode.pixelHeight)）"
        }
        return "虚拟屏已匹配 \(config.sizeLabel)"
    }
}
