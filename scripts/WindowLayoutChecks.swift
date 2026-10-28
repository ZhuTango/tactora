import Foundation
import CoreGraphics
@main struct WindowLayoutChecks {
 static func main() {
  let desktop = CGRect(x: -1440, y: 120, width: 1440, height: 900)
  let original = CGRect(x: -1200, y: 200, width: 600, height: 400)
  precondition(WindowLayout.left.frame(in: desktop, current: original) == CGRect(x: -1440, y: 120, width: 720, height: 900))
  precondition(WindowLayout.bottomRight.frame(in: desktop, current: original) == CGRect(x: -720, y: 570, width: 720, height: 450))
  precondition(WindowLayout.maximize.frame(in: desktop, current: original) == desktop)
  precondition(WindowLayout.center.frame(in: desktop, current: original) == CGRect(x: -1020, y: 370, width: 600, height: 400))
  for layout in WindowLayout.allCases where layout != .restore && layout != .fullscreen {
   precondition(desktop.contains(layout.frame(in: desktop, current: original)))
  }
  print("PASS: window geometry, negative screen origins and bounded layouts")
 }
}
