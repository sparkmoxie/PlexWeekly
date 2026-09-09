package manager

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestServerSecurityAndRedaction(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	data := t.TempDir()
	config := `{"ApiKey":"never-return-this","SmtpPassword":"also-private","ScheduleEnabled":false}`
	if err := os.WriteFile(filepath.Join(root, "config.json"), []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	server, err := New(Options{
		DataDir:        data,
		TautWeeklyRoot: root,
		Version:        "test",
		Now:            func() time.Time { return time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC) },
	})
	if err != nil {
		t.Fatal(err)
	}

	live := requestForTest(server, http.MethodGet, "/health/live", nil, nil)
	if live.Code != http.StatusOK {
		t.Fatalf("liveness status: got %d", live.Code)
	}
	unauthorized := requestForTest(server, http.MethodGet, "/api/v1/config", nil, nil)
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated config status: got %d", unauthorized.Code)
	}

	current, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}
	configResponse := requestForTest(server, http.MethodGet, "/api/v1/config", nil, cookie)
	if configResponse.Code != http.StatusOK {
		t.Fatalf("authenticated config status: got %d", configResponse.Code)
	}
	for _, secret := range []string{"never-return-this", "also-private"} {
		if strings.Contains(configResponse.Body.String(), secret) {
			t.Fatalf("config API returned secret %q", secret)
		}
	}
	logoutWithoutCSRF := requestForTest(server, http.MethodPost, "/api/v1/auth/logout", nil, cookie)
	if logoutWithoutCSRF.Code != http.StatusForbidden {
		t.Fatalf("logout without CSRF: got %d, want 403", logoutWithoutCSRF.Code)
	}

	request := httptest.NewRequest(http.MethodGet, "/health/live", nil)
	request.Host = "attacker.example"
	invalidHost := httptest.NewRecorder()
	server.Handler().ServeHTTP(invalidHost, request)
	if invalidHost.Code != http.StatusBadRequest {
		t.Fatalf("invalid Host status: got %d, want 400", invalidHost.Code)
	}
}

func TestOriginAuthorityCanonicalizationKeepsExactSameOrigin(t *testing.T) {
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: t.TempDir(), Version: "test", RuntimeMode: runtimeModeMac})
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name   string
		host   string
		origin string
		want   string
	}{
		{name: "default mac localhost", host: "localhost:8787", origin: "http://localhost:8787"},
		{name: "HTTP default port omitted in origin", host: "localhost:80", origin: "http://localhost"},
		{name: "HTTP default port omitted in Host", host: "localhost", origin: "http://localhost:80"},
		{name: "DNS case and trailing dot", host: "LOCALHOST.:8787", origin: "http://localhost:8787"},
		{name: "cross origin", host: "localhost:8787", origin: "http://127.0.0.1:8787", want: "origin-host-mismatch"},
		{name: "scheme mismatch", host: "localhost:8787", origin: "https://localhost:8787", want: "origin-scheme-mismatch"},
		{name: "malformed origin", host: "localhost:8787", origin: "http://localhost:8787/path", want: "invalid-origin"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, "/api/v1/auth/logout", nil)
			request.Host = test.host
			request.Header.Set("Origin", test.origin)
			if got := server.originRejectionCode(request); got != test.want {
				t.Fatalf("origin rejection code: got %q, want %q", got, test.want)
			}
			if test.want == "" && !server.allowedHost(test.host) {
				t.Fatalf("canonical Host %q was not allowlisted", test.host)
			}
		})
	}
}

func TestStaticRootServesIndexWithoutRedirect(t *testing.T) {
	t.Parallel()
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: t.TempDir(), Version: "test"})
	if err != nil {
		t.Fatal(err)
	}

	response := requestForTest(server, http.MethodGet, "/", nil, nil)
	if response.Code != http.StatusOK {
		t.Fatalf("static root status: got %d, want 200", response.Code)
	}
	if location := response.Header().Get("Location"); location != "" {
		t.Fatalf("static root redirected to %q", location)
	}
	if !strings.Contains(response.Body.String(), "TautWeekly Manager") {
		t.Fatal("static root did not serve the embedded application shell")
	}
	document := response.Body.String()
	for _, expected := range []string{
		"<title>" + windowsManagerBrowserTitle + "</title>",
		`<meta name="description" content="` + windowsManagerSocialDescription + `">`,
		`<meta property="og:title" content="` + windowsManagerSocialTitle + `">`,
		`<meta property="og:type" content="website">`,
		`<meta property="og:image" content="http://127.0.0.1:8788/manager-social-preview.jpg">`,
		`<meta property="og:url" content="http://127.0.0.1:8788/">`,
		`<meta property="og:image:width" content="1280">`,
		`<meta property="og:image:height" content="640">`,
		`<meta name="twitter:card" content="summary_large_image">`,
		`<link rel="icon" href="/favicon.ico" type="image/x-icon" sizes="16x16 24x24 32x32">`,
		`<link rel="icon" href="/tautweekly-icon-192.png" type="image/png" sizes="192x192">`,
	} {
		if !strings.Contains(document, expected) {
			t.Fatalf("Windows Manager document omitted sharing or favicon metadata: %s", expected)
		}
	}
	if strings.Contains(document, "og:image:secure_url") {
		t.Fatal("loopback HTTP document advertised a secure image URL")
	}
	if cache := response.Header().Get("Cache-Control"); cache != "no-store" {
		t.Fatalf("static application cache policy: got %q, want no-store", cache)
	}
	if !strings.Contains(response.Body.String(), "checked means excluded") || !strings.Contains(response.Body.String(), "notification-agent settings do not control TautWeekly delivery") {
		t.Fatal("static application shell omitted the explicit production-recipient policy")
	}
	app := requestForTest(server, http.MethodGet, "/app.js", nil, nil)
	if app.Code != http.StatusOK || !strings.Contains(app.Body.String(), "no-eligible-recipients") || !strings.Contains(app.Body.String(), "origin-host-mismatch") || !strings.Contains(app.Body.String(), "exact loopback recovery URL") || !strings.Contains(app.Body.String(), "independently verified Funnel address") || !strings.Contains(app.Body.String(), "No configuration was saved") || !strings.Contains(app.Body.String(), "(unsaved)") {
		t.Fatalf("production JavaScript omitted recipient/origin guidance: status=%d", app.Code)
	}
	favicon := requestForTest(server, http.MethodGet, "/favicon.ico", nil, nil)
	if favicon.Code != http.StatusOK || favicon.Header().Get("Content-Type") != "image/x-icon" || len(favicon.Body.Bytes()) < 4 || !bytes.Equal(favicon.Body.Bytes()[:4], []byte{0, 0, 1, 0}) {
		t.Fatalf("Windows Manager favicon contract failed: status=%d type=%q bytes=%d", favicon.Code, favicon.Header().Get("Content-Type"), favicon.Body.Len())
	}
}

func TestIntegratedLinuxManagerExposesPublicSocialMetadataAndAsset(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	assetPath := filepath.Join(root, filepath.FromSlash(windowsManagerSocialImageRelativePath))
	if err := os.MkdirAll(filepath.Dir(assetPath), 0o700); err != nil {
		t.Fatal(err)
	}
	image := []byte{0xff, 0xd8, 0xff, 0xd9}
	if err := os.WriteFile(assetPath, image, 0o600); err != nil {
		t.Fatal(err)
	}
	server, err := New(Options{
		DataDir:                t.TempDir(),
		TautWeeklyRoot:         root,
		Version:                "test",
		RuntimeMode:            runtimeModeLinux,
		remoteAccessController: newPublicFunnelController(t.TempDir(), "127.0.0.1:8788", "test-funnel.json", true, nil),
	})
	if err != nil {
		t.Fatal(err)
	}

	rootResponse := requestForTest(server, http.MethodGet, "/", nil, nil)
	if rootResponse.Code != http.StatusOK ||
		!strings.Contains(rootResponse.Body.String(), "property=\"og:image\"") ||
		!strings.Contains(rootResponse.Body.String(), "content=\"http://127.0.0.1:8788/manager-social-preview.jpg\"") {
		t.Fatalf("integrated Linux Manager omitted public sharing metadata: code=%d", rootResponse.Code)
	}
	assetResponse := requestForTest(server, http.MethodGet, windowsManagerSocialImagePath, nil, nil)
	if assetResponse.Code != http.StatusOK || !bytes.Equal(assetResponse.Body.Bytes(), image) {
		t.Fatalf("integrated Linux Manager social image contract failed: code=%d bytes=%d", assetResponse.Code, assetResponse.Body.Len())
	}
}

