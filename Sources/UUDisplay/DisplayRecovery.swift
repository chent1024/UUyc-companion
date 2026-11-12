// 断开收尾的单一顺序：亮物理屏 → 释放虚拟屏 → 等热插拔稳定 → 恢复原配置 → 连续核验。
// 不以“原模式已可用”作为释放虚拟屏的前提，也不把等待消耗在配置事务的重试预算里。
import Foundation

struct DisplayRecovery {
    struct Observation {
        var pendingEnable: Bool
        var hasActivePhysical: Bool
        var physical: [SavedDisplay]?
        var ownedVirtual: Set<UInt32>
        var virtualReadyToRelease: Bool
        var online: Set<UInt32>
        var modesAvailable: Bool
        var configurationVerified: Bool
        var transactionTimedOut: Bool
        var now: TimeInterval
    }
    enum Action: Equatable {
        case enablePhysical
        case releaseVirtual
        case restoreConfiguration
        case wait
        case complete
        case failed(String)
    }
    private(set) var releasedVirtual: Set<UInt32> = []
    private var awaitingRemoval = false
    private var enableAttempts = 0
    private var configurationAttempts = 0
    private var enableAcceptedAt: TimeInterval?
    private var lastPhysical: [SavedDisplay]?
    private var stableSamples = 0
    private var verifiedSamples = 0
    private var waitStage: String?
    private var waitSince: TimeInterval = 0

    mutating func didRelease(_ ids: Set<UInt32>) {
        releasedVirtual.formUnion(ids)
        awaitingRemoval = true
        resetSamples()
    }

    mutating func didEnableResult(accepted: Bool, now: TimeInterval) {
        enableAcceptedAt = accepted ? now : nil
    }

    /// 显式手动恢复可重试，但不能忘记已释放屏幕的离线等待，避免再次向旧拓扑提交事务。
    mutating func retry() {
        enableAttempts = 0
        configurationAttempts = 0
        resetSamples()
    }

    mutating func next(_ state: Observation) -> Action {
        if state.pendingEnable {
            if state.transactionTimedOut {
                return wait("enable-timeout", now: state.now, failure: "启用物理屏事务超时，保留恢复记录")
            }
            if let accepted = enableAcceptedAt {
                // CGComplete 成功只表示已接受；热插拔尚未完成时再次 enable 会与前一请求重叠。
                return state.now - accepted < 15 ? .wait : .failed("物理屏启用请求已接受，但活动状态未在 15 秒内落地；未重复提交")
            }
            guard enableAttempts < 3 else { return .failed("物理屏仍未启用，保留恢复记录") }
            enableAttempts += 1
            resetSamples()
            return .enablePhysical
        }
        enableAcceptedAt = nil
        guard state.hasActivePhysical else {
            return wait("physical", now: state.now, failure: "没有可用物理屏，保留虚拟屏和恢复记录")
        }
        if awaitingRemoval {
            if !releasedVirtual.isDisjoint(with: state.online) {
                return wait("removal", now: state.now, failure: "虚拟屏尚未离线，未提交物理屏模式事务")
            }
            awaitingRemoval = false
            resetSamples()
        }
        if let physical = state.physical?.sorted(by: { $0.uuid < $1.uuid }), !physical.isEmpty {
            stableSamples = physical == lastPhysical ? stableSamples + 1 : 1
            lastPhysical = physical
        } else { stableSamples = 0; lastPhysical = nil }

        if !state.ownedVirtual.isEmpty {
            guard stableSamples >= 2, state.virtualReadyToRelease else {
                return wait("physical", now: state.now, failure: "物理屏或虚拟屏尚未稳定，保留恢复记录")
            }
            return .releaseVirtual
        }
        guard stableSamples >= 2 else {
            return wait("physical", now: state.now, failure: "物理屏拓扑尚未稳定，保留恢复记录")
        }
        // 超时后仍可在物理屏已可用时安全释放所属虚拟屏；不再向 WindowServer 盲发事务。
        if state.configurationVerified {
            verifiedSamples += 1
            return verifiedSamples >= 2 ? .complete : .wait
        }
        verifiedSamples = 0
        guard !state.transactionTimedOut else { return .failed("显示事务超时，物理屏已保留，停止后续配置并保留记录") }
        guard state.modesAvailable else {
            return wait("modes", now: state.now, failure: "原显示模式仍不可用，保留记录，不替换分辨率或刷新率")
        }
        guard configurationAttempts < 3 else { return .failed("原显示配置未通过核验，保留恢复记录") }
        configurationAttempts += 1
        resetSamples()
        return .restoreConfiguration
    }

    private mutating func resetSamples() {
        lastPhysical = nil
        stableSamples = 0
        verifiedSamples = 0
        waitStage = nil
    }

    private mutating func wait(_ stage: String, now: TimeInterval, failure: String) -> Action {
        if waitStage != stage { waitStage = stage; waitSince = now }
        return now - waitSince >= 10 ? .failed(failure) : .wait
    }
}
