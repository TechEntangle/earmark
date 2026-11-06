import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.setContentSize(NSSize(width: 1180, height: 780))
    self.minSize = NSSize(width: 860, height: 560)
    self.title = "Earmark"
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)
    self.isMovableByWindowBackground = true
    self.center()
    self.setFrameAutosaveName("EarmarkMain")

    RegisterGeneratedPlugins(registry: flutterViewController)
    (NSApp.delegate as? AppDelegate)?.attach(flutterViewController)

    super.awakeFromNib()
  }
}
