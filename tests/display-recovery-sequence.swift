import Foundation

enum DisplayRecoveryTests {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    private static func sample(_ baseline: DisplaySession) -> DisplayRecovery.Observation {
        .init(pendingEnable: false, hasActivePhysical: true, physical: baseline.displays,
              ownedVirtual: [], virtualReadyToRelease: true, online: [1, 2],
              modesAvailable: true, configurationVerified: false, transactionTimedOut: false, now: 0)
    }
    private static func advance(_ recovery: inout DisplayRecovery, _ state: inout DisplayRecovery.Observation) -> DisplayRecovery.Action {
        state.now += 0.5
        let action = recovery.next(state)
        if action == .releaseVirtual { recovery.didRelease(state.ownedVirtual) }
        return action
    }
    private static func nextAction(_ recovery: inout DisplayRecovery, _ state: inout DisplayRecovery.Observation) -> DisplayRecovery.Action {
        for _ in 0..<30 {
            let action = advance(&recovery, &state)
            if action != .wait { return action }
        }
        preconditionFailure("recovery wait must be bounded")
    }

    static func run(_ baseline: DisplaySession) {
        do {
            // 本次故障：物理屏已亮但为默认模式，虚拟主屏残留，旧模式此时不可选。
            var recovery = DisplayRecovery(); var state = sample(baseline)
            state.pendingEnable = true; state.ownedVirtual = [10]; state.online.insert(10)
            state.modesAvailable = false
            expect(advance(&recovery, &state) == .enablePhysical, "must enable both physical displays first")
            state.pendingEnable = false
            expect(nextAction(&recovery, &state) == .releaseVirtual, "missing original mode must not prevent virtual release")
            state.ownedVirtual = []
            expect(advance(&recovery, &state) == .wait, "release return alone is not proof of offline")
            state.online.remove(10)
            expect(advance(&recovery, &state) == .wait, "must settle after virtual disappears")
            for _ in 0..<8 {
                expect(advance(&recovery, &state) == .wait, "wait for original mode; do not write a substitute mode")
            }
            state.modesAvailable = true
            expect(nextAction(&recovery, &state) == .restoreConfiguration, "restore only after virtual removal and mode availability")
            state.configurationVerified = true
            expect(advance(&recovery, &state) == .wait, "first sample after transaction is not completion")
            expect(advance(&recovery, &state) == .wait, "require two consecutive verified stable samples")
            expect(advance(&recovery, &state) == .complete, "now may clean records and restore windows")
        }
        do {
            var recovery = DisplayRecovery(); var state = sample(baseline)
            state.pendingEnable = true
            for _ in 0..<3 { expect(advance(&recovery, &state) == .enablePhysical, "enable has own budget") }
            state.pendingEnable = false
            for _ in 0..<3 {
                expect(nextAction(&recovery, &state) == .restoreConfiguration, "enable attempts must not consume mode restore budget")
            }
            if case .failed = nextAction(&recovery, &state) {} else { preconditionFailure("mode attempts must stop at three") }
        }
        do {
            var recovery = DisplayRecovery(); var state = sample(baseline)
            state.ownedVirtual = [10]; state.online.insert(10)
            expect(nextAction(&recovery, &state) == .releaseVirtual, "release once")
            state.ownedVirtual = []
            if case .failed = nextAction(&recovery, &state) {} else { preconditionFailure("virtual offline wait must time out, never apply modes to stale topology") }
        }
        do {
            var recovery = DisplayRecovery(); var state = sample(baseline)
            state.ownedVirtual = [10]; state.hasActivePhysical = false
            if case .failed = nextAction(&recovery, &state) {} else { preconditionFailure("must keep virtual when no physical display is available") }
            expect(recovery.releasedVirtual.isEmpty, "never release into a black desktop")
        }
        do {
            var recovery = DisplayRecovery(); var state = sample(baseline)
            state.ownedVirtual = [10]; state.virtualReadyToRelease = false
            for _ in 0..<6 { expect(advance(&recovery, &state) == .wait, "must respect virtual minimum lifetime") }
            state.virtualReadyToRelease = true
            expect(advance(&recovery, &state) == .releaseVirtual, "release once safe and physical topology stable")
        }
        do {
            var recovery = DisplayRecovery(); var state = sample(baseline)
            state.ownedVirtual = [10]; state.online.insert(10); state.transactionTimedOut = true
            expect(nextAction(&recovery, &state) == .releaseVirtual, "timeout must not retain virtual primary after physical displays are usable")
            state.ownedVirtual = []; state.online.remove(10)
            if case .failed = nextAction(&recovery, &state) {} else { preconditionFailure("no new CG transaction after a timeout") }
        }
        do {
            var recovery = DisplayRecovery(); var state = sample(baseline)
            expect(nextAction(&recovery, &state) == .restoreConfiguration, "initial restore")
            state.configurationVerified = true
            expect(advance(&recovery, &state) == .wait, "settle")
            expect(advance(&recovery, &state) == .wait, "one verified sample")
            // 模拟 WindowServer 迟到的热插拔再次改掉布局/模式。
            state.configurationVerified = false
            state.physical![0].x += 488
            expect(advance(&recovery, &state) == .wait, "reconfiguration invalidates the stable verification")
            expect(nextAction(&recovery, &state) == .restoreConfiguration, "must reapply instead of prematurely cleaning records")
            state.physical = baseline.displays; state.configurationVerified = true
            expect(nextAction(&recovery, &state) == .complete, "stable exact configuration completes")
        }
        do {
            var recovery = DisplayRecovery(); var state = sample(baseline)
            state.modesAvailable = false
            if case .failed = nextAction(&recovery, &state) {} else { preconditionFailure("unavailable 120 Hz mode must not silently become 60 Hz") }
        }
        do {
            var recovery = DisplayRecovery(); var state = sample(baseline)
            state.transactionTimedOut = true; state.configurationVerified = true
            expect(nextAction(&recovery, &state) == .complete, "late successful result may be confirmed by reads without another CG transaction")
        }
        do {
            var recovery = DisplayRecovery(); var state = sample(baseline)
            state.pendingEnable = true; state.transactionTimedOut = true
            expect(advance(&recovery, &state) == .wait, "ambiguous enable timeout requires observation, not another transaction")
            state.pendingEnable = false; state.configurationVerified = true
            expect(nextAction(&recovery, &state) == .complete, "late physical activation may complete by exact readback")
        }
        do {
            var recovery = DisplayRecovery(); var state = sample(baseline)
            state.ownedVirtual = [10]; state.online.insert(10)
            expect(nextAction(&recovery, &state) == .releaseVirtual, "release before retry")
            state.ownedVirtual = []
            recovery.retry()
            for _ in 0..<4 { expect(advance(&recovery, &state) == .wait, "manual retry must not forget a released virtual is still online") }
            state.online.remove(10)
            expect(nextAction(&recovery, &state) == .restoreConfiguration, "retry may continue after actual virtual disappearance")
        }
        do {
            var recovery = DisplayRecovery(); var state = sample(baseline)
            recovery.didRelease([9]) // 连接期间换配置，旧虚拟屏已交还但尚未离线。
            recovery.retry() // 紧接着断开，不得丢掉旧屏退出事实。
            state.ownedVirtual = [10]; state.online.formUnion([9, 10])
            for _ in 0..<4 { expect(advance(&recovery, &state) == .wait, "disconnect must still wait for the retired virtual display") }
            state.online.remove(9)
            expect(nextAction(&recovery, &state) == .releaseVirtual, "after old display disappears, safely retire the current virtual display")
        }
        do {
            var recovery = DisplayRecovery(); var state = sample(baseline)
            state.pendingEnable = true
            expect(advance(&recovery, &state) == .enablePhysical, "submit enable once")
            recovery.didEnableResult(accepted: true, now: state.now)
            for _ in 0..<20 { expect(advance(&recovery, &state) == .wait, "accepted enable must not be resubmitted while activation is asynchronous") }
            recovery.retry()
            expect(advance(&recovery, &state) == .wait, "manual retry must not overlap an already accepted activation")
            state.pendingEnable = false
            expect(nextAction(&recovery, &state) == .restoreConfiguration, "activation completion resumes exact configuration restoration")
        }
        do {
            var recovery = DisplayRecovery(); var state = sample(baseline)
            state.pendingEnable = true
            expect(advance(&recovery, &state) == .enablePhysical, "initial enable")
            recovery.didEnableResult(accepted: true, now: state.now)
            if case .failed = nextAction(&recovery, &state) {} else { preconditionFailure("accepted activation must be bounded without duplicate native requests") }
        }
        print("PASS: 14 disconnect recovery groups; accepted enable waits without resubmission; exact modes and verification; separate budgets; bounded waits; timeout safety")
    }
}
