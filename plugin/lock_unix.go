//go:build !windows

package main

import (
	"errors"
	"os"
	"syscall"
)

// takeSendingLock asks the kernel for the whole file, and does not wait for it. A hold that is
// already taken comes back as "no", not as a fault: another run is sending, which is the answer
// this is here to get.
//
// **The hold belongs to the open file, not to this process.** That is what makes it survive the
// one case this is for — a run that dies, or is killed when the machine wakes, drops it on the
// way out with no code of ours running.
func takeSendingLock(file *os.File) (bool, error) {
	err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	if err == nil {
		return true, nil
	}
	if errors.Is(err, syscall.EWOULDBLOCK) {
		return false, nil
	}
	return false, err
}

// dropSendingLock lets it go. Closing the file would do the same, and does when this is not
// reached; saying it out loud is for the reader, so the pair is visible at both ends.
func dropSendingLock(file *os.File) {
	syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
}
