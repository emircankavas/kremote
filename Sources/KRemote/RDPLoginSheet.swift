import SwiftUI

/// Asks for the credentials an RDP server demands when the tree has none stored
/// (or the stored ones were rejected). Mirrors what any RDP client pops up.
struct RDPLoginSheet: View {
    let request: RDPCredentialRequest
    let onSubmit: (_ username: String, _ domain: String, _ password: String) -> Void
    let onCancel: () -> Void

    @State private var username: String
    @State private var domain: String
    @State private var password = ""
    @FocusState private var focus: Field?

    private enum Field { case username, domain, password }

    init(
        request: RDPCredentialRequest,
        onSubmit: @escaping (String, String, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _username = State(initialValue: request.username)
        _domain = State(initialValue: request.domain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.secondary)
                Text("Sign in")
                    .font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()

            Form {
                Text("The server asked for credentials and none are stored for this connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Username", text: $username)
                    .focused($focus, equals: .username)
                TextField("Domain", text: $domain)
                    .focused($focus, equals: .domain)
                    .help("Optional. Windows domain, or leave as-is from the connection.")
                SecureField("Password", text: $password)
                    .focused($focus, equals: .password)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("Use the connection editor to save these for next time.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    onSubmit(username.trimmingCharacters(in: .whitespacesAndNewlines),
                             domain.trimmingCharacters(in: .whitespacesAndNewlines),
                             password)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty && request.username.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 420)
        .onAppear {
            // Land on whichever field is still empty.
            focus = username.isEmpty ? .username : (password.isEmpty ? .password : .username)
        }
    }
}
