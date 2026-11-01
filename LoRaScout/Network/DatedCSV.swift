import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A CSV shared as e.g. 20261101_233145_Server-Log.csv. The time is taken when the share starts, so names stay unique.
struct DatedCSV: Transferable {
    let source: URL
    let name: String

    static func stamp(_ date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { SentTransferredFile(try $0.stampedCopy()) }
    }

    private func stampedCopy() throws -> URL {
        let target = URL.temporaryDirectory.appending(path: "\(Self.stamp())_\(name).csv")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }
}
