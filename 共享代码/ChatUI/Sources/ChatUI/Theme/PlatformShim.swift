import Foundation

#if canImport(UIKit)
import UIKit

public func copyToClipboard(_ text: String) {
    UIPasteboard.general.string = text
}
#elseif canImport(AppKit)
import AppKit

public func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
#endif
