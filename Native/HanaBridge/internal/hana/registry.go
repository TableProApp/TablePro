package hana

import (
	"sync"
)

type sessionRegistry struct {
	mu       sync.Mutex
	lastID   uint64
	sessions map[uint64]*session
}

func newSessionRegistry() *sessionRegistry {
	return &sessionRegistry{sessions: map[uint64]*session{}}
}

func (r *sessionRegistry) register(entry *session) uint64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lastID++
	r.sessions[r.lastID] = entry
	return r.lastID
}

func (r *sessionRegistry) lookup(id uint64) (*session, *bridgeError) {
	r.mu.Lock()
	defer r.mu.Unlock()
	entry, ok := r.sessions[id]
	if !ok {
		return nil, closedError()
	}
	return entry, nil
}

func (r *sessionRegistry) remove(id uint64) (*session, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	entry, ok := r.sessions[id]
	if ok {
		delete(r.sessions, id)
	}
	return entry, ok
}

func (r *sessionRegistry) removeAll() []*session {
	r.mu.Lock()
	defer r.mu.Unlock()
	entries := make([]*session, 0, len(r.sessions))
	for _, entry := range r.sessions {
		entries = append(entries, entry)
	}
	clear(r.sessions)
	return entries
}
