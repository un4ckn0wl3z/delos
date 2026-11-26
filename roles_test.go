package main

import (
	"testing"
)

func TestRolesAccess(t *testing.T) {
	us, err := NewUserStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{"a", "b", "c"} {
		if _, err := us.Add(n, "password1", false); err != nil {
			t.Fatal(err)
		}
	}
	if us.Libraries("a") != nil {
		t.Fatal("no roles: all")
	}
	fam, _ := us.SaveRole("", Role{Name: "Family", Libraries: &[]string{"movies", "kids"}, Editor: true})
	allR, _ := us.SaveRole("", Role{Name: "Everything"})
	if fam != "family" || allR != "everything" {
		t.Fatal(fam, allR)
	}
	if _, err := us.SaveRole("", Role{Name: "family"}); err == nil {
		t.Fatal("duplicate name accepted")
	}
	// a: role only → just the role's libraries
	if err := us.SetUserRoles("a", []string{"family"}); err != nil {
		t.Fatal(err)
	}
	if got := us.Libraries("a"); len(got) != 2 {
		t.Fatal("a", got)
	}
	if !us.IsEditor("a") || us.IsDownloader("a") {
		t.Fatal("permissions from role")
	}
	// b: own list + role → union
	us.SetLibraries("b", &[]string{"music"})
	us.SetUserRoles("b", []string{"family"})
	if got := us.Libraries("b"); len(got) != 3 {
		t.Fatal("b", got)
	}
	// c: role with all
	us.SetUserRoles("c", []string{"family", "everything"})
	if us.Libraries("c") != nil {
		t.Fatal("c should see all")
	}
	// deleting a role takes it off users
	if err := us.DeleteRole("family"); err != nil {
		t.Fatal(err)
	}
	if got := us.Libraries("a"); len(got) != 0 {
		t.Fatal("a after delete", got)
	}
	// persisted
	us2, _ := NewUserStore(us.file[:len(us.file)-len("/users.json")])
	if len(us2.Roles()) != 1 || us2.Libraries("c") != nil {
		t.Fatal("reload", us2.Roles())
	}
}
