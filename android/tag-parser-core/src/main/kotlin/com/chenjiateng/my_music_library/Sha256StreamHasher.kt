package com.chenjiateng.my_music_library

import java.io.InputStream
import java.security.MessageDigest

internal data class StreamHashResult(
    val sha256: String,
    val sizeBytes: Long,
)

internal object Sha256StreamHasher {
    private const val BUFFER_SIZE = 1024 * 1024

    fun hash(input: InputStream): StreamHashResult {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(BUFFER_SIZE)
        var total = 0L
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            if (count == 0) continue
            digest.update(buffer, 0, count)
            total += count
        }
        return StreamHashResult(
            sha256 = digest.digest().joinToString("") { "%02x".format(it) },
            sizeBytes = total,
        )
    }
}
