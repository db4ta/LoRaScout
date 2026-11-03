import MapKit
import SwiftUI
import UIKit

struct ExportFile: Identifiable {
    var url: URL
    var id: URL { url }
}

struct ShareSheet: UIViewControllerRepresentable {
    var url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Renders the visible map section with its points into a .jpg file.
enum MapImage {
    struct LegendItem {
        var text: String
        var color: UIColor
    }

    private static let mapSize = CGSize(width: 1200, height: 1200)
    private static let bandHeight: CGFloat = 170
    private static let dotRadius: CGFloat = 9

    static func fittingRegion(_ points: [MapPoint]) -> MKCoordinateRegion? {
        guard let first = points.first else { return nil }
        var rect = MKMapRect(origin: MKMapPoint(first.coordinate), size: MKMapSize(width: 0, height: 0))
        for point in points {
            rect = rect.union(MKMapRect(origin: MKMapPoint(point.coordinate), size: MKMapSize(width: 0, height: 0)))
        }
        var region = MKCoordinateRegion(rect.insetBy(dx: -rect.width * 0.1 - 500, dy: -rect.height * 0.1 - 500))
        region.span.latitudeDelta = max(region.span.latitudeDelta, 0.002)
        region.span.longitudeDelta = max(region.span.longitudeDelta, 0.002)
        return region
    }

    /// `devices` are the ring colours of several testers, empty with one.
    static func render(region: MKCoordinateRegion, points: [MapPoint], legend: [LegendItem], devices: [LegendItem] = [],
                       summary: String, period: String) async throws -> URL {
        let bandHeight = Self.bandHeight + (devices.isEmpty ? 0 : 50)
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = mapSize
        options.scale = 1
        let snapshot = try await MKMapSnapshotter(options: options).start()

        let bounds = CGRect(origin: .zero, size: CGSize(width: mapSize.width, height: mapSize.height + bandHeight))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            UIColor.white.setFill()
            context.fill(bounds)
            snapshot.image.draw(at: .zero)
            for point in points {
                let center = snapshot.point(for: point.coordinate)
                let dot = CGRect(x: center.x - dotRadius, y: center.y - dotRadius, width: 2 * dotRadius, height: 2 * dotRadius)
                guard dot.intersects(CGRect(origin: .zero, size: mapSize)) else { continue }
                let path = UIBezierPath(ovalIn: dot)
                UIColor(point.color).setFill()
                path.fill()
                (point.ring.map { UIColor($0) } ?? .white).setStroke()
                path.lineWidth = point.ring == nil ? 2 : 5
                path.stroke()
            }
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: mapSize.height, width: mapSize.width, height: bandHeight))
            drawBand(top: mapSize.height, legend: legend, devices: devices, summary: summary, period: period)
        }

        guard let data = image.jpegData(compressionQuality: 0.9) else { throw CocoaError(.fileWriteUnknown) }
        let url = URL.temporaryDirectory.appending(path: "\(DatedCSV.stamp())_Karte.jpg")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func drawBand(top: CGFloat, legend: [LegendItem], devices: [LegendItem], summary: String, period: String) {
        let title: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 34), .foregroundColor: UIColor.black]
        let text: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.darkGray]
        (summary as NSString).draw(at: CGPoint(x: 30, y: top + 18), withAttributes: title)
        let date = "\(period) · LoRaScout, \(Date.now.germanText)"
        (date as NSString).draw(at: CGPoint(x: 30, y: top + 68), withAttributes: text)

        var x: CGFloat = 30
        for item in legend {
            let dot = CGRect(x: x, y: top + 124, width: 22, height: 22)
            item.color.setFill()
            UIBezierPath(ovalIn: dot).fill()
            let label = item.text as NSString
            label.draw(at: CGPoint(x: x + 30, y: top + 118), withAttributes: text)
            x += 30 + label.size(withAttributes: text).width + 36
        }
        x = 30
        for item in devices {
            let ring = UIBezierPath(ovalIn: CGRect(x: x + 3, y: top + 177, width: 18, height: 18))
            ring.lineWidth = 5
            item.color.setStroke()
            ring.stroke()
            let label = item.text as NSString
            label.draw(at: CGPoint(x: x + 30, y: top + 168), withAttributes: text)
            x += 30 + label.size(withAttributes: text).width + 36
        }
    }
}
