package com.personal.native_media

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetector
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * App 自用的原生功能。做成外掛後，背景索引的 Flutter 引擎也會自動註冊。
 * - photo_prompt/ocr：ML Kit 中文文字辨識（模型隨 App 打包，不需連網）
 * - photo_prompt/media：影片抽幀、人臉偵測
 */
class NativeMediaPlugin : FlutterPlugin {
    private lateinit var context: Context
    private var ocrChannel: MethodChannel? = null
    private var mediaChannel: MethodChannel? = null
    private var background: ExecutorService? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // 第一次使用時才建立，避免沒開 OCR 也載入模型。
    private var recognizerInstance: TextRecognizer? = null
    private val recognizer: TextRecognizer
        get() = recognizerInstance
            ?: TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
                .also { recognizerInstance = it }

    private var faceDetectorInstance: FaceDetector? = null
    private val faceDetector: FaceDetector
        get() = faceDetectorInstance
            ?: FaceDetection.getClient(
                FaceDetectorOptions.Builder()
                    .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
                    .setMinFaceSize(0.08f)
                    .build()
            ).also { faceDetectorInstance = it }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        background = Executors.newSingleThreadExecutor()

        ocrChannel = MethodChannel(binding.binaryMessenger, "photo_prompt/ocr").also {
            it.setMethodCallHandler { call, result ->
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
                    val image = InputImage.fromFilePath(context, Uri.fromFile(File(path)))
                    recognizer.process(image)
                        .addOnSuccessListener { text -> result.success(text.text) }
                        .addOnFailureListener { e -> result.error("ocr_failed", e.message, null) }
                } catch (e: Exception) {
                    result.error("ocr_failed", e.message, null)
                }
            }
        }

        mediaChannel = MethodChannel(binding.binaryMessenger, "photo_prompt/media").also {
            it.setMethodCallHandler { call, result ->
                if (call.method == "detectFaces") {
                    detectFaces(call.argument<String>("path"), result)
                    return@setMethodCallHandler
                }
                if (call.method != "videoFrame") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                val timeMs = call.argument<Number>("timeMs")?.toLong() ?: 0L
                val maxSize = call.argument<Number>("maxSize")?.toInt() ?: 320
                if (path == null) {
                    result.error("bad_args", "缺少 path", null)
                    return@setMethodCallHandler
                }
                val executor = background
                if (executor == null) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                executor.execute {
                    val bytes = try {
                        videoFrame(path, timeMs, maxSize)
                    } catch (e: Exception) {
                        null
                    }
                    mainHandler.post { result.success(bytes) }
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ocrChannel?.setMethodCallHandler(null)
        mediaChannel?.setMethodCallHandler(null)
        ocrChannel = null
        mediaChannel = null
        background?.shutdown()
        background = null
        recognizerInstance?.close()
        recognizerInstance = null
        faceDetectorInstance?.close()
        faceDetectorInstance = null
    }

    /** 人臉偵測：回傳 [left, top, width, height]（皆為 0~1 的比例）的清單。 */
    private fun detectFaces(path: String?, result: MethodChannel.Result) {
        if (path == null) {
            result.error("bad_args", "缺少 path", null)
            return
        }
        try {
            val image = InputImage.fromFilePath(context, Uri.fromFile(File(path)))
            val w = image.width.toDouble()
            val h = image.height.toDouble()
            faceDetector.process(image)
                .addOnSuccessListener { faces ->
                    result.success(faces.map {
                        val b = it.boundingBox
                        listOf(b.left / w, b.top / h, b.width() / w, b.height() / h)
                    })
                }
                .addOnFailureListener { e -> result.error("face_failed", e.message, null) }
        } catch (e: Exception) {
            result.error("face_failed", e.message, null)
        }
    }

    /** 取出指定時間附近的畫面，長邊縮到 maxSize，回傳 JPEG。 */
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
}
