//go:build windows

package main

// terminalPath is the console's input, which is Windows' answer to /dev/tty — the same reason
// applies, and only the name differs.
const terminalPath = "CONIN$"
