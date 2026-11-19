//go:build unix

package main

import (
	"os"
	"syscall"
)

// selfUpdateSupported: not inside the Docker image — there the image is updated instead.
func selfUpdateSupported() bool { return os.Getenv("STREAMMKV_DOCKER") == "" }

// restartSelf replaces the current process image with the (new) binary at exe.
// The PID stays the same; the listening socket is closed on exec (CLOEXEC) and re-bound.
func restartSelf(exe string) error {
	return syscall.Exec(exe, os.Args, os.Environ())
}
