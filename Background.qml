import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import QtMultimedia
import qs.Commons
import qs.Ui

Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"
  readonly property string currentThemeLink: stateHome + "/omarchy/current/theme"

  // Video wallpaper: the active theme may ship a videos/ directory. When it
  // does, each panel plays the current clip (looped; video-only assets carry
  // no audio track) on top of the image fallback. `omarchy theme bg next` /
  // `bg set` advance to the next clip (cycle); `omarchy theme set` resets to
  // the first clip. When the theme has no video, videoPath stays "" and the
  // plugin behaves exactly like the stock omarchy.background image renderer.
  property string videoPath: ""
  // Map of extension-less base name -> video path, for every videos/*.mp4 in
  // the active theme. The clip is derived from the current background (same
  // base name), so the video can never desync from the image: the background
  // symlink is the single source of truth, and it is already Omarchy's
  // persisted state (a restart resumes on the same clip for free).
  property var videoByBase: ({})
  // True once the active theme's videos/*.mp4 listing has finished loading.
  // While false the map is empty because the `ls` is still in flight, not
  // because the theme ships no videos; syncVideoToBackground must not fall
  // back to the image in that window, or videoPath flaps to "" and back and
  // the MediaPlayer restarts (the visible flash on startup / bg change).
  property bool videoMapLoaded: false

  // Occlusion: while the session is locked or idle (screensaver territory)
  // the background layer is not visible, so decoding is paused to save
  // battery and GPU. State is polled from the shell's first-party services
  // (lock + idle), which also honors the user's own idle configuration.
  property bool sessionOccluded: false

  property string currentBackground: ""
  property string displayedBackground: ""
  property string incomingBackground: ""
  property string oldBackground: ""
  property bool finishingTransition: false
  property int backgroundVersion: 0
  property int revealStartedVersion: -1
  property int pendingThemeVersion: -1
  property string pendingColorsRaw: ""
  property string pendingShellRaw: ""
  property real revealProgress: 1

  function imageUrl(path) {
    return Util.fileUrl(path)
  }

  function refreshBackground() {
    if (!readlinkProc.running) readlinkProc.running = true
    refreshVideo()
  }

  function refreshVideo() {
    if (!themeVideoProc.running) themeVideoProc.running = true
  }

  function setVideoPath(path) {
    path = String(path || "").trim()
    if (path === videoPath) return
    videoPath = path
    console.debug("[io.github.p3lu.video-background] video -> "
        + (path !== "" ? path : "(none, image fallback)"))
  }

  // Base name without directory or extension: "a/b/clip.mp4" -> "clip".
  function baseKey(path) {
    path = String(path || "")
    var b = path.substring(path.lastIndexOf("/") + 1)
    var dot = b.lastIndexOf(".")
    return (dot > 0) ? b.substring(0, dot) : b
  }

  // The video follows the current background: play the theme video whose base
  // name matches the background image, if any. Called when the background
  // changes and when the theme video list is (re)loaded.
  function syncVideoToBackground() {
    var key = (currentBackground === "") ? "" : baseKey(currentBackground)
    var found = (key !== "" && videoByBase.hasOwnProperty(key))
        ? videoByBase[key] : ""
    // Only fall back to the image once the listing has actually loaded.
    // While videoMapLoaded is false the map is empty because the `ls` is in
    // flight; clearing videoPath here would flap it to "" and back, restarting
    // the MediaPlayer and flashing the image behind the video.
    if (found !== "") setVideoPath(found)
    else if (videoMapLoaded) setVideoPath("")
  }

  function setBackground(path, instant) {
    refreshVideo()
    transitionBackground("", path, path, instant, false)
  }

  function transitionBackground(fromPath, path, finalPath, instant, force) {
    path = String(path || "").trim()
    finalPath = String(finalPath || path).trim()
    fromPath = String(fromPath || "").trim()
    refreshVideo()
    if (!path || (!force && finalPath === currentBackground)) return
    currentBackground = finalPath
    backgroundVersion += 1
    revealStartedVersion = -1

    revealAnimation.stop()
    finishingTransition = false

    if (instant || !displayedBackground) {
      oldBackground = ""
      incomingBackground = ""
      displayedBackground = path
      revealProgress = 1
      return
    }

    oldBackground = fromPath || displayedBackground
    incomingBackground = path
    revealProgress = 0
  }

  function setPendingTheme(colorsB64, shellB64) {
    pendingColorsRaw = Util.decodeBase64(colorsB64)
    pendingShellRaw = Util.decodeBase64(shellB64)
    pendingThemeVersion = backgroundVersion
    pendingThemeFallbackTimer.restart()
  }

  function applyPendingTheme() {
    // Background polling can advance backgroundVersion while a theme switch is
    // pending; the latest theme payload should still apply.
    if (pendingThemeVersion < 0) return
    pendingThemeFallbackTimer.stop()
    Color.loadColors(pendingColorsRaw)
    // Color.loadShell also refreshes Style so the type scale flips with the
    // background reveal instead of waiting for a separate reload path.
    Color.loadShell(pendingShellRaw)
    Style.scheduleRefresh()
    pendingThemeVersion = -1
    pendingColorsRaw = ""
    pendingShellRaw = ""
  }

  function transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64) {
    transitionBackground(fromPath, path, finalPath, false, true)
    setPendingTheme(colorsB64, shellB64)
    if (!incomingBackground || revealProgress >= 1) applyPendingTheme()
  }

  function startReveal(panel) {
    if (!incomingBackground) return
    panel.maskReady = true
    if (revealStartedVersion === backgroundVersion) return
    revealStartedVersion = backgroundVersion
    applyPendingTheme()
    revealAnimation.restart()
  }

  function openSelector() {
    if (!bgSwitchProc.running) bgSwitchProc.running = true
  }

  function openThemeSwitcher() {
    if (!themeSwitchProc.running) themeSwitchProc.running = true
  }

  Process {
    id: bgSwitchProc
    command: ["bash", "-c", "background=$(omarchy-theme-bg-switcher); [[ -n $background ]] && omarchy-theme-bg-set \"$background\""]
    onExited: root.refreshBackground()
  }

  Process {
    id: themeSwitchProc
    // Filtered theme switcher: hides the per-clip video themes (marked with
    // .video-theme) so the stock theme selector stays clean. Falls back to
    // the stock switcher when the plugin script is missing.
    command: ["bash", "-c",
      "VTS=\"$HOME/.config/omarchy/plugins/io.github.p3lu.video-background/bin/video-theme-switcher.sh\"; " +
      "if [[ -x $VTS ]]; then theme=$(\"$VTS\"); else theme=$(omarchy-theme-switcher); fi; " +
      "[[ -n $theme ]] && omarchy-theme-set \"$theme\" >/dev/null 2>&1 &"]
    onExited: root.refreshBackground()
  }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.currentBackgroundLink]
    stdout: StdioCollector {
      onStreamFinished: root.setBackground(String(text || "").trim(), false)
    }
  }

  // The background symlink is the source of truth. IPC can be dropped
  // (e.g. a burst of `bg next`), and themes can gain/lose videos at runtime,
  // so poll the symlink on a 2s cadence and re-resolve. A re-set of the
  // current path early-returns (no transition), so an unchanged desktop costs
  // one cheap readlink per tick.
  Timer {
    id: backgroundPollTimer
    interval: 2000
    repeat: true
    running: true
    onTriggered: { if (!readlinkProc.running) readlinkProc.running = true }
  }

  // Resolve the active theme's videos/*.mp4 and build the base-name map.
  // `omarchy theme set` / `theme bg next` also update the theme symlink, and
  // both paths funnel through setBackground/transitionBackground (IPC + poll),
  // so re-resolving there keeps the map in sync with the active theme.
  Process {
    id: themeVideoProc
    command: ["bash", "-c", "theme=$(readlink -f " + root.currentThemeLink + "); [[ -d $theme/videos ]] && ls $theme/videos/*.mp4 2>/dev/null | sort"]
    // A relaunch (theme change, poll) means the map is about to be rebuilt;
    // clear the loaded flag so syncVideoToBackground doesn't fall back to the
    // image on the stale/empty map during the gap.
    onRunningChanged: function(running) { if (running) root.videoMapLoaded = false }
    stdout: StdioCollector {
      onStreamFinished: {
        var map = ({})
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var p = lines[i].trim()
          if (p.length > 0)
            map[root.baseKey(p)] = p
        }
        root.videoByBase = map
        root.videoMapLoaded = true
        root.syncVideoToBackground()
      }
    }
  }

  IpcHandler {
    target: "background"

    function refresh(): void {
      root.refreshBackground()
    }

    function set(path: string): void {
      root.setBackground(path, false)
    }

    function setInstant(path: string): void {
      root.setBackground(path, true)
    }

    function transition(fromPath: string, path: string): void {
      root.transitionBackground(fromPath, path, path, false, false)
    }

    function themeTransition(fromPath: string, path: string, finalPath: string, colorsB64: string, shellB64: string): void {
      root.transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64)
    }
  }

  Timer {
    id: pendingThemeFallbackTimer
    interval: 300
    repeat: false
    onTriggered: root.applyPendingTheme()
  }

  NumberAnimation {
    id: revealAnimation
    target: root
    property: "revealProgress"
    from: 0
    to: 1
    duration: 420
    easing.type: Easing.InOutCubic
    onFinished: {
      if (root.incomingBackground) {
        root.displayedBackground = root.currentBackground || root.incomingBackground
        root.finishingTransition = true
      }
      root.revealProgress = 1
    }
  }

  Component.onCompleted: root.refreshBackground()

  // When the active background changes, follow it with its paired video.
  Connections {
    target: root
    function onCurrentBackgroundChanged() { root.syncVideoToBackground() }
  }

  // Stale-buffer recovery. The background layer can end up with an uncommitted
  // surface buffer (observed right after a shell restart, and after parking
  // behind the lock screen for a long time), leaving a flat desktop until a
  // scene change forces a re-render. We force an invisible one: run the reveal
  // transition with the same image on both sides (X over X changes nothing
  // visually) so the compositor re-commits the surface. The transition state
  // is cleared shortly after, since with no source change the base image never
  // re-emits its status signal to do it naturally.
  Timer {
    id: startupPokeTimer
    interval: 2000
    repeat: false
    running: true
    onTriggered: root.pokeRerender()
  }

  Timer {
    id: pokeCleanupTimer
    interval: 900
    repeat: false
    onTriggered: {
      root.incomingBackground = ""
      root.oldBackground = ""
      root.finishingTransition = false
    }
  }

  function pokeRerender() {
    if (root.displayedBackground === "")
      return
    if (root.incomingBackground !== "")
      return // a real transition is in progress; it will re-render on its own
    root.transitionBackground(root.displayedBackground, root.displayedBackground,
        root.currentBackground, false, true)
    pokeCleanupTimer.restart()
  }

  // When the desktop becomes visible again after lock/idle, force the same
  // re-commit (the surface can go stale while parked behind the lock screen).
  Connections {
    target: root
    function onSessionOccludedChanged() {
      if (!root.sessionOccluded)
        root.pokeRerender()
    }
  }

  // Occlusion probe: asks the shell's first-party lock and idle services for
  // the current state. Both answers are local IPC calls, so a 2s cadence is
  // negligible. A failed call keeps the previous state.
  Timer {
    id: occlusionProbeTimer
    interval: 2000
    repeat: true
    running: true
    onTriggered: { if (!occlusionProbeProc.running) occlusionProbeProc.running = true }
  }

  Process {
    id: occlusionProbeProc
    command: ["bash", "-c",
        "l=$(omarchy-shell lock isLocked 2>/dev/null); [[ -z $l ]] && l=false; "
        + "s=$(omarchy-shell idle status 2>/dev/null); "
        + "printf '%s %s\\n' \"$l\" \"$s\""]
    stdout: StdioCollector {
      onStreamFinished: {
        // Line format: "<lockIsLocked> <idleStatusJson>". The JSON is compact
        // today but may not stay that way, so split on the first space only.
        var t = String(text || "").trim()
        var sp = t.indexOf(" ")
        var lockedPart = (sp === -1) ? t : t.substring(0, sp)
        var statusPart = (sp === -1) ? "" : t.substring(sp + 1)
        var locked = (lockedPart === "true")
        var idle = (statusPart.indexOf("\"idle\":true") !== -1)
        var next = locked || idle
        if (next !== root.sessionOccluded) {
          console.log("[io.github.p3lu.video-background] "
              + (next ? "occluded (lock/idle) -> pausing video" : "visible -> resuming video"))
          root.sessionOccluded = next
        }
      }
    }
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      visible: !remapGuard.remapping
      anchors { top: true; bottom: true; left: true; right: true }

      ScreenMoveRemap {
        id: remapGuard
        window: panel
      }
      color: "transparent"
      // Keep render updates enabled. The background layer has been observed to
      // lose its committed buffer while parked with updatesEnabled=false,
      // leaving a black desktop until omarchy-shell is restarted. The wallpaper
      // itself is static, so this favors correctness over a small render-loop
      // optimization.
      updatesEnabled: true

      property bool maskReady: false

      function maybeStartReveal() {
        if (!root.incomingBackground || root.revealProgress !== 0 || maskReady) return
        if (incomingFrame.status !== Image.Ready) return
        Qt.callLater(function() {
          if (!root.incomingBackground || root.revealProgress !== 0 || maskReady) return
          if (incomingFrame.status !== Image.Ready) return
          root.startReveal(panel)
        })
      }

      WlrLayershell.namespace: "omarchy-background"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      Image {
        id: base
        anchors.fill: parent
        source: root.imageUrl(root.displayedBackground)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        onStatusChanged: {
          if (status === Image.Ready && root.finishingTransition) {
            root.incomingBackground = ""
            root.oldBackground = ""
            root.finishingTransition = false
          }
        }
      }

      // One player per panel (multi-monitor): each screen decodes its own
      // copy. On the reference hardware (AMD 780M, H.264 1080p) that is a few
      // percent of one core. The image `base` underneath is always kept
      // current, so a missing/corrupt/unloadable video degrades to the image
      // instead of a black screen. While the session is locked or idle the
      // player is paused (the background layer is not visible anyway).
      MediaPlayer {
        id: videoPlayer
        source: root.videoPath !== "" ? root.imageUrl(root.videoPath) : ""
        autoPlay: true
        loops: -1 // infinite
        onPlaybackStateChanged: function() {
          if (playbackState === MediaPlayer.PlayingState) {
            // Pause immediately if the session became occluded while this
            // clip was starting up (autoPlay would otherwise run it hidden).
            if (root.sessionOccluded) {
              videoPlayer.pause()
              return
            }
            console.log("[io.github.p3lu.video-background] playing " + root.videoPath + " on " + modelData.name)
            videoOut.ensureFrameHook()
          }
        }
        onErrorOccurred: function(error, errorString) {
          if (root.videoPath !== "")
            console.warn("[io.github.p3lu.video-background] video error on " + modelData.name + ": " + errorString)
        }
      }

      // Occlusion pause/resume. This Qt build exposes play()/pause()/stop()
      // methods (no writable paused property): play() on a paused player
      // resumes it in place, preserving the loop position.
      Connections {
        target: root
        function onSessionOccludedChanged() {
          if (root.sessionOccluded) {
            if (videoPlayer.playbackState === MediaPlayer.PlayingState)
              videoPlayer.pause()
          } else if (root.videoPath !== ""
              && videoPlayer.playbackState === MediaPlayer.PausedState) {
            videoPlayer.play()
          }
        }
      }

      VideoOutput {
        id: videoOut
        anchors.fill: parent
        fillMode: Qt.KeepAspectRatioByExpanding
        // Reveal only after the first decoded frame: the image underneath
        // (current poster) stays visible until real video pixels exist, so a
        // clip change or a cold start never flashes a black frame.
        property bool frameDecoded: false
        property bool frameHooked: false
        function ensureFrameHook() {
          if (frameHooked || videoSink === null)
            return
          videoSink.videoFrameChanged.connect(function() {
            videoOut.frameDecoded = true
          })
          frameHooked = true
        }
        visible: root.videoPath !== ""
            && videoPlayer.playbackState === MediaPlayer.PlayingState
            && videoOut.frameDecoded
        Component.onCompleted: {
          videoPlayer.videoOutput = videoOut
          videoOut.ensureFrameHook()
        }
        Connections {
          target: root
          function onVideoPathChanged() { videoOut.frameDecoded = false }
        }
      }

      Image {
        id: oldFrame
        anchors.fill: parent
        source: root.imageUrl(root.oldBackground)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        smooth: true
        mipmap: true
        visible: root.oldBackground !== "" && root.revealProgress < 1
        onStatusChanged: panel.maybeStartReveal()
      }

      Item {
        id: incomingLayer
        anchors.fill: parent
        visible: root.incomingBackground !== "" && incomingFrame.status === Image.Ready && (root.revealProgress >= 1 || panel.maskReady)
        layer.enabled: root.incomingBackground !== "" && root.revealProgress < 1
        layer.smooth: true
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: revealMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 0.02
        }

        Image {
          id: incomingFrame
          anchors.fill: parent
          source: root.imageUrl(root.incomingBackground)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          smooth: true
          mipmap: true
          onStatusChanged: panel.maybeStartReveal()
        }
      }

      Item {
        id: revealMask
        anchors.fill: parent
        visible: false
        layer.enabled: true

        readonly property real slant: -0.18
        readonly property real centerTop: width / 2 - slant * height / 2
        readonly property real centerBottom: width / 2 + slant * height / 2
        readonly property real reach: width / 2 + Math.abs(slant) * height / 2 + 4
        readonly property real spread: reach * root.revealProgress

        Shape {
          anchors.fill: parent
          antialiasing: true
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            fillColor: "white"
            strokeColor: "transparent"
            startX: revealMask.centerTop - revealMask.spread; startY: 0
            PathLine { x: revealMask.centerTop + revealMask.spread; y: 0 }
            PathLine { x: revealMask.centerBottom + revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerBottom - revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerTop - revealMask.spread; y: 0 }
          }
        }
      }

      Connections {
        target: root
        function onIncomingBackgroundChanged() {
          panel.maskReady = false
          panel.maybeStartReveal()
        }
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onDoubleClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) root.openThemeSwitcher()
          else root.openSelector()
          mouse.accepted = true
        }
      }
    }
  }
}
