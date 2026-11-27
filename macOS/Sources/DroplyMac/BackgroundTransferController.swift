import AppKit
import Foundation
import DroplyCore

/// Prevents macOS App Nap and system idle sleep while Droply is paired or transferring files,
/// and surfaces live background transfer status in the Dock icon badge.
@MainActor
final class BackgroundTransferController {
    private enum ActivityLevel: Equatable {
        case none
        case connected
        case transferring
    }

    private var activityToken: NSObjectProtocol?
    private var currentLevel: ActivityLevel = .none
    private var lastBadgePercent: Int?

    func update(
        isTransferring: Bool,
        isConnected: Bool,
        progress: TransferProgressSnapshot?
    ) {
        let targetLevel: ActivityLevel
        if isTransferring {
            targetLevel = .transferring
        } else if isConnected {
            targetLevel = .connected
        } else {
            targetLevel = .none
        }

        if targetLevel != currentLevel {
            if let existing = activityToken {
                ProcessInfo.processInfo.endActivity(existing)
                activityToken = nil
            }
            currentLevel = targetLevel

            switch targetLevel {
            case .none:
                break
            case .connected:
                activityToken = ProcessInfo.processInfo.beginActivity(
                    options: [
                        .userInitiatedAllowingIdleSystemSleep,
                        .suddenTerminationDisabled,
                        .automaticTerminationDisabled
                    ],
                    reason: "Droply maintains active Wi-Fi connection in background"
                )
            case .transferring:
                activityToken = ProcessInfo.processInfo.beginActivity(
                    options: [
                        .userInitiated,
                        .idleSystemSleepDisabled,
                        .suddenTerminationDisabled,
                        .automaticTerminationDisabled,
                        .latencyCritical
                    ],
                    reason: "Droply transfers files over Wi-Fi without interruption"
                )
            }
        }

        updateDockBadge(isTransferring: isTransferring, progress: progress)
    }

    private func updateDockBadge(isTransferring: Bool, progress: TransferProgressSnapshot?) {
        guard isTransferring, let progress else {
            if lastBadgePercent != nil {
                lastBadgePercent = nil
                NSApp.dockTile.badgeLabel = nil
            }
            return
        }

        let pct = max(0, min(100, Int(progress.percent.rounded(.down))))
        if lastBadgePercent != pct {
            lastBadgePercent = pct
            NSApp.dockTile.badgeLabel = "\(pct)%"
        }
    }

    func shutdown() {
        if let existing = activityToken {
            ProcessInfo.processInfo.endActivity(existing)
            activityToken = nil
        }
        currentLevel = .none
        if lastBadgePercent != nil {
            lastBadgePercent = nil
            NSApp.dockTile.badgeLabel = nil
        }
    }
}
