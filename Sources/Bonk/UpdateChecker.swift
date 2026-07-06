import AppKit

// Once-a-day version check against GitHub's public releases API. Toggleable in
// settings (default on, disclosed on the privacy page). Sends nothing beyond
// the HTTP request itself; on a newer tag, offers the releases page.
enum UpdateChecker {
    static let currentVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    static func checkIfEnabled() {
        guard BonkSettings.shared.updateCheckEnabled else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")

        var req = URLRequest(url: URL(string: "https://api.github.com/repos/Alex-duh/Bonk/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard latest.compare(currentVersion, options: .numeric) == .orderedDescending else { return }
            DispatchQueue.main.async { offerUpdate(latest) }
        }.resume()
    }

    private static func offerUpdate(_ version: String) {
        klog("update available: \(version) (running \(currentVersion))")
        let alert = NSAlert()
        alert.messageText = "Bonk \(version) is available"
        alert.informativeText = "You have \(currentVersion). Download the new version and drag it into Applications to replace this one. Your settings are kept."
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://github.com/Alex-duh/Bonk/releases/latest")!)
        }
    }
}
