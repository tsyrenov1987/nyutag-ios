// Нютаг. Релей звонков. Слушает только приватную сеть: снаружи к нему ведёт nginx ядра, который пропускает
// лишь запросы с действующим токеном Matrix. Адреса и слоты в журнал не пишутся, только счётчики.

package main

import (
	"encoding/hex"
	"errors"
	"flag"
	"io"
	"net"
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
	call, peers := h.join(slot, m)
	if call == 0 {
		conn.write(opClose, []byte{0x03, 0xF0}) // 1008: место занято
		logf("звонок: место занято")
		return
	}
	started := time.Now()
	logf("звонок #%d: участник вошёл, в слоте %d", call, peers)
	var writeErr error
	done := make(chan struct{})
	go func() {
		defer close(done)
		for o := range m.out {
			if err := conn.write(o.op, o.data); err != nil {
				writeErr = err
				conn.Close()
				for range m.out {
				}
				return
			}
		}
	}()
	// Выброшенное из очереди — раз в 10 с, пока растёт: видно, когда у получателя проседал канал.
	watch := make(chan struct{})
	go func() {
		var seen int64
		tick := time.NewTicker(10 * time.Second)
		defer tick.Stop()
		for {
			select {
			case <-watch:
				return
			case <-tick.C:
				if d := m.dropped.Load(); d > seen {
					logf("звонок #%d: получателю выброшено %d кадров за 10 с (очередь полна)", call, d-seen)
					seen = d
				}
			}
		}
	}()
	deadline := time.Now().Add(maxLifetime)
	var readErr error
	for {
		next := time.Now().Add(idleTimeout)
		if next.After(deadline) {
			next = deadline
		}
		conn.raw.SetReadDeadline(next)
		op, data, err := conn.ReadMessage()
		if err != nil {
			readErr = err
			break
		}
		if op == opBinary {
			m.in.Add(1)
			h.forward(slot, m, data)
		}
	}
	h.leave(slot, m)
	m.stop()
	<-done
	close(watch)
	logf("звонок #%d: участник вышел через %s (%s); принято %d, отдано в очередь %d, выброшено %d",
		call, time.Since(started).Round(time.Second), leaveReason(readErr, writeErr), m.in.Load(), m.queued.Load(), m.dropped.Load())
}

// leaveReason — почему участник ушёл, коротко для журнала.
func leaveReason(readErr, writeErr error) string {
	var ne net.Error
	switch {
	case errors.Is(readErr, errClosed):
		return "закрыл сам"
	case errors.As(readErr, &ne) && ne.Timeout():
		return "тишина 45 с"
	case writeErr != nil:
		return "не принимал: " + writeErr.Error()
	case errors.Is(readErr, io.EOF) || errors.Is(readErr, io.ErrUnexpectedEOF):
		return "соединение оборвано"
	case readErr != nil:
		return readErr.Error()
	}
	return "срок 6 ч"
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
