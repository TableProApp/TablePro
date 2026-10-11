package hana

import (
	"sync"
	"time"
)

type watchdog struct {
	timer    *time.Timer
	expire   func()
	expiry   sync.Once
	disarmed sync.Once
	expired  bool
}

func armWatchdog(deadline time.Duration, expire func()) *watchdog {
	dog := &watchdog{expire: expire}
	dog.timer = time.AfterFunc(deadline, dog.fire)
	return dog
}

func (w *watchdog) fire() {
	w.expiry.Do(w.expire)
}

func (w *watchdog) disarm() bool {
	w.disarmed.Do(func() {
		if w.timer.Stop() {
			return
		}
		w.expired = true
		w.fire()
	})
	return w.expired
}

func runUnderWatchdog(deadline time.Duration, expire func(), work func() error) (expired bool, err error) {
	dog := armWatchdog(deadline, expire)
	defer func() { expired = dog.disarm() }()
	return false, work()
}
