// 在线状态与模式核验是独立证据：模式缺失不能用来判定屏幕离线。
struct VirtualDisplayReadiness {
    var online: Bool
    var active: Bool
    var mode: SavedDisplayMode?

    var isOnline: Bool { online && active }

    /// 关物理屏只依赖真实可用性和像素尺寸，不能以 HiDPI 请求是否兑现为前提。
    func canKeepOnlyVirtual(_ config: DeviceConfig) -> Bool {
        guard isOnline, let mode, mode.usable, mode.width > 0, mode.height > 0 else { return false }
        return mode.pixelWidth == config.width && mode.pixelHeight == config.height
    }

    func modeMatches(_ config: DeviceConfig) -> Bool {
        guard canKeepOnlyVirtual(config), let mode else { return false }
        let scale = config.hiDPI ? 2 : 1
        return mode.width == config.width / scale && mode.height == config.height / scale
    }

    func status(for config: DeviceConfig) -> String {
        guard isOnline else { return "虚拟屏等待上线" }
        guard let mode else { return "虚拟屏已上线 · 模式未确认" }
        if canKeepOnlyVirtual(config), !modeMatches(config) {
            if config.hiDPI, mode.width == mode.pixelWidth, mode.height == mode.pixelHeight {
                return "虚拟屏已匹配 \(mode.pixelWidth)×\(mode.pixelHeight) · 标准模式（HiDPI 未启用）"
            }
            return "虚拟屏已匹配像素 \(mode.pixelWidth)×\(mode.pixelHeight) · 实际逻辑 \(mode.width)×\(mode.height)"
        }
        guard modeMatches(config) else {
            return "虚拟屏已上线 · 模式未通过核验（逻辑 \(mode.width)×\(mode.height)，像素 \(mode.pixelWidth)×\(mode.pixelHeight)）"
        }
        return "虚拟屏已匹配 \(config.sizeLabel)"
    }
}
