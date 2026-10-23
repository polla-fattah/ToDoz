package com.taskflow.geofence;

import android.content.Context;

import androidx.annotation.NonNull;

import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Channel "taskflow/geofence" for the app (and for the job that runs while it is closed):
 *  set(json)  watch exactly these places (a JSON list), replacing what was watched; answers null or why not
 *  status()   what is allowed and how many places are watched
 */
public class GeofencePlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    private MethodChannel channel;
    private Context context;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "taskflow/geofence");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (channel != null) channel.setMethodCallHandler(null);
        channel = null;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "set": {
                Object arg = call.arguments;
                String json = arg instanceof String ? (String) arg : "[]";
                GeofenceController.set(context, json, error -> result.success(error));
                break;
            }
            case "simulate": {
                // A test: show what would be shown on arriving at or leaving a place (the Places screen's test button).
                String placeId = call.argument("placeId");
                String kind = call.argument("kind");
                if (placeId == null || kind == null) {
                    result.error("bad_args", "placeId and kind are needed", null);
                    break;
                }
                result.success(GeofenceReceiver.fire(context, placeId, kind, true));
                break;
            }
            case "status": {
                Map<String, Object> m = new HashMap<>();
                m.put("playServices", GeofenceController.playServicesAvailable(context));
                m.put("fine", GeofenceController.hasFineLocation(context));
                m.put("background", GeofenceController.hasBackgroundLocation(context));
                m.put("watching", GeofenceController.watchedCount(context));
                m.put("result", GeofenceController.lastResult(context));
                result.success(m);
                break;
            }
            default:
                result.notImplemented();
        }
    }
}
