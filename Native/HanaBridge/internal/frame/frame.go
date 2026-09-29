package frame

import (
	"encoding/binary"
	"errors"
	"io"
	"math"
)

const (
	HeaderSize    = 13
	MaxBodyLength = math.MaxInt32
)

var (
	ErrShortHeader  = errors.New("the stream ended inside a frame header")
	ErrShortBody    = errors.New("the stream ended inside a frame body")
	ErrBodyTooLarge = errors.New("the frame body is larger than allowed")
)

type Frame struct {
	ID   uint64
	Code byte
	Body []byte
}

type header struct {
	length uint32
	id     uint64
	code   byte
}

func encodeHeader(id uint64, code byte, bodyLength int) ([HeaderSize]byte, error) {
	var encoded [HeaderSize]byte
	if bodyLength < 0 || uint64(bodyLength) > MaxBodyLength {
		return encoded, ErrBodyTooLarge
	}
	binary.BigEndian.PutUint32(encoded[0:4], uint32(bodyLength))
	binary.BigEndian.PutUint64(encoded[4:12], id)
	encoded[12] = code
	return encoded, nil
}

func decodeHeader(encoded [HeaderSize]byte) header {
	return header{
		length: binary.BigEndian.Uint32(encoded[0:4]),
		id:     binary.BigEndian.Uint64(encoded[4:12]),
		code:   encoded[12],
	}
}

func Read(input io.Reader, maxBodyLength uint32) (Frame, error) {
	var encoded [HeaderSize]byte
	if _, err := io.ReadFull(input, encoded[:]); err != nil {
		if errors.Is(err, io.ErrUnexpectedEOF) {
			return Frame{}, ErrShortHeader
		}
		return Frame{}, err
	}
	decoded := decodeHeader(encoded)
	if decoded.length > maxBodyLength {
		return Frame{}, ErrBodyTooLarge
	}
	body := make([]byte, decoded.length)
	if _, err := io.ReadFull(input, body); err != nil {
		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			return Frame{}, ErrShortBody
		}
		return Frame{}, err
	}
	return Frame{ID: decoded.id, Code: decoded.code, Body: body}, nil
}

func Write(output io.Writer, outgoing Frame) error {
	encoded, err := encodeHeader(outgoing.ID, outgoing.Code, len(outgoing.Body))
	if err != nil {
		return err
	}
	if _, err := output.Write(encoded[:]); err != nil {
		return err
	}
	if len(outgoing.Body) == 0 {
		return nil
	}
	_, err = output.Write(outgoing.Body)
	return err
}
