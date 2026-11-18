package main

import (
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const pbkdf2Iter = 600_000

var validName = regexp.MustCompile(`^[A-Za-z0-9._-]{1,32}$`)

type User struct {
	Hash    string `json:"hash"`
	Admin   bool   `json:"admin"`
	Gen     int    `json:"gen"` // bumped on password change / revoke → old tokens die
	Created int64  `json:"created"`
	// Libraries the user may see; nil = all, empty = none. Admins always see all.
	Libraries *[]string `json:"libraries,omitempty"`
	// Editor may correct metadata (admins always can).
	Editor bool `json:"editor,omitempty"`
	// Downloader may add HTTP/torrent downloads (admins always can).
	Downloader bool `json:"downloader,omitempty"`
}

type UserView struct {
	Name     string `json:"name"`
	Admin    bool   `json:"admin"`
	Created  int64  `json:"created"`
	LastSeen int64  `json:"lastSeen,omitempty"`
	// nil = all libraries
	Libraries  *[]string `json:"libraries"`
	Editor     bool      `json:"editor"`
	Downloader bool      `json:"downloader"`
}

// UserStore keeps users.json in memory. The file is re-read when it changes on
// disk (the `streammkv user …` CLI edits it while the server is running).
type UserStore struct {
	mu       sync.Mutex
	file     string
	mtime    time.Time
	users    map[string]*User
	lastSeen map[string]int64 // memory only
}

type usersFile struct {
	Version int              `json:"version"`
	Users   map[string]*User `json:"users"`
}

func NewUserStore(dir string) (*UserStore, error) {
	us := &UserStore{file: filepath.Join(dir, "users.json"), users: map[string]*User{}, lastSeen: map[string]int64{}}
	if err := us.load(); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	return us, nil
}

func (us *UserStore) load() error {
	st, err := os.Stat(us.file)
	if err != nil {
		return err
	}
	b, err := os.ReadFile(us.file)
	if err != nil {
		return err
	}
	var f usersFile
	if err := json.Unmarshal(b, &f); err != nil {
		return fmt.Errorf("%s: %w", us.file, err)
	}
	if f.Users == nil {
		f.Users = map[string]*User{}
	}
	us.users, us.mtime = f.Users, st.ModTime()
	return nil
}

// Watch reloads users.json when it is modified externally.
func (us *UserStore) Watch() {
	for range time.Tick(2 * time.Second) {
		st, err := os.Stat(us.file)
		if err != nil {
			continue
		}
		us.mu.Lock()
		if !st.ModTime().Equal(us.mtime) {
			if err := us.load(); err != nil {
				log.Printf("reload users: %v", err)
			} else {
				log.Printf("users.json reloaded (%d users)", len(us.users))
			}
		}
		us.mu.Unlock()
	}
}

func (us *UserStore) saveLocked() error {
	b, err := json.MarshalIndent(usersFile{Version: 1, Users: us.users}, "", "  ")
	if err != nil {
		return err
	}
	tmp := us.file + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, us.file); err != nil {
		return err
	}
	if st, err := os.Stat(us.file); err == nil {
		us.mtime = st.ModTime()
	}
	return nil
}

func hashPassword(pw string) string {
	salt := make([]byte, 16)
	rand.Read(salt)
	key, _ := pbkdf2.Key(sha256.New, pw, salt, pbkdf2Iter, 32)
	return fmt.Sprintf("pbkdf2-sha256$%d$%s$%s", pbkdf2Iter,
		base64.RawStdEncoding.EncodeToString(salt), base64.RawStdEncoding.EncodeToString(key))
}

func checkPassword(hash, pw string) bool {
	p := strings.Split(hash, "$")
	if len(p) != 4 || p[0] != "pbkdf2-sha256" {
		return false
	}
	iter, err := strconv.Atoi(p[1])
	salt, err2 := base64.RawStdEncoding.DecodeString(p[2])
	want, err3 := base64.RawStdEncoding.DecodeString(p[3])
	if err != nil || err2 != nil || err3 != nil {
		return false
	}
	got, err := pbkdf2.Key(sha256.New, pw, salt, iter, len(want))
	return err == nil && subtle.ConstantTimeCompare(got, want) == 1
}

func randomPassword() string {
	const chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	b := make([]byte, 16)
	rand.Read(b)
	for i := range b {
		b[i] = chars[int(b[i])%len(chars)]
	}
	return string(b)
}

