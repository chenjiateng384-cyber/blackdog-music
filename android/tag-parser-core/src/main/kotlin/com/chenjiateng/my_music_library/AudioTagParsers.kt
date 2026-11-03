package com.chenjiateng.my_music_library

import java.io.DataInputStream
import java.io.InputStream
import java.io.ByteArrayInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.Charset
import java.nio.channels.SeekableByteChannel

internal data class ParsedAudioTags(
    val title: String? = null,
    val artist: String? = null,
    val albumArtist: String? = null,
    val album: String? = null,
    val year: Int? = null,
    val trackNumber: Int? = null,
    val discNumber: Int? = null,
    val lyrics: String? = null,
    val artwork: ByteArray? = null,
    val artworkMime: String? = null,
    val sampleRate: Long? = null,
    val bitDepth: Long? = null,
    val durationMs: Long? = null,
    val tagFormat: String? = null,
    val readStatus: String = "complete",
)

internal object FlacTagParser {
    fun parse(input: InputStream): ParsedAudioTags {
        val stream = DataInputStream(input)
        val signature = ByteArray(4)
        stream.readFully(signature)
        require(signature.contentEquals("fLaC".toByteArray(Charsets.US_ASCII)))
        val comments = linkedMapOf<String, String>()
        var artwork: ByteArray? = null
        var artworkMime: String? = null
        var sampleRate: Long? = null
        var bitDepth: Long? = null
        var durationMs: Long? = null
        var last = false
        while (!last) {
            val header = stream.readUnsignedByte()
            last = header and 0x80 != 0
            val type = header and 0x7f
            val length = (stream.readUnsignedByte() shl 16) or
                (stream.readUnsignedByte() shl 8) or stream.readUnsignedByte()
            require(length in 0..(32 * 1024 * 1024))
            val block = ByteArray(length)
            stream.readFully(block)
            when (type) {
                0 -> if (block.size >= 18) {
                    var packed = 0L
                    for (index in 10..17) packed = (packed shl 8) or (block[index].toLong() and 0xff)
                    sampleRate = (packed ushr 44) and 0xfffff
                    bitDepth = ((packed ushr 36) and 0x1f) + 1
                    val totalSamples = packed and 0xfffffffffL
                    val rate = sampleRate
                    if (rate > 0) durationMs = totalSamples * 1000 / rate
                }
                4 -> comments.putAll(parseVorbisComments(block))
                6 -> parsePicture(block)?.let {
                    artwork = it.first
                    artworkMime = it.second
                }
            }
        }
        return ParsedAudioTags(
            title = comments["TITLE"],
            artist = comments["ARTIST"],
            albumArtist = comments["ALBUMARTIST"] ?: comments["ALBUM ARTIST"],
            album = comments["ALBUM"],
            year = parseYear(comments["DATE"] ?: comments["YEAR"]),
            trackNumber = parseNumber(comments["TRACKNUMBER"]),
            discNumber = parseNumber(comments["DISCNUMBER"]),
            lyrics = comments["LYRICS"] ?: comments["UNSYNCEDLYRICS"],
            artwork = artwork,
            artworkMime = artworkMime,
            sampleRate = sampleRate,
            bitDepth = bitDepth,
            durationMs = durationMs,
            tagFormat = "FLAC/VorbisComment",
            readStatus = if (comments.isEmpty()) "partial" else "complete",
        )
    }

    private fun parseVorbisComments(bytes: ByteArray): Map<String, String> {
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val result = linkedMapOf<String, String>()
        if (buffer.remaining() < 4) return result
        val vendorLength = buffer.int
        if (vendorLength < 0 || vendorLength > buffer.remaining()) return result
        buffer.position(buffer.position() + vendorLength)
        if (buffer.remaining() < 4) return result
        val count = buffer.int.coerceIn(0, 10000)
        repeat(count) {
            if (buffer.remaining() < 4) return@repeat
            val length = buffer.int
            if (length < 0 || length > buffer.remaining()) return@repeat
            val value = ByteArray(length)
            buffer.get(value)
            val text = value.toString(Charsets.UTF_8)
            val separator = text.indexOf('=')
            if (separator > 0) {
                val key = text.substring(0, separator).uppercase()
                result.putIfAbsent(key, text.substring(separator + 1).trim())
            }
        }
        return result
    }

