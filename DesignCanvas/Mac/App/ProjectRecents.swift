// Ported from ai.cst.2 `apps/desktop/DesignCanvasDesktop/ProjectRecents.swift`, unchanged.

import Foundation

final class ProjectRecents {
    private let defaults: UserDefaults
    private let key = "recentProjects"
    private let max: Int

    init(defaults: UserDefaults = .standard, max: Int = 8) {
        self.defaults = defaults
        self.max = max
    }

    var all: [URL] {
        (defaults.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }

    func add(_ url: URL) {
        var paths = defaults.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        if paths.count > max { paths = Array(paths.prefix(max)) }
        defaults.set(paths, forKey: key)
    }
}
