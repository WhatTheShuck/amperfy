//
//  PlaybackHandoffTest.swift
//  AmperfyKitTests
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

@testable import AmperfyKit
import XCTest

@MainActor
class PlaybackHandoffTest: XCTestCase {
  var cdHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  var mockCoreDataManager: MOCK_CoreDataManager!
  var storage: PersistentStorage!
  var eventLogger: EventLogger!
  var userStatistics: UserStatistics!
  var songDownloader: MOCK_SongDownloader!
  var backendApi: MOCK_BackendApi!
  var networkMonitor: MOCK_NetworkMonitor!
  var backendPlayer: BackendAudioPlayer!
  var mockMusicPlayable: MOCK_MusicPlayable!
  var playerData: PlayerData!
  var testMusicPlayer: AmperfyKit.AudioPlayer!
  var testPlayer: AmperfyKit.PlayerFacade!
  var testQueueHandler: AmperfyKit.PlayQueueHandler!
  var mockAudioStreamingPlayer: MOCK_AudioStreamingPlayer!

  var playlistAllCached: Playlist!
  let fillCount = 5

  override func setUp() async throws {
    cdHelper = CoreDataHelper()
    library = cdHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    songDownloader = MOCK_SongDownloader()
    mockAudioStreamingPlayer = MOCK_AudioStreamingPlayer()
    mockCoreDataManager = MOCK_CoreDataManager(persistentContainer: cdHelper.persistentContainer)
    storage = PersistentStorage(coreDataManager: mockCoreDataManager)
    eventLogger = EventLogger(storage: storage)
    userStatistics = library.getUserStatistics(appVersion: "")
    backendApi = MOCK_BackendApi()
    networkMonitor = MOCK_NetworkMonitor()
    backendPlayer = BackendAudioPlayer(
      createAudioStreamingPlayerCB: { self.mockAudioStreamingPlayer },
      audioSessionHandler: AudioSessionHandler(),
      eventLogger: eventLogger,
      getBackendApiCB: { accountInfo in self.backendApi },
      networkMonitor: networkMonitor,
      getPlayableDownloaderCB: { accountInfo in self.songDownloader },
      cacheProxy: library,
      userStatistics: userStatistics
    )
    mockMusicPlayable = MOCK_MusicPlayable()
    playerData = library.getPlayerData()
    testQueueHandler = PlayQueueHandler(playerData: playerData)
    testMusicPlayer = AudioPlayer(
      coreData: playerData,
      queueHandler: testQueueHandler,
      backendAudioPlayer: backendPlayer,
      settings: storage.settings,
      userStatistics: userStatistics
    )
    testPlayer = PlayerFacadeImpl(
      playerStatus: playerData,
      queueHandler: testQueueHandler,
      musicPlayer: testMusicPlayer,
      library: library,
      backendAudioPlayer: backendPlayer,
      userStatistics: userStatistics
    )
    testPlayer.addNotifier(notifier: mockMusicPlayable)

    guard let playlistAllCachedFetched = library.getPlaylist(
      for: account,
      id: cdHelper.seeder.playlists[3].id
    )
    else { XCTFail(); return }
    playlistAllCached = playlistAllCachedFetched
  }

  override func tearDown() {}

  func getAccountForSong(atIndex: Int) -> Account {
    let accIndex = cdHelper.seeder.songs[atIndex].accountIndex
    let accSeed = cdHelper.seeder.accounts[accIndex]
    return library.getAccount(info: AccountInfo(
      serverHash: accSeed.serverHash,
      userHash: accSeed.userHash,
      apiType: BackenApiType(rawValue: accSeed.apiType)!
    ))
  }

  func getSeedSong(atIndex: Int) -> Song {
    guard let song = library.getSong(
      for: getAccountForSong(atIndex: atIndex),
      id: cdHelper.seeder.songs[atIndex].id
    ) else {
      XCTFail("seed song \(atIndex) not available")
      fatalError()
    }
    return song
  }

  func fillPlayerWithSomeSongs() {
    for i in 0 ... fillCount - 1 {
      testPlayer.appendContextQueue(playables: [getSeedSong(atIndex: i)])
    }
  }

  func fillPlayerWithSomeSongsAndWaitingQueue() {
    fillPlayerWithSomeSongs()
    for i in 0 ... 3 {
      testPlayer.appendUserQueue(playables: [getSeedSong(atIndex: fillCount + i)])
    }
  }

  func makeItemRef(songSeedIndex: Int, accountIndex: Int = 0) -> String {
    "s:\(accountIndex):\(cdHelper.seeder.songs[songSeedIndex].id)"
  }

