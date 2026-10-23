import AppKit
import OmarchyInstallerUXCore
import SwiftUI

/// Try's part of the page: the Try page, then Omarchy's state while it runs
/// in its own window.
struct TrialStage: View {
  let trial: TrialSession

  var body: some View {
    switch trial.phase {
    case .hidden:
      EmptyView()

    case .ready(let space, let permissions):
      Panel {
        Text(PlainLanguage.trialHeadline).font(OmarchyTheme.heading)
        Text(trial.subheadline)
          .font(OmarchyTheme.body)
          .foregroundStyle(OmarchyTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
      Panel {
        PermissionRows(trial: trial, permissions: permissions, onlyMissing: false)
        Text(PlainLanguage.trialPermissionsNote)
          .font(OmarchyTheme.detail)
          .foregroundStyle(OmarchyTheme.secondaryText)
      }
      Text(PlainLanguage.trialSpace(space))
        .font(OmarchyTheme.body)
        .foregroundStyle(OmarchyTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
      if space.isShort {
        Text(PlainLanguage.trialSpaceShortfall(space))
          .font(OmarchyTheme.body)
          .foregroundStyle(OmarchyTheme.caution)
      }

    case .starting(let progress):
      Panel {
        HStack(alignment: .firstTextBaseline) {
          Text(progress.title).font(OmarchyTheme.heading)
          Spacer(minLength: 8)
          if let percent = progress.percent {
            Text("\(percent)%").font(OmarchyTheme.detail).foregroundStyle(
              OmarchyTheme.secondaryText)
          }
        }
        ProgressTrack(fraction: progress.fraction, height: 14)
      }

    case .running(let permissions):
      Panel {
        Text(PlainLanguage.trialRunningHeadline).font(OmarchyTheme.heading)
        Text(PlainLanguage.trialRunningDetail)
          .font(OmarchyTheme.body)
          .foregroundStyle(OmarchyTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        if trial.finishInstallAfterShutDown {
          Text(PlainLanguage.trialFinishInstall)
            .font(OmarchyTheme.body)
            .foregroundStyle(OmarchyTheme.caution)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if let line = trial.bridgedNetworkLine {
        Panel {
          HStack {
            Text(line)
              .font(OmarchyTheme.body)
              .foregroundStyle(OmarchyTheme.secondaryText)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action = trial.bridgedNetworkActionTitle {
              Button(action) {
                Task { await trial.setUpBridgedNetwork() }
              }
              .omarchySecondaryButton()
            }
          }
        }
      }
      if !permissions.allAllowed {
        Panel {
          PermissionRows(trial: trial, permissions: permissions, onlyMissing: true)
          Text(PlainLanguage.trialPermissionsNextStart)
            .font(OmarchyTheme.detail)
            .foregroundStyle(OmarchyTheme.secondaryText)
        }
      }

    case .stopping:
      Panel {
        Text(PlainLanguage.trialStoppingHeadline).font(OmarchyTheme.heading)
        Text(PlainLanguage.trialStoppingDetail)
          .font(OmarchyTheme.body)
          .foregroundStyle(OmarchyTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        ProgressTrack(fraction: nil, height: 14)
      }

    case .failed(let failure):
      Panel {
        Text(failure.headline)
          .font(OmarchyTheme.heading)
          .foregroundStyle(OmarchyTheme.danger)
        Text(failure.detail)
          .font(OmarchyTheme.body)
          .foregroundStyle(OmarchyTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        if let technical = failure.technicalDetail {
          DisclosureGroup("Technical details") {
            TechnicalDetailText(text: technical)
            Button("Copy error details") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(technical, forType: .string)
            }
          }
        }
      }
    }
  }
}

/// Try's buttons. Install on this Mac shuts Omarchy down, then continues
/// into the installer's plan.
struct TrialActions: View {
  let trial: TrialSession
  let onInstall: () -> Void

  var body: some View {
    switch trial.phase {
    case .hidden, .starting:
      EmptyView()

    case .ready:
      if trial.canGoBack {
        Button(PlainLanguage.trialBack) { trial.dismiss() }
          .omarchySecondaryButton()
      }
      Button(trial.startTitle) { trial.start() }
        .omarchyPrimaryButton()
        .disabled(!trial.canStart)
        .keyboardShortcut(.defaultAction)

    case .running:
      Button(PlainLanguage.trialShutDown) { trial.shutDown() }
        .omarchySecondaryButton()
      if trial.canInstall {
        Button(PlainLanguage.trialInstall) { trial.leaveForInstall(then: onInstall) }
          .omarchyPrimaryButton()
      }

    case .stopping:
      EmptyView()

    case .failed:
      if trial.canTryAgain {
        Button(PlainLanguage.trialBack) { trial.dismiss() }
          .omarchySecondaryButton()
        Button(PlainLanguage.trialTryAgain) { trial.tryAgain() }
          .omarchyPrimaryButton()
          .keyboardShortcut(.defaultAction)
      } else {
        Button(PlainLanguage.trialBack) { trial.dismiss() }
          .omarchySecondaryButton()
          .keyboardShortcut(.defaultAction)
      }
    }
  }
}

private struct PermissionRows: View {
  let trial: TrialSession
  let permissions: TrialPermissions
  /// The running page lists only what is still not granted.
  let onlyMissing: Bool

  var body: some View {
    if !onlyMissing || permissions.accessibility != .allowed {
      PermissionRow(
        title: PlainLanguage.trialAccessibility, state: permissions.accessibility,
        action: { trial.requestAccessibility() })
    }
    if !onlyMissing || permissions.microphone != .allowed {
      PermissionRow(
        title: PlainLanguage.trialMicrophone, state: permissions.microphone,
        action: { Task { await trial.requestMicrophone() } })
    }
    if !onlyMissing || permissions.camera != .allowed {
      PermissionRow(
        title: PlainLanguage.trialCamera, state: permissions.camera,
        action: { Task { await trial.requestCamera() } })
    }
  }
}

private struct PermissionRow: View {
  let title: String
  let state: TrialPermissionState
  let action: () -> Void

  var body: some View {
    HStack {
      Text(title).font(OmarchyTheme.body)
      Spacer(minLength: 8)
      if state == .allowed {
        StatusBadge(text: PlainLanguage.trialAllowed, kind: .ok)
      } else {
        Button(
          state == .refused ? PlainLanguage.trialOpenSettings : PlainLanguage.trialAllow,
          action: action
        )
        .omarchySecondaryButton()
      }
    }
  }
}
