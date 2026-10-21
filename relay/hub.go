// Нютаг. Релей звонков: участники одного звонка встречаются в «слоте» и получают друг от друга кадры как есть.
// Содержимое релей не читает: кадры зашифрованы ключом, который знают только участники. Слот — производная
// от этого ключа, по нему нельзя узнать ни комнату, ни людей.

package main

import (
	"encoding/json"
	"log"
	"sync"
)

type member struct {
	conn *wsConn
	out  chan outbound
	once sync.Once
}

type outbound struct {
	op   byte
	data []byte
}

type hub struct {
	mu       sync.Mutex
	slots    map[string][]*member
	maxSlots int
	maxPeers int
}

func newHub(maxSlots, maxPeers int) *hub {
	return &hub{slots: map[string][]*member{}, maxSlots: maxSlots, maxPeers: maxPeers}
}

// join добавляет участника; false — слот полон или слотов слишком много.
func (h *hub) join(slot string, m *member) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	peers, exists := h.slots[slot]
	if !exists && len(h.slots) >= h.maxSlots {
		return false
	}
	if len(peers) >= h.maxPeers {
		return false
	}
	h.slots[slot] = append(peers, m)
	h.announceLocked(slot)
	return true
}

func (h *hub) leave(slot string, m *member) {
	h.mu.Lock()
	defer h.mu.Unlock()
	peers := h.slots[slot]
	for i, p := range peers {
		if p == m {
			peers = append(peers[:i:i], peers[i+1:]...)
			break
		}
	}
	if len(peers) == 0 {
		delete(h.slots, slot)
		return
	}
	h.slots[slot] = peers
	h.announceLocked(slot)
}

// announceLocked сообщает всем в слоте, сколько их сейчас: по этому клиент понимает, что собеседник на связи.
func (h *hub) announceLocked(slot string) {
	peers := h.slots[slot]
	text, _ := json.Marshal(map[string]int{"peers": len(peers)})
	for _, p := range peers {
		p.offer(outbound{op: opText, data: text})
	}
}

// forward рассылает кадр остальным участникам слота. Очередь медленного получателя переполнена — кадр ему
// не достаётся: для живого звука старый кадр хуже потерянного.
func (h *hub) forward(slot string, from *member, data []byte) {
	h.mu.Lock()
	peers := h.slots[slot]
	targets := make([]*member, 0, len(peers))
	for _, p := range peers {
		if p != from {
			targets = append(targets, p)
		}
	}
	h.mu.Unlock()
	for _, p := range targets {
		p.offer(outbound{op: opBinary, data: data})
	}
}

func (m *member) offer(o outbound) {
	select {
	case m.out <- o:
	default:
	}
}

func (m *member) stop() {
	m.once.Do(func() { close(m.out) })
}

func (h *hub) stats() (slots, peers int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, p := range h.slots {
		peers += len(p)
	}
	return len(h.slots), peers
}

func logf(format string, args ...any) { log.Printf(format, args...) }
