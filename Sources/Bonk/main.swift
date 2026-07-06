import AppKit

if CommandLine.arguments.contains("--probe") {
    SensorProbe.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
