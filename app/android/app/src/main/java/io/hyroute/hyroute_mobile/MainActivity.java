package io.hyroute.hyroute_mobile;

import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.net.VpnService;
import android.os.Build;
import java.io.File;
import java.io.IOException;
import java.security.GeneralSecurityException;
import java.util.LinkedHashMap;
import java.util.Map;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.StandardMethodCodec;
import mobile.Mobile;

public class MainActivity extends FlutterActivity {
    private static final int VPN_PERMISSION = 600;
    private MethodChannel coreChannel;

    @Override
    public void configureFlutterEngine(FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        BinaryMessenger messenger = flutterEngine.getDartExecutor().getBinaryMessenger();
        coreChannel = new MethodChannel(
                messenger, "io.hyroute/core", StandardMethodCodec.INSTANCE,
                messenger.makeBackgroundTaskQueue());
        coreChannel.setMethodCallHandler(this::handleCoreCall);
    }

    @Override
    public void cleanUpFlutterEngine(FlutterEngine flutterEngine) {
        if (coreChannel != null) {
            coreChannel.setMethodCallHandler(null);
            coreChannel = null;
        }
        super.cleanUpFlutterEngine(flutterEngine);
    }

    private void handleCoreCall(MethodCall call, MethodChannel.Result result) {
        try {
            ClientStore store = new ClientStore(getNoBackupFilesDir());
            switch (call.method) {
                case "loadState":
                    Mobile.configureGeo(new File(getNoBackupFilesDir(), "geo").getPath());
                    result.success(Mobile.clientStateView(store.read()));
                    break;
                case "importSubscription":
                case "refreshSubscription": {
                    String state = store.read();
                    String updated = call.method.equals("refreshSubscription")
                            ? Mobile.refreshClientSubscription(state, call.argument("id"))
                            : Mobile.addClientSubscription(state, call.argument("input"),
                                Boolean.TRUE.equals(call.argument("fromUrl")));
                    String view = Mobile.clientStateView(updated);
                    store.write(updated);
                    result.success(view);
                    break;
                }
                case "saveSettings":
                    store.write(Mobile.saveClientSettings(store.read(), call.argument("settings"), true));
                    result.success(null);
                    break;
                case "geoTags":
                    result.success(Mobile.geoTags());
                    break;
                case "updateGeo":
                    Mobile.updateGeo();
                    result.success(null);
                    break;
                case "launchableApps":
                    result.success(launchableApps());
                    break;
                case "vpnStatus":
                    result.success(HyRouteVpnService.status());
                    break;
                case "startVpn":
                    runOnUiThread(() -> {
                        requestVpn();
                        result.success(null);
                    });
                    break;
                case "stopVpn":
                    runOnUiThread(() -> {
                        String status = HyRouteVpnService.status();
                        if (status.equals("on") || status.equals("starting")) {
                            startService(new Intent(this, HyRouteVpnService.class).setAction(HyRouteVpnService.STOP));
                        }
                        result.success(null);
                    });
                    break;
                default:
                    result.notImplemented();
            }
        } catch (IOException | GeneralSecurityException e) {
            result.error("storage", null, null);
        } catch (Exception e) {
            result.error("core", null, null);
        }
    }

    private void requestVpn() {
        if (!HyRouteVpnService.request()) return;
        try {
            Intent permission = VpnService.prepare(this);
            if (permission == null) {
                launchVpn();
            } else {
                startActivityForResult(permission, VPN_PERMISSION);
            }
        } catch (RuntimeException e) {
            HyRouteVpnService.failed();
        }
    }

    private void launchVpn() {
        if (!HyRouteVpnService.starting()) return;
        Intent service = new Intent(this, HyRouteVpnService.class);
        try {
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(service);
            else startService(service);
        } catch (RuntimeException e) {
            HyRouteVpnService.failed();
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != VPN_PERMISSION) return;
        if (resultCode == RESULT_OK) launchVpn();
        else HyRouteVpnService.permissionDenied();
    }

    private Map<String, String> launchableApps() {
        PackageManager packages = getPackageManager();
        Intent launcher = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
        Map<String, String> apps = new LinkedHashMap<>();
        for (ResolveInfo activity : packages.queryIntentActivities(launcher, 0)) {
            String id = activity.activityInfo.packageName;
            if (!getPackageName().equals(id)) {
                apps.putIfAbsent(id, activity.loadLabel(packages).toString());
            }
        }
        return apps;
    }
}
