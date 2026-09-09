package manager

import (
	"bytes"
	"context"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

const maximumIntegrationResponseBytes = 2 << 20
const maximumDiscoveryChoices = 2000

var (
	ErrRealCheckConfirmation = errors.New("real network check was not confirmed")
	ErrRealCheckNotReady     = errors.New("configuration is not ready for verification")
	errLANOnlyDestination    = errors.New("destination is outside the private LAN boundary")
	errIntegrationConnection = errors.New("connection failed or timed out")
	errIntegrationResponse   = errors.New("service returned an invalid response")
)

type RealIntegrationCheckRequest struct {
	ExpectedRevision   string `json:"expectedRevision"`
	ConfirmRealNetwork bool   `json:"confirmRealNetwork"`
}

type TautulliDiscoveryRequest struct {
	ExpectedRevision   string `json:"expectedRevision"`
	ConfirmRealNetwork bool   `json:"confirmRealNetwork"`
}

type DiscoveredLibrary struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	MediaType string `json:"mediaType"`
	ItemCount string `json:"itemCount,omitempty"`
}

type DiscoveredUser struct {
	ID                   string `json:"id"`
	Name                 string `json:"name"`
	Eligibility          string `json:"eligibility"`
	NeedsDeliveryAddress bool   `json:"needsDeliveryAddress,omitempty"`
	Role                 string `json:"role,omitempty"`
	LegacyRuleExcluded   bool   `json:"legacyRuleExcluded,omitempty"`
}

type TautulliDiscoveryResult struct {
	Mode                   string              `json:"mode"`
	NetworkBoundary        string              `json:"networkBoundary"`
	CompletedAtUTC         string              `json:"completedAtUtc"`
	ConfigRevision         string              `json:"configRevision"`
	Libraries              []DiscoveredLibrary `json:"libraries"`
	Users                  []DiscoveredUser    `json:"users"`
	SuggestedPreviewUserID string              `json:"suggestedPreviewUserId,omitempty"`
	LegacyRuleCount        int                 `json:"legacyRuleCount,omitempty"`
	MatchedLegacyRuleCount int                 `json:"matchedLegacyRuleCount,omitempty"`
	Retained               bool                `json:"retained,omitempty"`
}

type tautulliDiscoveryError struct {
	stage string
	err   error
}

func (e *tautulliDiscoveryError) Error() string {
	return "Tautulli " + e.stage + " discovery failed"
}

func (e *tautulliDiscoveryError) Unwrap() error {
	return e.err
}

func wrapTautulliDiscoveryError(stage string, err error) error {
	if err == nil {
		return nil
	}
	return &tautulliDiscoveryError{stage: stage, err: err}
}

func tautulliDiscoveryFailureStage(err error) string {
	var discoveryErr *tautulliDiscoveryError
	if errors.As(err, &discoveryErr) {
		switch discoveryErr.stage {
		case "libraries", "users":
			return discoveryErr.stage
		}
	}
	return "connection"
}

type IntegrationCheckStep struct {
	Service string `json:"service"`
	State   string `json:"state"`
	Summary string `json:"summary"`
}

type IntegrationCheckResult struct {
	Mode            string                 `json:"mode"`
	NetworkBoundary string                 `json:"networkBoundary"`
	Overall         string                 `json:"overall"`
	StartedAtUTC    string                 `json:"startedAtUtc"`
	CompletedAtUTC  string                 `json:"completedAtUtc"`
	ConfigRevision  string                 `json:"configRevision"`
	Steps           []IntegrationCheckStep `json:"steps"`
}

type tautulliServerData struct {
	PMSURL        string `json:"pms_url"`
	PMSIdentifier string `json:"pms_identifier"`
}

type tautulliEnvelope struct {
	Response struct {
		Result  string          `json:"result"`
		Message string          `json:"message"`
		Data    json.RawMessage `json:"data"`
	} `json:"response"`
}

type tautulliUsersTable struct {
	Data []map[string]any `json:"data"`
}

type tautulliLibrariesTable struct {
	Data []map[string]any `json:"data"`
}

