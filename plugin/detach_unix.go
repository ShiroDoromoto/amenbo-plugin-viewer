//go:build !windows

package main

import (
	"os/exec"
	"syscall"
)

// detached cuts the child loose from this run. A new session means it outlives the process group
// Amenbo waits on, which is the whole point: the code has to stay on screen after the command
// face has answered.
func detached(child *exec.Cmd) {
	child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
}