// Authenticate returns the user's token generation on success.
func (us *UserStore) Authenticate(name, pw string) (int, bool) {
	us.mu.Lock()
	u, ok := us.users[name]
	var hash string
	var gen int
	if ok {
		hash, gen = u.Hash, u.Gen
	}
	us.mu.Unlock()
	if !ok {
		hashPassword(pw) // same work for unknown users
		return 0, false
	}
	return gen, checkPassword(hash, pw)
}

// Valid reports whether a token for (name, gen) is still acceptable, and whether the user is admin.
func (us *UserStore) Valid(name string, gen int) (admin, ok bool) {
	us.mu.Lock()
	defer us.mu.Unlock()
	u, found := us.users[name]
	if !found || u.Gen != gen {
		return false, false
	}
	us.lastSeen[name] = time.Now().Unix()
	return u.Admin, true
}

func (us *UserStore) Count() int {
	us.mu.Lock()
	defer us.mu.Unlock()
	return len(us.users)
}

func (us *UserStore) List() []UserView {
	us.mu.Lock()
	defer us.mu.Unlock()
	out := make([]UserView, 0, len(us.users))
	for n, u := range us.users {
		out = append(out, UserView{Name: n, Admin: u.Admin, Created: u.Created, LastSeen: us.lastSeen[n], Libraries: u.Libraries, Editor: u.Editor, Downloader: u.Downloader})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func (us *UserStore) adminCountLocked() int {
	n := 0
	for _, u := range us.users {
		if u.Admin {
			n++
		}
	}
	return n
}

// Add creates a user; an empty password generates one, which is returned.
func (us *UserStore) Add(name, pw string, admin bool) (string, error) {
	if pw != "" && len(pw) < 6 {
		return "", errors.New("password must be at least 6 characters")
	}
	return us.add(name, pw, admin)
}

// AddBootstrap creates the first admin from -user/-pass, keeping whatever password an
// existing single-user install already had.
func (us *UserStore) AddBootstrap(name, pw string) error {
	_, err := us.add(name, pw, true)
	return err
}

func (us *UserStore) add(name, pw string, admin bool) (string, error) {
	if !validName.MatchString(name) {
		return "", errors.New("username: 1-32 chars of A-Z a-z 0-9 . _ -")
	}
	if pw == "" {
		pw = randomPassword()
	}
	us.mu.Lock()
	defer us.mu.Unlock()
	if _, ok := us.users[name]; ok {
		return "", errors.New("user already exists")
	}
	us.users[name] = &User{Hash: hashPassword(pw), Admin: admin, Gen: 1, Created: time.Now().Unix()}
	return pw, us.saveLocked()
}

// SetPassword changes a password (empty = generate) and logs the user out everywhere.
func (us *UserStore) SetPassword(name, pw string) (string, error) {
	if pw == "" {
		pw = randomPassword()
	} else if len(pw) < 6 {
		return "", errors.New("password must be at least 6 characters")
	}
	us.mu.Lock()
	defer us.mu.Unlock()
	u, ok := us.users[name]
	if !ok {
		return "", errors.New("no such user")
	}
	u.Hash = hashPassword(pw)
	u.Gen++
	return pw, us.saveLocked()
}

func (us *UserStore) IsAdmin(name string) bool {
	us.mu.Lock()
	defer us.mu.Unlock()
	u, ok := us.users[name]
	return ok && u.Admin
}

func (us *UserStore) IsEditor(name string) bool {
	us.mu.Lock()
	defer us.mu.Unlock()
	u, ok := us.users[name]
	return ok && (u.Editor || u.Admin)
}

func (us *UserStore) SetEditor(name string, editor bool) error {
	us.mu.Lock()
	defer us.mu.Unlock()
	u, ok := us.users[name]
	if !ok {
		return errors.New("no such user")
	}
	u.Editor = editor
	return us.saveLocked()
}

func (us *UserStore) IsDownloader(name string) bool {
	us.mu.Lock()
	defer us.mu.Unlock()
	u, ok := us.users[name]
	return ok && (u.Downloader || u.Admin)
}

func (us *UserStore) SetDownloader(name string, on bool) error {
	us.mu.Lock()
	defer us.mu.Unlock()
	u, ok := us.users[name]
	if !ok {
		return errors.New("no such user")
	}
	u.Downloader = on
	return us.saveLocked()
}

// Libraries returns the library ids a user may see; nil means all.
func (us *UserStore) Libraries(name string) []string {
	us.mu.Lock()
	defer us.mu.Unlock()
	u, ok := us.users[name]
	if !ok {
		return []string{}
	}
	if u.Libraries == nil {
		return nil
	}
	return append([]string{}, (*u.Libraries)...)
}

// SetLibraries restricts a user to the given libraries; nil gives access to all.
func (us *UserStore) SetLibraries(name string, libs *[]string) error {
	us.mu.Lock()
	defer us.mu.Unlock()
	u, ok := us.users[name]
	if !ok {
		return errors.New("no such user")
	}
	u.Libraries = libs
	return us.saveLocked()
}

func (us *UserStore) Revoke(name string) error {
	us.mu.Lock()
	defer us.mu.Unlock()
	u, ok := us.users[name]
	if !ok {
		return errors.New("no such user")
	}
	u.Gen++
	return us.saveLocked()
}

func (us *UserStore) SetAdmin(name string, admin bool) error {
	us.mu.Lock()
	defer us.mu.Unlock()
	u, ok := us.users[name]
	if !ok {
		return errors.New("no such user")
	}
	if u.Admin && !admin && us.adminCountLocked() == 1 {
		return errors.New("cannot remove the last admin")
	}
	u.Admin = admin
	return us.saveLocked()
}

func (us *UserStore) Delete(name string) error {
	us.mu.Lock()
	defer us.mu.Unlock()
	u, ok := us.users[name]
	if !ok {
		return errors.New("no such user")
	}
	if u.Admin && us.adminCountLocked() == 1 {
		return errors.New("cannot delete the last admin")
	}
	delete(us.users, name)
	delete(us.lastSeen, name)
	return us.saveLocked()
}

// ---------------------------------------------------------------- CLI
// streammkv user list | add NAME [--admin] [--password P] | passwd NAME [--password P]
//                    | del NAME | admin NAME on|off | revoke NAME

func runUserCLI(args []string) {
	dataDir := os.Getenv("STREAMMKV_DATA")
	if dataDir == "" {
		dataDir = os.Getenv("STREAMMKV_CACHE")
	}
	if dataDir == "" {
		d, _ := os.UserCacheDir()
		dataDir = filepath.Join(d, "streammkv")
	}
	usage := func() {
		fmt.Fprintln(os.Stderr, `usage: streammkv user <command>
  list
  add NAME [--admin] [--password P]   (random password if omitted)
  passwd NAME [--password P]          (random password if omitted; logs the user out)
  admin NAME on|off
  revoke NAME                         (log out all sessions)
  del NAME
data dir: $STREAMMKV_DATA (`+dataDir+`)`)
		os.Exit(2)
	}
	if len(args) == 0 {
		usage()
	}
	os.MkdirAll(dataDir, 0o700)
	us, err := NewUserStore(dataDir)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	var pw string
	var admin bool
	var pos []string
	for i := 1; i < len(args); i++ {
		switch args[i] {
		case "--admin":
			admin = true
		case "--password":
			if i+1 < len(args) {
				pw = args[i+1]
				i++
			}
		default:
			pos = append(pos, args[i])
		}
	}
	need := func(n int) {
		if len(pos) < n {
			usage()
		}
	}
	fail := func(err error) {
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
	}
	switch args[0] {
	case "list":
		for _, u := range us.List() {
			role := "user"
			if u.Admin {
				role = "admin"
			}
			fmt.Printf("%-24s %-6s created %s\n", u.Name, role, time.Unix(u.Created, 0).Format("2006-01-02"))
		}
	case "add":
		need(1)
		p, err := us.Add(pos[0], pw, admin)
		fail(err)
		fmt.Printf("added %s (admin=%v)\npassword: %s\n", pos[0], admin, p)
	case "passwd":
		need(1)
		p, err := us.SetPassword(pos[0], pw)
		fail(err)
		fmt.Printf("password for %s: %s\n", pos[0], p)
	case "admin":
		need(2)
		fail(us.SetAdmin(pos[0], pos[1] == "on" || pos[1] == "true" || pos[1] == "yes"))
		fmt.Println("ok")
	case "revoke":
		need(1)
		fail(us.Revoke(pos[0]))
		fmt.Println("ok")
	case "del", "delete", "rm":
		need(1)
		fail(us.Delete(pos[0]))
		fmt.Println("deleted", pos[0])
	default:
		usage()
	}
}
