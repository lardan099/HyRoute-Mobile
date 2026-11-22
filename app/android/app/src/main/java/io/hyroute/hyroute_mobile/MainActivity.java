package io.hyroute.hyroute_mobile;

import java.io.File;
import java.io.IOException;
import java.security.GeneralSecurityException;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.StandardMethodCodec;
import mobile.Mobile;

public class MainActivity extends FlutterActivity {
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
                case "importSubscription": {
                    String input = call.argument("input");
                    boolean fromUrl = Boolean.TRUE.equals(call.argument("fromUrl"));
                    String updated = Mobile.addClientSubscription(store.read(), input, fromUrl);
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
                default:
                    result.notImplemented();
            }
        } catch (IOException | GeneralSecurityException e) {
            result.error("storage", null, null);
        } catch (Exception e) {
            result.error("core", null, null);
        }
    }
}
