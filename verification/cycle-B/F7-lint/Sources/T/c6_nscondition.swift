import Foundation
func f5() { let c = NSCondition(); c.lock(); c.wait(); c.unlock() }
