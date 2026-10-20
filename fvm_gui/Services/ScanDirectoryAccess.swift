import Foundation

actor ScanDirectoryAccess {
    private var activeURLs: [URL] = []

    func acquire(_ records: [ApprovedScanDirectory]) -> [URL] {
        activeURLs.removeAll()
        var resolvedURLs: [URL] = []
        for record in records {
            let url: URL
            var stale = false
            if let bookmark = record.bookmark,
               let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                url = resolved
            } else { url = record.url }
            resolvedURLs.append(url)
            if url.startAccessingSecurityScopedResource() { activeURLs.append(url) }
        }
        return resolvedURLs
    }

    func release() {
        activeURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        activeURLs.removeAll()
    }
}