func TestEmbeddedTitleGifAssetsAreLocalAndByteIdentical(t *testing.T) {
	t.Parallel()
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: t.TempDir(), Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	expected := map[string]string{
		"celebrate.gif":    "A142E1EB25D6277BF95A3086221BA141700E1EF96FC47C3B6A3E1919A4D18FB1",
		"construction.gif": "08B3B20C4240E4EEA16F3E72645B0D49A705314B8396BF2D7B8D853926855638",
		"rocket.gif":       "38FC98792F107C94ECCB9DE2B4561AF9837644978E8FD35AA9950B4598D4522A",
		"tickets.gif":      "332193167C44D5B73DE43DB86B8AD11064EEF61744DF043A26A768E020EAF669",
		"warning.gif":      "AE9913885C0B0579A9548F30C0D06629A007175628F24D715E63E572FEB749B8",
		"alert.gif":        "5519D94DEAAA5F0CEE21F5F2F2CBB589145820C86E47FCAA423C5A1A58561B37",
	}
	for name, wantHash := range expected {
		response := requestForTest(server, http.MethodGet, "/media/"+name, nil, nil)
		if response.Code != http.StatusOK || response.Header().Get("Content-Type") != "image/gif" {
			t.Fatalf("embedded %s: status=%d type=%q", name, response.Code, response.Header().Get("Content-Type"))
		}
		digest := sha256.Sum256(response.Body.Bytes())
		if got := strings.ToUpper(hex.EncodeToString(digest[:])); got != wantHash {
			t.Fatalf("embedded %s SHA-256: got %s, want %s", name, got, wantHash)
		}
	}
}

func TestBooleanConfigurationTogglesPersistAcrossPackageVariants(t *testing.T) {
	tests := []struct {
		kind string
		mode string
	}{
		{packageKindWindows, runtimeModeWindows},
		{packageKindMac, runtimeModeMac},
		{packageKindNAS, runtimeModeNAS},
		{packageKindQNAP, runtimeModeNAS},
		{packageKindUnraid, runtimeModeNAS},
		{packageKindCompatibleDocker, runtimeModeNAS},
		{packageKindLinux, runtimeModeLinux},
		{packageKindFreeBSD, runtimeModeNAS},
	}
	for _, test := range tests {
		t.Run(test.kind, func(t *testing.T) {
			root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
			server, err := New(Options{
				DataDir:        t.TempDir(),
				TautWeeklyRoot: root,
				RuntimeRoot:    root,
				Version:        "test",
				RuntimeMode:    test.mode,
				PackageKind:    test.kind,
			})
			if err != nil {
				t.Fatal(err)
			}
			session, err := server.auth.newSession()
			if err != nil {
				t.Fatal(err)
			}
			cookie := &http.Cookie{Name: sessionCookieName, Value: session.Token}
			mutation := validConfigSaveRequest(t, ReadConfigEditor(root))
			for _, name := range []string{"SmtpEnableSsl", "SmtpUseAuthentication", "DeletedItemCacheEnabled"} {
				mutation.Values[name] = json.RawMessage(`false`)
			}
			body, err := json.Marshal(mutation)
			if err != nil {
				t.Fatal(err)
			}
			saved := mutationRequestForTest(server, http.MethodPut, "/api/v1/config", body, cookie, session.CSRFToken)
			if saved.Code != http.StatusOK {
				t.Fatalf("configuration save: got %d, body %s", saved.Code, saved.Body.String())
			}
			persisted := ReadConfigEditor(root)
			for _, name := range []string{"SmtpEnableSsl", "SmtpUseAuthentication", "DeletedItemCacheEnabled"} {
				field := editorField(t, persisted, name)
				value, ok := field.Value.(bool)
				if !ok || value {
					t.Fatalf("%s did not persist false for %s: %#v", name, test.kind, field.Value)
				}
			}
		})
	}
}

func TestServerNormalizesRelativeRuntimePaths(t *testing.T) {
	base := t.TempDir()
	t.Chdir(base)
	relativeRoot := "root"
	relativeData := "data"
	root := filepath.Join(base, relativeRoot)
	data := filepath.Join(base, relativeData)
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(data, 0o700); err != nil {
		t.Fatal(err)
	}
	server, err := New(Options{DataDir: relativeData, TautWeeklyRoot: relativeRoot, Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	if !filepath.IsAbs(server.options.TautWeeklyRoot) || !filepath.IsAbs(server.options.DataDir) {
		t.Fatalf("runtime paths were not normalized: root=%q data=%q", server.options.TautWeeklyRoot, server.options.DataDir)
	}
	if server.operations.root != server.options.TautWeeklyRoot || server.operations.dataDir != server.options.DataDir {
		t.Fatalf("operation coordinator received different normalized paths: %+v", server.operations)
	}
}

func TestPairingEndpointCreatesSessionWhenRuntimeRequiresAuthentication(t *testing.T) {
	t.Parallel()
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: t.TempDir(), Version: "test", RequireAuthentication: true})
	if err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(authRequest{Token: server.BootstrapToken(), Password: "lock8888"})
	if err != nil {
		t.Fatal(err)
	}
	response := requestForTest(server, http.MethodPost, "/api/v1/auth/pair", bytes.NewReader(body), nil)
	if response.Code != http.StatusCreated {
		t.Fatalf("pairing status: got %d, body %s", response.Code, response.Body.String())
	}
	if len(response.Result().Cookies()) != 1 {
		t.Fatal("pairing did not issue a session cookie")
	}
	if _, err := os.Stat(filepath.Join(server.options.DataDir, "bootstrap-token.txt")); !os.IsNotExist(err) {
		t.Fatalf("pairing token was not invalidated: %v", err)
	}
}

func TestTrustedLocalSessionAndOptionalPasswordLifecycle(t *testing.T) {
	t.Parallel()
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: t.TempDir(), Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	sessionResponseRecorder := requestForTest(server, http.MethodGet, "/api/v1/auth/session", nil, nil)
	if sessionResponseRecorder.Code != http.StatusOK || len(sessionResponseRecorder.Result().Cookies()) != 1 {
		t.Fatalf("trusted-local session: got %d, cookies %d, body %s", sessionResponseRecorder.Code, len(sessionResponseRecorder.Result().Cookies()), sessionResponseRecorder.Body.String())
	}
	var sessionPayload sessionResponse
	if err := json.Unmarshal(sessionResponseRecorder.Body.Bytes(), &sessionPayload); err != nil {
		t.Fatal(err)
	}
	cookie := sessionResponseRecorder.Result().Cookies()[0]
	passwordBody, _ := json.Marshal(accessPasswordRequest{Password: "lock8888"})
	locked := mutationRequestForTest(server, http.MethodPost, "/api/v1/auth/access/password", passwordBody, cookie, sessionPayload.CSRFToken)
	if locked.Code != http.StatusOK || !strings.Contains(locked.Body.String(), `"authenticationRequired":true`) {
		t.Fatalf("enable optional lock: got %d, body %s", locked.Code, locked.Body.String())
	}
	freshSession := requestForTest(server, http.MethodGet, "/api/v1/auth/session", nil, nil)
	if freshSession.Code != http.StatusUnauthorized {
		t.Fatalf("locked Manager created an unauthenticated session: got %d", freshSession.Code)
	}
	loginBody, _ := json.Marshal(authRequest{Password: "lock8888"})
	login := requestForTest(server, http.MethodPost, "/api/v1/auth/login", bytes.NewReader(loginBody), nil)
	if login.Code != http.StatusOK {
		t.Fatalf("optional lock login: got %d, body %s", login.Code, login.Body.String())
	}
	disabled := mutationRequestForTest(server, http.MethodPost, "/api/v1/auth/access/disable", []byte(`{}`), cookie, sessionPayload.CSRFToken)
	if disabled.Code != http.StatusOK || !strings.Contains(disabled.Body.String(), `"authenticationRequired":false`) {
		t.Fatalf("disable optional lock: got %d, body %s", disabled.Code, disabled.Body.String())
	}
}

