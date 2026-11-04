package com.chenjiateng.my_music_library

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.util.concurrent.Executors
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

class BackupBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val executor = Executors.newSingleThreadExecutor()
    private var pendingResult: MethodChannel.Result? = null
    private var pendingPath: String? = null

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "appVersion" -> result.success(appVersion())
            "exportBackup" -> chooseExport(call, result)
            "importBackup" -> chooseImport(call, result)
            else -> result.notImplemented()
        }
    }

    private fun appVersion(): String {
        val packageInfo = activity.packageManager.getPackageInfo(activity.packageName, 0)
        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            packageInfo.versionCode.toLong()
        }
        return "${packageInfo.versionName ?: "unknown"}+$versionCode"
    }

    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != EXPORT_REQUEST && requestCode != IMPORT_REQUEST) return false
        val result = pendingResult
        val path = pendingPath
        pendingResult = null
        pendingPath = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || result == null || path == null || uri == null) {
            result?.success(null)
            return true
        }
        if (requestCode == EXPORT_REQUEST) export(path, uri, result) else import(path, uri, result)
        return true
    }

    fun dispose() {
        pendingResult?.error("BACKUP_CANCELLED", "备份操作已取消", null)
        pendingResult = null
        pendingPath = null
        executor.shutdownNow()
        channel.setMethodCallHandler(null)
    }

    private fun chooseExport(call: MethodCall, result: MethodChannel.Result) {
        val source = call.argument<String>("sourceDirectory")
        val name = call.argument<String>("suggestedName") ?: "黑狗音乐.harmonybackup"
        if (source.isNullOrBlank() || !File(source).isDirectory) {
            result.error("BACKUP_SOURCE_INVALID", "备份临时目录不存在", null)
            return
        }
        if (!begin(result, source)) return
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = MIME_TYPE
            putExtra(Intent.EXTRA_TITLE, name)
        }
        activity.startActivityForResult(intent, EXPORT_REQUEST)
    }

    private fun chooseImport(call: MethodCall, result: MethodChannel.Result) {
        val destination = call.argument<String>("destinationDirectory")
        if (destination.isNullOrBlank()) {
            result.error("BACKUP_DESTINATION_INVALID", "恢复临时目录无效", null)
            return
        }
        val directory = File(destination)
        directory.mkdirs()
        if (!directory.isDirectory) {
            result.error("BACKUP_DESTINATION_INVALID", "无法创建恢复临时目录", null)
            return
        }
        if (!begin(result, destination)) return
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf(MIME_TYPE, "application/octet-stream", "application/zip"))
        }
        activity.startActivityForResult(intent, IMPORT_REQUEST)
    }

    private fun begin(result: MethodChannel.Result, path: String): Boolean {
        if (pendingResult != null) {
            result.error("BACKUP_ACTIVE", "另一个备份操作正在进行", null)
            return false
        }
        pendingResult = result
        pendingPath = path
        return true
    }

    private fun export(sourcePath: String, uri: Uri, result: MethodChannel.Result) {
        executor.execute {
            try {
                activity.contentResolver.openOutputStream(uri, "w")?.use { stream ->
                    ZipOutputStream(BufferedOutputStream(stream)).use { zip ->
                        val root = File(sourcePath)
                        root.walkTopDown().filter { it.isFile }.forEach { file ->
                            val name = file.relativeTo(root).invariantSeparatorsPath
                            zip.putNextEntry(ZipEntry(name))
                            file.inputStream().use { it.copyTo(zip) }
                            zip.closeEntry()
                        }
                    }
                } ?: error("无法打开目标文件")
                activity.runOnUiThread { result.success(uri.toString()) }
            } catch (error: Exception) {
                activity.runOnUiThread {
                    result.error("BACKUP_EXPORT_FAILED", error.message, null)
                }
            }
        }
    }

    private fun import(destinationPath: String, uri: Uri, result: MethodChannel.Result) {
        executor.execute {
            try {
                val root = File(destinationPath).canonicalFile
                var entryCount = 0
                var totalBytes = 0L
                activity.contentResolver.openInputStream(uri)?.use { stream ->
                    ZipInputStream(BufferedInputStream(stream)).use { zip ->
                        while (true) {
                            val entry = zip.nextEntry ?: break
                            entryCount++
                            if (entryCount > MAX_ENTRIES) error("备份文件条目过多")
                            val output = File(root, entry.name).canonicalFile
                            if (output.path != root.path &&
                                !output.path.startsWith(root.path + File.separator)) {
                                error("备份文件包含非法路径")
                            }
                            if (entry.isDirectory) {
                                output.mkdirs()
                            } else {
                                output.parentFile?.mkdirs()
                                output.outputStream().buffered().use { target ->
                                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                                    while (true) {
                                        val read = zip.read(buffer)
                                        if (read < 0) break
                                        totalBytes += read
                                        if (totalBytes > MAX_UNCOMPRESSED_BYTES) {
                                            error("备份文件解压后过大")
                                        }
                                        target.write(buffer, 0, read)
                                    }
                                }
                            }
                            zip.closeEntry()
                        }
                    }
                } ?: error("无法读取备份文件")
                activity.runOnUiThread { result.success(uri.toString()) }
            } catch (error: Exception) {
                activity.runOnUiThread {
                    result.error("BACKUP_IMPORT_FAILED", error.message, null)
                }
            }
        }
    }

    companion object {
        private const val CHANNEL = "my_music_library/backup"
        private const val MIME_TYPE = "application/x-harmonybackup"
        private const val EXPORT_REQUEST = 7391
        private const val IMPORT_REQUEST = 7392
        private const val MAX_ENTRIES = 4096
        private const val MAX_UNCOMPRESSED_BYTES = 1024L * 1024L * 1024L
    }
}
