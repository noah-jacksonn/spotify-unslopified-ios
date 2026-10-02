import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var isSigningIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            BarsMark(color: look.palette.accent, size: 54, playing: true)
                .padding(.bottom, 28)
            Text("Focused")
                .font(look.display(44))
                .tracking(look.titleTracking)
                .foregroundStyle(look.palette.text)
            Text("Your music, without the feed.")
                .font(look.font(19))
                .foregroundStyle(look.palette.muted)
                .padding(.top, 6)
            Spacer()

            if let error = model.signInError {
                Text(error)
                    .font(look.font(14))
                    .foregroundStyle(look.palette.accent)
                    .padding(.bottom, 14)
            }
            Button(action: signIn) {
                HStack {
                    if isSigningIn { ProgressView().tint(look.palette.onAccent) }
                    Text("Connect Spotify")
                }
                .font(look.font(17, .semibold))
                .foregroundStyle(look.palette.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(look.palette.accent, in: Capsule())
            }
            .buttonStyle(PressScale())
            .disabled(isSigningIn)

            Button {
                model.startPreview()
            } label: {
                Text("Try with sample music")
                    .font(look.font(16, .medium))
                    .foregroundStyle(look.palette.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .buttonStyle(PressScale())
            .padding(.top, 6)

            Text("Needs Spotify Premium and the Spotify app on this phone. Music plays through Spotify.")
                .font(look.font(12))
                .foregroundStyle(look.palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .background(AmbientBackground())
    }

    private func signIn() {
        Task {
            isSigningIn = true
            defer { isSigningIn = false }
            model.signInError = nil
            do {
                let url = model.auth.authorizeURL()
                let callback = try await webAuthenticationSession.authenticate(
                    using: url,
                    callbackURLScheme: Config.callbackScheme,
                    preferredBrowserSession: .shared
                )
                await model.signIn(callback: callback)
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                // Closed the sheet; nothing to say.
            } catch {
                model.signInError = error.localizedDescription
            }
        }
    }
}
