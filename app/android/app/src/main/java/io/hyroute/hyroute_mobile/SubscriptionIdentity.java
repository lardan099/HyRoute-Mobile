package io.hyroute.hyroute_mobile;

import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Build;

import java.util.UUID;

import mobile.Mobile;

final class SubscriptionIdentity {
    private static boolean configured;

    static synchronized void configure(Context context) {
        if (configured) return;
        SharedPreferences prefs = context.getSharedPreferences("hyroute-subscription", Context.MODE_PRIVATE);
        String seed = prefs.getString("device-seed", "");
        if (seed.isEmpty()) {
            seed = UUID.randomUUID().toString();
            if (!prefs.edit().putString("device-seed", seed).commit()) return;
        }
        String version;
        try {
            version = context.getPackageManager().getPackageInfo(context.getPackageName(), 0).versionName;
        } catch (PackageManager.NameNotFoundException ignored) {
            version = "";
        }
        Mobile.configureSubscriptionDevice(version == null ? "" : version, seed, "Android", Build.VERSION.RELEASE);
        configured = true;
    }

    private SubscriptionIdentity() {}
}
