package com.personal.photo_prompt

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    // 中文辨識器同時支援拉丁字母；模型隨 App 打包，不需連網。
    // 第一次使用時才建立，避免沒開 OCR 也載入模型。
    private var recognizerInstance: TextRecognizer? = null
    private val recognizer: TextRecognizer
        get() = recognizerInstance
            ?: TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
                .also { recognizerInstance = it }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerMediaChannel(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "photo_prompt/ocr")
            .setMethodCallHandler { call, result ->
                if (call.method != "recognize") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("bad_args", "缺少 path", null)
                    return@setMethodCallHandler
                }
                try {
                    val image = InputImage.fromFilePath(this, Uri.fromFile(File(path)))
                    recognizer.process(image)
                        .addOnSuccessListener { result.success(it.text) }
                        .addOnFailureListener { result.error("ocr_failed", it.message, null) }
                } catch (e: Exception) {
                    result.error("ocr_failed", e.message, null)
                }
            }
    }

    private val background = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    /// 影片抽幀（C7）：在背景執行緒取出指定時間的畫面，縮放後回傳 JPEG。
    private fun registerMediaChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "photo_prompt/media")
            .setMethodCallHandler { call, result ->
                if (call.method != "videoFrame") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                val timeMs = call.argument<Number>("timeMs")?.toLong() ?: 0L
                val maxSize = call.argument<Number>("maxSize")?.toInt() ?: 448
                if (path == null) {
                    result.error("bad_args", "缺少 path", null)
                    return@setMethodCallHandler
                }
                background.execute {
                    val bytes = try {
                        videoFrame(path, timeMs, maxSize)
                    } catch (e: Exception) {
                        null
                    }
                    mainHandler.post { result.success(bytes) }
                }
            }
    }

    private fun videoFrame(path: String, timeMs: Long, maxSize: Int): ByteArray? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val frame = retriever.getFrameAtTime(
                timeMs * 1000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            ) ?: return null
            val scale = maxSize.toFloat() / maxOf(frame.width, frame.height)
            val scaled = if (scale < 1f) {
                Bitmap.createScaledBitmap(
                    frame,
                    (frame.width * scale).toInt().coerceAtLeast(1),
                    (frame.height * scale).toInt().coerceAtLeast(1),
                    true
                ).also { frame.recycle() }
            } else {
                frame
            }
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 85, out)
            scaled.recycle()
            return out.toByteArray()
        } finally {
            retriever.release()
        }
    }

    override fun onDestroy() {
        background.shutdown()
        recognizerInstance?.close()
        super.onDestroy()
    }
}
