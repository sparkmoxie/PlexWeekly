package manager

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTautulliDiscoveryStorePersistsOnlyCurrentSanitizedChoices(t *testing.T) {
	store := newTautulliDiscoveryStore(t.TempDir())
	revision := strings.Repeat("a", 64)
	result := TautulliDiscoveryResult{
		Mode:            "real-lan-discovery",
		NetworkBoundary: "private-and-loopback-only",
		CompletedAtUTC:  "2031-04-18T16:30:00Z",
		ConfigRevision:  revision,
		Libraries: []DiscoveredLibrary{
			{ID: "10", Name: "Fictional Movies\r\nIgnored", MediaType: "movie", ItemCount: "34"},
		},
		Users: []DiscoveredUser{
			{ID: "1", Name: "Fictional Admin\r\nIgnored", Eligibility: "eligible", Role: "administrator", LegacyRuleExcluded: true},
			{ID: "2", Name: "Fictional Managed", Eligibility: "address-needed", NeedsDeliveryAddress: true},
		},
		SuggestedPreviewUserID: "999",
		LegacyRuleCount:        2,
		MatchedLegacyRuleCount: 1,
	}
	if err := store.Save(result); err != nil {
		t.Fatal(err)
	}
	loaded := store.Load(revision)
	if loaded == nil || !loaded.Retained || loaded.SuggestedPreviewUserID != "1" || len(loaded.Libraries) != 1 || len(loaded.Users) != 2 || !loaded.Users[0].LegacyRuleExcluded || !loaded.Users[1].NeedsDeliveryAddress || loaded.LegacyRuleCount != 2 || loaded.MatchedLegacyRuleCount != 1 {
		t.Fatalf("unexpected cached discovery: %+v", loaded)
	}
	if strings.Contains(loaded.Libraries[0].Name, "\r") || strings.Contains(loaded.Users[0].Name, "\n") {
		t.Fatalf("cached discovery was not sanitized: %+v", loaded)
	}
	if stale := store.Load(strings.Repeat("b", 64)); stale != nil {
		t.Fatalf("stale discovery cache was returned: %+v", stale)
	}
	raw, err := os.ReadFile(filepath.Join(filepath.Dir(store.path), "tautulli-discovery.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"999", "email", "password", "apikey"} {
		if strings.Contains(strings.ToLower(string(raw)), forbidden) {
			t.Fatalf("cache retained forbidden value %q: %s", forbidden, raw)
		}
	}
	if strings.Contains(string(raw), "\"retained\"") {
		t.Fatal("cache persisted a presentation-only retained marker")
	}
}

func TestTautulliDiscoveryStoreRejectsInvalidCache(t *testing.T) {
	store := newTautulliDiscoveryStore(t.TempDir())
	if err := os.WriteFile(store.path, []byte(`{"mode":"unexpected","configRevision":"private"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if loaded := store.Load(strings.Repeat("a", 64)); loaded != nil {
		t.Fatalf("invalid cache was returned: %+v", loaded)
	}
}
