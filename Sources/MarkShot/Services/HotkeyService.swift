import Carbon.HIToolbox
import Foundation

extension Notification.Name {
    static let markShotCaptureRegion = Notification.Name("markShotCaptureRegion")
    static let markShotCaptureFullScreen = Notification.Name("markShotCaptureFullScreen")
    static let markShotCaptureWindow = Notification.Name("markShotCaptureWindow")
    static let markShotNewBoard = Notification.Name("markShotNewBoard")
    static let markShotHotkeyStatus = Notification.Name("markShotHotkeyStatus")
    static let markShotShowToolbar = Notification.Name("markShotShowToolbar")
    static let markShotHideToolbar = Notification.Name("markShotHideToolbar")
    static let markShotRecordClip = Notification.Name("markShotRecordClip")
    static let markShotClearPinned = Notification.Name("markShotClearPinned")
    static let markShotSaveAllCaptureThumbnails = Notification.Name("markShotSaveAllCaptureThumbnails")
    static let markShotOpenVideoFrameLab = Notification.Name("markShotOpenVideoFrameLab")
    static let markShotStopVideoFrameLab = Notification.Name("markShotStopVideoFrameLab")
    static let markShotShowNotchShelf = Notification.Name("markShotShowNotchShelf")
    static let markShotAirDropLatestShelf = Notification.Name("markShotAirDropLatestShelf")
    static let deskAgentStartTalk = Notification.Name("deskAgentStartTalk")
}

final class HotkeyService {
    private var regionHotKey: EventHotKeyRef?
    private var fullScreenHotKey: EventHotKeyRef?
    private var recordClipHotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func register() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            DispatchQueue.main.async {
                switch hotKeyID.id {
                case 1:
                    MarkShotLog.write("hotkey pressed: region")
                    NotificationCenter.default.post(name: .markShotCaptureRegion, object: nil)
                case 2:
                    MarkShotLog.write("hotkey pressed: fullScreen")
                    NotificationCenter.default.post(name: .markShotCaptureFullScreen, object: nil)
                case 3:
                    MarkShotLog.write("hotkey pressed: recordClip")
                    NotificationCenter.default.post(name: .markShotRecordClip, object: nil)
                default:
                    MarkShotLog.write("hotkey pressed: unknown id \(hotKeyID.id)")
                    break
                }
            }

            return noErr
        }, 1, &eventType, nil, &eventHandler)

        let modifiers = UInt32(cmdKey | optionKey)
        let regionID = EventHotKeyID(signature: Self.signature, id: 1)
        let fullScreenID = EventHotKeyID(signature: Self.signature, id: 2)
        let recordClipID = EventHotKeyID(signature: Self.signature, id: 3)

        let regionStatus = RegisterEventHotKey(UInt32(kVK_ANSI_4), modifiers, regionID, GetEventDispatcherTarget(), 0, &regionHotKey)
        let fullStatus = RegisterEventHotKey(UInt32(kVK_ANSI_1), modifiers, fullScreenID, GetEventDispatcherTarget(), 0, &fullScreenHotKey)
        let recordStatus = RegisterEventHotKey(UInt32(kVK_ANSI_5), modifiers, recordClipID, GetEventDispatcherTarget(), 0, &recordClipHotKey)

        DispatchQueue.main.async {
            if regionStatus == noErr && fullStatus == noErr && recordStatus == noErr {
                MarkShotLog.write("hotkeys registered: region=ok full=ok record=ok")
                NotificationCenter.default.post(name: .markShotHotkeyStatus, object: "Hotkeys ready: Cmd+Opt+4 / Cmd+Opt+1 / Cmd+Opt+5")
            } else {
                MarkShotLog.write("hotkey registration failed: region=\(regionStatus) full=\(fullStatus) record=\(recordStatus)")
                NotificationCenter.default.post(name: .markShotHotkeyStatus, object: "Hotkey registration failed: region \(regionStatus), full \(fullStatus), record \(recordStatus)")
            }
        }
    }

    func unregister() {
        if let regionHotKey {
            UnregisterEventHotKey(regionHotKey)
        }
        if let fullScreenHotKey {
            UnregisterEventHotKey(fullScreenHotKey)
        }
        if let recordClipHotKey {
            UnregisterEventHotKey(recordClipHotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    private static let signature: OSType = 0x4D534854
}
