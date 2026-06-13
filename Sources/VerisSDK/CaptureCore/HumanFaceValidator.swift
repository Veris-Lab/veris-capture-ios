import Foundation
import Vision

/// HumanFaceValidator — Layer 3, runs after the quality gate passes.
/// iOS port of the Android validator. Rejects cartoons, illustrations, inverted
/// faces and gross occlusions using landmark geometry only — no extra model.
///
/// Vision coordinate note: landmark points are normalised within the face bounding
/// box with y increasing UPWARD, so an upright face has eyes at HIGHER y than mouth.
enum HumanFaceValidator {

    struct ValidationResult {
        let passed: Bool
        let instruction: String
        let failCode: String?

        static let pass = ValidationResult(passed: true, instruction: "", failCode: nil)
        static func fail(_ code: String, _ msg: String = "Keep your full face visible") -> ValidationResult {
            ValidationResult(passed: false, instruction: msg, failCode: code)
        }
    }

    static func validate(
        face: VNFaceObservation,
        leftEyeOpen: Float,
        rightEyeOpen: Float,
        imageAspect: CGFloat        // oriented image width / height
    ) -> ValidationResult {

        guard let landmarks = face.landmarks else {
            return .fail("HUMAN_FACE_INVALID:no_landmarks")
        }

        // Core landmark regions must exist — they vanish on blank ovals / heavy occlusion.
        guard let leftEye = landmarks.leftEye, leftEye.pointCount >= 3,
              let rightEye = landmarks.rightEye, rightEye.pointCount >= 3 else {
            return .fail("HUMAN_FACE_INVALID:no_eye_landmarks")
        }
        guard let nose = landmarks.nose, nose.pointCount >= 2 else {
            return .fail("HUMAN_FACE_INVALID:no_nose_landmark")
        }
        guard let lips = landmarks.outerLips, lips.pointCount >= 4 else {
            return .fail("HUMAN_FACE_INVALID:mouth_occluded")
        }

        // Eye-open probabilities in valid range and roughly symmetric — a photo artifact
        // or drawn face often produces wildly asymmetric values.
        if leftEyeOpen < 0 || rightEyeOpen < 0 {
            return .fail("HUMAN_FACE_INVALID:no_eye_probability")
        }
        if abs(leftEyeOpen - rightEyeOpen) > 0.60 {
            return .fail("HUMAN_FACE_INVALID:eye_asymmetry")
        }

        // Face proportion — true width:height needs the image aspect since the
        // bounding box is normalised independently per axis.
        let boxRatio = (face.boundingBox.width * imageAspect) / max(face.boundingBox.height, 0.001)
        if boxRatio < 0.45 || boxRatio > 1.20 {
            return .fail("HUMAN_FACE_INVALID:face_proportion")
        }

        let leftEyeMean  = mean(of: leftEye)
        let rightEyeMean = mean(of: rightEye)
        let noseMean     = mean(of: nose)
        let lipsPoints   = lips.normalizedPoints
        let mouthMean    = mean(of: lips)

        // Inverted-face detection — eyes must be ABOVE the mouth (higher y in Vision space).
        if leftEyeMean.y <= mouthMean.y {
            return .fail("HUMAN_FACE_INVALID:inverted_geometry")
        }

        // Eye vertical alignment — eyes roughly level (box-space fractions).
        if abs(leftEyeMean.y - rightEyeMean.y) > 0.15 {
            return .fail("HUMAN_FACE_INVALID:eye_alignment")
        }

        // Lower-face geometry — covered mouths keep landmarks but with implausible
        // ratios. Fractions of face box dims, same bands as Android.
        let mouthBottomY: CGFloat = lipsPoints.map(\.y).min() ?? mouthMean.y
        let noseToMouthRatio: CGFloat = abs(noseMean.y - mouthBottomY)
        let mouthMinX: CGFloat = lipsPoints.map(\.x).min() ?? 0
        let mouthMaxX: CGFloat = lipsPoints.map(\.x).max() ?? 0
        let mouthWidthRatio: CGFloat = mouthMaxX - mouthMinX
        let mouthCenterOffset: CGFloat = abs((mouthMaxX + mouthMinX) / 2 - 0.5)
        let badNoseMouth = noseToMouthRatio < 0.11 || noseToMouthRatio > 0.40
        let badMouthWidth = mouthWidthRatio < 0.18 || mouthWidthRatio > 0.70
        if badNoseMouth || badMouthWidth || mouthCenterOffset > 0.25 {
            return .fail("HUMAN_FACE_INVALID:mouth_geometry")
        }

        return .pass
    }

    private static func mean(of region: VNFaceLandmarkRegion2D) -> CGPoint {
        let pts = region.normalizedPoints
        guard !pts.isEmpty else { return .zero }
        let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(pts.count), y: sum.y / CGFloat(pts.count))
    }
}
