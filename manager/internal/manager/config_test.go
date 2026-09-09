package manager

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadRedactedConfig(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	config := `{
  "TautulliUrl": "http://tautulli.fictional.test:8181",
  "ApiKey": "fictional-secret",
  "PlexToken": "",
  "SmtpPassword": "fictional-password",
  "ScheduleEnabled": false,
  "SchedulerPollSeconds": 30,
  "IncludedLibraryIds": ["1", "4"],
  "UserEmailOverrides": {"42":"private-managed@example.org"}
}`
	if err := os.WriteFile(filepath.Join(root, "config.json"), []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}

	view := ReadRedactedConfig(root)
	if !view.Exists || !view.Valid || view.State != "ready" {
		t.Fatalf("unexpected config state: %+v", view)
	}
	encoded, err := json.Marshal(view)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"fictional-secret", "fictional-password", "private-managed@example.org"} {
		if strings.Contains(string(encoded), secret) {
			t.Fatalf("redacted response contains secret %q", secret)
		}
	}
	assertConfigField(t, view, "ApiKey", "secret", true)
	assertConfigField(t, view, "PlexToken", "secret", false)
	assertConfigField(t, view, "ScheduleEnabled", "boolean", false)
	assertConfigField(t, view, "SchedulerPollSeconds", "number", false)
	assertConfigField(t, view, "IncludedLibraryIds", "array", false)
	assertConfigField(t, view, "UserEmailOverrides", "secret", true)
}

func TestReadRedactedConfigRejectsTrailingJSON(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "config.json"), []byte(`{"ApiKey":"one"} {"ApiKey":"two"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	view := ReadRedactedConfig(root)
	if view.Valid || view.State != "invalid-json" {
		t.Fatalf("trailing JSON was accepted: %+v", view)
	}
}

func assertConfigField(t *testing.T, view ConfigView, name, fieldType string, configured bool) {
	t.Helper()
	for _, field := range view.Fields {
		if field.Name != name {
			continue
		}
		if field.Type != fieldType {
			t.Fatalf("%s type: got %q, want %q", name, field.Type, fieldType)
		}
		if fieldType == "secret" && (field.Secret == nil || field.Secret.Configured != configured) {
			t.Fatalf("%s configured state mismatch: %+v", name, field.Secret)
		}
		return
	}
	t.Fatalf("field %s not found", name)
}
