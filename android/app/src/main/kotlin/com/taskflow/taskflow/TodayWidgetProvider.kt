package com.taskflow.taskflow

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONObject

/**
 * The "Today" home-screen widget. The app writes a small JSON summary of today's tasks (see
 * lib/platform/today_widget.dart); this only draws it and wires the taps:
 *  - a task's circle completes it (a background Dart job runs, the app does not open),
 *  - a task opens it, the + adds a task, the heading opens Today (through MainActivity).
 */
class TodayWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray, widgetData: SharedPreferences) {
        val payload = try {
            JSONObject(widgetData.getString("today_json", null) ?: "{}")
        } catch (e: Exception) {
            JSONObject()
        }
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(id, build(context, payload))
        }
    }

    private fun build(context: Context, payload: JSONObject): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.today_widget)
        val items = payload.optJSONArray("items")
        val count = items?.length() ?: 0
        views.setTextViewText(R.id.widget_date, payload.optString("date", ""))
        views.setViewVisibility(R.id.widget_empty, if (count == 0) View.VISIBLE else View.GONE)

        val rows = intArrayOf(R.id.row0, R.id.row1, R.id.row2, R.id.row3, R.id.row4, R.id.row5)
        val checks = intArrayOf(R.id.check0, R.id.check1, R.id.check2, R.id.check3, R.id.check4, R.id.check5)
        val hits = intArrayOf(R.id.hit0, R.id.hit1, R.id.hit2, R.id.hit3, R.id.hit4, R.id.hit5)
        val titles = intArrayOf(R.id.title0, R.id.title1, R.id.title2, R.id.title3, R.id.title4, R.id.title5)
        val times = intArrayOf(R.id.time0, R.id.time1, R.id.time2, R.id.time3, R.id.time4, R.id.time5)
        for (i in rows.indices) {
            if (items == null || i >= count) {
                views.setViewVisibility(rows[i], View.GONE)
                continue
            }
            val item = items.getJSONObject(i)
            val id = item.optString("id")
            views.setViewVisibility(rows[i], View.VISIBLE)
            views.setTextViewText(titles[i], item.optString("title"))
            val time = if (item.isNull("time")) "" else item.optString("time")
            views.setTextViewText(times[i], time)
            views.setViewVisibility(times[i], if (time.isEmpty()) View.GONE else View.VISIBLE)
            views.setTextColor(times[i], if (item.optBoolean("late")) 0xFFD1453B.toInt() else context.getColor(R.color.widget_dim))
            views.setInt(checks[i], "setColorFilter", priorityColor(item.optInt("p", 4)))
            views.setOnClickPendingIntent(checks[i], HomeWidgetBackgroundIntent.getBroadcast(context, Uri.parse("taskflow://complete?id=$id")))
            views.setOnClickPendingIntent(hits[i], open(context, "com.taskflow.taskflow.OPEN_TASK", id))
        }
        val more = payload.optInt("more", 0)
        views.setViewVisibility(R.id.widget_more, if (more > 0) View.VISIBLE else View.GONE)
        if (more > 0) {
            views.setTextViewText(R.id.widget_more, "+$more more")
            views.setOnClickPendingIntent(R.id.widget_more, open(context, "com.taskflow.taskflow.TODAY", null))
        }
        views.setOnClickPendingIntent(R.id.widget_add, open(context, "com.taskflow.taskflow.NEW_TASK", null))
        views.setOnClickPendingIntent(R.id.widget_title, open(context, "com.taskflow.taskflow.TODAY", null))
        views.setOnClickPendingIntent(R.id.widget_date, open(context, "com.taskflow.taskflow.TODAY", null))
        return views
    }

    private fun priorityColor(p: Int): Int = when (p) {
        1 -> 0xFFD1453B.toInt()
        2 -> 0xFFEB8909.toInt()
        3 -> 0xFF246FE0.toInt()
        else -> 0xFF8A8A8A.toInt()
    }

    private fun open(context: Context, action: String, taskId: String?): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            this.action = action
            // A distinct address per target, so Android keeps one PendingIntent for each.
            data = Uri.parse("taskflow://widget/${action.substringAfterLast('.')}/${taskId ?: ""}")
            if (taskId != null) putExtra("id", taskId)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        return PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }
}
