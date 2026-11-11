import AVFoundation
import Flutter
import UIKit
import Vision

/// App 自用的原生功能。做成外掛後，背景索引的 Flutter 引擎也會自動註冊。
/// - photo_prompt/ocr：Apple Vision 文字辨識（繁中、簡中、英文）
/// - photo_prompt/media：影片抽幀、人臉偵測
public class NativeMediaPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()

    let ocr = FlutterMethodChannel(name: "photo_prompt/ocr", binaryMessenger: messenger)
    ocr.setMethodCallHandler { call, result in
      guard call.method == "recognize",
            let args = call.arguments as? [String: Any],
            let path = args["path"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      DispatchQueue.global(qos: .utility).async {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hant", "zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:])
        do {
          try handler.perform([request])
          let text = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
          DispatchQueue.main.async { result(text) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "ocr_failed", message: error.localizedDescription, details: nil))
          }
        }
      }
    }

    let media = FlutterMethodChannel(name: "photo_prompt/media", binaryMessenger: messenger)
    media.setMethodCallHandler { call, result in
      if call.method == "detectFaces" {
        detectFaces(call.arguments as? [String: Any], result: result)
        return
      }
      guard call.method == "videoFrame",
            let args = call.arguments as? [String: Any],
            let path = args["path"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      let timeMs = (args["timeMs"] as? NSNumber)?.int64Value ?? 0
      let maxSize = (args["maxSize"] as? NSNumber)?.doubleValue ?? 320
      DispatchQueue.global(qos: .utility).async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)
        let time = CMTime(value: timeMs, timescale: 1000)
        let data = (try? generator.copyCGImage(at: time, actualTime: nil))
          .flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.85) }
        DispatchQueue.main.async {
          result(data.map { FlutterStandardTypedData(bytes: $0) })
        }
      }
    }
  }

  /// 人臉偵測：回傳 [left, top, width, height]（0~1 比例，原點左上）的清單。
  private static func detectFaces(_ args: [String: Any]?, result: @escaping FlutterResult) {
    guard let path = args?["path"] as? String else {
      result(FlutterError(code: "bad_args", message: "缺少 path", details: nil))
      return
    }
    DispatchQueue.global(qos: .utility).async {
      let request = VNDetectFaceRectanglesRequest()
      let handler = VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:])
      do {
        try handler.perform([request])
        // Vision 的座標原點在左下角，轉成左上角。
        let boxes = (request.results ?? []).map { face -> [Double] in
          let b = face.boundingBox
          return [Double(b.minX), Double(1 - b.maxY), Double(b.width), Double(b.height)]
        }
        DispatchQueue.main.async { result(boxes) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "face_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }
}
