//
//  MioPlugin.swift
//  Mio Island Plugin SDK (verbatim copy from host).
//  Runtime conformance is by ObjC selector, not module identity.
//

import AppKit

@objc protocol MioPlugin: AnyObject {
    var id: String { get }
    var name: String { get }
    var icon: String { get }
    var version: String { get }
    func activate()
    func deactivate()
    func makeView() -> NSView
    @objc optional func viewForSlot(_ slot: String, context: [String: Any]) -> NSView?
}
