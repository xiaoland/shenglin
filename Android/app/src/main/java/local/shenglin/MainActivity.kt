package local.shenglin

import android.Manifest
import android.content.*
import android.content.pm.PackageManager
import android.os.*
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.outlined.List
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import local.shenglin.transport.PeerTransport

class MainActivity : ComponentActivity() {
    private var service by mutableStateOf<PeerService?>(null)
    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { }
    private val bluetoothPermissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { service?.refreshBluetooth() }
    private var permissionMessage by mutableStateOf<String?>(null)
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) { service = (binder as PeerService.LocalBinder).service() }
        override fun onServiceDisconnected(name: ComponentName) { service = null }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        bindService(Intent(this, PeerService::class.java), connection, BIND_AUTO_CREATE)
        if (getSharedPreferences("preferences", MODE_PRIVATE).getBoolean("enabled", false)) startForegroundService(Intent(this, PeerService::class.java))
        setContent {
            MaterialTheme(colorScheme = lightColorScheme(primary = Color(0xFF065E6E), secondary = Color(0xFF47676C), tertiary = Color(0xFF535F7D))) {
                val current = service
                val state = current?.state?.collectAsState()?.value ?: ServiceUiState()
                ShenglinApp(state, current, getSharedPreferences("preferences", MODE_PRIVATE), ::toggleEnabled, ::requestBluetooth)
                permissionMessage?.let { message ->
                    AlertDialog(onDismissRequest = { permissionMessage = null }, title = { Text("蓝牙协同") }, text = { Text(message) },
                        confirmButton = { TextButton(onClick = { permissionMessage = null }) { Text("知道了") } })
                }
            }
        }
    }
    private fun toggleEnabled(enabled: Boolean) {
        if (enabled) {
            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
                notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
            startForegroundService(Intent(this, PeerService::class.java))
        } else { service?.pause(); stopService(Intent(this, PeerService::class.java)) }
    }
    private fun requestBluetooth() {
        val permissions = if (Build.VERSION.SDK_INT >= 31) arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE)
        else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        val missing = permissions.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isNotEmpty()) bluetoothPermissions.launch(missing.toTypedArray())
        else {
            service?.refreshBluetooth()
            permissionMessage = "蓝牙权限已授予。请保持蓝牙开启；Android 11 及以下还需开启系统定位。"
        }
    }
    override fun onDestroy() { unbindService(connection); super.onDestroy() }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun ShenglinApp(state: ServiceUiState, service: PeerService?, prefs: SharedPreferences, toggle: (Boolean) -> Unit, bluetooth: () -> Unit) {
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    var page by rememberSaveable { mutableStateOf("home") }
    var detailId by rememberSaveable { mutableStateOf<String?>(null) }
    var pairId by rememberSaveable { mutableStateOf<String?>(null) }
    var code by rememberSaveable { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var forget by remember { mutableStateOf<PeerUiState?>(null) }
    fun act(action: () -> Unit) { try { action() } catch (failure: Exception) { error = failure.message ?: "暂时无法完成，请重试" } }
    fun back() {
        if (page == "add" && state.pairingStatus in listOf("waiting", "verifying")) service?.cancelPairing()
        page = if (page == "diagnostics") "settings" else "devices"; detailId = null
    }
    LaunchedEffect(page, pairId) { focus.clearFocus(); keyboard?.hide() }
    val nested = page in listOf("add", "detail", "diagnostics")
    BackHandler(nested) { back() }
    Scaffold(
        topBar = {
            TopAppBar(title = { Text(when (page) { "home" -> "声邻"; "devices" -> "设备"; "settings" -> "协同设置"; "add" -> "添加设备"; "detail" -> "设备详情"; else -> "运行详情" }) },
                navigationIcon = { if (nested) IconButton(onClick = { back() }) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "返回") } },
                actions = { if (page == "devices") IconButton(onClick = { page = "add" }) { Icon(Icons.Outlined.Add, "添加设备") } })
        },
        bottomBar = {
            if (!nested) NavigationBar {
                listOf(Triple("home", "首页", Icons.Outlined.Home), Triple("devices", "设备", Icons.AutoMirrored.Outlined.List), Triple("settings", "设置", Icons.Outlined.Settings)).forEach { (id, label, icon) ->
                    NavigationBarItem(selected = page == id, onClick = { page = id }, icon = { Icon(icon, null) }, label = { Text(label) })
                }
            }
        },
    ) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            when (page) {
                "home" -> {
                    item {
                        Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                                Column(Modifier.weight(1f)) { Text("自动协同", style = MaterialTheme.typography.titleLarge); Text(if (state.enabled) "已开启" else "已暂停", style = MaterialTheme.typography.bodyMedium) }
                                Switch(state.enabled, onCheckedChange = toggle, enabled = service != null, modifier = Modifier.semantics { contentDescription = "自动协同" })
                            }
                            Text(when { !state.enabled -> "开启后，与同一空间内的已配对设备协调音量。"; state.recording == true -> "本机正在录音"; state.recording == null -> "录音状态暂不可用，保护本机输出"; else -> "本机空闲" }, style = MaterialTheme.typography.titleMedium)
                            Text(state.volumeStatus)
                        } }
                    }
                    item {
                        val eligible = state.peers.count { it.spaceEligible }
                        ListItem(headlineContent = { Text(if (state.peers.isEmpty()) "添加你的第一台设备" else "${state.peers.size} 台已配对设备") },
                            supportingContent = { Text(if (state.peers.isEmpty()) "支持 Mac、iPad 与 Android" else "$eligible 台符合协同空间条件") },
                            trailingContent = { Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, null) }, modifier = Modifier.clickable { page = if (state.peers.isEmpty()) "add" else "devices" })
                    }
                    if (state.enabled && (state.status.contains("失败") || state.status.contains("权限") || state.status.contains("不可用"))) item {
                        OutlinedCard { Column(Modifier.padding(16.dp)) { Text(state.status); TextButton(onClick = { page = "diagnostics" }) { Text("查看详情") } } }
                    }
                    item { OutlinedButton(onClick = { service?.restoreNow() }, Modifier.fillMaxWidth(), enabled = service != null) { Icon(Icons.Outlined.Refresh, null); Spacer(Modifier.width(8.dp)); Text("立即恢复音量") } }
                    item { Text("声邻只观察系统录音状态，不采集或传输麦克风音频。", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                }
                "devices" -> {
                    if (state.peers.isEmpty()) item { Text("还没有配对设备", style = MaterialTheme.typography.titleLarge); Text("在另一台设备上打开声邻，然后添加设备。") }
                    items(state.peers, key = { it.id }) { peer ->
                        OutlinedCard(onClick = { detailId = peer.id; page = "detail" }, modifier = Modifier.fillMaxWidth()) {
                            ListItem(headlineContent = { Text(peer.name) }, supportingContent = { Text("${platform(peer.platform)} · ${if (peer.spaceEligible) "空间条件已满足" else "等待空间条件"}") }, trailingContent = { Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, null) })
                        }
                    }
                    item { Button(onClick = { page = "add" }, Modifier.fillMaxWidth()) { Icon(Icons.Outlined.Add, null); Spacer(Modifier.width(8.dp)); Text("添加设备") } }
                }
                "detail" -> {
                    val peer = state.peers.firstOrNull { it.id == detailId }
                    if (peer == null) item { Text("此设备已取消配对"); TextButton(onClick = { page = "devices" }) { Text("返回设备列表") } }
                    else {
                        item { Text(peer.name, style = MaterialTheme.typography.headlineSmall); Text(platform(peer.platform)) }
                        item { InfoCard("连接状态", connectionText(peer)); Text(if (peer.spaceEligible) "空间条件已满足，可参与自动协同。" else "尚未满足设置中的网络与蓝牙条件，暂不协同。", style = MaterialTheme.typography.bodyMedium) }
                        item { OutlinedButton(onClick = { forget = peer }, Modifier.fillMaxWidth()) { Text("取消配对", color = MaterialTheme.colorScheme.error) } }
                    }
                }
                "add" -> {
                    if (!state.enabled) item { InfoCard("先开启自动协同", "开启后才能查找与验证附近设备。"); Button(onClick = { toggle(true) }) { Text("开启自动协同") } }
                    item { Text("让另一台设备输入本机码", style = MaterialTheme.typography.titleMedium) }
                    item {
                        OutlinedCard(Modifier.fillMaxWidth()) { Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            if (state.pairingCode != null && state.pairingStatus == "waiting") {
                                Text(state.pairingCode, style = MaterialTheme.typography.displaySmall, fontFamily = FontFamily.Monospace)
                                Text("两分钟内有效。在另一台设备的声邻中选择「${prefs.getString("name", Build.MODEL)}」并输入此码。")
                                TextButton(onClick = { service?.cancelPairing() }) { Text("取消本机配对码") }
                            } else Button(onClick = { act { service?.beginPairing() } }, enabled = state.enabled) { Text("显示本机配对码") }
                            pairingMessage(state.pairingStatus)?.let { Text(it, color = if (state.pairingStatus == "failed") MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant) }
                        } }
                    }
                    item { Text("或输入另一台设备的码", style = MaterialTheme.typography.titleMedium); Text("先在 Mac、iPad 或 Android 的声邻中显示验证码，并连接同一局域网。") }
                    items(state.discovered, key = { it.id }) { peer ->
                        OutlinedCard(onClick = { pairId = peer.id; code = "" }, enabled = state.enabled, modifier = Modifier.fillMaxWidth()) {
                            ListItem(headlineContent = { Text(peer.name) }, supportingContent = { Text(platform(peer.platform)) }, trailingContent = { Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, null) })
                        }
                    }
                    if (state.discovered.isEmpty()) item { Text("尚未发现正在显示验证码的设备。", color = MaterialTheme.colorScheme.onSurfaceVariant) }
                }
                "settings" -> {
                    item { SettingsContent(prefs, service, bluetooth) }
                    item { ListItem(headlineContent = { Text("运行详情") }, supportingContent = { Text("连接、录音与最近一次音量操作") }, trailingContent = { Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, null) }, modifier = Modifier.clickable { page = "diagnostics" }) }
                }
                "diagnostics" -> {
                    item { InfoCard("设备连接", state.status) }
                    item { InfoCard("系统录音状态", when (state.recording) { true -> "正在录音"; false -> "本机空闲"; null -> "未知，保护本机输出" }) }
                    item { InfoCard("最近一次音量操作", state.volumeStatus) }
                    item { Text("Android 12 以下的蓝牙扫描需要系统定位开启。部分设备无法确认媒体输出路由时，声邻会保持音量并显示原因。", style = MaterialTheme.typography.bodySmall) }
                }
            }
        }
    }
    val selected = state.discovered.firstOrNull { it.id == pairId }
    if (pairId != null) AlertDialog(onDismissRequest = { pairId = null }, title = { Text("配对${selected?.name?.let { "「$it」" } ?: "设备"}") },
        text = { OutlinedTextField(code, onValueChange = { code = it.filter { digit -> digit in '0'..'9' }.take(6) }, label = { Text("对方的六位验证码") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword)) },
        confirmButton = { TextButton(enabled = code.length == 6 && selected != null, onClick = { val id = pairId!!; act { service?.pair(id, code) }; pairId = null }) { Text("验证并添加") } },
        dismissButton = { TextButton(onClick = { pairId = null }) { Text("取消") } })
    forget?.let { peer -> AlertDialog(onDismissRequest = { forget = null }, title = { Text("取消与「${peer.name}」的配对？") }, text = { Text("将停止与这台设备协同。再次连接需要重新验证配对码。") },
        confirmButton = { TextButton(onClick = { service?.forget(peer.id); forget = null; page = "devices" }) { Text("取消配对") } }, dismissButton = { TextButton(onClick = { forget = null }) { Text("保留") } }) }
    error?.let { message -> AlertDialog(onDismissRequest = { error = null }, title = { Text("暂时无法完成") }, text = { Text(message) }, confirmButton = { TextButton(onClick = { error = null }) { Text("知道了") } }) }
}

