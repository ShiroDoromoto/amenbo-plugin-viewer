//go:build windows

package main

import (
	"os/exec"
	"syscall"
)

// detached cuts the child loose from this run — the same reason as everywhere else, and only the
// way of saying it differs: its own process group, and no console to be closed along with ours.
func detached(child *exec.Cmd) {
	child.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP | 0x00000008, // DETACHED_PROCESS
	}
}
