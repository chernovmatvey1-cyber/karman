import Foundation

/// Находит самый свежий скриншот или запись экрана там, куда их сохраняет macOS.
enum Screenshots {
    static var folder: URL {
        let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        if let custom, !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    static func latest() -> URL? {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        return files
            .filter { isScreenCapture($0) }
            .max { date($0) < date($1) }
    }

    private static func date(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    /// macOS помечает свои снимки атрибутом kMDItemIsScreenCapture.
    private static func isScreenCapture(_ url: URL) -> Bool {
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        if size > 0 { return true }
        let n = url.lastPathComponent
        return ["png", "jpg", "jpeg", "heic", "mov"].contains(url.pathExtension.lowercased())
            && (n.hasPrefix("Снимок экрана") || n.hasPrefix("Screenshot") || n.hasPrefix("Запись экрана")
                || n.hasPrefix("Screen Recording"))
    }
}

extension Screenshots {
    /// Системный выбор области (пробел — окно, Esc — отмена) прямо в папку полки.
    static func capture(completion: @escaping (URL?) -> Void) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        let url = Storage.newItemFolder().appendingPathComponent("Снимок экрана \(f.string(from: Date())).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-x", url.path]
        p.terminationHandler = { _ in
            let ok = FileManager.default.fileExists(atPath: url.path)
            if !ok { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            DispatchQueue.main.async { completion(ok ? url : nil) }
        }
        do { try p.run() } catch { completion(nil) }
    }
}
