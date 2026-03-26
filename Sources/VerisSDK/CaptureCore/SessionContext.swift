import Foundation

struct SessionContext {
    let nonce: String
    let plan: CapturePlan
    let maxRetries: Int
    let strictness: VerisStrictness
}
