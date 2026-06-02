import SwiftUI
import AppCore
import PRPilotModels

struct NewTaskSheet: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @State private var repoKey: String = ""
    @State private var branch: String = ""

    private var repos: [RegisteredRepo] { model.registeredRepos }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Task")
                .font(.headline)
            if repos.isEmpty {
                Text("No registered repositories. Open a PR from a repo first to register its clone, then create tasks against it.")
                    .font(.callout).foregroundStyle(.secondary).frame(width: 440, alignment: .leading)
            } else {
                if repos.count > 1 {
                    Picker("Repo", selection: $repoKey) {
                        ForEach(repos) { repo in
                            Text(repo.remoteIdentity.replacingOccurrences(of: "github.com/", with: "")).tag(repo.remoteIdentity)
                        }
                    }
                    .frame(width: 440)
                }
                TextField("new branch name (e.g. feat/parallel-validation)", text: $branch)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 440)
                if let base = model.registeredDefaultBase(for: repoKey) {
                    Text("Branches off \(base).").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Create") {
                    Task {
                        await model.createTask(repoKey: repoKey, branch: branch)
                        if model.errorMessage == nil { isPresented = false }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(repoKey.isEmpty || branch.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear {
            if repoKey.isEmpty { repoKey = repos.first?.remoteIdentity ?? "" }
        }
    }
}
