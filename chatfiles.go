package main

// Chat attachments (pictures and files) and emoji reactions.
//
// Files live in <data>/chat/files/<conversation>/<id> (+ <id>.thumb.jpg for big pictures),
// only members of the conversation can fetch them, and they're deleted after the number of
// days set in the dashboard (the message stays and says the file has expired).

import (
	"bytes"
	"encoding/json"
	"fmt"
	"image"
	"image/draw"
	"image/jpeg"
	"io"
	"log"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	_ "image/gif"
	_ "image/png"
)

type Attachment struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Size  int64  `json:"size"`
	Mime  string `json:"mime"`
	Image bool   `json:"image,omitempty"` // shown inline
	W     int    `json:"w,omitempty"`
	H     int    `json:"h,omitempty"`
	Thumb bool   `json:"thumb,omitempty"` // a smaller preview exists (?thumb=1)
	Gone  bool   `json:"gone,omitempty"`  // deleted after the keep period
}

// Pictures the browser may show inline; everything else is always a download.
var inlineImage = map[string]bool{"image/jpeg": true, "image/png": true, "image/gif": true, "image/webp": true}

var attIDRe = regexp.MustCompile(`^[0-9a-f]{16}$`)

func (c *Chat) filesDir(conv string) string { return filepath.Join(c.dir, "files", conv) }

func (c *Chat) attExists(conv, id string) bool {
	_, err := os.Stat(filepath.Join(c.filesDir(conv), id))
	return err == nil
}

func (c *Chat) filesSize() int64 {
	var n int64
	filepath.WalkDir(filepath.Join(c.dir, "files"), func(_ string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			if fi, err := d.Info(); err == nil {
				n += fi.Size()
			}
		}
		return nil
	})
	return n
}

// filesLoop deletes attachments older than the keep period.
func (c *Chat) filesLoop() {
	time.Sleep(time.Minute)
	for {
		if days := c.s.settings.Get().ChatKeepDays; days > 0 {
			cut := time.Now().AddDate(0, 0, -days)
			root := filepath.Join(c.dir, "files")
			n := 0
			filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
				if err != nil || d.IsDir() {
					return nil
				}
				if fi, err := d.Info(); err == nil && fi.ModTime().Before(cut) {
					if os.Remove(p) == nil {
						n++
					}
				}
				return nil
			})
			if n > 0 {
				log.Printf("chat: deleted %d attachment file(s) older than %d days", n, days)
			}
		}
		time.Sleep(6 * time.Hour)
	}
}