@Composable private fun SettingsContent(prefs: SharedPreferences, service: PeerService?, bluetooth: () -> Unit) {
    var target by remember { mutableFloatStateOf(prefs.getInt("target", 20).toFloat()) }
    var scope by remember { mutableStateOf(prefs.getString("networkScope", "wifi")!!) }
    var space by remember { mutableStateOf(prefs.getString("space", "nearbyOrWiFi")!!) }
    var name by rememberSaveable { mutableStateOf(prefs.getString("name", Build.MODEL)!!) }
    var savedName by remember { mutableStateOf(name) }
    val validName = name.trim().let { it.isNotEmpty() && it.codePointCount(0, it.length) <= 40 }
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("其他设备录音时", style = MaterialTheme.typography.titleMedium)
        Text("媒体音量上限 · ${target.toInt()}%")
        Slider(target, onValueChange = { target = it }, onValueChangeFinished = { service?.setTarget(target.toInt()) }, valueRange = 0f..50f, steps = 49,
            modifier = Modifier.semantics { contentDescription = "媒体音量上限 ${target.toInt()}%" })
        Text("只降低，不提高本机音量。手动调音或切换输出设备后，本轮协同让权。", style = MaterialTheme.typography.bodySmall)
        HorizontalDivider()
        Text("空间条件", style = MaterialTheme.typography.titleMedium)
        Text("网络范围", style = MaterialTheme.typography.labelLarge)
        Choice("同一 Wi-Fi", scope == "wifi") { scope = "wifi"; service?.setNetworkScope(scope) }
        Choice("同一局域网", scope == "lan", "允许 Wi-Fi 或网线连接") { scope = "lan"; service?.setNetworkScope(scope) }
        Text("与蓝牙条件组合", style = MaterialTheme.typography.labelLarge)
        Choice("蓝牙或网络满足其一", space == "nearbyOrWiFi") { space = "nearbyOrWiFi"; service?.setSpace(space) }
        Choice("蓝牙和网络同时满足", space == "nearbyAndWiFi") { space = "nearbyAndWiFi"; service?.setSpace(space) }
        Text("网络条件由双方安全通信确认，不保证物理同室。", style = MaterialTheme.typography.bodySmall)
        OutlinedButton(onClick = bluetooth, Modifier.fillMaxWidth()) { Text("检查蓝牙权限") }
        HorizontalDivider()
        OutlinedTextField(name, onValueChange = { name = it }, label = { Text("本机名称") }, singleLine = true,
            supportingText = { Text(if (validName) "其他设备将看到此名称" else "请输入 1–40 个字符") }, isError = !validName, modifier = Modifier.fillMaxWidth())
        Button(onClick = { service?.setName(name.trim()); savedName = name }, enabled = validName && name != savedName && service != null) { Text("保存名称") }
    }
}
@Composable private fun Choice(label: String, selected: Boolean, description: String? = null, action: () -> Unit) {
    Row(Modifier.fillMaxWidth().selectable(selected, onClick = action, role = Role.RadioButton).padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        RadioButton(selected, null); Spacer(Modifier.width(12.dp)); Column { Text(label); description?.let { Text(it, style = MaterialTheme.typography.bodySmall) } }
    }
}
@Composable private fun InfoCard(title: String, body: String) {
    OutlinedCard(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) { Text(title, style = MaterialTheme.typography.titleMedium); Text(body) } }
}
private fun platform(value: String) = when (value) { "mac" -> "Mac"; "ipad" -> "iPad"; "android" -> "Android"; else -> "声邻设备" }
private fun connectionText(peer: PeerUiState) = when { peer.lanConnected && peer.bleConnected -> "局域网、蓝牙均已认证"; peer.lanConnected -> "局域网已认证"; peer.bleConnected -> "蓝牙已认证"; else -> "等待连接或激活" }
private fun pairingMessage(status: String): String? = when (status) {
    "verifying" -> "正在验证配对码…"; "verified" -> "验证码已通过，正在完成安全连接…"; "activated" -> "配对成功，设备已完成双向认证"
    "cancelled" -> "配对已取消"; "expired" -> "配对码已过期，请重新生成"; "failed" -> "配对未完成，请核对对方当前验证码后重试"; else -> null
}