func RunRealIntegrationCheck(ctx context.Context, root string, request RealIntegrationCheckRequest, now func() time.Time) (IntegrationCheckResult, error) {
	if !request.ConfirmRealNetwork {
		return IntegrationCheckResult{}, ErrRealCheckConfirmation
	}
	values, raw, exists, state := readConfigDocument(root)
	if state != "ready" || !exists || len(existingConfigIssues(values)) > 0 {
		return IntegrationCheckResult{}, ErrRealCheckNotReady
	}
	revision := configRevision(raw, true)
	if request.ExpectedRevision == "" || request.ExpectedRevision != revision {
		return IntegrationCheckResult{}, ErrConfigConflict
	}
	if now == nil {
		now = time.Now
	}
	started := now().UTC()
	checkContext, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()

	client := newLANOnlyHTTPClient()
	tautulliStep, serverData := verifyTautulli(checkContext, client, values)
	plexStep := verifyPlex(checkContext, client, values, serverData)
	steps := []IntegrationCheckStep{tautulliStep, plexStep}
	overall := integrationCheckOverall(steps)
	return IntegrationCheckResult{
		Mode:            "real-lan",
		NetworkBoundary: "private-and-loopback-only",
		Overall:         overall,
		StartedAtUTC:    started.Format(time.RFC3339),
		CompletedAtUTC:  now().UTC().Format(time.RFC3339),
		ConfigRevision:  revision,
		Steps:           steps,
	}, nil
}

func integrationCheckOverall(steps []IntegrationCheckStep) string {
	overall := "passed"
	for _, step := range steps {
		if step.State == "failed" {
			return "failed"
		}
		if step.State == "passed" || step.Service == "plex" && step.State == "skipped" {
			continue
		}
		overall = "warning"
	}
	return overall
}

// DiscoverTautulliChoices performs one explicit, non-persistent LAN lookup for
// the authenticated setup UI. It intentionally omits email addresses and never
// returns the API key, service URL, or raw Tautulli response.
func DiscoverTautulliChoices(ctx context.Context, root string, request TautulliDiscoveryRequest, now func() time.Time) (TautulliDiscoveryResult, error) {
	if !request.ConfirmRealNetwork {
		return TautulliDiscoveryResult{}, ErrRealCheckConfirmation
	}
	values, raw, exists, state := readConfigDocument(root)
	if state != "ready" || !exists || len(existingConfigIssues(values)) > 0 {
		return TautulliDiscoveryResult{}, ErrRealCheckNotReady
	}
	revision := configRevision(raw, true)
	if request.ExpectedRevision == "" || request.ExpectedRevision != revision {
		return TautulliDiscoveryResult{}, ErrConfigConflict
	}
	base, err := parseLANBaseURL(configMapString(values, "TautulliUrl"))
	if err != nil {
		return TautulliDiscoveryResult{}, err
	}
	if now == nil {
		now = time.Now
	}
	checkContext, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	client := newLANOnlyHTTPClient()
	apiKey := configMapString(values, "ApiKey")

	var rawLibraries []map[string]any
	libraryErr := tautulliCommand(checkContext, client, base, apiKey, "get_libraries", &rawLibraries)
	libraries := normalizeDiscoveredLibraries(rawLibraries)
	if libraryErr != nil || len(libraries) == 0 {
		var table tautulliLibrariesTable
		tableErr := tautulliCommandWithParams(checkContext, client, base, apiKey, "get_libraries_table", discoveryTableParams(), &table)
		if tableErr == nil {
			libraries = normalizeDiscoveredLibraries(table.Data)
		}
		if len(libraries) == 0 {
			cause := libraryErr
			if cause == nil {
				cause = tableErr
			}
			if cause == nil {
				cause = errIntegrationResponse
			}
			return TautulliDiscoveryResult{}, wrapTautulliDiscoveryError("libraries", cause)
		}
	}
	var rawNames []map[string]any
	nameErr := tautulliCommand(checkContext, client, base, apiKey, "get_user_names", &rawNames)
	var rawUsers []map[string]any
	detailErr := tautulliCommand(checkContext, client, base, apiKey, "get_users", &rawUsers)
	legacyRules := normalizedLegacyExclusionRules(values["ExcludedEmails"])
	users, matchedLegacyRules := normalizeDiscoveredUsers(rawNames, rawUsers, legacyRules)
	var tableErr error
	if nameErr != nil || detailErr != nil || len(users) == 0 || matchedLegacyRules < len(legacyRules) {
		var table tautulliUsersTable
		tableErr = tautulliCommandWithParams(checkContext, client, base, apiKey, "get_users_table", discoveryTableParams(), &table)
		if tableErr == nil {
			rawUsers = mergeDiscoveredUserDetails(rawUsers, table.Data)
			users, matchedLegacyRules = normalizeDiscoveredUsers(rawNames, rawUsers, legacyRules)
		}
	}
	if len(users) == 0 {
		cause := nameErr
		if cause == nil {
			cause = detailErr
		}
		if cause == nil {
			cause = tableErr
		}
		if cause == nil {
			cause = errIntegrationResponse
		}
		return TautulliDiscoveryResult{}, wrapTautulliDiscoveryError("users", cause)
	}
	return TautulliDiscoveryResult{
		Mode:                   "real-lan-discovery",
		NetworkBoundary:        "private-and-loopback-only",
		CompletedAtUTC:         now().UTC().Format(time.RFC3339),
		ConfigRevision:         revision,
		Libraries:              libraries,
		Users:                  users,
		SuggestedPreviewUserID: suggestedPreviewUserID(users),
		LegacyRuleCount:        len(legacyRules),
		MatchedLegacyRuleCount: matchedLegacyRules,
	}, nil
}

