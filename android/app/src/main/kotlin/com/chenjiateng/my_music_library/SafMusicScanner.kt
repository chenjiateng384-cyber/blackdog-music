package com.chenjiateng.my_music_library

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import java.io.File
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

internal class SafMusicScanner(
    private val context: Context,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    private val resolver = context.contentResolver
    private val tagReader = AudioTagReader(context)
    private val cancelled = AtomicBoolean(false)

    fun cancel() {
        cancelled.set(true)
    }

    fun scan(scanId: String, treeUri: Uri) {
        val rootDocumentId = DocumentsContract.getTreeDocumentId(treeUri)
        val rootUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, rootDocumentId)
        val rootStoragePath = rootDocumentId.substringAfter(':', "").trim('/')
        val mediaStore = MediaStoreLookup(context).apply { build() }
        try {
            val total = countAudio(scanId, rootUri, 0)
            if (cancelled.get()) return emitCancelled(scanId)
            emit(event(scanId, "progress", "readingMetadata", total = total, processed = 0))
            val batch = mutableListOf<Map<String, Any?>>()
            val processed = intArrayOf(0)
            processDirectory(
                scanId = scanId,
                directoryUri = rootUri,
                relativeDirectory = "",
                rootStoragePath = rootStoragePath,
                total = total,
                processed = processed,
                mediaStore = mediaStore,
                batch = batch,
                inheritedArtistArtwork = null,
            )
            if (batch.isNotEmpty()) emitBatch(scanId, batch, processed[0], total)
            if (cancelled.get()) return emitCancelled(scanId)
            emit(event(scanId, "complete", "complete", total = total, processed = processed[0]))
        } catch (error: Exception) {
            emit(
                event(scanId, "error", "failed").plus(
                    "message" to (error.message ?: error.javaClass.simpleName),
                ),
            )
        }
    }

    private fun countAudio(scanId: String, directoryUri: Uri, discovered: Int): Int {
        if (cancelled.get()) return discovered
        var count = discovered
        for (document in children(directoryUri)) {
            if (cancelled.get()) break
            if (document.isDirectory) {
                count = countAudio(scanId, document.uri, count)
            } else if (isAudio(document.filename)) {
                count++
                if (count % 25 == 0) {
                    emit(event(scanId, "progress", "discovering", discovered = count))
                }
            }
        }
        return count
    }

    private fun processDirectory(
        scanId: String,
        directoryUri: Uri,
        relativeDirectory: String,
        rootStoragePath: String,
        total: Int,
        processed: IntArray,
        mediaStore: MediaStoreLookup,
        batch: MutableList<Map<String, Any?>>,
        inheritedArtistArtwork: CachedLocalArtwork?,
    ) {
        if (cancelled.get()) return
        // Query each SAF directory once. Besides being noticeably faster on
        // large libraries, keeping the sibling set together lets us match
        // song.jpg and cover.jpg without touching the user's files.
        val documents = children(directoryUri)
        val lyrics = documents
            .asSequence()
            .filter { !it.isDirectory && it.filename.substringAfterLast('.', "").equals("lrc", true) }
            .map { document -> document.toLyricsMap(relativeDirectory) }
            .toList()
        val images = documents.filter { !it.isDirectory && isImage(it.filename) }
        val cachedImages = mutableMapOf<String, CachedLocalArtwork?>()
        val artistArtwork = if (relativeDirectory.isNotEmpty() && !relativeDirectory.contains('/')) {
            selectArtistArtwork(images)?.let { selected ->
                cachedImages.getOrPut(selected.uri.toString()) {
                    cacheLocalArtwork(selected)
                }?.copy(source = "artistFolder")
            }
        } else {
            null
        } ?: inheritedArtistArtwork
        val contentImages = images.filterNot { isArtistArtwork(it.filename) }
        for (document in documents) {
            if (cancelled.get()) return
            if (document.isDirectory) {
                val childDirectory = join(relativeDirectory, document.filename)
                processDirectory(
                    scanId,
                    document.uri,
                    childDirectory,
                    rootStoragePath,
                    total,
                    processed,
                    mediaStore,
                    batch,
                    artistArtwork,
                )
                continue
            }
            if (!isAudio(document.filename)) continue
            val relativePath = join(relativeDirectory, document.filename)
            val storagePath = join(rootStoragePath, relativePath)
            val mediaRecord = mediaStore.find(storagePath)
            val tags = tagReader.read(document.uri, document.mimeType, document.filename)
            val localArtwork = selectLocalArtwork(document.filename, contentImages)?.let { selected ->
                val cache = cachedImages.getOrPut(selected.first.uri.toString()) {
                    cacheLocalArtwork(selected.first)
                }
                cache?.copy(source = selected.second)
            }
            batch += mapOf(
                "documentUri" to document.uri.toString(),
                "relativePath" to relativePath,
                "parentFolder" to relativeDirectory.substringAfterLast('/', relativeDirectory),
                "filename" to document.filename,
                "extension" to document.filename.substringAfterLast('.', "").lowercase(Locale.ROOT),
                "mimeType" to (document.mimeType ?: mediaRecord?.mimeType ?: mimeType(document.filename)),
                "sizeBytes" to document.size,
                "modifiedAt" to document.modifiedAt,
                "mediaStoreVolume" to mediaRecord?.volume,
                "mediaStoreId" to mediaRecord?.id,
                "contentUri" to mediaRecord?.contentUri,
                "dateAdded" to mediaRecord?.dateAddedSeconds,
                "metadata" to tags,
                "lyricsCandidates" to lyrics,
                "localArtworkKey" to localArtwork?.key,
                "localArtworkPath" to localArtwork?.path,
                "localArtworkMime" to localArtwork?.mimeType,
                "localArtworkSource" to localArtwork?.source,
                "libraryArtistFolderName" to relativeDirectory
                    .substringBefore('/', relativeDirectory)
                    .takeIf { it.isNotBlank() },
                "libraryArtistRelativeDirectory" to relativeDirectory
                    .substringBefore('/', relativeDirectory)
                    .takeIf { it.isNotBlank() },
                "artistArtworkKey" to artistArtwork?.key,
                "artistArtworkPath" to artistArtwork?.path,
                "artistArtworkMime" to artistArtwork?.mimeType,
            )
            processed[0]++
            if (batch.size >= 20) emitBatch(scanId, batch, processed[0], total)
        }
    }

    private fun emitBatch(
        scanId: String,
        batch: MutableList<Map<String, Any?>>,
        processed: Int,
        total: Int,
    ) {
        emit(
            event(scanId, "batch", "readingMetadata", total = total, processed = processed)
                .plus("files" to batch.toList()),
        )
        batch.clear()
    }

    private fun children(directoryUri: Uri): List<SafDocument> {
        val documentId = DocumentsContract.getDocumentId(directoryUri)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(directoryUri, documentId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        val result = mutableListOf<SafDocument>()
        resolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
            val sizeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE)
            val modifiedColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
            while (cursor.moveToNext()) {
                val id = cursor.getString(idColumn)
                result += SafDocument(
                    uri = DocumentsContract.buildDocumentUriUsingTree(directoryUri, id),
                    filename = cursor.getString(nameColumn).orEmpty(),
                    mimeType = cursor.getString(mimeColumn),
                    size = if (cursor.isNull(sizeColumn)) 0L else cursor.getLong(sizeColumn),
                    modifiedAt = if (cursor.isNull(modifiedColumn)) null else cursor.getLong(modifiedColumn),
                )
            }
        }
        return result
    }

    private fun SafDocument.toLyricsMap(relativeDirectory: String): Map<String, Any?> = mapOf(
        "documentUri" to uri.toString(),
        "relativePath" to join(relativeDirectory, filename),
        "filename" to filename,
        "sizeBytes" to size,
        "modifiedAt" to modifiedAt,
    )

    private fun emitCancelled(scanId: String) {
        emit(event(scanId, "cancelled", "cancelled"))
    }

    private fun event(
        scanId: String,
        type: String,
        phase: String,
        discovered: Int? = null,
        total: Int? = null,
        processed: Int? = null,
    ): Map<String, Any?> = mapOf(
        "scanId" to scanId,
        "type" to type,
        "phase" to phase,
        "discovered" to discovered,
        "total" to total,
        "processed" to processed,
    )

    private fun isAudio(filename: String): Boolean =
        filename.substringAfterLast('.', "").lowercase(Locale.ROOT) in audioExtensions

    private fun isImage(filename: String): Boolean =
        filename.substringAfterLast('.', "").lowercase(Locale.ROOT) in imageExtensions

    private fun selectLocalArtwork(
        audioFilename: String,
        images: List<SafDocument>,
    ): Pair<SafDocument, String>? {
        if (images.isEmpty()) return null
        val audioStem = normalizedArtworkStem(audioFilename)
        images.firstOrNull { normalizedArtworkStem(it.filename) == audioStem }
            ?.let { return it to "sidecar" }

        for (preferred in preferredArtworkNames) {
            images.firstOrNull { normalizedArtworkStem(it.filename) == preferred }
                ?.let { return it to "folder" }
        }
        return if (images.size == 1) images.single() to "folder" else null
    }

    private fun selectArtistArtwork(images: List<SafDocument>): SafDocument? {
        for (preferred in preferredArtistArtworkNames) {
            images.firstOrNull { normalizedArtworkStem(it.filename) == preferred }
                ?.let { return it }
        }
        return null
    }

    private fun isArtistArtwork(filename: String): Boolean =
        normalizedArtworkStem(filename) in preferredArtistArtworkNames

    private fun normalizedArtworkStem(filename: String): String = filename
        .substringBeforeLast('.', filename)
        .lowercase(Locale.ROOT)
        .replace(Regex("^[0-9]{1,3}[\\s._-]+"), "")
        .replace(Regex("[\\s_\\-.·()（）\\[\\]【】]+"), "")

    private fun cacheLocalArtwork(document: SafDocument): CachedLocalArtwork? {
        return try {
            if (document.size > maxArtworkBytes) return null
            val bytes = resolver.openInputStream(document.uri)?.use { it.readBytes() } ?: return null
            if (bytes.isEmpty() || bytes.size > maxArtworkBytes) return null
            val key = MessageDigest.getInstance("SHA-256")
                .digest(bytes)
                .joinToString("") { "%02x".format(it) }
            val extension = document.filename.substringAfterLast('.', "jpg")
                .lowercase(Locale.ROOT)
                .takeIf { it in imageExtensions } ?: "jpg"
            val directory = File(context.filesDir, "artwork/local").apply { mkdirs() }
            val target = File(directory, "$key.$extension")
            if (!target.exists()) target.writeBytes(bytes)
            CachedLocalArtwork(
                key = key,
                path = target.absolutePath,
                mimeType = document.mimeType ?: mimeType(document.filename),
                source = "folder",
            )
        } catch (_: Exception) {
            null
        }
    }

    private fun mimeType(filename: String): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(filename.substringAfterLast('.', ""))
            ?: "audio/*"

    private fun join(first: String, second: String): String =
        listOf(first.trim('/'), second.trim('/')).filter { it.isNotEmpty() }.joinToString("/")

    private data class SafDocument(
        val uri: Uri,
        val filename: String,
        val mimeType: String?,
        val size: Long,
        val modifiedAt: Long?,
    ) {
        val isDirectory: Boolean
            get() = mimeType == DocumentsContract.Document.MIME_TYPE_DIR
    }

    private data class CachedLocalArtwork(
        val key: String,
        val path: String,
        val mimeType: String?,
        val source: String,
    )

    companion object {
        private val audioExtensions = setOf("flac", "mp3", "wav", "m4a", "aac", "ogg", "opus")
        private val imageExtensions = setOf("jpg", "jpeg", "png", "webp")
        private val preferredArtworkNames = listOf("封面", "cover", "folder", "front", "album")
        private val preferredArtistArtworkNames = listOf("歌手封面", "artist", "portrait", "歌手")
        private const val maxArtworkBytes = 32L * 1024 * 1024
    }
}
