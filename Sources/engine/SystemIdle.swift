//
//  SystemIdle.swift
//  摸鱼侠 plugin
//
//  Returns "seconds since the user last touched any input device". This
//  is the ground truth for "is a human at the keys right now." Unlike
//  Date()-since-startTimestamp, it survives sleep/lid-close/lock cleanly:
//  while no input arrives, the counter grows; the moment the user taps
//  a key it drops to ~0. The sit-timer uses it to distinguish "sat at
//  the desk for 45 minutes" from "left for lunch with the lid open."
//

import CoreGraphics
import Foundation

enum SystemIdle {
    /// Seconds since the last user input event of any kind.
    /// CGEventType is an enum and Swift doesn't expose the C-level
    /// kCGAnyInputEventType wildcard, so we iterate the events that
    /// matter for "is the user active" and take the minimum.
    static var seconds: TimeInterval {
        let types: [CGEventType] = [
            .mouseMoved,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged,
            .keyDown,
            .scrollWheel
        ]
        var minVal = Double.greatestFiniteMagnitude
        for t in types {
            let v = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: t)
            if v < minVal { minVal = v }
        }
        return minVal == .greatestFiniteMagnitude ? 0 : minVal
    }
}
