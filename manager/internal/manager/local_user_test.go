package manager

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func TestDiscoveryExcludesReservedLocalAcrossRosterSources(t *testing.T) {
	names := []map[string]any{
		{"user_id": "0", "friendly_name": "Local"},
		{"user_id": "000", "friendly_name": "Renamed anonymous bucket"},
		{"user_id": "42", "friendly_name": "Local"},
	}
	primary := []map[string]any{
		{"user_id": json.Number("0"), "friendly_name": "Local", "email": "anonymous@example.org", "is_active": true, "is_owner": true},
		{"user_id": "42", "friendly_name": "Local", "is_active": true},
	}
	fallback := []map[string]any{
		{"user_id": "00", "friendly_name": "Local", "is_active": true, "is_owner": true},
		{"user_id": "43", "friendly_name": "Viewer", "email": "viewer@example.org", "is_active": true, "is_admin": true},
	}
	merged := mergeDiscoveredUserDetails(primary, fallback)
	if len(merged) != 2 {
		t.Fatalf("reserved identities survived table merge: %#v", merged)
	}
	users, matched := normalizeDiscoveredUsers(names, merged, map[string]struct{}{"anonymous@example.org": {}})
	if len(users) != 2 || users[0].ID != "42" || users[0].Name != "Local" || !users[0].NeedsDeliveryAddress || users[1].ID != "43" || matched != 0 {
		t.Fatalf("unexpected recipient discovery: %#v matched=%d", users, matched)
	}
	if suggestedPreviewUserID(users) != "43" {
		t.Fatalf("reserved Local altered the suggested preview identity: %#v", users)
	}
	if discoveryID("0") != "0" {
		t.Fatal("user filtering changed the independent library ID contract")
	}
}

func TestDiscoveryLocalOnlyRosterIsValidAndEmpty(t *testing.T) {
	for _, tableFallback := range []bool{false, true} {
		name := "bulk roster"
		if tableFallback {
			name = "table fallback"
		}
		t.Run(name, func(t *testing.T) {
			tautulli := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var data any
				local := []any{map[string]any{"user_id": 0, "friendly_name": "Local", "is_active": 1}}
				switch r.URL.Query().Get("cmd") {
				case "get_libraries":
					data = []any{map[string]any{"section_id": 10, "section_name": "Movies", "section_type": "movie", "is_active": 1}}
				case "get_users", "get_user_names":
					data = local
					if tableFallback {
						data = []any{}
					}
				case "get_users_table":
					data = map[string]any{"data": local}
				default:
					t.Errorf("unexpected command: %s", r.URL.Query().Get("cmd"))
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"response": map[string]any{"result": "success", "data": data}})
			}))
			defer tautulli.Close()
			root := integrationConfigRoot(t, tautulli.URL, "fictional-api-key", "", "")
			result, err := DiscoverTautulliChoices(context.Background(), root, TautulliDiscoveryRequest{
				ExpectedRevision: ReadConfigEditor(root).Revision, ConfirmRealNetwork: true,
			}, time.Now)
			if err != nil || len(result.Users) != 0 || result.Users == nil || result.SuggestedPreviewUserID != "" || len(result.Libraries) != 1 {
				t.Fatalf("Local-only roster should be valid empty discovery: result=%+v err=%v", result, err)
			}
		})
	}
}

func TestRetainedDiscoveryRemovesReservedLocalOnLoadAndRebase(t *testing.T) {
	store := newTautulliDiscoveryStore(t.TempDir())
	revision := strings.Repeat("a", 64)
	stored := TautulliDiscoveryResult{
		Mode: "real-lan-discovery", NetworkBoundary: "private-and-loopback-only",
		CompletedAtUTC: "2031-04-18T16:30:00Z", ConfigRevision: revision,
		Libraries: []DiscoveredLibrary{{ID: "0", Name: "Movies", MediaType: "movie"}},
		Users: []DiscoveredUser{
			{ID: "0", Name: "Local", Eligibility: "address-needed", NeedsDeliveryAddress: true, Role: "owner"},
			{ID: "000", Name: "Anonymous", Eligibility: "eligible", Role: "owner"},
			{ID: "42", Name: "Local", Eligibility: "address-needed", NeedsDeliveryAddress: true, Role: "administrator"},
		},
		SuggestedPreviewUserID: "0",
	}
	raw, err := json.Marshal(stored)
	if err != nil {
		t.Fatal(err)
	}
	// Write the old cache directly so Load, not the new Save sanitizer, is tested.
	if err := os.WriteFile(store.path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	assertClean := func(loaded *TautulliDiscoveryResult) {
		t.Helper()
		if loaded == nil || len(loaded.Users) != 1 || loaded.Users[0].ID != "42" || loaded.Users[0].Name != "Local" || !loaded.Users[0].NeedsDeliveryAddress || loaded.SuggestedPreviewUserID != "42" || loaded.Libraries[0].ID != "0" {
			t.Fatalf("reserved Local survived cached discovery sanitization: %+v", loaded)
		}
	}
	assertClean(store.Load(revision))
	nextRevision := strings.Repeat("b", 64)
	if rebased, err := store.Rebase(revision, nextRevision); err != nil || !rebased {
		t.Fatalf("cache rebase: rebased=%v err=%v", rebased, err)
	}
	assertClean(store.Load(nextRevision))
}

func TestRecipientOperationsRejectReservedLocalBeforeStarting(t *testing.T) {
	coordinator := &operationCoordinator{}
	for _, userID := range []string{"0", "00", " 0 "} {
		for _, operationType := range []string{"preview-all", "send-test-all", "send-welcome"} {
			request := CreateOperationRequest{Type: operationType, UserID: userID}
			request.ConfirmNoSend = operationType == "preview-all"
			request.ConfirmTestSend = operationType == "send-test-all"
			request.ConfirmProductionSend = operationType == "send-welcome"
			if _, err := coordinator.Start(request); !errors.Is(err, ErrOperationInvalid) {
				t.Fatalf("%s accepted reserved user %q: %v", operationType, userID, err)
			}
		}
	}
}

func TestLegacyLocalDeliveryMappingRemainsInertAndDoesNotBlockValidConfig(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	setIntegrationConfigValues(t, root, map[string]any{
		"UserEmailOverrides": map[string]string{"0": "anonymous@example.org", "42": "viewer@example.org", "999": "orphan@example.org"},
	})
	view := ReadConfigEditor(root)
	request := validConfigSaveRequest(t, view)
	request.Values["UserEmailOverrides"] = json.RawMessage(`{"0":"anonymous@example.org","42":"viewer@example.org","999":"orphan@example.org"}`)
	result, fields, err := SaveConfig(root, request, time.Now)
	if err != nil || len(fields) != 0 {
		t.Fatalf("legacy Local mapping blocked valid config: result=%+v fields=%v err=%v", result, fields, err)
	}
	values, _, _, state := readConfigDocument(root)
	if state != "ready" || len(existingConfigIssues(values)) != 0 {
		t.Fatalf("legacy Local mapping made config unready: state=%s", state)
	}
	mapping := values["UserEmailOverrides"].(map[string]any)
	if len(mapping) != 3 || mapping["0"] != "anonymous@example.org" || mapping["42"] != "viewer@example.org" || mapping["999"] != "orphan@example.org" || validTautulliUserID("0") {
		t.Fatalf("legacy mapping was altered or Local became eligible: %#v", mapping)
	}
}
