package main

// Minimal rtorrent XML-RPC client. rtorrent speaks XML-RPC over SCGI (a unix
// socket or a TCP port); ruTorrent setups also expose it over HTTP (/RPC2).

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type RTorrent struct {
	Endpoint string // "/path/to/socket", "unix:/path", "scgi://host:port", "host:port", "http(s)://…"
}

// ---------------------------------------------------------------- transport

func (rt *RTorrent) Call(method string, args ...any) (any, error) {
	var body bytes.Buffer
	body.WriteString(`<?xml version="1.0"?><methodCall><methodName>`)
	xml.EscapeText(&body, []byte(method))
	body.WriteString(`</methodName><params>`)
	for _, a := range args {
		body.WriteString("<param>")
		if err := xmlrpcValue(&body, a); err != nil {
			return nil, err
		}
		body.WriteString("</param>")
	}
	body.WriteString(`</params></methodCall>`)

	ep := strings.TrimSpace(rt.Endpoint)
	if ep == "" {
		return nil, errors.New("rtorrent is not configured")
	}
	var resp []byte
	var err error
	if strings.HasPrefix(ep, "http://") || strings.HasPrefix(ep, "https://") {
		resp, err = httpRPC(ep, body.Bytes())
	} else {
		network, addr := "tcp", strings.TrimPrefix(ep, "scgi://")
		if strings.HasPrefix(ep, "unix:") || strings.HasPrefix(ep, "/") || strings.HasPrefix(ep, "~") {
			network, addr = "unix", expandHome(strings.TrimPrefix(ep, "unix:"))
		}
		resp, err = scgiRPC(network, addr, body.Bytes())
	}
	if err != nil {
		return nil, err
	}
	return parseXMLRPCResponse(resp)
}

func expandHome(p string) string {
	if strings.HasPrefix(p, "~/") {
		if h, err := os.UserHomeDir(); err == nil {
			return filepath.Join(h, p[2:])
		}
	}
	return p
}

func scgiRPC(network, addr string, body []byte) ([]byte, error) {
	c, err := net.DialTimeout(network, addr, 5*time.Second)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(30 * time.Second))
	hdr := "CONTENT_LENGTH\x00" + strconv.Itoa(len(body)) + "\x00SCGI\x001\x00REQUEST_METHOD\x00POST\x00REQUEST_URI\x00/RPC2\x00"
	var req bytes.Buffer
	req.WriteString(strconv.Itoa(len(hdr)) + ":" + hdr + ",")
	req.Write(body)
	if _, err := c.Write(req.Bytes()); err != nil {
		return nil, err
	}
	raw, err := io.ReadAll(io.LimitReader(c, 64<<20))
	if err != nil && len(raw) == 0 {
		return nil, err
	}
	// "Status: 200 OK\r\nContent-Type: text/xml\r\n…\r\n\r\n<?xml…" — drop the headers
	if t := bytes.TrimSpace(raw); !bytes.HasPrefix(t, []byte("<")) {
		if i := bytes.Index(raw, []byte("\r\n\r\n")); i >= 0 {
			raw = raw[i+4:]
		} else if i := bytes.Index(raw, []byte("\n\n")); i >= 0 {
			raw = raw[i+2:]
		}
	}
	return raw, nil
}

func httpRPC(ep string, body []byte) ([]byte, error) {
	req, err := http.NewRequest("POST", ep, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "text/xml")
	if req.URL.User != nil { // basic auth from the URL
		pw, _ := req.URL.User.Password()
		req.SetBasicAuth(req.URL.User.Username(), pw)
	}
	resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("rtorrent RPC: %s", resp.Status)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 64<<20))
}

// ---------------------------------------------------------------- encoding

func xmlrpcValue(w *bytes.Buffer, v any) error {
	w.WriteString("<value>")
	switch x := v.(type) {
	case string:
		w.WriteString("<string>")
		xml.EscapeText(w, []byte(x))
		w.WriteString("</string>")
	case int:
		fmt.Fprintf(w, "<i8>%d</i8>", x)
	case int64:
		fmt.Fprintf(w, "<i8>%d</i8>", x)
	case bool:
		if x {
			w.WriteString("<boolean>1</boolean>")
		} else {
			w.WriteString("<boolean>0</boolean>")
		}
	case []byte:
		w.WriteString("<base64>" + base64.StdEncoding.EncodeToString(x) + "</base64>")
	case []any:
		w.WriteString("<array><data>")
		for _, e := range x {
			if err := xmlrpcValue(w, e); err != nil {
				return err
			}
		}
		w.WriteString("</data></array>")
	case []string:
		w.WriteString("<array><data>")
		for _, e := range x {
			xmlrpcValue(w, e)
		}
		w.WriteString("</data></array>")
	default:
		return fmt.Errorf("xmlrpc: unsupported type %T", v)
	}
	w.WriteString("</value>")
	return nil
}

