import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Apron")
                .font(.largeTitle.weight(.semibold))
            Text("Protocol core only. Chat arrives in phase 2.")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