    private fun parsePicture(bytes: ByteArray): Pair<ByteArray, String?>? {
        return try {
            val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
            buffer.int
            val mimeLength = buffer.int
            require(mimeLength in 0..buffer.remaining())
            val mimeBytes = ByteArray(mimeLength)
            buffer.get(mimeBytes)
            val descriptionLength = buffer.int
            require(descriptionLength in 0..buffer.remaining())
            buffer.position(buffer.position() + descriptionLength)
            repeat(4) { buffer.int }
            val dataLength = buffer.int
            require(dataLength in 1..buffer.remaining())
            val data = ByteArray(dataLength)
            buffer.get(data)
            Pair(data, mimeBytes.toString(Charsets.US_ASCII).ifBlank { null })
        } catch (_: Exception) {
            null
        }
    }
}

internal object Id3TagParser {
    fun parse(input: InputStream): ParsedAudioTags {
        val stream = DataInputStream(input)
        val header = ByteArray(10)
        stream.readFully(header)
        require(header.copyOfRange(0, 3).contentEquals("ID3".toByteArray(Charsets.US_ASCII)))
        val version = header[3].toInt() and 0xff
        require(version == 3 || version == 4)
        val tagSize = syncSafe(header, 6)
        require(tagSize in 0..(32 * 1024 * 1024))
        val tag = ByteArray(tagSize)
        stream.readFully(tag)
        var position = 0
        val values = linkedMapOf<String, String>()
        var lyrics: String? = null
        var artwork: ByteArray? = null
        var artworkMime: String? = null
        while (position + 10 <= tag.size) {
            val id = tag.copyOfRange(position, position + 4).toString(Charsets.US_ASCII)
            if (id.all { it == '\u0000' }) break
            val size = if (version == 4) syncSafe(tag, position + 4) else bigEndianInt(tag, position + 4)
            position += 10
            if (size <= 0 || position + size > tag.size) break
            val payload = tag.copyOfRange(position, position + size)
            position += size
            when {
                id.startsWith("T") && id != "TXXX" -> decodeText(payload)?.let { values[id] = it }
                id == "USLT" -> lyrics = decodeUnsynchronisedLyrics(payload)
                id == "APIC" -> parseApic(payload)?.let {
                    artwork = it.first
                    artworkMime = it.second
                }
            }
        }
        return ParsedAudioTags(
            title = values["TIT2"],
            artist = values["TPE1"],
            albumArtist = values["TPE2"],
            album = values["TALB"],
            year = parseYear(values["TDRC"] ?: values["TYER"]),
            trackNumber = parseNumber(values["TRCK"]),
            discNumber = parseNumber(values["TPOS"]),
            lyrics = lyrics,
            artwork = artwork,
            artworkMime = artworkMime,
            tagFormat = "ID3v2.$version",
            readStatus = if (values.isEmpty()) "partial" else "complete",
        )
    }

    private fun decodeText(payload: ByteArray): String? {
        if (payload.isEmpty()) return null
        return decode(payload.copyOfRange(1, payload.size), payload[0].toInt())
            .trim('\u0000', ' ', '\r', '\n')
            .substringBefore('\u0000')
            .takeIf { it.isNotBlank() }
    }

    private fun decodeUnsynchronisedLyrics(payload: ByteArray): String? {
        if (payload.size < 4) return null
        val encoding = payload[0].toInt()
        val body = payload.copyOfRange(4, payload.size)
        val terminator = terminatorEnd(body, encoding)
        val lyricsStart = terminator.coerceAtMost(body.size)
        return decode(body.copyOfRange(lyricsStart, body.size), encoding)
            .trim('\u0000', ' ', '\r', '\n')
            .takeIf { it.isNotBlank() }
    }

