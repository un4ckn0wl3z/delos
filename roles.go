package main

// Roles: named sets of libraries (and permissions) the admin gives to users, e.g. "Family"
// sees Movies + Kids, "Music only" sees Music. A user's access = their roles + their own extras.

import (
	"errors"
	"net/http"
	"sort"
	"strings"
	"time"
)

type Role struct {
	Name string `json:"name"`
	// Libraries this role sees; nil = all (including ones added later).
	Libraries  *[]string `json:"libraries"`
	Editor     bool      `json:"editor,omitempty"`
	Downloader bool      `json:"downloader,omitempty"`
	Offline    bool      `json:"offline,omitempty"`
	Created    int64     `json:"created"`
}

type RoleView struct {
	ID string `json:"id"`
	Role
	Members []string `json:"members"`
}

func (us *UserStore) rolesOfLocked(u *User) []*Role {
	var out []*Role
	for _, id := range u.Roles {
		if r := us.roles[id]; r != nil {
			out = append(out, r)
		}
	}
	return out
}

func (us *UserStore) roleHasLocked(u *User, f func(*Role) bool) bool {
	for _, r := range us.rolesOfLocked(u) {
		if f(r) {
			return true
		}
	}
	return false
}

func (us *UserStore) Roles() []RoleView {
	us.mu.Lock()
	defer us.mu.Unlock()
	out := []RoleView{}
	for id, r := range us.roles {
		v := RoleView{ID: id, Role: *r, Members: []string{}}
		for n, u := range us.users {
			for _, x := range u.Roles {
				if x == id {
					v.Members = append(v.Members, n)
				}
			}
		}
		sort.Strings(v.Members)
		out = append(out, v)
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
	return out
}

func roleSlug(name string) string {
	var b strings.Builder
	for _, c := range strings.ToLower(name) {
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9':
			b.WriteRune(c)
		case b.Len() > 0 && !strings.HasSuffix(b.String(), "-"):
			b.WriteByte('-')
		}
	}
	s := strings.Trim(b.String(), "-")
	if s == "" {
		s = "role"
	}
	return clip(s, 32)
}

// SaveRole creates (id "") or updates a role; returns its id.
func (us *UserStore) SaveRole(id string, r Role) (string, error) {
	r.Name = strings.TrimSpace(r.Name)
	if r.Name == "" || len(r.Name) > 40 {
		return "", errors.New("give the role a name (up to 40 characters)")
	}
	us.mu.Lock()
	defer us.mu.Unlock()
	for oid, o := range us.roles {
		if oid != id && strings.EqualFold(o.Name, r.Name) {
			return "", errors.New("a role with that name exists")
		}
	}
	if id == "" {
		id = roleSlug(r.Name)
		for base, n := id, 2; us.roles[id] != nil; n++ {
			id = base + "-" + itoa(n)
		}
		r.Created = time.Now().Unix()
	} else {
		old := us.roles[id]
		if old == nil {
			return "", errors.New("no such role")
		}
		r.Created = old.Created
	}
	us.roles[id] = &r
	return id, us.saveLocked()
}

func (us *UserStore) DeleteRole(id string) error {
	us.mu.Lock()
	defer us.mu.Unlock()
	if us.roles[id] == nil {
		return errors.New("no such role")
	}
	delete(us.roles, id)
	for _, u := range us.users {
		keep := u.Roles[:0]
		for _, x := range u.Roles {
			if x != id {
				keep = append(keep, x)
			}
		}
		u.Roles = keep
	}
	return us.saveLocked()
}

// SetUserRoles gives [name] exactly these roles. The first time a user gets roles, their own
// library list stops meaning "all" (so the roles decide), unless it was a list already.
func (us *UserStore) SetUserRoles(name string, roles []string) error {
	us.mu.Lock()
	defer us.mu.Unlock()
	u, ok := us.users[name]
	if !ok {
		return errors.New("no such user")
	}
	clean := []string{}
	for _, id := range roles {
		if us.roles[id] == nil {
			return errors.New("no such role: " + id)
		}
		clean = append(clean, id)
	}
	if len(u.Roles) == 0 && len(clean) > 0 && u.Libraries == nil {
		none := []string{}
		u.Libraries = &none
	}
	u.Roles = clean
	return us.saveLocked()
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for ; n > 0; n /= 10 {
		b = append([]byte{byte('0' + n%10)}, b...)
	}
	return string(b)
}

func (s *Server) roleRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/admin/roles", s.adminOnly(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"roles": s.users.Roles()})
	}))
	save := func(w http.ResponseWriter, r *http.Request) {
		var b Role
		if !decodeJSON(w, r, &b) {
			return
		}
		if b.Libraries != nil {
			for _, id := range *b.Libraries {
				if _, ok := s.libs.Get(id); !ok {
					httpErr(w, 400, "unknown library "+id)
					return
				}
			}
		}
		id, err := s.users.SaveRole(r.PathValue("id"), b)
		if err != nil {
			httpErr(w, 400, err.Error())
			return
		}
		writeJSON(w, 200, map[string]string{"id": id})
	}
	mux.HandleFunc("POST /api/admin/roles", s.adminOnly(save))
	mux.HandleFunc("POST /api/admin/roles/{id}", s.adminOnly(save))
	mux.HandleFunc("DELETE /api/admin/roles/{id}", s.adminOnly(func(w http.ResponseWriter, r *http.Request) {
		if err := s.users.DeleteRole(r.PathValue("id")); err != nil {
			httpErr(w, 404, err.Error())
			return
		}
		writeJSON(w, 200, map[string]bool{"ok": true})
	}))
	// POST /api/admin/users/{name}/roles {"roles": ["family", …]}
	mux.HandleFunc("POST /api/admin/users/{name}/roles", s.adminOnly(func(w http.ResponseWriter, r *http.Request) {
		var b struct{ Roles []string }
		if !decodeJSON(w, r, &b) {
			return
		}
		name := r.PathValue("name")
		if err := s.users.SetUserRoles(name, b.Roles); err != nil {
			httpErr(w, 400, err.Error())
			return
		}
		writeJSON(w, 200, map[string]bool{"ok": true})
	}))
}
