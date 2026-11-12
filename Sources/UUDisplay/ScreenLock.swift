import ApplicationServices
import Foundation

enum ScreenLock {
    /// 无可用图形会话时也不读写应用窗口；显示器恢复不依赖此检查。
    static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true
    }
}
