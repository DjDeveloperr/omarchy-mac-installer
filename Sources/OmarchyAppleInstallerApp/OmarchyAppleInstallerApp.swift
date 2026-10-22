import AppKit
import OmarchyAppleInstallerTrustCore
import OmarchyInstallerUXCore
import SwiftUI

@MainActor
private final class InstallerApplicationDelegate: NSObject, NSApplicationDelegate {
  static var removalInProgress = false
  static weak var session: InstallerSession?
  static weak var trial: TrialSession?

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if Self.removalInProgress || Self.session?.isExecutionInProgress == true {
      NSSound.beep()
      return .terminateCancel
    }
    // Quitting shuts Omarchy down first; the page shows it until it has.
    if let trial = Self.trial, trial.isActive {
      trial.shutDown { NSApp.reply(toApplicationShouldTerminate: true) }
      return .terminateLater
    }
    return .terminateNow
  }

  private var instanceLease: InstallerAppInstanceLease?

  func applicationWillFinishLaunching(_ notification: Notification) {
    #if !DEBUG
      if ProcessInfo.processInfo.arguments.contains("--simulate") {
        fputs("Simulation requires a debug build. Refusing to launch the live installer.\n", stderr)
        NSApplication.shared.terminate(nil)
        return
      }
    #endif
    do {
      let lockFile = try InstallerAppInstanceLease.defaultLockFileURL()
      instanceLease = try InstallerAppInstanceLease.acquire(at: lockFile)
    } catch {
      fputs(
        "\(InstallerProductIdentity.appName) refused a duplicate or unsafe launch: \(error)\n",
        stderr)
      NSApplication.shared.terminate(nil)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // The install ends with a shutdown the app itself requests. macOS would
    // otherwise treat it as an app open at shutdown and bring it back at the
    // next login, so someone rebooting from Omarchy into macOS met the
    // installer again. Opt out for good.
    NSApp.disableRelaunchOnLogin()

    #if DEBUG
      // A bare SwiftPM executable has no Info.plist, so Launch Services
      // registers it background-only and the window never appears. Promote
      // unbundled debug runs to a regular, frontmost app; the packaged app
      // is already regular and never enters this branch.
      if Bundle.main.bundleURL.pathExtension != "app" {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
      }
    #endif
  }
}

@main
struct OmarchyAppleInstallerApp: App {
  @NSApplicationDelegateAdaptor(InstallerApplicationDelegate.self)
  private var applicationDelegate

  /// Testers switch to a pre-release channel here. The choice only picks among
  /// the URLs already signed into this build; changing it restarts the check so
  /// nothing planned against one channel is installed from the other.
  @State private var liveSession: InstallerSession?
  @State private var showsRemoval = false
  @State private var removalInProgress = false
  @State private var removalNeedsReview = false
  #if DEBUG
    @State private var simulation = SimulationControls()
  #endif
  @State private var generation = UUID()
  @State private var trial = TrialSession(environment: LiveTrialEnvironment())
  @State private var installReason: TrialInstallReason?
  @State private var deletionMessage: String?
  @State private var deletionFailure: String?

  private var isSimulation: Bool {
    #if DEBUG
      return ProcessInfo.processInfo.arguments.contains("--simulate")
    #else
      return false
    #endif
  }

  @ViewBuilder
  private var installerContent: some View {
    #if DEBUG
      if isSimulation {
        SimulationDashboard(controls: simulation, onSessionAvailable: rememberSession)
      } else {
        liveContent
      }
    #else
      if ProcessInfo.processInfo.arguments.contains("--simulate") {
        ContentUnavailableView(
          "Simulation is available in debug builds only.", systemImage: "lock.shield")
      } else {
        liveContent
      }
    #endif
  }

  private var liveContent: some View {
    OnePageInstallerView(
      environment: InstallerEnvironmentFactory.make(), channel: channel, trial: trial,
      onSessionAvailable: rememberSession)
  }

