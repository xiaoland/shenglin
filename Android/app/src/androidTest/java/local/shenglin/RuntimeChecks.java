package local.shenglin;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.Intent;
import android.media.AudioManager;
import android.os.Bundle;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import local.shenglin.core.Pairing;

/** Runs on an installed APK, including the real Rust UniFFI library and Android Keystore. */
public final class RuntimeChecks extends Instrumentation {
    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }
    @Override public void onStart() {
        Bundle result = new Bundle();
        try {
            Context context = getTargetContext();
            Context isolated = new ContextWrapper(context) {
                @Override public File getNoBackupFilesDir() {
                    File directory = new File(super.getNoBackupFilesDir(), "runtime-check");
                    if (!directory.isDirectory() && !directory.mkdirs()) throw new IllegalStateException("test directory");
                    return directory;
                }
            };
            SecureStore store = new SecureStore(isolated);
            byte[] data = "测试配对密钥记录".getBytes(StandardCharsets.UTF_8);
            store.write(data);
            require(Arrays.equals(data, new SecureStore(isolated).read()), "Keystore round trip");
            File primary = new File(isolated.getNoBackupFilesDir(), "peers.enc");
            File backup = new File(primary.getPath() + ".bak");
            require(primary.renameTo(backup), "simulate interrupted legacy AtomicFile write");
            require(Arrays.equals(data, new SecureStore(isolated).read()), "AtomicFile backup recovery");
            try (Pairing.Initiator initiator = new Pairing.Initiator("123456", "安卓甲", 100);
                 Pairing.Responder responder = new Pairing.Responder(initiator.startFrame(), "123456", "安卓乙", 100)) {
                Pairing.Frame confirm = initiator.receiveOffer(responder.offerFrame(), 101);
                Pairing.Frame finish = responder.receiveConfirm(confirm, 102);
                require(Arrays.equals(initiator.receiveFinish(finish, 103), responder.confirmedKey()), "native SPAKE2 round trip");
            }
            android.bluetooth.BluetoothAdapter adapter = context.getSystemService(android.bluetooth.BluetoothManager.class).getAdapter();
            String bluetooth = "无蓝牙适配器";
            if (adapter != null && (android.os.Build.VERSION.SDK_INT < 31 || context.checkSelfPermission(android.Manifest.permission.BLUETOOTH_CONNECT) == android.content.pm.PackageManager.PERMISSION_GRANTED))
                bluetooth = "蓝牙开启=" + adapter.isEnabled() + ", 多广告支持=" + adapter.isMultipleAdvertisementSupported() + ", BLE外设广告器=" + (adapter.getBluetoothLeAdvertiser() != null);
            result.putString("bluetooth", bluetooth);
            AudioManager audio = context.getSystemService(AudioManager.class);
            require(audio.getActiveRecordingConfigurations() != null, "anonymous recording query");
            int originalVolume = audio.getStreamVolume(AudioManager.STREAM_MUSIC);
            VolumeController volume = new VolumeController(context, audio);
            try {
                volume.update(true, false, 0);
                require(audio.getStreamVolume(AudioManager.STREAM_MUSIC) == 0, "actual media volume reduction: " + volume.result());
            } finally { volume.update(false, false, 0); }
            require(audio.getStreamVolume(AudioManager.STREAM_MUSIC) == originalVolume, "actual media volume recovery");
            Activity activity = startActivitySync(new Intent(context, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            runOnMainSync(() -> context.startForegroundService(new Intent(context, PeerService.class)));
            waitForIdleSync();
            require(activity != null && !activity.isFinishing(), "activity launch");
            boolean foreground = false;
            for (int attempt = 0; attempt < 20 && !foreground; attempt++) {
                for (android.app.ActivityManager.RunningServiceInfo info : context.getSystemService(android.app.ActivityManager.class).getRunningServices(50))
                    if (info.service.getClassName().equals(PeerService.class.getName()) && info.foreground) foreground = true;
                if (!foreground) android.os.SystemClock.sleep(100);
            }
            require(foreground, "connectedDevice foreground service running");
            android.content.SharedPreferences preferences = context.getSharedPreferences("preferences", Context.MODE_PRIVATE);
            String originalScope = preferences.getString("networkScope", null);
            clickText("设置");
            if (!"lan".equals(preferences.getString("networkScope", null))) clickText("同一局域网");
            require("lan".equals(preferences.getString("networkScope", null)), "LAN choice saved from Compose UI");
            clickText("同一 Wi-Fi");
            require("wifi".equals(preferences.getString("networkScope", null)), "Wi-Fi choice saved independently");
            if ("lan".equals(originalScope)) clickText("同一局域网");
            if (originalScope == null) preferences.edit().remove("networkScope").commit();
            clickText("首页");
            result.putString("stream", bluetooth + "\nKeystore、Rust SPAKE2、匿名录音查询、真实媒体降音量/恢复、Activity/前台服务、Compose 导航与网络条件保存通过\n");
            finish(Activity.RESULT_OK, result);
        } catch (Throwable error) {
            result.putString("stream", android.util.Log.getStackTraceString(error));
            finish(Activity.RESULT_CANCELED, result);
        }
    }
    private void clickText(String label) {
        for (int attempt = 0; attempt < 25; attempt++) {
            android.view.accessibility.AccessibilityNodeInfo root = getUiAutomation().getRootInActiveWindow();
            if (root != null) {
                for (android.view.accessibility.AccessibilityNodeInfo node : findNodes(root, label)) {
                    android.view.accessibility.AccessibilityNodeInfo target = node;
                    while (target != null && !target.isClickable()) target = target.getParent();
                    if (target != null && target.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK)) {
                        android.os.SystemClock.sleep(300); waitForIdleSync(); return;
                    }
                }
            }
            android.os.SystemClock.sleep(100);
        }
        throw new AssertionError("Compose action not found: " + label + " tree=" + describe(getUiAutomation().getRootInActiveWindow()));
    }
    private String describe(android.view.accessibility.AccessibilityNodeInfo node) {
        if (node == null) return "null";
        StringBuilder text = new StringBuilder("[" + node.getText() + "," + node.getContentDescription() + ",click=" + node.isClickable() + "]");
        for (int i = 0; i < node.getChildCount(); i++) text.append(describe(node.getChild(i)));
        return text.toString();
    }
    private java.util.List<android.view.accessibility.AccessibilityNodeInfo> findNodes(android.view.accessibility.AccessibilityNodeInfo node, String label) {
        java.util.List<android.view.accessibility.AccessibilityNodeInfo> result = new java.util.ArrayList<>();
        if (node.getText() != null && node.getText().toString().contains(label)) result.add(node);
        for (int index = 0; index < node.getChildCount(); index++) {
            android.view.accessibility.AccessibilityNodeInfo child = node.getChild(index);
            if (child != null) result.addAll(findNodes(child, label));
        }
        return result;
    }
    private static void require(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
