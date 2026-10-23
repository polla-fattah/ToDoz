package com.taskflow.geofence;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Android forgets geofences when the phone restarts or the app is updated: watch the remembered places again. */
public class GeofenceBootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent == null ? null : intent.getAction();
        if (!Intent.ACTION_BOOT_COMPLETED.equals(action)
                && !Intent.ACTION_MY_PACKAGE_REPLACED.equals(action)
                && !"android.intent.action.QUICKBOOT_POWERON".equals(action)) {
            return;
        }
        final PendingResult pending = goAsync();
        GeofenceController.register(context, error -> pending.finish());
    }
}