func TestDiagnosticsAPIRequiresAuthenticationAndReturnsSanitizedSetupEvents(t *testing.T) {
	root := t.TempDir()
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	unauthorized := requestForTest(server, http.MethodGet, "/api/v1/diagnostics", nil, nil)
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated diagnostics: got %d, want 401", unauthorized.Code)
	}
	current, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}
	mutation := validConfigSaveRequest(t, ReadConfigEditor(root))
	mutation.Secrets["ApiKey"] = SecretChange{Action: "replace", Value: "diagnostic-api-secret"}
	mutation.Secrets["SmtpPassword"] = SecretChange{Action: "replace", Value: "diagnostic-smtp-secret"}
	body, err := json.Marshal(mutation)
	if err != nil {
		t.Fatal(err)
	}
	saved := mutationRequestForTest(server, http.MethodPut, "/api/v1/config", body, cookie, current.CSRFToken)
	if saved.Code != http.StatusOK {
		t.Fatalf("configuration save: got %d, body %s", saved.Code, saved.Body.String())
	}
	diagnostics := requestForTest(server, http.MethodGet, "/api/v1/diagnostics", nil, cookie)
	if diagnostics.Code != http.StatusOK || !strings.Contains(diagnostics.Body.String(), `"code":"config-saved"`) || !strings.Contains(diagnostics.Body.String(), `"maximumEntries":20`) || !strings.Contains(diagnostics.Body.String(), `"retentionPolicy":"count-only-fifo"`) {
		t.Fatalf("diagnostics response: got %d, body %s", diagnostics.Code, diagnostics.Body.String())
	}
	for _, forbidden := range []string{"diagnostic-api-secret", "diagnostic-smtp-secret", root, "config.json"} {
		if strings.Contains(strings.ToLower(diagnostics.Body.String()), strings.ToLower(forbidden)) {
			t.Fatalf("diagnostics response retained private value %q: %s", forbidden, diagnostics.Body.String())
		}
	}
}

func TestIntegrationCheckPresentationIdentifiesComponentWithoutRawEvidence(t *testing.T) {
	tests := []struct {
		name        string
		result      IntegrationCheckResult
		wantState   string
		wantCode    string
		wantSummary string
	}{
		{
			name: "optional direct Plex omitted",
			result: IntegrationCheckResult{Overall: "passed", Steps: []IntegrationCheckStep{
				{Service: "tautulli", State: "passed"},
				{Service: "plex", State: "skipped"},
			}},
			wantState:   "passed",
			wantCode:    "verification-passed-plex-skipped",
			wantSummary: "Optional direct Plex verification was skipped",
		},
		{
			name: "direct Plex failure",
			result: IntegrationCheckResult{Overall: "failed", Steps: []IntegrationCheckStep{
				{Service: "tautulli", State: "passed"},
				{Service: "plex", State: "failed", Summary: "private raw evidence must not be retained"},
			}},
			wantState:   "failed",
			wantCode:    "verification-plex-failed",
			wantSummary: "Direct Plex verification failed",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			state, summary, code := integrationCheckPresentation(test.result)
			if state != test.wantState || code != test.wantCode || !strings.Contains(summary, test.wantSummary) {
				t.Fatalf("presentation: got state=%q summary=%q code=%q", state, summary, code)
			}
			if strings.Contains(summary, "private raw evidence") {
				t.Fatalf("presentation retained raw step evidence: %q", summary)
			}
		})
	}
}

