package com.chenjiateng.my_music_library

import android.content.Context
import android.net.Uri

internal class ContentHashReader(private val context: Context) {
    fun hash(request: Map<*, *>): Map<String, Any?> {
        val fileId = request["fileId"]?.toString().orEmpty()
        val uri = request["uri"]?.toString().orEmpty()
        val modifiedAt = (request["modifiedAt"] as? Number)?.toLong()
        return try {
            require(fileId.isNotBlank() && uri.isNotBlank())
            val result = context.contentResolver.openInputStream(Uri.parse(uri))?.use {
                Sha256StreamHasher.hash(it)
            } ?: error("无法打开音频文件")
            mapOf(
                "fileId" to fileId,
                "sha256" to result.sha256,
                "sizeBytes" to result.sizeBytes,
                "modifiedAt" to modifiedAt,
                "state" to "ready",
            )
        } catch (error: Exception) {
            mapOf(
                "fileId" to fileId,
                "sizeBytes" to ((request["sizeBytes"] as? Number)?.toLong() ?: 0L),
                "modifiedAt" to modifiedAt,
                "state" to "failed",
                "error" to (error.message ?: error.javaClass.simpleName),
            )
        }
    }
}
