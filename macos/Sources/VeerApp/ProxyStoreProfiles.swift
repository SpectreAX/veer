import Foundation
import VeerCore
import VeerProxy

/// Profiles: switching, importing, updating and deleting them.
extension ProxyStore {
    // MARK: Profiles

    /// Switches profile. With the core running this is one transaction, one at a time and the
    /// last click winning: earlier tests are called off and their results dropped, the new config is
    /// checked and loaded, the core is confirmed to run it with its node lists and rule sets loaded
    /// (no fixed wait), the groups are read back, and only then are delays tested again. If any of
    /// that fails, the previous profile stays (or is loaded back) and the reason is shown; nothing
    /// falls back to DIRECT.
    func activate(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        if phase == .starting {
            profileAfterStartup = id
            return
        }
        profileAfterStartup = nil
        guard id != (switchingTo ?? activeProfileID) else { return }
        let previous = switchingTo == nil ? activeProfileID : committedProfileID
        if switchingTo == nil { committedProfileID = activeProfileID }
        activeProfileID = id
        effective = effectiveCache[id]
        ipRegions = [:]
        resetDelays()
        guard isRunning else {
            switchingTo = nil
            committedProfileID = nil
            groups = []
            if case .failed = phase { start() }
            return
        }
        switchingTo = id
        notice = nil
        let ticket = generation
        coreConfigWork.add { [weak self] in
            // A later click has taken over; it will do the work.
            guard let self, ticket == generation, activeProfileID == id else { return }
            await commitSwitch(to: id, from: previous, ticket: ticket)
        }
    }

    private func commitSwitch(to id: UUID, from previous: UUID?, ticket: Int) async {
        let timeline = ChangeTimeline(kind: "profileSwitch")
        defer { timeline.finish() }
        do {
            let text = try await startableText(of: id)
            timeline.mark("checked")
            guard ticket == generation else { return }
            guard try await reloadRunningCoreNow(profile: id) else { return }
            timeline.mark("loaded")
            guard ticket == generation else { return }
            try await confirmRunning(text, ticket: ticket)
            timeline.mark("ready")
            guard ticket == generation else { return }
            switchingTo = nil
            committedProfileID = nil
            let names = try? await controller?.proxyNames()
            guard ticket == generation else { return }
            if let names { await reconnect(after: .profile(policies: names)) }
            timeline.mark("reconnect")
            guard ticket == generation else { return }
            await refresh()
            guard ticket == generation else { return }
            locateServersByIP()
            // New nodes: measure them, and the exit may have moved.
            testEverythingOnce()
            checkExit()
        } catch {
            await restoreFailedSwitch(id, previous: previous, ticket: ticket, error: error)
        }
    }

    private func restoreFailedSwitch(_ id: UUID, previous: UUID?, ticket: Int, error: Error) async {
        guard ticket == generation else { return }
        let failed = profiles.first { $0.id == id }?.name ?? ""
        switchingTo = nil
        committedProfileID = nil
        guard let previous, let kept = profiles.first(where: { $0.id == previous }) else {
            notice = message(for: error)
            return
        }
        activeProfileID = previous
        effective = effectiveCache[previous]
        do {
            // The failed request may have touched the running config. Confirm the rollback did run.
            guard try await reloadRunningCoreNow(profile: previous) else { return }
            guard ticket == generation else { return }
            testEverythingOnce()
            notice = String(localized: "未能切换到“\(failed)”：\(message(for: error)) 仍在使用“\(kept.name)”。")
        } catch let rollbackError {
            guard ticket == generation else { return }
            notice = String(localized: "未能切换到“\(failed)”，也未能恢复上一个配置：\(message(for: rollbackError))")
        }
    }

    /// Waits until the core runs `text`'s groups and has loaded its node lists and rule sets,
    /// polling as the start-up check does; no fixed sleep.
    private func confirmRunning(_ text: String, ticket: Int) async throws {
        guard let controller else { throw EditorError(String(localized: "内核没有运行。")) }
        let expected = Set((try? ConfigDocument.parse(text))?.targets.filter { $0.kind == .group }.map(\.name) ?? [])
        let began = ContinuousClock.now
        while ContinuousClock.now - began < .seconds(15) {
            guard ticket == generation else { throw CancellationError() }
            let names = try await controller.proxyNames()
            let loaded = (try? await controller.providersLoaded()) ?? false
            if expected.isSubset(of: names), loaded { return }
            // A provider that failed never reports loaded; the groups being there is enough then.
            if expected.isSubset(of: names), ContinuousClock.now - began > .seconds(3) { return }
            try await Task.sleep(for: ReadinessPolling.interval(after: ContinuousClock.now - began))
        }
        throw EditorError(String(localized: "内核没有在 15 秒内载入新的配置。"))
    }

