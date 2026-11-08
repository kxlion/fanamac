// Tells macOS that the CSL DD has a force feedback plug-in: FanaMacFF.plugin,
// inside this app. macOS's ForceFeedback framework then loads it for any game
// that asks for the wheel's force feedback, native or through CrossOver (Wine
// uses SDL2, which uses that framework). Nothing is installed anywhere: the
// entry lives in the base's IORegistry entry until the base is unplugged or
// FanaMac quits.
//
// A CrossOver bottle that was already running when the base was marked does
// not see it: start FanaMac (or plug the base in) before the bottle.
//
// The same plug-in also stands in for macOS's HID device plug-in on the base,
// to hide the input report the base never sends (ffplugin/src/hidfilter.c):
// without that, CrossOver games lose the brake and the handbrake.

import Foundation
@preconcurrency import IOKit
@preconcurrency import IOKit.hid

enum NativeForce {
    /// kIOForceFeedbackLibTypeID: the key macOS looks for in IOCFPlugInTypes.
    static let typeID = "F4545CE5-BF5B-11D6-A4BB-0003933E3E3E"
    /// kIOHIDDeviceTypeID, with the value macOS gives it on every HID device.
    static let hidTypeID = "7DDEECA8-A7B4-11DA-8A0E-0014519758EF"
    static let appleHIDPlugin = "IOHIDFamily.kext/Contents/PlugIns/IOHIDLib.plugin"
    private static let key = "IOCFPlugInTypes" as CFString

    /// The plug-in's path as the framework wants it: relative to
    /// /System/Library/Extensions (it refuses an absolute path).
    static var pluginPath: String? {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("FanaMacFF.plugin"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return "../../.." + url.path
    }

    /// Adds our force feedback entry and puts our HID entry in place of
    /// Apple's. Returns false if macOS refused it.
    @discardableResult
    static func mark(_ device: IOHIDDevice) -> Bool {
        guard let path = pluginPath else { return false }
        let service = IOHIDDeviceGetService(device)
        let types = entries(service)
        types[typeID] = path
        types[hidTypeID] = path
        return IORegistryEntrySetCFProperty(service, key, types) == KERN_SUCCESS
    }

    /// Takes out our force feedback entry and gives the HID entry back to Apple.
    static func unmark(_ device: IOHIDDevice) {
        let service = IOHIDDeviceGetService(device)
        let types = entries(service)
        guard types[typeID] != nil else { return }
        types.removeObject(forKey: typeID)
        types[hidTypeID] = appleHIDPlugin
        IORegistryEntrySetCFProperty(service, key, types)
    }

    private static func entries(_ service: io_service_t) -> NSMutableDictionary {
        let current = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSDictionary
        return NSMutableDictionary(dictionary: current ?? [:])
    }
}