func TestConfigurationStatusAPIIsRevisionScopedAndPersists(t *testing.T) {
	root := t.TempDir()
	data := t.TempDir()
	server, err := New(Options{DataDir: data, TautWeeklyRoot: root, Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	current, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}
	initial := requestForTest(server, http.MethodGet, "/api/v1/config/status", nil, cookie)
	if initial.Code != http.StatusOK || !strings.Contains(initial.Body.String(), `"available":false`) {
		t.Fatalf("unconfigured status: got %d, body %s", initial.Code, initial.Body.String())
	}

	mutation := validConfigSaveRequest(t, ReadConfigEditor(root))
	mutation.Secrets["ApiKey"] = SecretChange{Action: "replace", Value: "configuration-status-api-key"}
	mutation.Secrets["SmtpPassword"] = SecretChange{Action: "replace", Value: "configuration-status-smtp-password"}
	body, err := json.Marshal(mutation)
	if err != nil {
		t.Fatal(err)
	}
	saved := mutationRequestForTest(server, http.MethodPut, "/api/v1/config", body, cookie, current.CSRFToken)
	if saved.Code != http.StatusOK {
		t.Fatalf("configuration save: got %d, body %s", saved.Code, saved.Body.String())
	}
	revision := ReadConfigEditor(root).Revision
	statusResponse := requestForTest(server, http.MethodGet, "/api/v1/config/status", nil, cookie)
	if statusResponse.Code != http.StatusOK {
		t.Fatalf("configuration status: got %d, body %s", statusResponse.Code, statusResponse.Body.String())
	}
	var status ConfigurationStatus
	if err := json.Unmarshal(statusResponse.Body.Bytes(), &status); err != nil {
		t.Fatal(err)
	}
	if !status.Available || !status.Running || status.ConfigRevision != revision {
		t.Fatalf("unexpected saved configuration status: %+v", status)
	}
	for _, name := range configurationStatusSteps {
		expectedState := "waiting"
		if name == "cache" {
			expectedState = "running"
		}
		if status.Steps[name].State != expectedState {
			t.Fatalf("step %s state: got %q, want %s", name, status.Steps[name].State, expectedState)
		}
	}

	skipBody, _ := json.Marshal(skipConfigurationPreviewsRequest{ExpectedRevision: revision, Reason: "metadata-not-ready"})
	skipped := mutationRequestForTest(server, http.MethodPost, "/api/v1/config/status/previews/skipped", skipBody, cookie, current.CSRFToken)
	if skipped.Code != http.StatusOK || !strings.Contains(skipped.Body.String(), `"state":"skipped"`) {
		t.Fatalf("skip preview status: got %d, body %s", skipped.Code, skipped.Body.String())
	}
	discoverySkipBody, _ := json.Marshal(skipConfigurationPreviewsRequest{ExpectedRevision: revision, Reason: "discovery-failed"})
	discoverySkipped := mutationRequestForTest(server, http.MethodPost, "/api/v1/config/status/previews/skipped", discoverySkipBody, cookie, current.CSRFToken)
	if discoverySkipped.Code != http.StatusOK || !strings.Contains(discoverySkipped.Body.String(), "Preview generation was skipped because Tautulli choices could not be refreshed") || strings.Contains(discoverySkipped.Body.String(), "unambiguous owner") {
		t.Fatalf("failed-discovery preview status was masked: got %d, body %s", discoverySkipped.Code, discoverySkipped.Body.String())
	}
	completedAt := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	if err := server.configuration.StoreIntegrationCheck(revision, IntegrationCheckResult{
		Mode:            "real-lan",
		NetworkBoundary: "private-and-loopback-only",
		Overall:         "passed",
		StartedAtUTC:    completedAt.Add(-time.Second).Format(time.RFC3339),
		CompletedAtUTC:  completedAt.Format(time.RFC3339),
		ConfigRevision:  revision,
		Steps: []IntegrationCheckStep{
			{Service: "tautulli", State: "passed", Summary: "Authenticated Tautulli API compatibility passed."},
			{Service: "plex", State: "passed", Summary: "Authenticated direct Plex compatibility passed."},
		},
	}); err != nil {
		t.Fatal(err)
	}
	if err := server.configuration.StoreSMTPCheck(revision, SMTPNetworkCheckResult{Mode: "smtp-network", Overall: "passed", State: "passed", Security: "starttls-validated", CompletedAtUTC: completedAt.Format(time.RFC3339), ConfigRevision: revision, Summary: "SMTP connectivity and certificate-validated STARTTLS passed."}); err != nil {
		t.Fatal(err)
	}

	restarted, err := New(Options{DataDir: data, TautWeeklyRoot: root, Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	restartedSession, err := restarted.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	restartedCookie := &http.Cookie{Name: sessionCookieName, Value: restartedSession.Token}
	persisted := requestForTest(restarted, http.MethodGet, "/api/v1/config/status", nil, restartedCookie)
	if persisted.Code != http.StatusOK || !strings.Contains(persisted.Body.String(), `"state":"skipped"`) {
		t.Fatalf("persisted configuration status: got %d, body %s", persisted.Code, persisted.Body.String())
	}
	verification := requestForTest(restarted, http.MethodGet, "/api/v1/checks/integrations", nil, restartedCookie)
	if verification.Code != http.StatusOK || !strings.Contains(verification.Body.String(), `"service":"tautulli","state":"passed"`) || !strings.Contains(verification.Body.String(), `"smtp":{"mode":"smtp-network","overall":"passed"`) {
		t.Fatalf("persisted verification status: got %d, body %s", verification.Code, verification.Body.String())
	}
}

func TestDiscoveryCacheAPIRequiresAuthenticationAndSurvivesManagerRestart(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "cached-api-secret", "", "")
	data := t.TempDir()
	server, err := New(Options{DataDir: data, TautWeeklyRoot: root, Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	revision := ReadConfigEditor(root).Revision
	result := TautulliDiscoveryResult{
		Mode:            "real-lan-discovery",
		NetworkBoundary: "private-and-loopback-only",
		CompletedAtUTC:  "2031-04-18T16:30:00Z",
		ConfigRevision:  revision,
		Libraries:       []DiscoveredLibrary{{ID: "10", Name: "Fictional Movies", MediaType: "movie"}},
		Users:           []DiscoveredUser{{ID: "1", Name: "Fictional Owner", Eligibility: "eligible", Role: "owner"}},
	}
	if err := server.discovery.Save(result); err != nil {
		t.Fatal(err)
	}
	unauthorized := requestForTest(server, http.MethodGet, "/api/v1/discovery/tautulli", nil, nil)
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated discovery cache: got %d, want 401", unauthorized.Code)
	}
	restarted, err := New(Options{DataDir: data, TautWeeklyRoot: root, Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	current, err := restarted.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}
	response := requestForTest(restarted, http.MethodGet, "/api/v1/discovery/tautulli", nil, cookie)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"suggestedPreviewUserId":"1"`) || !strings.Contains(response.Body.String(), "Fictional Movies") {
		t.Fatalf("cached discovery response: got %d, body %s", response.Code, response.Body.String())
	}
	for _, forbidden := range []string{"cached-api-secret", root, "config.json"} {
		if strings.Contains(strings.ToLower(response.Body.String()), strings.ToLower(forbidden)) {
			t.Fatalf("cached discovery response retained private value %q", forbidden)
		}
	}
}

func TestDiscoveryLiveFailureKeepsCacheAndReportsSanitizedStage(t *testing.T) {
	const secret = "fictional-retained-discovery-secret"
	tautulli := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v2" || r.URL.Query().Get("apikey") != secret {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		switch r.URL.Query().Get("cmd") {
		case "get_libraries", "get_libraries_table":
			_ = json.NewEncoder(w).Encode(map[string]any{"response": map[string]any{
				"result":  "error",
				"message": "private upstream detail must not escape",
				"data":    map[string]any{"private": "private library response"},
			}})
		default:
			http.Error(w, "unexpected command", http.StatusBadRequest)
		}
	}))
	defer tautulli.Close()

	root := integrationConfigRoot(t, tautulli.URL, secret, "", "")
	mappingRequest := validConfigSaveRequest(t, ReadConfigEditor(root))
	mappingRequest.Values["UserEmailOverrides"] = json.RawMessage(`{"7":"retained-managed@example.org"}`)
	mappingResult, mappingFields, err := SaveConfig(root, mappingRequest, time.Now)
	if err != nil || !mappingResult.Saved || len(mappingFields) != 0 {
		t.Fatalf("seed managed-user mapping: saved=%t fields=%v err=%v", mappingResult.Saved, mappingFields, err)
	}
	data := t.TempDir()
	server, err := New(Options{
		DataDir:        data,
		TautWeeklyRoot: root,
		Version:        "test",
		Now:            func() time.Time { return time.Date(2031, 4, 18, 16, 35, 0, 0, time.UTC) },
	})
	if err != nil {
		t.Fatal(err)
	}
	revision := ReadConfigEditor(root).Revision
	cached := TautulliDiscoveryResult{
		Mode:            "real-lan-discovery",
		NetworkBoundary: "private-and-loopback-only",
		CompletedAtUTC:  "2031-04-18T16:30:00Z",
		ConfigRevision:  revision,
		Libraries:       []DiscoveredLibrary{{ID: "10", Name: "Fictional Cached Movies", MediaType: "movie"}},
		Users:           []DiscoveredUser{{ID: "1", Name: "Fictional Cached Owner", Eligibility: "eligible", Role: "owner"}},
	}
	if err := server.discovery.Save(cached); err != nil {
		t.Fatal(err)
	}
	session, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: session.Token}
	body, err := json.Marshal(TautulliDiscoveryRequest{ExpectedRevision: revision, ConfirmRealNetwork: true})
	if err != nil {
		t.Fatal(err)
	}
	response := mutationRequestForTest(server, http.MethodPost, "/api/v1/discovery/tautulli", body, cookie, session.CSRFToken)
	if response.Code != http.StatusBadGateway || !strings.Contains(response.Body.String(), "\"code\":\"discovery-libraries-failed\"") {
		t.Fatalf("live discovery failure: got %d, body %s", response.Code, response.Body.String())
	}
	if !strings.Contains(response.Body.String(), "Live Tautulli library roster refresh failed") ||
		!strings.Contains(response.Body.String(), "fresh Tautulli/Plex check") {
		t.Fatalf("live discovery failure did not provide safe stage guidance: %s", response.Body.String())
	}
	for _, private := range []string{secret, tautulli.URL, "private upstream detail", "private library response", root, "config.json"} {
		if strings.Contains(strings.ToLower(response.Body.String()), strings.ToLower(private)) {
			t.Fatalf("live discovery failure returned private value %q: %s", private, response.Body.String())
		}
	}

	retained := requestForTest(server, http.MethodGet, "/api/v1/discovery/tautulli", nil, cookie)
	if retained.Code != http.StatusOK || !strings.Contains(retained.Body.String(), "\"retained\":true") ||
		!strings.Contains(retained.Body.String(), "Fictional Cached Movies") ||
		!strings.Contains(retained.Body.String(), cached.CompletedAtUTC) {
		t.Fatalf("failed live refresh changed or hid the retained cache: %d %s", retained.Code, retained.Body.String())
	}
	mapping := editorField(t, ReadConfigEditor(root), "UserEmailOverrides").Value.(map[string]any)
	if mapping["7"] != "retained-managed@example.org" {
		t.Fatalf("failed live refresh changed the private managed-user mapping: %#v", mapping)
	}
	status := server.configuration.Load(revision)
	choiceStep := status.Steps["choices"]
	if choiceStep.State != "failed" || !strings.Contains(choiceStep.Summary, "previous sanitized choices remain retained and usable") {
		t.Fatalf("retained/live setup evidence is ambiguous: %+v", choiceStep)
	}
	history := server.diagnostics.History()
	if len(history.Events) == 0 || history.Events[0].Code != "discovery-libraries-failed" ||
		!strings.Contains(history.Events[0].Summary, "prior sanitized choice cache was left unchanged") {
		t.Fatalf("missing sanitized discovery-stage diagnostic: %+v", history.Events)
	}
}

func TestFailedDiscoveryCopyClassifiesWrappedErrors(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want string
	}{
		{name: "authentication", err: errors.New("authentication rejected: HTTP 401"), want: "rejected the saved API credential"},
		{name: "http status", err: errors.New("unexpected HTTP status: 503"), want: "unexpected HTTP status"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, message := failedDiscoveryCopy("users", wrapTautulliDiscoveryError("users", test.err), false)
			if !strings.Contains(message, test.want) || strings.Contains(message, test.err.Error()) {
				t.Fatalf("wrapped failure was not classified and sanitized: %q", message)
			}
		})
	}
}

func TestConfigurationMutationRequiresCSRFAndNeverReturnsSecrets(t *testing.T) {
	root := t.TempDir()
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	current, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}
	mutation := validConfigSaveRequest(t, ReadConfigEditor(root))
	mutation.Secrets["ApiKey"] = SecretChange{Action: "replace", Value: "api-secret-never-return"}
	mutation.Secrets["SmtpPassword"] = SecretChange{Action: "replace", Value: "smtp-secret-never-return"}
	body, err := json.Marshal(mutation)
	if err != nil {
		t.Fatal(err)
	}

	withoutCSRF := requestForTest(server, http.MethodPut, "/api/v1/config", bytes.NewReader(body), cookie)
	if withoutCSRF.Code != http.StatusForbidden {
		t.Fatalf("configuration write without CSRF: got %d, want 403", withoutCSRF.Code)
	}

	request := httptest.NewRequest(http.MethodPut, "/api/v1/config", bytes.NewReader(body))
	request.Host = "127.0.0.1:8788"
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Origin", "http://127.0.0.1:8788")
	request.Header.Set("X-CSRF-Token", current.CSRFToken)
	request.AddCookie(cookie)
	response := httptest.NewRecorder()
	server.Handler().ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("configuration write: got %d, body %s", response.Code, response.Body.String())
	}
	for _, secret := range []string{"api-secret-never-return", "smtp-secret-never-return"} {
		if strings.Contains(response.Body.String(), secret) {
			t.Fatalf("configuration write response returned %q", secret)
		}
	}
	if _, err := os.Stat(filepath.Join(root, "config.json")); err != nil {
		t.Fatalf("configuration was not saved: %v", err)
	}
}

func TestSecretRevealRequiresCSRFPasswordAndCurrentRevision(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "requested-api-secret", "", "other-plex-secret")
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Version: "test", RequireAuthentication: true})
	if err != nil {
		t.Fatal(err)
	}
	const password = "correct horse weekly battery"
	current, err := server.auth.pair(server.BootstrapToken(), password)
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}
	revision := ReadConfigEditor(root).Revision
	body, _ := json.Marshal(secretRevealRequest{ExpectedRevision: revision, Password: password})

	withoutCSRF := requestForTest(server, http.MethodPost, "/api/v1/config/secrets/ApiKey/reveal", bytes.NewReader(body), cookie)
	if withoutCSRF.Code != http.StatusForbidden {
		t.Fatalf("secret reveal without CSRF: got %d, want 403", withoutCSRF.Code)
	}
	wrongBody, _ := json.Marshal(secretRevealRequest{ExpectedRevision: revision, Password: "incorrect password"})
	wrong := mutationRequestForTest(server, http.MethodPost, "/api/v1/config/secrets/ApiKey/reveal", wrongBody, cookie, current.CSRFToken)
	if wrong.Code != http.StatusUnauthorized || strings.Contains(wrong.Body.String(), "requested-api-secret") {
		t.Fatalf("wrong-password reveal: got %d, body %s", wrong.Code, wrong.Body.String())
	}

	revealed := mutationRequestForTest(server, http.MethodPost, "/api/v1/config/secrets/ApiKey/reveal", body, cookie, current.CSRFToken)
	if revealed.Code != http.StatusOK || !strings.Contains(revealed.Body.String(), "requested-api-secret") {
		t.Fatalf("secret reveal: got %d, body %s", revealed.Code, revealed.Body.String())
	}
	if strings.Contains(revealed.Body.String(), "other-plex-secret") || strings.Contains(revealed.Body.String(), "fictional-smtp-secret") {
		t.Fatalf("secret reveal returned another credential: %s", revealed.Body.String())
	}
	if cache := revealed.Header().Get("Cache-Control"); cache != "no-store" {
		t.Fatalf("secret reveal cache policy: got %q", cache)
	}

	unknown := mutationRequestForTest(server, http.MethodPost, "/api/v1/config/secrets/FromEmail/reveal", body, cookie, current.CSRFToken)
	if unknown.Code != http.StatusNotFound || strings.Contains(unknown.Body.String(), "requested-api-secret") {
		t.Fatalf("unsupported secret reveal: got %d, body %s", unknown.Code, unknown.Body.String())
	}
	staleBody, _ := json.Marshal(secretRevealRequest{ExpectedRevision: "stale", Password: password})
	stale := mutationRequestForTest(server, http.MethodPost, "/api/v1/config/secrets/ApiKey/reveal", staleBody, cookie, current.CSRFToken)
	if stale.Code != http.StatusConflict || strings.Contains(stale.Body.String(), "requested-api-secret") {
		t.Fatalf("stale secret reveal: got %d, body %s", stale.Code, stale.Body.String())
	}
}

func TestTrustedLocalSecretRevealNeedsExplicitSessionAndCSRFButNoPassword(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "trusted-local-api-secret", "", "")
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	sessionRecorder := requestForTest(server, http.MethodGet, "/api/v1/auth/session", nil, nil)
	var current sessionResponse
	if err := json.Unmarshal(sessionRecorder.Body.Bytes(), &current); err != nil {
		t.Fatal(err)
	}
	cookie := sessionRecorder.Result().Cookies()[0]
	body, _ := json.Marshal(secretRevealRequest{ExpectedRevision: ReadConfigEditor(root).Revision})
	revealed := mutationRequestForTest(server, http.MethodPost, "/api/v1/config/secrets/ApiKey/reveal", body, cookie, current.CSRFToken)
	if revealed.Code != http.StatusOK || !strings.Contains(revealed.Body.String(), "trusted-local-api-secret") {
		t.Fatalf("trusted-local secret reveal: got %d, body %s", revealed.Code, revealed.Body.String())
	}
}

func TestBackupAndRealCheckAPIsAreGuardedAndSanitized(t *testing.T) {
	root := integrationConfigRoot(t, "http://203.0.113.10:8181", "api-secret-never-return", "", "")
	configRaw, err := os.ReadFile(filepath.Join(root, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	backupID := "config.backup.20310418-163000.000000000Z.json"
	if err := os.WriteFile(filepath.Join(root, backupID), configRaw, 0o600); err != nil {
		t.Fatal(err)
	}
	setIntegrationConfigValues(t, root, map[string]any{"SmtpHost": "0.0.0.0"})
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	current, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}

	backups := requestForTest(server, http.MethodGet, "/api/v1/config/backups", nil, cookie)
	if backups.Code != http.StatusOK || !strings.Contains(backups.Body.String(), backupID) || !strings.Contains(backups.Body.String(), `"maximumEntries":10`) || !strings.Contains(backups.Body.String(), `"retentionPolicy":"newest-first-fifo"`) {
		t.Fatalf("backup list: got %d, body %s", backups.Code, backups.Body.String())
	}
	if strings.Contains(backups.Body.String(), "api-secret-never-return") {
		t.Fatal("backup list returned a stored API key")
	}

	checkBody, err := json.Marshal(RealIntegrationCheckRequest{ExpectedRevision: ReadConfigEditor(root).Revision, ConfirmRealNetwork: true})
	if err != nil {
		t.Fatal(err)
	}
	withoutCSRF := requestForTest(server, http.MethodPost, "/api/v1/checks/integrations", bytes.NewReader(checkBody), cookie)
	if withoutCSRF.Code != http.StatusForbidden {
		t.Fatalf("real check without CSRF: got %d, want 403", withoutCSRF.Code)
	}
	checked := mutationRequestForTest(server, http.MethodPost, "/api/v1/checks/integrations", checkBody, cookie, current.CSRFToken)
	if checked.Code != http.StatusOK || !strings.Contains(checked.Body.String(), `"overall":"failed"`) {
		t.Fatalf("real check: got %d, body %s", checked.Code, checked.Body.String())
	}
	if strings.Contains(checked.Body.String(), "api-secret-never-return") || strings.Contains(checked.Body.String(), "203.0.113.10") {
		t.Fatal("real check returned a secret or configured destination")
	}

	discoveryBody, err := json.Marshal(TautulliDiscoveryRequest{ExpectedRevision: ReadConfigEditor(root).Revision, ConfirmRealNetwork: true})
	if err != nil {
		t.Fatal(err)
	}
	discoveryWithoutCSRF := requestForTest(server, http.MethodPost, "/api/v1/discovery/tautulli", bytes.NewReader(discoveryBody), cookie)
	if discoveryWithoutCSRF.Code != http.StatusForbidden {
		t.Fatalf("discovery without CSRF: got %d, want 403", discoveryWithoutCSRF.Code)
	}
	discovery := mutationRequestForTest(server, http.MethodPost, "/api/v1/discovery/tautulli", discoveryBody, cookie, current.CSRFToken)
	if discovery.Code != http.StatusUnprocessableEntity || !strings.Contains(discovery.Body.String(), `"code":"discovery-boundary"`) {
		t.Fatalf("public discovery boundary: got %d, body %s", discovery.Code, discovery.Body.String())
	}
	if strings.Contains(discovery.Body.String(), "api-secret-never-return") || strings.Contains(discovery.Body.String(), "203.0.113.10") {
		t.Fatal("discovery error returned a secret or configured destination")
	}

	smtpBody, err := json.Marshal(SMTPNetworkCheckRequest{ExpectedRevision: ReadConfigEditor(root).Revision, ConfirmRealNetwork: true})
	if err != nil {
		t.Fatal(err)
	}
	smtpWithoutCSRF := requestForTest(server, http.MethodPost, "/api/v1/checks/smtp-network", bytes.NewReader(smtpBody), cookie)
	if smtpWithoutCSRF.Code != http.StatusForbidden {
		t.Fatalf("SMTP preflight without CSRF: got %d, want 403", smtpWithoutCSRF.Code)
	}
	smtp := mutationRequestForTest(server, http.MethodPost, "/api/v1/checks/smtp-network", smtpBody, cookie, current.CSRFToken)
	if smtp.Code != http.StatusOK || !strings.Contains(smtp.Body.String(), `"overall":"failed"`) {
		t.Fatalf("SMTP preflight: got %d, body %s", smtp.Code, smtp.Body.String())
	}
	for _, private := range []string{"0.0.0.0", "fictional-smtp-secret", "newsletter@example.org"} {
		if strings.Contains(smtp.Body.String(), private) {
			t.Fatalf("SMTP preflight returned private value %q", private)
		}
	}

	restoreBody, err := json.Marshal(ConfigRestoreRequest{ExpectedRevision: ReadConfigEditor(root).Revision})
	if err != nil {
		t.Fatal(err)
	}
	restored := mutationRequestForTest(server, http.MethodPost, "/api/v1/config/backups/"+backupID+"/restore", restoreBody, cookie, current.CSRFToken)
	if restored.Code != http.StatusOK || !strings.Contains(restored.Body.String(), `"restored":true`) {
		t.Fatalf("backup restore: got %d, body %s", restored.Code, restored.Body.String())
	}
	if strings.Contains(restored.Body.String(), "api-secret-never-return") {
		t.Fatal("backup restore returned a stored API key")
	}

	deleteWithoutCSRF := requestForTest(server, http.MethodDelete, "/api/v1/config/backups/"+backupID, nil, cookie)
	if deleteWithoutCSRF.Code != http.StatusForbidden {
		t.Fatalf("backup delete without CSRF: got %d, want 403", deleteWithoutCSRF.Code)
	}
	deleted := mutationRequestForTest(server, http.MethodDelete, "/api/v1/config/backups/"+backupID, nil, cookie, current.CSRFToken)
	if deleted.Code != http.StatusOK || !strings.Contains(deleted.Body.String(), `"deleted":true`) || !strings.Contains(deleted.Body.String(), backupID) {
		t.Fatalf("backup delete: got %d, body %s", deleted.Code, deleted.Body.String())
	}
	if _, err := os.Stat(filepath.Join(root, backupID)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("backup API did not remove selected file: %v", err)
	}
}

func TestPreviewOperationAPIsRequireCSRFAndReturnOnlySanitizedRecords(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "operation-api-secret", "", "")
	runner := &fixturePreviewRunner{started: make(chan struct{})}
	server, err := New(Options{
		DataDir:         t.TempDir(),
		TautWeeklyRoot:  root,
		Version:         "test",
		operationRunner: runner,
	})
	if err != nil {
		t.Fatal(err)
	}
	current, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}
	const privateUserID = "9876543210123456789"
	body, err := json.Marshal(CreateOperationRequest{
		Type:             "preview-all",
		ExpectedRevision: ReadConfigEditor(root).Revision,
		UserID:           privateUserID,
		ConfirmNoSend:    true,
	})
	if err != nil {
		t.Fatal(err)
	}

	withoutCSRF := requestForTest(server, http.MethodPost, "/api/v1/operations", bytes.NewReader(body), cookie)
	if withoutCSRF.Code != http.StatusForbidden {
		t.Fatalf("operation without CSRF: got %d, want 403", withoutCSRF.Code)
	}
	created := mutationRequestForTest(server, http.MethodPost, "/api/v1/operations", body, cookie, current.CSRFToken)
	if created.Code != http.StatusAccepted {
		t.Fatalf("create operation: got %d, body %s", created.Code, created.Body.String())
	}
	assertOperationResponseSanitized(t, created.Body.String(), privateUserID)
	finished := waitForOperationState(t, server.operations, "succeeded")

	for _, target := range []string{"/api/v1/operations/current", "/api/v1/operations/" + finished.ID, "/api/v1/history"} {
		response := requestForTest(server, http.MethodGet, target, nil, cookie)
		if response.Code != http.StatusOK {
			t.Fatalf("GET %s: got %d, body %s", target, response.Code, response.Body.String())
		}
		assertOperationResponseSanitized(t, response.Body.String(), privateUserID)
		if target == "/api/v1/history" && (!strings.Contains(response.Body.String(), `"maximumEntries":20`) || !strings.Contains(response.Body.String(), `"retentionPolicy":"count-only-fifo"`)) {
			t.Fatalf("history API omitted count-only retention metadata: %s", response.Body.String())
		}
	}

	cancelWithoutCSRF := requestForTest(server, http.MethodPost, "/api/v1/operations/"+finished.ID+"/cancel", nil, cookie)
	if cancelWithoutCSRF.Code != http.StatusForbidden {
		t.Fatalf("cancel without CSRF: got %d, want 403", cancelWithoutCSRF.Code)
	}
	cancelled := mutationRequestForTest(server, http.MethodPost, "/api/v1/operations/"+finished.ID+"/cancel", nil, cookie, current.CSRFToken)
	if cancelled.Code != http.StatusConflict || !strings.Contains(cancelled.Body.String(), `"code":"operation-complete"`) {
		t.Fatalf("cancel completed operation: got %d, body %s", cancelled.Code, cancelled.Body.String())
	}
}

func TestSendTestAllOperationAPIRequiresExplicitConfirmationAndReturnsOnlyAggregateDeliveryEvidence(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "operation-api-secret", "", "")
	server, err := New(Options{
		DataDir:         t.TempDir(),
		TautWeeklyRoot:  root,
		Version:         "test",
		operationRunner: &fixturePreviewRunner{},
	})
	if err != nil {
		t.Fatal(err)
	}
	current, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}
	const privateUserID = "9876543210123456789"
	request := CreateOperationRequest{
		Type:             "send-test-all",
		ExpectedRevision: ReadConfigEditor(root).Revision,
		UserID:           privateUserID,
	}
	unconfirmedBody, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	unconfirmed := mutationRequestForTest(server, http.MethodPost, "/api/v1/operations", unconfirmedBody, cookie, current.CSRFToken)
	if unconfirmed.Code != http.StatusUnprocessableEntity || !strings.Contains(unconfirmed.Body.String(), `"code":"operation-confirmation-required"`) {
		t.Fatalf("unconfirmed test send: got %d, body %s", unconfirmed.Code, unconfirmed.Body.String())
	}

	request.ConfirmTestSend = true
	body, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	created := mutationRequestForTest(server, http.MethodPost, "/api/v1/operations", body, cookie, current.CSRFToken)
	if created.Code != http.StatusAccepted {
		t.Fatalf("create test-send operation: got %d, body %s", created.Code, created.Body.String())
	}
	assertOperationResponseSanitized(t, created.Body.String(), privateUserID)
	finished := waitForOperationState(t, server.operations, "succeeded")
	if finished.Type != "send-test-all" || finished.DeliveryScope != "test" || finished.SMTPAcceptedCount != 6 || finished.SkippedCount != 0 || finished.FailedCount != 0 || finished.Cancellable {
		t.Fatalf("unexpected aggregate test-send record: %+v", finished)
	}

	for _, target := range []string{"/api/v1/operations/current", "/api/v1/operations/" + finished.ID, "/api/v1/history"} {
		response := requestForTest(server, http.MethodGet, target, nil, cookie)
		if response.Code != http.StatusOK {
			t.Fatalf("GET %s: got %d, body %s", target, response.Code, response.Body.String())
		}
		assertOperationResponseSanitized(t, response.Body.String(), privateUserID)
		if !strings.Contains(response.Body.String(), `"smtpAcceptedCount":6`) || !strings.Contains(response.Body.String(), `"deliveryScope":"test"`) {
			t.Fatalf("GET %s omitted aggregate test-send evidence: %s", target, response.Body.String())
		}
	}
}

func TestSendAllOperationAPIRequiresExplicitConfirmationAndReturnsOnlyAggregateDeliveryEvidence(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "operation-api-secret", "", "")
	server, err := New(Options{
		DataDir:         t.TempDir(),
		TautWeeklyRoot:  root,
		Version:         "test",
		operationRunner: &fixturePreviewRunner{},
	})
	if err != nil {
		t.Fatal(err)
	}
	current, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}
	request := CreateOperationRequest{Type: "send-all", ExpectedRevision: ReadConfigEditor(root).Revision}
	unconfirmedBody, _ := json.Marshal(request)
	unconfirmed := mutationRequestForTest(server, http.MethodPost, "/api/v1/operations", unconfirmedBody, cookie, current.CSRFToken)
	if unconfirmed.Code != http.StatusUnprocessableEntity || !strings.Contains(unconfirmed.Body.String(), `"code":"operation-confirmation-required"`) {
		t.Fatalf("unconfirmed production send: got %d, body %s", unconfirmed.Code, unconfirmed.Body.String())
	}

	request.ConfirmProductionSend = true
	body, _ := json.Marshal(request)
	created := mutationRequestForTest(server, http.MethodPost, "/api/v1/operations", body, cookie, current.CSRFToken)
	if created.Code != http.StatusAccepted {
		t.Fatalf("create production send: got %d, body %s", created.Code, created.Body.String())
	}
	finished := waitForOperationState(t, server.operations, "succeeded")
	if finished.Type != "send-all" || finished.DeliveryScope != "production" || finished.SMTPAcceptedCount != 4 || finished.SkippedCount != 2 || finished.FailedCount != 0 || finished.Cancellable {
		t.Fatalf("unexpected aggregate production record: %+v", finished)
	}
	for _, target := range []string{"/api/v1/operations/current", "/api/v1/operations/" + finished.ID, "/api/v1/history"} {
		response := requestForTest(server, http.MethodGet, target, nil, cookie)
		if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"deliveryScope":"production"`) || !strings.Contains(response.Body.String(), `"smtpAcceptedCount":4`) {
			t.Fatalf("GET %s omitted aggregate production evidence: %s", target, response.Body.String())
		}
	}
}

func TestSendWelcomeOperationAPIRequiresExplicitConfirmationAndDoesNotReturnSelectedUser(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "operation-api-secret", "", "")
	server, err := New(Options{
		DataDir:         t.TempDir(),
		TautWeeklyRoot:  root,
		Version:         "test",
		operationRunner: &fixturePreviewRunner{},
	})
	if err != nil {
		t.Fatal(err)
	}
	current, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}
	const selectedUserID = "9876543210123456789"
	request := CreateOperationRequest{Type: "send-welcome", ExpectedRevision: ReadConfigEditor(root).Revision, UserID: selectedUserID}
	unconfirmedBody, _ := json.Marshal(request)
	unconfirmed := mutationRequestForTest(server, http.MethodPost, "/api/v1/operations", unconfirmedBody, cookie, current.CSRFToken)
	if unconfirmed.Code != http.StatusUnprocessableEntity || !strings.Contains(unconfirmed.Body.String(), `"code":"operation-confirmation-required"`) {
		t.Fatalf("unconfirmed Manual Welcome: got %d, body %s", unconfirmed.Code, unconfirmed.Body.String())
	}

	request.ConfirmProductionSend = true
	body, _ := json.Marshal(request)
	created := mutationRequestForTest(server, http.MethodPost, "/api/v1/operations", body, cookie, current.CSRFToken)
	if created.Code != http.StatusAccepted {
		t.Fatalf("create Manual Welcome: got %d, body %s", created.Code, created.Body.String())
	}
	assertOperationResponseSanitized(t, created.Body.String(), selectedUserID)
	finished := waitForOperationState(t, server.operations, "succeeded")
	if finished.Type != "send-welcome" || finished.DeliveryScope != "welcome" || finished.SMTPAcceptedCount != 1 || finished.Cancellable {
		t.Fatalf("unexpected Manual Welcome record: %+v", finished)
	}
	for _, target := range []string{"/api/v1/operations/current", "/api/v1/operations/" + finished.ID, "/api/v1/history"} {
		response := requestForTest(server, http.MethodGet, target, nil, cookie)
		if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"deliveryScope":"welcome"`) || strings.Contains(response.Body.String(), selectedUserID) {
			t.Fatalf("GET %s returned unsafe Manual Welcome evidence: %s", target, response.Body.String())
		}
	}
}

func TestScheduleLifecycleAPIRequiresCSRFConfirmationAndReturnsSanitizedState(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "schedule-api-secret", "", "")
	setFixtureTaskName(t, root, "Private API Fixture Task")
	server, err := New(Options{
		DataDir:        t.TempDir(),
		TautWeeklyRoot: root,
		Version:        "test",
		scheduleRunner: &fixtureScheduleRunner{},
	})
	if err != nil {
		t.Fatal(err)
	}
	current, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}
	request := ScheduleMutationRequest{ExpectedRevision: ReadConfigEditor(root).Revision}
	unconfirmedBody, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}

	withoutCSRF := requestForTest(server, http.MethodPost, "/api/v1/schedule/install", bytes.NewReader(unconfirmedBody), cookie)
	if withoutCSRF.Code != http.StatusForbidden {
		t.Fatalf("schedule mutation without CSRF: got %d, body %s", withoutCSRF.Code, withoutCSRF.Body.String())
	}
	unconfirmed := mutationRequestForTest(server, http.MethodPost, "/api/v1/schedule/install", unconfirmedBody, cookie, current.CSRFToken)
	if unconfirmed.Code != http.StatusUnprocessableEntity || !strings.Contains(unconfirmed.Body.String(), `"code":"schedule-confirmation-required"`) {
		t.Fatalf("unconfirmed schedule mutation: got %d, body %s", unconfirmed.Code, unconfirmed.Body.String())
	}

	request.Confirm = true
	body, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	created := mutationRequestForTest(server, http.MethodPost, "/api/v1/schedule/install", body, cookie, current.CSRFToken)
	if created.Code != http.StatusAccepted {
		t.Fatalf("create schedule operation: got %d, body %s", created.Code, created.Body.String())
	}
	assertScheduleResponseSanitized(t, created.Body.String(), request.ExpectedRevision)
	waitForScheduleState(t, server.schedule, "succeeded")
	response := requestForTest(server, http.MethodGet, "/api/v1/schedule/operation", nil, cookie)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"action":"install"`) || !strings.Contains(response.Body.String(), `"state":"succeeded"`) {
		t.Fatalf("schedule operation state: got %d, body %s", response.Code, response.Body.String())
	}
	assertScheduleResponseSanitized(t, response.Body.String(), request.ExpectedRevision)

	arbitrary := mutationRequestForTest(server, http.MethodPost, "/api/v1/schedule/run-command", body, cookie, current.CSRFToken)
	if arbitrary.Code != http.StatusUnprocessableEntity || !strings.Contains(arbitrary.Body.String(), `"code":"schedule-action-invalid"`) {
		t.Fatalf("arbitrary schedule action: got %d, body %s", arbitrary.Code, arbitrary.Body.String())
	}
}

