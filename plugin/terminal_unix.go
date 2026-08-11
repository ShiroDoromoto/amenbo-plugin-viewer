//go:build !windows

package main

// terminalPath is the controlling terminal, which is where `setup` reads the pasted token from.
//
// It is opened by name rather than read off stdin, because stdin is already spoken for: Amenbo
// writes the plugin's input document there and closes it, so by the time a command face runs
// there is nothing left on it to type into.
const terminalPath = "/dev/tty"
