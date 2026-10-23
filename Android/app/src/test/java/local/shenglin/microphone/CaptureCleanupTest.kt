package local.shenglin.microphone

import org.junit.Assert.*
import org.junit.Test

class CaptureCleanupTest {
    @Test fun stopAndReleaseFailureStillClearSessionAndReleaseBothLocks() {
        val cleaned = mutableListOf<String>()
        val failure = try {
            releaseCaptureResources(
                { throw IllegalStateException("stop") },
                { throw IllegalStateException("release") },
                { cleaned.add("session") },
                { cleaned.add("wifi") },
                { cleaned.add("wake") },
                { cleaned.add("notification") },
            )
            error("应返回清理异常")
        } catch (error: IllegalStateException) { error }
        assertEquals(listOf("session", "wifi", "wake", "notification"), cleaned)
        assertEquals("stop", failure.message)
        assertEquals("release", failure.suppressed.single().message)
    }
}