func TestScheduleAndNewsletterOperationsAreMutuallyExclusive(t *testing.T) {
	t.Run("schedule blocks newsletter operation", func(t *testing.T) {
		root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
		scheduleRunner := &fixtureScheduleRunner{started: make(chan struct{}), release: make(chan struct{})}
		server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Version: "test", scheduleRunner: scheduleRunner, operationRunner: &fixturePreviewRunner{}})
		if err != nil {
			t.Fatal(err)
		}
		session, err := server.auth.newSession()
		if err != nil {
			t.Fatal(err)
		}
		cookie := &http.Cookie{Name: sessionCookieName, Value: session.Token}
		revision := ReadConfigEditor(root).Revision
		scheduleBody, _ := json.Marshal(ScheduleMutationRequest{ExpectedRevision: revision, Confirm: true})
		created := mutationRequestForTest(server, http.MethodPost, "/api/v1/schedule/install", scheduleBody, cookie, session.CSRFToken)
		if created.Code != http.StatusAccepted {
			t.Fatalf("start schedule operation: %d %s", created.Code, created.Body.String())
		}
		select {
		case <-scheduleRunner.started:
		case <-time.After(3 * time.Second):
			t.Fatal("fixture schedule operation did not start")
		}
		previewBody, _ := json.Marshal(CreateOperationRequest{Type: "preview-all", ExpectedRevision: revision, UserID: "42", ConfirmNoSend: true})
		blocked := mutationRequestForTest(server, http.MethodPost, "/api/v1/operations", previewBody, cookie, session.CSRFToken)
		if blocked.Code != http.StatusConflict || !strings.Contains(blocked.Body.String(), `"code":"schedule-busy"`) {
			t.Fatalf("schedule did not block newsletter operation: %d %s", blocked.Code, blocked.Body.String())
		}
		close(scheduleRunner.release)
		waitForScheduleState(t, server.schedule, "succeeded")
	})

	t.Run("newsletter operation blocks schedule", func(t *testing.T) {
		root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
		operationRunner := &fixturePreviewRunner{started: make(chan struct{}), release: make(chan struct{})}
		server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Version: "test", scheduleRunner: &fixtureScheduleRunner{}, operationRunner: operationRunner})
		if err != nil {
			t.Fatal(err)
		}
		session, err := server.auth.newSession()
		if err != nil {
			t.Fatal(err)
		}
		cookie := &http.Cookie{Name: sessionCookieName, Value: session.Token}
		revision := ReadConfigEditor(root).Revision
		previewBody, _ := json.Marshal(CreateOperationRequest{Type: "preview-all", ExpectedRevision: revision, UserID: "42", ConfirmNoSend: true})
		created := mutationRequestForTest(server, http.MethodPost, "/api/v1/operations", previewBody, cookie, session.CSRFToken)
		if created.Code != http.StatusAccepted {
			t.Fatalf("start preview operation: %d %s", created.Code, created.Body.String())
		}
		select {
		case <-operationRunner.started:
		case <-time.After(3 * time.Second):
			t.Fatal("fixture preview operation did not start")
		}
		scheduleBody, _ := json.Marshal(ScheduleMutationRequest{ExpectedRevision: revision, Confirm: true})
		blocked := mutationRequestForTest(server, http.MethodPost, "/api/v1/schedule/install", scheduleBody, cookie, session.CSRFToken)
		if blocked.Code != http.StatusConflict || !strings.Contains(blocked.Body.String(), `"code":"operation-busy"`) {
			t.Fatalf("newsletter operation did not block schedule: %d %s", blocked.Code, blocked.Body.String())
		}
		current := server.operations.Current()
		if current == nil {
			t.Fatal("active preview operation disappeared")
		}
		if _, err := server.operations.Cancel(current.ID); err != nil {
			t.Fatal(err)
		}
		waitForOperationState(t, server.operations, "cancelled")
	})
}

