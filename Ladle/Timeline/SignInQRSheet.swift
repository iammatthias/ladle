import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A sign-in link from a `~private` notice (`NoticeMenu.signInLinks`) as a QR code for another
/// device to scan, as apron-web's SignInQrDialog. The warning comes first and the code only on
/// Show QR Code, so it is never on screen before the user has read who it lets in.
struct SignInQRSheet: View {
    let link: URL
    @State var revealed = false
    let done: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Tokens.Space.s4) {
                    if revealed {
                        if let code = SignInQRCode.image(of: link.absoluteString) {
                            Image(code, scale: 1, label: Text("QR code of the sign-in link"))
                                .interpolation(.none)
                                .resizable()
                                .aspectRatio(1, contentMode: .fit)
                                .frame(maxWidth: 280)
                            Text("Scan it with an Apron app on your other device to sign in there.")
                                .foregroundStyle(Palette.ink)
                        } else {
                            Text("This link is too long for a QR code. Open it on your other device instead.")
                                .foregroundStyle(Palette.ink)
                        }
                    }
                    Label("Anyone who scans this code can sign in as you. Show it only to your own devices.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Palette.danger)
                    if !revealed {
                        Button("Show QR Code", systemImage: "qrcode") { revealed = true }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }
                .apText(.ui)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(Tokens.Space.s4)
            }
            .background(Palette.timeline)
            .navigationTitle("Sign in on another device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Palette.timeline)
    }
}

/// The sign-in link a notice's Show QR Code opens.
struct SignInQRRequest: Identifiable {
    let id = UUID()
    let link: URL
}

enum SignInQRCode {
    private static let context = CIContext()

    /// The text as a QR code, one pixel a module, inside a white quiet zone of four modules
    /// beyond the generator's own; nil when the text is too long for one. A scanner reads dark
    /// on light, so it stays black on white in either theme.
    static func image(of text: String) -> CGImage? {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(text.utf8)
        generator.correctionLevel = "M"
        guard let code = generator.outputImage else { return nil }
        let extent = code.extent.insetBy(dx: -4, dy: -4)
        let framed = code.composited(over: CIImage(color: .white).cropped(to: extent))
        return context.createCGImage(framed, from: extent)
    }
}