    private fun parseApic(payload: ByteArray): Pair<ByteArray, String?>? {
        if (payload.size < 5) return null
        return try {
            val encoding = payload[0].toInt()
            var position = 1
            val mimeEnd = indexOfZero(payload, position)
            if (mimeEnd < 0) return null
            val mime = payload.copyOfRange(position, mimeEnd).toString(Charsets.ISO_8859_1)
            position = mimeEnd + 2
            position += terminatorEnd(payload.copyOfRange(position, payload.size), encoding)
            if (position >= payload.size) return null
            Pair(payload.copyOfRange(position, payload.size), mime.ifBlank { null })
        } catch (_: Exception) {
            null
        }
    }

    private fun decode(bytes: ByteArray, encoding: Int): String {
        val charset: Charset = when (encoding) {
            1 -> Charsets.UTF_16
            2 -> Charsets.UTF_16BE
            3 -> Charsets.UTF_8
            else -> Charsets.ISO_8859_1
        }
        return bytes.toString(charset)
    }

    private fun terminatorEnd(bytes: ByteArray, encoding: Int): Int {
        val wide = encoding == 1 || encoding == 2
        if (wide) {
            var index = 0
            while (index + 1 < bytes.size) {
                if (bytes[index].toInt() == 0 && bytes[index + 1].toInt() == 0) return index + 2
                index += 2
            }
        } else {
            val index = bytes.indexOf(0)
            if (index >= 0) return index + 1
        }
        return 0
    }
}

/**
 * Reads ID3v2 metadata appended to a RIFF/WAVE file.
 *
 * Mutagen and other modern taggers commonly store the ID3 block after the
 * audio data instead of in a RIFF INFO chunk. The footer path is O(1); the
 * bounded backwards scan is only a compatibility fallback for tags without
 * an ID3v2.4 footer.
 */
internal object WavTagParser {
    private const val maxTagBytes = 32 * 1024 * 1024
    private const val fallbackSearchBytes = 16 * 1024 * 1024

    fun parse(channel: SeekableByteChannel): ParsedAudioTags {
        val fileSize = channel.size()
        if (fileSize < 12) return partial()
        val riff = readAt(channel, 0, 12) ?: return partial()
        val container = riff.copyOfRange(0, 4).toString(Charsets.US_ASCII)
        val wave = riff.copyOfRange(8, 12).toString(Charsets.US_ASCII)
        if ((container != "RIFF" && container != "RF64") || wave != "WAVE") {
            return partial()
        }

        locateFromFooter(channel, fileSize)?.let { located ->
            parseAt(channel, located)?.let { return it }
        }

        val searchLength = minOf(fileSize - 12, fallbackSearchBytes.toLong()).toInt()
        if (searchLength < 10) return partial()
        val searchStart = fileSize - searchLength
        val tail = readAt(channel, searchStart, searchLength) ?: return partial()
        for (index in tail.size - 10 downTo 0) {
            if (tail[index] != 'I'.code.toByte() ||
                tail[index + 1] != 'D'.code.toByte() ||
                tail[index + 2] != '3'.code.toByte()
            ) continue
            val tagLength = declaredTagLength(tail, index) ?: continue
            val absoluteOffset = searchStart + index
            if (absoluteOffset + tagLength > fileSize) continue
            parseAt(channel, LocatedTag(absoluteOffset, tagLength))?.let { return it }
        }
        return partial()
    }

