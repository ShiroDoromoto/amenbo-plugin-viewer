//go:build windows

package main

import (
	"errors"
	"os"

	"golang.org/x/sys/windows"
)

// takeSendingLock is the same hold as everywhere else, and only the way of asking differs:
// Windows locks a range rather than a file, so one byte stands for the whole of it — both sides
// name the same byte, so both sides contend.
//
// `LOCKFILE_FAIL_IMMEDIATELY` is what makes it not wait, and a range already held comes back as
// `ERROR_LOCK_VIOLATION` — the answer, not a fault.
func takeSendingLock(file *os.File) (bool, error) {
	err := windows.LockFileEx(
		windows.Handle(file.Fd()),
		windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY,
		0, 1, 0,
		new(windows.Overlapped),
	)
	if err == nil {
		return true, nil
	}
	if errors.Is(err, windows.ERROR_LOCK_VIOLATION) {
		return false, nil
	}
	return false, err
}

// dropSendingLock lets that range go. Closing the handle would do the same, and does when this is
// not reached.
func dropSendingLock(file *os.File) {
	windows.UnlockFileEx(windows.Handle(file.Fd()), 0, 1, 0, new(windows.Overlapped))
}