// parseXMLRPCResponse decodes a methodResponse into Go values:
// string, int64, bool, []byte, []any, map[string]any.
func parseXMLRPCResponse(b []byte) (any, error) {
	d := xml.NewDecoder(bytes.NewReader(b))
	d.Strict = false
	var fault bool
	for {
		t, err := d.Token()
		if err != nil {
			return nil, fmt.Errorf("rtorrent: bad XML-RPC response: %v", err)
		}
		if se, ok := t.(xml.StartElement); ok {
			switch se.Name.Local {
			case "fault":
				fault = true
			case "value":
				v, err := xmlrpcDecodeValue(d)
				if err != nil {
					return nil, err
				}
				if fault {
					m, _ := v.(map[string]any)
					return nil, fmt.Errorf("rtorrent: %v", m["faultString"])
				}
				return v, nil
			}
		}
	}
}

// xmlrpcDecodeValue reads the contents of a <value> element (start already consumed).
func xmlrpcDecodeValue(d *xml.Decoder) (any, error) {
	var text strings.Builder
	var out any
	typed := false
	for {
		t, err := d.Token()
		if err != nil {
			return nil, err
		}
		switch x := t.(type) {
		case xml.CharData:
			text.Write(x)
		case xml.EndElement:
			if x.Name.Local == "value" {
				if !typed {
					return text.String(), nil // untyped value = string
				}
				return out, nil
			}
		case xml.StartElement:
			typed = true
			switch x.Name.Local {
			case "string":
				s, err := elemText(d)
				if err != nil {
					return nil, err
				}
				out = s
			case "i4", "i8", "int":
				s, err := elemText(d)
				if err != nil {
					return nil, err
				}
				n, _ := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
				out = n
			case "boolean":
				s, err := elemText(d)
				if err != nil {
					return nil, err
				}
				out = strings.TrimSpace(s) == "1"
			case "double":
				s, err := elemText(d)
				if err != nil {
					return nil, err
				}
				f, _ := strconv.ParseFloat(strings.TrimSpace(s), 64)
				out = f
			case "base64":
				s, err := elemText(d)
				if err != nil {
					return nil, err
				}
				out, _ = base64.StdEncoding.DecodeString(strings.TrimSpace(s))
			case "array":
				arr := []any{}
				for {
					t, err := d.Token()
					if err != nil {
						return nil, err
					}
					if se, ok := t.(xml.StartElement); ok && se.Name.Local == "value" {
						v, err := xmlrpcDecodeValue(d)
						if err != nil {
							return nil, err
						}
						arr = append(arr, v)
					}
					if ee, ok := t.(xml.EndElement); ok && ee.Name.Local == "array" {
						break
					}
				}
				out = arr
			case "struct":
				m := map[string]any{}
				name := ""
				for {
					t, err := d.Token()
					if err != nil {
						return nil, err
					}
					if se, ok := t.(xml.StartElement); ok {
						switch se.Name.Local {
						case "name":
							name, _ = elemText(d)
						case "value":
							v, err := xmlrpcDecodeValue(d)
							if err != nil {
								return nil, err
							}
							m[name] = v
						}
					}
					if ee, ok := t.(xml.EndElement); ok && ee.Name.Local == "struct" {
						break
					}
				}
				out = m
			default:
				d.Skip()
			}
		}
	}
}

func elemText(d *xml.Decoder) (string, error) {
	var b strings.Builder
	for {
		t, err := d.Token()
		if err != nil {
			return "", err
		}
		switch x := t.(type) {
		case xml.CharData:
			b.Write(x)
		case xml.EndElement:
			return b.String(), nil
		}
	}
}

// ---------------------------------------------------------------- rtorrent commands

func (rt *RTorrent) Version() (string, error) {
	v, err := rt.Call("system.client_version")
	if err != nil {
		return "", err
	}
	return fmt.Sprint(v), nil
}

// quoteCmdArg quotes a value for an rtorrent command string (d.directory.set="…").
func quoteCmdArg(s string) (string, error) {
	if strings.ContainsAny(s, "\"\\\n\r") {
		return "", errors.New("folder name contains unsupported characters (quote or backslash)")
	}
	return `"` + s + `"`, nil
}

