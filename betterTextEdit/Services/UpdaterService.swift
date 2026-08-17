import Combine
import Sparkle
import SwiftUI

// Keeping the app up to date.
//
// Sparkle does the actual work — checking the feed, downloading, verifying the
// signature, swapping the bundle, relaunching. This is the thin layer between
// it and SwiftUI: Sparkle's controller is an `NSObject` with KVO-observable
// properties, and SwiftUI wants `@Published`, so the two are bridged here once
// rather than in every view that wants to show a "Check for Updates" item.
//
// The feed URL and the public key that validates it live in Info.plist
// (`SUFeedURL`, `SUPublicEDKey`). Sparkle reads them itself; nothing below
// needs to know where updates come from.

@MainActor
final class UpdaterService: ObservableObject {
    static let shared = UpdaterService()

    /// Whether a check is possible right now — false while one is already in
    /// flight, and false again if the updater failed to start at all. The menu
    /// item and the button in Settings both dim on it, so neither offers an
    /// action that would do nothing.
    @Published private(set) var canCheckForUpdates = false

    /// Whether Sparkle looks for updates on its own, once a day.
    ///
    /// Not `@AppStorage`: Sparkle owns this setting and writes it to its own
    /// defaults key. Reading and writing it through Sparkle keeps one answer
    /// rather than two that can disagree.
    var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// The version the user is running, as shown in Settings — "1.0.0 (12)".
    /// The short string is what a person calls the release; the build number
    /// after it is what distinguishes two builds of the same release, which is
    /// the thing worth knowing when a bug report comes in.
    let versionDescription: String

    private let controller: SPUStandardUpdaterController
    private var observation: AnyCancellable?

    private init() {
        // `startingUpdater: false` matters more than it looks.
        //
        // This object is a `static let`, so it's built inside a `dispatch_once`
        // the first time anything asks for `.shared` — and the first thing to
        // ask is the menu bar, while SwiftUI is evaluating `Scene.commands`.
        // Starting the updater here sets `canCheckForUpdates`, which fires KVO,
        // which publishes `objectWillChange`, which sends SwiftUI back around to
        // re-read the commands — and back into a `.shared` whose `dispatch_once`
        // hasn't finished. That deadlocks the main thread on launch.
        //
        // So construction stays inert, and `start()` below does the waking up,
        // once the app is running and there's no half-built singleton to fall
        // back into.
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        versionDescription = "\(short) (\(build))"
    }

    /// Begin checking. Called once, from `applicationDidFinishLaunching`.
    ///
    /// Sparkle only reaches the network when a scheduled check is actually due,
    /// so this costs nothing at launch beyond starting a timer.
    func start() {
        guard observation == nil else { return }

        controller.startUpdater()

        // Read the first value across directly rather than letting the
        // publisher deliver it, and drop the one it would have sent. Combine
        // publishes the current value the instant you subscribe; taking it
        // through `@Published` instead would announce a change to SwiftUI from
        // inside this call, which is the re-entrancy the initialiser above
        // goes out of its way to avoid.
        canCheckForUpdates = controller.updater.canCheckForUpdates

        observation = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .dropFirst()
            // Later changes land on the next turn of the run loop, so a check
            // starting or finishing can never redraw a view mid-update.
            .receive(on: RunLoop.main)
            .assign(to: \.canCheckForUpdates, on: self)
    }

    /// Check now, and show the result either way — including "you're up to
    /// date", which a scheduled check stays quiet about but someone who just
    /// asked deserves to see.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
