import Foundation

/// The complete list of features, in display order.
///
/// Adding a feature is one file under `Features/` plus one line here. The dropdown, the
/// sidebar, the detail pane, persistence and permission gating all follow automatically.
enum FeatureRegistry {
    static func makeAll() -> [Feature] {
        [
            CutPasteFeature(),
            ClipboardFeature(),
            QuitOnCloseFeature(),
            FileRulesFeature(),
            TrashCleanupFeature(),
            AppSweepFeature(),
            KeepAwakeFeature(),
        ]
    }
}
