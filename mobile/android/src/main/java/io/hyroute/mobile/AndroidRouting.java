package io.hyroute.mobile;

import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.VpnService;
import android.os.Build;
import android.system.OsConstants;

import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;

import mobile.Router;

/** Android's VPN app scope and TCP/UDP flow ownership for the HyRoute router. */
public final class AndroidRouting {
    public enum Scope {
        ALL_APPS,
        ONLY_SELECTED,
        EXCEPT_SELECTED
    }

    private final Router router;
    private final ConnectivityManager connectivity;
    private final PackageManager packageManager;
    private final Set<String> routedPackages = new HashSet<>();

    public AndroidRouting(VpnService service, Router router) throws PackageManager.NameNotFoundException {
        this.router = Objects.requireNonNull(router);
        connectivity = Objects.requireNonNull(service.getSystemService(ConnectivityManager.class));
        packageManager = service.getPackageManager();
        String packages = router.androidPackages();
        if (packages.isEmpty()) {
            return;
        }
        if (Build.VERSION.SDK_INT < 29) {
            throw new UnsupportedOperationException("App-specific routing requires Android 10 or later");
        }
        for (String packageName : packages.split("\n")) {
            packageManager.getPackageUid(packageName, 0);
            routedPackages.add(packageName);
        }
    }

    /**
     * Applies app scope to a fresh builder before establish(). The caller must
     * discard the builder if Android rejects any selected package.
     */
    public static void applySplitTunnel(VpnService.Builder builder, Scope scope, List<String> packages)
            throws PackageManager.NameNotFoundException {
        Objects.requireNonNull(builder);
        Objects.requireNonNull(scope);
        Set<String> selection = new LinkedHashSet<>(packages);
        if (scope == Scope.ALL_APPS) {
            if (!selection.isEmpty()) {
                throw new IllegalArgumentException("All apps mode does not use a package list");
            }
            return;
        }
        if (selection.isEmpty()) {
            throw new IllegalArgumentException("Select at least one app");
        }
        for (String packageName : selection) {
            if (scope == Scope.ONLY_SELECTED) {
                builder.addAllowedApplication(packageName);
            } else {
                builder.addDisallowedApplication(packageName);
            }
        }
    }

    /** A routing error leaves the flow unrouted and must never trigger direct forwarding. */
    public String decide(int protocol, InetSocketAddress source, InetSocketAddress destination, String domain)
            throws Exception {
        String network = network(protocol);
        Owner owner = ownerOf(protocol, source, destination);
        return router.decideForApp(endpoint(destination), network, domain, owner.packageName, owner.known);
    }

    /** Evaluates cached DNS names before the payload's exact domain is known. */
    public String decideWithDns(int protocol, InetSocketAddress source, InetSocketAddress destination, String dnsSites)
            throws Exception {
        String network = network(protocol);
        Owner owner = ownerOf(protocol, source, destination);
        return router.decideForAppWithDNS(endpoint(destination), network, dnsSites, owner.packageName, owner.known);
    }

    private Owner ownerOf(int protocol, InetSocketAddress source, InetSocketAddress destination) {
        if (routedPackages.isEmpty()) {
            return Owner.UNKNOWN;
        }
        int uid;
        try {
            uid = connectivity.getConnectionOwnerUid(protocol, source, destination);
        } catch (SecurityException e) {
            return Owner.UNKNOWN;
        }
        if (uid < 0) {
            return Owner.UNKNOWN;
        }
        String[] owners = packageManager.getPackagesForUid(uid);
        if (owners == null || owners.length == 0) {
            return Owner.UNKNOWN;
        }
        if (owners.length == 1) {
            return new Owner(owners[0], true);
        }
        for (String packageName : owners) {
            if (routedPackages.contains(packageName)) {
                return Owner.UNKNOWN;
            }
        }
        return new Owner("", true);
    }

    private static String network(int protocol) {
        if (protocol == OsConstants.IPPROTO_TCP) {
            return "tcp";
        }
        if (protocol == OsConstants.IPPROTO_UDP) {
            return "udp";
        }
        throw new IllegalArgumentException("Only TCP and UDP flows have application owners");
    }

    private static String endpoint(InetSocketAddress destination) {
        InetAddress address = Objects.requireNonNull(destination.getAddress());
        String ip = address.getHostAddress();
        if (address instanceof Inet6Address) {
            ip = "[" + ip + "]";
        }
        return ip + ":" + destination.getPort();
    }

    private static final class Owner {
        static final Owner UNKNOWN = new Owner("", false);

        final String packageName;
        final boolean known;

        Owner(String packageName, boolean known) {
            this.packageName = packageName;
            this.known = known;
        }
    }
}