    func delete(_ id: UUID) {
        if id == activeProfileID {
            stop()
            activeProfileID = profiles.first { $0.id != id }?.id
        }
        let edits = routingStore.load(id).edits.map(\.id)
        profileStore.delete(id)
        routingStore.delete(id)
        effectiveStore.remove(id)
        forgetEffective(id)
        if activity?.profileID == id { dismissActivity() }
        profiles = profileStore.loadAll()
        editsRemoved?(edits)
        if profiles.isEmpty { onboarding = .addProfile }
    }

    func openImport(prefill: String = "") {
        importText = prefill
        importError = nil
        showingImport = true
    }

    /// A subscription link, or pasted config / share links. A link Veer already has updates that
    /// profile in place (same id, name, "my routing", app rules and conversations) instead of
    /// adding a copy; links are compared exactly, after trimming spaces only.
    func importFromText() {
        let input = importText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !importing else { return }
        importing = true
        importError = nil
        Task {
            defer { importing = false }
            do {
                if SubscriptionFetcher.looksLikeLink(input) {
                    let url = try SubscriptionFetcher.validate(input)
                    if let existing = existingProfile(for: url) {
                        showingImport = false
                        update(existing.id, reimport: true)
                        return
                    }
                    let key = url.absoluteString
                    // A second import of the same link while the first downloads: one profile.
                    guard importingLinks.insert(key).inserted else { return }
                    defer { importingLinks.remove(key) }
                    let response = try await fetchSubscription(url)
                    let result = try ConfigImporter.normalize(response.text)
                    // It may have been added another way while this one downloaded.
                    if let existing = existingProfile(for: url) {
                        showingImport = false
                        try await save(response, result, into: existing, reimport: true)
                        return
                    }
                    var profile = Profile(name: response.title ?? url.host() ?? String(localized: "订阅"), isSubscription: true,
                                          nodeCount: result.nodeCount, usage: response.usage)
                    profile.updateIntervalHours = response.updateIntervalHours
                    try profileStore.save(profile, text: result.text)
                    try profileStore.setSubscriptionURL(url, for: profile.id)
                    added(profile)
                } else {
                    let result = try ConfigImporter.normalize(input)
                    let profile = Profile(name: String(localized: "粘贴的配置"), isSubscription: false, nodeCount: result.nodeCount)
                    try profileStore.save(profile, text: result.text)
                    added(profile)
                }
                showingImport = false
            } catch {
                importError = message(for: error)
            }
        }
    }

    /// The subscription profile whose link is exactly `url`. Links stay in the secret store;
    /// this compares them on this Mac only, never logs or sends them.
    func existingProfile(for url: URL) -> Profile? {
        let link = url.absoluteString
        return profiles.first { $0.isSubscription && profileStore.subscriptionURL(of: $0.id)?.absoluteString == link }
    }

    /// Subscription profiles that share a link, oldest group first, each with more than one.
    func duplicateProfiles() -> [[Profile]] {
        var byLink: [String: [Profile]] = [:], order: [String] = []
        for profile in profiles where profile.isSubscription {
            guard let link = profileStore.subscriptionURL(of: profile.id)?.absoluteString else { continue }
            if byLink[link] == nil { order.append(link) }
            byLink[link, default: []].append(profile)
        }
        return order.compactMap { byLink[$0] }.filter { $0.count > 1 }
    }

    /// Which copy a merge keeps: the one in use, else the most recently updated; and which copies
    /// it can remove, being only those with nothing of the user's in their layer. A copy with its
    /// own routing changes or app rules is never removed by a merge.
    func mergePlan(_ copies: [Profile]) -> MergePlan? {
        guard copies.count > 1, let newest = copies.max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
        let keep = copies.first { $0.id == activeProfileID } ?? newest
        var remove: [Profile] = []
        var keptWithChanges: [Profile] = []
        for copy in copies where copy.id != keep.id {
            if routingStore.protectsFromMerge(copy.id) { keptWithChanges.append(copy) } else { remove.append(copy) }
        }
        return MergePlan(keep: keep, remove: remove, keptWithChanges: keptWithChanges)
    }

