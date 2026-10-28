import SwiftUI
#if !targetEnvironment(macCatalyst)
import VisionKit

/// The camera, full screen, until it reads a sign-in QR code. `onScan` says whether the code was
/// one; when it was not, the scanner says so and keeps looking.
struct QRScanner: View {
    let onScan: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var rejected = false

    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        ZStack {
            QRScannerView { text in
                let accepted = onScan(text)
                rejected = !accepted
                return accepted
            }
            .ignoresSafeArea()
            VStack {
                Button("Close") { dismiss() }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Space.s4)
                Spacer()
                hint
            }
        }
    }

    private var hint: some View {
        Label(rejected ? "That QR code isn't an Apron sign-in." : "Point the camera at a sign-in QR code.",
              systemImage: rejected ? "exclamationmark.triangle" : "qrcode.viewfinder")
            .apText(.ui, .semibold)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Tokens.Space.s4)
            .padding(.vertical, Tokens.Space.s3)
            .background(Palette.chrome, in: Capsule())
            .padding(Tokens.Space.s6)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// VisionKit's scanner, QR codes only.
private struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Bool

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
        let onScan: (String) -> Bool
        private var accepted = false

        init(onScan: @escaping (String) -> Bool) { self.onScan = onScan }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !accepted else { return }
            for case .barcode(let barcode) in items {
                guard let text = barcode.payloadStringValue else { continue }
                if onScan(text) {
                    accepted = true
                    return
                }
            }
        }
    }
}
#else
/// VisionKit's scanner does not exist on Mac Catalyst, where only the design-review renderer runs.
struct QRScanner: View {
    let onScan: (String) -> Bool
    static let isAvailable = false
    var body: some View { EmptyView() }
}
#endif
