//
//  ProjectLocations.swift
//  Dance Player
//
//  Which `.dbdj` projects were opened recently.
//
//  Under the app sandbox this isn't as simple as storing a path: permission to reach a file
//  the DJ picked is lost on quit unless a security-scoped bookmark is saved.
//

import Foundation
import AppKit

enum ProjectLocations {
    private static let recentsKey = "recentProjectBookmarks"
    private static let maximumRecents = 8

    // MARK: - Recent projects

    struct RecentProject: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let url: URL
    }

    /// Records a project file as recently used, most recent first.
    static func noteRecentProject(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)

        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        var stored = UserDefaults.standard.array(forKey: recentsKey) as? [Data] ?? []
        stored.removeAll { existing in
            resolveRecent(existing)?.standardizedFileURL == url.standardizedFileURL
        }
        stored.insert(data, at: 0)
        UserDefaults.standard.set(Array(stored.prefix(maximumRecents)), forKey: recentsKey)
    }

    /// Recent projects that still exist on disk. Missing files are dropped silently — a DJ
    /// doesn't need to be told about a project they deleted themselves.
    static func recentProjects() -> [RecentProject] {
        let stored = UserDefaults.standard.array(forKey: recentsKey) as? [Data] ?? []
        var results: [RecentProject] = []
        var survivingBookmarks: [Data] = []

        for data in stored {
            guard let url = resolveRecent(data),
                  FileManager.default.fileExists(atPath: url.path)
            else { continue }
            survivingBookmarks.append(data)
            results.append(
                RecentProject(name: url.deletingPathExtension().lastPathComponent, url: url)
            )
        }

        if survivingBookmarks.count != stored.count {
            UserDefaults.standard.set(survivingBookmarks, forKey: recentsKey)
        }
        return results
    }

    /// Re-acquires access to a recent project and hands back its URL.
    static func openRecent(_ recent: RecentProject) -> URL? {
        let stored = UserDefaults.standard.array(forKey: recentsKey) as? [Data] ?? []
        for data in stored {
            if let url = resolveRecent(data),
               url.standardizedFileURL == recent.url.standardizedFileURL {
                _ = url.startAccessingSecurityScopedResource()
                return url
            }
        }
        return nil
    }

    static func clearRecentProjects() {
        UserDefaults.standard.removeObject(forKey: recentsKey)
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    private static func resolveRecent(_ data: Data) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
}
