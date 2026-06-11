//
//  PlaybackHandoff.swift
//  AmperfyKit
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

import Foundation

// MARK: - ResolvedHandoffPlayback

/// A handoff payload whose items have been resolved against the local library,
/// ready to be applied to the player.
public struct ResolvedHandoffPlayback {
  public let playerMode: PlayerMode
  public let isPlaying: Bool
  public let elapsedTime: Double
  public let repeatMode: RepeatMode
  public let contextName: String
  /// The active queue in visible play order (prev + current + next);
  /// when `isUserQueuePlaying` the current item is part of `userQueueItems` instead.
  public let contextItems: [AbstractPlayable]
  /// Index of the current item in `contextItems`; when `isUserQueuePlaying`
  /// it is the count of already played context items.
  public let currentIndex: Int
  public let isUserQueuePlaying: Bool
  /// User queue ("Play Next"); when `isUserQueuePlaying` its first entry is the current item.
  public let userQueueItems: [AbstractPlayable]
}

// MARK: - HandoffPlaybackState

/// Playback state that is passed between devices via Handoff (NSUserActivity).
/// Items are referenced by type, account ident and remote library id.
public struct HandoffPlaybackState {
  public static let activityType = "de.familie-zimba.amperfy-music.handoff-playback"
  static let payloadVersion = 1
  /// Queues are capped to keep the activity payload small enough for a quick transfer.
  static let maxQueueItemCount = 500

  enum UserInfoKey: String {
    case version
    case playerMode
    case isPlaying
    case elapsedTime
    case repeatMode
    case contextName
    case accounts
    case queueItems
    case currentIndex
    case isUserQueuePlaying
    case userQueueItems
  }

  private enum ItemTypePrefix: String {
    case song = "s"
    case podcastEpisode = "p"
    case radio = "r"

    init(derivedType: DerivedPlayableType) {
      switch derivedType {
      case .song: self = .song
      case .podcastEpisode: self = .podcastEpisode
      case .radio: self = .radio
      }
    }
  }

  public internal(set) var playerMode: PlayerMode
  public internal(set) var isPlaying: Bool
  public internal(set) var elapsedTime: Double
  public internal(set) var repeatMode: RepeatMode
  public internal(set) var contextName: String
  /// Account idents (`serverHash-userHash`) referenced by the item lists.
  var accounts: [String]
  /// Active queue in visible play order, encoded as `"<type>:<accountIndex>:<id>"`.
  var queueItems: [String]
  public internal(set) var currentIndex: Int
  public internal(set) var isUserQueuePlaying: Bool
  var userQueueItems: [String]

  // MARK: Capture

  /// Captures the player's current playback state; nil if nothing is playing
  /// or the current item can't be referenced across devices.
  @MainActor
  public static func capture(from player: PlayerFacade) -> HandoffPlaybackState? {
    guard let current = player.currentlyPlaying else { return nil }

    var queue: [AbstractPlayable]
    var currentIndex: Int
    var userQueue: [AbstractPlayable]
    let isUserQueuePlaying = player.playerMode == .music && player.isUserQueuePlaying

    let prevItems = player.getAllPrevQueueItems()
    let nextItems = player.getAllNextQueueItems()
    if isUserQueuePlaying {
      queue = prevItems + nextItems
      currentIndex = prevItems.count
      userQueue = [current] + player.getAllUserQueueItems()
    } else {
      queue = prevItems + [current] + nextItems
      currentIndex = prevItems.count
      userQueue = player.playerMode == .music ? player.getAllUserQueueItems() : []
    }

    // cap overlong queues with a window centered around the current item
    if queue.count > maxQueueItemCount {
      let start = max(0, min(currentIndex - maxQueueItemCount / 2, queue.count - maxQueueItemCount))
      queue = Array(queue[start ..< start + maxQueueItemCount])
      currentIndex -= start
    }
    if userQueue.count > maxQueueItemCount {
      userQueue = Array(userQueue.prefix(maxQueueItemCount))
    }

    var accounts = [String]()
    var encodedQueue = [String]()
    var adjustedIndex = currentIndex
    for (index, playable) in queue.enumerated() {
      if let encoded = encode(playable: playable, accounts: &accounts) {
        encodedQueue.append(encoded)
      } else {
        guard isUserQueuePlaying || index != currentIndex else { return nil }
        if index < currentIndex { adjustedIndex -= 1 }
      }
    }
    var encodedUserQueue = [String]()
    for (index, playable) in userQueue.enumerated() {
      if let encoded = encode(playable: playable, accounts: &accounts) {
        encodedUserQueue.append(encoded)
      } else if isUserQueuePlaying, index == 0 {
        return nil
      }
    }

    return HandoffPlaybackState(
      playerMode: player.playerMode,
      isPlaying: player.isPlaying,
      elapsedTime: player.elapsedTime,
      repeatMode: player.repeatMode,
      contextName: player.contextName,
      accounts: accounts,
      queueItems: encodedQueue,
      currentIndex: adjustedIndex,
      isUserQueuePlaying: isUserQueuePlaying,
      userQueueItems: encodedUserQueue
    )
  }

