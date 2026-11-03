package com.chenjiateng.my_music_library

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.ParcelFileDescriptor
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/** Reads audio tags through a Content URI without requiring an absolute path. */
class AudioTagReader(private val context: Context) {
    fun read(uri: Uri, mimeType: String?, filename: String): Map<String, Any?> {
        val extension = filename.substringAfterLast('.', "").lowercase()
        val parsed = try {
            when (extension) {
                "wav", "wave" -> readWav(uri)
                else -> context.contentResolver.openInputStream(uri)?.use { input ->
                    when (extension) {
                    "flac" -> FlacTagParser.parse(input)
                    "mp3" -> Id3TagParser.parse(input)
                    else -> ParsedAudioTags(
                        tagFormat = extension.ifBlank { null },
                        readStatus = "partial",
                    )
                    }
                }
                    ?: ParsedAudioTags(readStatus = "failed")
            }
        } catch (_: Exception) {
            ParsedAudioTags(readStatus = "failed")
        }

        val retrieverValues = readRetriever(uri)
        val artwork = parsed.artwork ?: retrieverValues.artwork
        val cachedArtwork = artwork?.takeIf { it.isNotEmpty() }?.let {
            EmbeddedArtworkCache(context).store(it, parsed.artworkMime)
        }
        val title = parsed.title ?: retrieverValues.title
        val artist = parsed.artist ?: retrieverValues.artist
        val albumArtist = parsed.albumArtist ?: retrieverValues.albumArtist
        val album = parsed.album ?: retrieverValues.album
        val year = parsed.year ?: retrieverValues.year
        val trackNumber = parsed.trackNumber ?: retrieverValues.trackNumber
        val discNumber = parsed.discNumber ?: retrieverValues.discNumber
        val durationMs = parsed.durationMs ?: retrieverValues.durationMs ?: 0L
        val bitrate = retrieverValues.bitrate
        val sampleRate = parsed.sampleRate ?: retrieverValues.sampleRate
        val bitDepth = parsed.bitDepth ?: retrieverValues.bitDepth
        val rawPayload = JSONObject().apply {
            put("title", title)
            put("artist", artist)
            put("albumArtist", albumArtist)
            put("album", album)
            put("year", year)
            put("trackNumber", trackNumber)
            put("discNumber", discNumber)
            put("tagFormat", parsed.tagFormat)
        }.toString()

        val result = HashMap<String, Any?>(24)
        result["title"] = title
        result["artist"] = artist
        result["albumArtist"] = albumArtist
        result["album"] = album
        result["year"] = year
        result["trackNumber"] = trackNumber
        result["discNumber"] = discNumber
        result["durationMs"] = durationMs
        result["bitrate"] = bitrate
        result["sampleRate"] = sampleRate
        result["bitDepth"] = bitDepth
        result["embeddedLyrics"] = parsed.lyrics
        result["embeddedArtworkKey"] = cachedArtwork?.key
        result["embeddedArtworkPath"] = cachedArtwork?.path
        result["embeddedArtworkMime"] = parsed.artworkMime ?: retrieverValues.artworkMime
        result["tagFormat"] = parsed.tagFormat
        result["readStatus"] = if (parsed.readStatus == "failed") {
            if (retrieverValues.isEmpty) "failed" else "partial"
        } else {
            parsed.readStatus
        }
        result["rawPayload"] = rawPayload
        result["mimeType"] = mimeType ?: retrieverValues.mimeType
        return result
    }

    private fun readWav(uri: Uri): ParsedAudioTags {
        val descriptor = context.contentResolver.openFileDescriptor(uri, "r")
            ?: return ParsedAudioTags(tagFormat = "WAV", readStatus = "failed")
        return ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { stream ->
            WavTagParser.parse(stream.channel)
        }
    }

    private fun readRetriever(uri: Uri): RetrieverValues {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(context, uri)
            RetrieverValues(
                title = retriever.text(MediaMetadataRetriever.METADATA_KEY_TITLE),
                artist = retriever.text(MediaMetadataRetriever.METADATA_KEY_ARTIST),
                albumArtist = retriever.text(MediaMetadataRetriever.METADATA_KEY_ALBUMARTIST),
                album = retriever.text(MediaMetadataRetriever.METADATA_KEY_ALBUM),
                year = retriever.text(MediaMetadataRetriever.METADATA_KEY_YEAR)?.take(4)?.toIntOrNull(),
                trackNumber = number(retriever.text(MediaMetadataRetriever.METADATA_KEY_CD_TRACK_NUMBER)),
                discNumber = number(retriever.text(MediaMetadataRetriever.METADATA_KEY_DISC_NUMBER)),
                durationMs = retriever.text(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull(),
                bitrate = retriever.text(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toLongOrNull(),
                sampleRate = retriever.text(MediaMetadataRetriever.METADATA_KEY_SAMPLERATE)?.toLongOrNull(),
                bitDepth = retriever.text(MediaMetadataRetriever.METADATA_KEY_BITS_PER_SAMPLE)?.toLongOrNull(),
                mimeType = retriever.text(MediaMetadataRetriever.METADATA_KEY_MIMETYPE),
                artwork = retriever.embeddedPicture,
            )
        } catch (_: Exception) {
            RetrieverValues()
        } finally {
            retriever.release()
        }
    }

    private fun MediaMetadataRetriever.text(key: Int): String? =
        extractMetadata(key)?.trim()?.takeIf { it.isNotEmpty() && it != "<unknown>" }

    private fun number(value: String?): Int? = value
        ?.substringBefore('/')
        ?.trim()
        ?.toIntOrNull()
        ?.takeIf { it > 0 }
}

private data class RetrieverValues(
    val title: String? = null,
    val artist: String? = null,
    val albumArtist: String? = null,
    val album: String? = null,
    val year: Int? = null,
    val trackNumber: Int? = null,
    val discNumber: Int? = null,
    val durationMs: Long? = null,
    val bitrate: Long? = null,
    val sampleRate: Long? = null,
    val bitDepth: Long? = null,
    val mimeType: String? = null,
    val artwork: ByteArray? = null,
    val artworkMime: String? = null,
) {
    val isEmpty: Boolean
        get() = title == null && artist == null && album == null && durationMs == null
}

private data class CachedArtwork(val key: String, val path: String)

private class EmbeddedArtworkCache(context: Context) {
    private val directory = File(context.filesDir, "artwork/embedded")

    fun store(bytes: ByteArray, mime: String?): CachedArtwork {
        val key = MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString("") { "%02x".format(it) }
        val extension = when (mime?.lowercase()) {
            "image/png" -> "png"
            "image/webp" -> "webp"
            else -> "jpg"
        }
        directory.mkdirs()
        val target = File(directory, "$key.$extension")
        if (!target.exists()) target.writeBytes(bytes)
        return CachedArtwork(key, target.absolutePath)
    }
}