func discoveryTableParams() url.Values {
	return url.Values{
		"start":  {"0"},
		"length": {strconv.Itoa(maximumDiscoveryChoices)},
	}
}

func normalizeDiscoveredLibraries(values []map[string]any) []DiscoveredLibrary {
	result := make([]DiscoveredLibrary, 0, min(len(values), maximumDiscoveryChoices))
	seen := make(map[string]struct{})
	for _, value := range values {
		id := discoveryID(value["section_id"])
		mediaType := strings.ToLower(sanitizeEvidence(fmt.Sprint(value["section_type"]), 16))
		if id == "" || mediaType != "movie" && mediaType != "show" || !integrationTruthy(value["is_active"]) {
			continue
		}
		if _, exists := seen[id]; exists {
			continue
		}
		seen[id] = struct{}{}
		name := sanitizeEvidence(fmt.Sprint(value["section_name"]), 100)
		if name == "" || name == "<nil>" {
			name = "Library " + id
		}
		count := sanitizeNumericEvidence(value["count"])
		result = append(result, DiscoveredLibrary{ID: id, Name: name, MediaType: mediaType, ItemCount: count})
		if len(result) == maximumDiscoveryChoices {
			break
		}
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].MediaType != result[j].MediaType {
			return result[i].MediaType < result[j].MediaType
		}
		return strings.ToLower(result[i].Name) < strings.ToLower(result[j].Name)
	})
	return result
}

func normalizeDiscoveredUsers(names, details []map[string]any, legacyRules map[string]struct{}) ([]DiscoveredUser, int) {
	detailsByID := make(map[string]map[string]any)
	nameByID := make(map[string]string)
	ids := make([]string, 0, len(names)+len(details))
	seen := make(map[string]struct{})
	addID := func(id string) {
		if id == "" {
			return
		}
		if _, exists := seen[id]; exists {
			return
		}
		seen[id] = struct{}{}
		ids = append(ids, id)
	}
	for _, value := range details {
		id := discoveryID(value["user_id"])
		if id != "" {
			detailsByID[id] = value
			addID(id)
		}
	}
	for _, value := range names {
		id := discoveryID(value["user_id"])
		if id != "" {
			nameByID[id] = sanitizeEvidence(fmt.Sprint(value["friendly_name"]), 100)
			addID(id)
		}
	}
	result := make([]DiscoveredUser, 0, min(len(ids), maximumDiscoveryChoices))
	matchedLegacyRules := make(map[string]struct{})
	for _, id := range ids {
		detail, hasDetails := detailsByID[id]
		name := sanitizeEvidence(fmt.Sprint(detail["friendly_name"]), 100)
		if name == "" || name == "<nil>" {
			name = nameByID[id]
		}
		if name == "" || name == "<nil>" {
			name = sanitizeEvidence(fmt.Sprint(detail["username"]), 100)
		}
		if name == "" || name == "<nil>" {
			name = "User " + id
		}
		eligibility := "unknown"
		needsDeliveryAddress := false
		legacyRuleExcluded := false
		if hasDetails {
			eligibility = "skipped"
			email := discoveredUserEmail(detail)
			if integrationTruthy(detail["is_active"]) {
				if email != "" && email != "<nil>" {
					eligibility = "eligible"
				} else {
					eligibility = "address-needed"
					needsDeliveryAddress = true
				}
			}
			if _, excluded := legacyRules[email]; excluded {
				legacyRuleExcluded = true
				matchedLegacyRules[email] = struct{}{}
			}
		}
		result = append(result, DiscoveredUser{ID: id, Name: name, Eligibility: eligibility, NeedsDeliveryAddress: needsDeliveryAddress, Role: discoveredUserRole(detail), LegacyRuleExcluded: legacyRuleExcluded})
		if len(result) == maximumDiscoveryChoices {
			break
		}
	}
	sort.Slice(result, func(i, j int) bool { return strings.ToLower(result[i].Name) < strings.ToLower(result[j].Name) })
	return result, len(matchedLegacyRules)
}

