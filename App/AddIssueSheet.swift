import SwiftUI
import AppCore

struct AddIssueSheet: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @State private var urlString = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add an issue")
                .font(.headline)
            TextField("https://github.com/owner/repo/issues/123", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .frame(width: 440)
            HStack {
                if model.isAdding {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Add") {
                    Task {
                        await model.addIssue(urlString: urlString)
                        if model.errorMessage == nil {
                            isPresented = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(urlString.isEmpty || model.isAdding)
            }
        }
        .padding(20)
    }
}
