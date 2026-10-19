package com.taskflow.taskflow

import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * FlutterFragmentActivity is needed by the biometric prompt (app lock).
 *
 * This class also turns the Android intents the app answers into a small map
 * for Dart (channel "taskflow/intents"):
 *  - the share sheet (text, links, images, files): FR-C5
 *  - launcher shortcuts "New task", "Today", "Search": FR-I2
 *  - app-to-app intents (Tasker, Automate, Shortcuts): add or complete a task: FR-I7
 *      action com.taskflow.taskflow.ADD_TASK       extra text = a Quick Add line
 *      action com.taskflow.taskflow.COMPLETE_TASK  extra text = the task's title
 *  - the home-screen widget: OPEN_TASK (extra id), NEW_TASK, TODAY
 */
class MainActivity : FlutterFragmentActivity() {
    private var channel: MethodChannel? = null
    private var pending: Map<String, Any?>? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "taskflow/intents")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "initial" -> {
                    val p = pending
                    pending = null
                    result.success(p)
                }
                else -> result.notImplemented()
            }
        }
        channel = ch
        handle(intent, launch = true)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handle(intent, launch = false)
    }

    private fun deliver(message: Map<String, Any?>, launch: Boolean) {
        if (launch) {
            pending = message
        } else {
            channel?.invokeMethod("intent", message)
        }
    }

    private fun handle(intent: Intent?, launch: Boolean) {
        if (intent == null) return
        when (intent.action) {
            Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE -> {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
                val uris = ArrayList<Uri>()
                if (intent.action == Intent.ACTION_SEND) {
                    @Suppress("DEPRECATION")
                    (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uris.add(it) }
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
                }
                if (uris.isEmpty()) {
                    deliver(mapOf("type" to "share", "text" to text, "subject" to subject, "files" to emptyList<Map<String, Any?>>()), launch)
                } else {
                    // Copy the shared files into the app's cache (a content URI may stop working
                    // once the other app is gone), off the main thread.
                    worker.execute {
                        val files = uris.mapNotNull { copyShared(it) }
                        main.post {
                            deliver(
                                mapOf("type" to "share", "text" to text, "subject" to subject, "files" to files, "unreadable" to (uris.size - files.size)),
                                launch,
                            )
                        }
                    }
                }
            }
            "com.taskflow.taskflow.ADD_TASK" -> deliver(mapOf("type" to "add", "text" to intent.getStringExtra("text"), "silent" to true), launch)
            "com.taskflow.taskflow.COMPLETE_TASK" -> deliver(mapOf("type" to "complete", "text" to intent.getStringExtra("text")), launch)
            "com.taskflow.taskflow.NEW_TASK" -> deliver(mapOf("type" to "add", "text" to null, "silent" to false), launch)
            "com.taskflow.taskflow.OPEN_TASK" -> deliver(mapOf("type" to "open", "text" to intent.getStringExtra("id")), launch)
            "com.taskflow.taskflow.TODAY" -> deliver(mapOf("type" to "today"), launch)
            "com.taskflow.taskflow.SEARCH" -> deliver(mapOf("type" to "search"), launch)
            else -> return
        }
        // Handled: a later configuration change must not act on it again.
        intent.action = null
    }

    private fun copyShared(uri: Uri): Map<String, Any?>? {
        return try {
            var name = uri.lastPathSegment ?: "file"
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0)?.let { name = it }
            }
            name = name.substringAfterLast('/').replace(Regex("[\\\\:*?\"<>|]"), "_")
            val dir = File(cacheDir, "shared").apply { mkdirs() }
            val out = File(dir, "${System.nanoTime()}-$name")
            val max = 100L * 1024 * 1024
            var total = 0L
            contentResolver.openInputStream(uri)?.use { input ->
                out.outputStream().use { o ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > max) {
                            o.close()
                            out.delete()
                            return null
                        }
                        o.write(buf, 0, n)
                    }
                }
            } ?: return null
            mapOf("path" to out.absolutePath, "name" to name, "mime" to (contentResolver.getType(uri) ?: ""))
        } catch (e: Exception) {
            null
        }
    }
}
