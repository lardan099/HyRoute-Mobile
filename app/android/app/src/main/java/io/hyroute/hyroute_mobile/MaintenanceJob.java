package io.hyroute.hyroute_mobile;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import java.io.File;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

import mobile.Mobile;
import mobile.Maintenance;

public final class MaintenanceJob extends JobService {
    static final ExecutorService executor = Executors.newFixedThreadPool(3);
    private static final Object SUBSCRIPTIONS = new Object();
    private static final int JOB_ID = 7401;

    private JobParameters active;
    private Future<?> work;
    private Maintenance maintenance;

    static void schedule(Context context) {
        JobScheduler scheduler = context.getSystemService(JobScheduler.class);
        if (scheduler == null) return;
        for (JobInfo pending : scheduler.getAllPendingJobs()) {
            if (pending.getId() == JOB_ID) return;
        }
        JobInfo job = new JobInfo.Builder(JOB_ID, new ComponentName(context, MaintenanceJob.class))
                .setPersisted(true)
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .setPeriodic(TimeUnit.HOURS.toMillis(24))
                .build();
        scheduler.schedule(job);
    }

    static String refreshSubscriptions(Context context) throws Exception {
        return refreshSubscriptions(context, null);
    }

    private static String refreshSubscriptions(Context context, Maintenance task) throws Exception {
        synchronized (SUBSCRIPTIONS) {
            ClientStore store = new ClientStore(context.getNoBackupFilesDir());
            String before = store.read();
            String updated = task == null ? Mobile.autoRefreshSubscriptions(before) : task.refreshSubscriptions(before);
            return store.writeIfCurrent(before, updated);
        }
    }

    static boolean refreshGeo(Context context) {
        return refreshGeo(context, null);
    }

    private static boolean refreshGeo(Context context, Maintenance task) {
        try {
            Mobile.configureGeo(new File(context.getNoBackupFilesDir(), "geo").getPath());
            String state = new ClientStore(context.getNoBackupFilesDir()).read();
            if (task == null) Mobile.autoUpdateGeoForState(state);
            else task.updateGeoForState(state);
            return true;
        } catch (Exception error) {
            return false;
        }
    }

    @Override
    public boolean onStartJob(JobParameters parameters) {
        active = parameters;
        Maintenance task = Mobile.newMaintenance();
        maintenance = task;
        work = executor.submit(() -> {
            boolean subscriptionsOK = true;
            try {
                refreshSubscriptions(this, task);
            } catch (Exception error) {
                subscriptionsOK = false;
            }
            boolean geoOK = !Thread.currentThread().isInterrupted() && refreshGeo(this, task);
            boolean retry = !subscriptionsOK || !geoOK;
            new Handler(Looper.getMainLooper()).post(() -> {
                if (active == parameters) {
                    active = null;
                    work = null;
                    maintenance = null;
                    jobFinished(parameters, retry);
                }
            });
        });
        return true;
    }

    @Override
    public boolean onStopJob(JobParameters parameters) {
        active = null;
        if (work != null) work.cancel(true);
        if (maintenance != null) maintenance.cancel();
        maintenance = null;
        work = null;
        return true;
    }
}
