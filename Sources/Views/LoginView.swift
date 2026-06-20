import SwiftUI

/// Connexion au compte Stremio (e-mail / mot de passe), ou accès invité.
struct LoginView: View {
    @Environment(SessionStore.self) private var session
    @State private var email = ""
    @State private var password = ""

    private var canSubmit: Bool {
        !email.isEmpty && !password.isEmpty && session.status != .working
    }

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "play.tv.fill").font(.system(size: 70))
            Text("StremioTV").font(.largeTitle.bold())
            Text("Connecte-toi à ton compte Stremio pour retrouver tous tes add-ons, dont RealDebrid.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)

            VStack(spacing: 16) {
                TextField("E-mail", text: $email)
                    .textContentType(.emailAddress)
                SecureField("Mot de passe", text: $password)
                    .textContentType(.password)
            }
            .frame(maxWidth: 760)

            if let error = session.errorMessage {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            Button {
                Task { await session.login(email: email, password: password) }
            } label: {
                if session.status == .working {
                    ProgressView()
                } else {
                    Text("Se connecter").frame(maxWidth: 760)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)

            Button("Continuer sans compte (Cinemeta)") {
                session.continueAsGuest()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("guestButton")
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
