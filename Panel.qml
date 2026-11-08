import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Panel {
  id: root
  moduleName: "ariasbruno.mixarchy"
  ipcTarget: "ariasbruno.mixarchy"
  manageIpc: true

  IpcHandler {
    target: "mixarchy"
    function showNowPlaying(): void {
      root.open()
      root.currentScreen = "nowplaying"
      root.syncNowPlayingTab()
    }
    function setSubTab(tab: string): void {
      root.open()
      root.currentScreen = "nowplaying"
      root.nowPlayingSubTab = (tab === "cover" ? "" : tab)
      root.syncNowPlayingTab()
    }
  }

  readonly property string homeDir: Quickshell.env("HOME") || ""
  // Percent-decode the resolved URL (a path with spaces arrives as file:///...%20...);
  // fall back to the raw path on malformed input rather than crashing (fail-safe).
  readonly property string pluginDir: (function() {
    var dir = String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")
    try {
      dir = decodeURIComponent(dir)
    } catch (e) {
      // Malformed percent-encoding: keep the raw path.
    }
    return dir.replace(/\/$/, "")
  })()
  property string ctlPath: pluginDir + "/bin/mixarchy-ctl"
  property bool isBuilding: false
  // True only after bootstrapDone(): a binary verified against the pinned
  // SHA-256 has been assigned to ctlPath. Every automatic process boundary
  // (status/lib/action/cover) refuses to run before this flag is set, so no
  // unverified bytes from bin/ or target/ are ever executed, even during the
  // async bootstrap window.
  property bool bootstrapped: false
  // Explicit developer opt-in: with MIXARCHY_DEV_BUILD=1 the bootstrap may
  // use a locally built target/release binary WITHOUT matching the pinned
  // release digest, but only with a permanent visible warning (devMode).
  // Without this flag the cargo fallback is never started (fail closed).
  readonly property bool devBuildEnabled: Quickshell.env("MIXARCHY_DEV_BUILD") === "1"
  property bool devMode: false
  // User-visible bootstrap error (no silent failures).
  property string bootError: ""

  // ------------------------------------------------------------- Trusted processes
  // Every automatic process boundary clears the inherited environment and
  // reconstructs a fixed minimal allow-list (never inheriting PATH/BASH_ENV/
  // LD_PRELOAD or other session variables), and every executable is resolved
  // from fixed root-owned system locations instead of the inherited PATH.
  // No shell is ever started. This removes the pre-verification execution
  // window the marketplace review flagged: a user-writable or shadowed
  // executable or startup file can no longer run before the downloaded
  // binary's pinned SHA-256 is checked. mixarchy-ctl applies the same
  // resolution (regular-file/owner/mode/directory-chain checks) and the same
  // allow-list to the mpv child it starts (see src/trusted.rs).
  readonly property string trustedPath: "/usr/local/bin:/usr/bin:/bin"
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string cargoBinDir: root.homeDir !== "" ? root.homeDir + "/.cargo/bin" : ""

  // Allow-listed environment handed to every automatic child process.
  readonly property var cleanEnv: ({
    "HOME": root.homeDir,
    "XDG_RUNTIME_DIR": root.runtimeDir,
    "PATH": root.trustedPath,
    "LANG": "C.UTF-8"
  })

  // cargo build fallback additionally needs the user's rustup shim directory
  // (where rustc lives alongside cargo) available to the child.
  readonly property var buildEnv: ({
    "HOME": root.homeDir,
    "XDG_RUNTIME_DIR": root.runtimeDir,
    "PATH": (root.cargoBinDir !== "" ? root.cargoBinDir + ":" : "") + root.trustedPath,
    "LANG": "C.UTF-8"
  })

  // Fixed trusted candidate locations for bootstrap executables, in probe
  // order. Probing only ever uses /usr/bin/test -x (absolute, cleared env);
  // a candidate is never looked up through the inherited PATH.
  readonly property var toolCandidates: {
    "stat": ["/usr/bin/stat", "/bin/stat"],
    "test": ["/usr/bin/test", "/bin/test"],
    "mkdir": ["/usr/bin/mkdir", "/bin/mkdir"],
    "curl": ["/usr/bin/curl", "/bin/curl"],
    "sha256sum": ["/usr/bin/sha256sum", "/bin/sha256sum"],
    "chmod": ["/usr/bin/chmod", "/bin/chmod"],
    "mv": ["/usr/bin/mv", "/bin/mv"],
    "rm": ["/usr/bin/rm", "/bin/rm"],
    "mktemp": ["/usr/bin/mktemp", "/bin/mktemp"]
  }
  property var resolvedTools: ({})
  property var pendingTool: null

  readonly property color foreground: bar ? bar.barForeground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // State
  property string currentScreen: "tracks" // "tracks" | "playlists" | "nowplaying"
  property string nowPlayingSubTab: "" // "" (default: cover) | "lyrics" | "queue"

  // Lyrics state
  property var currentLyrics: null
  property string lastLyricsTrackId: ""
  property bool lyricsLoading: false

  // Playback queue state
  property var playbackQueue: []
  property bool queueLoading: false

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

  // ------------------------------------------------------------- Tool resolution
  // Resolve all bootstrap executables from fixed root-owned system locations
  // before any process that needs them is started. Each candidate must pass:
  //   1. /usr/bin/test -x        → exists and is executable;
  //   2. /usr/bin/stat (uid, mode) → owned by uid 0 and not writable by group
  //      or other (`mode & 0o22 == 0`);
  //   3. /usr/bin/stat on the parent directory → same uid 0 / non-writable
  //      rule on the directory chain.
  // The probe binaries themselves (/usr/bin/test, /usr/bin/stat) are fixed
  // absolute paths invoked with a cleared environment — they are never looked
  // up through the inherited PATH. cargo is handled separately because it
  // lives under the user's home; both /usr/bin/cargo and the rustup shim
  // directory are tested (the home candidate is only ever reached as a
  // user-initiated build fallback, never for the verified download path).
  function tool(name) {
    return root.resolvedTools[name] || ""
  }

  function candidatesFor(name) {
    if (name === "cargo") {
      var list = ["/usr/bin/cargo"]
      if (root.cargoBinDir !== "") list.push(root.cargoBinDir + "/cargo")
      list.push("/usr/local/bin/cargo")
      return list
    }
    return root.toolCandidates[name] || []
  }

  function probeTool(name, onResolved) {
    var cands = root.candidatesFor(name)
    if (cands.length === 0) {
      console.warn("Mixarchy: no trusted candidate locations for '" + name + "'")
      if (onResolved) onResolved()
      return
    }
    root.pendingTool = { name: name, index: 0, candidates: cands, phase: "xtest", onResolved: onResolved || null }
    toolProbeProc.command = ["/usr/bin/test", "-x", cands[0]]
    toolProbeProc.running = true
  }

  // Advance the probe to the next candidate for the pending tool.
  function probeNext() {
    var pending = root.pendingTool
    if (!pending) return
    pending.index++
    if (pending.index < pending.candidates.length) {
      pending.phase = "xtest"
      toolProbeProc.command = ["/usr/bin/test", "-x", pending.candidates[pending.index]]
      toolProbeProc.running = true
    } else {
      var cb = pending.onResolved
      root.pendingTool = null
      console.warn("Mixarchy: '" + pending.name + "' not found in trusted system locations")
      if (cb) cb()
    }
  }

  // Accept the current candidate for the pending tool.
  function probeAccept() {
    var pending = root.pendingTool
    if (!pending) return
    root.resolvedTools[pending.name] = pending.candidates[pending.index]
    var cb = pending.onResolved
    root.pendingTool = null
    if (cb) cb()
  }

  // "uid mode" (e.g. "0 755") → true when root-owned and no group/other write.
  function statLineOk(line) {
    var parts = String(line || "").trim().split(/\s+/)
    if (parts.length < 2) return false
    var uid = parseInt(parts[0], 10)
    var mode = parseInt(parts[1], 8)
    return uid === 0 && (mode & 0o22) === 0
  }

  Process {
    id: toolProbeProc
    clearEnvironment: true
    environment: root.cleanEnv
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.probeStatOut = text
    }
    onExited: function(exitCode, exitStatus) {
      var pending = root.pendingTool
      if (!pending) return
      var path = pending.candidates[pending.index]

      if (pending.phase === "xtest") {
        if (exitCode !== 0) {
          root.probeNext()
          return
        }
        if (pending.name === "stat") {
          // stat is the validator itself; its fixed absolute path is accepted
          // on the existence test alone.
          root.probeAccept()
          return
        }
        pending.phase = "statfile"
        toolProbeProc.command = ["/usr/bin/stat", "-c", "%u %a", path]
        toolProbeProc.running = true
        return
      }

      if (pending.phase === "statfile") {
        if (exitCode !== 0 || !root.statLineOk(root.probeStatOut)) {
          root.probeNext()
          return
        }
        pending.phase = "statdir"
        var parent = path.substring(0, path.lastIndexOf("/"))
        toolProbeProc.command = ["/usr/bin/stat", "-c", "%u %a", parent]
        toolProbeProc.running = true
        return
      }

      // statdir — ownership of the DIRECT PARENT only. This QML probe checks
      // the tool file and its immediate parent; it deliberately does not walk
      // the full chain (install.sh's trusted helpers validate every directory
      // on the path). The parent check still defeats the common attack: a
      // binary dropped into a user-writable directory.
      if (exitCode !== 0 || !root.statLineOk(root.probeStatOut)) {
        root.probeNext()
        return
      }
      root.probeAccept()
    }
  }

  property string probeStatOut: ""

  // Resolve a list of tool names in sequence before starting any work.
  function bootstrapTools(names, onDone) {
    var i = 0
    var next = function() {
      if (i >= names.length) {
        if (onDone) onDone()
        return
      }
      var name = names[i++]
      root.probeTool(name, next)
    }
    next()
  }

  // ------------------------------------------------------------- Process handlers
  Process {
    id: statusProc
    clearEnvironment: true
    environment: root.cleanEnv
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
            var curId = (root.currentTrack && root.currentTrack.id) ? root.currentTrack.id : ""
            var newId = (res.track && res.track.id) ? res.track.id : ""
            if (curId !== newId || (!root.currentTrack && res.track) || (root.currentTrack && !res.track)) {
              root.currentTrack = res.track
            }
            root.sourceName = res.source_name || "Tracks"
            root.queueIndex = (res.queue_index !== undefined && res.queue_index > 0) ? (res.queue_index - 1) : 0
            root.queueTotal = res.queue_total || 0
            root.timePos = res.time_pos || 0
            root.duration = res.duration || 0
            root.timePosStr = res.time_pos_str || "0:00"
            root.durationStr = res.duration_str || "0:00"
            root.lastSyncTimePos = root.timePos
            root.lastSyncWall = Date.now()
          }
        } catch (e) { console.warn("Mixarchy: status parse: " + e) }
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) {
        root.bootError = "Mixarchy: backend status process failed unexpectedly."
      } else if (root.bootError.indexOf("Mixarchy: backend") === 0) {
        root.bootError = ""
      }
    }
  }

  Process {
    id: libProc
    // True once onExited ran for the CURRENT run (cleared at run start).
    // Quickshell's Process does NOT emit exited for QProcess::FailedToStart
    // (upstream src/io/process.cpp: errorOccurred only warns + emits
    // runningChanged), so ending with running==false and this flag clear
    // means the backend never started.
    property bool sawExited: false
    clearEnvironment: true
    environment: root.cleanEnv
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
        } catch (e) { console.warn("Mixarchy: library parse: " + e) }
      }
    }
    onExited: function(exitCode, exitStatus) {
      libProc.sawExited = true
      if (exitStatus !== 0) {
        // Crashed/killed. onStreamFinished already ran before this handler
        // (upstream onFinished calls streamEnded first), so the list shows
        // the data the backend produced before dying — log, don't clobber.
        console.warn("Mixarchy: library process ended abnormally (exitStatus " + exitStatus + ", code " + exitCode + ")")
      }
      if (exitCode !== 0) {
        root.bootError = "Mixarchy: backend library process failed unexpectedly."
      } else if (root.bootError.indexOf("Mixarchy: backend") === 0) {
        root.bootError = ""
      }
    }
    onRunningChanged: {
      if (libProc.running) {
        // A new run started: the previous run's onExited set sawExited, which
        // must not leak into the new run's end decision.
        libProc.sawExited = false
      } else if (!libProc.sawExited) {
        // FailedToStart: onExited/onStreamFinished never fire, so
        // libraryLoading stays stuck true and the list keeps stale tracks
        // with no error surfaced. Unstick the UI.
        console.warn("Mixarchy: library process failed to start")
        root.libraryLoading = false
        root.bootError = "Mixarchy: backend library process failed unexpectedly."
      }
    }
  }

  Process {
    id: actionProc
    property var nextAction: null
    // Same sawExited invariant as libProc: tracks whether onExited ran for
    // the current run so a FailedToStart (no exited, no streamEnded) can be
    // distinguished from a clean/crashed end.
    property bool sawExited: false
    clearEnvironment: true
    environment: root.cleanEnv
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
    onExited: function(exitCode, exitStatus) {
      actionProc.sawExited = true
      if (exitStatus !== 0) {
        // Crashed/killed, rather than a clean exit. onStreamFinished already
        // ran first (upstream streamEnded-before-exited order), refreshing
        // status and dispatching nextAction — log for diagnosis, don't
        // double-dispatch.
        console.warn("Mixarchy: action process ended abnormally (exitStatus " + exitStatus + ", code " + exitCode + ")")
      }
      if (exitCode !== 0) {
        root.bootError = "Mixarchy: backend action process failed unexpectedly."
      } else if (root.bootError.indexOf("Mixarchy: backend") === 0) {
        root.bootError = ""
      }
    }
    onRunningChanged: {
      if (actionProc.running) {
        // A new run started: the previous run's onExited set sawExited, which
        // must not leak into the new run's end decision.
        actionProc.sawExited = false
      } else if (!actionProc.sawExited) {
        // FailedToStart: onExited/onStreamFinished never fire, so the action
        // never ran and its continuation must not run either (a queued
        // rescan's refreshLibrary callback, for example).
        console.warn("Mixarchy: action process failed to start; dropping pending continuation")
        actionProc.nextAction = null
        root.bootError = "Mixarchy: backend action process failed unexpectedly."
      }
    }
  }

  // On-demand cover fetch. NOT part of the status poll; driven separately so
  // the 5s poll never carries cover payloads. Requests are serialized: one
  // in-flight process plus an explicit queue drained on finish, so a burst of
  // visible rows (ListView instantiates ~20 delegates) never drops requests or
  // misattributes a result to the wrong track id.
  // Release every cover request a backend run left stuck: the pending one and
  // the whole queued batch. Runs when the current cover run ended WITHOUT
  // onStreamFinished (Quickshell's FailedToStart path — verified upstream:
  // errorOccurred emits only runningChanged, never exited/streamEnded), so
  // coverRequested dedup and the serial queue recover on the next
  // scroll/current-track change instead of blocking retries forever.
  function clearCoverState() {
    var pendId = coverProc.pendingId
    coverProc.pendingId = ""
    coverProc.pendingThumbOnly = false
    if (pendId !== "") root.coverRequested[pendId] = false
    while (root.coverQueue.length > 0) {
      var queued = root.coverQueue.shift()
      root.coverRequested[queued.id] = false
    }
  }

  Process {
    id: coverProc
    property var pendingId: ""
    property bool pendingThumbOnly: false
    // True once onExited ran for the CURRENT run. Cleared when a run starts
    // (requestCover, queue advance, and onStarted via runningChanged(true)).
    // Quickshell's Process does NOT emit exited for QProcess::FailedToStart
    // (upstream src/io/process.cpp: errorOccurred only warns + emits
    // runningChanged), so a run ending with running==false and this flag
    // clear means the backend never started.
    property bool sawExited: false
    clearEnvironment: true
    environment: root.cleanEnv
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
        } catch (e) { console.warn("Mixarchy: cover parse: " + e) } // malformed response: leave trackThumbs unset -> retried on next scroll
        if (root.coverQueue.length > 0) {
          var next = root.coverQueue.shift()
          coverProc.pendingId = next.id
          coverProc.pendingThumbOnly = next.thumbOnly
          coverProc.command = next.thumbOnly
            ? [root.ctlPath, "cover", "--thumb", next.id]
            : [root.ctlPath, "cover", next.id]
          coverProc.sawExited = false
          coverProc.running = true
        }
      }
    }
    onExited: function(exitCode, exitStatus) {
      coverProc.sawExited = true
      if (exitStatus !== 0) {
        // Crashed/killed. onStreamFinished already ran before this handler
        // (upstream onFinished calls streamEnded first), so the per-request
        // state is cleared and the queue has advanced — touching it here
        // would corrupt the next in-flight request. Log instead, so a broken
        // backend is diagnosable rather than a silent "no art" UI.
        console.warn("Mixarchy: cover process ended abnormally (exitStatus " + exitStatus + ", code " + exitCode + ")")
      }
      if (exitCode !== 0) {
        root.bootError = "Mixarchy: backend cover process failed unexpectedly."
      } else if (root.bootError.indexOf("Mixarchy: backend") === 0) {
        root.bootError = ""
      }
    }
    onRunningChanged: {
      if (coverProc.running) {
        // A new run started: the previous run's onExited set sawExited, which
        // must not leak into the new run's end decision.
        coverProc.sawExited = false
      } else if (!coverProc.sawExited) {
        // FailedToStart: onExited/onStreamFinished never fire, so the pending
        // request and everything queued stays stuck (dedup blocks retries and
        // the queue only drains inside onStreamFinished). Release it all.
        console.warn("Mixarchy: cover process failed to start; clearing stale cover state")
        root.clearCoverState()
        root.bootError = "Mixarchy: backend cover process failed unexpectedly."
      }
    }
  }

  Process {
    id: lyricsProc
    property string pendingId: ""
    property bool sawExited: false
    clearEnvironment: true
    environment: root.cleanEnv
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.lyricsLoading = false
        try {
          var res = JSON.parse(text)
          if (res.ok) {
            root.currentLyrics = res
          } else {
            root.currentLyrics = null
          }
        } catch (e) {
          root.currentLyrics = null
        }
      }
    }
    onExited: function(exitCode, exitStatus) {
      lyricsProc.sawExited = true
    }
    onRunningChanged: {
      if (lyricsProc.running) {
        lyricsProc.sawExited = false
      } else if (!lyricsProc.sawExited) {
        root.lyricsLoading = false
      }
    }
  }

  Process {
    id: queueProc
    property bool sawExited: false
    clearEnvironment: true
    environment: root.cleanEnv
    command: [root.ctlPath, "queue"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.queueLoading = false
        try {
          var res = JSON.parse(text)
          if (res.ok && res.tracks) {
            root.playbackQueue = res.tracks
            root.queueIndex = res.queue_index
          }
        } catch (e) { }
      }
    }
    onExited: function(exitCode, exitStatus) {
      queueProc.sawExited = true
    }
    onRunningChanged: {
      if (queueProc.running) {
        queueProc.sawExited = false
      } else if (!queueProc.sawExited) {
        root.queueLoading = false
      }
    }
  }

  // ------------------------------------------------------------- Bootstrap
  // Single dispatcher process drives the whole bootstrap state machine.
  // Every automatic boundary clears the inherited environment and uses only
  // executables resolved from fixed root-owned system locations (never the
  // inherited PATH), and never starts a shell. The bash-based verify step
  // is replaced by an explicit mktemp → curl → sha256sum → chmod → mv chain;
  // each step is its own process with argv only (no string interpolation).
  // Every binary that may execute (release download, pre-existing local
  // build) must match the pinned digest before assignment; freshly built
  // cargo output is accepted only in opted-in developer mode, because a
  // local build can never match the stripped CI release pin.
  readonly property string releaseTag: "v1.2.0"
  readonly property string expectedSha256: "f3cf6b1c8b6039ecfe8f74b6ac1625e6fad488d2155206ac3d350b03a9e8bf9b"

  // Unpredictable temp path created exclusively by the trusted mktemp
  // process inside bin/ before any download writes to it. Never use a fixed
  // name: a pre-existing symlink there would let curl overwrite an arbitrary
  // user-writable file before verification.
  property string tmpBinary: ""
  property string bootstrapStep: ""
  property string bootstrapHashOut: ""
  // Set by the bootstrap watchdog when it aborts a hung bootstrap; every
  // onExited continuation of the aborted processes checks it and stands down
  // instead of re-entering the state machine.
  property bool bootstrapAborted: false

  function runBootstrap(step, args) {
    bootstrapWatchdog.restart()
    bootstrapProc.step = step
    bootstrapProc.command = args
    bootstrapProc.running = true
  }

  function bootstrapDone() {
    bootstrapWatchdog.stop()
    root.isBuilding = false
    // Only a digest-verified binary (or an explicitly opted-in dev build)
    // may be executed; this flag is the single unlock for every automatic
    // Process boundary.
    root.bootstrapped = true
    root.refreshStatus()
    root.refreshLibrary()
  }

  function downloadError() {
    bootstrapWatchdog.stop()
    root.isBuilding = false
    // Without the explicit dev flag the cargo fallback is never started:
    // a local build can never match the release pin, so attempting it would
    // end in a silently dead widget. Fail closed with a visible error.
    if (!root.devBuildEnabled) {
      root.bootError = "Mixarchy: verified binary download failed and local builds are disabled. Set MIXARCHY_DEV_BUILD=1 to allow an unverified local build (developer mode)."
      console.warn("Mixarchy: download/verify failed — dev builds disabled, refusing cargo fallback")
      return
    }
    console.warn("Mixarchy: download/verify failed — dev build fallback (MIXARCHY_DEV_BUILD=1)")
    var cands = root.candidatesFor("cargo")
    root.cargoCandidates = cands
    root.cargoProbeIndex = 0
    if (cands.length > 0) {
      root.runBootstrap("check-cargo", [root.tool("test"), "-x", cands[0]])
    } else {
      root.bootError = "Mixarchy: no trusted cargo binary found; cannot build locally."
      console.warn("Mixarchy: no trusted cargo binary found; cannot build locally")
    }
  }

  Process {
    id: bootstrapProc
    property string step: ""
    clearEnvironment: true
    environment: root.cleanEnv
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.bootstrapHashOut = text
    }
    onExited: function(exitCode, exitStatus) {
      if (root.bootstrapAborted) return
      var step = bootstrapProc.step

      if (step === "check-bin") {
        var actual = (root.bootstrapHashOut || "").trim().split(" ")[0]
        if (exitCode === 0 && actual === root.expectedSha256) {
          root.bootstrapDone()
          return
        }
        root.runBootstrap("check-target-hash", [root.tool("sha256sum"), "-b",
          root.pluginDir + "/target/release/mixarchy-ctl"])
      }
      else if (step === "check-target-hash") {
        var targetHash = (root.bootstrapHashOut || "").trim().split(" ")[0]
        if (exitCode === 0 && targetHash === root.expectedSha256) {
          root.ctlPath = root.pluginDir + "/target/release/mixarchy-ctl"
          root.bootstrapDone()
          return
        }
        if (exitCode === 0 && root.devBuildEnabled) {
          // Developer mode opt-in: accept the local build without the release
          // pin, but only with a permanent visible warning (devMode).
          root.devMode = true
          root.ctlPath = root.pluginDir + "/target/release/mixarchy-ctl"
          root.bootstrapDone()
          return
        }
        // Stale, replaced, or unpinned local build: remove it and re-acquire
        // the verified release (fail closed on mismatch).
        root.runBootstrap("rm-target", [root.tool("rm"), "-f",
          root.pluginDir + "/target/release/mixarchy-ctl"])
      }
      else if (step === "rm-target") {
        root.runBootstrap("rm-bin", [root.tool("rm"), "-f", root.ctlPath])
      }
      else if (step === "rm-bin") {
        root.runBootstrap("mkdir", [root.tool("mkdir"), "-p", root.pluginDir + "/bin"])
      }
      else if (step === "mkdir") {
        if (exitCode === 0) {
          // Exclusive unpredictable temp path inside bin/: mktemp creates it
          // with O_EXCL, so a pre-existing symlink at that name is impossible.
          root.runBootstrap("mktemp", [root.tool("mktemp"),
            root.pluginDir + "/bin/mixarchy-ctl.XXXXXX"])
        } else {
          root.downloadError()
        }
      }
      else if (step === "mktemp") {
        var tmpPath = (root.bootstrapHashOut || "").trim()
        if (exitCode === 0 && tmpPath !== "") {
          root.tmpBinary = tmpPath
          root.runBootstrap("download", [
            root.tool("curl"), "-fsSL",
            "--connect-timeout", "10",
            "--max-time", "120",
            "--max-filesize", "10485760",
            "https://github.com/ariasbruno/mixarchy/releases/download/" + root.releaseTag + "/mixarchy-ctl",
            "-o", root.tmpBinary
          ])
        } else {
          // mktemp failed: do not fall into a predictable-path download
          root.downloadError()
        }
      }
      else if (step === "download") {
        if (exitCode === 0) {
          root.runBootstrap("hash", [root.tool("sha256sum"), "-b", root.tmpBinary])
        } else {
          root.downloadError()
        }
      }
      else if (step === "hash") {
        // sha256sum -b prints "<hash> *<file>\n"; split on space → hash.
        var actual = root.bootstrapHashOut.trim().split(" ")[0]
        if (actual === root.expectedSha256) {
          root.runBootstrap("chmod", [root.tool("chmod"), "755", root.tmpBinary])
        } else {
          console.warn("Mixarchy: checksum mismatch; deleting unverified binary")
          root.runBootstrap("rm-tmp", [root.tool("rm"), "-f", root.tmpBinary])
        }
      }
      else if (step === "chmod") {
        if (exitCode === 0) {
          root.runBootstrap("mv", [root.tool("mv"), "-f", root.tmpBinary,
            root.pluginDir + "/bin/mixarchy-ctl"])
        } else {
          root.runBootstrap("rm-tmp", [root.tool("rm"), "-f", root.tmpBinary])
        }
      }
      else if (step === "mv") {
        if (exitCode === 0) {
          root.ctlPath = root.pluginDir + "/bin/mixarchy-ctl"
          root.bootstrapDone()
        } else {
          root.runBootstrap("rm-tmp", [root.tool("rm"), "-f", root.tmpBinary])
        }
      }
      else if (step === "rm-tmp") {
        root.downloadError()
      }
      else if (step === "check-cargo") {
        if (exitCode === 0) {
          root.resolvedCargo = root.cargoCandidates[root.cargoProbeIndex]
          root.buildProc.environment = root.buildEnv
          root.buildProc.command = [root.resolvedCargo, "build", "--release",
            "--locked", "--manifest-path", root.pluginDir + "/Cargo.toml"]
          root.isBuilding = true
          // check-cargo is a fast `test -x` probe, so the watchdog window
          // restarted by runBootstrap mostly expires BEFORE the real build
          // finishes: a cold `cargo build --release --locked` can legitimately
          // take > 3 minutes and would be aborted as a false timeout. Give
          // buildProc its own fresh watchdog window here (and stand it down
          // in buildProc.onExited, so the bootstrap never needs to extend it
          // again — no double restart).
          root.bootstrapWatchdog.restart()
          root.buildProc.running = true
        } else {
          root.cargoProbeIndex++
          if (root.cargoProbeIndex < root.cargoCandidates.length) {
            root.runBootstrap("check-cargo", [root.tool("test"), "-x",
              root.cargoCandidates[root.cargoProbeIndex]])
          } else {
            root.isBuilding = false
            root.bootError = "Mixarchy: no trusted cargo binary found; cannot build locally."
            console.warn("Mixarchy: no trusted cargo binary found")
            // The bootstrap has concluded with an error; stop the watchdog
            // so its timer cannot later replace this message with a bogus
            // "bootstrap timed out" banner.
            root.bootstrapWatchdog.stop()
          }
        }
      }
    }
  }

  property int cargoProbeIndex: 0
  property var cargoCandidates: []
  property string resolvedCargo: ""

  Process {
    id: buildProc
    clearEnvironment: true
    environment: root.buildEnv
    command: []
    onExited: function(exitCode, exitStatus) {
      if (root.bootstrapAborted) return
      root.isBuilding = false
      if (exitCode === 0) {
        if (root.devBuildEnabled) {
          // Developer mode opt-in: a local cargo build can never match the
          // release pin (CI strip + toolchain), so skip the digest gate and
          // accept it with a permanent visible warning instead.
          root.devMode = true
          root.ctlPath = root.pluginDir + "/target/release/mixarchy-ctl"
          root.bootstrapDone()
        } else {
          // Fail closed: a locally built binary can never match the CI
          // release pin (different strip flags and toolchain), so the old
          // hash-built step was dead code that always ended in a SILENT
          // disabled widget. Refuse to execute and say so instead.
          console.warn("Mixarchy: refusing to execute unverified local build (set MIXARCHY_DEV_BUILD=1 to opt in)")
          root.bootError = "Mixarchy: local cargo build output is not digest-verified; plugin disabled. Set MIXARCHY_DEV_BUILD=1 to allow an unverified local build (developer mode)."
          // The build drove the watchdog directly (restarted in check-cargo);
          // stand it down now that the bootstrap has concluded, or its timer
          // would later overwrite this error with a misleading "bootstrap
          // timed out" banner.
          root.bootstrapWatchdog.stop()
        }
      } else {
        console.warn("Mixarchy: cargo build failed")
        root.bootError = "Mixarchy: local cargo build failed; plugin disabled until a verified binary is available."
        // The build drove the watchdog directly (restarted in check-cargo);
        // stand it down now that the bootstrap has concluded, or its timer
        // would later overwrite this error with a misleading "bootstrap
        // timed out" banner. On the success paths bootstrapDone() already
        // stopped it (or runBootstrap keeps the hash step gated).
        root.bootstrapWatchdog.stop()
      }
    }
  }

  function runCtl(args, onDone) {
    // Never execute before the pinned binary is verified.
    if (!root.bootstrapped) return
    if (actionProc.running) return
    var cmd = [root.ctlPath].concat(args)
    actionProc.nextAction = onDone || null
    actionProc.command = cmd
    actionProc.sawExited = false
    actionProc.running = true
  }

  function refreshStatus() {
    // Never spawn the backend before the pinned binary is verified.
    if (!root.bootstrapped) return
    if (!statusProc.running) statusProc.running = true
  }

  function refreshLibrary() {
    // Never spawn the backend before the pinned binary is verified.
    if (!root.bootstrapped) return
    root.libraryLoading = true
    if (!libProc.running) {
      libProc.sawExited = false
      libProc.running = true
    }
  }

  // Request the cover for a single track id, deduplicated. Called on-demand
  // for the now-playing area and for visible track-list rows only, so a large
  // library never triggers a flood of cover fetches. Rows pass thumbOnly=true
  // to transport only the cached thumb path; only the current track asks for
  // the full-res data URI.
  function requestCover(id, thumbOnly) {
    if (!id) return
    // Never spawn the backend before the pinned binary is verified.
    if (!root.bootstrapped) return
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
    coverProc.sawExited = false
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

  function fetchLyrics(id) {
    if (!id || !root.bootstrapped) return
    if (root.lastLyricsTrackId === id && root.currentLyrics) return
    root.lastLyricsTrackId = id
    root.lyricsLoading = true
    lyricsProc.pendingId = id
    lyricsProc.command = [root.ctlPath, "lyrics", id]
    lyricsProc.sawExited = false
    lyricsProc.running = true
  }

  function fetchQueue() {
    if (!root.bootstrapped) return
    if (!root.playbackQueue || root.playbackQueue.length === 0) {
      root.queueLoading = true
    }
    queueProc.command = [root.ctlPath, "queue"]
    queueProc.sawExited = false
    queueProc.running = true
  }

  function syncNowPlayingTab() {
    if (root.currentScreen !== "nowplaying") return
    if (root.nowPlayingSubTab === "lyrics") {
      if (root.currentTrack && root.currentTrack.id) {
        root.fetchLyrics(root.currentTrack.id)
      }
    } else if (root.nowPlayingSubTab === "queue") {
      root.fetchQueue()
    }
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

  // Aborts a bootstrap that hangs: no single step may leave the widget stuck
  // unverified indefinitely. Restarted on every runBootstrap step, stopped on
  // success (bootstrapDone) and on downloadError. Only covers the bootstrap
  // flow, never runCtl/refresh.
  Timer {
    id: bootstrapWatchdog
    interval: 180000
    repeat: false
    running: false
    onTriggered: {
      if (!root.bootstrapped) {
        root.bootstrapAborted = true
        root.isBuilding = false
        if (bootstrapProc.running) bootstrapProc.running = false
        if (buildProc.running) buildProc.running = false
        root.bootError = "Mixarchy: bootstrap timed out after 180s."
      }
    }
  }

  Component.onCompleted: {
    // Resolve all bootstrap executables from fixed trusted locations first,
    // then walk the bootstrap state machine. Nothing touches ctlPath until a
    // verified binary is assigned: bootstrapDone() sets root.bootstrapped and
    // is the only entry point that starts status/library refresh.
    root.bootstrapTools(["stat", "test", "mkdir", "mktemp", "curl", "sha256sum", "chmod", "mv", "rm"], function() {
      root.runBootstrap("check-bin", [root.tool("sha256sum"), "-b", root.ctlPath])
    })
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
      root.currentLyrics = null
      root.lastLyricsTrackId = ""
      if (newId !== "") {
        root.requestCover(newId, false)
        if (root.currentScreen === "nowplaying" && root.nowPlayingSubTab === "lyrics") {
          root.fetchLyrics(newId)
        }
        if (root.currentScreen === "nowplaying" && root.nowPlayingSubTab === "queue") {
          root.fetchQueue()
        }
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

        // ========================================== [STATUS BANNER]
        // Visible while the backend is being downloaded/built, when the plugin
        // runs with an unverified local binary (developer mode), or on a
        // bootstrap/backend failure; never silent.
        Rectangle {
          id: statusBanner
          Layout.fillWidth: true
          Layout.preferredHeight: statusBannerText.implicitHeight + Style.space(8)
          visible: root.devMode || root.bootError !== "" || root.isBuilding
          radius: Style.cornerRadius
          color: root.bootError !== ""
            ? Qt.rgba(Commons.Color.urgent.r, Commons.Color.urgent.g, Commons.Color.urgent.b, 0.18)
            : Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.10)

          Text {
            id: statusBannerText
            anchors.fill: parent
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            anchors.topMargin: Style.space(4)
            anchors.bottomMargin: Style.space(4)
            verticalAlignment: Text.AlignVCenter
            wrapMode: Text.WordWrap
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: root.bootError !== "" ? Commons.Color.urgent : Commons.Color.foreground
            text: root.bootError !== ""
              ? root.bootError
              : (root.isBuilding
                ? "Mixarchy: downloading / building backend, please wait..."
                : "Mixarchy: developer mode — using local build without the pinned release digest.")
          }
        }

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

          Button {
            visible: root.currentTrack !== null
            iconText: "󰝚"
            tooltipText: "Now Playing"
            bordered: true
            selected: root.currentScreen === "nowplaying"
            onClicked: {
              root.currentScreen = "nowplaying"
              root.syncNowPlayingTab()
            }
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
          currentIndex: root.currentScreen === "tracks" ? 0 : (root.currentScreen === "playlists" ? 1 : 2)

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
                color: Qt.darker(Commons.Color.foreground, 1.4)
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
                  ? Border.controlSpec(isCurrent ? "focus" : "hover-cursor", root.foreground, Commons.Color.accent)
                  : Border.none()
                color: isCurrent
                  ? Style.selectedFillFor(root.foreground, Commons.Color.accent)
                  : (trackArea.containsMouse ? Style.hoverFillFor(root.foreground, Commons.Color.accent) : "transparent")

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
                    color: Style.normalFillFor(root.foreground, Commons.Color.accent)

                    Text {
                      anchors.centerIn: parent
                      text: "󰎆"
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      color: Qt.darker(Commons.Color.foreground, 1.4)
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
                    color: Commons.Color.accent
                  }

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Text {
                      text: modelData.title || modelData.filename
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      font.weight: isCurrent ? Font.Bold : Font.Normal
                      color: isCurrent ? Commons.Color.accent : Commons.Color.foreground
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                    }
                    Text {
                      text: (modelData.artist || "Unknown") + (modelData.album ? (" · " + modelData.album) : "")
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      color: Qt.darker(Commons.Color.foreground, 1.4)
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                    }
                  }

                  Text {
                    text: modelData.duration_str || "0:00"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: Qt.darker(Commons.Color.foreground, 1.4)
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
                borderSpec: Border.controlSpec(plMouseArea.containsMouse ? "hover-cursor" : "normal", root.foreground, Commons.Color.accent)
                color: plMouseArea.containsMouse ? Style.hoverFillFor(root.foreground, Commons.Color.accent) : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(8)

                  Text {
                    text: ""
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    color: Commons.Color.accent
                  }

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Text {
                      text: modelData.name
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      color: Commons.Color.foreground
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                    }
                    Text {
                      text: modelData.track_count + " tracks"
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      color: Qt.darker(Commons.Color.foreground, 1.4)
                    }
                  }

                  Text {
                    text: "󰁔"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: Qt.darker(Commons.Color.foreground, 1.4)
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

          // ---------------------------------------- TAB 3: NOW PLAYING EXPANDED
          ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Style.space(6)

            // Sub-navigation bar inside Now Playing
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(4)

              Button {
                iconText: "󰁍"
                tooltipText: "Back to Library"
                bordered: true
                onClicked: root.currentScreen = "tracks"
              }

              Item { Layout.fillWidth: true }

              Button {
                iconText: "󰨖"
                text: "Lyrics"
                bordered: true
                selected: root.nowPlayingSubTab === "lyrics"
                onClicked: {
                  root.nowPlayingSubTab = root.nowPlayingSubTab === "lyrics" ? "" : "lyrics"
                  root.syncNowPlayingTab()
                }
              }

              Button {
                iconText: ""
                text: "Queue"
                bordered: true
                selected: root.nowPlayingSubTab === "queue"
                onClicked: {
                  root.nowPlayingSubTab = root.nowPlayingSubTab === "queue" ? "" : "queue"
                  root.syncNowPlayingTab()
                }
              }
            }

            PanelSeparator { Layout.fillWidth: true }

            // Sub-tab content
            StackLayout {
              Layout.fillWidth: true
              Layout.fillHeight: true
              currentIndex: root.nowPlayingSubTab === "lyrics" ? 1 : (root.nowPlayingSubTab === "queue" ? 2 : 0)

              // 1. Big Cover Art
              ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Style.space(10)

                Item { Layout.fillHeight: true }

                Rectangle {
                  Layout.alignment: Qt.AlignHCenter
                  Layout.preferredWidth: Math.min(panel.width - Style.space(32), Style.space(290))
                  Layout.preferredHeight: Layout.preferredWidth
                  radius: Style.cornerRadius
                  color: Style.normalFillFor(root.foreground, Commons.Color.accent)
                  clip: true

                  Text {
                    anchors.centerIn: parent
                    visible: !bigCoverImg.visible
                    text: "󰎆"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.display
                    color: Qt.darker(Commons.Color.foreground, 1.4)
                  }

                  Image {
                    id: bigCoverImg
                    anchors.fill: parent
                    visible: root.nowPlayingCover !== ""
                    source: root.nowPlayingCover
                    fillMode: Image.PreserveAspectCrop
                    smooth: true
                  }

                  Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    color: "transparent"
                    border.width: 1
                    border.color: Qt.rgba(Commons.Color.foreground.r, Commons.Color.foreground.g, Commons.Color.foreground.b, 0.2)
                  }
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  Layout.leftMargin: Style.space(16)
                  Layout.rightMargin: Style.space(16)
                  spacing: Style.space(2)
                  Layout.alignment: Qt.AlignHCenter

                  Text {
                    text: root.currentTrack ? (root.currentTrack.title || root.currentTrack.filename) : "No playback"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.heading
                    font.weight: Font.Bold
                    color: Commons.Color.foreground
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                  }

                  Text {
                    text: root.currentTrack ? (root.currentTrack.artist + (root.currentTrack.album ? (" · " + root.currentTrack.album) : "")) : ""
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    color: Qt.darker(Commons.Color.foreground, 1.4)
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                  }
                }

                Item { Layout.fillHeight: true }
              }

              // 2. Lyrics View
              Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                Text {
                  anchors.centerIn: parent
                  visible: root.lyricsLoading
                  text: "Loading lyrics..."
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  color: Qt.darker(Commons.Color.foreground, 1.4)
                }

                ColumnLayout {
                  anchors.centerIn: parent
                  visible: !root.lyricsLoading && (!root.currentLyrics || !root.currentLyrics.has_lyrics)
                  spacing: Style.space(8)

                  Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "󰨖"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.display
                    color: Qt.darker(Commons.Color.foreground, 1.4)
                  }
                  Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "No local lyrics found"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    color: Qt.darker(Commons.Color.foreground, 1.4)
                  }
                  Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "Add a .lrc file next to the track or embed lyrics in tags"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: Qt.darker(Commons.Color.foreground, 1.8)
                  }
                }

                ListView {
                  id: lyricsListView
                  anchors.fill: parent
                  visible: !root.lyricsLoading && root.currentLyrics && root.currentLyrics.has_lyrics
                  clip: true
                  spacing: Style.space(8)
                  ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                  model: (root.currentLyrics && root.currentLyrics.lines) ? root.currentLyrics.lines : []

                  NumberAnimation {
                    id: lyricScrollAnim
                    target: lyricsListView
                    property: "contentY"
                    duration: 350
                    easing.type: Easing.OutCubic
                  }

                  function smoothScrollTo(index) {
                    if (index < 0 || lyricsListView.moving || lyricsListView.flicking) return
                    var item = lyricsListView.itemAtIndex(index)
                    if (item) {
                      var targetY = item.y - (lyricsListView.height - item.height) / 2
                      var maxContentY = Math.max(0, lyricsListView.contentHeight - lyricsListView.height)
                      targetY = Math.max(0, Math.min(targetY, maxContentY))
                      if (Math.abs(lyricsListView.contentY - targetY) > 1) {
                        lyricScrollAnim.stop()
                        lyricScrollAnim.from = lyricsListView.contentY
                        lyricScrollAnim.to = targetY
                        lyricScrollAnim.start()
                      }
                    } else {
                      lyricsListView.positionViewAtIndex(index, ListView.Center)
                    }
                  }

                  function scrollToCurrent(smooth) {
                    if (!root.currentLyrics || !root.currentLyrics.synced) return
                    var lines = root.currentLyrics.lines || []
                    var t = root.timePos
                    for (var i = 0; i < lines.length; i++) {
                      var myTime = lines[i].time
                      var nextTime = (i + 1 < lines.length) ? lines[i + 1].time : 999999
                      if (t >= myTime && t < nextTime) {
                        if (smooth) {
                          smoothScrollTo(i)
                        } else {
                          lyricsListView.positionViewAtIndex(i, ListView.Center)
                        }
                        break
                      }
                    }
                  }

                  onModelChanged: Qt.callLater(function() { scrollToCurrent(false) })

                  delegate: Item {
                    width: lyricsListView.width
                    implicitHeight: lyricLineText.implicitHeight + Style.space(8)

                    readonly property bool isCurrentLine: {
                      if (!root.currentLyrics || !root.currentLyrics.synced) return false
                      var lines = root.currentLyrics.lines || []
                      var myTime = modelData.time
                      if (myTime < 0) return false
                      var nextTime = (index + 1 < lines.length) ? lines[index + 1].time : 999999
                      return root.timePos >= myTime && root.timePos < nextTime
                    }

                    onIsCurrentLineChanged: {
                      if (isCurrentLine) lyricsListView.smoothScrollTo(index)
                    }

                    Component.onCompleted: {
                      if (isCurrentLine && !lyricsListView.moving && !lyricsListView.flicking) {
                        lyricsListView.positionViewAtIndex(index, ListView.Center)
                      }
                    }

                    Text {
                      id: lyricLineText
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(16)
                      anchors.rightMargin: Style.space(16)
                      text: modelData.text || "♪"
                      font.family: Style.font.family
                      font.pixelSize: isCurrentLine ? Style.font.subtitle : Style.font.body
                      font.weight: isCurrentLine ? Font.Bold : Font.Normal
                      color: isCurrentLine ? Commons.Color.accent : Qt.darker(Commons.Color.foreground, 1.3)
                      horizontalAlignment: Text.AlignLeft
                      wrapMode: Text.WordWrap
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: modelData.time >= 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                      onClicked: {
                        if (modelData.time >= 0) {
                          root.seekTo(modelData.time)
                          lyricsListView.smoothScrollTo(index)
                        }
                      }
                    }
                  }
                }
              }

              // 3. Queue View
              ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Style.space(4)

                // Sub-header with queue position & jump button
                RowLayout {
                  Layout.fillWidth: true
                  Layout.leftMargin: Style.space(4)
                  Layout.rightMargin: Style.space(4)
                  spacing: Style.space(6)

                  Text {
                    text: "Queue (" + root.playbackQueue.length + ")"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.weight: Font.Bold
                    color: Qt.darker(Commons.Color.foreground, 1.3)
                    Layout.fillWidth: true
                  }

                  Button {
                    visible: root.queueIndex >= 0 && root.queueIndex < root.playbackQueue.length
                    iconText: "󰆤"
                    text: (root.queueIndex + 1) + "/" + root.playbackQueue.length
                    tooltipText: "Locate currently playing track"
                    bordered: true
                    onClicked: queueListView.scrollToCurrent(true)
                  }
                }

                Item {
                  Layout.fillWidth: true
                  Layout.fillHeight: true

                  Text {
                    anchors.centerIn: parent
                    visible: root.queueLoading && root.playbackQueue.length === 0
                    text: "Loading queue..."
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    color: Qt.darker(Commons.Color.foreground, 1.4)
                  }

                  ListView {
                    id: queueListView
                    anchors.fill: parent
                    clip: true
                    spacing: Style.space(3)
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    model: root.playbackQueue

                    NumberAnimation {
                      id: queueScrollAnim
                      target: queueListView
                      property: "contentY"
                      duration: 350
                      easing.type: Easing.OutCubic
                    }

                    function scrollToCurrent(smooth) {
                      if (root.queueIndex >= 0 && root.playbackQueue && root.queueIndex < root.playbackQueue.length) {
                        if (smooth && !queueListView.moving && !queueListView.flicking) {
                          var item = queueListView.itemAtIndex(root.queueIndex)
                          if (item) {
                            var targetY = item.y - (queueListView.height - item.height) / 2
                            var maxContentY = Math.max(0, queueListView.contentHeight - queueListView.height)
                            targetY = Math.max(0, Math.min(targetY, maxContentY))
                            if (Math.abs(queueListView.contentY - targetY) > 1) {
                              queueScrollAnim.stop()
                              queueScrollAnim.from = queueListView.contentY
                              queueScrollAnim.to = targetY
                              queueScrollAnim.start()
                              return
                            }
                          }
                        }
                        queueListView.positionViewAtIndex(root.queueIndex, ListView.Center)
                      }
                    }

                    onModelChanged: Qt.callLater(function() { scrollToCurrent(false) })

                    Connections {
                      target: root
                      function onQueueIndexChanged() {
                        if (root.currentScreen === "nowplaying" && root.nowPlayingSubTab === "queue") {
                          queueListView.scrollToCurrent(true)
                        }
                      }
                      function onNowPlayingSubTabChanged() {
                        if (root.currentScreen === "nowplaying" && root.nowPlayingSubTab === "queue") {
                          Qt.callLater(function() { queueListView.scrollToCurrent(false) })
                        }
                      }
                    }

                    delegate: BorderSurface {
                      required property var modelData
                      required property int index
                      readonly property bool isCurrentInQueue: index === root.queueIndex
                      readonly property bool isPastInQueue: root.queueIndex >= 0 && index < root.queueIndex

                      Component.onCompleted: {
                        root.requestCover(modelData.id, true)
                        if (isCurrentInQueue) {
                          queueListView.positionViewAtIndex(index, ListView.Center)
                        }
                      }

                      width: queueListView.width
                      implicitHeight: Style.space(38)
                      radius: Style.cornerRadius
                      opacity: isPastInQueue ? (qArea.containsMouse ? 0.8 : 0.45) : 1.0
                      Behavior on opacity { NumberAnimation { duration: 150 } }

                      borderSpec: isCurrentInQueue || qArea.containsMouse
                        ? Border.controlSpec(isCurrentInQueue ? "focus" : "hover-cursor", root.foreground, Commons.Color.accent)
                        : Border.none()
                      color: isCurrentInQueue
                        ? Style.selectedFillFor(root.foreground, Commons.Color.accent)
                        : (qArea.containsMouse ? Style.hoverFillFor(root.foreground, Commons.Color.accent) : "transparent")

                      RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(8)
                        anchors.rightMargin: Style.space(8)
                        spacing: Style.space(8)

                        Text {
                          text: isCurrentInQueue ? "󰝚" : String(index + 1)
                          font.family: Style.font.family
                          font.pixelSize: isCurrentInQueue ? Style.font.body : Style.font.caption
                          font.weight: isCurrentInQueue ? Font.Bold : Font.Normal
                          color: isCurrentInQueue ? Commons.Color.accent : (isPastInQueue ? Qt.darker(Commons.Color.foreground, 1.8) : Qt.darker(Commons.Color.foreground, 1.4))
                          Layout.minimumWidth: Style.space(20)
                          horizontalAlignment: Text.AlignRight
                        }

                        Rectangle {
                          Layout.preferredWidth: Style.space(24)
                          Layout.preferredHeight: Style.space(24)
                          Layout.alignment: Qt.AlignVCenter
                          radius: Style.cornerRadius
                          color: Style.normalFillFor(root.foreground, Commons.Color.accent)

                          Text {
                            anchors.centerIn: parent
                            text: "󰎆"
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            color: Qt.darker(Commons.Color.foreground, 1.4)
                          }

                          Image {
                            anchors.fill: parent
                            visible: root.trackThumbs[modelData.id] !== undefined && root.trackThumbs[modelData.id] !== ""
                            source: visible ? ("file://" + root.trackThumbs[modelData.id]) : ""
                            sourceSize: Qt.size(96, 96)
                            fillMode: Image.PreserveAspectCrop
                            clip: true
                            smooth: true
                          }
                        }

                        ColumnLayout {
                          Layout.fillWidth: true
                          spacing: 0
                          Text {
                            text: modelData.title || modelData.filename
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            font.weight: isCurrentInQueue ? Font.Bold : Font.Normal
                            color: isCurrentInQueue ? Commons.Color.accent : (isPastInQueue ? Qt.darker(Commons.Color.foreground, 1.4) : Commons.Color.foreground)
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                          }
                          Text {
                            text: (modelData.artist || "Unknown")
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            color: isPastInQueue ? Qt.darker(Commons.Color.foreground, 1.8) : Qt.darker(Commons.Color.foreground, 1.4)
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                          }
                        }

                        Text {
                          text: modelData.duration_str || "0:00"
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                          color: isPastInQueue ? Qt.darker(Commons.Color.foreground, 1.8) : Qt.darker(Commons.Color.foreground, 1.4)
                        }
                      }

                      MouseArea {
                        id: qArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          root.runCtl(["play-index", String(index)], function() {
                            root.fetchQueue()
                          })
                        }
                      }
                    }
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
          borderSpec: Border.controlSpec("normal", root.foreground, Commons.Color.accent)
          color: Style.normalFillFor(Commons.Color.foreground, Commons.Color.accent)

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

              // Track info area (clickable to toggle Now Playing view)
              Item {
                Layout.fillWidth: true
                Layout.preferredHeight: Style.space(36)

                RowLayout {
                  anchors.fill: parent
                  spacing: Style.space(8)

                  // Album cover for the now-playing area.
                  Rectangle {
                    id: nowPlayingCoverBox
                    Layout.preferredWidth: Style.space(36)
                    Layout.preferredHeight: Style.space(36)
                    Layout.alignment: Qt.AlignVCenter
                    radius: Style.cornerRadius
                    color: Style.normalFillFor(root.foreground, Commons.Color.accent)

                    Text {
                      anchors.centerIn: parent
                      text: "󰎆"
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      color: Qt.darker(Commons.Color.foreground, 1.4)
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
                        border.color: Qt.rgba(Commons.Color.foreground.r, Commons.Color.foreground.g, Commons.Color.foreground.b, 0.15)
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
                      color: Commons.Color.foreground
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                    }

                    Text {
                      text: root.currentTrack
                        ? root.currentTrack.artist
                        : (root.trackCount + " tracks available")
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      color: Qt.darker(Commons.Color.foreground, 1.4)
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                    }
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: root.currentTrack ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: {
                    if (root.currentTrack) {
                      root.currentScreen = root.currentScreen === "nowplaying" ? "tracks" : "nowplaying"
                      root.syncNowPlayingTab()
                    }
                  }
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
                color: Qt.darker(Commons.Color.foreground, 1.4)
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
                  color: Qt.rgba(Commons.Color.foreground.r, Commons.Color.foreground.g, Commons.Color.foreground.b, 0.18)
                  Behavior on height { NumberAnimation { duration: 100 } }

                  // Filled progress
                  Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: parent.width * progressBar.currentRatio
                    radius: parent.radius
                    color: Commons.Color.accent
                  }
                }

                // Scrub Knob
                Rectangle {
                  id: scrubKnob
                  width: Style.space(10)
                  height: Style.space(10)
                  radius: width / 2
                  color: Commons.Color.accent
                  border.width: 1.5
                  border.color: Commons.Color.foreground
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
                color: Qt.darker(Commons.Color.foreground, 1.4)
                Layout.minimumWidth: Style.space(28)
              }
            }
          }
        }
      }
    }
  }
}
