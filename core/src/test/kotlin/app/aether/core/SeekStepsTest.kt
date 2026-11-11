package app.aether.core

import app.aether.core.playback.SeekSteps
import kotlin.test.Test
import kotlin.test.assertEquals

class SeekStepsTest {
    @Test fun aTapJumpsTheBaseStepAndAHoldJumpsFurther() {
        assertEquals(10, SeekSteps.stepSeconds(0, 10))
        assertEquals(10, SeekSteps.stepSeconds(5, 10))
        assertEquals(20, SeekSteps.stepSeconds(6, 10))
        assertEquals(30, SeekSteps.stepSeconds(16, 10))
        assertEquals(60, SeekSteps.stepSeconds(31, 10))
    }

    @Test fun manyPressesInARowAddUpToOneTargetInsideTheVideo() {
        var position = 100_000L
        repeat(5) { position = SeekSteps.target(position, 10_000, 3_600_000) }
        assertEquals(150_000L, position)
        assertEquals(0L, SeekSteps.target(5_000, -10_000, 3_600_000), "never before the start")
        assertEquals(3_600_000L, SeekSteps.target(3_595_000, 10_000, 3_600_000), "never past the end")
        assertEquals(1_010_000L, SeekSteps.target(1_000_000, 10_000, -1), "a length that is not known yet does not block the jump")
    }
}