func mergeDiscoveredUserDetails(primary, fallback []map[string]any) []map[string]any {
	result := make([]map[string]any, 0, len(primary)+len(fallback))
	byID := make(map[string]map[string]any, len(primary)+len(fallback))
	for _, source := range primary {
		copyOfSource := make(map[string]any, len(source))
		for key, value := range source {
			copyOfSource[key] = value
		}
		id := discoveryID(copyOfSource["user_id"])
		if id != "" {
			byID[id] = copyOfSource
		}
		result = append(result, copyOfSource)
	}
	for _, source := range fallback {
		id := discoveryID(source["user_id"])
		if id == "" {
			continue
		}
		if existing, ok := byID[id]; ok {
			for key, value := range source {
				if discoveryValueMissing(existing[key]) && !discoveryValueMissing(value) {
					existing[key] = value
				}
			}
			continue
		}
		copyOfSource := make(map[string]any, len(source))
		for key, value := range source {
			copyOfSource[key] = value
		}
		byID[id] = copyOfSource
		result = append(result, copyOfSource)
	}
	return result
}

func discoveredUserEmail(detail map[string]any) string {
	for _, key := range []string{"email", "user_email"} {
		value := strings.ToLower(strings.TrimSpace(fmt.Sprint(detail[key])))
		if value != "" && value != "<nil>" {
			return value
		}
	}
	return ""
}

func discoveryValueMissing(value any) bool {
	if value == nil {
		return true
	}
	if text, ok := value.(string); ok {
		text = strings.TrimSpace(text)
		return text == "" || text == "<nil>"
	}
	return false
}

func normalizedLegacyExclusionRules(value any) map[string]struct{} {
	result := make(map[string]struct{})
	appendRule := func(candidate any) {
		text, ok := candidate.(string)
		if !ok {
			return
		}
		text = strings.ToLower(strings.TrimSpace(text))
		if text != "" {
			result[text] = struct{}{}
		}
	}
	switch typed := value.(type) {
	case []any:
		for _, candidate := range typed {
			appendRule(candidate)
		}
	case []string:
		for _, candidate := range typed {
			appendRule(candidate)
		}
	}
	return result
}

func discoveredUserRole(detail map[string]any) string {
	for _, key := range []string{"is_owner", "is_plex_owner", "is_server_owner"} {
		if integrationTruthy(detail[key]) {
			return "owner"
		}
	}
	for _, key := range []string{"is_admin", "is_administrator"} {
		if integrationTruthy(detail[key]) {
			return "administrator"
		}
	}
	return ""
}

func suggestedPreviewUserID(users []DiscoveredUser) string {
	owners := []string{}
	administrators := []string{}
	for _, user := range users {
		switch user.Role {
		case "owner":
			owners = append(owners, user.ID)
		case "administrator":
			administrators = append(administrators, user.ID)
		}
	}
	if len(owners) == 1 {
		return owners[0]
	}
	if len(owners) == 0 && len(administrators) == 1 {
		return administrators[0]
	}
	return ""
}

func discoveryID(value any) string {
	text := strings.TrimSpace(fmt.Sprint(value))
	if len(text) == 0 || len(text) > 20 {
		return ""
	}
	for _, character := range text {
		if character < '0' || character > '9' {
			return ""
		}
	}
	return text
}

