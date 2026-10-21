import XCTest
@testable import AetherCore

final class BackgroundPolicyTests: XCTestCase {
    private typealias Policy = PlayerBackgroundPolicy

    private func decide(_ phase: Policy.Phase,
                        playing: Bool = true,
                        pip: Bool = false,
                        external: Bool = false,
                        possible: Bool = true,
                        auto: Bool = true,
                        audio: Bool = true,
                        expired: Bool = false) -> Policy.Decision {
        return Policy.decide(Policy.State(phase: phase, isPlaying: playing, isPictureInPictureActive: pip,
                                          isExternalPlaybackActive: external, isPictureInPicturePossible: possible,
                                          autoPictureInPicture: auto, allowBackgroundAudio: audio,
                                          pictureInPictureGraceExpired: expired))
    }

    // MARK: Inactive is not a reason to touch the picture

    /// 1.0 detached the video as soon as the app became inactive, which also happens on the way to the Home screen: the
    /// system then had no video layer to move into the floating window.
    func testInactiveNeverDetachesOrPauses() {
        for audio in [true, false] {
            for auto in [true, false] {
                for playing in [true, false] {
                    let decision = decide(.inactive, playing: playing, auto: auto, audio: audio)
                    XCTAssertEqual(decision.video, .keep, "audio \(audio) auto \(auto) playing \(playing)")
                    XCTAssertFalse(decision.pause)
                    XCTAssertFalse(decision.waitForPictureInPicture)
                    XCTAssertTrue(decision.recordProgress, "the position is saved in case the app is killed next")
                }
            }
        }
    }

    func testBecomingActiveShowsThePictureAgainWithoutPausing() {
        let decision = decide(.active)
        XCTAssertEqual(decision.video, .attach)
        XCTAssertFalse(decision.pause)
        XCTAssertFalse(decision.recordProgress)
    }

    // MARK: Background

    func testBackgroundWithPictureInPictureActiveLeavesEverythingAlone() {
        let decision = decide(.background, pip: true, audio: false)
        XCTAssertEqual(decision.video, .keep)
        XCTAssertFalse(decision.pause)
        XCTAssertFalse(decision.waitForPictureInPicture)
    }

    func testBackgroundWhileCastingToAirPlayLeavesEverythingAlone() {
        let decision = decide(.background, external: true, audio: false)
        XCTAssertEqual(decision.video, .keep)
        XCTAssertFalse(decision.pause)
    }

    func testBackgroundWaitsForAutomaticPictureInPictureBeforeFallingBack() {
        let decision = decide(.background)
        XCTAssertTrue(decision.waitForPictureInPicture)
        XCTAssertEqual(decision.video, .keep, "the layer must still be there while the system decides")
        XCTAssertFalse(decision.pause)
    }

    func testAfterTheGraceThePlayerFallsBackToSoundOnly() {
        let decision = decide(.background, expired: true)
        XCTAssertEqual(decision.video, .detach)
        XCTAssertFalse(decision.pause)
        XCTAssertFalse(decision.waitForPictureInPicture)
    }

    func testAfterTheGraceWithoutBackgroundAudioThePlayerPauses() {
        let decision = decide(.background, audio: false, expired: true)
        XCTAssertTrue(decision.pause)
        XCTAssertFalse(decision.waitForPictureInPicture)
    }

    func testNoWaitWhenAutomaticPictureInPictureIsOff() {
        let decision = decide(.background, auto: false)
        XCTAssertFalse(decision.waitForPictureInPicture)
        XCTAssertEqual(decision.video, .detach)
    }

    func testNoWaitWhenTheSystemSaysItIsNotPossible() {
        let decision = decide(.background, possible: false)
        XCTAssertFalse(decision.waitForPictureInPicture)
        XCTAssertEqual(decision.video, .detach)
    }

    func testNoWaitWhenPaused() {
        let decision = decide(.background, playing: false)
        XCTAssertFalse(decision.waitForPictureInPicture)
    }

    func testBackgroundWithoutAnythingKeepsOnlyTheSound() {
        let decision = decide(.background, auto: false, audio: true)
        XCTAssertEqual(decision.video, .detach)
        XCTAssertFalse(decision.pause)
        XCTAssertTrue(decision.recordProgress)
    }

    func testBackgroundWithoutAnythingAndNoBackgroundAudioPauses() {
        let decision = decide(.background, auto: false, audio: false)
        XCTAssertTrue(decision.pause)
        XCTAssertEqual(decision.video, .keep)
    }

    func testGraceIsShort() {
        XCTAssertLessThan(Policy.pictureInPictureGrace, 2)
        XCTAssertGreaterThan(Policy.pictureInPictureGrace, 0.2)
    }

    // MARK: Button availability

    func testMPVNeverOffersPictureInPictureAndSaysWhy() {
        let availability = PictureInPictureAvailability.evaluate(engine: .mpv, deviceSupportsPictureInPicture: true,
                                                                 controllerExists: true, isPossible: true)
        XCTAssertFalse(availability.canStart)
        XCTAssertTrue(availability.explanation?.contains("MPV") == true)
    }

    func testAVPlayerReadyOffersPictureInPicture() {
        let availability = PictureInPictureAvailability.evaluate(engine: .avPlayer, deviceSupportsPictureInPicture: true,
                                                                 controllerExists: true, isPossible: true)
        XCTAssertEqual(availability, .available)
        XCTAssertTrue(availability.canStart)
        XCTAssertNil(availability.explanation)
    }

    func testAVPlayerNotYetPossibleAsksToWait() {
        let availability = PictureInPictureAvailability.evaluate(engine: .avPlayer, deviceSupportsPictureInPicture: true,
                                                                 controllerExists: true, isPossible: false)
        XCTAssertEqual(availability, .notReadyYet)
        XCTAssertFalse(availability.canStart)
        XCTAssertNotNil(availability.explanation)
    }

    func testNoControllerMeansTheDeviceOrLaunchDoesNotAllowIt() {
        for supported in [true, false] {
            let availability = PictureInPictureAvailability.evaluate(engine: .avPlayer, deviceSupportsPictureInPicture: supported,
                                                                     controllerExists: false, isPossible: false)
            XCTAssertEqual(availability, .deviceUnsupported)
        }
        let unsupported = PictureInPictureAvailability.evaluate(engine: .avPlayer, deviceSupportsPictureInPicture: false,
                                                                controllerExists: true, isPossible: true)
        XCTAssertEqual(unsupported, .deviceUnsupported)
    }

    func testEveryNegativeAnswerHasAnExplanation() {
        let all: [PictureInPictureAvailability] = [.notReadyYet, .engineUnsupported(engine: "MPV"), .deviceUnsupported]
        for availability in all {
            XCTAssertFalse(availability.canStart)
            XCTAssertFalse(availability.explanation?.isEmpty ?? true)
        }
    }
}
