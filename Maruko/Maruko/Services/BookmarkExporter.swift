import Foundation
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct BookmarkExporter {
    func exportGroup(_ group: String, context: ModelContext) throws -> String {
        let descriptor = FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.group == group },
            sortBy: [SortDescriptor(\Bookmark.title, order: .forward)]
        )

        let bookmarks = try context.fetch(descriptor)
        return generateNetscapeHTML(group: group, bookmarks: bookmarks)
    }

    func save(html: String, defaultName: String) throws {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = defaultName
        panel.title = "Export Bookmarks"

        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }

        try html.write(to: destination, atomically: true, encoding: .utf8)
    }

    private func generateNetscapeHTML(group: String, bookmarks: [Bookmark]) -> String {
        var lines: [String] = []
        lines.append("<!DOCTYPE NETSCAPE-Bookmark-file-1>")
        lines.append("<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">")
        lines.append("<TITLE>Bookmarks</TITLE>")
        lines.append("<H1>Bookmarks</H1>")
        lines.append("<DL><p>")
        lines.append("<DT><H3>\(escapeHTML(group))</H3>")
        lines.append("<DL><p>")

        for bookmark in bookmarks {
            let title = escapeHTML(bookmark.title)
            let href = escapeHTML(bookmark.url)
            lines.append("<DT><A HREF=\"\(href)\">\(title)</A>")
        }

        lines.append("</DL><p>")
        lines.append("</DL><p>")

        return lines.joined(separator: "\n")
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