    private fun locateFromFooter(
        channel: SeekableByteChannel,
        fileSize: Long,
    ): LocatedTag? {
        // A RIFF chunk may end with one alignment byte, while a few writers
        // leave small trailing padding. Checking 16 bytes keeps this path
        // constant-time without assuming the footer is the literal last byte.
        for (trailingBytes in 0..16) {
            val footerOffset = fileSize - trailingBytes - 10
            if (footerOffset < 12) break
            val footer = readAt(channel, footerOffset, 10) ?: continue
            if (!footer.copyOfRange(0, 3).contentEquals("3DI".toByteArray(Charsets.US_ASCII))) {
                continue
            }
            val bodySize = syncSafeOrNull(footer, 6) ?: continue
            if (bodySize !in 0..maxTagBytes) continue
            val tagLength = 10 + bodySize
            val tagOffset = footerOffset - tagLength
            if (tagOffset < 12) continue
            val header = readAt(channel, tagOffset, 10) ?: continue
            if (declaredTagLength(header, 0) == tagLength) {
                return LocatedTag(tagOffset, tagLength)
            }
        }
        return null
    }

    private fun parseAt(
        channel: SeekableByteChannel,
        located: LocatedTag,
    ): ParsedAudioTags? {
        if (located.length !in 10..(maxTagBytes + 10)) return null
        val bytes = readAt(channel, located.offset, located.length) ?: return null
        return runCatching { Id3TagParser.parse(ByteArrayInputStream(bytes)) }
            .getOrNull()
            ?.let { parsed ->
                parsed.copy(tagFormat = "WAV/${parsed.tagFormat ?: "ID3"}")
            }
    }

    private fun declaredTagLength(bytes: ByteArray, offset: Int): Int? {
        if (offset < 0 || offset + 10 > bytes.size) return null
        if (!bytes.copyOfRange(offset, offset + 3)
                .contentEquals("ID3".toByteArray(Charsets.US_ASCII))
        ) return null
        val version = bytes[offset + 3].toInt() and 0xff
        if (version != 3 && version != 4) return null
        val bodySize = syncSafeOrNull(bytes, offset + 6) ?: return null
        if (bodySize !in 0..maxTagBytes) return null
        return 10 + bodySize
    }

    private fun syncSafeOrNull(bytes: ByteArray, offset: Int): Int? {
        if (offset < 0 || offset + 4 > bytes.size) return null
        if ((0..3).any { bytes[offset + it].toInt() and 0x80 != 0 }) return null
        return syncSafe(bytes, offset)
    }

    private fun readAt(
        channel: SeekableByteChannel,
        offset: Long,
        length: Int,
    ): ByteArray? {
        if (offset < 0 || length < 0) return null
        val buffer = ByteBuffer.allocate(length)
        channel.position(offset)
        while (buffer.hasRemaining()) {
            if (channel.read(buffer) < 0) return null
        }
        return buffer.array()
    }

    private fun partial() = ParsedAudioTags(tagFormat = "WAV", readStatus = "partial")

    private data class LocatedTag(val offset: Long, val length: Int)
}

private fun syncSafe(bytes: ByteArray, offset: Int): Int =
    ((bytes[offset].toInt() and 0x7f) shl 21) or
        ((bytes[offset + 1].toInt() and 0x7f) shl 14) or
        ((bytes[offset + 2].toInt() and 0x7f) shl 7) or
        (bytes[offset + 3].toInt() and 0x7f)

private fun bigEndianInt(bytes: ByteArray, offset: Int): Int =
    ((bytes[offset].toInt() and 0xff) shl 24) or
        ((bytes[offset + 1].toInt() and 0xff) shl 16) or
        ((bytes[offset + 2].toInt() and 0xff) shl 8) or
        (bytes[offset + 3].toInt() and 0xff)

private fun indexOfZero(bytes: ByteArray, start: Int): Int {
    for (index in start until bytes.size) {
        if (bytes[index].toInt() == 0) return index
    }
    return -1
}

private fun parseYear(value: String?): Int? = Regex("(?:19|20)\\d{2}")
    .find(value.orEmpty())
    ?.value
    ?.toIntOrNull()

private fun parseNumber(value: String?): Int? = value
    ?.substringBefore('/')
    ?.trim()
    ?.toIntOrNull()
    ?.takeIf { it > 0 }
