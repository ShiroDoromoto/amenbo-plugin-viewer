package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// The environment the other process is told where to look through. A test's directory is made
// while it runs, so it cannot be named in the helper's own source — it has to be handed over.
const (
	envLockHelper    = "VIEWER_TEST_LOCK_HELPER"
	envLockHelperDir = "VIEWER_TEST_LOCK_HELPER_DIR"
)

// TestHelperHoldsTheSendingLock is not a test. It is the other process, and it is a test function
// only because that is the one thing a test binary knows how to be told to run.
//
// It takes the hold, says so, and then waits on its own stdin until whoever started it has seen
// what it wanted to see. Waiting on a read rather than on nothing is deliberate: a goroutine
// asleep on a syscall is asleep in the kernel, where the runtime will not call it a deadlock.
func TestHelperHoldsTheSendingLock(t *testing.T) {
	if os.Getenv(envLockHelper) == "" {
		t.Skip("this is the other process, and nobody started it as one")
	}
	dir := os.Getenv(envLockHelperDir)
	pluginDir = func() (string, error) { return dir, nil }

	letGo, err := holdTheSend()
	if err != nil {
		fmt.Println("refused")
		os.Exit(1)
	}
	fmt.Println("held")
	bufio.NewReader(os.Stdin).ReadString('\n')
	letGo()
}

// theOtherProcess starts that helper and comes back once it says it has the hold.
func theOtherProcess(t *testing.T, dir string) *exec.Cmd {
	t.Helper()
	other := exec.Command(os.Args[0], "-test.run=^TestHelperHoldsTheSendingLock$")
	other.Env = append(os.Environ(), envLockHelper+"=1", envLockHelperDir+"="+dir)
	if _, err := other.StdinPipe(); err != nil {
		t.Fatal(err)
	}
	said, err := other.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := other.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		other.Process.Kill()
		other.Wait()
	})
	lines := bufio.NewScanner(said)
	for lines.Scan() {
		if strings.TrimSpace(lines.Text()) == "held" {
			return other
		}
	}
	t.Fatal("the other process never took the hold")
	return nil
}

// **The hold is what makes one send run at a time**, and a second one asks for it rather than
// waiting: a run that cannot have the send has nothing of its own to carry, so it stops.
func TestASecondTurnIsTurnedAwayWhileTheFirstHoldsTheSend(t *testing.T) {
	remembering(t)

	letGo, err := holdTheSend()
	if err != nil {
		t.Fatal(err)
	}

	if _, err := holdTheSend(); !errors.Is(err, errSendingElsewhere) {
		t.Fatalf("a second turn got into the send while the first held it: %v", err)
	}

	letGo()
	again, err := holdTheSend()
	if err != nil {
		t.Fatalf("the send stayed shut after the turn holding it let go: %v", err)
	}
	again()
}

// The hold has to work between processes, because that is the only place the problem is: two runs
// of this plugin, started by Amenbo, one of them raised by the other's own child. A hold that only
// held within one process would answer nothing.
func TestTheSendIsHeldAgainstAnotherProcess(t *testing.T) {
	dir := remembering(t)
	theOtherProcess(t, dir)

	if _, err := holdTheSend(); !errors.Is(err, errSendingElsewhere) {
		t.Fatalf("this process got into the send while another process held it: %v", err)
	}
}

// **A run that dies holding the send must not shut it forever.** Nothing of ours runs on the way
// out of a process that is killed — which is exactly what a machine waking from sleep does to what
// it finds running — so the letting go has to be the kernel's, not ours.
func TestTheSendOpensAgainWhenTheProcessHoldingItDies(t *testing.T) {
	dir := remembering(t)
	other := theOtherProcess(t, dir)

	if err := other.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	other.Wait()

	// The kernel lets go as it takes the process apart, which it finishes in its own time rather
	// than by the time `wait` answers.
	var err error
	for range 100 {
		var letGo func()
		if letGo, err = holdTheSend(); err == nil {
			letGo()
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("the send stayed shut after the process holding it was killed: %v", err)
}
