package io.hyroute.hyroute_mobile;

import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.net.Uri;
import android.net.VpnService;
import android.os.Build;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.security.GeneralSecurityException;
import java.util.LinkedHashMap;
import java.util.Map;
import org.json.JSONObject;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.StandardMethodCodec;
import mobile.Mobile;
import mobile.ProbeBatch;

public class MainActivity extends FlutterActivity {
    private static final int VPN_PERMISSION = 600;
    private static final int GEO_FILE = 601;
    private MethodChannel coreChannel;
    private ProbeBatch probeBatch;
    private MethodChannel.Result geoImportResult;
    private String geoImportKind;

    private String journalPath() {
        return HyRouteVpnService.journalPath(getNoBackupFilesDir());
    }

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
                    MaintenanceJob.schedule(this);
                    result.success(Mobile.clientStateView(store.read()));
                    break;
                case "importSubscription":
                case "refreshSubscription": {
                    synchronized (ClientStore.LOCK) {
                        String state = store.read();
                        String updated = call.method.equals("refreshSubscription")
                                ? Mobile.attemptClientSubscriptionRefresh(state, call.argument("id"))
                                : Mobile.addClientSubscription(state, call.argument("input"),
                                    Boolean.TRUE.equals(call.argument("fromUrl")));
                        String view = Mobile.clientStateView(updated);
                        store.write(updated);
                        result.success(view);
                    }
                    break;
                }
                case "saveSettings":
                    synchronized (ClientStore.LOCK) {
                        String current = store.read();
                        String updated;
                        try {
                            updated = Mobile.saveClientSettings(current, call.argument("settings"), true);
                        } catch (Exception failure) {
                            result.error("settings", failure.getMessage(), null);
                            break;
                        }
                        store.write(updated);
                    }
                    result.success(null);
                    break;
                case "changeRoutingProfile":
                    synchronized (ClientStore.LOCK) {
                        String previous = store.read();
                        try {
                            String updated = Mobile.changeRoutingProfile(previous, call.argument("operation"),
                                    call.argument("id"), call.argument("name"));
                            String view = Mobile.clientStateView(updated);
                            if (!previous.equals(updated)) store.write(updated);
                            result.success(view);
                        } catch (IOException | GeneralSecurityException failure) {
                            throw failure;
                        } catch (Exception failure) {
                            result.error("routing-profile", failure.getMessage(), null);
                        }
                    }
                    break;
                case "checkRoute": {
                    String state = store.read();
                    try {
                        result.success(Mobile.checkClientRoute(state, call.argument("address"),
                                call.argument("ip"), call.argument("protocol"),
                                call.argument("package"), true));
                    } catch (Exception failure) {
                        result.error("route", failure.getMessage(), null);
                    }
                    break;
                }
                case "changeServerGroup":
                    synchronized (ClientStore.LOCK) {
                        try {
                            String updated = Mobile.changeServerGroup(store.read(), call.argument("id"), call.argument("definition"));
                            String view = Mobile.clientStateView(updated);
                            store.write(updated);
                            result.success(view);
                        } catch (IOException | GeneralSecurityException failure) {
                            throw failure;
                        } catch (Exception failure) {
                            result.error("server-group", failure.getMessage(), null);
                        }
                    }
                    break;
                case "geoTags":
                    result.success(Mobile.geoTags());
                    break;
                case "updateGeo":
                    Mobile.updateGeoForState(store.read());
                    result.success(null);
                    break;
                case "geoSources": {
                    JSONObject sources = new JSONObject(Mobile.geoSettings());
                    Map<String, String> view = new LinkedHashMap<>();
                    view.put("site", sources.getString("site"));
                    view.put("ip", sources.getString("ip"));
                    result.success(view);
                    break;
                }
                case "setGeoSource":
                    Mobile.setGeoSource(call.argument("kind"), call.argument("address"));
                    result.success(null);
                    break;
                case "importGeoFile":
                    runOnUiThread(() -> requestGeoFile(call.argument("kind"), result));
                    break;
                case "refreshDue":
                    MaintenanceJob.executor.execute(() -> {
                        try {
                            result.success(Mobile.clientStateView(MaintenanceJob.refreshSubscriptions(this)));
                        } catch (Exception error) {
                            result.error("refresh", null, null);
                        }
                        MaintenanceJob.refreshGeo(this);
                    });
                    break;
                case "launchableApps":
                    result.success(launchableApps());
                    break;
                case "vpnStatus":
                    result.success(HyRouteVpnService.status());
                    break;
                case "openVpnSettings":
                    runOnUiThread(() -> {
                        try {
                            startActivity(new Intent(android.provider.Settings.ACTION_VPN_SETTINGS));
                            result.success(null);
                        } catch (android.content.ActivityNotFoundException e) {
                            result.error("vpn-settings", null, null);
                        }
                    });
                    break;
                case "vpnJournal":
                    result.success(Mobile.vpnJournalEvents(journalPath(), ""));
                    break;
                case "probeStart":
                    if (probeBatch != null) probeBatch.cancel();
                    probeBatch = Mobile.startProbe(store.read(), call.argument("scope"), call.argument("id"), journalPath());
                    result.success(probeBatch.snapshot());
                    break;
                case "probeStatus":
                    result.success(probeBatch == null ? null : probeBatch.snapshot());
                    break;
                case "probeCancel":
                    if (probeBatch != null) {
                        probeBatch.cancel();
                        probeBatch = null;
                    }
                    result.success(null);
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
        Mobile.recordVPNEvent(journalPath(), "vpn_request");
        try {
            Intent permission = VpnService.prepare(this);
            if (permission == null) {
                launchVpn();
            } else {
                Mobile.recordVPNEvent(journalPath(), "vpn_permission");
                startActivityForResult(permission, VPN_PERMISSION);
            }
        } catch (RuntimeException e) {
            Mobile.recordVPNEvent(journalPath(), "vpn_system_error");
            HyRouteVpnService.failed();
        }
    }

    private void launchVpn() {
        if (!HyRouteVpnService.starting()) return;
        Intent service = new Intent(this, HyRouteVpnService.class).setAction(HyRouteVpnService.START);
        try {
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(service);
            else startService(service);
        } catch (RuntimeException e) {
            Mobile.recordVPNEvent(journalPath(), "vpn_service_error");
            HyRouteVpnService.failed();
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == GEO_FILE) {
            finishGeoImport(resultCode == RESULT_OK && data != null ? data.getData() : null);
            return;
        }
        if (requestCode != VPN_PERMISSION) return;
        if (resultCode == RESULT_OK) launchVpn();
        else {
            Mobile.recordVPNEvent(journalPath(), "vpn_denied");
            HyRouteVpnService.permissionDenied();
        }
    }

    private void requestGeoFile(String kind, MethodChannel.Result result) {
        if (geoImportResult != null) {
            result.error("busy", null, null);
            return;
        }
        geoImportKind = kind;
        geoImportResult = result;
        try {
            Intent openFile = new Intent(Intent.ACTION_OPEN_DOCUMENT)
                    .addCategory(Intent.CATEGORY_OPENABLE).setType("*/*");
            startActivityForResult(openFile, GEO_FILE);
        } catch (RuntimeException error) {
            geoImportResult = null;
            result.error("file", null, null);
        }
    }

    private void finishGeoImport(Uri uri) {
        MethodChannel.Result result = geoImportResult;
        String kind = geoImportKind;
        geoImportResult = null;
        geoImportKind = null;
        if (result == null) return;
        if (uri == null) {
            result.success(false);
            return;
        }
        MaintenanceJob.executor.execute(() -> {
            File temp = null;
            try {
                temp = File.createTempFile("hyroute-geo-", ".dat", getCacheDir());
                try (InputStream input = getContentResolver().openInputStream(uri);
                     FileOutputStream output = new FileOutputStream(temp)) {
                    if (input == null) throw new IOException("Missing document");
                    byte[] buffer = new byte[64 * 1024];
                    long size = 0;
                    int count;
                    while ((count = input.read(buffer)) != -1) {
                        size += count;
                        if (size > 300L * 1024 * 1024) throw new IOException("Database is too large");
                        output.write(buffer, 0, count);
                    }
                }
                Mobile.importGeoFileForState(kind, temp.getPath(), new ClientStore(getNoBackupFilesDir()).read());
                result.success(true);
            } catch (Exception error) {
                result.error("file", null, null);
            } finally {
                if (temp != null) temp.delete();
            }
        });
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
