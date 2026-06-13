Pod::Spec.new do |s|
  s.name             = "VerisCapture"
  s.version          = "1.2.0"
  s.summary          = "On-device face capture with liveness detection for iOS."
  s.description      = <<-DESC
Native iOS SDK for Veris on-device face capture with quality gate and liveness detection.
Passive liveness (LBP), active liveness challenges (head turn, blink, nod), and ECDSA-signed result payloads.
No face image ever leaves the device. Requires a valid Veris subscription.
                       DESC
  s.homepage         = "https://verisinfra.com"
  s.license          = { :type => "Commercial", :file => "LICENSE" }
  s.author           = { "Veris Engineering" => "engineering@verisinfra.com" }

  # CocoaPods trunk requires a git + tag source (not :path)
  s.source           = {
    :git => "https://github.com/Veris-Lab/veris-capture-ios.git",
    :tag => s.version.to_s
  }

  s.source_files     = "Sources/VerisSDK/**/*.{swift}"
  s.platform         = :ios, "15.0"
  s.swift_version    = "5.9"
  s.frameworks       = "UIKit", "AVFoundation", "Vision"
  s.module_name      = "VerisCaptureSDK"

  s.pod_target_xcconfig = { "DEFINES_MODULE" => "YES" }
end