// POST /api/chat/{id}/attachments  multipart: file, text (optional caption)
func (s *Server) handleChatAttach(w http.ResponseWriter, r *http.Request) {
	me := userOf(r)
	maxMB := s.settings.Get().ChatMaxMB
	if maxMB <= 0 {
		httpErr(w, 403, "attachments are turned off on this server")
		return
	}
	limit := int64(maxMB) << 20
	c := s.chat
	c.mu.Lock()
	cv := s.convFor(w, r)
	c.mu.Unlock()
	if cv == nil {
		return
	}
	if err := c.allow(me); err != nil {
		httpErr(w, 429, err.Error())
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, limit+(1<<20))
	mr, err := r.MultipartReader()
	if err != nil {
		httpErr(w, 400, "expected a file upload")
		return
	}
	dir := c.filesDir(cv.ID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	var att *Attachment
	var text string
	tmp := ""
	defer func() {
		if tmp != "" {
			os.Remove(tmp)
		}
	}()
	for {
		part, err := mr.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			httpErr(w, 413, fmt.Sprintf("file too big (max %d MB)", maxMB))
			return
		}
		switch part.FormName() {
		case "text":
			b, _ := io.ReadAll(io.LimitReader(part, 8000))
			text = strings.TrimSpace(string(b))
		case "file":
			if att != nil {
				continue
			}
			f, err := os.CreateTemp(dir, ".upload-*")
			if err != nil {
				httpErr(w, 500, err.Error())
				return
			}
			tmp = f.Name()
			head := make([]byte, 512)
			n, _ := io.ReadFull(part, head)
			head = head[:n]
			f.Write(head)
			size, err := io.Copy(f, io.LimitReader(part, limit-int64(n)+1))
			f.Close()
			size += int64(n)
			if err != nil {
				httpErr(w, 413, fmt.Sprintf("file too big (max %d MB)", maxMB))
				return
			}
			if size > limit {
				httpErr(w, 413, fmt.Sprintf("file too big (max %d MB)", maxMB))
				return
			}
			if size == 0 {
				httpErr(w, 400, "empty file")
				return
			}
			name := cleanFileName(part.FileName())
			att = &Attachment{ID: chatID(), Name: name, Size: size, Mime: sniffMime(head, name)}
		}
	}
	if att == nil {
		httpErr(w, 400, "no file")
		return
	}
	if len(text) > 4000 {
		text = text[:4000]
	}
	final := filepath.Join(dir, att.ID)
	if err := os.Rename(tmp, final); err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	tmp = ""
	if inlineImage[att.Mime] {
		att.Image = true
		makePreview(final, att)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	cv = s.convFor(w, r)
	if cv == nil {
		os.Remove(final)
		return
	}
	m := &Message{From: me, Text: text, Att: att}
	if err := c.appendMsg(cv, m); err != nil {
		os.Remove(final)
		httpErr(w, 500, err.Error())
		return
	}
	c.saveLocked()
	c.notify(cv, m)
	writeJSON(w, 200, map[string]any{"message": m})
}

// makePreview records a picture's size and writes a ≤640 px JPEG preview when the original is big.
func makePreview(file string, att *Attachment) {
	f, err := os.Open(file)
	if err != nil {
		return
	}
	defer f.Close()
	cfg, format, err := image.DecodeConfig(f)
	if err != nil {
		return // e.g. WebP: shown as is
	}
	att.W, att.H = cfg.Width, cfg.Height
	if format == "gif" || cfg.Width*cfg.Height > 50_000_000 {
		return // keep animations; refuse to decode gigantic pictures
	}
	if att.Size < 400<<10 && cfg.Width <= 1280 && cfg.Height <= 1280 {
		return
	}
	f.Seek(0, io.SeekStart)
	src, _, err := image.Decode(f)
	if err != nil {
		return
	}
	const max = 640
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	if w > h && w > max {
		w, h = max, h*max/w
	} else if h > max {
		w, h = w*max/h, max
	}
	w, h = max1(w), max1(h)
	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	// box-filter scale: average the source pixels that fall in each target pixel
	sx, sy := float64(b.Dx())/float64(w), float64(b.Dy())/float64(h)
	rgba := image.NewRGBA(b)
	draw.Draw(rgba, b, src, b.Min, draw.Src)
	for y := 0; y < h; y++ {
		y0, y1 := int(float64(y)*sy), max1(int(float64(y+1)*sy))
		for x := 0; x < w; x++ {
			x0, x1 := int(float64(x)*sx), max1(int(float64(x+1)*sx))
			var r, g, bl, a, n uint32
			for yy := y0; yy < y1 && yy < b.Dy(); yy += 1 + (y1-y0)/4 {
				for xx := x0; xx < x1 && xx < b.Dx(); xx += 1 + (x1-x0)/4 {
					o := rgba.PixOffset(b.Min.X+xx, b.Min.Y+yy)
					p := rgba.Pix[o : o+4]
					r, g, bl, a, n = r+uint32(p[0]), g+uint32(p[1]), bl+uint32(p[2]), a+uint32(p[3]), n+1
				}
			}
			if n == 0 {
				continue
			}
			o := dst.PixOffset(x, y)
			// flatten on dark grey (chat background) so transparent PNGs look right
			alpha := a / n
			mix := func(v uint32) uint8 { return uint8((v/n*alpha + 32*(255-alpha)) / 255) }
			dst.Pix[o], dst.Pix[o+1], dst.Pix[o+2], dst.Pix[o+3] = mix(r), mix(g), mix(bl), 255
		}
	}
	var buf bytes.Buffer
	if jpeg.Encode(&buf, dst, &jpeg.Options{Quality: 82}) == nil && os.WriteFile(file+".thumb.jpg", buf.Bytes(), 0o600) == nil {
		att.Thumb = true
	}
}

func max1(v int) int {
	if v < 1 {
		return 1
	}
	return v
}

func sniffMime(head []byte, name string) string {
	m := http.DetectContentType(head)
	if i := strings.IndexByte(m, ';'); i >= 0 {
		m = m[:i]
	}
	if m == "application/octet-stream" || m == "text/plain" || m == "application/zip" {
		if t := mime.TypeByExtension(strings.ToLower(filepath.Ext(name))); t != "" {
			if i := strings.IndexByte(t, ';'); i >= 0 {
				t = t[:i]
			}
			if !inlineImage[t] { // never trust the extension for something we'd show inline
				m = t
			}
		}
	}
	return m
}

func cleanFileName(n string) string {
	n = filepath.Base(strings.ReplaceAll(n, "\\", "/"))
	n = strings.Map(func(r rune) rune {
		if r < 32 || r == 127 || r == '/' || r == '"' {
			return -1
		}
		return r
	}, n)
	n = strings.TrimSpace(n)
	if n == "" || n == "." || n == ".." {
		n = "file"
	}
	if len(n) > 180 {
		ext := filepath.Ext(n)
		if len(ext) > 20 {
			ext = ""
		}
		n = n[:180-len(ext)] + ext
		for !utf8.ValidString(n) {
			n = n[:len(n)-1]
		}
	}
	return n
}

// GET /api/chat/{id}/files/{att}[?thumb=1][&dl=1]
func (s *Server) handleChatFile(w http.ResponseWriter, r *http.Request) {
	c := s.chat
	c.mu.Lock()
	cv := s.convFor(w, r)
	c.mu.Unlock()
	if cv == nil {
		return
	}
	id := r.PathValue("att")
	if !attIDRe.MatchString(id) {
		http.NotFound(w, r)
		return
	}
	att := c.findAtt(cv, id)
	if att == nil {
		http.NotFound(w, r)
		return
	}
	file := filepath.Join(c.filesDir(cv.ID), id)
	ctype := att.Mime
	if r.URL.Query().Get("thumb") == "1" && att.Thumb {
		file, ctype = file+".thumb.jpg", "image/jpeg"
	}
	f, err := os.Open(file)
	if err != nil {
		httpErr(w, 410, "this file has expired")
		return
	}
	defer f.Close()
	fi, _ := f.Stat()
	h := w.Header()
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Content-Security-Policy", "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; sandbox")
	h.Set("Cache-Control", "private, max-age=31536000, immutable")
	disp := "attachment"
	if inlineImage[ctype] && r.URL.Query().Get("dl") != "1" {
		disp = "inline"
	} else if !inlineImage[ctype] {
		ctype = "application/octet-stream"
	}
	h.Set("Content-Type", ctype)
	h.Set("Content-Disposition", mime.FormatMediaType(disp, map[string]string{"filename": att.Name}))
	http.ServeContent(w, r, "", fi.ModTime(), f)
}

// findAtt looks the attachment up in the conversation log (so only real messages are served).
func (c *Chat) findAtt(cv *Conversation, id string) *Attachment {
	f, err := os.Open(filepath.Join(c.dir, cv.ID+".jsonl"))
	if err != nil {
		return nil
	}
	defer f.Close()
	b, err := io.ReadAll(f)
	if err != nil || !bytes.Contains(b, []byte(`"id":"`+id+`"`)) {
		return nil
	}
	for _, line := range bytes.Split(b, []byte{'\n'}) {
		if !bytes.Contains(line, []byte(id)) {
			continue
		}
		var m Message
		if json.Unmarshal(line, &m) == nil && m.Att != nil && m.Att.ID == id {
			return m.Att
		}
	}
	return nil
}

// ---------------------------------------------------------------- reactions

func (c *Chat) reactionsLocked(conv string) map[int64]map[string][]string {
	if re, ok := c.reacts[conv]; ok {
		return re
	}
	re := map[int64]map[string][]string{}
	if b, err := os.ReadFile(filepath.Join(c.dir, conv+".reactions.json")); err == nil {
		json.Unmarshal(b, &re)
	}
	c.reacts[conv] = re
	return re
}

// validEmoji accepts one emoji (with modifiers / ZWJ sequences), nothing else.
func validEmoji(e string) bool {
	if e == "" || len(e) > 40 || !utf8.ValidString(e) {
		return false
	}
	for _, r := range e {
		if r < 0x80 && r != '#' && r != '*' && !unicode.IsDigit(r) { // keycaps 1️⃣ #️⃣ are fine, letters aren't
			return false
		}
		if unicode.IsSpace(r) || unicode.IsLetter(r) && r < 0x2000 {
			return false
		}
	}
	return utf8.RuneCountInString(e) <= 12
}

// POST /api/chat/{id}/messages/{seq}/react {"emoji": "👍"} — toggles my reaction.
func (s *Server) handleChatReact(w http.ResponseWriter, r *http.Request) {
	var b struct{ Emoji string }
	if !decodeJSON(w, r, &b) {
		return
	}
	if !validEmoji(b.Emoji) {
		httpErr(w, 400, "not an emoji")
		return
	}
	seq, err := strconv.ParseInt(r.PathValue("seq"), 10, 64)
	if err != nil || seq <= 0 {
		httpErr(w, 400, "bad message")
		return
	}
	me := userOf(r)
	c := s.chat
	c.mu.Lock()
	defer c.mu.Unlock()
	cv := s.convFor(w, r)
	if cv == nil {
		return
	}
	if seq > cv.Seq {
		httpErr(w, 404, "no such message")
		return
	}
	re := c.reactionsLocked(cv.ID)
	msg := re[seq]
	if msg == nil {
		msg = map[string][]string{}
	}
	users := msg[b.Emoji]
	found := false
	for _, u := range users {
		found = found || u == me
	}
	if found {
		users = without(users, me)
	} else {
		if len(msg) >= 20 && users == nil {
			httpErr(w, 400, "too many different reactions")
			return
		}
		users = append(users, me)
	}
	if len(users) == 0 {
		delete(msg, b.Emoji)
	} else {
		msg[b.Emoji] = users
	}
	if len(msg) == 0 {
		delete(re, seq)
	} else {
		re[seq] = msg
	}
	if err := c.saveReactionsLocked(cv.ID); err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	ev := map[string]any{"conv": cv.ID, "seq": seq, "reactions": re[seq], "by": me, "emoji": b.Emoji, "added": !found}
	for _, u := range cv.Members {
		c.send(u, "reaction", ev)
	}
	writeJSON(w, 200, ev)
}

func (c *Chat) saveReactionsLocked(conv string) error {
	b, err := json.Marshal(c.reacts[conv])
	if err != nil {
		return err
	}
	f := filepath.Join(c.dir, conv+".reactions.json")
	if err := os.WriteFile(f+".tmp", b, 0o600); err != nil {
		return err
	}
	return os.Rename(f+".tmp", f)
}
