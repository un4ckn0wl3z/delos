//go:build unix

package main

import (
	"os"
	"syscall"
)

func selfUpdateSupported() bool { return true }

// restartSelf replaces the current process image with the (new) binary at exe.
// The PID stays the same; the listening socket is closed on exec (CLOEXEC) and re-bound.
func restartSelf(exe string) error {
	return syscall.Exec(exe, os.Args, os.Environ())
}
