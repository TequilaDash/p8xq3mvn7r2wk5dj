//
//  MultitaskManager.swift
//  LiveContainer
//
//  Created by s s on 2026/3/20.
//

import Foundation

// Logical order is newest first. Rendering order is deliberately separate:
// LCOrbit's negative-distance compression expects the focal card at the end.
struct MultitaskRecency {
    private(set) var identifiers: [String] = []

    mutating func record(_ identifier: String) {
        guard !identifier.isEmpty else { return }
        identifiers.removeAll { $0 == identifier }
        identifiers.insert(identifier, at: 0)
    }

    mutating func remove(_ identifier: String) {
        identifiers.removeAll { $0 == identifier }
    }

    func ordered(_ candidates: [String]) -> [String] {
        var seen = Set<String>()
        let unique = candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
        let available = Set(unique)
        let known = identifiers.filter { available.contains($0) }
        let recorded = Set(known)
        // An already-open scene without an event has unknown recency; do not
        // invent a timestamp or reorder known usage when it is discovered.
        return known + unique.filter { !recorded.contains($0) }
    }
}

enum MultitaskMode : Int {
    case virtualWindow = 0
    case nativeWindow = 1
}

@objc class MultitaskManager : NSObject {
    // Changed only on the main thread
    static private var usingMultitaskContainers : [String] = []
    private static var recency = MultitaskRecency()
    static let recencyChanged = Notification.Name("LCMultitaskRecencyChanged")

    @objc(recordUseOfContainer:)
    class func recordUse(container: String) {
        precondition(Thread.isMainThread)
        guard !container.isEmpty else { return }
        recency.record(container)
        NotificationCenter.default.post(name: recencyChanged, object: container)
    }

    class func recentOrder(candidates: [String]) -> [String] {
        precondition(Thread.isMainThread)
        return recency.ordered(candidates)
    }
    
    @objc class func registerMultitaskContainer(container: String) {
        precondition(Thread.isMainThread)
        guard !container.isEmpty, !usingMultitaskContainers.contains(container) else { return }
        usingMultitaskContainers.append(container)
    }
    
    @objc class func unregisterMultitaskContainer(container: String) {
        precondition(Thread.isMainThread)
        // Process exit is not an App Switcher dismissal. Keep last-use order
        // for any retained recent task/termination card; do not mark it used.
        usingMultitaskContainers.removeAll(where: { c in
            return c == container
        })
    }
    
    @objc(isUsingWithContainer:) class func isUsing(container: String) -> Bool {
        return usingMultitaskContainers.contains { c in
            return c == container
        }
    }
    
    @objc class func isMultitasking() -> Bool {
        return usingMultitaskContainers.count > 0
    }
}