func sanitizeNumericEvidence(value any) string {
	text := discoveryID(value)
	if len(text) > 10 {
		return ""
	}
	return text
}

func verifyTautulli(ctx context.Context, client *http.Client, values map[string]any) (IntegrationCheckStep, tautulliServerData) {
	base, err := parseLANBaseURL(configMapString(values, "TautulliUrl"))
	if err != nil {
		return failedIntegrationStep("tautulli", err), tautulliServerData{}
	}
	apiKey := configMapString(values, "ApiKey")
	var info struct {
		Version string `json:"tautulli_version"`
	}
	if err := tautulliCommand(ctx, client, base, apiKey, "get_tautulli_info", &info); err != nil {
		return failedIntegrationStep("tautulli", err), tautulliServerData{}
	}
	var users []json.RawMessage
	if err := tautulliCommand(ctx, client, base, apiKey, "get_user_names", &users); err != nil {
		return failedIntegrationStep("tautulli", err), tautulliServerData{}
	}
	var libraries []map[string]any
	if err := tautulliCommand(ctx, client, base, apiKey, "get_libraries", &libraries); err != nil {
		return failedIntegrationStep("tautulli", err), tautulliServerData{}
	}
	selectable := 0
	for _, library := range libraries {
		kind := strings.ToLower(strings.TrimSpace(fmt.Sprint(library["section_type"])))
		if (kind == "movie" || kind == "show") && integrationTruthy(library["is_active"]) {
			selectable++
		}
	}
	if selectable == 0 {
		return IntegrationCheckStep{Service: "tautulli", State: "failed", Summary: "API authentication worked, but no active movie or TV libraries were reported."}, tautulliServerData{}
	}
	serverData := tautulliServerData{}
	_ = tautulliCommand(ctx, client, base, apiKey, "get_server_info", &serverData)
	version := sanitizeEvidence(info.Version, 64)
	if version == "" {
		version = "version not reported"
	}
	summary := fmt.Sprintf("Authenticated Tautulli API %s; %d users and %d active movie/TV libraries were reported.", version, len(users), selectable)
	return IntegrationCheckStep{Service: "tautulli", State: "passed", Summary: summary}, serverData
}

func verifyPlex(ctx context.Context, client *http.Client, values map[string]any, serverData tautulliServerData) IntegrationCheckStep {
	serverURL := configMapString(values, "PlexServerUrl")
	token := runtimePlexToken(values)
	if serverURL == "" {
		serverURL = strings.TrimSpace(serverData.PMSURL)
	}
	if serverURL == "" || token == "" {
		summary := "Direct Plex was not tested because a URL/token pair is not available to the Manager; Tautulli core access was tested separately."
		if serverURL == "" && token != "" {
			summary = "Direct Plex was not tested because no server URL was configured or reported by Tautulli; a runtime token is available."
		} else if serverURL != "" && token == "" {
			summary = "Direct Plex was not tested because no stored or supported runtime Plex token is available."
		}
		return IntegrationCheckStep{
			Service: "plex",
			State:   "skipped",
			Summary: summary,
		}
	}
	base, err := parseLANBaseURL(serverURL)
	if err != nil {
		return failedIntegrationStep("plex", err)
	}
	identityBody, err := plexRequest(ctx, client, integrationEndpoint(base, "identity"), token)
	if err != nil {
		return failedIntegrationStep("plex", err)
	}
	libraryBody, err := plexRequest(ctx, client, integrationEndpoint(base, "library/sections"), token)
	if err != nil {
		return failedIntegrationStep("plex", err)
	}
	identity, identityOK := plexMediaContainer(identityBody)
	_, librariesOK := plexMediaContainer(libraryBody)
	if !identityOK || !librariesOK {
		return failedIntegrationStep("plex", errIntegrationResponse)
	}
	if expected := strings.TrimSpace(serverData.PMSIdentifier); expected != "" && identity != "" && !strings.EqualFold(expected, identity) {
		return IntegrationCheckStep{Service: "plex", State: "failed", Summary: "Plex answered both requests, but its server identity did not match the Plex server reported by Tautulli."}
	}
	return IntegrationCheckStep{Service: "plex", State: "passed", Summary: "Direct Plex identity and authenticated library requests succeeded against the configured server."}
}

