import SwiftUI

/// One tab per solving strategy.
///
/// On iPhone and iPad the strategies are tabs. A Mac shows tabs of this kind as a sidebar, so
/// there the strategies form the first of three columns: strategy › example › problem.
struct ContentView: View {
    var body: some View {
        #if os(macOS)
        StrategyColumns()
        #else
        StrategyTabs()
        #endif
    }
}

/// iPhone and iPad: a tab per strategy, each with its own example list and problem page.
private struct StrategyTabs: View {
    @State private var tab: StrategyKind = .simplex

    var body: some View {
        TabView(selection: $tab) {
            ForEach(StrategyKind.allCases) { kind in
                Tab(kind.title, systemImage: kind.systemImage, value: kind) {
                    StrategyView(kind: kind)
                }
            }
        }
    }
}

/// Mac: the strategies, the selected strategy's examples, and the selected problem, side by
/// side. A tab view in sidebar style would put a split view inside another one, and macOS then
/// indents the problem page twice; one three-column split view avoids that.
private struct StrategyColumns: View {
    @State private var kind: StrategyKind? = .simplex
    /// The selected example of each strategy, so switching strategies keeps each one's place.
    @State private var selections: [StrategyKind: Example.ID] = [:]

    var body: some View {
        NavigationSplitView {
            List(selection: $kind) {
                ForEach(StrategyKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.systemImage)
                        .tag(kind)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } content: {
            Group {
                if let kind {
                    ExampleList(kind: kind, selection: $selections[kind])
                        .id(kind)
                } else {
                    ContentUnavailableView("Choose a strategy", systemImage: "sidebar.left")
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            if let kind {
                ProblemPage(kind: kind, exampleID: selections[kind])
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(RunStore())
}
