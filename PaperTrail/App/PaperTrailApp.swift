import PaperTrailKit
import SwiftData
import SwiftUI
#if os(iOS)
import BackgroundTasks
#endif

@main
struct PaperTrailApp: App {
    @State private var settingsStore = SettingsStore()
    private let modelContainer = AppServices.modelContainer
    private let filingService: FilingService
    @State private var model: AppModel
    @State private var appLock = AppLock()
    @State private var mailIntake: MailIntakeService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        TemporaryFiles.cleanUp()
        let filingService = FilingService(location: ICloudArchiveLocation(), store: CoordinatedFileStore())
        self.filingService = filingService
        let model = AppModel(
            filingService: filingService,
            billService: BillService(reminders: EventKitBillReminders()),
            expenseService: ExpenseService(location: ICloudArchiveLocation())
        )
        _model = State(initialValue: model)
        // Shortcuts actions that open the app use the same model.
        AppServices.model = model
        let mail = MailIntakeService(filingService: filingService)
        _mailIntake = State(initialValue: mail)
        #if os(macOS)
        // The Mac checks the mailbox every few minutes, independent of any open window.
        mail.start()
        #endif
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(settingsStore)
                .environment(model)
                .environment(appLock)
                .environment(mailIntake)
                #if os(macOS)
                .frame(minWidth: 820, minHeight: 560)
                #endif
        }
        .modelContainer(modelContainer)
        #if os(iOS)
        // iOS gives no regular background time: check on coming to the front, and ask for an
        // occasional background refresh (iOS decides when, if at all).
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await mailIntake.checkIfDue() }
            case .background: Self.scheduleMailCheck(enabled: mailIntake.account.isEnabled)
            default: break
            }
        }
        .backgroundTask(.appRefresh(MailIntakeService.backgroundTaskID)) {
            await Self.scheduleMailCheck(enabled: true)
            await mailIntake.checkNow(timeLimit: 25)
        }
        #endif
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        #endif
        .commands {
            // View → Show/Hide Sidebar (⌃⌘S).
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("Add Document…") { model.showingImporter = true }
                    .keyboardShortcut("n")
                    .disabled(appLock.isLocked)
            }
            CommandGroup(after: .textEditing) {
                Button("Find Documents") { model.wantsSearchFocus = true }
                    .keyboardShortcut("f")
                    .disabled(appLock.isLocked)
            }
        }

        #if os(macOS)
        // Paper Trail → Settings… (⌘,), the standard place on the Mac.
        Settings {
            NavigationStack { SettingsView() }
                .environment(settingsStore)
                .environment(model)
                .environment(appLock)
                .environment(mailIntake)
                .modelContainer(modelContainer)
                .frame(minWidth: 520, minHeight: 600)
        }
        #endif

        #if os(macOS)
        MenuBarExtra("Paper Trail", systemImage: "tray.and.arrow.down") {
            MailMenu(mail: mailIntake)
        }
        #endif
    }

}

#if os(iOS)
extension PaperTrailApp {
    /// Asks iOS for a background refresh in about 15 minutes, to check the mailbox.
    static func scheduleMailCheck(enabled: Bool) {
        guard enabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: MailIntakeService.backgroundTaskID)
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif

/// What the app and its Shortcuts actions share: one data store, and the app's model.
enum AppServices {
    /// One container per process: the app and App Intents must not open the store twice.
    static let modelContainer = makeModelContainer()
    static var model: AppModel?

    /// Uses CloudKit sync when the app has the CloudKit entitlement, and a local store otherwise.
    /// The index can always be rebuilt from the files, so falling back to local is safe.
    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema(PaperTrailSchema.models)
        do {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .automatic))
        } catch {
            do {
                return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .none))
            } catch {
                fatalError("Could not open the document index: \(error.localizedDescription)")
            }
        }
    }
}
