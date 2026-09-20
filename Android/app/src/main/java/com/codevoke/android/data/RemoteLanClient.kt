package com.codevoke.android.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.net.URLEncoder
import java.util.Base64
import java.util.concurrent.TimeUnit

class RemoteApiException(message: String) : Exception(message)

class RemoteLanClient(
    private val config: RemoteChatConfig,
    private val client: OkHttpClient = defaultClient,
) {
    companion object {
        private val defaultClient = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(20, TimeUnit.SECONDS)
            .build()
    }

    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()

    suspend fun health(): Boolean = withContext(Dispatchers.IO) {
        if (!config.supportsDirectHttp) return@withContext false
        val request = Request.Builder().url("${config.baseUrl}/health").build()
        client.newCall(request).execute().use { it.isSuccessful }
    }

    suspend fun uploadAttachment(filename: String, data: ByteArray): RemoteAttachmentUploadResponse = withContext(Dispatchers.IO) {
        if (!config.supportsDirectHttp) throw RemoteApiException("远程连接暂不支持附件上传，请在同一局域网连接后使用。")
        val payload = JSONObject()
            .put("filename", filename)
            .put("contentBase64", Base64.getEncoder().encodeToString(data))
        val request = Request.Builder()
            .url("${config.baseUrl}/attachments")
            .post(payload.toString().toRequestBody(jsonMediaType))
            .build()
        client.newCall(request).execute().use { response ->
            val raw = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                val message = runCatching { JSONObject(raw).optString("message") }.getOrNull().orEmpty()
                throw RemoteApiException(message.ifBlank { "附件上传失败：${response.code}" })
            }
            JSONObject(raw).toAttachmentUploadResponse()
        }
    }

    suspend fun projectFiles(projectId: String, path: String): RemoteProjectFiles = withContext(Dispatchers.IO) {
        if (!config.supportsDirectHttp) throw RemoteApiException("远程连接暂不支持文件树浏览，请在同一局域网连接后使用。")
        val encoded = URLEncoder.encode(path, "UTF-8")
        val request = Request.Builder()
            .url("${config.baseUrl}/projects/$projectId/files?path=$encoded")
            .build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw RemoteApiException("文件列表加载失败：${response.code}")
            val json = JSONObject(response.body?.string().orEmpty())
            RemoteProjectFiles(
                projectId = json.optString("projectId"),
                path = json.optString("path"),
                parentPath = json.stringOrNull("parentPath"),
                entries = json.optJSONArray("entries")?.objects()?.map {
                    RemoteFileEntry(
                        name = it.optString("name"),
                        relativePath = it.optString("relativePath"),
                        isDirectory = it.optBoolean("isDirectory"),
                    )
                }.orEmpty(),
            )
        }
    }
}
