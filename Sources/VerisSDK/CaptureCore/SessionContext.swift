import Foundation

struct SessionContext {
    let nonce: String
    let plan: CapturePlan
    let maxRetries: Int
    let strictness: VerisStrictness
    var environment: String = "production"
    var licenseKeyId: String = ""
    var validationState: String = "verified"
}