  var testAccountIdent: String { TestAccountInfo.create1().ident }

  func makeState(
    queueItems: [String],
    currentIndex: Int,
    isUserQueuePlaying: Bool = false,
    userQueueItems: [String] = [],
    accounts: [String]? = nil,
    isPlaying: Bool = false,
    elapsedTime: Double = 0.0
  )
    -> HandoffPlaybackState {
    HandoffPlaybackState(
      playerMode: .music,
      isPlaying: isPlaying,
      elapsedTime: elapsedTime,
      repeatMode: .off,
      contextName: "Test Context",
      accounts: accounts ?? [testAccountIdent],
      queueItems: queueItems,
      currentIndex: currentIndex,
      isUserQueuePlaying: isUserQueuePlaying,
      userQueueItems: userQueueItems
    )
  }

  // MARK: Capture

  func testCapture_NothingPlaying_ReturnsNil() {
    XCTAssertNil(HandoffPlaybackState.capture(from: testPlayer))
  }

  func testCapture_ContextQueuePlaying() {
    fillPlayerWithSomeSongs()
    playerData.setCurrentIndex(2)
    guard let state = HandoffPlaybackState.capture(from: testPlayer) else { XCTFail(); return }
    XCTAssertEqual(state.playerMode, .music)
    XCTAssertFalse(state.isUserQueuePlaying)
    XCTAssertEqual(state.currentIndex, 2)
    XCTAssertEqual(state.queueItems.count, fillCount)
    XCTAssertEqual(state.userQueueItems.count, 0)
    XCTAssertEqual(state.accounts, [testAccountIdent])
    for i in 0 ... fillCount - 1 {
      XCTAssertEqual(state.queueItems[i], makeItemRef(songSeedIndex: i))
    }
  }

  func testCapture_UserQueuePlaying() {
    fillPlayerWithSomeSongsAndWaitingQueue()
    playerData.setUserQueuePlaying(true)
    playerData.setCurrentIndex(1)
    guard let state = HandoffPlaybackState.capture(from: testPlayer) else { XCTFail(); return }
    XCTAssertTrue(state.isUserQueuePlaying)
    // context queue stays complete; current index marks the insertion point after the played items
    XCTAssertEqual(state.queueItems.count, fillCount)
    XCTAssertEqual(state.currentIndex, 2)
    // user queue contains the currently playing item first
    XCTAssertEqual(state.userQueueItems.count, 4)
    for i in 0 ... 3 {
      XCTAssertEqual(state.userQueueItems[i], makeItemRef(songSeedIndex: fillCount + i))
    }
  }

  func testCapture_ReflectsRepeatAndContextName() {
    fillPlayerWithSomeSongs()
    testPlayer.setRepeatMode(.all)
    guard let state = HandoffPlaybackState.capture(from: testPlayer) else { XCTFail(); return }
    XCTAssertEqual(state.repeatMode, .all)
    XCTAssertEqual(state.contextName, testPlayer.contextName)
  }

  // MARK: userInfo encoding

  func testUserInfoRoundTrip() {
    let state = HandoffPlaybackState(
      playerMode: .podcast,
      isPlaying: true,
      elapsedTime: 1234.5,
      repeatMode: .single,
      contextName: "My Mix",
      accounts: ["server1-user1", "server2-user2"],
      queueItems: ["s:0:12", "p:1:34", "r:0:56"],
      currentIndex: 1,
      isUserQueuePlaying: false,
      userQueueItems: ["s:1:78"]
    )
    guard let decoded = HandoffPlaybackState(userInfo: state.userInfoRepresentation)
    else { XCTFail(); return }
    XCTAssertEqual(decoded.playerMode, state.playerMode)
    XCTAssertEqual(decoded.isPlaying, state.isPlaying)
    XCTAssertEqual(decoded.elapsedTime, state.elapsedTime)
    XCTAssertEqual(decoded.repeatMode, state.repeatMode)
    XCTAssertEqual(decoded.contextName, state.contextName)
    XCTAssertEqual(decoded.accounts, state.accounts)
    XCTAssertEqual(decoded.queueItems, state.queueItems)
    XCTAssertEqual(decoded.currentIndex, state.currentIndex)
    XCTAssertEqual(decoded.isUserQueuePlaying, state.isUserQueuePlaying)
    XCTAssertEqual(decoded.userQueueItems, state.userQueueItems)
  }

