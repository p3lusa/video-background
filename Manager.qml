import QtQuick
import Quickshell
import Quickshell.Io

// Service entry point. v0.8 retired the plugin's own wallpaper layer (owe
// renders videos, stock omarchy.background draws stills); this service now
// does real work: each time the shell loads the plugin (enable, rescan,
// restart) it runs bin/video-bootstrap.sh — which self-deploys the keybinding
// block and menu entry and installs the companion library theme when absent.
// The script is idempotent and cheap; all logic lives there, out of QML, so
// it stays testable without the shell.
Item {
  id: root

  Process {
    id: boot
    // Quickshell quirk (0.3.2, same pattern the stock agents plugin uses):
    // an auto-running Process inside a component-instantiated service never
    // starts — the run must be triggered explicitly on completion.
    running: false
    // resolvedUrl gives file://<plugin-dir>/bin/video-bootstrap.sh
    command: ["bash", decodeURIComponent(Qt.resolvedUrl("bin/video-bootstrap.sh")).replace(/^file:\/\//, "")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "")
        console.log("[video-background] bootstrap: " + text.trim())
    }
  }

  Component.onCompleted: boot.running = true
}
