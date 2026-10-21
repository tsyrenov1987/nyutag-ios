// Нютаг. Релей звонков. Слушает только приватную сеть: снаружи к нему ведёт nginx ядра, который пропускает
// лишь запросы с действующим токеном Matrix. Адреса и слоты в журнал не пишутся, только счётчики.

package main

import (
	"encoding/hex"
	"flag"
	"net/http"
	"time"
)

const (
	maxMessage  = 256 << 10
	idleTimeout = 45 * time.Second
	maxLifetime = 6 * time.Hour
)

func validSlot(s string) bool {
	if len(s) != 32 {
		return false
	}
	_, err := hex.DecodeString(s)
	return err == nil
}

func (h *hub) serve(w http.ResponseWriter, r *http.Request) {
	slot := r.URL.Query().Get("slot")
	if !validSlot(slot) {
		http.Error(w, "bad slot", http.StatusBadRequest)
		return
	}
	conn, err := upgrade(w, r, maxMessage)
	if err != nil {
		return
	}
	defer conn.Close()
	m := &member{conn: conn, out: make(chan outbound, 64)}
	if !h.join(slot, m) {
		conn.write(opClose, []byte{0x03, 0xF0}) // 1008: место занято
		return
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		for o := range m.out {
			if conn.write(o.op, o.data) != nil {
				conn.Close()
				for range m.out {
				}
				return
			}
		}
	}()
	deadline := time.Now().Add(maxLifetime)
	for {
		next := time.Now().Add(idleTimeout)
		if next.After(deadline) {
			next = deadline
		}
		conn.raw.SetReadDeadline(next)
		op, data, err := conn.ReadMessage()
		if err != nil {
			break
		}
		if op == opBinary {
			h.forward(slot, m, data)
		}
	}
	h.leave(slot, m)
	m.stop()
	<-done
}

func main() {
	listen := flag.String("listen", "10.77.1.1:7890", "адрес приватной сети")
	flag.Parse()
	h := newHub(2000, 8)
	mux := http.NewServeMux()
	mux.HandleFunc("/_nyutag/relay/v1", h.serve)
	mux.HandleFunc("/_nyutag/relay/health", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok\n")) })
	go func() {
		for range time.Tick(10 * time.Minute) {
			if s, p := h.stats(); s > 0 {
				logf("звонков %d, участников %d", s, p)
			}
		}
	}()
	srv := &http.Server{Addr: *listen, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	logf("релей слушает %s", *listen)
	if err := srv.ListenAndServe(); err != nil {
		logf("релей остановлен: %v", err)
	}
}
