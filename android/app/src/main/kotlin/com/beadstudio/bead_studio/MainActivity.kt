package com.beadstudio.bead_studio

import android.content.ContentValues
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.GZIPInputStream
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/// 自建 OCR 通道（bead_native_ocr）：位图构造 + ML Kit 推理整体挪到后台
/// 单线程 executor。google_mlkit 插件的 MethodChannel handler 固定在平台
/// 线程执行（InputImageConverter.createBitmapFromRawData 逐像素 Kotlin 循环
/// + 推理回调），本 app 平台线程与 UI isolate 合并——每次 processImage 主
/// 线程 100% 冻结（2026-11-03 模拟器实测：识别全程 6s 主线程满载，ML Kit
/// 自带线程池全程空闲）。Dart 侧 lib/core/native_ocr.dart 桥接，通道不可用
/// 时回退插件原路径。
class MainActivity : FlutterActivity() {
    private val ocrExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    ///< ML Kit 推理专用线程：options 不 setExecutor 时推理任务回落主线程
    ///< （实测识别全程主线程满载 5s+），指定后与 ocrExecutor 分离——
    ///< ocrExecutor park 在 Tasks.await 等推理结果，不能共用同一线程（自锁）
    private val mlkitExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var recognizer: com.google.mlkit.vision.text.TextRecognizer? = null
    private var channel: MethodChannel? = null

