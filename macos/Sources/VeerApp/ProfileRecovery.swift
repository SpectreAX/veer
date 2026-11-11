extension ProxyStore {
    /// A failed start during onboarding must be able to reach the profile picker and importer.
    /// Navigation alone leaves the current configuration and network state untouched.
    func manageProfiles() {
        guard !profiles.isEmpty else { return }
        onboarding = nil
        page = .proxies
    }
}
