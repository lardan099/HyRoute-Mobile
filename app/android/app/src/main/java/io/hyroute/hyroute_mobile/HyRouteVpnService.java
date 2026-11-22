package io.hyroute.hyroute_mobile;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.VpnService;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.system.OsConstants;

import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicReference;

import mobile.Mobile;
import mobile.VPNPlan;
import mobile.VPNPlatform;
import mobile.VPNPrepared;
import mobile.VPNSession;

public final class HyRouteVpnService extends VpnService {
    private static final String CHANNEL = "hyroute-vpn";
    static final String STOP = "io.hyroute.vpn.STOP";
    private static final int NOTIFICATION = 601;
    private static final AtomicReference<String> STATUS = new AtomicReference<>("off");

    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private volatile boolean closed;
    private boolean started;
    private VPNSession engine;
    private ParcelFileDescriptor tunnel;

    static String status() { return STATUS.get(); }

    static boolean request() {
        String old = STATUS.get();
        return (old.equals("off") || old.equals("error")) && STATUS.compareAndSet(old, "permission");
    }

    static boolean starting() { return STATUS.compareAndSet("permission", "starting"); }
    static void permissionDenied() { STATUS.compareAndSet("permission", "off"); }
    static void failed() { STATUS.set("error"); }

    private static void stopping() {
        STATUS.getAndUpdate(value -> value.equals("on") || value.equals("starting") ? "stopping" : value);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null || STOP.equals(intent.getAction())) {
            requestStop();
            return START_NOT_STICKY;
        }
        if (started) return START_NOT_STICKY;
        started = true;
        try {
            startForeground(NOTIFICATION, notification("Подключение VPN"));
            worker.execute(this::startTunnel);
        } catch (RuntimeException e) {
            failed();
            stopSelf();
        }
        return START_NOT_STICKY;
    }

    private void startTunnel() {
        try {
            ClientStore store = new ClientStore(getNoBackupFilesDir());
            Mobile.configureGeo(new java.io.File(getNoBackupFilesDir(), "geo").getPath());
            VPNPlan plan = Mobile.newVPNPlan(store.read(), true);
            VPNPrepared prepared = plan.prepare();
            if (closed) return;

            Builder builder = new Builder().setSession("HyRoute").setMtu(1400)
                    .addAddress("198.18.0.1", 30).addRoute("0.0.0.0", 0)
                    .addAddress("fd72:cc0d:fe::1", 64).addRoute("::", 0)
                    .addDnsServer(plan.dnsServer());
            applyScope(builder, plan);
            SocketHooks hooks = new SocketHooks(plan.rulePackages());
            tunnel = builder.establish();
            if (tunnel == null) throw new IOException("No VPN interface");
            engine = prepared.start(tunnel.getFd(), hooks);
            if (!closed && STATUS.compareAndSet("starting", "on")) {
                getSystemService(NotificationManager.class).notify(NOTIFICATION, notification("VPN включён"));
            }
        } catch (Exception e) {
            closeTunnel();
            if (!closed && STATUS.compareAndSet("starting", "error")) stopSelf();
        }
    }

    private static void applyScope(Builder builder, VPNPlan plan) throws PackageManager.NameNotFoundException {
        String scope = plan.appScope();
        if (scope.equals("all")) return;
        for (String id : plan.appPackages().split("\n")) {
            if (scope.equals("only")) builder.addAllowedApplication(id);
            else builder.addDisallowedApplication(id);
        }
    }

    private Notification notification(String title) {
        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager manager = getSystemService(NotificationManager.class);
            manager.createNotificationChannel(new NotificationChannel(CHANNEL, "VPN", NotificationManager.IMPORTANCE_LOW));
            builder = new Notification.Builder(this, CHANNEL);
        } else {
            builder = new Notification.Builder(this);
        }
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), PendingIntent.FLAG_IMMUTABLE);
        PendingIntent stop = PendingIntent.getService(this, 1,
                new Intent(this, HyRouteVpnService.class).setAction(STOP), PendingIntent.FLAG_IMMUTABLE);
        return builder.setSmallIcon(android.R.drawable.ic_lock_lock).setContentTitle(title)
                .setContentIntent(open).setOngoing(true)
                .addAction(new Notification.Action.Builder(null, "Отключить", stop).build()).build();
    }

    @Override public void onRevoke() {
        new Handler(Looper.getMainLooper()).post(this::requestStop);
    }

    private void requestStop() {
        if (closed) return;
        closed = true;
        stopping();
        // Android keeps this service bound until the TUN descriptor closes.
        worker.execute(() -> {
            closeTunnel();
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelf();
        });
    }

    @Override public void onDestroy() {
        closed = true;
        worker.execute(() -> {
            closeTunnel();
            STATUS.getAndUpdate(value -> value.equals("error") ? value : "off");
        });
        worker.shutdown();
        super.onDestroy();
    }

    private void closeTunnel() {
        if (engine != null) {
            engine.stop();
            engine = null;
        }
        if (tunnel != null) {
            try { tunnel.close(); } catch (IOException ignored) { }
            tunnel = null;
        }
    }

    private final class SocketHooks implements VPNPlatform {
        private final Map<Integer, String> routed = new HashMap<>();

        SocketHooks(String packages) throws PackageManager.NameNotFoundException {
            if (packages.isEmpty()) return;
            if (Build.VERSION.SDK_INT < 29) throw new IllegalStateException("Android 10 required for app rules");
            PackageManager manager = getPackageManager();
            for (String name : packages.split("\n")) {
                int uid = manager.getPackageUid(name, 0);
                String[] owners = manager.getPackagesForUid(uid);
                routed.put(uid, owners != null && owners.length == 1 ? name : "?");
            }
        }

        @Override public boolean protect(int fd) {
            return !closed && HyRouteVpnService.this.protect(fd);
        }

        @Override public String packageForFlow(String protocol, String source, int sourcePort, String target, int targetPort) {
            if (closed) return "?";
            if (Build.VERSION.SDK_INT < 29 || routed.isEmpty()) return "";
            try {
                ConnectivityManager manager = getSystemService(ConnectivityManager.class);
                int transport = protocol.equals("tcp") ? OsConstants.IPPROTO_TCP : OsConstants.IPPROTO_UDP;
                int uid = manager.getConnectionOwnerUid(transport,
                        new InetSocketAddress(InetAddress.getByName(source), sourcePort),
                        new InetSocketAddress(InetAddress.getByName(target), targetPort));
                return uid < 0 ? "?" : routed.getOrDefault(uid, "");
            } catch (Exception e) {
                return "?";
            }
        }
    }
}
