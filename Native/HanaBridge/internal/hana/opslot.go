package hana

import (
	"errors"
	"sync"
	"sync/atomic"
	"time"
)

type stopReason uint8

const (
	stopNone stopReason = iota
	stopCancelled
	stopTimedOut
	stopClosed
)

var (
	errOperationDroppedWhileQueued = errors.New("operation cancelled before it started")
	errOperationStopped            = errors.New("operation stopped")
	errSlotClosed                  = errors.New("session closed")
)

type interruptFunc func(reason stopReason)

type operationSlot struct {
	mu                   sync.Mutex
	idle                 *sync.Cond
	closed               bool
	lastStarted          uint64
	running              *operation
	cancelledBeforeStart map[uint64]struct{}
	severGrace           time.Duration
	sever                func()
}

func newOperationSlot(severGrace time.Duration, sever func()) *operationSlot {
	slot := &operationSlot{cancelledBeforeStart: map[uint64]struct{}{}, severGrace: severGrace, sever: sever}
	slot.idle = sync.NewCond(&slot.mu)
	return slot
}

func (s *operationSlot) begin(id uint64, interrupt interruptFunc) (*operation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for s.running != nil && !s.closed {
		s.idle.Wait()
	}
	if s.closed {
		return nil, errSlotClosed
	}
	_, cancelledEarly := s.cancelledBeforeStart[id]
	s.forgetCancellationsThrough(id)
	if id > s.lastStarted {
		s.lastStarted = id
	}
	if cancelledEarly && id != 0 {
		return nil, errOperationDroppedWhileQueued
	}
	op := &operation{id: id, interrupt: interrupt, severGrace: s.severGrace, sever: s.sever}
	s.running = op
	return op, nil
}

func (s *operationSlot) forgetCancellationsThrough(id uint64) {
	for pending := range s.cancelledBeforeStart {
		if pending <= id {
			delete(s.cancelledBeforeStart, pending)
		}
	}
}

func (s *operationSlot) cancel(id uint64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	if s.running != nil && (id == 0 || id == s.running.id) {
		s.running.requestStop(stopCancelled)
		return
	}
	if id > s.lastStarted {
		s.cancelledBeforeStart[id] = struct{}{}
	}
}

func (s *operationSlot) finish(op *operation) {
	op.settle()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.running == op {
		s.running = nil
	}
	s.idle.Broadcast()
}

func (s *operationSlot) close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closed = true
	if s.running != nil {
		s.running.requestStop(stopClosed)
	}
	s.idle.Broadcast()
}

type operation struct {
	id         uint64
	interrupt  interruptFunc
	severGrace time.Duration
	sever      func()
	stopFlag   atomic.Bool

	mu          sync.Mutex
	reason      stopReason
	settled     bool
	deadline    *time.Timer
	forcedSever *watchdog
	inFlight    sync.WaitGroup
}

func (o *operation) requestStop(reason stopReason) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.settled || o.reason != stopNone {
		return
	}
	o.reason = reason
	o.stopFlag.Store(true)
	if reason != stopClosed && o.sever != nil {
		o.forcedSever = armWatchdog(o.severGrace, o.sever)
	}
	if o.interrupt == nil {
		return
	}
	o.inFlight.Add(1)
	go func() {
		defer o.inFlight.Done()
		o.interrupt(reason)
	}()
}

func (o *operation) stopAfter(timeout time.Duration) {
	if timeout <= 0 {
		return
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.settled {
		return
	}
	o.deadline = time.AfterFunc(timeout, func() { o.requestStop(stopTimedOut) })
}

func (o *operation) settle() {
	o.mu.Lock()
	o.settled = true
	if o.deadline != nil {
		o.deadline.Stop()
	}
	forcedSever := o.forcedSever
	o.mu.Unlock()
	if forcedSever != nil {
		forcedSever.disarm()
	}
	o.inFlight.Wait()
}

func (o *operation) stopped() bool {
	return o.stopFlag.Load()
}

func (o *operation) currentStopReason() stopReason {
	if o == nil {
		return stopNone
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.reason
}
