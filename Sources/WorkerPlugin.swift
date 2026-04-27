//
//  WorkerPlugin.swift
//  Mio Island plugin: 摸鱼侠
//
//  Principal class. Module = WorkerPlugin, Class = WorkerPlugin →
//  NSPrincipalClass = "WorkerPlugin.WorkerPlugin".
//

import AppKit
import SwiftUI

final class WorkerPlugin: NSObject, MioPlugin {
    var id: String { "worker" }
    var name: String { "摸鱼侠" }
    var icon: String { "fish.fill" }
    var version: String { "0.1.0" }

    func activate() {
        WorkerDebugLog.write("plugin activate")
        Task { @MainActor in
            WorkerStore.shared.start()
            WorkerNotificationCenter.shared.requestAuthorizationIfNeeded()
        }
    }

    func deactivate() {
        WorkerDebugLog.write("plugin deactivate")
        Task { @MainActor in
            WorkerStore.shared.stop()
        }
    }

    func makeView() -> NSView {
        let view = NSHostingView(rootView: ExpandedView())
        view.autoresizingMask = [.width, .height]
        return view
    }
}
