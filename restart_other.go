//go:build !unix

package main

import "errors"

func selfUpdateSupported() bool { return false }

func restartSelf(string) error { return errors.New("restart not supported on this platform") }
