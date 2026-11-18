import Foundation
final class TU: @unchecked Sendable {}
func t() { Thread.sleep(forTimeInterval: 1); let s = DispatchSemaphore(value: 0); s.wait() }
