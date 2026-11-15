import SwiftUI
import ZTronLPOptimizer

/// One example on one tab, top to bottom: the problem, its formulation, the Solve button, and
/// the log of the last run under it.
struct ExampleDetailView: View {
    let kind: StrategyKind
    let example: Example
    @Environment(RunStore.self) private var store

    /// The Solve button's row, which the page scrolls to when a run starts and ends, so the
    /// log under it comes into view.
    private static let solveRow = "solve"

    var body: some View {
        ScrollViewReader { proxy in
            form
                .onChange(of: phaseStep) { _, step in
                    guard step != 0 else { return }
                    withAnimation { proxy.scrollTo(Self.solveRow, anchor: .top) }
                }
        }
        .navigationTitle(example.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var form: some View {
        Form {
            Section("Problem") {
                Text(example.summary)
                HStack(spacing: 6) {
                    TagLabel(example.problemClass.rawValue)
                    TagLabel(example.conditioning.rawValue)
                }
            }

            Section("Formulation") {
                MonospacedBlock(example.formulation)
                DisclosureGroup("LP file, as the engine reads it") {
                    EngineFormulation(example: example)
                }
            }

            Section("Solve") {
                if kind.variants.count > 1 {
                    Picker(kind.variantTitle, selection: variant) {
                        ForEach(kind.variants) { variant in
                            Text(variant.label).tag(variant.id)
                        }
                    }
                }
                LabeledContent("Strategy") {
                    Text(kind.strategy(variant.wrappedValue, for: example).engineName)
                        .font(.callout.monospaced())
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Limits", value: limits)
                SolveButton(kind: kind, example: example)
                    .id(Self.solveRow)
            }

            switch store.phase(kind, example) {
            case .idle:
                EmptyView()
            case .running(let since):
                Section("Log") {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Solving…")
                        Spacer()
                        Text(since, style: .timer)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            case .finished(let log):
                Section("Log") {
                    LogView(log: log)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 0 before the first run, 1 while running, 2 once the log is in.
    private var phaseStep: Int {
        switch store.phase(kind, example) {
        case .idle: return 0
        case .running: return 1
        case .finished: return 2
        }
    }

    private var variant: Binding<Variant.ID> {
        Binding(
            get: { store.variant(kind, example) },
            set: { store.setVariant($0, kind, example) })
    }

    private var limits: String {
        let seconds = example.limits.seconds ?? Runner.defaultTimeLimit
        var parts = ["\(Format.number(seconds)) s"]
        if let nodes = example.limits.nodes, kind.honorsNodeLimit {
            parts.append("\(Format.count(nodes)) nodes")
        }
        return parts.joined(separator: ", ")
    }
}

/// Solve while idle, Stop while running.
private struct SolveButton: View {
    let kind: StrategyKind
    let example: Example
    @Environment(RunStore.self) private var store

    var body: some View {
        let running = store.isRunning(kind, example)
        Button {
            if running {
                store.stop(kind, example)
            } else {
                store.solve(kind, example)
            }
        } label: {
            Label(running ? "Stop" : "Solve", systemImage: running ? "stop.fill" : "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(running ? .red : .accentColor)
    }
}

/// The model in LP file format, written from the compiled problem.
private struct EngineFormulation: View {
    let example: Example
    @State private var text: String?

    var body: some View {
        Group {
            if let text {
                MonospacedBlock(text)
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                text = try LPFormat.write(example.build().lp)
            } catch {
                text = "The model could not be written: \(error)"
            }
        }
    }
}

/// Monospaced text that never wraps, so columns stay aligned: full size when it fits, smaller
/// when that fits, and scrolling sideways on narrow screens.
private struct MonospacedBlock: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            block(.caption)
            block(.caption2)
            ScrollView(.horizontal) {
                block(.caption2)
            }
            .scrollIndicatorsFlash(onAppear: true)
        }
        .textSelection(.enabled)
    }

    private func block(_ style: Font.TextStyle) -> some View {
        Text(text)
            .font(.system(style, design: .monospaced))
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, 4)
    }
}

/// A small capsule label.
private struct TagLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}

#Preview {
    NavigationStack {
        ExampleDetailView(kind: .simplex, example: Catalog.furniture)
    }
    .environment(RunStore())
}
