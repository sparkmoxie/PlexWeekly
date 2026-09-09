package manager

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const maximumDiscoveryCacheBytes = 2 << 20

type tautulliDiscoveryStore struct {
	mu   sync.Mutex
	path string
}

func newTautulliDiscoveryStore(dataDir string) *tautulliDiscoveryStore {
	return &tautulliDiscoveryStore{path: filepath.Join(dataDir, "tautulli-discovery.json")}
}

func (s *tautulliDiscoveryStore) Save(result TautulliDiscoveryResult) error {
	clean, ok := sanitizeCachedDiscovery(result)
	if !ok {
		return errIntegrationResponse
	}
	encoded, err := json.Marshal(clean)
	if err != nil {
		return err
	}
	encoded = append(encoded, '\n')
	s.mu.Lock()
	defer s.mu.Unlock()
	return writePrivateBytes(s.path, encoded)
}

func (s *tautulliDiscoveryStore) Load(configRevision string) *TautulliDiscoveryResult {
	s.mu.Lock()
	defer s.mu.Unlock()
	info, err := os.Stat(s.path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > maximumDiscoveryCacheBytes {
		return nil
	}
	raw, err := os.ReadFile(s.path)
	if err != nil || len(raw) > maximumDiscoveryCacheBytes {
		return nil
	}
	var stored TautulliDiscoveryResult
	if json.Unmarshal(raw, &stored) != nil {
		return nil
	}
	clean, ok := sanitizeCachedDiscovery(stored)
	if !ok || clean.ConfigRevision != configRevision {
		return nil
	}
	clean.Retained = true
	return &clean
}

// Rebase carries only the already-sanitized discovery choices to a new full
// configuration revision. Callers use it only when normalized Tautulli inputs
// are unchanged.
func (s *tautulliDiscoveryStore) Rebase(previousRevision, nextRevision string) (bool, error) {
	if !validConfigRevision(previousRevision) || !validConfigRevision(nextRevision) {
		return false, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	info, err := os.Stat(s.path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > maximumDiscoveryCacheBytes {
		return false, nil
	}
	raw, err := os.ReadFile(s.path)
	if err != nil || len(raw) > maximumDiscoveryCacheBytes {
		return false, nil
	}
	var stored TautulliDiscoveryResult
	if json.Unmarshal(raw, &stored) != nil {
		return false, nil
	}
	clean, ok := sanitizeCachedDiscovery(stored)
	if !ok || clean.ConfigRevision != previousRevision {
		return false, nil
	}
	clean.ConfigRevision = nextRevision
	encoded, err := json.Marshal(clean)
	if err != nil {
		return false, err
	}
	encoded = append(encoded, '\n')
	if err := writePrivateBytes(s.path, encoded); err != nil {
		return false, err
	}
	return true, nil
}

func sanitizeCachedDiscovery(stored TautulliDiscoveryResult) (TautulliDiscoveryResult, bool) {
	if stored.Mode != "real-lan-discovery" || stored.NetworkBoundary != "private-and-loopback-only" || !validConfigRevision(stored.ConfigRevision) {
		return TautulliDiscoveryResult{}, false
	}
	completed, err := time.Parse(time.RFC3339, stored.CompletedAtUTC)
	if err != nil {
		return TautulliDiscoveryResult{}, false
	}
	clean := TautulliDiscoveryResult{
		Mode:                   stored.Mode,
		NetworkBoundary:        stored.NetworkBoundary,
		CompletedAtUTC:         completed.UTC().Format(time.RFC3339),
		ConfigRevision:         stored.ConfigRevision,
		Libraries:              make([]DiscoveredLibrary, 0, min(len(stored.Libraries), maximumDiscoveryChoices)),
		Users:                  make([]DiscoveredUser, 0, min(len(stored.Users), maximumDiscoveryChoices)),
		LegacyRuleCount:        min(max(stored.LegacyRuleCount, 0), maximumDiscoveryChoices),
		MatchedLegacyRuleCount: min(max(stored.MatchedLegacyRuleCount, 0), maximumDiscoveryChoices),
	}
	if clean.MatchedLegacyRuleCount > clean.LegacyRuleCount {
		return TautulliDiscoveryResult{}, false
	}
	seenLibraries := map[string]struct{}{}
	for _, library := range stored.Libraries {
		id := discoveryID(library.ID)
		mediaType := strings.ToLower(strings.TrimSpace(library.MediaType))
		if id == "" || mediaType != "movie" && mediaType != "show" {
			continue
		}
		if _, exists := seenLibraries[id]; exists {
			continue
		}
		seenLibraries[id] = struct{}{}
		name := sanitizeEvidence(library.Name, 100)
		if name == "" {
			name = "Library " + id
		}
		clean.Libraries = append(clean.Libraries, DiscoveredLibrary{ID: id, Name: name, MediaType: mediaType, ItemCount: sanitizeNumericEvidence(library.ItemCount)})
		if len(clean.Libraries) == maximumDiscoveryChoices {
			break
		}
	}
	if len(clean.Libraries) == 0 {
		return TautulliDiscoveryResult{}, false
	}
	seenUsers := map[string]struct{}{}
	for _, user := range stored.Users {
		id := discoveryUserID(user.ID)
		if id == "" {
			continue
		}
		if _, exists := seenUsers[id]; exists {
			continue
		}
		seenUsers[id] = struct{}{}
		name := sanitizeEvidence(user.Name, 100)
		if name == "" {
			name = "User " + id
		}
		eligibility := user.Eligibility
		if eligibility != "eligible" && eligibility != "address-needed" && eligibility != "skipped" && eligibility != "unknown" {
			eligibility = "unknown"
		}
		needsDeliveryAddress := eligibility == "address-needed" && user.NeedsDeliveryAddress
		role := user.Role
		if role != "owner" && role != "administrator" {
			role = ""
		}
		clean.Users = append(clean.Users, DiscoveredUser{ID: id, Name: name, Eligibility: eligibility, NeedsDeliveryAddress: needsDeliveryAddress, Role: role, LegacyRuleExcluded: user.LegacyRuleExcluded})
		if len(clean.Users) == maximumDiscoveryChoices {
			break
		}
	}
	clean.SuggestedPreviewUserID = suggestedPreviewUserID(clean.Users)
	return clean, true
}

func validConfigRevision(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, character := range value {
		if character < '0' || character > '9' {
			if character < 'a' || character > 'f' {
				return false
			}
		}
	}
	return true
}
