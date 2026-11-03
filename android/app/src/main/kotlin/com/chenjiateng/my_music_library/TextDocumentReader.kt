package com.chenjiateng.my_music_library

import android.content.Context
import android.net.Uri
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.nio.charset.Charset

internal class TextDocumentReader(context: Context) {
    private val resolver = context.contentResolver

    fun read(uriString: String): String {
        val uri = Uri.parse(uriString)
        val bytes = resolver.openInputStream(uri)?.use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            var total = 0
            while (true) {
                val count = input.read(buffer)
                if (count <= 0) break
                total += count
                require(total <= MAX_TEXT_BYTES) { "歌词文件超过 2 MB，已拒绝读取。" }
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        } ?: error("无法读取歌词文件。")
        return decode(bytes)
    }

    private fun decode(bytes: ByteArray): String {
        if (bytes.size >= 3 &&
            bytes[0] == 0xEF.toByte() &&
            bytes[1] == 0xBB.toByte() &&
            bytes[2] == 0xBF.toByte()
        ) {
            return String(bytes, 3, bytes.size - 3, StandardCharsets.UTF_8)
        }
        if (bytes.size >= 2 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xFE.toByte()) {
            return String(bytes, 2, bytes.size - 2, StandardCharsets.UTF_16LE)
        }
        if (bytes.size >= 2 && bytes[0] == 0xFE.toByte() && bytes[1] == 0xFF.toByte()) {
            return String(bytes, 2, bytes.size - 2, StandardCharsets.UTF_16BE)
        }
        return try {
            StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString()
        } catch (_: Exception) {
            String(bytes, Charset.forName("GB18030"))
        }
    }

    companion object {
        private const val MAX_TEXT_BYTES = 2 * 1024 * 1024
    }
}