  private static func encode(
    playable: AbstractPlayable,
    accounts: inout [String]
  )
    -> String? {
    guard let ident = playable.account?.ident, !ident.isEmpty else { return nil }
    let accountIndex: Int
    if let existing = accounts.firstIndex(of: ident) {
      accountIndex = existing
    } else {
      accounts.append(ident)
      accountIndex = accounts.count - 1
    }
    let prefix = ItemTypePrefix(derivedType: playable.derivedType)
    return "\(prefix.rawValue):\(accountIndex):\(playable.id)"
  }

  // MARK: NSUserActivity userInfo

  public var userInfoRepresentation: [String: Any] {
    [
      UserInfoKey.version.rawValue: Self.payloadVersion,
      UserInfoKey.playerMode.rawValue: Int(playerMode.rawValue),
      UserInfoKey.isPlaying.rawValue: isPlaying,
      UserInfoKey.elapsedTime.rawValue: elapsedTime,
      UserInfoKey.repeatMode.rawValue: Int(repeatMode.rawValue),
      UserInfoKey.contextName.rawValue: contextName,
      UserInfoKey.accounts.rawValue: accounts,
      UserInfoKey.queueItems.rawValue: queueItems,
      UserInfoKey.currentIndex.rawValue: currentIndex,
      UserInfoKey.isUserQueuePlaying.rawValue: isUserQueuePlaying,
      UserInfoKey.userQueueItems.rawValue: userQueueItems,
    ]
  }

  public init?(userInfo: [AnyHashable: Any]) {
    guard let version = userInfo[UserInfoKey.version.rawValue] as? Int,
          version == Self.payloadVersion,
          let playerModeRaw = userInfo[UserInfoKey.playerMode.rawValue] as? Int,
          let playerMode = PlayerMode(rawValue: Int16(clamping: playerModeRaw)),
          let isPlaying = userInfo[UserInfoKey.isPlaying.rawValue] as? Bool,
          let elapsedTime = userInfo[UserInfoKey.elapsedTime.rawValue] as? Double,
          let repeatModeRaw = userInfo[UserInfoKey.repeatMode.rawValue] as? Int,
          let repeatMode = RepeatMode(rawValue: Int16(clamping: repeatModeRaw)),
          let contextName = userInfo[UserInfoKey.contextName.rawValue] as? String,
          let accounts = userInfo[UserInfoKey.accounts.rawValue] as? [String],
          let queueItems = userInfo[UserInfoKey.queueItems.rawValue] as? [String],
          let currentIndex = userInfo[UserInfoKey.currentIndex.rawValue] as? Int,
          let isUserQueuePlaying = userInfo[UserInfoKey.isUserQueuePlaying.rawValue] as? Bool,
          let userQueueItems = userInfo[UserInfoKey.userQueueItems.rawValue] as? [String]
    else { return nil }

    if isUserQueuePlaying {
      guard !userQueueItems.isEmpty,
            currentIndex >= 0, currentIndex <= queueItems.count else { return nil }
    } else {
      guard !queueItems.isEmpty,
            currentIndex >= 0, currentIndex < queueItems.count else { return nil }
    }

    self.playerMode = playerMode
    self.isPlaying = isPlaying
    self.elapsedTime = elapsedTime
    self.repeatMode = repeatMode
    self.contextName = contextName
    self.accounts = accounts
    self.queueItems = queueItems
    self.currentIndex = currentIndex
    self.isUserQueuePlaying = isUserQueuePlaying
    self.userQueueItems = userQueueItems
  }

