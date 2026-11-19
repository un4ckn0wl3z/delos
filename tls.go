package main

// HTTPS on the same port as HTTP.
//
// Every connection is sniffed: a TLS ClientHello (first byte 0x16) goes to the TLS server,
// anything else to the plain HTTP server, so http://host:port keeps working for the apps
// while https://host:port gives browsers a secure context (WebCodecs → direct play in the
// browser, installable web app).
//
// Certificates:
//   - -tls-cert/-tls-key (STREAMMKV_TLS_CERT/KEY): your own files, reloaded when they change;
//   - otherwise a small built-in certificate authority in <data>/tls. Its certificate can be
//     downloaded at /tls/ca.crt and installed on your devices to remove the browser warning.
//     The CA is name-constrained to this server's host names, so even if its key leaked it
//     could not be used to impersonate any other site. Host names are learned from the
//     address the admin uses to open the dashboard (and can be edited there).
//
// STREAMMKV_TLS=off (-tls off) turns it all off.

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// ---------------------------------------------------------------- listener that splits TLS and plain

type sniffListener struct {
	net.Listener
	plain, tls *chanListener
}

type chanListener struct {
	addr   net.Addr
	ch     chan net.Conn
	done   chan struct{}
	closed sync.Once
}

func (c *chanListener) Accept() (net.Conn, error) {
	select {
	case conn := <-c.ch:
		return conn, nil
	case <-c.done:
		return nil, net.ErrClosed
	}
}
func (c *chanListener) Close() error   { c.closed.Do(func() { close(c.done) }); return nil }
func (c *chanListener) Addr() net.Addr { return c.addr }

// peekedConn gives back the byte we looked at, and keeps sendfile working for plain HTTP.
type peekedConn struct {
	net.Conn
	r *bufio.Reader
}

func (p *peekedConn) Read(b []byte) (int, error) { return p.r.Read(b) }
func (p *peekedConn) ReadFrom(r io.Reader) (int64, error) {
	if rf, ok := p.Conn.(io.ReaderFrom); ok {
		return rf.ReadFrom(r)
	}
	return io.Copy(p.Conn, r)
}

func newSniffListener(ln net.Listener) *sniffListener {
	s := &sniffListener{Listener: ln,
		plain: &chanListener{addr: ln.Addr(), ch: make(chan net.Conn), done: make(chan struct{})},
		tls:   &chanListener{addr: ln.Addr(), ch: make(chan net.Conn), done: make(chan struct{})}}
	go s.loop()
	return s
}

func (s *sniffListener) loop() {
	var delay time.Duration
	for {
		c, err := s.Listener.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				s.plain.Close()
				s.tls.Close()
				return
			}
			if delay == 0 {
				delay = 5 * time.Millisecond
			} else if delay *= 2; delay > time.Second {
				delay = time.Second
			}
			time.Sleep(delay)
			continue
		}
		delay = 0
		go s.route(c)
	}
}

func (s *sniffListener) route(c net.Conn) {
	c.SetReadDeadline(time.Now().Add(15 * time.Second))
	br := bufio.NewReader(c)
	b, err := br.Peek(1)
	c.SetReadDeadline(time.Time{})
	if err != nil {
		c.Close()
		return
	}
	to := s.plain
	if b[0] == 0x16 { // TLS handshake record
		to = s.tls
	}
	select {
	case to.ch <- &peekedConn{Conn: c, r: br}:
	case <-to.done:
		c.Close()
	}
}

// ---------------------------------------------------------------- certificates

type TLSManager struct {
	mode string // "builtin", "custom" or "off"
	dir  string
	env  []string // STREAMMKV_TLS_HOSTS

	mu      sync.RWMutex
	cert    *tls.Certificate
	caDER   []byte
	caKey   *ecdsa.PrivateKey
	hosts   []string // names the current CA/leaf cover
	learned []string
	leafExp time.Time
	caMade  time.Time

	certFile, keyFile string
	checked           time.Time
	modTime           time.Time
}

type tlsState struct {
	Hosts []string `json:"hosts"` // learned or set by the admin
}

