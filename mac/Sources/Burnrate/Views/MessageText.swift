// A card's error or hint, with "Settings" underlined as a link to that
// provider's section in Settings ▸ Providers.
import BurnrateCore
import SwiftUI

struct MessageText: View {
    let source: Source
    var uppercase = false
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(Self.linked(uppercase ? source.message.uppercased() : source.message, name: source.name))
            .environment(
                \.openURL,
                OpenURLAction { url in
                    guard url.scheme == "burnrate" else { return .systemAction }
                    app.settings.show(provider: source.name)
                    AppDelegate.showSettings(openSettings)
                    return .handled
                })
    }

    static func linked(_ text: String, name: String) -> AttributedString {
        var a = AttributedString(text)
        if let r = a.range(of: "settings", options: .caseInsensitive) {
            a[r].link = URL(string: "burnrate://settings/\(name)")
            a[r].underlineStyle = .single
        }
        return a
    }
}
