package local.shenglin

import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.os.Handler

/** Observes anonymous system configurations without opening an audio session. */
internal class RecordingObserver(
    private val audio: AudioManager,
    private val handler: Handler,
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
        val state = try { audio.activeRecordingConfigurations.isNotEmpty() } catch (_: RuntimeException) { null }
        listener(state)
    }
    fun stop() {
        if (registered) audio.unregisterAudioRecordingCallback(callback)
        registered = false
    }
}