  func testDecode_RejectsInvalidPayloads() {
    XCTAssertNil(HandoffPlaybackState(userInfo: [:]))

    let valid = makeState(queueItems: [makeItemRef(songSeedIndex: 0)], currentIndex: 0)
    var userInfo = valid.userInfoRepresentation
    XCTAssertNotNil(HandoffPlaybackState(userInfo: userInfo))

    // unsupported version
    userInfo["version"] = HandoffPlaybackState.payloadVersion + 1
    XCTAssertNil(HandoffPlaybackState(userInfo: userInfo))

    // index out of bounds
    userInfo = valid.userInfoRepresentation
    userInfo["currentIndex"] = 1
    XCTAssertNil(HandoffPlaybackState(userInfo: userInfo))

    // empty queue while context queue is playing
    userInfo = valid.userInfoRepresentation
    userInfo["queueItems"] = [String]()
    XCTAssertNil(HandoffPlaybackState(userInfo: userInfo))

    // user queue playing requires a user queue item
    userInfo = makeState(
      queueItems: [makeItemRef(songSeedIndex: 0)],
      currentIndex: 0,
      isUserQueuePlaying: true
    ).userInfoRepresentation
    userInfo["userQueueItems"] = [String]()
    XCTAssertNil(HandoffPlaybackState(userInfo: userInfo))
  }

  // MARK: Resolution

  func testResolve_AllItemsAvailable() {
    let state = makeState(
      queueItems: [
        makeItemRef(songSeedIndex: 0),
        makeItemRef(songSeedIndex: 1),
        makeItemRef(songSeedIndex: 2),
      ],
      currentIndex: 1
    )
    guard let resolved = state.resolve(using: library) else { XCTFail(); return }
    XCTAssertEqual(resolved.contextItems.count, 3)
    XCTAssertEqual(resolved.currentIndex, 1)
    XCTAssertEqual(resolved.contextItems[0].id, getSeedSong(atIndex: 0).id)
    XCTAssertEqual(resolved.contextItems[2].id, getSeedSong(atIndex: 2).id)
    XCTAssertEqual(resolved.contextName, "Test Context")
  }

  func testResolve_SkipsMissingItemsAndAdjustsIndex() {
    let state = makeState(
      queueItems: [
        "s:0:doesNotExist1",
        makeItemRef(songSeedIndex: 0),
        "s:0:doesNotExist2",
        makeItemRef(songSeedIndex: 1),
        makeItemRef(songSeedIndex: 2),
      ],
      currentIndex: 3
    )
    guard let resolved = state.resolve(using: library) else { XCTFail(); return }
    XCTAssertEqual(resolved.contextItems.count, 3)
    XCTAssertEqual(resolved.currentIndex, 1)
    XCTAssertEqual(resolved.contextItems[1].id, getSeedSong(atIndex: 1).id)
  }

  func testResolve_FailsIfCurrentItemIsMissing() {
    let state = makeState(
      queueItems: [makeItemRef(songSeedIndex: 0), "s:0:doesNotExist"],
      currentIndex: 1
    )
    XCTAssertNil(state.resolve(using: library))
  }

  func testResolve_FailsForUnknownAccount() {
    let state = makeState(
      queueItems: [makeItemRef(songSeedIndex: 0)],
      currentIndex: 0,
      accounts: ["deadbeefdeadbeef-feedfacefeedface"]
    )
    XCTAssertNil(state.resolve(using: library))
  }

  func testResolve_FailsIfPlayingUserQueueItemIsMissing() {
    let state = makeState(
      queueItems: [makeItemRef(songSeedIndex: 0)],
      currentIndex: 1,
      isUserQueuePlaying: true,
      userQueueItems: ["s:0:doesNotExist"]
    )
    XCTAssertNil(state.resolve(using: library))
  }

  // MARK: Restore

