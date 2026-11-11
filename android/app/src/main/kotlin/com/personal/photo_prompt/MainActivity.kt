package com.personal.photo_prompt

import android.net.Uri
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

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

    override fun onDestroy() {
        recognizerInstance?.close()
        super.onDestroy()
    }
}
