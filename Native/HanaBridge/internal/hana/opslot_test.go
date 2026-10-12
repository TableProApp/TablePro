package hana

import (
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type recordingInterrupter struct {
	mu      sync.Mutex
	reasons []stopReason
	release chan struct{}
}

func newRecordingInterrupter() *recordingInterrupter {
	return &recordingInterrupter{}
}

func newBlockingInterrupter() *recordingInterrupter {
	return &recordingInterrupter{release: make(chan struct{})}
}

func (r *recordingInterrupter) interrupt(reason stopReason) {
	r.mu.Lock()
	r.reasons = append(r.reasons, reason)
	release := r.release
	r.mu.Unlock()
	if release != nil {
		<-release
	}
}

func (r *recordingInterrupter) calls() []stopReason {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]stopReason(nil), r.reasons...)
}

func awaitSignal(t *testing.T, signal <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(5 * time.Second):
		t.Fatalf("%s did not happen within 5 seconds", what)
	}
}

func waitFor(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal("condition not met within 5 seconds")
		}
		time.Sleep(time.Millisecond)
	}
}

func TestQueuedOperationCancelledBeforeItArrivesIsDroppedWithoutInterrupting(t *testing.T) {
	slot := newOperationSlot(0, nil)
	interrupter := newRecordingInterrupter()
	slot.cancel(5)
	op, err := slot.begin(5, interrupter.interrupt)
	if !errors.Is(err, errOperationDroppedWhileQueued) || op != nil {
		t.Fatalf("begin(5) = %v, %v; want a dropped operation", op, err)
	}
	if calls := interrupter.calls(); len(calls) != 0 {
		t.Fatalf("a dropped operation reached the interrupter: %v", calls)
	}
	next, err := slot.begin(6, interrupter.interrupt)
	if err != nil {
		t.Fatalf("begin(6) after a dropped operation: %v", err)
	}
	if next.stopped() {
		t.Fatal("the operation after a dropped one started stopped")
	}
	slot.finish(next)
}

func TestCancellingAFinishedOperationIsIgnored(t *testing.T) {
	slot := newOperationSlot(0, nil)
	interrupter := newRecordingInterrupter()
	op, err := slot.begin(3, interrupter.interrupt)
	if err != nil {
		t.Fatal(err)
	}
	slot.finish(op)
	slot.cancel(3)
	next, err := slot.begin(4, interrupter.interrupt)
	if err != nil {
		t.Fatal(err)
	}
	defer slot.finish(next)
	if next.stopped() {
		t.Fatal("cancelling a finished operation stopped the next one")
	}
	if calls := interrupter.calls(); len(calls) != 0 {
		t.Fatalf("cancelling a finished operation interrupted: %v", calls)
	}
}

func TestOperationZeroTargetsTheRunningOperation(t *testing.T) {
	slot := newOperationSlot(0, nil)
	interrupter := newRecordingInterrupter()
	op, err := slot.begin(7, interrupter.interrupt)
	if err != nil {
		t.Fatal(err)
	}
	slot.cancel(0)
	slot.finish(op)
	if !op.stopped() || op.currentStopReason() != stopCancelled {
		t.Fatalf("stopped=%v reason=%v; want a cancelled operation", op.stopped(), op.currentStopReason())
	}
	if calls := interrupter.calls(); len(calls) != 1 || calls[0] != stopCancelled {
		t.Fatalf("interrupter calls = %v; want one cancellation", calls)
	}
}

func TestOperationZeroWithNothingRunningDoesNothing(t *testing.T) {
	slot := newOperationSlot(0, nil)
	interrupter := newRecordingInterrupter()
	slot.cancel(0)
	op, err := slot.begin(1, interrupter.interrupt)
	if err != nil {
		t.Fatal(err)
	}
	defer slot.finish(op)
	if op.stopped() {
		t.Fatal("a cancel of operation 0 with nothing running stopped a later operation")
	}
}

func TestCancellingTheRunningOperationByIDInterruptsOnlyThatOperation(t *testing.T) {
	slot := newOperationSlot(0, nil)
	interrupter := newRecordingInterrupter()
	op, err := slot.begin(9, interrupter.interrupt)
	if err != nil {
		t.Fatal(err)
	}
	slot.cancel(8)
	if op.stopped() {
		t.Fatal("cancelling an older operation stopped the running one")
	}
	slot.cancel(9)
	slot.cancel(9)
	slot.finish(op)
	if calls := interrupter.calls(); len(calls) != 1 {
		t.Fatalf("interrupter calls = %v; want exactly one", calls)
	}
}

