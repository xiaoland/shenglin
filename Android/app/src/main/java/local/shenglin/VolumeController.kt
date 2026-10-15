package local.shenglin

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build

/** Owns only a matching volume/route snapshot. External changes relinquish the demand round. */
class VolumeController(private val port: Port) {
    interface Port {
        fun current(): Int
        fun maximum(): Int
        fun fixed(): Boolean = false
        fun route(): String?
        fun set(value: Int)
        fun load(): Snapshot?
        fun save(snapshot: Snapshot?)
    }
    data class Snapshot(val original: Int, val applied: Int, val route: String?)
    private var baselineRoute: String? = null
    private var baselineVolume = 0
    private var round = false
    private var manual = false
    private var result = "alreadyRestored"
    fun result() = result
    private fun outcome(code: String, message: String): String { result = code; return message }

    constructor(context: Context, audio: AudioManager) : this(object : Port {
        private val saved = context.getSharedPreferences("volume-recovery", Context.MODE_PRIVATE)
        override fun current() = audio.getStreamVolume(AudioManager.STREAM_MUSIC)
        override fun maximum() = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        override fun fixed() = audio.isVolumeFixed
        override fun route(): String? {
            val devices = if (Build.VERSION.SDK_INT >= 33) {
                audio.getAudioDevicesForAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build())
                    .takeIf { it.isNotEmpty() } ?: return null
            } else {
                audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).filter {
                    it.type != AudioDeviceInfo.TYPE_BUILTIN_EARPIECE && it.type != AudioDeviceInfo.TYPE_TELEPHONY
                }.takeIf { it.size == 1 } ?: return null
            }
            // Before API 33, only a single unambiguous output supplies enough routing evidence.
            return devices.map { "${it.id}:${it.type}:${if (Build.VERSION.SDK_INT >= 28) it.address else ""}" }.sorted().joinToString("|")
        }
        override fun set(value: Int) = audio.setStreamVolume(AudioManager.STREAM_MUSIC, value, 0)
        override fun load() = if (saved.contains("original")) Snapshot(saved.getInt("original", -1), saved.getInt("applied", -1), saved.getString("route", "")) else null
        override fun save(snapshot: Snapshot?) {
            val edit = saved.edit().clear()
            snapshot?.let { edit.putInt("original", it.original).putInt("applied", it.applied).putString("route", it.route) }
            check(edit.commit()) { "无法保存音量恢复记录" }
        }
    })
    private fun baseline() { baselineRoute = port.route(); baselineVolume = port.current() }
    private fun changed() = baselineRoute != null && (baselineRoute != port.route() || baselineVolume != port.current())
    fun isManual() = manual
    fun recover(): String = restore().also { if (result == "preservedManualOrRoute") manual = true }
    @JvmOverloads fun update(demand: Boolean, recording: Boolean?, targetPercent: Int, inheritedManual: Boolean = false): String {
        try {
            if (inheritedManual) { manual = true; round = true; return preserveAfterRestore() }
            if (!demand) { val message = restore(); round = false; manual = false; baselineRoute = null; return message }
            if (port.fixed()) return outcome("outputUnsupported", "此设备使用固定音量，暂不调整音量")
            if (port.route() == null) return outcome("outputUnsupported", "当前媒体输出路由无法确认，暂不调整音量")
            if (!round) { round = true; baseline() }
            if (changed()) { manual = true; clear(); baseline() }
            if (manual) return preserveAfterRestore()
            if (recording != false) {
                val message = restore(); baseline()
                return if (message.startsWith("错误")) message else outcome(
                    if (recording == null) "unknown" else "protectedLocal",
                    if (recording == null) "录音状态未知，保护本机输出" else "本机正在录音，保护本机输出")
            }
            val now = port.current()
            val wanted = minOf(now, port.maximum() * targetPercent.coerceIn(0, 50) / 100)
            if (wanted == now) return outcome("alreadyBelowTarget", "媒体音量已符合目标")
            val original = port.load()?.original ?: now
            port.save(Snapshot(original, wanted, port.route()))
            port.set(wanted)
            val actual = port.current()
            port.save(Snapshot(original, actual, port.route())); baseline()
            return if (actual <= wanted) outcome("applied", "已降低媒体音量") else outcome("setFailed", "错误：系统未接受音量调整")
        } catch (error: RuntimeException) { return outcome("setFailed", "错误：音量操作失败（${error.javaClass.simpleName}）") }
    }
    private fun preserveAfterRestore(): String {
        val message = restore()
        return if (message.startsWith("错误") || result == "outputUnsupported") message
        else outcome("preservedManualOrRoute", "保留你手动调整的音量或输出设备")
    }
    fun restoreNow(): String {
        val message = restore()
        if (round) manual = true
        try { baseline() } catch (_: RuntimeException) { return outcome("readFailed", "错误：读取媒体音量失败") }
        return message
    }
    private fun clear() = port.save(null)
    private fun restore(): String {
        try {
            val saved = port.load() ?: return outcome("alreadyRestored", "媒体音量保持原状")
            if (port.fixed()) return outcome("outputUnsupported", "此设备使用固定音量，保留恢复记录")
            val route = port.route() ?: return outcome("outputUnsupported", "当前媒体输出路由无法确认，保留恢复记录")
            if (route != saved.route || port.current() != saved.applied) {
                clear(); return outcome("preservedManualOrRoute", "保留你手动调整的音量或输出设备")
            }
            port.set(saved.original)
            if (port.current() != saved.original) return outcome("restoreFailed", "错误：恢复音量失败，将稍后重试")
            clear(); return outcome("restored", "媒体音量已恢复")
        } catch (error: RuntimeException) { return outcome("restoreFailed", "错误：恢复音量失败（${error.javaClass.simpleName}）") }
    }
}
