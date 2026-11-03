package com.chenjiateng.my_music_library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardOpenOption

class RealLibraryAcceptanceTest {
    @Test
    fun realJayGemAndEnglishDirectoriesAreReadableAndHashable() {
        val root = File(System.getProperty("realMusicRoot", ""))
        assumeTrue("需要 -DrealMusicRoot 指向真实音乐目录", root.isDirectory)

        for (artist in artists) {
            val directory = File(root, artist)
            assertTrue("缺少真实目录：$artist", directory.isDirectory)
            val audio = directory.walkTopDown()
                .filter { it.isFile && it.extension.lowercase() in audioExtensions }
                .toList()
            val lyrics = directory.walkTopDown()
                .count { it.isFile && it.extension.equals("lrc", ignoreCase = true) }
            assertTrue("$artist 没有真实音频", audio.isNotEmpty())
            assertTrue("$artist 没有真实歌词", lyrics > 0)
            val sample = audio.minBy { it.length() }
            val first = sample.inputStream().buffered().use(Sha256StreamHasher::hash)
            val second = sample.inputStream().buffered().use(Sha256StreamHasher::hash)
            assertEquals(sample.length(), first.sizeBytes)
            assertEquals(first, second)
            assertEquals(64, first.sha256.length)
            println("$artist native hash: ${sample.name} ${first.sha256.take(12)}…")
        }
    }

    @Test
    fun realFlacAndMp3TagsCanBeReadFromTheLibrary() {
        val root = File(System.getProperty("realMusicRoot", ""))
        assumeTrue("需要 -DrealMusicRoot 指向真实音乐目录", root.isDirectory)

        val jayFlac = firstReadableTags(File(root, "周杰伦"), "flac", FlacTagParser::parse)
        val englishFlac = firstReadableTags(File(root, "英文歌"), "flac", FlacTagParser::parse)
        val mp3 = sequenceOf(File(root, "邓紫棋"), File(root, "周杰伦"), File(root, "英文歌"))
            .mapNotNull { firstReadableTags(it, "mp3", Id3TagParser::parse) }
            .firstOrNull()

        assertNotNull("真实周杰伦 FLAC 中未找到可读标签", jayFlac)
        assertNotNull("真实英文歌 FLAC 中未找到可读标签", englishFlac)
        assertNotNull("真实音乐库 MP3 中未找到可读 ID3 标签", mp3)
        println("real FLAC/MP3 tags: ${jayFlac?.title}, ${englishFlac?.title}, ${mp3?.title}")
    }

    @Test
    fun realWavTailId3ArtworkCanBeReadFromTheLibrary() {
        val root = File(System.getProperty("realMusicRoot", ""))
        assumeTrue("需要 -DrealMusicRoot 指向真实音乐目录", root.isDirectory)

        val wav = root.walkTopDown()
            .filter { it.isFile && it.extension.equals("wav", ignoreCase = true) }
            .mapNotNull { file ->
                runCatching {
                    Files.newByteChannel(file.toPath(), StandardOpenOption.READ).use(WavTagParser::parse)
                }.getOrNull()?.let { parsed -> file to parsed }
            }
            .firstOrNull { (_, parsed) ->
                parsed.title != null && parsed.artist != null &&
                    parsed.album != null && parsed.artwork?.isNotEmpty() == true
            }

        assertNotNull("真实 WAV 中未找到可读取的尾部 ID3 与 APIC 封面", wav)
        assertEquals("complete", wav?.second?.readStatus)
        assertTrue(wav?.second?.tagFormat?.startsWith("WAV/ID3v2") == true)
        println(
            "real WAV tail ID3: ${wav?.first?.name}, ${wav?.second?.title}, " +
                "artwork=${wav?.second?.artwork?.size}",
        )
    }

    private fun firstReadableTags(
        directory: File,
        extension: String,
        parser: (java.io.InputStream) -> ParsedAudioTags,
    ): ParsedAudioTags? = directory.walkTopDown()
        .filter { it.isFile && it.extension.equals(extension, ignoreCase = true) }
        .mapNotNull { file ->
            runCatching { file.inputStream().buffered().use(parser) }.getOrNull()
        }
        .firstOrNull { it.title != null || it.artist != null || it.album != null }

    companion object {
        private val artists = listOf("周杰伦", "邓紫棋", "英文歌")
        private val audioExtensions = setOf("flac", "mp3", "wav", "m4a", "aac", "ogg", "opus")
    }
}
