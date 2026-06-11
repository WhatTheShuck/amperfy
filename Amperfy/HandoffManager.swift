//
//  HandoffManager.swift
//  Amperfy
//
//  Created by Amperfy Contributors on 11.06.26.
//  Copyright (c) 2026 Maximilian Bauer. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import AmperfyKit
import Foundation
import OSLog
import UIKit

// MARK: - HandoffManager

/// Advertises the current playback state via Handoff and continues
/// playback that was handed off from another device.
@MainActor
class HandoffManager: NSObject {
  /// limits how often the activity payload is refreshed while playing
  private static let elapsedTimeRepublishThresholdInSec = 5.0

  private let player: PlayerFacade
  private let library: LibraryStorage
  private let eventLogger: EventLogger
  private let log = OSLog(subsystem: "Amperfy", category: "HandoffManager")

  private var activity: NSUserActivity?
  private var lastPublishedElapsedTime = 0.0
  private var isStarted = false

  init(player: PlayerFacade, library: LibraryStorage, eventLogger: EventLogger) {
    self.player = player
    self.library = library
    self.eventLogger = eventLogger
    super.init()
  }

  func start() {
    guard !isStarted else { return }
    isStarted = true
    player.addNotifier(notifier: self)
    publishCurrentState()
  }

  // MARK: Publishing

  private func publishCurrentState() {
    guard let currentItem = player.currentlyPlaying,
          let state = HandoffPlaybackState.capture(from: player) else {
      invalidateActivity()
      return
    }
    let activity = activity ?? createActivity()
    activity.title = currentItem.displayString
    activity.userInfo = state.userInfoRepresentation
    activity.needsSave = true
    lastPublishedElapsedTime = state.elapsedTime
  }

  private func createActivity() -> NSUserActivity {
    let activity = NSUserActivity(activityType: HandoffPlaybackState.activityType)
    activity.isEligibleForHandoff = true
    activity.isEligibleForSearch = false
    activity.isEligibleForPrediction = false
    activity.delegate = self
    self.activity = activity
    activity.becomeCurrent()
    return activity
  }

  private func invalidateActivity() {
    activity?.invalidate()
    activity = nil
    lastPublishedElapsedTime = 0.0
  }

  // MARK: Receiving

  @discardableResult
  func handle(_ userActivity: NSUserActivity) -> Bool {
    guard userActivity.activityType == HandoffPlaybackState.activityType else { return false }
    guard let userInfo = userActivity.userInfo,
          let state = HandoffPlaybackState(userInfo: userInfo) else {
      os_log("Handoff activity has an invalid payload", log: log, type: .error)
      return false
    }
    guard let resolved = state.resolve(using: library) else {
      eventLogger.info(
        topic: "Handoff",
        message: "Playback could not be continued on this device. The handed-off items are not available in the local library."
      )
      return false
    }
    os_log(
      "Continue handoff playback: %d queue items, mode %s",
      log: log,
      type: .info,
      resolved.contextItems.count,
      resolved.playerMode.description
    )
    player.restoreHandoffPlayback(resolved)
    return true
  }
}

// MARK: MusicPlayable

extension HandoffManager: MusicPlayable {
  func didStartPlayingFromBeginning() {}
  func didStartPlaying() { publishCurrentState() }
  func didPause() { publishCurrentState() }
  func didStopPlaying() { invalidateActivity() }

  func didElapsedTimeChange() {
    guard activity != nil else { return }
    guard abs(player.elapsedTime - lastPublishedElapsedTime) >=
      Self.elapsedTimeRepublishThresholdInSec else { return }
    publishCurrentState()
  }

  func didPlaylistChange() { publishCurrentState() }
  func didArtworkChange() {}
  func didShuffleChange() { publishCurrentState() }
  func didRepeatChange() { publishCurrentState() }
  func didPlaybackRateChange() {}
}

// MARK: NSUserActivityDelegate

extension HandoffManager: NSUserActivityDelegate {
  nonisolated func userActivityWasContinued(_ userActivity: NSUserActivity) {
    // playback has moved over to another device -> pause here
    Task { @MainActor in
      self.player.pause()
    }
  }
}
