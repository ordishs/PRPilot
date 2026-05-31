import SwiftUI
import PRPilotModels
import AppCore

struct ManageLocalClonesView: View {
    let model: AppModel
    @Binding var isPresented: Bool
    @State private var showingFolderPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Local Clones").font(.headline)
                Spacer()
                Button("Add…") { showingFolderPicker = true }
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            if model.registeredRepos.isEmpty {
                Text("No local clones registered. Click Add… to choose a folder.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else {
                List(model.registeredRepos) { repo in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(repo.remoteIdentity)
                                .font(.callout)
                                .bold()
                            Text(tildeShortened(repo.localClonePath))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task { await model.removeRegisteredRepo(remoteIdentity: repo.remoteIdentity) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 220)
            }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 320)
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task { await model.registerLocalClone(at: url.path) }
        }
    }

    private func tildeShortened(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
