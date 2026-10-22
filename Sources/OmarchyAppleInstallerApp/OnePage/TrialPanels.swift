import AppKit
import OmarchyInstallerUXCore
import SwiftUI

/// The trial's part of the page: the Try screen, then Omarchy's state while
/// it runs in its own window.
struct TrialStage: View {
  let trial: TrialSession

  var body: some View {
    switch trial.phase {
    case .hidden:
      EmptyView()

    case .ready(let space, let permissions):
      Panel {
        Text(PlainLanguage.trialHeadline).font(OmarchyTheme.heading)
        Text(PlainLanguage.trialSubheadline)
          .font(OmarchyTheme.body)
          .foregroundStyle(OmarchyTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
      Panel {
        PermissionRow(
          title: PlainLanguage.trialAccessibility, state: permissions.accessibility,
          action: { trial.requestAccessibility() })
        PermissionRow(
          title: PlainLanguage.trialMicrophone, state: permissions.microphone,
          action: { Task { await trial.requestMicrophone() } })
        PermissionRow(
          title: PlainLanguage.trialCamera, state: permissions.camera,
          action: { Task { await trial.requestCamera() } })
        Text(PlainLanguage.trialPermissionsNote)
          .font(OmarchyTheme.detail)
          .foregroundStyle(OmarchyTheme.secondaryText)
      }
      Text(PlainLanguage.trialSpace(space))
        .font(OmarchyTheme.body)
        .foregroundStyle(OmarchyTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
      if !space.isEnough {
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

    case .running:
      Panel {
        Text(PlainLanguage.trialRunningHeadline).font(OmarchyTheme.heading)
        Text(PlainLanguage.trialRunningDetail)
          .font(OmarchyTheme.body)
          .foregroundStyle(OmarchyTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
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

/// The trial's buttons. `canInstall` is whether this Mac can continue into
/// the native install.
struct TrialActions: View {
  let trial: TrialSession
  let canInstall: Bool
  let onInstall: () -> Void

  var body: some View {
    switch trial.phase {
    case .hidden, .starting:
      EmptyView()

    case .ready:
      Button(PlainLanguage.trialBack) { trial.dismiss() }
        .omarchySecondaryButton()
      Button(trial.startTitle) { trial.start() }
        .omarchyPrimaryButton()
        .disabled(!trial.canStart)
        .keyboardShortcut(.defaultAction)

    case .running:
      Button(PlainLanguage.trialShutDown) { trial.shutDown() }
        .omarchySecondaryButton()
      if canInstall {
        Button(PlainLanguage.trialInstall) { trial.shutDown(then: onInstall) }
          .omarchyPrimaryButton()
      }

    case .stopping:
      EmptyView()

    case .failed:
      Button(PlainLanguage.trialBack) { trial.dismiss() }
        .omarchySecondaryButton()
        .keyboardShortcut(.defaultAction)
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
