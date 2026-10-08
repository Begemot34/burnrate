// Registers the bundled TTFs for this process. In the .app they live in
// Resources/Fonts, the widget its own copy; under `swift run` they are read from the source tree.
import CoreText
import Foundation

public enum Fonts {
    public static func register() {
        let candidates = [
            Bundle.main.resourceURL?.appending(path: "Fonts"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appending(path: "../../Resources/Fonts").standardizedFileURL,
        ]
        for case let dir? in candidates {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            for f in files where f.pathExtension == "ttf" {
                CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
            }
            return
        }
    }
}
