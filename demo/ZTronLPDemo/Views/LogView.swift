import SwiftUI

/// The log of one run: the verdict first, then facts, with details indented under them.
struct LogView: View {
    let log: RunLog

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(log.lines) { line in
                LogLineView(line: line, outcome: log.outcome)
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .padding(.vertical, 4)
    }
}

private struct LogLineView: View {
    let line: LogLine
    let outcome: RunLog.Outcome

    var body: some View {
        switch line.style {
        case .title:
            Text(line.text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        case .success, .stopped, .undecided, .failure:
            row {
                Image(systemName: outcome.symbol).foregroundStyle(outcome.color)
            } text: {
                Text(line.text).fontWeight(.semibold)
            }
        case .item:
            row {
                Text("•").foregroundStyle(.secondary)
            } text: {
                Text(line.text)
            }
        case .detail:
            row {
                Color.clear.frame(height: 1)
            } text: {
                Text(line.text).font(.footnote).foregroundStyle(.secondary)
            }
        case .warning:
            row {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } text: {
                Text(line.text)
            }
        }
    }

    /// A line with a fixed-width gutter, so details line up under the text they explain.
    private func row<Icon: View, Content: View>(
        @ViewBuilder icon: () -> Icon, @ViewBuilder text: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            icon()
                .frame(width: 20)
            text()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension RunLog.Outcome {
    var symbol: String {
        switch self {
        case .optimal: return "checkmark.circle.fill"
        case .infeasible: return "nosign"
        case .unbounded: return "infinity.circle.fill"
        case .undecided: return "questionmark.circle.fill"
        case .stopped: return "stop.circle.fill"
        case .failed: return "exclamationmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .optimal: return .green
        case .infeasible, .unbounded: return .purple
        case .undecided, .stopped: return .orange
        case .failed: return .red
        }
    }

    var label: String {
        switch self {
        case .optimal: return "Optimal"
        case .infeasible: return "Proven infeasible"
        case .unbounded: return "Proven unbounded"
        case .undecided: return "No verdict"
        case .stopped: return "Stopped by a limit"
        case .failed: return "Failed"
        }
    }
}
