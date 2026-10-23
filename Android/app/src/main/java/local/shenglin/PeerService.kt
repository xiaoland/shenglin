package local.shenglin

import android.app.*
import android.content.*
import android.content.pm.ServiceInfo
import local.shenglin.microphone.MicrophoneSharing
import android.media.AudioManager
import android.os.*
import java.io.FileDescriptor
import java.io.PrintWriter
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import local.shenglin.transport.PeerTransport

data class PeerUiState(val id: String, val name: String, val platform: String, val lanConnected: Boolean, val bleConnected: Boolean, val spaceEligible: Boolean = false, val microphoneShared: Boolean = false, val pending: Boolean = false)

data class ServiceUiState(
    val enabled: Boolean = false,
    val recording: Boolean? = null,
    val status: String = "开启后自动连接已配对设备",
    val volumeStatus: String = "媒体音量保持原状",
    val peers: List<PeerUiState> = emptyList(),
    val discovered: List<PeerUiState> = emptyList(),
    val pairingStatus: String = "idle",
    val pairingCode: String? = null,
    val microphoneEnabled: Boolean = false,
    val microphoneStatus: String = "共享已关闭",
    val microphoneCapturing: Boolean = false,
)

class PeerService : Service() {
    inner class LocalBinder : Binder() { fun service() = this@PeerService }
    private val handler = Handler(Looper.getMainLooper())
    private val binder = LocalBinder()
    private lateinit var observer: RecordingObserver
    private lateinit var volume: VolumeController
    private lateinit var preferences: SharedPreferences
    var transport: PeerTransport? = null
        private set
    private var recording: Boolean? = null
    private var status = "开启后自动连接已配对设备"
    private var volumeStatus = "媒体音量保持原状"
    private var demand = false
    private var inheritedManual = false
    private var enabled = false
    private var microphoneEnabled = false
    private var running = false
    private var foreground = false
    private var notificationText = ""
    private lateinit var microphone: MicrophoneSharing
    private var startupFailed = false
    private var reportedManual = false
    private val mutableState = MutableStateFlow(ServiceUiState())
    val state = mutableState.asStateFlow()
    @Volatile private var lastTickElapsed = 0L
    @Volatile private var tickCount = 0L
    @Volatile private var maxTickGapMs = 0L
    private val tick = object : Runnable {
        override fun run() {
            val now = SystemClock.elapsedRealtime()
            if (lastTickElapsed != 0L) maxTickGapMs = maxOf(maxTickGapMs, now - lastTickElapsed)
            lastTickElapsed = now; tickCount++
            observer.sample(); reconcile(); handler.postDelayed(this, 1000)
        }
    }
    override fun dump(fd: FileDescriptor, writer: PrintWriter, args: Array<out String>?) {
        // This read-only snapshot does not navigate the UI. Binder delivery may wake
        // the process: avoid repeated dumps during lock-screen tests. Never include
        // pairing codes, keys or user device names here.
        val snapshot = state.value
        writer.println("enabled=${snapshot.enabled} recording=${snapshot.recording} demand=$demand manual=$inheritedManual")
        writer.println("volumeResult=${if (::volume.isInitialized) volume.result() else "uninitialized"} volumeStatus=${snapshot.volumeStatus}")
        writer.println("tickCount=$tickCount maxTickGapMs=$maxTickGapMs tickAgeMs=${if (lastTickElapsed == 0L) -1 else SystemClock.elapsedRealtime() - lastTickElapsed}")
        writer.println("microphoneEnabled=${snapshot.microphoneEnabled} microphoneCapturing=${snapshot.microphoneCapturing} microphoneStatus=${snapshot.microphoneStatus}")
        writer.println("transport=${transport?.diagnostics() ?: "unavailable"}")
        snapshot.peers.forEachIndexed { index, peer ->
            writer.println("peer[$index] platform=${peer.platform} lan=${peer.lanConnected} ble=${peer.bleConnected} spaceEligible=${peer.spaceEligible} microphoneShared=${peer.microphoneShared}")
        }
    }
    override fun onCreate() {
        super.onCreate()
        preferences = getSharedPreferences("preferences", MODE_PRIVATE)
        val audio = getSystemService(AudioManager::class.java)
        volume = VolumeController(this, audio)
        volumeStatus = volume.recover()
        microphone = MicrophoneSharing(this) { observer.sample(); reconcile() }
        observer = RecordingObserver(audio, handler, { microphone.ownSession }) { value ->
            recording = value
            transport?.setLocalRecording(value)
            reconcile()
        }
        try {
            transport = PeerTransport(this, object : PeerTransport.Listener {
                override fun onDemand(quiet: Boolean, manualTakeover: Boolean): String {
                    demand = quiet; inheritedManual = manualTakeover; reconcile()
                    return if (enabled) volume.result() else "paused"
                }
                override fun onStatus(message: String) { status = message; publish() }
                override fun onPeersChanged() = publish()
            }, SecureStore(this))
            transport?.apply {
                if (volume.isManual()) takeOver()
                setDeviceName(preferences.getString("name", Build.MODEL)!!)
                setSpaceMode(preferences.getString("space", "nearbyOrWiFi")!!)
                setNetworkScope(preferences.getString("networkScope", "wifi")!!)
            }
        } catch (error: Exception) { startupFailed = true; status = "启动失败：${error.message}" }
        publish()
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "STOP" -> pause()
            "STOP_MICROPHONE" -> stopMicrophone()
            else -> {
                val startMicrophone = intent?.action == "START_MICROPHONE"
                try {
                    promote(microphoneEnabled || startMicrophone)
                    if (startupFailed) { stopForeground(STOP_FOREGROUND_REMOVE); foreground = false; stopSelf(); return START_NOT_STICKY }
                    if (startMicrophone) microphoneEnabled = true
                    else {
                        enabled = true; status = "正在连接已配对设备"
                        preferences.edit().putBoolean("enabled", true).apply()
                        transport?.setEnabled(true)
                    }
                    updateLifetime()
                } catch (error: RuntimeException) {
                    status = "无法开启服务：${error.message}"
                    if (!running) { stopForeground(STOP_FOREGROUND_REMOVE); foreground = false; stopSelf() }
                }
            }
        }
        publish()
        return START_NOT_STICKY
    }
    private fun notification(sharing: Boolean): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val builder = Notification.Builder(this, "peers").setSmallIcon(android.R.drawable.ic_lock_silent_mode_off)
            .setContentTitle(if (sharing) "声邻 · 麦克风共享" else "声邻 · 自动协同中")
            .setContentText(if (sharing) microphone.status else "与已配对设备协同音量").setContentIntent(open).setOngoing(true)
        if (enabled || !sharing) {
            val stop = PendingIntent.getService(this, 1, Intent(this, PeerService::class.java).setAction("STOP"), PendingIntent.FLAG_IMMUTABLE)
            builder.addAction(Notification.Action.Builder(null, "暂停协同", stop).build())
        }
        if (sharing) {
            val stop = PendingIntent.getService(this, 2, Intent(this, PeerService::class.java).setAction("STOP_MICROPHONE"), PendingIntent.FLAG_IMMUTABLE)
            builder.addAction(Notification.Action.Builder(null, "停止共享", stop).build())
        }
        return builder.build()
    }
    private fun promote(sharing: Boolean) {
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel("peers", "设备协同与麦克风共享", NotificationManager.IMPORTANCE_LOW))
        if (Build.VERSION.SDK_INT >= 29) {
            val types = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or
                if (sharing && Build.VERSION.SDK_INT >= 30) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0
            startForeground(1, notification(sharing), types)
        } else startForeground(1, notification(sharing))
        foreground = true
    }
    fun enabled() = enabled
    fun pause() {
        enabled = false
        if (!startupFailed) status = "自动协同已暂停"
        preferences.edit().putBoolean("enabled", false).apply()
        transport?.setEnabled(false)
        demand = false; updateLifetime(); reconcile()
    }
    fun stopMicrophone() {
        microphoneEnabled = false
        microphone.update(false, null, emptyList())
        if (enabled) promote(false)
        updateLifetime(); reconcile()
    }
    private fun updateLifetime() {
        val active = enabled || microphoneEnabled
        if (active && !running) {
            running = true; transport?.start(); observer.start(); handler.post(tick)
        } else if (!active) {
            running = false; handler.removeCallbacks(tick); observer.stop(); transport?.stop()
            stopForeground(STOP_FOREGROUND_REMOVE); foreground = false; notificationText = ""; stopSelf()
        }
    }
    private fun reconcile() {
        if (!::volume.isInitialized) return
        volumeStatus = volume.update(enabled && demand, if (microphone.capturing) true else recording, preferences.getInt("target", 20), inheritedManual)
        if (!volume.isManual()) reportedManual = false
        else if (!reportedManual && transport != null) { reportedManual = true; transport?.takeOver() }
        publish()
    }
    private fun publish() {
        if (::microphone.isInitialized) microphone.update(microphoneEnabled, transport?.microphoneAddress(), transport?.microphonePeers() ?: emptyList())
        val pairing = transport?.pairingSnapshot()
        mutableState.value = ServiceUiState(enabled, recording, status, volumeStatus,
            transport?.peers()?.map { it.uiState() } ?: emptyList(), transport?.discovered()?.map { it.uiState() } ?: emptyList(),
            pairing?.status ?: "idle", pairing?.code, microphoneEnabled, microphone.status, microphone.capturing)
        val text = "$enabled|$microphoneEnabled|${microphone.status}"
        if (foreground && text != notificationText) { notificationText = text; getSystemService(NotificationManager::class.java).notify(1, notification(microphoneEnabled)) }
    }
    fun restoreNow() { volumeStatus = volume.restoreNow(); transport?.takeOver(); publish() }
    fun setTarget(percent: Int) { preferences.edit().putInt("target", percent.coerceIn(0, 50)).apply(); reconcile() }
    fun setName(name: String) {
        preferences.edit().putString("name", name).apply(); transport?.setDeviceName(name); publish()
    }
    fun setSpace(mode: String) { preferences.edit().putString("space", mode).apply(); transport?.setSpaceMode(mode); publish() }
    fun setNetworkScope(scope: String) {
        require(scope == "wifi" || scope == "lan") { "未知网络条件" }
        preferences.edit().putString("networkScope", scope).apply(); transport?.setNetworkScope(scope); publish()
    }
    fun beginPairing() { requireTransport().beginPairing(); publish() }
    fun cancelPairing() { transport?.cancelPairing(); publish() }
    fun pair(id: String, code: String) { requireTransport().pair(id, code); publish() }
    fun setMicrophoneShared(id: String, shared: Boolean) { transport?.setMicrophoneShared(id, shared); publish() }
    fun forget(id: String) { transport?.forget(id); publish() }
    fun refreshBluetooth() { transport?.refreshBluetooth(); publish() }
    private fun requireTransport(): PeerTransport {
        check(enabled || microphoneEnabled) { "请先开启自动协同或麦克风共享" }
        return checkNotNull(transport) { "设备连接服务尚未就绪" }
    }
    override fun onBind(intent: Intent): IBinder = binder
    override fun onDestroy() { microphoneEnabled = false; pause(); microphone.close(); super.onDestroy() }
}

private fun PeerTransport.Peer.uiState() = PeerUiState(id, name, platform, lanConnected, bleConnected, spaceEligible, microphoneShared, pending)
