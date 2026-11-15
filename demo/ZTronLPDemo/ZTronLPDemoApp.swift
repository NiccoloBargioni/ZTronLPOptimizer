// A small tour of ZTronLPOptimizer: one tab per solving strategy, a few example problems per
// tab, and a Solve button that runs the tab's strategy and logs what happened.

import SwiftUI

@main
struct ZTronLPDemoApp: App {
    @State private var store = RunStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #endif
    }
}
