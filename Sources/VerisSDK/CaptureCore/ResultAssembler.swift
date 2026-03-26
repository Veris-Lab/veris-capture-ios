import Foundation
import UIKit

struct SuccessEvidence {
    let signedResult: String
    let faceImage: UIImage
    let qualityScore: Float
    let livenessScore: Float?
    let confidenceScore: Float?
}

enum ResultAssembler {
    static func success(_ evidence: SuccessEvidence) -> VerisResult {
        .success(
            VerisSuccessPayload(
                signedResult: evidence.signedResult,
                faceImage: evidence.faceImage,
                qualityScore: evidence.qualityScore,
                livenessScore: evidence.livenessScore,
                confidenceScore: evidence.confidenceScore,
                videoData: nil
            )
        )
    }

    static func failure(_ error: VerisError, message: String? = nil, retryable: Bool) -> VerisResult {
        .failure(error, message ?? VerisErrorMessages.message(for: error), retryable: retryable)
    }
}
