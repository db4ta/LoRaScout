import Charts
import SwiftUI

extension PeriodEntry {
    var lossText: String { lossRate.text { $0.formatted(.percent.precision(.fractionLength(1)).locale(Locale(identifier: "de_DE"))) } }
    var detail: String { "\(count) Punkte · Verlust \(lossText)" }
}

/// Period choice with back and forward, shown at the top of Auswertung.
struct PeriodPicker: View {
    @Environment(CoverageStore.self) private var coverage

    private var kind: Binding<PeriodKind> {
        Binding(get: { coverage.period.kind }, set: { coverage.selectKind($0) })
    }

    var body: some View {
        Picker("Zeitraum", selection: kind) {
            ForEach(PeriodKind.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(minHeight: 44)
        if coverage.period.kind == .all {
            Text(coverage.period.title).font(.headline)
        } else {
            HStack {
                Button("Zurück", systemImage: "chevron.left") { coverage.period = coverage.period.moved(by: -1) }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                Spacer()
                Text(coverage.period.title).font(.headline).multilineTextAlignment(.center)
                Spacer()
                Button("Weiter", systemImage: "chevron.right") { coverage.period = coverage.period.moved(by: 1) }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled((coverage.period.moved(by: 1).first ?? .init(year: 0, month: 1, day: 1)) > DayKey(date: .now, timeZone: .current))
            }
            .buttonStyle(.borderless)
        }
    }
}

/// Loss over time, one series, so the title names it and no legend is needed.
struct LossChart: View {
    var entries: [PeriodEntry]
    @State private var selection: Date?

    private func date(_ day: DayKey) -> Date {
        Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? .distantPast
    }

    private var points: [(entry: PeriodEntry, date: Date, rate: Double)] {
        entries.compactMap { entry in
            guard let rate = entry.lossRate, let first = entry.period.first else { return nil }
            return (entry, date(first), rate * 100)
        }
    }

    private var picked: (entry: PeriodEntry, date: Date, rate: Double)? {
        guard let selection else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }

    var body: some View {
        let points = points
        if points.isEmpty {
            Text("Noch keine Werte: Für die Verlustquote braucht es Zeilen mit bekanntem Empfang.")
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            Text(picked.map { "\($0.entry.period.title): \($0.entry.lossText)" } ?? "Antippen zeigt den Wert")
                .font(.footnote).foregroundStyle(.secondary)
            Chart {
                ForEach(points, id: \.date) { point in
                    LineMark(x: .value("Zeit", point.date), y: .value("Verlust", point.rate))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("Zeit", point.date), y: .value("Verlust", point.rate))
                        .symbolSize(40)
                        .accessibilityLabel(point.entry.period.title)
                        .accessibilityValue(point.entry.lossText)
                }
                if let picked {
                    RuleMark(x: .value("Auswahl", picked.date)).foregroundStyle(.secondary)
                }
            }
            .chartXSelection(value: $selection)
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel { Text("\(value.as(Int.self) ?? 0) %") }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.defaultDigits).locale(Locale(identifier: "de_DE")))
                }
            }
            .frame(height: 170)
        }
    }
}

/// Years, months and days with data like the folders of the archive, tapping one selects it.
struct ArchiveListView: View {
    @Environment(CoverageStore.self) private var coverage
    @Environment(\.dismiss) private var dismiss

    private func row(_ title: String, _ entry: PeriodEntry) -> some View {
        Button {
            coverage.period = entry.period
            dismiss()
        } label: {
            LabeledContent(title, value: entry.detail)
        }
        .foregroundStyle(.primary)
    }

    var body: some View {
        let device = coverage.deviceFilter
        let days = coverage.archive.entries(.day, device: device), months = coverage.archive.entries(.month, device: device)
        List {
            if coverage.deviceTags.count > 1 {
                Section { DeviceFilterPicker() }
            }
            ForEach(coverage.archive.entries(.year, device: device).reversed()) { year in
                Section {
                    row("Ganzes Jahr", year)
                    ForEach(months.filter { year.period.contains($0.period.anchor) }.reversed()) { month in
                        DisclosureGroup {
                            ForEach(days.filter { month.period.contains($0.period.anchor) }.reversed()) { day in
                                row(day.period.title, day)
                            }
                        } label: {
                            row(Period.monthNames[month.period.anchor.month - 1], month)
                        }
                    }
                } header: {
                    Text(year.period.title)
                }
            }
        }
        .overlay {
            if days.isEmpty {
                ContentUnavailableView("Archiv ist leer", systemImage: "archivebox",
                                       description: Text("Jeder Log-Download landet automatisch hier."))
            }
        }
        .navigationTitle("Archiv")
    }
}
