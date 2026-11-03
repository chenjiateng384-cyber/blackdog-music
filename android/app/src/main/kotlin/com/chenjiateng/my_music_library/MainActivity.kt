package com.chenjiateng.my_music_library

import android.content.ContentValues
import android.content.Intent
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity
import java.io.File
import java.security.MessageDigest

class MainActivity : AudioServiceActivity() {
    private val channelName = "my_music_library/media"
    private var scanRootBridge: ScanRootBridge? = null
    private var backupBridge: BackupBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "scanMusic" -> result.success(scanMusic())
                "artwork" -> {
                    val uri = call.argument<String>("uri")
                    result.success(uri?.let(::readArtwork))
                }
                "importMusic" -> {
                    val paths = call.argument<List<String>>("paths").orEmpty()
                    try {
                        result.success(importMusic(paths))
                    } catch (error: Exception) {
                        result.error("IMPORT_FAILED", error.message, null)
                    }
                }
                "cleanupDuplicates" -> {
                    try {
                        result.success(cleanupDuplicates())
                    } catch (error: Exception) {
                        result.error("CLEANUP_FAILED", error.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        scanRootBridge = ScanRootBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        backupBridge = BackupBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (scanRootBridge?.handleActivityResult(requestCode, resultCode, data) == true) return
        if (backupBridge?.handleActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        scanRootBridge?.dispose()
        scanRootBridge = null
        backupBridge?.dispose()
        backupBridge = null
        super.onDestroy()
    }

    private fun scanMusic(): List<Map<String, Any?>> {
        val collection = MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        val projection = mutableListOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.DATE_ADDED,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.MIME_TYPE,
            MediaStore.Audio.Media.SIZE,
            MediaStore.Audio.Media.BITRATE,
        ).apply {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                add(MediaStore.Audio.Media.SAMPLERATE)
                add(MediaStore.Audio.Media.BITS_PER_SAMPLE)
            }
        }.toTypedArray()
        val rows = mutableListOf<Map<String, Any?>>()
        contentResolver.query(
            collection,
            projection,
            "${MediaStore.Audio.Media.IS_MUSIC} != 0",
            null,
            "${MediaStore.Audio.Media.DATE_ADDED} DESC, ${MediaStore.Audio.Media.TITLE} COLLATE NOCASE ASC",
        )?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val titleColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val artistColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val albumColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
            val durationColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
            val dateAddedColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATE_ADDED)
            val displayNameColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
            val mimeTypeColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.MIME_TYPE)
            val sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.SIZE)
            val bitrateColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.BITRATE)
            val sampleRateColumn = cursor.getColumnIndex(MediaStore.Audio.Media.SAMPLERATE)
            val bitsPerSampleColumn = cursor.getColumnIndex(MediaStore.Audio.Media.BITS_PER_SAMPLE)
            while (cursor.moveToNext()) {
                val id = cursor.getLong(idColumn)
                rows.add(
                    mapOf(
                        "id" to id,
                        "uri" to "$collection/$id",
                        "title" to cursor.getString(titleColumn),
                        "artist" to cursor.getString(artistColumn),
                        "album" to cursor.getString(albumColumn),
                        "duration" to cursor.getLong(durationColumn),
                        "dateAdded" to cursor.getLong(dateAddedColumn),
                        "displayName" to cursor.getString(displayNameColumn),
                        "mimeType" to cursor.getString(mimeTypeColumn),
                        "size" to cursor.getLong(sizeColumn),
                        "bitrate" to cursor.getLong(bitrateColumn),
                        "sampleRate" to if (sampleRateColumn >= 0) cursor.getLong(sampleRateColumn) else 0L,
                        "bitsPerSample" to if (bitsPerSampleColumn >= 0) cursor.getLong(bitsPerSampleColumn) else 0L,
                    ),
                )
            }
        }
        return rows
    }

    private fun importMusic(paths: List<String>): Int {
        var imported = 0
        for (path in paths) {
            val source = File(path)
            if (!source.exists()) continue
            val sourceHash = sha256(source) ?: continue
            if (hasMatchingHash(sourceHash)) continue
            val metadata = MediaMetadataRetriever()
            try {
                metadata.setDataSource(source.absolutePath)
                val title = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE)
                    ?.takeIf { it.isNotBlank() } ?: source.nameWithoutExtension
                val artist = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST)
                    ?.takeIf { it.isNotBlank() } ?: "未知歌手"
                val album = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUM)
                    ?.takeIf { it.isNotBlank() } ?: "未知专辑"
                val duration = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull() ?: 0L
                val mimeType = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)
                    ?: mimeTypeFor(source.extension)
                val values = ContentValues().apply {
                    put(MediaStore.Audio.Media.DISPLAY_NAME, source.name)
                    put(MediaStore.Audio.Media.TITLE, title)
                    put(MediaStore.Audio.Media.ARTIST, artist)
                    put(MediaStore.Audio.Media.ALBUM, album)
                    put(MediaStore.Audio.Media.DURATION, duration)
                    put(MediaStore.Audio.Media.MIME_TYPE, mimeType)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        put(MediaStore.Audio.Media.RELATIVE_PATH, "Music/我的音乐库")
                        put(MediaStore.Audio.Media.IS_PENDING, 1)
                    }
                }
                val uri = contentResolver.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, values)
                    ?: continue
                contentResolver.openOutputStream(uri)?.use { output ->
                    source.inputStream().use { input -> input.copyTo(output) }
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    values.clear()
                    values.put(MediaStore.Audio.Media.IS_PENDING, 0)
                    contentResolver.update(uri, values, null, null)
                }
                imported++
            } finally {
                metadata.release()
            }
        }
        return imported
    }

    private fun hasMatchingHash(sourceHash: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val collection = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(MediaStore.Audio.Media._ID)
        val selection = "${MediaStore.Audio.Media.RELATIVE_PATH} = ?"
        contentResolver.query(collection, projection, selection, arrayOf("Music/我的音乐库/"), null)
            ?.use { cursor ->
                val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
                while (cursor.moveToNext()) {
                    val uri = Uri.withAppendedPath(collection, cursor.getLong(idColumn).toString())
                    if (sha256(uri) == sourceHash) return true
                }
            }
        return false
    }

    private fun cleanupDuplicates(): Map<String, Any> {
        val collection = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.DATE_ADDED,
        )
        val selection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            "${MediaStore.Audio.Media.RELATIVE_PATH} = ?"
        } else {
            "${MediaStore.Audio.Media.IS_MUSIC} != 0"
        }
        val arguments = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            arrayOf("Music/我的音乐库/")
        } else null
        val candidates = mutableListOf<Triple<Long, String, Long>>()
        contentResolver.query(collection, projection, selection, arguments, null)?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val nameColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
            val dateColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATE_ADDED)
            while (cursor.moveToNext()) {
                candidates.add(Triple(cursor.getLong(idColumn), cursor.getString(nameColumn).orEmpty(), cursor.getLong(dateColumn)))
            }
        }
        candidates.sortWith(compareBy<Triple<Long, String, Long>>(
            { hasCopySuffix(it.second) },
            { it.third },
        ))
        val seenHashes = mutableSetOf<String>()
        val removedIds = mutableListOf<Long>()
        var failed = 0
        for ((id, _, _) in candidates) {
            val uri = Uri.withAppendedPath(collection, id.toString())
            val hash = sha256(uri) ?: continue
            if (seenHashes.add(hash)) continue
            try {
                if (contentResolver.delete(uri, null, null) > 0) removedIds.add(id) else failed++
            } catch (_: SecurityException) {
                failed++
            }
        }
        return mapOf("removed" to removedIds.size, "failed" to failed, "removedIds" to removedIds)
    }

    private fun hasCopySuffix(name: String): Boolean = Regex("\\s*\\(\\d+\\)(?=\\.[^.]+$)").containsMatchIn(name)

    private fun sha256(file: File): String? = try {
        file.inputStream().use { input ->
            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count <= 0) break
                digest.update(buffer, 0, count)
            }
            digest.digest().joinToString("") { "%02x".format(it) }
        }
    } catch (_: Exception) {
        null
    }

    private fun sha256(uri: Uri): String? = try {
        contentResolver.openInputStream(uri)?.use { input ->
            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count <= 0) break
                digest.update(buffer, 0, count)
            }
            digest.digest().joinToString("") { "%02x".format(it) }
        }
    } catch (_: Exception) {
        null
    }

    private fun readArtwork(uriString: String): ByteArray? {
        val metadata = MediaMetadataRetriever()
        return try {
            metadata.setDataSource(this, Uri.parse(uriString))
            metadata.embeddedPicture
        } catch (_: Exception) {
            null
        } finally {
            metadata.release()
        }
    }

    private fun mimeTypeFor(extension: String): String = when (extension.lowercase()) {
        "flac" -> "audio/flac"
        "wav" -> "audio/wav"
        "m4a" -> "audio/mp4"
        "aac" -> "audio/aac"
        "ogg", "opus" -> "audio/ogg"
        else -> "audio/mpeg"
    }
}
