import SwiftUI
#if !targetEnvironment(macCatalyst)
import VisionKit

/// Scans one QR code with VisionKit and hands back its text.
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    @MainActor static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var delivered = false

        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for case .barcode(let barcode) in items {
                guard let text = barcode.payloadStringValue else { continue }
                delivered = true
                onScan(text)
                return
            }
        }
    }
}
#else
/// VisionKit's scanner does not exist on Mac Catalyst, where only the design-review renderer runs.
struct QRScannerView: View {
    let onScan: (String) -> Void
    static let isAvailable = false
    var body: some View { EmptyView() }
}
#endif
