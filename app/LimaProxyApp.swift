import Cocoa
import WebKit

// ─── App Delegate ───

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var webView: WKWebView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure web view with shell bridge
        let userContentController = WKUserContentController()
        let config = WKWebViewConfiguration()
        config.userContentController = userContentController
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = WKWebView(frame: .zero, configuration: config)
        let handler = ShellMessageHandler(webView: webView)
        userContentController.add(handler, name: "shell")

        // Create window
        let screenSize = NSScreen.main?.frame.size ?? NSSize(width: 1200, height: 800)
        let windowWidth: CGFloat = 560
        let windowHeight: CGFloat = 750
        let windowRect = NSRect(
            x: (screenSize.width - windowWidth) / 2,
            y: (screenSize.height - windowHeight) / 2,
            width: windowWidth,
            height: windowHeight
        )

        window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Lima Proxy Manager"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.102, green: 0.102, blue: 0.180, alpha: 1.0)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 500)
        window.contentView = webView

        // Load HTML
        let home = FileManager.default.homeDirectoryForCurrentUser
        let htmlPath = home.appendingPathComponent(".lima-proxy/web/index.html")
        webView.loadFileURL(htmlPath, allowingReadAccessTo: htmlPath.deletingLastPathComponent())

        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

// ─── Shell Message Handler ───

class ShellMessageHandler: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    private let shellTimeout: TimeInterval = 120  // 2 minute timeout

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let cmd = body["cmd"] as? String,
              let callId = body["callId"] as? String else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.runShell(cmd) ?? "Error: handler deallocated"
            let escaped = self?.escapeForJS(result) ?? ""
            DispatchQueue.main.async {
                self?.webView?.evaluateJavaScript("window['\(callId)'](\"\(escaped)\")")
            }
        }
    }

    /// Escape string for safe embedding in JavaScript double-quoted string
    func escapeForJS(_ str: String) -> String {
        var result = ""
        result.reserveCapacity(str.count)
        for char in str {
            switch char {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": continue  // skip CR
            case "\t": result += "\\t"
            case "\u{2028}": result += "\\u2028"  // JS line separator
            case "\u{2029}": result += "\\u2029"  // JS paragraph separator
            case "\u{0008}": result += "\\b"      // backspace
            case "\u{000C}": result += "\\f"      // form feed
            default: result.append(char)
            }
        }
        return result
    }

    func runShell(_ command: String) -> String {
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-l", "-c", command]

        // Set HOME explicitly
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        task.environment = env

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        // Read output asynchronously to prevent pipe buffer deadlock
        var outputData = Data()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        // Wait with timeout
        let deadline = DispatchTime.now() + shellTimeout
        let waitResult = readGroup.wait(timeout: deadline)

        if waitResult == .timedOut {
            task.terminate()
            return "Error: 命令执行超时 (\(Int(shellTimeout))s)"
        }

        task.waitUntilExit()
        return String(data: outputData, encoding: .utf8) ?? ""
    }
}

// ─── Main ───

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
