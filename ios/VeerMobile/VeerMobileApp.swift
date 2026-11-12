import ObjectiveC
import os
import SwiftUI

@main
struct VeerMobile: App {
    init() {
        #if DEBUG
        CrashTrace.install()
        // Process-local localization override for the Simulator acceptance matrix. The argument
        // domain is volatile: this never changes the person's saved app/system language.
        if let language = ProcessInfo.processInfo.environment["VEER_UI_LANGUAGE"],
           ["zh-Hans", "en"].contains(language) {
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments["AppleLanguages"] = [language]
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            // UIKit resolves Bundle.main's localization before App.init runs, so the defaults
            // override alone only changes formatters. Route string lookups to the chosen .lproj.
            LanguageOverrideBundle.install(language)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                #if DEBUG
                .environment(\.locale, LanguageOverrideBundle.locale ?? .current)
                #endif
        }
    }
}

#if DEBUG
/// Debug-only, process-local: answers Bundle.main string lookups from one .lproj so the
/// Simulator matrix can show either language without touching the device language.
nonisolated private final class LanguageOverrideBundle: Bundle, @unchecked Sendable {
    nonisolated(unsafe) private static var target: Bundle?
    nonisolated(unsafe) static var locale: Locale?

    static func install(_ language: String) {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return }
        target = bundle
        locale = Locale(identifier: language)
        object_setClass(Bundle.main, LanguageOverrideBundle.self)
    }

    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let target = Self.target {
            return target.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }

    override var preferredLocalizations: [String] {
        if let locale = Self.locale { return [locale.identifier] }
        return super.preferredLocalizations
    }
}
#endif

#if DEBUG
/// Debug-only diagnosis aid for the Simulator, where crash reports are not reachable: logs the
/// trapping thread's stack to the unified log, then lets the default action end the process.
/// Only SIGTRAP and SIGABRT: Go's runtime relies on its own SIGSEGV/SIGBUS handlers.
nonisolated enum CrashTrace {
    static func install() {
        for sig in [SIGTRAP, SIGABRT] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { sig in
                let log = OSLog(subsystem: "com.yamax.veer.ios-prototype", category: "crash")
                os_log(.fault, log: log, "VEER-CRASH signal %d on %{public}@", sig, Thread.isMainThread ? "main" : "background")
                for line in Thread.callStackSymbols { os_log(.fault, log: log, "VEER-CRASH %{public}@", line) }
                signal(sig, SIG_DFL)
                raise(sig)
            }
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            sigaction(sig, &action, nil)
        }
    }
}
#endif
