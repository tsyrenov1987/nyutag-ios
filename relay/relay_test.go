package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type testClient struct {
	c net.Conn
	r *bufio.Reader
}

func dial(t *testing.T, srv *httptest.Server, slot string) *testClient {
	t.Helper()
	c, err := net.Dial("tcp", strings.TrimPrefix(srv.URL, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	key := "dGhlIHNhbXBsZSBub25jZQ=="
	req := "GET /_nyutag/relay/v1?slot=" + slot + " HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\n" +
		"Sec-WebSocket-Key: " + key + "\r\nSec-WebSocket-Version: 13\r\n\r\n"
	c.Write([]byte(req))
	r := bufio.NewReader(c)
	resp, err := http.ReadResponse(r, nil)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != 101 || resp.Header.Get("Sec-WebSocket-Accept") != "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" {
		t.Fatalf("handshake: %d %q", resp.StatusCode, resp.Header.Get("Sec-WebSocket-Accept"))
	}
	return &testClient{c: c, r: r}
}

func (tc *testClient) send(op byte, fin bool, payload []byte) {
	b := byte(op)
	if fin {
		b |= 0x80
	}
	head := []byte{b}
	n := len(payload)
	switch {
	case n < 126:
		head = append(head, 0x80|byte(n))
	case n <= 0xFFFF:
		head = append(head, 0x80|126, byte(n>>8), byte(n))
	default:
		head = append(head, 0x80|127)
		head = binary.BigEndian.AppendUint64(head, uint64(n))
	}
	mask := []byte{1, 2, 3, 4}
	masked := make([]byte, n)
	for i := range payload {
		masked[i] = payload[i] ^ mask[i%4]
	}
	tc.c.Write(append(append(head, mask...), masked...))
}

func (tc *testClient) read(t *testing.T) (byte, []byte) {
	t.Helper()
	tc.c.SetReadDeadline(time.Now().Add(2 * time.Second))
	var h [2]byte
	if _, err := io.ReadFull(tc.r, h[:]); err != nil {
		t.Fatal(err)
	}
	n := int(h[1] & 0x7F)
	if n == 126 {
		var e [2]byte
		io.ReadFull(tc.r, e[:])
		n = int(binary.BigEndian.Uint16(e[:]))
	} else if n == 127 {
		var e [8]byte
		io.ReadFull(tc.r, e[:])
		n = int(binary.BigEndian.Uint64(e[:]))
	}
	p := make([]byte, n)
	io.ReadFull(tc.r, p)
	return h[0] & 0x0F, p
}

func newTestServer(maxPeers int) *httptest.Server {
	h := newHub(10, maxPeers)
	mux := http.NewServeMux()
	mux.HandleFunc("/_nyutag/relay/v1", h.serve)
	return httptest.NewServer(mux)
}

const slotA = "00112233445566778899aabbccddeeff"

func TestPairForwardsBinaryBothWays(t *testing.T) {
	srv := newTestServer(2)
	defer srv.Close()
	a := dial(t, srv, slotA)
	if op, p := a.read(t); op != opText || string(p) != `{"peers":1}` {
		t.Fatalf("a first: %d %s", op, p)
	}
	b := dial(t, srv, slotA)
	a.read(t)
	b.read(t)
	a.send(opBinary, true, []byte("кадр от a"))
	if op, p := b.read(t); op != opBinary || string(p) != "кадр от a" {
		t.Fatalf("b got %d %q", op, p)
	}
	// Большой кадр по частям: собирается целиком.
	big := bytes.Repeat([]byte{7}, 70000)
	b.send(opBinary, false, big[:30000])
	b.send(opPing, true, []byte("p"))
	b.send(opContinuation, true, big[30000:])
	if op, p := b.read(t); op != opPong || string(p) != "p" {
		t.Fatalf("pong: %d %q", op, p)
	}
	if op, p := a.read(t); op != opBinary || !bytes.Equal(p, big) {
		t.Fatalf("a big: %d len %d", op, len(p))
	}
	// Третьему места нет.
	c := dial(t, srv, slotA)
	if op, _ := c.read(t); op != opClose {
		t.Fatalf("third should be closed, got %d", op)
	}
	// Ушёл b — a узнаёт.
	b.c.Close()
	if op, p := a.read(t); op != opText || string(p) != `{"peers":1}` {
		t.Fatalf("after leave: %d %s", op, p)
	}
}

func TestOtherSlotIsolated(t *testing.T) {
	srv := newTestServer(2)
	defer srv.Close()
	a := dial(t, srv, slotA)
	a.read(t)
	b := dial(t, srv, "ffeeddccbbaa99887766554433221100")
	b.read(t)
	a.send(opBinary, true, []byte("x"))
	b.c.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	var h [1]byte
	if _, err := b.r.Read(h[:]); err == nil {
		t.Fatal("frame leaked to other slot")
	}
}

func TestBadSlotRejected(t *testing.T) {
	srv := newTestServer(2)
	defer srv.Close()
	resp, err := http.Get(srv.URL + "/_nyutag/relay/v1?slot=xyz")
	if err != nil || resp.StatusCode != 400 {
		t.Fatalf("got %v %v", resp, err)
	}
}