func NewTLSManager(cfg Config, mode string) (*TLSManager, error) {
	m := &TLSManager{mode: "builtin", dir: filepath.Join(cfg.DataDir, "tls")}
	switch strings.ToLower(strings.TrimSpace(mode)) {
	case "off", "0", "false", "no", "none":
		m.mode = "off"
		return m, nil
	}
	if cfg.TLSCert != "" {
		m.mode, m.certFile, m.keyFile = "custom", cfg.TLSCert, cfg.TLSKey
		if err := m.reloadFiles(); err != nil {
			return nil, err
		}
		return m, nil
	}
	for _, h := range strings.FieldsFunc(os.Getenv("STREAMMKV_TLS_HOSTS"), func(r rune) bool { return r == ',' || r == ' ' }) {
		if h = cleanHost(h); h != "" {
			m.env = append(m.env, h)
		}
	}
	if err := os.MkdirAll(m.dir, 0o700); err != nil {
		return nil, err
	}
	var st tlsState
	if b, err := os.ReadFile(filepath.Join(m.dir, "hosts.json")); err == nil {
		json.Unmarshal(b, &st)
	}
	m.learned = st.Hosts
	if err := m.load(); err != nil {
		log.Printf("tls: %v — making a new certificate authority", err)
		if err := m.issue(true); err != nil {
			return nil, err
		}
	}
	go m.renewLoop()
	return m, nil
}

func (m *TLSManager) Enabled() bool { return m.mode != "off" }

func (m *TLSManager) GetCertificate(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	if m.mode == "custom" {
		m.mu.RLock()
		stale := time.Since(m.checked) > 30*time.Second
		m.mu.RUnlock()
		if stale {
			if err := m.reloadFiles(); err != nil {
				log.Printf("tls: %v (keeping the previous certificate)", err)
			}
		}
	}
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.cert == nil {
		return nil, errors.New("no certificate")
	}
	return m.cert, nil
}

func (m *TLSManager) reloadFiles() error {
	fi, err := os.Stat(m.certFile)
	if err != nil {
		return err
	}
	m.mu.Lock()
	m.checked = time.Now()
	same := m.cert != nil && fi.ModTime().Equal(m.modTime)
	m.mu.Unlock()
	if same {
		return nil
	}
	c, err := tls.LoadX509KeyPair(m.certFile, m.keyFile)
	if err != nil {
		return err
	}
	leaf, _ := x509.ParseCertificate(c.Certificate[0])
	m.mu.Lock()
	m.cert, m.modTime = &c, fi.ModTime()
	if leaf != nil {
		m.leafExp, m.hosts = leaf.NotAfter, certNames(leaf)
	}
	m.mu.Unlock()
	return nil
}

// wanted is every name the certificates should cover.
func (m *TLSManager) wanted() []string {
	set := map[string]bool{"localhost": true, "127.0.0.1": true, "::1": true}
	for _, h := range append(append([]string{}, m.env...), m.learned...) {
		set[h] = true
	}
	out := make([]string, 0, len(set))
	for h := range set {
		out = append(out, h)
	}
	sort.Strings(out)
	return out
}

func (m *TLSManager) load() error {
	read := func(n string) (*pem.Block, error) {
		b, err := os.ReadFile(filepath.Join(m.dir, n))
		if err != nil {
			return nil, err
		}
		p, _ := pem.Decode(b)
		if p == nil {
			return nil, fmt.Errorf("%s: not PEM", n)
		}
		return p, nil
	}
	caP, err := read("ca.crt")
	if err != nil {
		return err
	}
	caKP, err := read("ca.key")
	if err != nil {
		return err
	}
	ca, err := x509.ParseCertificate(caP.Bytes)
	if err != nil {
		return err
	}
	caKey, err := x509.ParseECPrivateKey(caKP.Bytes)
	if err != nil {
		return err
	}
	if !sameNames(append(append([]string{}, ca.PermittedDNSDomains...), ipStrings(ca.PermittedIPRanges)...), m.wanted()) {
		return errors.New("host names changed")
	}
	if time.Until(ca.NotAfter) < 60*24*time.Hour {
		return errors.New("certificate authority expires soon")
	}
	m.mu.Lock()
	m.caDER, m.caKey, m.caMade, m.hosts = caP.Bytes, caKey, ca.NotBefore, m.wanted()
	m.mu.Unlock()
	c, err := tls.LoadX509KeyPair(filepath.Join(m.dir, "server.crt"), filepath.Join(m.dir, "server.key"))
	if err == nil {
		leaf, _ := x509.ParseCertificate(c.Certificate[0])
		if leaf != nil && time.Until(leaf.NotAfter) > 30*24*time.Hour && sameNames(certNames(leaf), m.wanted()) {
			m.mu.Lock()
			m.cert, m.leafExp = &c, leaf.NotAfter
			m.mu.Unlock()
			return nil
		}
	}
	return m.issue(false)
}

