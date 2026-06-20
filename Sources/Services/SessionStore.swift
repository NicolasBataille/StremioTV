import Foundation
import Observation

/// État d'authentification de l'utilisateur et orchestration du chargement
/// des add-ons du compte.
@Observable
@MainActor
final class SessionStore {
    enum Status: Equatable {
        case loggedOut    // écran de connexion
        case working      // login / restauration en cours
        case guest        // utilisation sans compte (Cinemeta + ajouts manuels)
        case loggedIn     // connecté au compte Stremio
    }

    private(set) var status: Status = .working
    private(set) var user: APIUser?
    private(set) var errorMessage: String?

    let repository = AddonRepository()
    let library = LibraryStore()

    private let api = StremioAPIClient()
    private let keychain = KeychainStore()
    private let authAccount = "authKey"

    var isReady: Bool { status == .loggedIn || status == .guest }

    /// Renvoie vers l'écran de connexion (depuis le mode invité).
    func requestLogin() {
        status = .loggedOut
    }

    /// Connecte la session à partir d'un authKey déjà obtenu (utilisé pour les
    /// tests : injecté localement, sans que le mot de passe transite).
    func bootstrap(authKey: String) async {
        keychain.set(authKey, for: authAccount)
        await restore()
    }

    /// Au lancement : tente de restaurer une session via l'authKey du Keychain.
    func restore() async {
        guard let key = keychain.get(authAccount) else {
            status = .loggedOut
            return
        }
        status = .working
        do {
            let auth = try await api.loginWithToken(key)
            await finishLogin(auth)
        } catch {
            keychain.delete(authAccount)
            status = .loggedOut
        }
    }

    func login(email: String, password: String) async {
        status = .working
        errorMessage = nil
        do {
            let auth = try await api.login(email: email, password: password)
            await finishLogin(auth)
        } catch {
            errorMessage = error.localizedDescription
            status = .loggedOut
        }
    }

    func continueAsGuest() {
        status = .guest
    }

    func logout() async {
        if let key = keychain.get(authAccount) {
            await api.logout(authKey: key)
        }
        keychain.delete(authAccount)
        user = nil
        repository.clearAccountAddons()
        library.clear()
        status = .loggedOut
    }

    /// Recharge la collection d'add-ons depuis le compte.
    func refreshAddons() async {
        guard let key = keychain.get(authAccount) else { return }
        if let addons = try? await api.addonCollection(authKey: key) {
            repository.setAccountAddons(addons)
        }
    }

    private func finishLogin(_ auth: AuthResponse) async {
        keychain.set(auth.authKey, for: authAccount)
        user = auth.user
        if let addons = try? await api.addonCollection(authKey: auth.authKey) {
            repository.setAccountAddons(addons)
        }
        await library.refresh()
        status = .loggedIn
    }
}
