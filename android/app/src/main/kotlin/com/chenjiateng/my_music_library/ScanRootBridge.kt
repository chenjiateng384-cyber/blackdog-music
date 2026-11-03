package com.chenjiateng.my_music_library

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.Executors

class ScanRootBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : EventChannel.StreamHandler {
    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
    private val executor = Executors.newSingleThreadExecutor()
    private var eventSink: EventChannel.EventSink? = null
    private var pendingPickerResult: MethodChannel.Result? = null
    private var scanner: SafMusicScanner? = null

    init {
        eventChannel.setStreamHandler(this)
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickScanRoot" -> pickScanRoot(result)
                "validateScanRoot" -> {
                    val treeUri = call.argument<String>("treeUri")
                    result.success(treeUri != null && hasPersistedPermission(Uri.parse(treeUri)))
                }
                "startScan" -> {
                    val scanId = call.argument<String>("scanId") ?: UUID.randomUUID().toString()
                    val treeUri = call.argument<String>("treeUri")
                    if (treeUri == null || !hasPersistedPermission(Uri.parse(treeUri))) {
                        result.error("SCAN_ROOT_PERMISSION", "音乐目录授权已失效，请重新选择目录。", null)
                    } else {
                        startScan(scanId, Uri.parse(treeUri))
                        result.success(scanId)
                    }
                }
                "cancelScan" -> {
                    scanner?.cancel()
                    result.success(null)
                }
                "hashFiles" -> {
                    val requests = call.argument<List<Map<String, Any?>>>("files").orEmpty()
                    if (requests.size > MAX_HASH_BATCH) {
                        result.error("HASH_BATCH_TOO_LARGE", "单次最多校验 $MAX_HASH_BATCH 个文件。", null)
                    } else {
                        hashFiles(requests, result)
                    }
                }
                "readTextDocument" -> {
                    val uri = call.argument<String>("uri")
                    if (uri.isNullOrBlank()) {
                        result.error("LYRICS_URI_MISSING", "歌词文件地址为空。", null)
                    } else {
                        readTextDocument(uri, result)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_TREE_REQUEST) return false
        val result = pendingPickerResult
        pendingPickerResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result?.success(null)
            return true
        }
        val uri = data.data!!
        val flags = data.flags and
            (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        var persisted = false
        try {
            activity.contentResolver.takePersistableUriPermission(
                uri,
                flags and Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
            persisted = hasPersistedPermission(uri)
        } catch (_: SecurityException) {
            persisted = false
        }
        val documentId = DocumentsContract.getTreeDocumentId(uri)
        val relativeHint = documentId.substringAfter(':', "").trim('/')
        result?.success(
            mapOf(
                "treeUri" to uri.toString(),
                "displayName" to relativeHint.substringAfterLast('/').ifBlank { "音乐文件" },
                "volumeName" to documentId.substringBefore(':', "primary"),
                "relativePathHint" to relativeHint,
                "permissionPersisted" to persisted,
            ),
        )
        return true
    }

    fun dispose() {
        scanner?.cancel()
        executor.shutdownNow()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun pickScanRoot(result: MethodChannel.Result) {
        if (pendingPickerResult != null) {
            result.error("PICKER_ACTIVE", "目录选择器已经打开。", null)
            return
        }
        pendingPickerResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }
        activity.startActivityForResult(intent, PICK_TREE_REQUEST)
    }

    private fun startScan(scanId: String, treeUri: Uri) {
        scanner?.cancel()
        val next = SafMusicScanner(activity.applicationContext) { event ->
            activity.runOnUiThread { eventSink?.success(event) }
        }
        scanner = next
        executor.execute { next.scan(scanId, treeUri) }
    }

    private fun hashFiles(
        requests: List<Map<String, Any?>>,
        result: MethodChannel.Result,
    ) {
        executor.execute {
            val reader = ContentHashReader(activity.applicationContext)
            val hashes = requests.map(reader::hash)
            activity.runOnUiThread { result.success(hashes) }
        }
    }

    private fun readTextDocument(uri: String, result: MethodChannel.Result) {
        executor.execute {
            try {
                val content = TextDocumentReader(activity.applicationContext).read(uri)
                activity.runOnUiThread { result.success(content) }
            } catch (error: Exception) {
                activity.runOnUiThread {
                    result.error("LYRICS_READ_FAILED", error.message, null)
                }
            }
        }
    }

    private fun hasPersistedPermission(uri: Uri): Boolean = activity.contentResolver
        .persistedUriPermissions
        .any { it.uri == uri && it.isReadPermission }

    companion object {
        private const val METHOD_CHANNEL = "my_music_library/v4_scan"
        private const val EVENT_CHANNEL = "my_music_library/v4_scan_events"
        private const val PICK_TREE_REQUEST = 4812
        private const val MAX_HASH_BATCH = 12
    }
}
