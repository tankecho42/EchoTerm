import AppKit
import CoreGraphics
for screen in NSScreen.screens { print("SCREEN", NSStringFromRect(screen.frame), screen.backingScaleFactor) }
for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as? [[String:Any]] ?? [] {
 if let owner=w[kCGWindowOwnerName as String] as? String, owner.contains("Echo") { print(w) }
}
