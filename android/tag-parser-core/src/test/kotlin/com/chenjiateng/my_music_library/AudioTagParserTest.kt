package com.chenjiateng.my_music_library

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.nio.file.StandardOpenOption

class AudioTagParserTest {
    @Test
    fun sha256HashesStreamAndCountsBytes() {
        val result = Sha256StreamHasher.hash(ByteArrayInputStream("abc".toByteArray()))

        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            result.sha256,
        )
        assertEquals(3L, result.sizeBytes)
    }

    @Test
    fun flacReadsVorbisMetadataStreamInfoArtworkAndLyrics() {
        val artwork = byteArrayOf(1, 2, 3, 4, 5)
        val parsed = FlacTagParser.parse(ByteArrayInputStream(flacFixture(artwork)))

        assertEquals("借口", parsed.title)
        assertEquals("周杰伦", parsed.artist)
        assertEquals("周杰伦", parsed.albumArtist)
        assertEquals("七里香", parsed.album)
        assertEquals(2004, parsed.year)
        assertEquals(3, parsed.trackNumber)
        assertEquals(1, parsed.discNumber)
        assertEquals("[00:00.00]借口", parsed.lyrics)
        assertEquals(44100L, parsed.sampleRate)
        assertEquals(16L, parsed.bitDepth)
        assertEquals(10000L, parsed.durationMs)
        assertEquals("image/jpeg", parsed.artworkMime)
        assertArrayEquals(artwork, parsed.artwork)
    }

    @Test
    fun mp3ReadsId3TextArtworkAndLyrics() {
        val artwork = byteArrayOf(9, 8, 7, 6)
        val parsed = Id3TagParser.parse(ByteArrayInputStream(id3Fixture(artwork)))

        assertEquals("AIN'T A THING", parsed.title)
        assertEquals("Avicii", parsed.artist)
        assertEquals("Avicii", parsed.albumArtist)
        assertEquals("TIM", parsed.album)
        assertEquals(2019, parsed.year)
        assertEquals(2, parsed.trackNumber)
        assertEquals(1, parsed.discNumber)
        assertEquals("Line one", parsed.lyrics)
        assertEquals("image/jpeg", parsed.artworkMime)
        assertArrayEquals(artwork, parsed.artwork)
        assertTrue(parsed.tagFormat!!.startsWith("ID3v2"))
    }

    @Test
    fun wavReadsId3v24MetadataAndApicFromFileTail() {
        val artwork = byteArrayOf(5, 4, 3, 2, 1)
        val file = Files.createTempFile("harmony-wav-tail-id3", ".wav")
        try {
            Files.write(file, wavWithTailId3Fixture(artwork))
            val parsed = Files.newByteChannel(file, StandardOpenOption.READ).use(WavTagParser::parse)

            assertEquals("可爱女人", parsed.title)
            assertEquals("周杰伦", parsed.artist)
            assertEquals("周杰伦", parsed.albumArtist)
            assertEquals("Jay", parsed.album)
            assertEquals(2000, parsed.year)
            assertEquals(1, parsed.trackNumber)
            assertEquals(1, parsed.discNumber)
            assertEquals("[00:01.00]想要有直升机", parsed.lyrics)
            assertEquals("image/jpeg", parsed.artworkMime)
            assertArrayEquals(artwork, parsed.artwork)
            assertEquals("WAV/ID3v2.4", parsed.tagFormat)
            assertEquals("complete", parsed.readStatus)
        } finally {
            Files.deleteIfExists(file)
        }
    }

    private fun flacFixture(artwork: ByteArray): ByteArray {
        val output = ByteArrayOutputStream()
        output.write("fLaC".toByteArray())
        val streamInfo = ByteArray(34)
        val packed = (44100L shl 44) or (1L shl 41) or (15L shl 36) or 441000L
        for (index in 0..7) {
            streamInfo[17 - index] = ((packed ushr (index * 8)) and 0xff).toByte()
        }
        block(output, 0, streamInfo, false)
        val comments = listOf(
            "TITLE=借口",
            "ARTIST=周杰伦",
            "ALBUMARTIST=周杰伦",
            "ALBUM=七里香",
            "DATE=2004-08-03",
            "TRACKNUMBER=03/10",
            "DISCNUMBER=1",
            "LYRICS=[00:00.00]借口",
        )
        val commentBytes = ByteArrayOutputStream().also { bytes ->
            val buffer = DataOutputStream(bytes)
            writeLittleInt(buffer, 4)
            buffer.write("test".toByteArray())
            writeLittleInt(buffer, comments.size)
            for (comment in comments) {
                val value = comment.toByteArray(Charsets.UTF_8)
                writeLittleInt(buffer, value.size)
                buffer.write(value)
            }
        }.toByteArray()
        block(output, 4, commentBytes, false)
        val picture = ByteArrayOutputStream().also { bytes ->
            val buffer = DataOutputStream(bytes)
            buffer.writeInt(3)
            val mime = "image/jpeg".toByteArray()
            buffer.writeInt(mime.size)
            buffer.write(mime)
            buffer.writeInt(0)
            repeat(4) { buffer.writeInt(0) }
            buffer.writeInt(artwork.size)
            buffer.write(artwork)
        }.toByteArray()
        block(output, 6, picture, true)
        return output.toByteArray()
    }

    private fun id3Fixture(artwork: ByteArray): ByteArray {
        val frames = ByteArrayOutputStream()
        frame(frames, "TIT2", text("AIN'T A THING"))
        frame(frames, "TPE1", text("Avicii"))
        frame(frames, "TPE2", text("Avicii"))
        frame(frames, "TALB", text("TIM"))
        frame(frames, "TDRC", text("2019"))
        frame(frames, "TRCK", text("02/12"))
        frame(frames, "TPOS", text("1/1"))
        frame(
            frames,
            "USLT",
            byteArrayOf(3) + "eng".toByteArray() + byteArrayOf(0) + "Line one".toByteArray(),
        )
        frame(
            frames,
            "APIC",
            byteArrayOf(3) + "image/jpeg".toByteArray() + byteArrayOf(0, 3, 0) + artwork,
        )
        val body = frames.toByteArray()
        return ByteArrayOutputStream().also { output ->
            output.write("ID3".toByteArray())
            output.write(byteArrayOf(3, 0, 0))
            output.write(syncSafe(body.size))
            output.write(body)
        }.toByteArray()
    }

    private fun wavWithTailId3Fixture(artwork: ByteArray): ByteArray {
        val frames = ByteArrayOutputStream()
        frameV4(frames, "TIT2", text("可爱女人"))
        frameV4(frames, "TPE1", text("周杰伦"))
        frameV4(frames, "TPE2", text("周杰伦"))
        frameV4(frames, "TALB", text("Jay"))
        frameV4(frames, "TDRC", text("2000"))
        frameV4(frames, "TRCK", text("01/10"))
        frameV4(frames, "TPOS", text("1/1"))
        frameV4(
            frames,
            "USLT",
            byteArrayOf(3) + "zho".toByteArray() + byteArrayOf(0) +
                "[00:01.00]想要有直升机".toByteArray(),
        )
        frameV4(
            frames,
            "APIC",
            byteArrayOf(3) + "image/jpeg".toByteArray() + byteArrayOf(0, 3, 0) + artwork,
        )
        val body = frames.toByteArray()
        val id3 = ByteArrayOutputStream().also { output ->
            output.write("ID3".toByteArray())
            output.write(byteArrayOf(4, 0, 0x10))
            output.write(syncSafe(body.size))
            output.write(body)
            output.write("3DI".toByteArray())
            output.write(byteArrayOf(4, 0, 0x10))
            output.write(syncSafe(body.size))
        }.toByteArray()
        val pcm = ByteArray(256) { (it and 0xff).toByte() }
        return ByteArrayOutputStream().also { output ->
            output.write("RIFF".toByteArray())
            val riffSize = 4 + 8 + pcm.size + id3.size
            writeLittleInt(DataOutputStream(output), riffSize)
            output.write("WAVE".toByteArray())
            output.write("data".toByteArray())
            writeLittleInt(DataOutputStream(output), pcm.size)
            output.write(pcm)
            output.write(id3)
        }.toByteArray()
    }

    private fun text(value: String): ByteArray = byteArrayOf(3) + value.toByteArray(Charsets.UTF_8)

    private fun frame(output: ByteArrayOutputStream, id: String, payload: ByteArray) {
        val data = DataOutputStream(output)
        data.write(id.toByteArray())
        data.writeInt(payload.size)
        data.writeShort(0)
        data.write(payload)
    }

    private fun frameV4(output: ByteArrayOutputStream, id: String, payload: ByteArray) {
        output.write(id.toByteArray())
        output.write(syncSafe(payload.size))
        output.write(byteArrayOf(0, 0))
        output.write(payload)
    }

    private fun block(output: ByteArrayOutputStream, type: Int, bytes: ByteArray, last: Boolean) {
        output.write(type or if (last) 0x80 else 0)
        output.write((bytes.size ushr 16) and 0xff)
        output.write((bytes.size ushr 8) and 0xff)
        output.write(bytes.size and 0xff)
        output.write(bytes)
    }

    private fun writeLittleInt(output: DataOutputStream, value: Int) {
        output.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(value).array())
    }

    private fun syncSafe(value: Int): ByteArray = byteArrayOf(
        ((value ushr 21) and 0x7f).toByte(),
        ((value ushr 14) and 0x7f).toByte(),
        ((value ushr 7) and 0x7f).toByte(),
        (value and 0x7f).toByte(),
    )
}
