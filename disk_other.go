//go:build !unix

package main

func diskUsage(path string) (total, free uint64, ok bool) { return 0, 0, false }
