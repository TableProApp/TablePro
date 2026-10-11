package hana

import (
	"fmt"
)

const lobCellLimit = 64 << 20

type lobCell struct {
	limit     int
	data      []byte
	null      bool
	truncated bool
	stopped   func() bool
}

func newLobCell(limit int, stopped func() bool) *lobCell {
	return &lobCell{limit: limit, stopped: stopped}
}

func (c *lobCell) Write(chunk []byte) (int, error) {
	if c.stopped != nil && c.stopped() {
		return 0, errOperationStopped
	}
	room := c.limit - len(c.data)
	if len(chunk) > room {
		c.data = append(c.data, chunk[:max(room, 0)]...)
		c.truncated = true
		return len(chunk), nil
	}
	c.data = append(c.data, chunk...)
	return len(chunk), nil
}

func (c *lobCell) Scan(source any) error {
	switch value := source.(type) {
	case nil:
		c.null = true
		return nil
	case []byte:
		_, err := c.Write(value)
		return err
	case string:
		_, err := c.Write([]byte(value))
		return err
	default:
		return fmt.Errorf("unsupported LOB value %T", source)
	}
}

func (c *lobCell) cell(column columnInfo) cell {
	if c.null {
		return nullCell()
	}
	if !column.holdsText() {
		return bytesCell(c.data)
	}
	return textCell(c.text())
}

func (c *lobCell) text() string {
	data := c.data
	if c.truncated {
		data = trimIncompleteRune(data)
	}
	return decodeText(data)
}