  init(
    playerMode: PlayerMode,
    isPlaying: Bool,
    elapsedTime: Double,
    repeatMode: RepeatMode,
    contextName: String,
    accounts: [String],
    queueItems: [String],
    currentIndex: Int,
    isUserQueuePlaying: Bool,
    userQueueItems: [String]
  ) {
    self.playerMode = playerMode
    self.isPlaying = isPlaying
    self.elapsedTime = elapsedTime
    self.repeatMode = repeatMode
    self.contextName = contextName
    self.accounts = accounts
    self.queueItems = queueItems
    self.currentIndex = currentIndex
    self.isUserQueuePlaying = isUserQueuePlaying
    self.userQueueItems = userQueueItems
  }

  // MARK: Resolution

  /// Resolves the referenced items against the local library.
  /// Items not available on this device are skipped; nil is returned if the
  /// currently playing item (or every item) can't be resolved.
  @MainActor
  public func resolve(using library: LibraryStorage) -> ResolvedHandoffPlayback? {
    let resolvedAccounts: [Account?] = accounts.map { library.getAccount(ident: $0) }

    func resolve(itemRef: String) -> AbstractPlayable? {
      let parts = itemRef.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
      guard parts.count == 3,
            let prefix = ItemTypePrefix(rawValue: String(parts[0])),
            let accountIndex = Int(parts[1]),
            accountIndex >= 0, accountIndex < resolvedAccounts.count,
            let account = resolvedAccounts[accountIndex]
      else { return nil }
      let id = String(parts[2])
      guard !id.isEmpty else { return nil }
      switch prefix {
      case .song: return library.getSong(for: account, id: id)
      case .podcastEpisode: return library.getPodcastEpisode(for: account, id: id)
      case .radio: return library.getRadio(for: account, id: id)
      }
    }

    var contextItems = [AbstractPlayable]()
    var adjustedIndex = currentIndex
    for (index, itemRef) in queueItems.enumerated() {
      if let playable = resolve(itemRef: itemRef) {
        contextItems.append(playable)
      } else {
        guard isUserQueuePlaying || index != currentIndex else { return nil }
        if index < currentIndex { adjustedIndex -= 1 }
      }
    }
    var resolvedUserQueue = [AbstractPlayable]()
    for (index, itemRef) in userQueueItems.enumerated() {
      if let playable = resolve(itemRef: itemRef) {
        resolvedUserQueue.append(playable)
      } else if isUserQueuePlaying, index == 0 {
        return nil
      }
    }
    guard !contextItems.isEmpty || !resolvedUserQueue.isEmpty else { return nil }

    return ResolvedHandoffPlayback(
      playerMode: playerMode,
      isPlaying: isPlaying,
      elapsedTime: elapsedTime,
      repeatMode: repeatMode,
      contextName: contextName,
      contextItems: contextItems,
      currentIndex: adjustedIndex,
      isUserQueuePlaying: isUserQueuePlaying,
      userQueueItems: resolvedUserQueue
    )
  }
}
