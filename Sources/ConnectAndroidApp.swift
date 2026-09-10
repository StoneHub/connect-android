import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
#if DEBUG
import DevFeedback
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ConnectAndroidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("Connect Android", id: "connect") {
            ConnectionView()
                .frame(width: 460, height: 590)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            #if DEBUG
            FeedbackCommands()
            #endif
        }
    }
}

struct ConnectionView: View {
    @StateObject private var engine = PairingEngine()
    @State private var details = false
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: engine.phase == .connected ? "checkmark.circle.fill" : "iphone.radiowaves.left.and.right")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(engine.phase == .connected ? Color.green : Color.accentColor)
                .accessibilityHidden(true)
            Text("Connect Android").font(.largeTitle.bold()).tagged("connection.title", "Window title")
            Text(engine.status).font(.body).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).tagged("connection.status", "Connection status")
            Group {
                if let payload = engine.qrPayload, engine.phase == .scanning, let qr = qrImage(payload) {
                    Image(nsImage: qr).interpolation(.none).resizable().scaledToFit()
                        .padding(16).background(.white).clipShape(RoundedRectangle(cornerRadius: 12))
                        .frame(width: 240, height: 240).accessibilityLabel("Android wireless debugging pairing QR code")
                        .tagged("connection.qr", "Pairing QR code")
                } else if engine.phase == .connected {
                    VStack(spacing: 12) {
                        Image(systemName: "iphone.gen3").font(.system(size: 84)).foregroundStyle(.secondary)
                        Text(engine.deviceName ?? "Android device").font(.title2.bold())
                        Text("You can close this window.\nYour debugging connection stays available.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }.frame(height: 240).tagged("connection.device", "Connected device")
                } else if engine.phase == .failed {
                    VStack(spacing: 14) {
                        Image(systemName: "wifi.exclamationmark").font(.system(size: 64)).foregroundStyle(.orange)
                        Text("Keep your phone and Mac on the same Wi-Fi, and allow local network access if macOS asks.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }.frame(height: 240)
                } else {
                    ProgressView().controlSize(.large).frame(height: 240)
                }
            }
            if engine.phase == .scanning {
                Text("On your phone: Developer options → Wireless debugging → Pair device with QR code")
                    .font(.callout).multilineTextAlignment(.center).tagged("connection.instructions", "Scan instructions")
            }
            Spacer(minLength: 0)
            HStack {
                Button("Details") { details = true }.tagged("connection.details", "Show connection details")
                Spacer()
                if engine.phase == .failed {
                    Button("Choose ADB…", action: chooseADB).tagged("connection.chooseadb", "Choose ADB executable")
                    Button("Retry") { engine.start() }.buttonStyle(.borderedProminent).tagged("connection.retry", "Retry connection")
                } else {
                    Button(engine.phase == .connected ? "Done" : "Cancel") {
                        engine.stop()
                        NSApplication.shared.terminate(nil)
                    }.keyboardShortcut(.defaultAction).tagged("connection.done", "Close application")
                }
            }
        }
        .padding(28)
        .tagged("connection.content", "Connection window content")
        .task { engine.start() }
        .onDisappear { engine.stop() }
        .sheet(isPresented: $details) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connection details").font(.title2.bold())
                ScrollView { Text(String(describing: engine.log)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("Close") { details = false }.keyboardShortcut(.cancelAction) }
            }.padding(24).frame(width: 540, height: 360)
        }
        #if DEBUG
        .feedbackOverlay(appID: "com.monroestone.connectandroid", screen: "connection")
        #endif
    }
    private func chooseADB() {
        let panel = NSOpenPanel()
        panel.title = "Choose the adb executable in Android SDK platform-tools"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { engine.start(adbURL: url) }
    }
    private func qrImage(_ payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

extension View {
    @ViewBuilder func tagged(_ id: @autoclosure () -> String, _ label: @autoclosure () -> String) -> some View {
        #if DEBUG
        self.feedbackTarget(id(), label: label())
        #else
        self
        #endif
    }
}