func tautulliCommand(ctx context.Context, client *http.Client, base *url.URL, apiKey, command string, target any) error {
	return tautulliCommandWithParams(ctx, client, base, apiKey, command, nil, target)
}

func tautulliCommandWithParams(ctx context.Context, client *http.Client, base *url.URL, apiKey, command string, params url.Values, target any) error {
	endpoint := integrationEndpoint(base, "api/v2")
	query := endpoint.Query()
	query.Set("apikey", apiKey)
	query.Set("cmd", command)
	for key, values := range params {
		query.Del(key)
		for _, value := range values {
			query.Add(key, value)
		}
	}
	endpoint.RawQuery = query.Encode()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return errIntegrationResponse
	}
	request.Header.Set("Accept", "application/json")
	response, err := client.Do(request)
	if err != nil {
		return classifyIntegrationTransportError(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		if response.StatusCode == http.StatusUnauthorized || response.StatusCode == http.StatusForbidden {
			return fmt.Errorf("authentication rejected: HTTP %d", response.StatusCode)
		}
		return fmt.Errorf("unexpected HTTP status: %d", response.StatusCode)
	}
	body, err := readLimitedIntegrationBody(response.Body)
	if err != nil {
		return err
	}
	var envelope tautulliEnvelope
	if json.Unmarshal(body, &envelope) != nil || !strings.EqualFold(envelope.Response.Result, "success") || len(envelope.Response.Data) == 0 {
		return errIntegrationResponse
	}
	decoder := json.NewDecoder(bytes.NewReader(envelope.Response.Data))
	decoder.UseNumber()
	if decoder.Decode(target) != nil {
		return errIntegrationResponse
	}
	return nil
}

func plexRequest(ctx context.Context, client *http.Client, endpoint *url.URL, token string) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return nil, errIntegrationResponse
	}
	request.Header.Set("Accept", "application/json, application/xml;q=0.9")
	request.Header.Set("X-Plex-Token", token)
	response, err := client.Do(request)
	if err != nil {
		return nil, classifyIntegrationTransportError(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		if response.StatusCode == http.StatusUnauthorized || response.StatusCode == http.StatusForbidden {
			return nil, fmt.Errorf("authentication rejected: HTTP %d", response.StatusCode)
		}
		return nil, fmt.Errorf("unexpected HTTP status: %d", response.StatusCode)
	}
	return readLimitedIntegrationBody(response.Body)
}

func newLANOnlyHTTPClient() *http.Client {
	dialer := &net.Dialer{Timeout: 8 * time.Second, KeepAlive: 15 * time.Second}
	transport := &http.Transport{
		Proxy:                 nil,
		DialContext:           lanOnlyDialContext(dialer),
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          4,
		IdleConnTimeout:       15 * time.Second,
		TLSHandshakeTimeout:   8 * time.Second,
		ResponseHeaderTimeout: 10 * time.Second,
	}
	return &http.Client{
		Transport: transport,
		Timeout:   15 * time.Second,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return errors.New("redirects are disabled for integration verification")
		},
	}
}

func lanOnlyDialContext(dialer *net.Dialer) func(context.Context, string, string) (net.Conn, error) {
	return func(ctx context.Context, network, address string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(address)
		if err != nil {
			return nil, errLANOnlyDestination
		}
		addresses, err := resolveLANAddresses(ctx, host)
		if err != nil {
			return nil, err
		}
		var lastErr error
		for _, ip := range addresses {
			connection, dialErr := dialer.DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
			if dialErr == nil {
				return connection, nil
			}
			lastErr = dialErr
		}
		if lastErr != nil {
			return nil, errIntegrationConnection
		}
		return nil, errLANOnlyDestination
	}
}

func resolveLANAddresses(ctx context.Context, host string) ([]net.IP, error) {
	if parsed := net.ParseIP(strings.Trim(host, "[]")); parsed != nil {
		if !allowedLANIP(parsed) {
			return nil, errLANOnlyDestination
		}
		return []net.IP{parsed}, nil
	}
	addresses, err := net.DefaultResolver.LookupIP(ctx, "ip", host)
	if err != nil || len(addresses) == 0 {
		return nil, errIntegrationConnection
	}
	for _, address := range addresses {
		if !allowedLANIP(address) {
			return nil, errLANOnlyDestination
		}
	}
	return addresses, nil
}

