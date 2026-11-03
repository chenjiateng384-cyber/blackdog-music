package com.chenjiateng.my_music_library

import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import java.util.Locale

internal data class MediaStoreRecord(
    val volume: String,
    val id: Long,
    val contentUri: String,
    val mimeType: String?,
    val dateAddedSeconds: Long?,
)

/** Optional MediaStore enrichment. SAF remains the source of truth. */
internal class MediaStoreLookup(private val context: Context) {
    private val byStoragePath = mutableMapOf<String, MediaStoreRecord>()

    fun build() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val volumes = try {
            MediaStore.getExternalVolumeNames(context)
        } catch (_: Exception) {
            emptySet()
        }
        for (volume in volumes) indexVolume(volume)
    }

    fun find(storageRelativePath: String): MediaStoreRecord? =
        byStoragePath[normalize(storageRelativePath)]

    private fun indexVolume(volume: String) {
        val collection = MediaStore.Audio.Media.getContentUri(volume)
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.RELATIVE_PATH,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.MIME_TYPE,
            MediaStore.Audio.Media.DATE_ADDED,
        )
        try {
            context.contentResolver.query(collection, projection, null, null, null)?.use { cursor ->
                val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
                val pathColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.RELATIVE_PATH)
                val nameColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
                val mimeColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.MIME_TYPE)
                val addedColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATE_ADDED)
                while (cursor.moveToNext()) {
                    val path = cursor.getString(pathColumn).orEmpty() + cursor.getString(nameColumn).orEmpty()
                    val id = cursor.getLong(idColumn)
                    byStoragePath.putIfAbsent(
                        normalize(path),
                        MediaStoreRecord(
                            volume = volume,
                            id = id,
                            contentUri = Uri.withAppendedPath(collection, id.toString()).toString(),
                            mimeType = cursor.getString(mimeColumn),
                            dateAddedSeconds = cursor.getLong(addedColumn).takeIf { it > 0 },
                        ),
                    )
                }
            }
        } catch (_: SecurityException) {
            // SAF scanning still works when READ_MEDIA_AUDIO has not been granted.
        } catch (_: Exception) {
            // A vendor MediaStore may omit optional columns; SAF remains authoritative.
        }
    }

    private fun normalize(value: String): String = value
        .replace('\\', '/')
        .trimStart('/')
        .lowercase(Locale.ROOT)
}