func assertScheduleResponseSanitized(t *testing.T, response, revision string) {
	t.Helper()
	for _, forbidden := range []string{"Private API Fixture Task", "schedule-api-secret", revision, "127.0.0.1", "config.json", "powershell", "SCHEDULE-HELPER"} {
		if strings.Contains(strings.ToLower(response), strings.ToLower(forbidden)) {
			t.Fatalf("schedule API response retained private or implementation value %q: %s", forbidden, response)
		}
	}
}

func assertOperationResponseSanitized(t *testing.T, response string, privateUserID string) {
	t.Helper()
	for _, forbidden := range []string{privateUserID, "operation-api-secret", "127.0.0.1", "config.json", "powershell"} {
		if strings.Contains(strings.ToLower(response), strings.ToLower(forbidden)) {
			t.Fatalf("operation API response retained private or implementation value %q: %s", forbidden, response)
		}
	}
}

func mutationRequestForTest(server *Server, method, target string, body []byte, cookie *http.Cookie, csrf string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, target, bytes.NewReader(body))
	request.Host = "127.0.0.1:8788"
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Origin", "http://127.0.0.1:8788")
	request.Header.Set("X-CSRF-Token", csrf)
	request.AddCookie(cookie)
	recorder := httptest.NewRecorder()
	server.Handler().ServeHTTP(recorder, request)
	return recorder
}

func requestForTest(server *Server, method, target string, body io.Reader, cookie *http.Cookie) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, target, body)
	request.Host = "127.0.0.1:8788"
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	if cookie != nil {
		request.AddCookie(cookie)
	}
	recorder := httptest.NewRecorder()
	server.Handler().ServeHTTP(recorder, request)
	return recorder
}
