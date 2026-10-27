// Нютаг. Релей звонков: минимальный WebSocket (RFC 6455) на стандартной библиотеке Go.
// Нужно немного: рукопожатие, чтение кадров с маской, сборка продолжений, ping/pong, close.
// Сервер пишет кадры без маски.

package main

import (
	"bufio"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

const wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

const (
	opContinuation = 0x0
	opText         = 0x1
	opBinary       = 0x2
	opClose        = 0x8
	opPing         = 0x9
	opPong         = 0xA
)

var errTooBig = errors.New("message too big")

// errClosed — участник сам закрыл соединение кадром close (обычное завершение).
var errClosed = errors.New("close frame")

type wsConn struct {
	raw     net.Conn
	r       *bufio.Reader
	writeMu sync.Mutex
	maxSize int
}

func acceptKey(key string) string {
	h := sha1.Sum([]byte(key + wsGUID))
	return base64.StdEncoding.EncodeToString(h[:])
}

func headerHas(h http.Header, name, token string) bool {
	for _, v := range h.Values(name) {
		for _, part := range strings.Split(v, ",") {
			if strings.EqualFold(strings.TrimSpace(part), token) {
				return true
			}
		}
	}
	return false
}

// upgrade переводит HTTP-запрос в WebSocket. При ошибке ответ клиенту уже отправлен.
func upgrade(w http.ResponseWriter, r *http.Request, maxSize int) (*wsConn, error) {
	key := r.Header.Get("Sec-WebSocket-Key")
	if r.Method != http.MethodGet || !headerHas(r.Header, "Connection", "upgrade") ||
		!headerHas(r.Header, "Upgrade", "websocket") || r.Header.Get("Sec-WebSocket-Version") != "13" || key == "" {
		http.Error(w, "websocket only", http.StatusBadRequest)
		return nil, errors.New("not a websocket request")
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "no hijack", http.StatusInternalServerError)
		return nil, errors.New("no hijack")
	}
	raw, rw, err := hj.Hijack()
	if err != nil {
		return nil, err
	}
	resp := "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: " + acceptKey(key) + "\r\n\r\n"
	raw.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if _, err := raw.Write([]byte(resp)); err != nil {
		raw.Close()
		return nil, err
	}
	raw.SetWriteDeadline(time.Time{})
	return &wsConn{raw: raw, r: rw.Reader, maxSize: maxSize}, nil
}

// readFrame читает один кадр и снимает маску.
func (c *wsConn) readFrame() (fin bool, op byte, payload []byte, err error) {
	var head [2]byte
	if _, err = io.ReadFull(c.r, head[:]); err != nil {
		return
	}
	fin = head[0]&0x80 != 0
	op = head[0] & 0x0F
	masked := head[1]&0x80 != 0
	length := uint64(head[1] & 0x7F)
	switch length {
	case 126:
		var ext [2]byte
		if _, err = io.ReadFull(c.r, ext[:]); err != nil {
			return
		}
		length = uint64(binary.BigEndian.Uint16(ext[:]))
	case 127:
		var ext [8]byte
		if _, err = io.ReadFull(c.r, ext[:]); err != nil {
			return
		}
		length = binary.BigEndian.Uint64(ext[:])
	}
	if length > uint64(c.maxSize) {
		err = errTooBig
		return
	}
	if !masked {
		// Клиент обязан маскировать кадры.
		err = errors.New("unmasked client frame")
		return
	}
	var mask [4]byte
	if _, err = io.ReadFull(c.r, mask[:]); err != nil {
		return
	}
	payload = make([]byte, length)
	if _, err = io.ReadFull(c.r, payload); err != nil {
		return
	}
	for i := range payload {
		payload[i] ^= mask[i%4]
	}
	return
}

// ReadMessage возвращает следующее сообщение с данными; ping отвечает сам, close возвращает io.EOF.
func (c *wsConn) ReadMessage() (op byte, data []byte, err error) {
	var buf []byte
	var msgOp byte
	for {
		fin, frameOp, payload, err := c.readFrame()
		if err != nil {
			return 0, nil, err
		}
		switch frameOp {
		case opPing:
			if err := c.write(opPong, payload); err != nil {
				return 0, nil, err
			}
			continue
		case opPong:
			continue
		case opClose:
			c.write(opClose, nil)
			return 0, nil, errClosed
		case opText, opBinary:
			if buf != nil {
				return 0, nil, errors.New("new message inside fragmented one")
			}
			msgOp = frameOp
			buf = payload
		case opContinuation:
			if buf == nil {
				return 0, nil, errors.New("continuation without start")
			}
			if len(buf)+len(payload) > c.maxSize {
				return 0, nil, errTooBig
			}
			buf = append(buf, payload...)
		default:
			return 0, nil, errors.New("unknown opcode")
		}
		if fin {
			return msgOp, buf, nil
		}
	}
}

func (c *wsConn) write(op byte, payload []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	head := make([]byte, 0, 10)
	head = append(head, 0x80|op)
	switch n := len(payload); {
	case n < 126:
		head = append(head, byte(n))
	case n <= 0xFFFF:
		head = append(head, 126, byte(n>>8), byte(n))
	default:
		head = append(head, 127)
		head = binary.BigEndian.AppendUint64(head, uint64(n))
	}
	c.raw.SetWriteDeadline(time.Now().Add(5 * time.Second))
	defer c.raw.SetWriteDeadline(time.Time{})
	if _, err := c.raw.Write(append(head, payload...)); err != nil {
		return err
	}
	return nil
}

func (c *wsConn) Close() error { return c.raw.Close() }
