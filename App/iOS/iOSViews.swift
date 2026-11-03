import SwiftUI
import UIKit
import PencilKit
import VisionKit

struct ActivityView: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Full-screen PencilKit canvas; produces a PNG of the drawing.
struct SketchView: View {
    @Environment(\.dismiss) private var dismiss
    var onSave: (Data) -> Void
    @State private var canvas = PKCanvasView()

    var body: some View {
        NavigationStack {
            CanvasRepresentable(canvas: canvas)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Sketch")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Insert") {
                            let drawing = canvas.drawing
                            let bounds = drawing.bounds.insetBy(dx: -24, dy: -24)
                            if !drawing.strokes.isEmpty {
                                let image = drawing.image(from: bounds, scale: 2)
                                let rendered = UIGraphicsImageRenderer(size: image.size).image { ctx in
                                    UIColor.white.setFill()
                                    ctx.fill(CGRect(origin: .zero, size: image.size))
                                    image.draw(at: .zero)
                                }
                                if let png = rendered.pngData() { onSave(png) }
                            }
                            dismiss()
                        }
                    }
                }
        }
    }
}

private struct CanvasRepresentable: UIViewRepresentable {
    let canvas: PKCanvasView
    func makeUIView(context: Context) -> PKCanvasView {
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .white
        canvas.overrideUserInterfaceStyle = .light
        let picker = context.coordinator.picker
        picker.setVisible(true, forFirstResponder: canvas)
        picker.addObserver(canvas)
        canvas.becomeFirstResponder()
        return canvas
    }
    func updateUIView(_ view: PKCanvasView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { let picker = PKToolPicker() }
}

struct DocumentScannerView: UIViewControllerRepresentable {
    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }
    var onScan: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView
        init(_ parent: DocumentScannerView) { self.parent = parent }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            parent.onScan((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
            parent.dismiss()
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { parent.dismiss() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { parent.dismiss() }
    }
}

/// Scans a sync code QR shown on another device.
struct QRScannerView: UIViewControllerRepresentable {
    static var isSupported: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }
    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: QRScannerView
        private var done = false
        init(_ parent: QRScannerView) { self.parent = parent }
        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in items {
                if case .barcode(let code) = item, let value = code.payloadStringValue, value.uppercased().hasPrefix("AXO"), !done {
                    done = true
                    scanner.stopScanning()
                    parent.onCode(value)
                }
            }
        }
    }
}
