// Snapshot.swift — one JPEG of the FaceTime window (the caller's video).
//
// 2026-09-14: the Captain wants to show DATA something on camera and ask
// about it. The remote video of a FaceTime call exists in exactly one place
// on this Mac — FaceTime.app's window — so the daemon captures that window
// with ScreenCaptureKit on request. Privacy boundary: the filter is the
// FaceTime window and nothing else; the daemon cannot return any other pixels.
// Needs the Screen & System Audio Recording grant for this signed identity.
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum SnapshotError: Error, CustomStringConvertible {
  case noWindow
  case encodeFailed
  case capture(String)

  var description: String {
    switch self {
    case .noWindow: return "no FaceTime window on screen"
    case .encodeFailed: return "JPEG encode failed"
    case .capture(let m): return m
    }
  }

  var code: String {
    switch self {
    case .noWindow: return "NO_WINDOW"
    case .encodeFailed: return "ENCODE_FAILED"
    case .capture: return "CAPTURE_FAILED"
    }
  }
}

struct SnapshotResult {
  let jpeg: Data
  let width: Int
  let height: Int
  let windowTitle: String
}

private let faceTimeBundleID = "com.apple.FaceTime"

/// Capture the largest on-screen FaceTime.app window, scaled so the longer
/// side is at most `maxSide` pixels, as JPEG.
func captureFaceTimeWindow(maxSide: Int, quality: Double = 0.85) async throws -> SnapshotResult {
  let content: SCShareableContent
  do {
    content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
  } catch {
    throw SnapshotError.capture("shareable content unavailable (Screen Recording grant?): \(error)")
  }
  let candidates = content.windows.filter { w in
    w.owningApplication?.bundleIdentifier == faceTimeBundleID
      && w.frame.width >= 160 && w.frame.height >= 120
  }
  guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
    throw SnapshotError.noWindow
  }
  let filter = SCContentFilter(desktopIndependentWindow: window)
  let config = SCStreamConfiguration()
  let scale = Double(filter.pointPixelScale)
  var px = window.frame.width * scale
  var py = window.frame.height * scale
  let longest = max(px, py)
  if longest > Double(maxSide) {
    let k = Double(maxSide) / longest
    px *= k
    py *= k
  }
  config.width = max(2, Int(px.rounded()))
  config.height = max(2, Int(py.rounded()))
  config.showsCursor = false
  config.captureResolution = .best
  let image: CGImage
  do {
    image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
  } catch {
    throw SnapshotError.capture("captureImage failed: \(error)")
  }
  let data = NSMutableData()
  guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
    throw SnapshotError.encodeFailed
  }
  CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
  guard CGImageDestinationFinalize(dest) else { throw SnapshotError.encodeFailed }
  return SnapshotResult(jpeg: data as Data, width: image.width, height: image.height,
                        windowTitle: window.title ?? "")
}