// issue makes a new server certificate, and a new CA first when newCA is set.
func (m *TLSManager) issue(newCA bool) error {
	hosts := m.wanted()
	var dns []string
	var ips []net.IP
	var nets []*net.IPNet
	for _, h := range hosts {
		if ip := net.ParseIP(h); ip != nil {
			ips = append(ips, ip)
			bits := 32
			if ip.To4() == nil {
				bits = 128
			}
			nets = append(nets, &net.IPNet{IP: ip, Mask: net.CIDRMask(bits, bits)})
		} else {
			dns = append(dns, h)
		}
	}
	now := time.Now().Add(-time.Hour)
	m.mu.RLock()
	caDER, caKey := m.caDER, m.caKey
	m.mu.RUnlock()
	if newCA || caKey == nil {
		k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return err
		}
		name := "Delos"
		for _, h := range dns {
			if h != "localhost" {
				name += " " + h
				break
			}
		}
		tpl := &x509.Certificate{
			SerialNumber:                serial(),
			Subject:                     pkix.Name{CommonName: name + " CA", Organization: []string{"Delos"}},
			NotBefore:                   now,
			NotAfter:                    now.AddDate(10, 0, 0),
			IsCA:                        true,
			BasicConstraintsValid:       true,
			MaxPathLenZero:              true,
			KeyUsage:                    x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
			PermittedDNSDomainsCritical: true,
			PermittedDNSDomains:         dns,
			PermittedIPRanges:           nets,
		}
		der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &k.PublicKey, k)
		if err != nil {
			return err
		}
		kb, _ := x509.MarshalECPrivateKey(k)
		if err := writePEM(filepath.Join(m.dir, "ca.key"), "EC PRIVATE KEY", kb); err != nil {
			return err
		}
		if err := writePEM(filepath.Join(m.dir, "ca.crt"), "CERTIFICATE", der); err != nil {
			return err
		}
		caDER, caKey = der, k
		m.mu.Lock()
		m.caDER, m.caKey, m.caMade = der, k, now
		m.mu.Unlock()
		log.Printf("tls: new certificate authority for %s — reinstall /tls/ca.crt on your devices", strings.Join(hosts, ", "))
	}
	ca, err := x509.ParseCertificate(caDER)
	if err != nil {
		return err
	}
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	tpl := &x509.Certificate{
		SerialNumber: serial(),
		Subject:      pkix.Name{CommonName: firstOr(dns, "localhost")},
		NotBefore:    now,
		NotAfter:     now.AddDate(0, 0, 397), // the most Apple devices accept
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     dns,
		IPAddresses:  ips,
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, ca, &k.PublicKey, caKey)
	if err != nil {
		return err
	}
	kb, _ := x509.MarshalECPrivateKey(k)
	if err := writePEM(filepath.Join(m.dir, "server.key"), "EC PRIVATE KEY", kb); err != nil {
		return err
	}
	certPEM := append(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER})...)
	if err := os.WriteFile(filepath.Join(m.dir, "server.crt"), certPEM, 0o644); err != nil {
		return err
	}
	c := tls.Certificate{Certificate: [][]byte{der, caDER}, PrivateKey: k}
	m.mu.Lock()
	m.cert, m.leafExp, m.hosts = &c, tpl.NotAfter, hosts
	m.mu.Unlock()
	return nil
}

func (m *TLSManager) renewLoop() {
	for range time.Tick(12 * time.Hour) {
		m.mu.RLock()
		exp := m.leafExp
		m.mu.RUnlock()
		if time.Until(exp) < 30*24*time.Hour {
			if err := m.issue(false); err != nil {
				log.Printf("tls: renew: %v", err)
			}
		}
	}
}

// Learn adds the host the admin reached us by (dashboard visits), so the certificate matches it.
func (m *TLSManager) Learn(hostport string) {
	if m.mode != "builtin" {
		return
	}
	h := cleanHost(hostport)
	if h == "" {
		return
	}
	m.mu.RLock()
	known := false
	for _, x := range m.hosts {
		known = known || x == h
	}
	n := len(m.learned)
	m.mu.RUnlock()
	if known || n >= 12 {
		return
	}
	if err := m.SetHosts(append(append([]string{}, m.learned...), h)); err != nil {
		log.Printf("tls: %v", err)
	}
}

