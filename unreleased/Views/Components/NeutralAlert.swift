import SwiftUI

extension View {
    /// Presents an alert from an isolated view whose tint is the adaptive label
    /// color. SwiftUI otherwise inherits the app accent color for every
    /// non-destructive alert action.
    func neutralAlert<Actions: View, Message: View>(
        _ title: String,
        isPresented: Binding<Bool>,
        @ViewBuilder actions: @escaping () -> Actions,
        @ViewBuilder message: @escaping () -> Message
    ) -> some View {
        background {
            Color.clear
                .alert(
                    title,
                    isPresented: isPresented,
                    actions: actions,
                    message: message
                )
                .tint(Color(uiColor: .label))
        }
    }

    func neutralAlert<Actions: View>(
        _ title: String,
        isPresented: Binding<Bool>,
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        background {
            Color.clear
                .alert(title, isPresented: isPresented, actions: actions)
                .tint(Color(uiColor: .label))
        }
    }

    func neutralAlert<Data, Actions: View, Message: View>(
        _ title: String,
        isPresented: Binding<Bool>,
        presenting data: Data?,
        @ViewBuilder actions: @escaping (Data) -> Actions,
        @ViewBuilder message: @escaping (Data) -> Message
    ) -> some View {
        background {
            Color.clear
                .alert(
                    title,
                    isPresented: isPresented,
                    presenting: data,
                    actions: actions,
                    message: message
                )
                .tint(Color(uiColor: .label))
        }
    }
}
