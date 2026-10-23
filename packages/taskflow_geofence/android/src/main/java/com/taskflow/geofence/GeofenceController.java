package com.taskflow.geofence;

import android.Manifest;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Build;
import android.util.Log;

import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;

import com.google.android.gms.common.ConnectionResult;
import com.google.android.gms.common.GoogleApiAvailability;
import com.google.android.gms.location.Geofence;
import com.google.android.gms.location.GeofencingClient;
import com.google.android.gms.location.GeofencingRequest;
import com.google.android.gms.location.LocationServices;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

/**
 * Hands the places to Android's geofencing and keeps the list (with the tasks to mention at each) in
 * SharedPreferences, so the receiver can show the right notification without starting the app and the boot
 * receiver can watch the places again after a restart.
 *
 * The list is a JSON array of {id, name, lat, lon, radius, tasks: [{taskId, title, trigger: arrive|leave}]}
 * (WatchedPlace.toJson in the app's shared Dart code).
 */
final class GeofenceController {
    private GeofenceController() {}

    interface Done {
        /** @param error null on success, otherwise a sentence about what went wrong */
        void done(@Nullable String error);
    }

    static final String PREFS = "taskflow_geofence";
    static final String KEY_PLACES = "places";
    static final String KEY_RESULT = "register_result"; // "ok:<n>" or a sentence about what went wrong
    static final String TAG = "ToDozGeofence";

    static SharedPreferences prefs(Context c) {
        return c.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    static boolean playServicesAvailable(Context c) {
        return GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(c) == ConnectionResult.SUCCESS;
    }

    static boolean hasFineLocation(Context c) {
        return ContextCompat.checkSelfPermission(c, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    static boolean hasBackgroundLocation(Context c) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return hasFineLocation(c);
        return ContextCompat.checkSelfPermission(c, Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    static JSONArray stored(Context c) {
        try {
            return new JSONArray(prefs(c).getString(KEY_PLACES, "[]"));
        } catch (Exception e) {
            return new JSONArray();
        }
    }

    static int watchedCount(Context c) {
        return stored(c).length();
    }

    /** How the last attempt to hand the places to Android ended: "ok:3" (3 places watched) or why not. */
    static String lastResult(Context c) {
        return prefs(c).getString(KEY_RESULT, "");
    }

    private static void remember(Context c, String result) {
        Log.i(TAG, "register: " + result);
        prefs(c).edit().putString(KEY_RESULT, result).apply();
    }

    private static PendingIntent pending(Context c) {
        Intent intent = new Intent(c, GeofenceReceiver.class);
        // Android fills in the transition details, so the intent must be mutable (Android 12 and newer).
        int flags = PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ? PendingIntent.FLAG_MUTABLE : 0);
        return PendingIntent.getBroadcast(c, 0, intent, flags);
    }

    /** Remembers [json] and watches exactly those places. */
    static void set(Context c, String json, Done done) {
        try {
            new JSONArray(json); // refuse text that is not a list
        } catch (Exception e) {
            done.done("The places could not be read");
            return;
        }
        prefs(c).edit().putString(KEY_PLACES, json).apply();
        register(c, done);
    }

    /** Watches the remembered places (after a restart, or when the list changed). */
    static void register(Context c, @Nullable Done done) {
        final Context app = c.getApplicationContext();
        final Done inner = done != null ? done : error -> {};
        final Done finish = error -> {
            if (error != null) remember(app, error);
            inner.done(error);
        };
        final GeofencingClient client = LocationServices.getGeofencingClient(app);
        final JSONArray places = stored(app);

        client.removeGeofences(pending(app)).addOnCompleteListener(task -> {
            if (places.length() == 0) {
                remember(app, "ok:0");
                inner.done(null);
                return;
            }
            if (!playServicesAvailable(app)) {
                finish.done("Google Play Services is not available on this phone, so location reminders cannot work");
                return;
            }
            if (!hasFineLocation(app)) {
                finish.done("Location access is not allowed");
                return;
            }
            List<Geofence> fences = new ArrayList<>();
            for (int i = 0; i < places.length(); i++) {
                JSONObject p = places.optJSONObject(i);
                if (p == null) continue;
                boolean arrive = false;
                boolean leave = false;
                JSONArray tasks = p.optJSONArray("tasks");
                for (int j = 0; tasks != null && j < tasks.length(); j++) {
                    String t = tasks.optJSONObject(j) == null ? "" : tasks.optJSONObject(j).optString("trigger");
                    if ("arrive".equals(t)) arrive = true;
                    if ("leave".equals(t)) leave = true;
                }
                int types = (arrive ? Geofence.GEOFENCE_TRANSITION_ENTER : 0) | (leave ? Geofence.GEOFENCE_TRANSITION_EXIT : 0);
                if (types == 0) continue;
                try {
                    fences.add(new Geofence.Builder()
                            .setRequestId(p.getString("id"))
                            .setCircularRegion(p.getDouble("lat"), p.getDouble("lon"), (float) p.optDouble("radius", 150))
                            .setExpirationDuration(Geofence.NEVER_EXPIRE)
                            .setTransitionTypes(types)
                            .build());
                } catch (Exception ignored) {
                    // A place that cannot be built is skipped; the others are still watched.
                }
            }
            if (fences.isEmpty()) {
                remember(app, "ok:0");
                inner.done(null);
                return;
            }
            // 0: do not report "you are already inside" at the moment the places are handed over. The places are
            // handed over again after every change to a task, and that must not announce the same arrival again.
            final int count = fences.size();
            try {
                GeofencingRequest request = new GeofencingRequest.Builder().setInitialTrigger(0).addGeofences(fences).build();
                client.addGeofences(request, pending(app))
                        .addOnSuccessListener(v -> {
                            remember(app, "ok:" + count);
                            inner.done(null);
                        })
                        .addOnFailureListener(e -> finish.done("Android could not watch the places: " + e.getMessage()));
            } catch (SecurityException e) {
                finish.done("Location access is not allowed");
            } catch (RuntimeException e) {
                finish.done("Could not watch the places: " + e);
            }
        });
    }
}