func TestRunningOperationDoesNotFinishUntilTheInFlightCancelSettles(t *testing.T) {
	slot := newOperationSlot(0, nil)
	interrupter := newBlockingInterrupter()
	op, err := slot.begin(1, interrupter.interrupt)
	if err != nil {
		t.Fatal(err)
	}
	slot.cancel(1)
	waitFor(t, func() bool { return len(interrupter.calls()) == 1 })

	var finished atomic.Bool
	finishDone := make(chan struct{})
	go func() {
		slot.finish(op)
		finished.Store(true)
		close(finishDone)
	}()
	var nextStarted atomic.Bool
	nextDone := make(chan *operation)
	go func() {
		next, beginErr := slot.begin(2, interrupter.interrupt)
		if beginErr != nil {
			t.Error(beginErr)
		}
		nextStarted.Store(true)
		nextDone <- next
	}()

	time.Sleep(100 * time.Millisecond)
	if finished.Load() {
		t.Fatal("the operation finished while its cancel was still in flight")
	}
	if nextStarted.Load() {
		t.Fatal("the next operation started while a cancel was still in flight")
	}

	close(interrupter.release)
	<-finishDone
	next := <-nextDone
	if next.stopped() {
		t.Fatal("the in-flight cancel reached the next operation")
	}
	slot.finish(next)
}

func TestTimeoutStopsTheOperationAndTheFirstCauseWins(t *testing.T) {
	slot := newOperationSlot(0, nil)
	interrupter := newRecordingInterrupter()
	op, err := slot.begin(1, interrupter.interrupt)
	if err != nil {
		t.Fatal(err)
	}
	op.stopAfter(10 * time.Millisecond)
	waitFor(t, op.stopped)
	slot.cancel(1)
	slot.finish(op)
	if op.currentStopReason() != stopTimedOut {
		t.Fatalf("reason = %v; want the timeout that fired first", op.currentStopReason())
	}
	if calls := interrupter.calls(); len(calls) != 1 || calls[0] != stopTimedOut {
		t.Fatalf("interrupter calls = %v; want one timeout", calls)
	}
}

func TestSettledOperationIgnoresLaterCancelsAndTimeouts(t *testing.T) {
	slot := newOperationSlot(0, nil)
	interrupter := newRecordingInterrupter()
	op, err := slot.begin(1, interrupter.interrupt)
	if err != nil {
		t.Fatal(err)
	}
	op.stopAfter(5 * time.Millisecond)
	op.settle()
	slot.cancel(1)
	time.Sleep(20 * time.Millisecond)
	slot.finish(op)
	if op.stopped() || len(interrupter.calls()) != 0 {
		t.Fatalf("a settled operation was stopped: stopped=%v calls=%v", op.stopped(), interrupter.calls())
	}
}

func TestOperationsRunOneAtATime(t *testing.T) {
	slot := newOperationSlot(0, nil)
	first, err := slot.begin(1, nil)
	if err != nil {
		t.Fatal(err)
	}
	var secondStarted atomic.Bool
	secondDone := make(chan *operation)
	go func() {
		second, beginErr := slot.begin(2, nil)
		if beginErr != nil {
			t.Error(beginErr)
		}
		secondStarted.Store(true)
		secondDone <- second
	}()
	time.Sleep(50 * time.Millisecond)
	if secondStarted.Load() {
		t.Fatal("a second operation started while the first was running")
	}
	slot.finish(first)
	slot.finish(<-secondDone)
}

func TestCancelForAWaitingOperationDropsItWhenItArrives(t *testing.T) {
	slot := newOperationSlot(0, nil)
	interrupter := newRecordingInterrupter()
	first, err := slot.begin(1, interrupter.interrupt)
	if err != nil {
		t.Fatal(err)
	}
	result := make(chan error)
	go func() {
		_, beginErr := slot.begin(2, interrupter.interrupt)
		result <- beginErr
	}()
	time.Sleep(20 * time.Millisecond)
	slot.cancel(2)
	if first.stopped() {
		t.Fatal("cancelling the waiting operation stopped the running one")
	}
	slot.finish(first)
	if err := <-result; !errors.Is(err, errOperationDroppedWhileQueued) {
		t.Fatalf("waiting operation began with %v; want it dropped", err)
	}
}

func TestEarlyCancellationsOlderThanAStartedOperationAreForgotten(t *testing.T) {
	slot := newOperationSlot(0, nil)
	slot.cancel(10)
	op, err := slot.begin(11, nil)
	if err != nil {
		t.Fatalf("begin(11) = %v; an unrelated early cancel dropped it", err)
	}
	slot.finish(op)
	if len(slot.cancelledBeforeStart) != 0 {
		t.Fatalf("stale early cancellations kept: %v", slot.cancelledBeforeStart)
	}
}