    private fun recognizer(): com.google.mlkit.vision.text.TextRecognizer =
        recognizer ?: TextRecognition.getClient(
            TextRecognizerOptions.Builder().setExecutor(mlkitExecutor).build()
        ).also { recognizer = it }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bead_native_ocr")
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                // 从临时文件读原始 RGBA（宽度/高度随参数传）：大段字节不进
                // Dart 主 isolate，避免 compute 出参在主线程反序列化二次冻结
                "processRgbaFile" -> {
                    val path = call.argument<String>("path")
                    val w = call.argument<Int>("width") ?: 0
                    val h = call.argument<Int>("height") ?: 0
                    if (path == null || w <= 0 || h <= 0) {
                        result.error("badArgs", "path/width/height required", null)
                        return@setMethodCallHandler
                    }
                    runOcr(result) { fileRgba(path, w, h) }
                }
                // 直接喂内存 RGBA（救援链小区变体图）：字节数小，直传即可
                "processRgba" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val w = call.argument<Int>("width") ?: 0
                    val h = call.argument<Int>("height") ?: 0
                    if (bytes == null || w <= 0 || h <= 0) {
                        result.error("badArgs", "bytes/width/height required", null)
                        return@setMethodCallHandler
                    }
                    runOcr(result) { Pair(bytes, Pair(w, h)) }
                }
                // 磁盘图片文件（PNG/JPEG）：解码也放后台（复核单格路径，
                // PNG 已在 isolate 编码落盘，主线程只传路径）
                "processImageFile" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("badArgs", "path required", null)
                        return@setMethodCallHandler
                    }
                    ocrExecutor.execute {
                        try {
                            val bmp = android.graphics.BitmapFactory.decodeFile(path)
                                ?: throw IllegalArgumentException("decode failed: $path")
                            val text = Tasks.await(
                                recognizer().process(InputImage.fromBitmap(bmp, 0))
                            )
                            mainHandler.post { result.success(flatten(text)) }
                        } catch (e: Exception) {
                            mainHandler.post { result.error("ocrError", e.toString(), null) }
                        }
                    }
                }
                "close" -> {
                    ocrExecutor.execute {
                        recognizer?.close()
                        recognizer = null
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // 相册保存通道（bead_gallery_save）：小红书原图查看页右上角下载用。
        // Q+ 走 MediaStore 免权限（Pictures/bead_studio），Q 以下 legacy
        // 公共目录 + 媒体扫描广播，尽力而为。写盘挪到后台 executor。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bead_gallery_save")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveImage" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        val name = call.argument<String>("displayName")
                        val mime = call.argument<String>("mimeType")
                        if (bytes == null || name == null || mime == null) {
                            result.error("badArgs", "bytes/displayName/mimeType required", null)
                            return@setMethodCallHandler
                        }
                        ocrExecutor.execute {
                            try {
                                val saved = saveToGallery(bytes, name, mime)
                                mainHandler.post { result.success(saved) }
                            } catch (e: Exception) {
                                mainHandler.post { result.error("saveError", e.toString(), null) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        // 笔记页抓取通道（bead_native_fetch）：HttpURLConnection/Conscrypt。
        // 小红书按 TLS 指纹分流，Dart HttpClient（BoringSSL 极简 ClientHello）
        // 只拿得到无数据壳页（实测 37KB 无 imageList），Conscrypt 拿全量
        // SSR 页（81KB）。图片 CDN 不看指纹，下载仍在 Dart http。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bead_native_fetch")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "get" -> {
                        val url = call.argument<String>("url")
                        val ua = call.argument<String>("userAgent")
                        val referer = call.argument<String>("referer")
                        if (url == null) {
                            result.error("badArgs", "url required", null)
                            return@setMethodCallHandler
                        }
                        ocrExecutor.execute {
                            try {
                                val (code, body) = httpGet(url, ua, referer)
                                mainHandler.post {
                                    result.success(mapOf("status" to code, "body" to body))
                                }
                            } catch (e: Exception) {
                                android.util.Log.e("XhsFetch", "native get failed", e)
                                mainHandler.post {
                                    result.error("fetchError", e.toString(), null)
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// 原生 GET（手动逐跳重定向——内建跟随在跨主机跳转时可能丢自定义头，
    /// UA 一丢就被小红书分流到无数据壳页），返回 (状态码, 文本)
    private fun httpGet(
        url: String,
        userAgent: String?,
        referer: String?,
    ): Pair<Int, String> {
        var current = url
        var code = 0
        var conn: HttpURLConnection? = null
        try {
            for (hop in 0 until 5) {
                conn = URL(current).openConnection() as HttpURLConnection
                conn.connectTimeout = 15000
                conn.readTimeout = 20000
                conn.instanceFollowRedirects = false
                userAgent?.let { conn.setRequestProperty("User-Agent", it) }
                referer?.let { conn.setRequestProperty("Referer", it) }
                code = conn.responseCode
                if (code in 300..399) {
                    val location = conn.getHeaderField("Location")
                    // 排干跳转响应体再断开，避免底层连接池状态污染
                    try {
                        conn.inputStream?.close()
                    } catch (_: Exception) {
                    }
                    conn.disconnect()
                    conn = null
                    if (location.isNullOrBlank()) {
                        break
                    }
                    current = URL(URL(current), location).toString()
                    continue
                }
                break
            }
            // 2xx/4xx/5xx：读完整正文（Android 会自动加 Accept-Encoding:gzip
            // 并透明解压，getContentEncoding 那时为 null，无需手动 GZIP）
            val c = conn ?: throw IllegalStateException("redirect loop exhausted")
            val stream = if (code in 200..299) c.inputStream
            else c.errorStream ?: c.inputStream
            val body = stream!!.bufferedReader(Charsets.UTF_8).use { it.readText() }
            return Pair(code, body)
        } finally {
            conn?.disconnect()
        }
    }

    /// 保存图片字节到系统相册，成功返回显示名
    private fun saveToGallery(bytes: ByteArray, displayName: String, mime: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
                put(MediaStore.Images.Media.MIME_TYPE, mime)
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/bead_studio")
            }
            val uri = contentResolver.insert(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values
            ) ?: throw IllegalStateException("MediaStore insert failed")
            contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                ?: throw IllegalStateException("openOutputStream failed")
            return displayName
        }
        @Suppress("DEPRECATION")
        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
            "bead_studio"
        )
        dir.mkdirs()
        val f = File(dir, displayName)
        f.writeBytes(bytes)
        // 触发媒体扫描，相册立刻可见（老路径专用）
        @Suppress("DEPRECATION")
        sendBroadcast(
            Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE, Uri.fromFile(f))
        )
        return displayName
    }

    private fun fileRgba(path: String, w: Int, h: Int): Pair<ByteArray, Pair<Int, Int>> =
        Pair(File(path).readBytes(), Pair(w, h))

    /// OCR 执行骨架：后台线程读字节→建位图→推理→展平元素表，结果回主线程
    private fun runOcr(
        result: MethodChannel.Result,
        load: () -> Pair<ByteArray, Pair<Int, Int>>,
    ) {
        ocrExecutor.execute {
            try {
                val (bytes, dim) = load()
                val text = recognizeRgba(bytes, dim.first, dim.second)
                mainHandler.post { result.success(text) }
            } catch (e: Exception) {
                mainHandler.post { result.error("ocrError", e.toString(), null) }
            }
        }
    }

    private fun recognizeRgba(
        bytes: ByteArray,
        w: Int,
        h: Int,
    ): List<Map<String, Any>> {
        if (bytes.size < w * h * 4) {
            throw IllegalArgumentException("rgba size ${bytes.size} < ${w * h * 4}")
        }
        // RGBA 字节序 -> Android ARGB int 像素（插件同款转换，只是跑在后台）
        val pixels = IntArray(w * h)
        var i = 0
        var p = 0
        while (i < pixels.size) {
            val r = bytes[p].toInt() and 0xFF
            val g = bytes[p + 1].toInt() and 0xFF
            val b = bytes[p + 2].toInt() and 0xFF
            val a = bytes[p + 3].toInt() and 0xFF
            pixels[i] = (a shl 24) or (r shl 16) or (g shl 8) or b
            i++
            p += 4
        }
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        // 必须用插件同款 IntBuffer 直拷：setPixels 会过一遍预乘舍入，
        // ML Kit 边缘读数随之翻转（实测 F19→F18、C4→CH），直拷则与
        // 插件路径逐元素一致（同进程对拍验证）
        bitmap.copyPixelsFromBuffer(java.nio.IntBuffer.wrap(pixels))
        return flatten(Tasks.await(recognizer().process(InputImage.fromBitmap(bitmap, 0))))
    }

    /// 展平 blocks→lines→elements：Dart 侧只消费 text+rect（三重循环
    /// 展开成一层，回传结构也小一个量级）
    private fun flatten(text: com.google.mlkit.vision.text.Text): List<Map<String, Any>> {
        val out = mutableListOf<Map<String, Any>>()
        for (block in text.textBlocks) {
            for (line in block.lines) {
                for (element in line.elements) {
                    val bb = element.boundingBox ?: continue
                    out.add(
                        mapOf(
                            "t" to element.text,
                            "l" to bb.left.toDouble(),
                            "t2" to bb.top.toDouble(),
                            "r" to bb.right.toDouble(),
                            "b" to bb.bottom.toDouble(),
                        )
                    )
                }
            }
        }
        return out
    }

    override fun onDestroy() {
        ocrExecutor.execute {
            recognizer?.close()
            recognizer = null
        }
        mlkitExecutor.shutdown()
        channel?.setMethodCallHandler(null)
        super.onDestroy()
    }
}
