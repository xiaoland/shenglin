package local.shenglin

import org.junit.Assert.*
import org.junit.Test

class RecordingObserverTest {
    @Test fun ownCaptureDoesNotHideOtherApps() {
        assertEquals(false, otherRecording({ 7 }) { listOf(7) })
        assertEquals(true, otherRecording({ 7 }) { listOf(7, 9) })
        assertEquals(true, otherRecording({ null }) { listOf(9) })
    }
    @Test fun endingCaptureDuringQueryRetriesInsteadOfPublishingOwnDemand() {
        var own: Int? = 7
        var queries = 0
        assertEquals(false, otherRecording({ own }) {
            queries++
            if (queries == 1) { own = null; listOf(7) } else emptyList()
        })
        assertEquals(2, queries)
    }
    @Test fun startingCaptureDuringQueryRetriesAndPreservesOtherRecording() {
        var own: Int? = null
        assertEquals(true, otherRecording({ own }) { own = 7; listOf(7, 9) })
    }
    @Test fun continuouslyChangingCaptureIsUnknown() {
        var own = 1
        assertNull(otherRecording({ own }) { listOf(own++) })
    }
}