func TestClosingTheSlotStopsTheRunningOperationAndRefusesNewOnes(t *testing.T) {
	slot := newOperationSlot(0, nil)
	interrupter := newRecordingInterrupter()
	op, err := slot.begin(1, interrupter.interrupt)
	if err != nil {
		t.Fatal(err)
	}
	waiting := make(chan error)
	go func() {
		_, beginErr := slot.begin(2, nil)
		waiting <- beginErr
	}()
	time.Sleep(20 * time.Millisecond)
	slot.close()
	if err := <-waiting; !errors.Is(err, errSlotClosed) {
		t.Fatalf("waiting operation = %v; want the closed slot error", err)
	}
	slot.finish(op)
	if op.currentStopReason() != stopClosed {
		t.Fatalf("reason = %v; want closed", op.currentStopReason())
	}
	if calls := interrupter.calls(); len(calls) != 1 || calls[0] != stopClosed {
		t.Fatalf("interrupter calls = %v; want one close", calls)
	}
	if _, err := slot.begin(3, nil); !errors.Is(err, errSlotClosed) {
		t.Fatalf("begin after close = %v; want the closed slot error", err)
	}
	slot.cancel(3)
}

func TestForcedSeverThatFiredBeforeSettleFinishesBeforeTheSlotIsReleased(t *testing.T) {
	severStarted := make(chan struct{})
	releaseSever := make(chan struct{})
	var severs atomic.Int32
	var severFinished atomic.Bool
	slot := newOperationSlot(time.Millisecond, func() {
		severs.Add(1)
		close(severStarted)
		<-releaseSever
		severFinished.Store(true)
	})
	op, err := slot.begin(1, nil)
	if err != nil {
		t.Fatal(err)
	}
	slot.cancel(1)
	awaitSignal(t, severStarted, "the forced sever")

	finished := make(chan bool, 1)
	go func() {
		slot.finish(op)
		finished <- severFinished.Load()
	}()
	nextBegan := make(chan bool, 1)
	go func() {
		next, beginErr := slot.begin(2, nil)
		if beginErr != nil {
			t.Error(beginErr)
			nextBegan <- false
			return
		}
		nextBegan <- severFinished.Load()
		slot.finish(next)
	}()

	select {
	case <-finished:
		t.Fatal("the slot released the operation while its forced sever was still running")
	case <-nextBegan:
		t.Fatal("the next operation began while the forced sever was still running")
	case <-time.After(50 * time.Millisecond):
	}
	close(releaseSever)
	if !<-finished {
		t.Fatal("finish returned before the forced sever finished")
	}
	if !<-nextBegan {
		t.Fatal("the next operation began before the forced sever finished")
	}
	if count := severs.Load(); count != 1 {
		t.Fatalf("forced sever ran %d times; want once", count)
	}
}

func TestATimeoutArmsTheForcedSever(t *testing.T) {
	severed := make(chan struct{})
	slot := newOperationSlot(time.Millisecond, func() { close(severed) })
	op, err := slot.begin(1, nil)
	if err != nil {
		t.Fatal(err)
	}
	op.stopAfter(time.Millisecond)
	awaitSignal(t, severed, "the forced sever of a timed-out operation")
	slot.finish(op)
}

func TestSettlingInsideTheGraceNeverSevers(t *testing.T) {
	var severs atomic.Int32
	slot := newOperationSlot(50*time.Millisecond, func() { severs.Add(1) })
	stopped, err := slot.begin(1, nil)
	if err != nil {
		t.Fatal(err)
	}
	slot.cancel(1)
	slot.finish(stopped)
	unstopped, err := slot.begin(2, nil)
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	slot.finish(unstopped)
	if count := severs.Load(); count != 0 {
		t.Fatalf("forced sever ran %d times; want none", count)
	}
}

func TestClosingTheSlotArmsNoForcedSever(t *testing.T) {
	var severs atomic.Int32
	slot := newOperationSlot(time.Millisecond, func() { severs.Add(1) })
	op, err := slot.begin(1, nil)
	if err != nil {
		t.Fatal(err)
	}
	slot.close()
	time.Sleep(30 * time.Millisecond)
	slot.finish(op)
	if count := severs.Load(); count != 0 {
		t.Fatalf("closing the slot armed a forced sever that ran %d times", count)
	}
}
