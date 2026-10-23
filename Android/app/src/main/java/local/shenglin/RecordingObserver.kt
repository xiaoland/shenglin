package local.shenglin

import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.os.Handler

/** Observes anonymous system configurations without opening an audio session. */
internal class RecordingObserver(
    private val audio: AudioManager,
    private val handler: Handler,
    private val ownSession: () -> Int? = { null },
    private val listener: (Boolean?) -> Unit,
) {
    private var registered = false
    private val callback = object : AudioManager.AudioRecordingCallback() {
        override fun onRecordingConfigChanged(configurations: MutableList<AudioRecordingConfiguration>) = sample()
    }
    fun start() {
        try { audio.registerAudioRecordingCallback(callback, handler); registered = true; sample() }
        catch (_: RuntimeException) { listener(null) }
    }
    fun sample() {
        val state = try {
            otherRecording(ownSession) { audio.activeRecordingConfigurations.map { it.clientAudioSessionId } }
        } catch (_: RuntimeException) { null }
        listener(state)
    }
    fun stop() {
        if (registered) audio.unregisterAudioRecordingCallback(callback)
        registered = false
    }
}

/** 采集线程可能在系统查询期间启停；混合快照不能发布为新的录音需求。 */
internal fun otherRecording(ownSession: () -> Int?, sessions: () -> List<Int>): Boolean? {
    repeat(2) {
        val own = ownSession()
        val active = sessions()
        if (own == ownSession()) return active.any { it != own }
    }
    return null
}
