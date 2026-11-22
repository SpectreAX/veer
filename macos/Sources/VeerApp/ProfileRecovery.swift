extension ProxyStore {
    /// Opens Manage Profiles, from any page. A failed start during onboarding must be able to reach
    /// the profile picker and importer; opening it leaves the configuration and network untouched.
    func manageProfiles() {
        guard !profiles.isEmpty else { return }
        onboarding = nil
        showingProfiles = true
    }
}
