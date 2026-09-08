import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "ariasbruno.mixarchy"
  ipcTarget: "ariasbruno.mixarchy"
  manageIpc: true

  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  property string ctlPath: pluginDir + "/bin/mixarchy-ctl"
  property bool isBuilding: false

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // State
  property string currentScreen: "tracks" // "tracks" | "playlists"
  property string activePlaylistName: ""
  property var activePlaylistTrackPaths: []
  property string searchFilter: ""
  property bool lockSearchQueue: false
  property string sortMode: "artist" // "artist" | "album" | "title" | "recent" | "duration"
  property bool sortAsc: true

  readonly property var sortModes: [
    { id: "artist", label: "Artist", icon: "󰠃" },
    { id: "album", label: "Album", icon: "󰀥" },
    { id: "title", label: "Title", icon: "󰰎" },
    { id: "recent", label: "Recent", icon: "󰔚" },
    { id: "duration", label: "Duration", icon: "󱎫" }
  ]

  readonly property var currentSortModeObj: {
    for (var i = 0; i < sortModes.length; i++) {
      if (sortModes[i].id === root.sortMode) return sortModes[i]
    }
    return sortModes[0]
  }

  function cycleSortMode(reverse) {
    var curIdx = 0
    for (var i = 0; i < sortModes.length; i++) {
      if (sortModes[i].id === root.sortMode) {
        curIdx = i
        break
      }
    }
    var nextIdx = reverse
      ? (curIdx - 1 + sortModes.length) % sortModes.length
      : (curIdx + 1) % sortModes.length
    root.sortMode = sortModes[nextIdx].id
  }

  // Library cache
  property var tracks: []
  property var playlists: []
  property int trackCount: 0
  property int playlistCount: 0
  property bool libraryLoading: false

  // Player state
  property bool isPlaying: false
  property bool isMpvRunning: false
  property bool isPaused: true
  property bool shuffle: false
  property var currentTrack: null
  property string sourceName: "Tracks"
  property int queueIndex: 0
  property int queueTotal: 0
  property string timePosStr: "0:00"
  property string durationStr: "0:00"
  property real timePos: 0
  property real duration: 0

  // Cover art state (fetched on-demand, never in the status poll)
  property string nowPlayingCover: "" // now-playing area only; data URI
  property string lastPlayingTrackId: "" // track id currently loaded in nowPlayingCover
  property var trackThumbs: ({}) // track id -> thumb file path (track-list rows), "" = verified no cover
  property var coverRequested: ({}) // track id -> true while a cover fetch is pending
  property var coverQueue: [] // pending cover ids drained serially by coverProc

  // Local playback clock: the last authoritative time/position from the
  // backend and the wall-clock moment it was captured. Used to animate the
  // progress smoothly between (now less frequent) status polls without
  // spawning a status process every second.
  property real lastSyncTimePos: 0
  property real lastSyncWall: 0

  // ------------------------------------------------------------- Process handlers
  Process {
    id: statusProc
    command: [root.ctlPath, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var res = JSON.parse(text)
          if (res.ok) {
            root.isPlaying = res.is_playing
            root.isMpvRunning = !!res.running
            root.isPaused = res.is_paused
            root.shuffle = res.shuffle
            root.currentTrack = res.track
            root.sourceName = res.source_name || "Tracks"
            root.queueIndex = res.queue_index || 0
            root.queueTotal = res.queue_total || 0
            root.timePos = res.time_pos || 0
            root.duration = res.duration || 0
            root.timePosStr = res.time_pos_str || "0:00"
            root.durationStr = res.duration_str || "0:00"
            root.lastSyncTimePos = root.timePos
            root.lastSyncWall = Date.now()
          }
        } catch (e) {}
      }
    }
  }

  Process {
    id: libProc
    command: [root.ctlPath, "library"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.libraryLoading = false
        try {
          var res = JSON.parse(text)
          root.tracks = res.tracks || []
          root.playlists = res.playlists || []
          root.trackCount = res.track_count || root.tracks.length
          root.playlistCount = res.playlist_count || root.playlists.length
        } catch (e) {}
      }
    }
  }

  Process {
    id: actionProc
    property var nextAction: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.refreshStatus()
        if (actionProc.nextAction) {
          var act = actionProc.nextAction
          actionProc.nextAction = null
          act()
        }
      }
    }
  }

  // On-demand cover fetch. NOT part of the status poll; driven separately so
  // the 5s poll never carries cover payloads. Requests are serialized: one
  // in-flight process plus an explicit queue drained on finish, so a burst of
  // visible rows (ListView instantiates ~20 delegates) never drops requests or
  // misattributes a result to the wrong track id.
  Process {
    id: coverProc
    property var pendingId: ""
    property bool pendingThumbOnly: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var id = coverProc.pendingId
        var thumbOnly = coverProc.pendingThumbOnly
        coverProc.pendingId = ""
        coverProc.pendingThumbOnly = false
        root.coverRequested[id] = false
        try {
          var res = JSON.parse(text)
          if (res.ok && res.has_cover) {
            if (!thumbOnly && id !== "" && root.currentTrack && root.currentTrack.id === id) {
              root.nowPlayingCover = res.data_uri || ""
            }
            if (res.thumb) {
              // Re-assign object to trigger QML property notification signal for trackThumbs
              var updatedThumbs = Object.assign({}, root.trackThumbs)
              updatedThumbs[id] = res.thumb
              root.trackThumbs = updatedThumbs
            }
          } else if (res.ok && !res.has_cover) {
            // Track genuinely has no embedded art: remember it so we don't
            // re-request it on every scroll re-visit.
            var updatedEmpty = Object.assign({}, root.trackThumbs)
            updatedEmpty[id] = ""
            root.trackThumbs = updatedEmpty
            if (!thumbOnly && id !== "" && root.currentTrack && root.currentTrack.id === id) {
              root.nowPlayingCover = ""
            }
          }
        } catch (e) {} // malformed response: leave trackThumbs unset -> retried on next scroll
        if (root.coverQueue.length > 0) {
          var next = root.coverQueue.shift()
          coverProc.pendingId = next.id
          coverProc.pendingThumbOnly = next.thumbOnly
          coverProc.command = next.thumbOnly
            ? [root.ctlPath, "cover", "--thumb", next.id]
            : [root.ctlPath, "cover", next.id]
          coverProc.running = true
        }
      }
    }
  }

  Process {
    id: checkBinProc
    command: ["test", "-x", root.ctlPath]
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) {
        checkTargetProc.running = true
      }
    }
  }

  Process {
    id: checkTargetProc
    command: ["test", "-x", root.pluginDir + "/target/release/mixarchy-ctl"]
    onExited: function(exitCode, exitStatus) {
      if (exitCode === 0) {
        root.ctlPath = root.pluginDir + "/target/release/mixarchy-ctl"
      } else {
        // Prefer the verified release download (fast, no toolchain) over an
        // in-process cargo build; building is only a last-resort dev fallback.
        downloadMkdirProc.running = true
      }
    }
  }

  Process {
    id: checkCargoProc
    command: ["which", "cargo"]
    onExited: function(exitCode, exitStatus) {
      root.isBuilding = true
      if (exitCode === 0) {
        buildProc.running = true
      } else {
        root.isBuilding = false
        console.warn("Mixarchy: could not download a verified binary and cargo is not installed")
      }
    }
  }

  Process {
    id: downloadMkdirProc
    command: ["mkdir", "-p", root.pluginDir + "/bin"]
    onExited: function(exitCode, exitStatus) {
      if (exitCode === 0) downloadFetchProc.running = true
      else downloadError()
    }
  }

  readonly property string releaseTag: "v1.0.0"
  readonly property string expectedSha256: "d0c66ca6859d4c1777d05c1b508e88bc69a40322f9d0696d7e7e0c525eebec25"

  Process {
    id: downloadFetchProc
    command: [
      "curl", "-fsSL",
      "--connect-timeout", "10",
      "--max-time", "120",
      "--max-filesize", "10485760",
      "https://github.com/ariasbruno/mixarchy/releases/download/" + root.releaseTag + "/mixarchy-ctl",
      "-o", root.pluginDir + "/bin/mixarchy-ctl.tmp"
    ]
    onExited: function(exitCode, exitStatus) {
      if (exitCode === 0) downloadVerifyProc.running = true
      else downloadError()
    }
  }

  Process {
    id: downloadVerifyProc
    // Verify pinned sha256 on temporary file without shell interpolation.
    // If valid: chmod 755 and atomic mv to destination.
    // If invalid: delete temporary file and exit non-zero.
    command: ["bash", "-c",
      "act=$(sha256sum \"$1\" 2>/dev/null | awk '{print $1}'); if [ -n \"$act\" ] && [ \"$act\" = \"$2\" ]; then chmod 755 \"$1\" && mv -f \"$1\" \"$3\"; exit 0; else rm -f \"$1\"; exit 1; fi",
      "verify-pinned",
      root.pluginDir + "/bin/mixarchy-ctl.tmp",
      root.expectedSha256,
      root.pluginDir + "/bin/mixarchy-ctl"]
    onExited: function(exitCode, exitStatus) {
      root.isBuilding = false
      if (exitCode === 0) {
        root.ctlPath = root.pluginDir + "/bin/mixarchy-ctl"
        root.refreshStatus()
        root.refreshLibrary()
      } else {
        downloadError()
      }
    }
  }

  function downloadError() {
    root.isBuilding = false
    console.warn("Mixarchy: Failed to download or verify mixarchy-ctl binary; falling back to cargo build")
    checkCargoProc.running = true
  }

  Process {
    id: buildProc
    command: ["cargo", "build", "--release", "--locked", "--manifest-path", root.pluginDir + "/Cargo.toml"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.isBuilding = false
        root.ctlPath = root.pluginDir + "/target/release/mixarchy-ctl"
        root.refreshStatus()
        root.refreshLibrary()
      }
    }
  }

  function runCtl(args, onDone) {
    if (actionProc.running) return
    var cmd = [root.ctlPath].concat(args)
    actionProc.nextAction = onDone || null
    actionProc.command = cmd
    actionProc.running = true
  }

  function refreshStatus() {
    if (!statusProc.running) statusProc.running = true
  }

  function refreshLibrary() {
    root.libraryLoading = true
    if (!libProc.running) libProc.running = true
  }

  // Request the cover for a single track id, deduplicated. Called on-demand
  // for the now-playing area and for visible track-list rows only, so a large
  // library never triggers a flood of cover fetches. Rows pass thumbOnly=true
  // to transport only the cached thumb path; only the current track asks for
  // the full-res data URI.
  function requestCover(id, thumbOnly) {
    if (!id) return
    if (thumbOnly && root.trackThumbs[id] !== undefined) return // row: already have it (or know it has none)
    if (root.coverRequested[id]) return // already pending or queued
    root.coverRequested[id] = true
    var entry = { id: id, thumbOnly: thumbOnly }
    if (coverProc.running) {
      root.coverQueue.push(entry)
      return
    }
    coverProc.pendingId = entry.id
    coverProc.pendingThumbOnly = entry.thumbOnly
    coverProc.command = entry.thumbOnly
      ? [root.ctlPath, "cover", "--thumb", entry.id]
      : [root.ctlPath, "cover", entry.id]
    coverProc.running = true
  }

  function rescanLibrary() {
    root.trackThumbs = ({})
    root.coverRequested = ({})
    root.coverQueue = []
    runCtl(["scan"], function() {
      refreshLibrary()
    })
  }

  function playTrack(trackPath, source) {
    runCtl(["play", trackPath, source || "Tracks"])
  }

  function togglePlay() {
    runCtl(["toggle"])
  }

  function nextTrack() {
    runCtl(["next"])
  }

  function prevTrack() {
    runCtl(["prev"])
  }

  function toggleShuffle() {
    runCtl(["shuffle"])
  }

  function stopPlayer() {
    runCtl(["stop"])
  }

  function seekTo(sec) {
    runCtl(["seek", String(sec)])
  }

  function formatSec(sec) {
    var s = Math.max(0, Math.floor(sec))
    var m = Math.floor(s / 60)
    var remS = s % 60
    return m + ":" + (remS < 10 ? "0" : "") + remS
  }

  // ------------------------------------------------------------- Timers
  // Animate the playback progress locally between status polls so the slider
  // stays fluid without spawning a `mixarchy-ctl status` process every second.
  Timer {
    id: progressTimer
    interval: 200
    repeat: true
    running: root.isPlaying
    onTriggered: {
      root.timePos = root.lastSyncTimePos + (Date.now() - root.lastSyncWall) / 1000
      root.timePosStr = root.formatSec(root.timePos)
    }
  }

  // Re-sync authoritative state from the backend much less often (5s instead
  // of 1s): catches track transitions, pause/toggle, and end-of-track while the
  // local clock above keeps the visible progress smooth in between.
  Timer {
    id: pollTimer
    interval: 5000
    repeat: true
    running: root.opened || root.isPlaying || root.isMpvRunning
    onTriggered: root.refreshStatus()
  }

  Component.onCompleted: {
    checkBinProc.running = true
    refreshStatus()
    refreshLibrary()
  }

  onOpenedChanged: {
    if (opened) {
      refreshStatus()
      if (root.tracks.length === 0) refreshLibrary()
    }
  }

  onCurrentTrackChanged: {
    // Fetch the full-resolution cover for the now-playing area whenever the
    // active track changes. Never part of the poll. Only clear and re-fetch if
    // the track ID actually changed, preventing flickers on play/pause polls.
    var newId = (root.currentTrack && root.currentTrack.id) ? root.currentTrack.id : ""
    if (newId !== root.lastPlayingTrackId) {
      root.lastPlayingTrackId = newId
      root.nowPlayingCover = ""
      if (newId !== "") {
        root.requestCover(newId, false)
      }
    }
  }

  // ------------------------------------------------------------- Tracks Processing
  function sortTracksList(tracksList) {
    var sorted = tracksList.slice()
    sorted.sort(function(a, b) {
      var res = 0
      if (root.sortMode === "artist") {
        var artA = (a.artist || "Unknown").toLowerCase()
        var artB = (b.artist || "Unknown").toLowerCase()
        res = artA.localeCompare(artB)
        if (res === 0) {
          var albA = (a.album || "Unknown").toLowerCase()
          var albB = (b.album || "Unknown").toLowerCase()
          res = albA.localeCompare(albB)
        }
        if (res === 0) {
          res = (a.track_num || 0) - (b.track_num || 0)
        }
        if (res === 0) {
          res = (a.title || "").localeCompare(b.title || "")
        }
      } else if (root.sortMode === "album") {
        var albA = (a.album || "Unknown").toLowerCase()
        var albB = (b.album || "Unknown").toLowerCase()
        res = albA.localeCompare(albB)
        if (res === 0) {
          res = (a.track_num || 0) - (b.track_num || 0)
        }
        if (res === 0) {
          res = (a.title || "").localeCompare(b.title || "")
        }
      } else if (root.sortMode === "recent") {
        res = (b.mtime || 0) - (a.mtime || 0)
        if (res === 0) {
          res = (a.title || "").localeCompare(b.title || "")
        }
      } else if (root.sortMode === "duration") {
        res = (b.duration || 0) - (a.duration || 0)
        if (res === 0) {
          res = (a.title || "").localeCompare(b.title || "")
        }
      } else { // "title" or "az"
        var titA = (a.title || a.filename || "").toLowerCase()
        var titB = (b.title || b.filename || "").toLowerCase()
        res = titA.localeCompare(titB)
        if (res === 0) {
          res = (a.artist || "").localeCompare(b.artist || "")
        }
      }
      return root.sortAsc ? res : -res
    })
    return sorted
  }

  // Active full tracks (playlist or library, fully sorted)
  readonly property var activeFullTracks: {
    var list = root.tracks || []
    var plPaths = root.activePlaylistTrackPaths || []
    if (root.activePlaylistName !== "" && plPaths.length > 0) {
      var pathSet = {}
      for (var p = 0; p < plPaths.length; p++) {
        pathSet[plPaths[p]] = true
      }
      list = list.filter(function(t) { return pathSet[t.path] })
    }
    return root.sortTracksList(list)
  }

  // Filtered tracks (for UI display in tracks list)
  readonly property var filteredTracks: {
    var list = root.activeFullTracks
    if (root.searchFilter.trim() !== "") {
      var query = root.searchFilter.toLowerCase().trim()
      list = list.filter(function(t) {
        return (t.title && t.title.toLowerCase().indexOf(query) !== -1) ||
               (t.artist && t.artist.toLowerCase().indexOf(query) !== -1) ||
               (t.album && t.album.toLowerCase().indexOf(query) !== -1)
      })
    }
    return list
  }

  // ------------------------------------------------------------- Bar Button
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰎆"
    tooltipText: root.currentTrack ? (root.currentTrack.title + " - " + root.currentTrack.artist) : "Mixarchy"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        root.togglePlay()
      } else {
        root.toggle()
      }
    }
  }

  // ------------------------------------------------------------- Popup Panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher

    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(Style.space(560), Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ColumnLayout {
        id: mainColumn
        anchors.fill: parent
        spacing: Style.space(8)

        // ========================================== [NAV TABS]
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Button {
            text: root.activePlaylistName !== "" ? (root.activePlaylistName + " (" + root.activePlaylistTrackPaths.length + ")") : ("Tracks (" + root.trackCount + ")")
            iconText: "󰎆"
            bordered: true
            selected: root.currentScreen === "tracks"
            onClicked: {
              if (root.currentScreen === "tracks" && root.activePlaylistName !== "") {
                // Clear playlist filter when clicking again
                root.activePlaylistName = ""
                root.activePlaylistTrackPaths = []
              }
              root.currentScreen = "tracks"
            }
          }

          Button {
            text: "Playlists (" + root.playlistCount + ")"
            iconText: ""
            bordered: true
            selected: root.currentScreen === "playlists"
            onClicked: root.currentScreen = "playlists"
          }

          Item { Layout.fillWidth: true }

          Button {
            iconText: "󰑐"
            tooltipText: "Rescan Library (~/Music)"
            bordered: true
            onClicked: root.rescanLibrary()
          }
        }

        PanelSeparator { Layout.fillWidth: true }

        // ========================================== [MAIN CONTENT]
        StackLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          currentIndex: root.currentScreen === "tracks" ? 0 : 1

          // ---------------------------------------- TAB 1: TRACKS (DEFAULT)
          ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Style.space(6)

            // Search bar with queue lock toggle
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(4)

              TextField {
                id: searchField
                Layout.fillWidth: true
                placeholderText: "Search tracks, artists, albums..."
                text: root.searchFilter
                onTextChanged: root.searchFilter = text
              }

              Button {
                id: lockSearchBtn
                iconText: root.lockSearchQueue ? "󰌾" : "󰌿"
                tooltipText: root.lockSearchQueue
                  ? "Queue locked to search results (Click to unlock)"
                  : "Queue plays from full library (Click to lock to search)"
                bordered: true
                active: root.lockSearchQueue
                onClicked: root.lockSearchQueue = !root.lockSearchQueue
              }
            }

            // Controls & sort row
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(4)

              Button {
                iconText: root.currentSortModeObj.icon
                text: root.currentSortModeObj.label
                tooltipText: "Sort: " + root.currentSortModeObj.label + " (click: next, right-click: prev)"
                bordered: true
                onClicked: root.cycleSortMode(false)
                onRightClicked: root.cycleSortMode(true)
              }

              Button {
                iconText: root.sortAsc ? "󰁝" : "󰁅"
                tooltipText: root.sortAsc ? "Ascending order" : "Descending order"
                bordered: true
                onClicked: root.sortAsc = !root.sortAsc
              }

              Button {
                iconText: "󰐊"
                text: "Play"
                bordered: true
                active: true
                onClicked: {
                  var source = root.activePlaylistName !== "" ? root.activePlaylistName : "Tracks"
                  var isSearching = root.searchFilter.trim() !== ""
                  var shouldLock = isSearching && root.lockSearchQueue
                  var list = shouldLock ? root.filteredTracks : root.activeFullTracks
                  if (list.length > 0) {
                    var paths = list.map(function(t) { return t.path })
                    var queueSource = shouldLock ? ("Search: " + root.searchFilter.trim()) : source
                    root.runCtl(["play-queue", queueSource, "play-all"].concat(paths))
                  }
                }
              }

              Button {
                iconText: ""
                bordered: true
                selected: root.shuffle
                onClicked: root.toggleShuffle()
              }

              Item { Layout.fillWidth: true }

              Text {
                text: root.filteredTracks.length + " tracks" + ((root.searchFilter.trim() !== "" && root.lockSearchQueue) ? " · 󰌾 Locked" : "")
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: Qt.darker(Color.foreground, 1.4)
              }
            }

            // Tracks List View
            ListView {
              id: tracksListView
              Layout.fillWidth: true
              Layout.fillHeight: true
              Layout.minimumHeight: Style.space(250)
              clip: true
              model: root.filteredTracks
              spacing: Style.space(3)
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              delegate: BorderSurface {
                required property var modelData
                required property int index
                readonly property bool isCurrent: root.currentTrack && root.currentTrack.path === modelData.path

                // ListView creates delegates only for visible rows, so this
                // fires at most once per visible row; requestCover dedupes.
                Component.onCompleted: root.requestCover(modelData.id, true)

                width: tracksListView.width
                implicitHeight: Style.space(38)
                radius: Style.cornerRadius
                borderSpec: isCurrent || trackArea.containsMouse
                  ? Border.controlSpec(isCurrent ? "focus" : "hover-cursor", root.foreground, Color.accent)
                  : Border.none()
                color: isCurrent
                  ? Style.selectedFillFor(root.foreground, Color.accent)
                  : (trackArea.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent")

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  spacing: Style.space(8)

                  // Track thumbnail (96x96 thumb cached on disk by the backend).
                  // Always shows a placeholder box so rows never look empty;
                  // the Image replaces it once the thumb arrives.
                  Rectangle {
                    id: thumbPlaceholder
                    Layout.preferredWidth: Style.space(24)
                    Layout.preferredHeight: Style.space(24)
                    Layout.alignment: Qt.AlignVCenter
                    radius: Style.cornerRadius
                    color: Style.normalFillFor(root.foreground, Color.accent)

                    Text {
                      anchors.centerIn: parent
                      text: "󰎆"
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      color: Qt.darker(Color.foreground, 1.4)
                    }

                    Image {
                      anchors.fill: parent
                      visible: root.trackThumbs[modelData.id] !== undefined
                               && root.trackThumbs[modelData.id] !== ""
                      source: visible ? ("file://" + root.trackThumbs[modelData.id]) : ""
                      sourceSize: Qt.size(96, 96)
                      fillMode: Image.PreserveAspectCrop
                      clip: true
                      smooth: true
                    }
                  }

                  Text {
                    visible: isCurrent
                    text: root.isPlaying ? "" : "󰏤"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: Color.accent
                  }

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Text {
                      text: modelData.title || modelData.filename
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      font.weight: isCurrent ? Font.Bold : Font.Normal
                      color: isCurrent ? Color.accent : Color.foreground
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                    }
                    Text {
                      text: (modelData.artist || "Unknown") + (modelData.album ? (" · " + modelData.album) : "")
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      color: Qt.darker(Color.foreground, 1.4)
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                    }
                  }

                  Text {
                    text: modelData.duration_str || "0:00"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: Qt.darker(Color.foreground, 1.4)
                  }
                }

                MouseArea {
                  id: trackArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    var source = root.activePlaylistName !== "" ? root.activePlaylistName : "Tracks"
                    var isSearching = root.searchFilter.trim() !== ""
                    var shouldLock = isSearching && root.lockSearchQueue

                    if (shouldLock) {
                      var list = root.filteredTracks
                      var paths = list.map(function(t) { return t.path })
                      var queueSource = "Search: " + root.searchFilter.trim()
                      root.runCtl(["play-queue", queueSource, String(index)].concat(paths))
                    } else {
                      var fullList = root.activeFullTracks
                      var clickedPath = modelData.path
                      var fullIndex = -1
                      for (var i = 0; i < fullList.length; i++) {
                        if (fullList[i].path === clickedPath) {
                          fullIndex = i
                          break
                        }
                      }
                      var paths = fullList.map(function(t) { return t.path })
                      root.runCtl(["play-queue", source, String(fullIndex >= 0 ? fullIndex : 0)].concat(paths))
                    }
                  }
                }
              }
            }
          }

          // ---------------------------------------- TAB 2: PLAYLISTS
          ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Style.space(6)

            ListView {
              id: plListView
              Layout.fillWidth: true
              Layout.fillHeight: true
              Layout.minimumHeight: Style.space(250)
              clip: true
              model: root.playlists
              spacing: Style.space(4)
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              delegate: BorderSurface {
                required property var modelData
                width: plListView.width
                implicitHeight: Style.space(42)
                radius: Style.cornerRadius
                borderSpec: Border.controlSpec(plMouseArea.containsMouse ? "hover-cursor" : "normal", root.foreground, Color.accent)
                color: plMouseArea.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(8)

                  Text {
                    text: ""
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    color: Color.accent
                  }

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Text {
                      text: modelData.name
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      color: Color.foreground
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                    }
                    Text {
                      text: modelData.track_count + " tracks"
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      color: Qt.darker(Color.foreground, 1.4)
                    }
                  }

                  Text {
                    text: "󰁔"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: Qt.darker(Color.foreground, 1.4)
                  }
                }

                MouseArea {
                  id: plMouseArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.activePlaylistName = modelData.name
                    root.activePlaylistTrackPaths = modelData.track_paths || []
                    root.currentScreen = "tracks"
                  }
                }
              }
            }
          }
        }

        PanelSeparator { Layout.fillWidth: true }

        // ========================================== [CONTROLES (FIXED BOTTOM)]
        BorderSurface {
          Layout.fillWidth: true
          implicitHeight: Style.space(72)
          radius: Style.cornerRadius
          borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
          color: Style.normalFillFor(Color.foreground, Color.accent)

          ColumnLayout {
            anchors.fill: parent
            anchors.topMargin: Style.space(8)
            anchors.bottomMargin: Style.space(8)
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            spacing: Style.space(6)

            // Top Row: Track info (left) + Controls (right)
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              // Album cover for the now-playing area. Source is a data URI
              // returned on-demand by `mixarchy-ctl cover`; never polled.
              // Sized to fit inside the 72px control bar (56px usable);
              // placeholder box always visible so the layout never jumps.
              Rectangle {
                id: nowPlayingCoverBox
                Layout.preferredWidth: Style.space(36)
                Layout.preferredHeight: Style.space(36)
                Layout.alignment: Qt.AlignVCenter
                radius: Style.cornerRadius
                color: Style.normalFillFor(root.foreground, Color.accent)

                Text {
                  anchors.centerIn: parent
                  text: "󰎆"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  color: Qt.darker(Color.foreground, 1.4)
                }

                Image {
                  id: nowPlayingCoverImg
                  anchors.fill: parent
                  visible: root.nowPlayingCover !== ""
                  source: root.nowPlayingCover
                  sourceSize: Qt.size(96, 96)
                  fillMode: Image.PreserveAspectCrop
                  clip: true
                  smooth: true

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: "transparent"
                    border.width: 1
                    border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.15)
                  }
                }
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: 1

                Text {
                  text: root.currentTrack ? (root.currentTrack.title || root.currentTrack.filename) : "No playback"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.weight: Font.Bold
                  color: Color.foreground
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                }

                Text {
                  text: root.currentTrack
                    ? root.currentTrack.artist
                    : (root.trackCount + " tracks available")
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: Qt.darker(Color.foreground, 1.4)
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                }
              }

              RowLayout {
                spacing: Style.space(4)

                Button {
                  iconText: "󰒮"
                  bordered: false
                  onClicked: root.prevTrack()
                }

                Button {
                  iconText: root.isPlaying ? "󰏤" : "󰐊"
                  bordered: true
                  active: root.isPlaying
                  onClicked: root.togglePlay()
                }

                Button {
                  iconText: "󰒭"
                  bordered: false
                  onClicked: root.nextTrack()
                }
              }
            }

            // Bottom Row: [Time elapsed] [------- Slider -------] [Total duration]
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              Text {
                text: root.currentTrack
                  ? (progressBar.isDragging ? root.formatSec(progressBar.dragRatio * root.duration) : root.timePosStr)
                  : "0:00"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: Qt.darker(Color.foreground, 1.4)
                Layout.minimumWidth: Style.space(28)
                horizontalAlignment: Text.AlignRight
              }

              Item {
                id: progressBar
                Layout.fillWidth: true
                Layout.preferredHeight: Style.space(12)

                property bool isDragging: false
                property real dragRatio: 0
                readonly property real currentRatio: isDragging
                  ? dragRatio
                  : (root.duration > 0 ? Math.max(0, Math.min(1, root.timePos / root.duration)) : 0)

                // Track background
                Rectangle {
                  id: trackBg
                  anchors.centerIn: parent
                  width: parent.width
                  height: (progressMouse.containsMouse || progressBar.isDragging) ? Style.space(4) : Style.space(2)
                  radius: height / 2
                  color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.18)
                  Behavior on height { NumberAnimation { duration: 100 } }

                  // Filled progress
                  Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: parent.width * progressBar.currentRatio
                    radius: parent.radius
                    color: Color.accent
                  }
                }

                // Scrub Knob
                Rectangle {
                  id: scrubKnob
                  width: Style.space(10)
                  height: Style.space(10)
                  radius: width / 2
                  color: Color.accent
                  border.width: 1.5
                  border.color: Color.foreground
                  x: Math.max(0, Math.min(progressBar.width - width, (progressBar.width * progressBar.currentRatio) - (width / 2)))
                  anchors.verticalCenter: parent.verticalCenter
                  visible: root.duration > 0
                  opacity: (progressMouse.containsMouse || progressBar.isDragging) ? 1.0 : 0.8
                  scale: (progressMouse.containsMouse || progressBar.isDragging) ? 1.1 : 0.85
                  Behavior on opacity { NumberAnimation { duration: 120 } }
                  Behavior on scale { NumberAnimation { duration: 120 } }
                }

                MouseArea {
                  id: progressMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: root.duration > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor

                  function updateRatio(mouse) {
                    if (root.duration <= 0) return
                    var clampedX = Math.max(0, Math.min(width, mouse.x))
                    progressBar.dragRatio = clampedX / width
                  }

                  onPressed: function(mouse) {
                    if (root.duration <= 0) return
                    progressBar.isDragging = true
                    updateRatio(mouse)
                  }

                  onPositionChanged: function(mouse) {
                    if (progressBar.isDragging) {
                      updateRatio(mouse)
                    }
                  }

                  onReleased: function(mouse) {
                    if (progressBar.isDragging) {
                      updateRatio(mouse)
                      var targetSec = Math.round(progressBar.dragRatio * root.duration)
                      root.seekTo(targetSec)
                      root.timePos = targetSec
                      root.timePosStr = root.formatSec(targetSec)
                      // Restart the local playback clock from the seek target.
                      root.lastSyncTimePos = targetSec
                      root.lastSyncWall = Date.now()
                      progressBar.isDragging = false
                    }
                  }
                }
              }

              Text {
                text: root.currentTrack ? root.durationStr : "0:00"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: Qt.darker(Color.foreground, 1.4)
                Layout.minimumWidth: Style.space(28)
              }
            }
          }
        }
      }
    }
  }
}
