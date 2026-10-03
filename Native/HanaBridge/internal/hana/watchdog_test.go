package hana

import (
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

type watchdogOutcome struct {
	expired                bool
	err                    error
	expiryFinishedAtReturn bool
}

func TestWatchdogThatExpiresFinishesItsExpiryBeforeItReturns(t *testing.T) {
	expiryStarted := make(chan struct{})
	releaseExpiry := make(chan struct{})
	var expiries atomic.Int32
	var expiryFinished atomic.Bool
	expire := func() {
		expiries.Add(1)
		close(expiryStarted)
		<-releaseExpiry
		expiryFinished.Store(true)
	}
	workFailure := errors.New("work failed")
	outcome := make(chan watchdogOutcome, 1)
	go func() {
		expired, err := runUnderWatchdog(time.Millisecond, expire, func() error {
			select {
			case <-expiryStarted:
			case <-time.After(5 * time.Second):
			}
			return workFailure
		})
		outcome <- watchdogOutcome{expired: expired, err: err, expiryFinishedAtReturn: expiryFinished.Load()}
	}()
	awaitSignal(t, expiryStarted, "the watchdog expiry")
	select {
	case <-outcome:
		t.Fatal("the watchdog returned while its expiry was still running")
	case <-time.After(50 * time.Millisecond):
	}
	close(releaseExpiry)
	got := <-outcome
	if !got.expired || !got.expiryFinishedAtReturn || !errors.Is(got.err, workFailure) {
		t.Fatalf("outcome = %+v; want an expiry that finished before the watchdog returned the work's error", got)
	}
	if count := expiries.Load(); count != 1 {
		t.Fatalf("expiry ran %d times; want once", count)
	}
}

func TestWatchdogStoppedBeforeItsDeadlineNeverExpires(t *testing.T) {
	var expiries atomic.Int32
	expired, err := runUnderWatchdog(time.Hour, func() { expiries.Add(1) }, func() error { return nil })
	if expired || err != nil || expiries.Load() != 0 {
		t.Fatalf("expired=%v err=%v expiries=%d; want the work's result and no expiry", expired, err, expiries.Load())
	}
}

func TestDisarmingAWatchdogTwiceKeepsItsFirstAnswer(t *testing.T) {
	var expiries atomic.Int32
	quiet := armWatchdog(time.Hour, func() { expiries.Add(1) })
	quietFirst := quiet.disarm()
	quietSecond := quiet.disarm()
	if quietFirst || quietSecond {
		t.Fatal("a watchdog stopped before its deadline reported an expiry")
	}
	fired := make(chan struct{})
	loud := armWatchdog(time.Millisecond, func() {
		expiries.Add(1)
		close(fired)
	})
	awaitSignal(t, fired, "the watchdog expiry")
	loudFirst := loud.disarm()
	loudSecond := loud.disarm()
	if !loudFirst || !loudSecond {
		t.Fatal("a watchdog that fired reported no expiry")
	}
	if count := expiries.Load(); count != 1 {
		t.Fatalf("expiries = %d; want exactly one", count)
	}
}

func TestWatchdogIsDisarmedWhenTheWorkPanics(t *testing.T) {
	var expiries atomic.Int32
	func() {
		defer func() { _ = recover() }()
		_, _ = runUnderWatchdog(20*time.Millisecond, func() { expiries.Add(1) }, func() error { panic("work panicked") })
	}()
	time.Sleep(60 * time.Millisecond)
	if count := expiries.Load(); count != 0 {
		t.Fatalf("a watchdog whose work panicked expired %d times", count)
	}
}