  /// waits until the player's async start-playing chain has applied the pending seek
  func waitForElapsedTime(toBecome expected: Double, timeout: Double = 2.0) async {
    let start = Date()
    while testPlayer.elapsedTime != expected, Date().timeIntervalSince(start) < timeout {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  func testRestore_ContextQueuePlaying() async {
    let cachedSongs = playlistAllCached.playables
    testPlayer.play(context: PlayContext(name: "Cached Mix", playables: cachedSongs))
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 0))
    testPlayer.setRepeatMode(.all)
    mockAudioStreamingPlayer.mockElapsedTime = 33.0
    guard let state = HandoffPlaybackState.capture(from: testPlayer) else { XCTFail(); return }
    XCTAssertTrue(state.isPlaying)
    XCTAssertEqual(state.elapsedTime, 33.0)

    // bring the player into a completely different state
    testPlayer.setRepeatMode(.off)
    testPlayer.clearQueues()
    testPlayer.appendContextQueue(playables: [getSeedSong(atIndex: 0)])

    guard let resolved = state.resolve(using: library) else { XCTFail(); return }
    testPlayer.restoreHandoffPlayback(resolved)

    XCTAssertEqual(testPlayer.playerMode, .music)
    XCTAssertEqual(testPlayer.repeatMode, .all)
    XCTAssertFalse(testPlayer.isShuffle)
    XCTAssertEqual(testPlayer.contextName, "Cached Mix")
    let restoredQueue = testPlayer.getAllPrevQueueItems() +
      [testPlayer.currentlyPlaying!] + testPlayer.getAllNextQueueItems()
    XCTAssertEqual(restoredQueue.count, cachedSongs.count)
    XCTAssertEqual(restoredQueue.map { $0.id }, cachedSongs.map { $0.id })
    XCTAssertEqual(playerData.currentIndex, 1)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, cachedSongs[1].id)
    XCTAssertTrue(testPlayer.isPlaying)

    await waitForElapsedTime(toBecome: 33.0)
    XCTAssertEqual(testPlayer.elapsedTime, 33.0)
  }

  func testRestore_PausedKeepsPlayerSilent() {
    let cachedSongs = playlistAllCached.playables
    let state = makeState(
      queueItems: cachedSongs.map { "s:0:\($0.id)" },
      currentIndex: 2,
      isPlaying: false,
      elapsedTime: 60.0
    )
    guard let resolved = state.resolve(using: library) else { XCTFail(); return }
    testPlayer.restoreHandoffPlayback(resolved)

    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(playerData.currentIndex, 2)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, cachedSongs[2].id)
    // the seek to the handed-off position is pending until playback starts
    XCTAssertEqual(testMusicPlayer.initialSeekTime, 60.0)
  }

  func testRestore_UserQueuePlaying() {
    fillPlayerWithSomeSongsAndWaitingQueue()
    playerData.setUserQueuePlaying(true)
    playerData.setCurrentIndex(1)
    guard let state = HandoffPlaybackState.capture(from: testPlayer) else { XCTFail(); return }

    testPlayer.clearQueues()
    XCTAssertNil(testPlayer.currentlyPlaying)

    guard let resolved = state.resolve(using: library) else { XCTFail(); return }
    testPlayer.restoreHandoffPlayback(resolved)

    XCTAssertTrue(testPlayer.isUserQueuePlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, getSeedSong(atIndex: fillCount).id)
    XCTAssertEqual(
      testPlayer.getAllUserQueueItems().map { $0.id },
      [
        getSeedSong(atIndex: fillCount + 1).id,
        getSeedSong(atIndex: fillCount + 2).id,
        getSeedSong(atIndex: fillCount + 3).id,
      ]
    )
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 2)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 3)
    let contextItems = testPlayer.getAllPrevQueueItems() + testPlayer.getAllNextQueueItems()
    XCTAssertEqual(
      contextItems.map { $0.id },
      (0 ... fillCount - 1).map { getSeedSong(atIndex: $0).id }
    )
  }

  func testRestore_TurnsShuffleOff() {
    fillPlayerWithSomeSongs()
    guard let state = HandoffPlaybackState.capture(from: testPlayer) else { XCTFail(); return }

    testPlayer.toggleShuffle()
    XCTAssertTrue(testPlayer.isShuffle)

    guard let resolved = state.resolve(using: library) else { XCTFail(); return }
    testPlayer.restoreHandoffPlayback(resolved)
    XCTAssertFalse(testPlayer.isShuffle)
    let restoredQueue = testPlayer.getAllPrevQueueItems() +
      [testPlayer.currentlyPlaying!] + testPlayer.getAllNextQueueItems()
    XCTAssertEqual(
      restoredQueue.map { $0.id },
      (0 ... fillCount - 1).map { getSeedSong(atIndex: $0).id }
    )
  }

  func testCapture_ShuffledQueueKeepsVisibleOrder() {
    let cachedSongs = playlistAllCached.playables
    testPlayer.playShuffled(context: PlayContext(name: "Shuffled", playables: cachedSongs))
    let visibleOrder = (
      testPlayer.getAllPrevQueueItems() +
        [testPlayer.currentlyPlaying!] + testPlayer.getAllNextQueueItems()
    ).map { $0.id }
    guard let state = HandoffPlaybackState.capture(from: testPlayer) else { XCTFail(); return }
    guard let resolved = state.resolve(using: library) else { XCTFail(); return }
    XCTAssertEqual(resolved.contextItems.map { $0.id }, visibleOrder)
  }
}
