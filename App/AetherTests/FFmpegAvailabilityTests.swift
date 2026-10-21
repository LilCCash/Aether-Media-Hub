import XCTest
@testable import Aether

final class FFmpegAvailabilityTests: XCTestCase {
    func testTheFFmpegLibrariesCanBeImportedByTheApp() {
        XCTAssertTrue(FFmpegAvailability.isLinked, "Libavformat / Libavcodec / Libavutil could not be imported from MPVKit")
        XCTAssertGreaterThanOrEqual(FFmpegAvailability.libavformatMajor, 60, "libavformat \(FFmpegAvailability.libavformatVersion)")
    }
}
