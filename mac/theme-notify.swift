// Tells running apps and the window server that AppleInterfaceStyle changed, as System Settings does when the owner
// picks Light or Dark. Mac run 2 (19 October 2026): writing the default alone left Photos light even after a relaunch.
import Foundation

DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.5))
