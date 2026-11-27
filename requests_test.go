package main

import (
	"testing"
	"time"
)

func TestRequestCounts(t *testing.T) {
	q := &Requests{path: t.TempDir() + "/requests.json", seen: map[string]int64{}}
	now := time.Now().Unix()
	q.list = []*MediaRequest{
		{ID: "a", By: "ann", Votes: []string{"ann", "bob"}, Status: ReqApproved, StatusAt: now},
		{ID: "b", By: "bob", Votes: []string{"bob"}, Status: ReqPending},
		{ID: "c", By: "cat", Votes: []string{"cat"}, Status: ReqDeclined, StatusAt: now},
	}
	if u, p := q.Counts("bob", false); u != 1 || p != 0 {
		t.Fatalf("bob: unread %d pending %d", u, p)
	}
	if u, p := q.Counts("admin", true); u != 0 || p != 1 {
		t.Fatalf("admin: unread %d pending %d", u, p)
	}
	q.seen["bob"] = now + 1 // looked after the change
	if u, _ := q.Counts("bob", false); u != 0 {
		t.Fatalf("bob after looking: unread %d", u)
	}
	q.markSeen("cat")
	if u, _ := q.Counts("cat", false); u != 0 {
		t.Fatalf("cat after markSeen: unread %d", u)
	}
	// seen marks survive a restart
	q2 := &Requests{path: q.path, seen: map[string]int64{}}
	if b := q2.seenPath(); b != q.seenPath() {
		t.Fatal(b)
	}
}
