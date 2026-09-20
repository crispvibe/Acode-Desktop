package com.codevoke.android.data

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit
import kotlin.coroutines.coroutineContext

/** GitHub Releases 上发现的可更新版本。 */
data class AppUpdateInfo(
    /// 原始 tag，如 "v0.4.0"。
    val tag: String,
    /// 归一化后的版本号（去 v 前缀），用于展示。
    val version: String,
    /// release notes 原文（markdown）。
    val notes: String,
    /// release 页面地址。
    val pageUrl: String,
    /// 安卓 APK asset 的下载地址；该 release 没带 APK 时为 null。
    val apkUrl: String?,
    val apkName: String?,
    val apkSizeBytes: Long,
)

/**
 * 语义化版本比较（纯函数）：去 v/V 前缀、忽略 +build 元数据、
 * 数字段逐段比较、缺段补 0；core 相同则带 prerelease 的版本更小，
 * prerelease 之间按 semver 规则（数字<字母串、段多者大）比较。
 */
object AppVersions {
    fun compare(a: String, b: String): Int {
        val pa = parse(a)
        val pb = parse(b)
        val size = maxOf(pa.core.size, pb.core.size)
        for (i in 0 until size) {
            val x = pa.core.getOrElse(i) { 0 }
            val y = pb.core.getOrElse(i) { 0 }
            if (x != y) return x.compareTo(y)
        }
        return comparePrerelease(pa.prerelease, pb.prerelease)
    }

    /** remote 版本是否比 local 新。 */
    fun isNewer(remote: String, local: String): Boolean = compare(remote, local) > 0

    private data class Parsed(val core: List<Int>, val prerelease: String?)

    private fun parse(version: String): Parsed {
        var s = version.trim()
        if (s.startsWith("v") || s.startsWith("V")) s = s.substring(1)
        s = s.substringBefore('+')
        val core = s.substringBefore('-')
        val prerelease = s.substringAfter('-', "").ifBlank { null }
        val nums = core.split('.')
            .map { segment -> segment.trim().takeWhile(Char::isDigit).toIntOrNull() ?: 0 }
        return Parsed(nums, prerelease)
    }

    private fun comparePrerelease(a: String?, b: String?): Int {
        if (a == null && b == null) return 0
        if (a == null) return 1 // 正式版 > 预发布版
        if (b == null) return -1
        val ai = a.split('.')
        val bi = b.split('.')
        val size = maxOf(ai.size, bi.size)
        for (i in 0 until size) {
            val x = ai.getOrNull(i) ?: return -1
            val y = bi.getOrNull(i) ?: return 1
            val xn = x.toIntOrNull()
            val yn = y.toIntOrNull()
            val c = when {
                xn != null && yn != null -> xn.compareTo(yn)
                xn != null -> -1 // semver：数字标识符 < 字母数字标识符
                yn != null -> 1
                else -> x.compareTo(y)
            }
            if (c != 0) return c
        }
        return 0
    }
}

/**
 * GitHub Releases 版本检查与 APK 下载（无服务器，纯 GitHub）。
 * 所有函数失败返回 null/抛异常由调用方决定提示；启动静默检查直接忽略失败。
 */
