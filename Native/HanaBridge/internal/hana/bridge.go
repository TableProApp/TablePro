package hana

type Bridge struct {
	sessions *sessionRegistry
}

func NewBridge() *Bridge {
	return &Bridge{sessions: newSessionRegistry()}
}

func (b *Bridge) Open(configJSON []byte) (sessionID uint64, failure []byte) {
	id, bridgeFailure := b.openSession(configJSON)
	return id, encodedFailure(bridgeFailure)
}

func (b *Bridge) Connect(sessionID uint64, operationID uint64) (result []byte, failure []byte) {
	encoded, bridgeFailure := b.connectSession(sessionID, operationID)
	return encoded, encodedFailure(bridgeFailure)
}

func (b *Bridge) Execute(sessionID uint64, operationID uint64, requestJSON []byte) (result []byte, failure []byte) {
	encoded, bridgeFailure := b.executeOnSession(sessionID, operationID, requestJSON)
	return encoded, encodedFailure(bridgeFailure)
}

func (b *Bridge) Explain(sessionID uint64, operationID uint64, requestJSON []byte) (result []byte, failure []byte) {
	encoded, bridgeFailure := b.explainOnSession(sessionID, operationID, requestJSON)
	return encoded, encodedFailure(bridgeFailure)
}

func (b *Bridge) Ping(sessionID uint64, operationID uint64) (failure []byte) {
	return encodedFailure(b.pingSession(sessionID, operationID))
}

func (b *Bridge) Cancel(sessionID uint64, operationID uint64) {
	b.cancelOnSession(sessionID, operationID)
}

func (b *Bridge) Close(sessionID uint64) {
	b.closeSession(sessionID)
}

func (b *Bridge) CloseAll() {
	for _, entry := range b.sessions.removeAll() {
		entry.close()
	}
}

func InternalFailure(message string) []byte {
	return internalError(message).encoded()
}

func encodedFailure(failure *bridgeError) []byte {
	if failure == nil {
		return nil
	}
	return failure.encoded()
}

func (b *Bridge) openSession(configJSON []byte) (uint64, *bridgeError) {
	config, failure := parseConnectionConfig(configJSON)
	if failure != nil {
		return 0, failure
	}
	entry, failure := newSession(config)
	if failure != nil {
		return 0, failure
	}
	return b.sessions.register(entry), nil
}

func (b *Bridge) connectSession(sessionID uint64, operationID uint64) ([]byte, *bridgeError) {
	entry, failure := b.sessions.lookup(sessionID)
	if failure != nil {
		return nil, failure
	}
	return entry.connect(operationID)
}

func (b *Bridge) executeOnSession(sessionID uint64, operationID uint64, requestJSON []byte) ([]byte, *bridgeError) {
	entry, failure := b.sessions.lookup(sessionID)
	if failure != nil {
		return nil, failure
	}
	request, failure := decodeRequest[executeRequest](requestJSON)
	if failure != nil {
		return nil, failure
	}
	return entry.execute(operationID, request)
}

func (b *Bridge) explainOnSession(sessionID uint64, operationID uint64, requestJSON []byte) ([]byte, *bridgeError) {
	entry, failure := b.sessions.lookup(sessionID)
	if failure != nil {
		return nil, failure
	}
	request, failure := decodeRequest[explainRequest](requestJSON)
	if failure != nil {
		return nil, failure
	}
	return entry.explain(operationID, request)
}

func (b *Bridge) pingSession(sessionID uint64, operationID uint64) *bridgeError {
	entry, failure := b.sessions.lookup(sessionID)
	if failure != nil {
		return failure
	}
	return entry.ping(operationID)
}

func (b *Bridge) cancelOnSession(sessionID uint64, operationID uint64) {
	entry, failure := b.sessions.lookup(sessionID)
	if failure != nil {
		return
	}
	entry.cancel(operationID)
}

func (b *Bridge) closeSession(sessionID uint64) {
	entry, found := b.sessions.remove(sessionID)
	if !found {
		return
	}
	entry.close()
}
