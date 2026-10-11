// Read-only, bounded diagnostic. Does not open Ecru, request permissions,
// suppress events or generate keyboard/mouse input. --watch observes 30 seconds
// so a human can record a startup boundary; the default observes 5 seconds.
import Foundation
import AppKit
import CoreGraphics
import IOKit.hid

let duration: Double = CommandLine.arguments.contains("--watch") ? 30 : 5
let started = ProcessInfo.processInfo.systemUptime
var entries: [[String:Any]] = []
var spaceEvents = 0
var hidEvents = 0
func record(_ entry: [String:Any]) {
    guard entries.count < 2048 else { return }
    var value = entry; value["elapsed"] = ProcessInfo.processInfo.systemUptime - started
    entries.append(value)
}
func product(_ device: IOHIDDevice) -> String {
    IOHIDDeviceGetProperty(device,kIOHIDProductKey as CFString) as? String ?? "unknown keyboard"
}
func systemState() -> [String:Bool] {
    ["hidSpaceDown":CGEventSource.keyState(.hidSystemState,key:49),
     "sessionSpaceDown":CGEventSource.keyState(.combinedSessionState,key:49)]
}
let listeningAllowed = CGPreflightListenEventAccess()
let manager = IOHIDManagerCreate(kCFAllocatorDefault,IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager,[kIOHIDDeviceUsagePageKey:1,kIOHIDDeviceUsageKey:6] as CFDictionary)
// Non-seizing access only; matching is keyboard devices, recording only Space.
let opened = listeningAllowed ? IOHIDManagerOpen(manager,IOOptionBits(kIOHIDOptionsTypeNone)) : kIOReturnNotPermitted
func deviceState() -> [[String:Any]] {
    guard opened == kIOReturnSuccess,
          let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
    var rows: [[String:Any]] = []
    for device in devices {
        guard let elements = IOHIDDeviceCopyMatchingElements(device,
              [kIOHIDElementUsagePageKey:7,kIOHIDElementUsageKey:44] as CFDictionary,0) as? [IOHIDElement] else { continue }
        for element in elements {
            let value = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity:1)
            defer { value.deallocate() }
            let result = IOHIDDeviceGetValue(device,element,value)
            var row: [String:Any] = ["product":product(device),"readResult":result]
            if result == kIOReturnSuccess {
                let actual = value.pointee.takeUnretainedValue()
                row["cachedSpaceValue"] = IOHIDValueGetIntegerValue(actual)
                row["cachedTimestamp"] = IOHIDValueGetTimeStamp(actual)
            }
            rows.append(row)
        }
    }
    return rows
}
let before = systemState(), devicesBefore = deviceState()
var tap: CFMachPort?
var source: CFRunLoopSource?
if listeningAllowed {
    tap = CGEvent.tapCreate(tap:.cgSessionEventTap,place:.tailAppendEventTap,options:.listenOnly,
        eventsOfInterest:(1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue),
        callback:{ _, type, event, _ in
            if (type == .keyDown || type == .keyUp), event.getIntegerValueField(.keyboardEventKeycode) == 49 {
                spaceEvents += 1
                record(["channel":"session","type":type == .keyDown ? "down" : "up",
                        "repeat":event.getIntegerValueField(.keyboardEventAutorepeat),
                        "sourcePID":event.getIntegerValueField(.eventSourceUnixProcessID),
                        "sourceState":event.getIntegerValueField(.eventSourceStateID),
                        "userData":event.getIntegerValueField(.eventSourceUserData),"timestamp":event.timestamp])
            }
            // listenOnly callbacks cannot change/suppress delivery.
            return Unmanaged.passUnretained(event)
        }, userInfo:nil)
    if let tap {
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault,tap,0)
        if let source { CFRunLoopAddSource(CFRunLoopGetCurrent(),source,.commonModes) }
    }
}
if opened == kIOReturnSuccess {
    IOHIDManagerRegisterInputValueCallback(manager,{ _, _, _, value in
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == 7, IOHIDElementGetUsage(element) == 44 else { return }
        hidEvents += 1
        record(["channel":"device","product":product(IOHIDElementGetDevice(element)),
                "spaceValue":IOHIDValueGetIntegerValue(value),"timestamp":IOHIDValueGetTimeStamp(value)])
    },nil)
    IOHIDManagerScheduleWithRunLoop(manager,CFRunLoopGetCurrent(),CFRunLoopMode.commonModes.rawValue)
}
let center = NSWorkspace.shared.notificationCenter
let tokens = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification,
              NSWorkspace.didTerminateApplicationNotification].map { name in
    center.addObserver(forName:name,object:nil,queue:.main) { notification in
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "local.leafink.reader.development" else { return }
        record(["channel":"app","notification":name.rawValue,"pid":app.processIdentifier])
    }
}
let runningBefore = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "local.leafink.reader.development" }.map(\.processIdentifier)
fputs("Read-only Space observation for \(Int(duration)) seconds. No app will be launched; no keys will be posted.\n",stderr)
CFRunLoopRunInMode(.defaultMode,duration,false)
let after = systemState(), devicesAfter = deviceState()
tokens.forEach(center.removeObserver)
if let tap { CGEvent.tapEnable(tap:tap,enable:false) }
if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(),source,.commonModes); CFRunLoopSourceInvalidate(source) }
if let tap { CFMachPortInvalidate(tap) }
IOHIDManagerUnscheduleFromRunLoop(manager,CFRunLoopGetCurrent(),CFRunLoopMode.commonModes.rawValue)
IOHIDManagerClose(manager,IOOptionBits(kIOHIDOptionsTypeNone))
let result: [String:Any] = ["duration":duration,"before":before,"after":after,"devicesBefore":devicesBefore,"devicesAfter":devicesAfter,
    "listenPermission":listeningAllowed,"tapCreated":tap != nil,"deviceOpenResult":opened,"ecruPIDsBefore":runningBefore,
    "spaceEvents":spaceEvents,"deviceSpaceEvents":hidEvents,"entries":entries,
    "interpretation":"Device snapshots are cached HID values, not proof of physical key position. Initial nonrepeat down/up plus app timing is required for attribution."]
print(String(data:try! JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
