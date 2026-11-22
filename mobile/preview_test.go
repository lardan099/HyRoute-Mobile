package mobile

import (
	"strings"
	"testing"
)

func TestPreviewSubscriptionOmitsCredentials(t *testing.T) {
	raw, err := PreviewSubscription("hy2://test-preview-secret@preview.example:443#Preview", false)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(raw, "test-preview-secret") || !strings.Contains(raw, "preview.example") {
		t.Fatal("preview must contain server metadata and omit credentials")
	}
}
