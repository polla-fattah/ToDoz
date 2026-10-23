package com.taskflow.geofence;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;
import android.util.Log;

import androidx.core.app.NotificationCompat;

import com.google.android.gms.location.Geofence;
import com.google.android.gms.location.GeofencingEvent;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.List;

/**
 * Android calls this when the phone crosses the edge of a watched place, even if the app is closed. It shows one
 * notification per task that wanted that arrival or departure ("Talk to Sam" - "You arrived at Work"); a tap opens
 * the task in the app.
 */
public class GeofenceReceiver extends BroadcastReceiver {
    static final String CHANNEL = "location_reminders";

    /** The same reminder is not shown again within this long (a phone near an edge can cross it several times). */
    static final long COOLDOWN_MS = 30L * 60 * 1000;

    @Override
    public void onReceive(Context context, Intent intent) {
        GeofencingEvent event = GeofencingEvent.fromIntent(intent);
        if (event == null || event.hasError()) {
            Log.w(GeofenceController.TAG, "geofence event with an error");
            return;
        }
        int transition = event.getGeofenceTransition();
        Log.i(GeofenceController.TAG, "transition " + transition + " at " + event.getTriggeringGeofences());
        String wanted;
        if (transition == Geofence.GEOFENCE_TRANSITION_ENTER) wanted = "arrive";
        else if (transition == Geofence.GEOFENCE_TRANSITION_EXIT) wanted = "leave";
        else return;
        List<Geofence> fences = event.getTriggeringGeofences();
        if (fences == null) return;
        for (Geofence fence : fences) fire(context, fence.getRequestId(), wanted, false);
    }

    /**
     * Shows the notification for every task that wanted [wanted] ("arrive" or "leave") at the place [placeId].
     * Returns how many were shown. With [ignoreCooldown] (a test from the Places screen) the 30 minute pause between
     * repeats is skipped.
     */
    static int fire(Context context, String placeId, String wanted, boolean ignoreCooldown) {
        int shown = 0;
        JSONArray places = GeofenceController.stored(context);
        for (int i = 0; i < places.length(); i++) {
            JSONObject place = places.optJSONObject(i);
            if (place == null || !placeId.equals(place.optString("id"))) continue;
            JSONArray tasks = place.optJSONArray("tasks");
            for (int j = 0; tasks != null && j < tasks.length(); j++) {
                JSONObject task = tasks.optJSONObject(j);
                if (task == null || !wanted.equals(task.optString("trigger"))) continue;
                if (show(context, place.optString("name"), task.optString("taskId"), task.optString("title"), wanted, ignoreCooldown)) shown++;
            }
        }
        return shown;
    }

    private static boolean show(Context context, String placeName, String taskId, String title, String kind, boolean ignoreCooldown) {
        SharedPreferences prefs = GeofenceController.prefs(context);
        String key = "last_" + taskId + "_" + placeName + "_" + kind;
        long now = System.currentTimeMillis();
        if (!ignoreCooldown && now - prefs.getLong(key, 0) < COOLDOWN_MS) return false;
        prefs.edit().putLong(key, now).apply();

        NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager == null) return false;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(CHANNEL, "Location reminders", NotificationManager.IMPORTANCE_HIGH);
            channel.setDescription("Reminders for when you arrive at or leave a place");
            manager.createNotificationChannel(channel);
        }

        // A tap opens the task: the app's MainActivity answers OPEN_TASK with the task id.
        Intent open = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        if (open == null) open = new Intent();
        open.setAction("com.taskflow.taskflow.OPEN_TASK");
        open.putExtra("id", taskId);
        open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M ? PendingIntent.FLAG_IMMUTABLE : 0);
        PendingIntent tap = PendingIntent.getActivity(context, (taskId + placeName + kind).hashCode(), open, flags);

        String text = ("arrive".equals(kind) ? "You arrived at " : "You left ") + placeName;
        NotificationCompat.Builder builder = new NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(context.getApplicationInfo().icon)
                .setContentTitle(title)
                .setContentText(text)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .setContentIntent(tap);
        try {
            manager.notify((taskId + placeName + kind).hashCode(), builder.build());
            return true;
        } catch (SecurityException ignored) {
            // Notifications are not allowed; nothing to do.
            return false;
        }
    }
}