object AppUpdateClient {
    private const val LATEST_RELEASE_API =
        "https://api.github.com/repos/crispvibe/Acode-Desktop/releases/latest"
    const val RELEASE_PAGE_URL = "https://github.com/crispvibe/Acode-Desktop/releases/latest"
    private const val ANDROID_ASSET_NAME = "acode-android-debug.apk"

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    /** 拉取最新 release；网络失败/无 release 返回 null。draft/prerelease 不算可更新版本。 */
    suspend fun fetchLatestRelease(): AppUpdateInfo? = withContext(Dispatchers.IO) {
        runCatching {
            val request = Request.Builder()
                .url(LATEST_RELEASE_API)
                .header("Accept", "application/vnd.github+json")
                .header("User-Agent", "acode-android")
                .build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@use null
                val json = JSONObject(response.body?.string().orEmpty())
                if (json.optBoolean("draft") || json.optBoolean("prerelease")) return@use null
                val tag = json.optString("tag_name").trim()
                if (tag.isBlank()) return@use null
                var apkUrl: String? = null
                var apkName: String? = null
                var apkSize = 0L
                val assets = json.optJSONArray("assets")
                if (assets != null) {
                    for (i in 0 until assets.length()) {
                        val asset = assets.optJSONObject(i) ?: continue
                        if (asset.optString("name") == ANDROID_ASSET_NAME) {
                            apkUrl = asset.optString("browser_download_url").ifBlank { null }
                            apkName = asset.optString("name")
                            apkSize = asset.optLong("size", 0L)
                            break
                        }
                    }
                }
                AppUpdateInfo(
                    tag = tag,
                    version = tag.removePrefix("v").removePrefix("V"),
                    notes = json.optString("body").orEmpty(),
                    pageUrl = json.optString("html_url").ifBlank { RELEASE_PAGE_URL },
                    apkUrl = apkUrl,
                    apkName = apkName,
                    apkSizeBytes = apkSize,
                )
            }
        }.getOrNull()
    }

    /** 有更新版本时返回其信息，否则 null；失败也返回 null（静默）。 */
    suspend fun checkForUpdate(currentVersion: String): AppUpdateInfo? {
        val latest = fetchLatestRelease() ?: return null
        return if (AppVersions.isNewer(latest.tag, currentVersion)) latest else null
    }

    /**
     * 流式下载 APK 到 cacheDir/updates/，onProgress 回传 0f..1f（长度未知时为 -1 不进度的累积字节）。
     * 返回落盘文件；失败抛异常并清掉半成品文件。
     */
    suspend fun downloadApk(
        context: Context,
        info: AppUpdateInfo,
        onProgress: (bytesSoFar: Long, totalBytes: Long) -> Unit,
    ): File = withContext(Dispatchers.IO) {
        val url = info.apkUrl ?: throw RemoteApiException("该版本没有提供安卓安装包。")
        val dir = File(context.cacheDir, "updates").apply { mkdirs() }
        // 清掉旧版本安装包，避免占用缓存。
        dir.listFiles()?.forEach { it.delete() }
        val dest = File(dir, "acode-${info.version}.apk")
        val request = Request.Builder()
            .url(url)
            .header("User-Agent", "acode-android")
            .build()
        try {
            client.newBuilder().readTimeout(0, TimeUnit.SECONDS).build()
                .newCall(request).execute().use { response ->
                    if (!response.isSuccessful) {
                        throw RemoteApiException("下载失败：${response.code}")
                    }
                    val body = response.body ?: throw RemoteApiException("下载响应为空。")
                    val total = body.contentLength().takeIf { it > 0 } ?: info.apkSizeBytes
                    body.byteStream().use { input ->
                        dest.outputStream().use { output ->
                            val buffer = ByteArray(64 * 1024)
                            var soFar = 0L
                            while (true) {
                                coroutineContext.ensureActive()
                                val read = input.read(buffer)
                                if (read < 0) break
                                output.write(buffer, 0, read)
                                soFar += read
                                onProgress(soFar, total)
                            }
                        }
                    }
                }
            dest
        } catch (error: Throwable) {
            dest.delete()
            throw error
        }
    }
}

/** APK 安装：FileProvider 授权 + 系统安装器。 */
object AppUpdateInstaller {
    fun canRequestInstalls(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            context.packageManager.canRequestPackageInstalls()

    /** 跳系统"允许安装未知应用"授权页。 */
    fun openInstallPermissionSettings(context: Context) {
        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:${context.packageName}"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    /** 用系统安装器打开已下载的 APK。 */
    fun installApk(context: Context, apk: File) {
        val uri: Uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            apk,
        )
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }
}
