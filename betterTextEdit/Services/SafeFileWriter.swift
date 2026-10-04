import Foundation

/// Saves over a file without losing it, or anything attached to it.
///
/// A plain atomic write replaces the file with a brand-new one, and a new file
/// starts with nothing: the Finder tags, the colour label, the "where from"
/// note, any other extended attribute — all gone on the first ⌘S. So the new
/// contents are built beside the original, in the scratch directory macOS keeps
/// on the same volume for exactly this, and swapped in with `replaceItemAt`,
/// which keeps the original's attributes, permissions, and creation date. If
/// writing fails partway, the original was never touched.
enum SafeFileWriter {
    /// Calls `produce` to write the new contents to a scratch location, then
    /// moves them into place.
    static func write(to url: URL, _ produce: (URL) throws -> Void) throws {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }

        let files = FileManager.default
        guard files.fileExists(atPath: url.path) else {
            // Nothing to preserve, so nothing to swap.
            try produce(url)
            return
        }

        let scratch = try files.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: url,
            create: true
        )
        defer { try? files.removeItem(at: scratch) }

        let temporary = scratch.appendingPathComponent(url.lastPathComponent)
        try produce(temporary)
        _ = try files.replaceItemAt(url, withItemAt: temporary)
    }

    static func write(_ data: Data, to url: URL) throws {
        try write(to: url) { try data.write(to: $0) }
    }
}
