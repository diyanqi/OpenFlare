package wsclient

import (
	"errors"
	"strings"
	"testing"
)

func TestDecodeWebSocketMessage(t *testing.T) {
	tests := []struct {
		name      string
		data      []byte
		wantType  string
		wantError bool
		wantEmpty bool
	}{
		{
			name:     "complete json message",
			data:     []byte(`{"type":"active_config","payload":{"version":"20260803-001"}}`),
			wantType: "active_config",
		},
		{
			name:      "truncated json message",
			data:      []byte(`{"type":"active_config"`),
			wantError: true,
		},
		{
			name:      "empty message",
			wantError: true,
			wantEmpty: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var got WSMessage
			err := decodeWebSocketMessage(tt.data, &got)
			if (err != nil) != tt.wantError {
				t.Errorf("decodeWebSocketMessage(%q) error = %v, want error presence = %t", tt.data, err, tt.wantError)
			}
			if gotEmpty := errors.Is(err, errEmptyWebSocketMessage); gotEmpty != tt.wantEmpty {
				t.Errorf("decodeWebSocketMessage(%q) empty error = %t, want %t", tt.data, gotEmpty, tt.wantEmpty)
			}
			if err == nil && got.Type != tt.wantType {
				t.Errorf("decodeWebSocketMessage(%q) type = %q, want %q", tt.data, got.Type, tt.wantType)
			}
		})
	}
}

func TestWebSocketPayloadPreview(t *testing.T) {
	data := []byte(strings.Repeat("a", wsPayloadPreviewBytes+1))
	got := websocketPayloadPreview(data)
	want := strings.Repeat("61", wsPayloadPreviewBytes)
	if got != want {
		t.Errorf("websocketPayloadPreview(%d bytes) = %q, want %q", len(data), got, want)
	}
}