    /// Removes the copies `mergePlan` allows, after saving each one's files, so that the merge can be
    /// undone with `restore`. Conversations about a removed copy move to the kept one.
    func mergeDuplicates(_ confirmed: MergePlan) throws -> [RemovedProfile] {
        guard switchingTo == nil, phase != .starting,
              let copies = duplicateProfiles().first(where: { Set($0.map(\.id)) == confirmed.profileIDs }),
              let plan = mergePlan(copies), plan.keep.id == confirmed.keep.id, !plan.remove.isEmpty,
              Set(plan.remove.map(\.id)) == Set(confirmed.remove.map(\.id)),
              let link = profileStore.subscriptionURL(of: plan.keep.id) else {
            throw EditorError(String(localized: "配置已变化。请重新确认要合并的副本。"))
        }
        let removed = try plan.remove.map { RemovedProfile(profile: $0, text: try profileStore.text(of: $0.id), link: link) }
        try profileStore.remove(Set(removed.map(\.profile.id)))
        for item in removed {
            routingStore.delete(item.profile.id)
            effectiveStore.remove(item.profile.id)
            forgetEffective(item.profile.id)
        }
        profiles.removeAll { profile in removed.contains { $0.profile.id == profile.id } }
        profilesMerged?(Dictionary(uniqueKeysWithValues: removed.map { ($0.profile.id, plan.keep.id) }))
        return removed
    }

    /// Puts the copies a merge removed back, as they were. Conversations stay with the kept copy,
    /// which runs the same subscription.
    func restoreMergedCopies(_ copies: [RemovedProfile]) -> [RemovedProfile] {
        guard var current = try? profileStore.readIndex() else { return copies }
        var existing = Set(current.map(\.id))
        var remaining: [RemovedProfile] = []
        for item in copies {
            let id = item.profile.id
            guard !existing.contains(id) else { remaining.append(item); continue }
            do {
                try profileStore.setSubscriptionURL(item.link, for: id)
                try profileStore.save(item.profile, text: item.text)
                current.append(item.profile)
                existing.insert(id)
            } catch {
                profileStore.forgetSubscriptionURL(of: id)
                remaining.append(item)
            }
        }
        profiles = current
        return remaining
    }