func (m *TLSManager) SetHosts(hosts []string) error {
	if m.mode != "builtin" {
		return errors.New("HTTPS uses your own certificate files")
	}
	var clean []string
	seen := map[string]bool{}
	for _, h := range hosts {
		if h = cleanHost(h); h != "" && !seen[h] {
			seen[h] = true
			clean = append(clean, h)
		}
	}
	if len(clean) > 12 {
		return errors.New("at most 12 host names")
	}
	m.mu.Lock()
	m.learned = clean
	m.mu.Unlock()
	b, _ := json.MarshalIndent(tlsState{Hosts: clean}, "", "  ")
	if err := os.WriteFile(filepath.Join(m.dir, "hosts.json"), b, 0o600); err != nil {
		return err
	}
	m.mu.RLock()
	same := sameNames(m.hosts, m.wanted())
	m.mu.RUnlock()
	if same {
		return nil
	}
	return m.issue(true)
}

func (m *TLSManager) CAPEM() []byte {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.mode != "builtin" || m.caDER == nil {
		return nil
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: m.caDER})
}

func (m *TLSManager) Status() map[string]any {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := map[string]any{"mode": m.mode}
	if m.mode == "off" {
		return out
	}
	out["hosts"] = m.hosts
	out["expires"] = m.leafExp
	if m.mode == "builtin" {
		sum := sha256.Sum256(m.caDER)
		out["learned"] = m.learned
		out["env"] = m.env
		out["fingerprint"] = strings.ToUpper(fmt.Sprintf("% x", sum[:]))
		out["caCreated"] = m.caMade
	}
	return out
}

func (s *Server) tlsRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /tls/ca.crt", func(w http.ResponseWriter, r *http.Request) {
		b := s.tls.CAPEM()
		if b == nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/x-x509-ca-cert")
		w.Header().Set("Content-Disposition", `attachment; filename="streammkv-ca.crt"`)
		w.Header().Set("Cache-Control", "no-cache")
		w.Write(b)
	})
	mux.HandleFunc("GET /tls/info", func(w http.ResponseWriter, r *http.Request) {
		st := s.tls.Status()
		out := map[string]any{"mode": st["mode"]}
		if st["mode"] == "builtin" {
			out["fingerprint"], out["hosts"] = st["fingerprint"], st["hosts"]
		}
		writeJSON(w, 200, out)
	})
	mux.HandleFunc("GET /api/admin/tls", s.adminOnly(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, s.tls.Status())
	}))
	mux.HandleFunc("POST /api/admin/tls", s.adminOnly(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Hosts []string `json:"hosts"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&body); err != nil {
			httpErr(w, 400, "bad request")
			return
		}
		if err := s.tls.SetHosts(body.Hosts); err != nil {
			httpErr(w, 400, err.Error())
			return
		}
		writeJSON(w, 200, s.tls.Status())
	}))
}

// ---------------------------------------------------------------- helpers

var hostRe = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$`)

func cleanHost(h string) string {
	h = strings.ToLower(strings.TrimSpace(h))
	if hh, _, err := net.SplitHostPort(h); err == nil {
		h = hh
	}
	h = strings.TrimSuffix(strings.Trim(h, "[]"), ".")
	if ip := net.ParseIP(h); ip != nil {
		if ip.IsUnspecified() || ip.IsMulticast() {
			return ""
		}
		return ip.String()
	}
	if len(h) > 253 || !hostRe.MatchString(h) {
		return ""
	}
	return h
}

func certNames(c *x509.Certificate) []string {
	return append(append([]string{}, c.DNSNames...), ipStrings(c.IPAddresses)...)
}

func ipStrings[T net.IP | *net.IPNet](v []T) []string {
	var out []string
	for _, x := range v {
		switch y := any(x).(type) {
		case net.IP:
			out = append(out, y.String())
		case *net.IPNet:
			out = append(out, y.IP.String())
		}
	}
	return out
}

func sameNames(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	a, b = append([]string{}, a...), append([]string{}, b...)
	sort.Strings(a)
	sort.Strings(b)
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func serial() *big.Int {
	n, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	return n
}

func firstOr(v []string, d string) string {
	for _, x := range v {
		if x != "localhost" {
			return x
		}
	}
	return d
}

func writePEM(path, typ string, b []byte) error {
	return os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: typ, Bytes: b}), 0o600)
}
