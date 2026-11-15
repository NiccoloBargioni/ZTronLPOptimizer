import SwiftUI

/// One tab per solving strategy.
struct ContentView: View {
    @State private var tab: StrategyKind = .simplex

    var body: some View {
        TabView(selection: $tab) {
            ForEach(StrategyKind.allCases) { kind in
                Tab(kind.title, systemImage: kind.systemImage, value: kind) {
                    StrategyView(kind: kind)
                }
            }
        }
        #if os(macOS)
        // Seven tabs do not fit the toolbar next to the split view's controls; as a sidebar
        // they read as the first level of strategy › example › problem.
        .tabViewStyle(.sidebarAdaptable)
        #endif
    }
}

#Preview {
    ContentView()
        .environment(RunStore())
}