func allowedLANIP(ip net.IP) bool {
	return ip.IsLoopback() || ip.IsPrivate()
}

func parseLANBaseURL(raw string) (*url.URL, error) {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Host == "" || parsed.Scheme != "http" && parsed.Scheme != "https" {
		return nil, errIntegrationResponse
	}
	if parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return nil, errIntegrationResponse
	}
	if parsed.Port() != "" {
		port, err := strconv.Atoi(parsed.Port())
		if err != nil || port < 1 || port > 65535 {
			return nil, errIntegrationResponse
		}
	}
	if ip := net.ParseIP(parsed.Hostname()); ip != nil && !allowedLANIP(ip) {
		return nil, errLANOnlyDestination
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/")
	parsed.RawPath = ""
	return parsed, nil
}

func integrationEndpoint(base *url.URL, suffix string) *url.URL {
	endpoint := *base
	endpoint.Path = strings.TrimRight(base.Path, "/") + "/" + strings.TrimLeft(suffix, "/")
	endpoint.RawPath = ""
	endpoint.RawQuery = ""
	endpoint.Fragment = ""
	return &endpoint
}

func readLimitedIntegrationBody(reader io.Reader) ([]byte, error) {
	body, err := io.ReadAll(io.LimitReader(reader, maximumIntegrationResponseBytes+1))
	if err != nil || len(body) > maximumIntegrationResponseBytes {
		return nil, errIntegrationResponse
	}
	return body, nil
}

func plexMediaContainer(body []byte) (string, bool) {
	var jsonEnvelope struct {
		MediaContainer struct {
			MachineIdentifier string `json:"machineIdentifier"`
		} `json:"MediaContainer"`
	}
	if json.Unmarshal(body, &jsonEnvelope) == nil && strings.Contains(string(body), `"MediaContainer"`) {
		return strings.TrimSpace(jsonEnvelope.MediaContainer.MachineIdentifier), true
	}
	var xmlEnvelope struct {
		XMLName           xml.Name `xml:"MediaContainer"`
		MachineIdentifier string   `xml:"machineIdentifier,attr"`
	}
	if xml.Unmarshal(body, &xmlEnvelope) == nil && xmlEnvelope.XMLName.Local == "MediaContainer" {
		return strings.TrimSpace(xmlEnvelope.MachineIdentifier), true
	}
	return "", false
}

func failedIntegrationStep(service string, err error) IntegrationCheckStep {
	summary := "The configured service could not be verified. Confirm its address, credentials, and availability from this Manager runtime."
	switch {
	case errors.Is(err, errLANOnlyDestination):
		summary = "The configured destination was blocked because it did not resolve exclusively to private or loopback addresses."
	case errors.Is(err, errIntegrationConnection), errors.Is(err, context.DeadlineExceeded):
		summary = "The configured service could not be reached before the verification timeout."
	case strings.Contains(err.Error(), "authentication rejected"):
		summary = "The service rejected the configured credential. The credential value was not returned or logged."
	case strings.Contains(err.Error(), "unexpected HTTP status"):
		summary = "The service answered, but its HTTP status did not match the expected API contract."
	case errors.Is(err, errIntegrationResponse):
		summary = "The service answered, but its response did not match the expected API contract."
	}
	return IntegrationCheckStep{Service: service, State: "failed", Summary: summary}
}

func classifyIntegrationTransportError(err error) error {
	if errors.Is(err, errLANOnlyDestination) {
		return errLANOnlyDestination
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return context.DeadlineExceeded
	}
	return errIntegrationConnection
}

func configMapString(values map[string]any, name string) string {
	value, _ := values[name].(string)
	return strings.TrimSpace(value)
}

func integrationTruthy(value any) bool {
	switch typed := value.(type) {
	case bool:
		return typed
	case float64:
		return typed != 0
	case json.Number:
		return typed.String() != "0"
	case string:
		return typed == "1" || strings.EqualFold(typed, "true")
	default:
		return false
	}
}

func sanitizeEvidence(value string, maximum int) string {
	value = strings.Map(func(character rune) rune {
		if character < 32 || character == 127 {
			return -1
		}
		return character
	}, strings.TrimSpace(value))
	if len(value) > maximum {
		value = value[:maximum]
	}
	return value
}
