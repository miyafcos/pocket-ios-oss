import SwiftUI

/// Present the saved shelf immediately while preserving the NavigationStack.
struct SkillShelfImmediateNavigationStyle: PrimitiveButtonStyle {
    @Environment(PocketStore.self) private var store
    func makeBody(configuration: Configuration) -> some View {
        Button {
            SkillShelfMetrics.shared.beginToolbarTap()
            let navigate = {
                var transaction = Transaction(animation:nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { configuration.trigger() }
            }
            if !SkillShelfFastOpening.begin(base:store.base,then:navigate) { navigate() }
        } label: {
            configuration.label.foregroundStyle(Color("Accent"))
                .background(SkillShelfToolbarTapProbe().frame(width: 0, height: 0))
        }.buttonStyle(.plain)
    }
}
