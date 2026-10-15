package local.shenglin

import android.app.*
import android.content.*
import android.media.AudioManager
import android.os.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import local.shenglin.transport.PeerTransport

data class PeerUiState(val id: String, val name: String, val platform: String, val lanConnected: Boolean, val bleConnected: Boolean, val spaceEligible: Boolean = false)

data class ServiceUiState(
    val enabled: Boolean = false,
    val recording: Boolean? = null,
    val status: String = "开启后自动连接已配对设备",
    val volumeStatus: String = "媒体音量保持原状",
    val peers: List<PeerUiState> = emptyList(),
    val discovered: List<PeerUiState> = emptyList(),
    val pairingStatus: String = "idle",
    val pairingCode: String? = null,
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
    private var startupFailed = false
    private var reportedManual = false
    private val mutableState = MutableStateFlow(ServiceUiState())
    val state = mutableState.asStateFlow()
    private val tick = object : Runnable {
        override fun run() { observer.sample(); reconcile(); handler.postDelayed(this, 1000) }
    }
    override fun onCreate() {
        super.onCreate()
        preferences = getSharedPreferences("preferences", MODE_PRIVATE)
        val audio = getSystemService(AudioManager::class.java)
        volume = VolumeController(this, audio)
        volumeStatus = volume.recover()
        observer = RecordingObserver(audio, handler) { value ->
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
        if (intent?.action == "STOP") { pause(); stopSelf(); return START_NOT_STICKY }
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel("peers", "设备音量协同", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, PeerService::class.java).setAction("STOP"), PendingIntent.FLAG_IMMUTABLE)
        startForeground(1, Notification.Builder(this, "peers").setSmallIcon(android.R.drawable.ic_lock_silent_mode_off)
            .setContentTitle("声邻 · 自动协同中").setContentText("观察录音状态，与已配对设备协同音量")
            .setContentIntent(open).setOngoing(true)
            .addAction(Notification.Action.Builder(null, "暂停协同", stop).build()).build())
        if (startupFailed) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(); return START_NOT_STICKY }
        if (!enabled) {
            enabled = true; status = "正在连接已配对设备"
            preferences.edit().putBoolean("enabled", true).apply()
            transport?.apply { setEnabled(true); start() }
            observer.start(); handler.post(tick)
        }
        publish()
        return START_NOT_STICKY
    }
    fun enabled() = enabled
    fun pause() {
        enabled = false
        if (!startupFailed) status = "自动协同已暂停"
        preferences.edit().putBoolean("enabled", false).apply()
        handler.removeCallbacks(tick); observer.stop()
        transport?.apply { setEnabled(false); stop() }
        demand = false; reconcile(); stopForeground(STOP_FOREGROUND_REMOVE)
    }
    private fun reconcile() {
        if (!::volume.isInitialized) return
        volumeStatus = volume.update(enabled && demand, recording, preferences.getInt("target", 20), inheritedManual)
        if (!volume.isManual()) reportedManual = false
        else if (!reportedManual && transport != null) { reportedManual = true; transport?.takeOver() }
        publish()
    }
    private fun publish() {
        val pairing = transport?.pairingSnapshot()
        mutableState.value = ServiceUiState(enabled, recording, status, volumeStatus,
            transport?.peers()?.map { it.uiState() } ?: emptyList(), transport?.discovered()?.map { it.uiState() } ?: emptyList(),
            pairing?.status ?: "idle", pairing?.code)
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
    fun forget(id: String) { transport?.forget(id); publish() }
    fun refreshBluetooth() { transport?.refreshBluetooth(); publish() }
    private fun requireTransport(): PeerTransport {
        check(enabled) { "请先开启自动协同" }
        return checkNotNull(transport) { "设备连接服务尚未就绪" }
    }
    override fun onBind(intent: Intent): IBinder = binder
    override fun onDestroy() { pause(); super.onDestroy() }
}

private fun PeerTransport.Peer.uiState() = PeerUiState(id, name, platform, lanConnected, bleConnected, spaceEligible)
