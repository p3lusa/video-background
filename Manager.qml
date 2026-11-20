import QtQuick

// v0.8: the plugin's wallpaper layer is retired — owe (the OWE wallpaper
// daemon) owns video rendering and the stock omarchy.background service draws
// stills. This service entry point exists only because the plugin manifest
// schema requires at least one kind; it intentionally draws nothing and
// keeps no state. All the plugin's behaviour lives in bin/ (TUI, theme
// generation, keybindings).
Item {}