  private func rememberSession(_ session: InstallerSession) {
    liveSession = session
    InstallerApplicationDelegate.session = session
    InstallerApplicationDelegate.trial = trial
  }

  @State private var channel = ReleaseChannelPreference().resolveFromMainBundle()

  var body: some Scene {
    Window(PlainLanguage.windowTitle, id: "installer") {
      Group {
        if removalNeedsReview {
          VStack {
            ContentUnavailableView(
              "Removal needs review", systemImage: "externaldrive.badge.exclamationmark",
              description: Text(
                "Check the removal record and disk layout before changing any disks."))

          }
        } else {
          installerContent
        }
      }
      .id(generation)
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
      ) { _ in
        liveSession?.cancelPrefetchOnQuit()
      }
      .disabled(showsRemoval)
      .windowDismissBehavior(
        removalInProgress || liveSession?.isExecutionInProgress == true || trial.isActive
          ? .disabled : .enabled
      )
      .sheet(isPresented: $showsRemoval, onDismiss: { generation = UUID() }) {
        OmarchyRemovalSheet(
          isSimulation: isSimulation,
          onBusyChanged: { busy in
            removalInProgress = busy
            InstallerApplicationDelegate.removalInProgress = busy
            for window in NSApp.windows where window.sheetParent == nil {
              window.standardWindowButton(.closeButton)?.isEnabled = !busy
            }
          }, onClose: { showsRemoval = false }, onRequiresReview: { removalNeedsReview = true },
          simulationScenario: previewRemovalScenario)
      }
      .alert(
        installReason?.headline ?? "", isPresented: presented($installReason),
        presenting: installReason
      ) { reason in
        if reason.canCheckAgain {
          Button(PlainLanguage.checkAgain) { checkAgain() }
        }
        Button("OK", role: .cancel) {}
      } message: { reason in
        Text(reason.detail)
      }
      .alert(
        PlainLanguage.trialDeleteTitle, isPresented: presented($deletionMessage),
        presenting: deletionMessage
      ) { _ in
        Button(PlainLanguage.trialDeleteAction, role: .destructive) { deleteVM() }
        Button("Cancel", role: .cancel) {}
      } message: { message in
        Text(message)
      }
      .alert(
        PlainLanguage.trialDeleteFailed, isPresented: presented($deletionFailure),
        presenting: deletionFailure
      ) { _ in
        Button("OK", role: .cancel) {}
      } message: { failure in
        Text(failure)
      }
      .preferredColorScheme(previewColorScheme)
      .frame(minWidth: 640)
      .omarchyTypography()
      .tint(OmarchyTheme.accent)
      // The window itself takes the theme colour, title bar included, so the
      // translucent system title bar never tints from the wallpaper behind.
      .containerBackground(OmarchyTheme.window, for: .window)
    }
    .defaultSize(width: 780, height: 600)
    .windowResizability(.contentSize)
    .windowStyle(.hiddenTitleBar)
    .commands {
      #if DEBUG
        if isSimulation {
          CommandMenu("Simulation") {
            Picker("Scenario", selection: $simulation.scenario) {
              ForEach(InstallerSimulationScenario.allCases) { item in
                Text(item.title).tag(item)
              }
            }
            Picker("Test Channel", selection: $simulation.channel) {
              ForEach(ReleaseChannel.allCases, id: \.self) { item in
                Text(PlainLanguage.badge(for: item)).tag(item)
              }
            }.disabled(!simulation.canChangeChannel)
            Toggle("Slow Playback", isOn: $simulation.slow)
            Toggle("Dark Appearance", isOn: $simulation.dark)
            Divider()
            Picker("Removal Scenario", selection: $simulation.removalScenario) {
              ForEach(RemovalPreviewScenario.allCases, id: \.self) { item in
                Text(item.rawValue).tag(item)
              }
            }.disabled(removalInProgress)
            Divider()
            Button("Reset Simulation") {
              guard !removalInProgress else { return }
              showsRemoval = false
              removalNeedsReview = false
              simulation.reset()
              generation = UUID()
            }.disabled(removalInProgress)
            Button("Scenario Guidance…") { simulation.showGuidance() }
          }
        }
      #endif
      CommandMenu("Installation") {
        Button(PlainLanguage.trialInstallMenuItem) { installFromMenu() }
          .disabled(
            isSimulation || removalNeedsReview || showsRemoval
              || trial.installMenuAction == .unavailable)
        Button(PlainLanguage.trialCheckAgainMenuItem) { checkAgain() }
          .disabled(
            isSimulation || removalNeedsReview || showsRemoval || !installStatusIsUnsupported
              || liveSession?.canInspect != true)
        Divider()
        Button("Remove Omarchy…") { showsRemoval = true }
          .disabled(removalNeedsReview || showsRemoval || liveSession?.canOpenRemoval != true)
        if trial.isAvailable {
          Divider()
          Button(PlainLanguage.trialDeleteMenuItem) {
            Task { deletionMessage = await trial.deletionMessage() }
          }
          .disabled(isSimulation || removalNeedsReview || showsRemoval || !trial.canDeleteVM)
        }
      }
      if InstallerBuildProfile.current.showsReleaseChannels {
        CommandMenu(PlainLanguage.channelMenuTitle) {
          // One toggle per channel rather than an inline picker, so a channel
          // with nothing for this Mac can be shown but not chosen.
          ForEach(ReleaseChannel.allCases, id: \.self) { option in
            let availability = liveSession?.channelAvailability[option]
            Toggle(
              PlainLanguage.channelMenuItem(option, availability: availability),
              isOn: channelBinding(option)
            )
            .disabled(
              !PlainLanguage.channelMenuItemEnabled(
                option, selected: channel, availability: availability))
          }
          .disabled(
            removalNeedsReview || showsRemoval || liveSession?.canChangeChannel != true
              || isSimulation || channel == nil)
          Divider()
          Button(PlainLanguage.channelMenuCheckAgain) {
            Task { await liveSession?.refreshChannelAvailability() }
          }
          .disabled(
            removalNeedsReview || showsRemoval || liveSession?.canChangeChannel != true
              || isSimulation || channel == nil)
        }
      }
    }
  }

  private var installStatusIsUnsupported: Bool {
    if case .unsupported = trial.installStatus { return true }
    return false
  }

  /// Install on this Mac from the menu: shuts Omarchy down and continues into
  /// the plan, or says why this Mac can't install.
  private func installFromMenu() {
    switch trial.installMenuAction {
    case .unavailable:
      break
    case .install:
      trial.leaveForInstall { Task { await liveSession?.continueToPlan() } }
    case .explain(let reason):
      installReason = reason
    }
  }

  private func checkAgain() {
    guard let session = liveSession, session.canInspect else { return }
    Task {
      await session.inspect()
      await session.refreshChannelAvailability()
    }
  }

  private func deleteVM() {
    do {
      try trial.deleteVM()
    } catch {
      deletionFailure = error.localizedDescription
    }
  }

  private func presented<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
    Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
  }

  private var previewColorScheme: ColorScheme? {
    #if DEBUG
      if isSimulation { return simulation.dark ? .dark : .light }
    #endif
    return nil
  }

  private var previewRemovalScenario: String? {
    #if DEBUG
      if isSimulation { return simulation.removalScenario.rawValue }
    #endif
    return nil
  }

  private func channelBinding(_ option: ReleaseChannel) -> Binding<Bool> {
    Binding(
      get: { channel == option },
      set: { isOn in
        guard isOn, option != channel,
          liveSession?.canChangeChannel == true && !isSimulation,
          PlainLanguage.channelMenuItemEnabled(
            option, selected: channel,
            availability: liveSession?.channelAvailability[option])
        else {
          return
        }
        ReleaseChannelPreference().select(option)
        channel = option
      }
    )
  }
}
