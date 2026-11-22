package io.hyroute.hyroute_mobile;

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
            switch (call.method) {
                case "importSubscription":
                    String input = call.argument("input");
                    boolean fromUrl = Boolean.TRUE.equals(call.argument("fromUrl"));
                    result.success(Mobile.previewSubscription(input, fromUrl));
                    break;
                case "validateRouting":
                    Mobile.newAndroidRouter(call.argument("configuration"), call.argument("selectedServer"));
                    result.success(null);
                    break;
                default:
                    result.notImplemented();
            }
        } catch (Exception e) {
            result.error("core", null, null);
        }
    }
}
