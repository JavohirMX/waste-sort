import Foundation
import os
import Vision

/// One decoded barcode from the live feed.
struct ScannedBarcode: Equatable {
    let payload: String
    /// Human-readable symbology name, e.g. "EAN-13".
    let symbology: String
    let timestamp: Date
}

/// Maps barcode symbologies to a disposal hint. Deliberately offline: this
/// kiosk makes no network calls, so there is no product-name database - the
/// honest signal is "this is a packaged retail product", which nudges the
/// operator toward sorting by packaging material.
nonisolated enum BarcodeGuidance {
    static func hint(for symbology: String) -> String {
        switch symbology {
        case "EAN-13", "EAN-8", "UPC-E", "UPC-A":
            return "Retail product - sort by its packaging"
        case "QR", "Aztec", "DataMatrix", "PDF417":
            return "Encoded label - not recyclable on its own"
        default:
            return "Packaged item - check the material"
        }
    }

    static func displayName(for symbology: String) -> String {
        symbology.isEmpty ? "Barcode" : symbology
    }
}

/// Throttled Vision barcode detection over the live camera feed.
///
/// Runs on its own serial queue with a drop-when-busy policy so scanning never
/// competes with YOLO inference for more than one frame at a time. Callbacks
/// arrive on `queue`; callers hop to main as needed.
final class BarcodeFrameScanner {
    private let queue = DispatchQueue(label: "sortla.barcode.scan")
    private let minimumInterval: TimeInterval = 0.5

    private var lastRunAt: TimeInterval = 0
    private var pending: CVPixelBuffer?
    private var inFlight = false

    /// Called on `queue` with the most recent decode (or none while idle).
    var onBarcode: ((ScannedBarcode?) -> Void)?

    /// Scans when at least `minimumInterval` seconds have passed since the last
    /// pass; otherwise drops the frame entirely (cheapest possible back-pressure).
    func submit(_ pixelBuffer: CVPixelBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastRunAt >= self.minimumInterval, !self.inFlight else { return }
            self.lastRunAt = now
            self.inFlight = true

            let request = VNDetectBarcodesRequest { [weak self] request, _ in
                guard let self else { return }
                defer { self.inFlight = false }
                self.queue.async {
                    self.handle(request)
                }
            }
            request.symbologies = [.ean13, .ean8, .upce, .qr, .aztec, .dataMatrix, .pdf417]
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
            do {
                try handler.perform([request])
            } catch {
                self.inFlight = false
                AppLog.vision.error("Barcode scan failed: \(error.localizedDescription)")
            }
        }
    }

    private func handle(_ request: VNRequest) {
        guard let results = request.results as? [VNBarcodeObservation] else {
            onBarcode?(nil)
            return
        }
        // Prefer the most confident machine-readable code in the frame.
        guard let best = results
            .filter({ !$0.payloadStringValue.isNilOrEmpty })
            .max(by: { $0.confidence < $1.confidence }),
            let payload = best.payloadStringValue
        else {
            onBarcode?(nil)
            return
        }
        onBarcode?(
            ScannedBarcode(
                payload: payload,
                symbology: Self.symbologyName(best.symbology),
                timestamp: Date()
            )
        )
    }

    private static func symbologyName(_ raw: VNBarcodeSymbology) -> String {
        switch raw {
        case .ean13: return "EAN-13"
        case .ean8: return "EAN-8"
        case .upce: return "UPC-E"
        case .qr: return "QR"
        case .aztec: return "Aztec"
        case .dataMatrix: return "DataMatrix"
        case .pdf417: return "PDF417"
        default: return ""
        }
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
