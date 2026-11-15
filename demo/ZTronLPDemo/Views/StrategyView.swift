import SwiftUI

/// A strategy's tab on iPhone and iPad: the strategy's examples and the selected example's page.
/// On iPhone the two collapse into one navigation stack.
struct StrategyView: View {
    let kind: StrategyKind
    @State private var selection: Example.ID?
    /// Both columns from the start: an iPad in portrait would otherwise hide the list behind
    /// the sidebar button and open on an empty page.
    @State private var visibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            ExampleList(kind: kind, selection: $selection)
        } detail: {
            ProblemPage(kind: kind, exampleID: selection)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

/// What a strategy does, followed by its examples grouped by kind.
struct ExampleList: View {
    let kind: StrategyKind
    @Binding var selection: Example.ID?

    var body: some View {
        List(selection: $selection) {
            Section {
                Text(kind.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(kind.groups) { group in
                Section(group.title) {
                    ForEach(group.examples) { example in
                        NavigationLink(value: example.id) {
                            ExampleRow(kind: kind, example: example)
                        }
                    }
                }
            }
        }
        .navigationTitle(kind.title)
    }
}

/// The selected example's page, or a hint to pick one.
struct ProblemPage: View {
    let kind: StrategyKind
    let exampleID: Example.ID?

    var body: some View {
        if let example = kind.example(id: exampleID) {
            ExampleDetailView(kind: kind, example: example)
                .id(example.id)
        } else {
            ContentUnavailableView(
                "Choose a problem",
                systemImage: kind.systemImage,
                description: Text("Pick an example, then press Solve to run \(kind.title) on it."))
        }
    }
}

/// An example in the list: its title, a one-line description, and the outcome of its last run.
struct ExampleRow: View {
    let kind: StrategyKind
    let example: Example
    @Environment(RunStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(example.title)
                Text(example.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            switch store.phase(kind, example) {
            case .idle:
                EmptyView()
            case .running:
                ProgressView()
                    .controlSize(.small)
            case .finished(let log):
                Image(systemName: log.outcome.symbol)
                    .foregroundStyle(log.outcome.color)
                    .accessibilityLabel(log.outcome.label)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    StrategyView(kind: .branchAndBound)
        .environment(RunStore())
}
