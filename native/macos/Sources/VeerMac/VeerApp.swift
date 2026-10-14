import SwiftUI

@main
struct VeerApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    private let model = EditorModel()
    var body: some Scene {
        Window("Veer AI 编辑器", id: "editor") {
            EditorView(model: model).tint(Color(nsColor: .systemGreen))
                .background(WindowProtection(lifecycle: lifecycle, model: model))
        }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1320, height: 900)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