    func importFile(_ url: URL) {
        importError = nil
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            let result = try ConfigImporter.normalize(text)
            let profile = Profile(name: url.deletingPathExtension().lastPathComponent, isSubscription: false, nodeCount: result.nodeCount)
            try profileStore.save(profile, text: result.text)
            added(profile)
            showingImport = false
        } catch {
            importError = message(for: error)
        }
    }

    func added(_ profile: Profile) {
        profiles = profileStore.loadAll()
        if activeProfileID == nil { activeProfileID = profile.id }
        if onboarding == .addProfile { onboarding = .routing }
    }

    /// Downloads a subscription again, one update per profile at a time. Every entry point (the
    /// profile menu, Manage Profiles, the Proxy menu, the Agent, a repeated import) reports through
    /// one `Activity`; an automatic update records a failure on the profile and stays quiet. The
    /// running core reloads only for the profile in use, and when it refuses the new content the
    /// last good content is put back.
    func update(_ id: UUID, automatic: Bool = false, reimport: Bool = false) {
        guard let url = profileStore.subscriptionURL(of: id), let profile = profiles.first(where: { $0.id == id }),
              !updatingProfiles.contains(id) else { return }
        updatingProfiles.insert(id)
        if !automatic {
            notice = nil
            showActivity(Activity(profileID: id, name: profile.name, kind: .updating))
        }
        Task {
            defer { updatingProfiles.remove(id) }
            do {
                let response = try await fetchSubscription(url)
                let result = try ConfigImporter.normalize(response.text)
                try await save(response, result, into: profile, reimport: reimport, quiet: automatic)
            } catch {
                guard var failed = profiles.first(where: { $0.id == id }) else { return }
                if automatic {
                    failed.updateError = message(for: error)
                    try? profileStore.saveInfo(failed)
                    profiles = profileStore.loadAll()
                } else {
                    showActivity(Activity(profileID: id, name: profile.name, kind: .failed(message(for: error))))
                }
            }
        }
    }

    /// Saves a downloaded subscription into an existing profile, keeping its id, name and layer.
    func save(_ response: SubscriptionResponse, _ result: ConfigImporter.Result, into original: Profile, reimport: Bool, quiet: Bool = false) async throws {
        let id = original.id
        while true {
            let committed = try await coreConfigWork.run { [self] in
                // A switch can be queued after the download but before this work runs. Check the
                // target that was already on disk first, then give the download its own reload.
                guard switchingTo != id else { return false }
                try await commitSubscription(response, result, profile: id, reimport: reimport, quiet: quiet)
                return true
            }
            if committed { return }
        }
    }

    private func commitSubscription(_ response: SubscriptionResponse, _ result: ConfigImporter.Result, profile id: UUID,
                                    reimport: Bool, quiet: Bool) async throws {
        // The download may have outlived a deletion or merge. Never recreate that profile.
        guard var profile = profiles.first(where: { $0.id == id }) else { return }
        let previousText = try? profileStore.text(of: id), previousInfo = profile
        profile.nodeCount = result.nodeCount
        profile.updatedAt = .now
        profile.usage = response.usage ?? profile.usage
        profile.updateIntervalHours = response.updateIntervalHours ?? profile.updateIntervalHours
        profile.updateError = nil
        try profileStore.save(profile, text: result.text)
        forgetEffective(id)
        profiles = profileStore.loadAll()
        let reloaded = try await reloadUpdatedProfile(previous: previousInfo, text: previousText)
        guard profiles.contains(where: { $0.id == id }) else { return }
        alertAboutUsage(of: profile)
        if !quiet || reimport {
            let kind: Activity.Kind = reimport ? .reimported(reloaded: reloaded) : .updated(reloaded: reloaded)
            showActivity(Activity(profileID: id, name: profile.name, kind: kind))
        }
    }

    private func reloadUpdatedProfile(previous: Profile, text: String?) async throws -> Bool {
        let id = previous.id
        guard id == activeProfileID, isRunning, switchingTo == nil else { return false }
        let ticket = generation
        do {
            guard try await reloadRunningCoreNow(profile: id) else { return false }
            let names = try? await controller?.proxyNames()
            guard ticket == generation else { return false }
            if let names { await reconnect(after: .profile(policies: names)) }
            guard ticket == generation else { return false }
            locateServersByIP()
            resetDelays()
            let refreshedTicket = generation
            await refresh()
            if refreshedTicket == generation { testEverythingOnce() }
            return refreshedTicket == generation
        } catch {
            try await restoreSubscription(previous, text: text, ticket: ticket)
            throw EditorError(String(localized: "内核没有接受新的内容，继续使用之前的配置：\(message(for: error))"))
        }
    }

    private func restoreSubscription(_ previous: Profile, text: String?, ticket: Int) async throws {
        let id = previous.id
        guard profiles.contains(where: { $0.id == id }) else { return }
        guard let text else { throw EditorError(String(localized: "无法恢复之前的配置。")) }
        try profileStore.save(previous, text: text)
        forgetEffective(id)
        profiles = profileStore.loadAll()
        if ticket == generation { _ = try await reloadRunningCoreNow(profile: id) }
    }

    /// Straight out first, so a broken node cannot stop an update; through the running core
    /// when that fails, for subscriptions blocked on the local network.
    func fetchSubscription(_ url: URL) async throws -> SubscriptionResponse {
        do {
            return try await SubscriptionFetcher(route: .direct).fetch(url)
        } catch {
            guard isRunning else { throw error }
            return try await SubscriptionFetcher(route: .proxy(port: proxyPort)).fetch(url)
        }
    }

    /// Every ten minutes, updates the subscriptions that are due. One that just failed waits
    /// an hour before the next try.
    func scheduleSubscriptionUpdates() {
        updateSchedule?.cancel()
        updateSchedule = Task {
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                updateDueSubscriptions()
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    func updateDueSubscriptions(now: Date = .now) {
        for profile in profiles where profile.isSubscription && profile.nextUpdate <= now {
            if let tried = lastAutomaticUpdate[profile.id], now.timeIntervalSince(tried) < 3600 { continue }
            lastAutomaticUpdate[profile.id] = now
            update(profile.id, automatic: true)
        }
    }
}