// Add starts a magnet/URL (string) or a .torrent file ([]byte) downloading into dir.
// tag is stored in d.custom2 so the job can be found again.
func (rt *RTorrent) Add(src any, dir, tag string) error {
	q, err := quoteCmdArg(dir)
	if err != nil {
		return err
	}
	cmds := []any{"", src, "d.directory.set=" + q, "d.custom2.set=" + tag, "d.custom1.set=StreamMKV"}
	method := "load.start"
	if _, raw := src.([]byte); raw {
		method = "load.raw_start"
	}
	_, err = rt.Call(method, cmds...)
	return err
}

type rtItem struct {
	Hash, Name, Tag, BasePath, Message string
	Size, Done, DownRate, UpRate       int64
	Complete, Active                   bool
}

func (rt *RTorrent) List() ([]rtItem, error) {
	v, err := rt.Call("d.multicall2", "", "main",
		"d.hash=", "d.name=", "d.size_bytes=", "d.completed_bytes=", "d.down.rate=", "d.up.rate=",
		"d.complete=", "d.custom2=", "d.base_path=", "d.message=", "d.is_active=")
	if err != nil {
		return nil, err
	}
	rows, _ := v.([]any)
	out := []rtItem{}
	for _, r := range rows {
		c, _ := r.([]any)
		if len(c) < 11 {
			continue
		}
		s := func(i int) string { return fmt.Sprint(c[i]) }
		n := func(i int) int64 {
			switch x := c[i].(type) {
			case int64:
				return x
			case string:
				v, _ := strconv.ParseInt(x, 10, 64)
				return v
			}
			return 0
		}
		out = append(out, rtItem{Hash: s(0), Name: s(1), Size: n(2), Done: n(3), DownRate: n(4), UpRate: n(5),
			Complete: n(6) == 1, Tag: s(7), BasePath: s(8), Message: s(9), Active: n(10) == 1})
	}
	return out, nil
}

func (rt *RTorrent) Erase(hash string) error {
	_, err := rt.Call("d.erase", hash)
	return err
}

// ---------------------------------------------------------------- discovery

var reSCGI = regexp.MustCompile(`^\s*(?:network\.scgi\.open_local|scgi_local|network\.scgi\.open_port|scgi_port)\s*=\s*(.+?)\s*$`)

// DetectRTorrent looks for rtorrent's XML-RPC endpoint in the usual places.
func DetectRTorrent() string {
	home, _ := os.UserHomeDir()
	if home == "" {
		return ""
	}
	var cands []string
	for _, rc := range []string{".rtorrent.rc", ".config/rtorrent/rtorrent.rc", ".config/rtorrent/.rtorrent.rc"} {
		f, err := os.Open(filepath.Join(home, rc))
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			m := reSCGI.FindStringSubmatch(sc.Text())
			if m == nil || strings.HasPrefix(strings.TrimSpace(sc.Text()), "#") {
				continue
			}
			v := strings.Trim(m[1], `"'`)
			if strings.Contains(v, "(") { // computed path, e.g. (cat,(session.path),rpc.socket) — handled by the scan below
				continue
			}
			if strings.Contains(sc.Text(), "port") {
				cands = append(cands, "scgi://"+v)
			} else {
				cands = append(cands, expandHome(v))
			}
		}
		f.Close()
	}
	// any socket file in the usual folders
	for _, dir := range []string{home, filepath.Join(home, ".config/rtorrent"), filepath.Join(home, ".config/rtorrent/session"),
		filepath.Join(home, ".local/share/rtorrent"), filepath.Join(home, ".rtorrent"), filepath.Join(home, ".sessions"),
		filepath.Join(home, ".session"), filepath.Join(home, ".rtorrent-session"), filepath.Join(home, "rtorrent"),
		filepath.Join(home, "rtorrent/.session"), filepath.Join(home, "torrents/rtorrent/.session")} {
		ents, _ := os.ReadDir(dir)
		for _, e := range ents {
			if e.Type()&os.ModeSocket != 0 && (strings.Contains(e.Name(), "rpc") || strings.Contains(e.Name(), "rtorrent") || strings.Contains(e.Name(), "scgi")) {
				cands = append(cands, filepath.Join(dir, e.Name()))
			}
		}
	}
	cands = append(cands, "scgi://127.0.0.1:5000")
	for _, c := range cands {
		rt := &RTorrent{Endpoint: c}
		if _, err := rt.Version(); err == nil {
			return c
		}
	}
	return ""
}
