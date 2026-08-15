import AppKit

for (index, screen) in NSScreen.screens.enumerated() {
    let description = screen.deviceDescription
    let screenNumber = description[NSDeviceDescriptionKey("NSScreenNumber")] ?? "unknown"
    let resolution = description[NSDeviceDescriptionKey("NSDeviceResolution")] ?? "unknown"

    print("screen[\(index)]")
    print("  name=\(screen.localizedName)")
    print("  number=\(screenNumber)")
    print("  frame=\(NSStringFromRect(screen.frame))")
    print("  visibleFrame=\(NSStringFromRect(screen.visibleFrame))")
    print("  backingScaleFactor=\(screen.backingScaleFactor)")
    print("  resolution=\(resolution)")
}
