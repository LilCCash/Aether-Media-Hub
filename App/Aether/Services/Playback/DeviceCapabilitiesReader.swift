import AVFoundation
import UIKit
import VideoToolbox
import AetherCore

/// Reads what this device and screen can do, at run time. These are the platform's own answers; they are not
/// inferred from the device model.
enum DeviceCapabilitiesReader {
    @MainActor
    static func current() -> DeviceVideoCapabilities {
        let modes = AVPlayer.availableHDRModes
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first ?? UIScreen.main
        return DeviceVideoCapabilities(
            supportsHDR10: modes.contains(.hdr10),
            supportsHLG: modes.contains(.hlg),
            supportsDolbyVision: modes.contains(.dolbyVision),
            hardwareHEVC: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
            hardwareAV1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1),
            hardwareVP9: VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9),
            edrHeadroom: Double(screen.potentialEDRHeadroom)
        )
    }
}
