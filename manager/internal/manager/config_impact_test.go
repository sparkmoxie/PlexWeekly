package manager

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestEveryConfigFieldHasExplicitSaveImpact(t *testing.T) {
	type impact struct {
		category    string
		discovery   bool
		integration bool
		smtp        bool
		preview     bool
		warmCache   bool
	}
	expected := map[string]impact{
		"TautulliUrl":                   {category: "tautulli", discovery: true, integration: true, preview: true, warmCache: true},
		"ApiKey":                        {category: "tautulli", discovery: true, integration: true, preview: true, warmCache: true},
		"PlexServerUrl":                 {category: "plex", integration: true, preview: true, warmCache: true},
		"PlexToken":                     {category: "plex", integration: true, preview: true, warmCache: true},
		"PlexWebUrl":                    {category: "identity", preview: true},
		"PlexButtonLabel":               {category: "identity", preview: true},
		"ServerLabel":                   {category: "identity", preview: true},
		"FooterServerName":              {category: "identity", preview: true},
		"FromName":                      {category: "email"},
		"FromEmail":                     {category: "email"},
		"ReplyToEmail":                  {category: "email"},
		"TestEmail":                     {category: "email"},
		"SmtpHost":                      {category: "smtp", smtp: true},
		"SmtpPort":                      {category: "smtp", smtp: true},
		"SmtpEnableSsl":                 {category: "smtp", smtp: true},
		"SmtpUseAuthentication":         {category: "smtp", smtp: true},
		"SmtpUsername":                  {category: "smtp", smtp: true},
		"SmtpPassword":                  {category: "smtp", smtp: true},
		"SmtpStripPasswordSpaces":       {category: "smtp", smtp: true},
		"SmtpAuthenticationMethod":      {category: "smtp", smtp: true},
		"SmtpTimeoutSeconds":            {category: "smtp", smtp: true},
		"ScheduleDay":                   {category: "schedule"},
		"ScheduleTime":                  {category: "schedule"},
		"ScheduledTaskName":             {category: "schedule"},
		"DaysBack":                      {category: "newsletter", preview: true, warmCache: true},
		"RecentAccessDays":              {category: "newsletter", preview: true, warmCache: true},
		"WatchedPercent":                {category: "newsletter", preview: true, warmCache: true},
		"MaxMovies":                     {category: "newsletter", preview: true, warmCache: true},
		"MaxTv":                         {category: "newsletter", preview: true, warmCache: true},
		"SendDelaySeconds":              {category: "newsletter"},
		"TestSendDelaySeconds":          {category: "newsletter"},
		"DeletedItemCacheEnabled":       {category: "cache", warmCache: true},
		"DeletedItemCacheRetentionDays": {category: "cache", warmCache: true},
		"DeletedItemCacheMaxItems":      {category: "cache", warmCache: true},
		"DeletedItemCacheMaxBytesMB":    {category: "cache", warmCache: true},
		"CustomTextCardEnabled":         {category: "custom-text-card", preview: true},
		"CustomTextCardBorderColor":     {category: "custom-text-card", preview: true},
		"CustomTextCardBorderOpacity":   {category: "custom-text-card", preview: true},
		"CustomTextCardTitle":           {category: "custom-text-card", preview: true},
		"CustomTextCardTitleGif":        {category: "custom-text-card", preview: true},
		"CustomTextCardSubheading":      {category: "custom-text-card", preview: true},
		"CustomTextCardBody":            {category: "custom-text-card", preview: true},
		"IncludedLibraryIds":            {category: "libraries", preview: true, warmCache: true},
		"ExcludedUserIds":               {category: "recipients", preview: true, warmCache: true},
		"UserEmailOverrides":            {category: "recipients", discovery: true, preview: true, warmCache: true},
		"ExcludedEmails":                {category: "recipients", discovery: true, preview: true, warmCache: true},
	}

	definitions := configDefinitions()
	if len(expected) != len(definitions) {
		t.Fatalf("explicit impact count=%d, config definition count=%d", len(expected), len(definitions))
	}
	for _, definition := range definitions {
		want, ok := expected[definition.Name]
		if !ok {
			t.Fatalf("config field %q has no explicit save impact", definition.Name)
		}
		plan := classifyConfigPostSave(map[string]any{definition.Name: "before"}, map[string]any{definition.Name: "after"}, true)
		if !plan.MaterialChange || len(plan.ChangedCategories) != 1 || plan.ChangedCategories[0] != want.category ||
			plan.RunDiscovery != want.discovery || plan.RunIntegration != want.integration ||
			plan.RunSMTP != want.smtp || plan.GeneratePreviews != want.preview || plan.WarmCache != want.warmCache || !plan.CacheEnabled || !plan.VerifyCache {
			t.Fatalf("config field %q: got %+v, want %+v", definition.Name, plan, want)
		}
	}
}

func TestConfigPostSavePlanInvalidatesOnlyAffectedCategories(t *testing.T) {
	tests := []struct {
		name          string
		mutate        func(*ConfigSaveRequest)
		want          ConfigPostSavePlan
		cacheDisabled bool
	}{
		{
			name: "custom card presentation",
			mutate: func(request *ConfigSaveRequest) {
				request.Values["CustomTextCardEnabled"] = json.RawMessage(`true`)
				request.Values["CustomTextCardBody"] = json.RawMessage(`"Synthetic maintenance notice"`)
			},
			want: ConfigPostSavePlan{MaterialChange: true, GeneratePreviews: true},
		},
		{
			name: "Tautulli connection",
			mutate: func(request *ConfigSaveRequest) {
				request.Values["TautulliUrl"] = json.RawMessage(`"http://127.0.0.1:8282"`)
			},
			want: ConfigPostSavePlan{MaterialChange: true, RunDiscovery: true, RunIntegration: true, GeneratePreviews: true, WarmCache: true},
		},
		{
			name: "Plex connection",
			mutate: func(request *ConfigSaveRequest) {
				request.Values["PlexServerUrl"] = json.RawMessage(`"http://127.0.0.1:32401"`)
				request.Secrets["PlexToken"] = SecretChange{Action: "replace", Value: "synthetic-new-plex-token"}
			},
			want: ConfigPostSavePlan{MaterialChange: true, RunIntegration: true, GeneratePreviews: true, WarmCache: true},
		},
		{
			name: "SMTP connection",
			mutate: func(request *ConfigSaveRequest) {
				request.Values["SmtpHost"] = json.RawMessage(`"mail.example.test"`)
			},
			want: ConfigPostSavePlan{MaterialChange: true, RunSMTP: true},
		},
		{
			name: "library selection",
			mutate: func(request *ConfigSaveRequest) {
				request.Values["IncludedLibraryIds"] = json.RawMessage(`["7"]`)
			},
			want: ConfigPostSavePlan{MaterialChange: true, GeneratePreviews: true, WarmCache: true},
		},
		{
			name: "managed-user recipient coverage",
			mutate: func(request *ConfigSaveRequest) {
				request.Values["UserEmailOverrides"] = json.RawMessage(`{"42":"managed@example.org"}`)
			},
			want: ConfigPostSavePlan{MaterialChange: true, RunDiscovery: true, GeneratePreviews: true, WarmCache: true},
		},
		{
			name: "identity presentation",
			mutate: func(request *ConfigSaveRequest) {
				request.Values["FooterServerName"] = json.RawMessage(`"Synthetic Plex"`)
			},
			want: ConfigPostSavePlan{MaterialChange: true, GeneratePreviews: true},
		},
		{
			name: "newsletter content",
			mutate: func(request *ConfigSaveRequest) {
				request.Values["DaysBack"] = json.RawMessage(`14`)
			},
			want: ConfigPostSavePlan{MaterialChange: true, GeneratePreviews: true, WarmCache: true},
		},
		{
			name: "newsletter delivery delay",
			mutate: func(request *ConfigSaveRequest) {
				request.Values["SendDelaySeconds"] = json.RawMessage(`20`)
			},
			want: ConfigPostSavePlan{MaterialChange: true},
		},
		{
			name: "email identity",
			mutate: func(request *ConfigSaveRequest) {
				request.Values["FromName"] = json.RawMessage(`"Synthetic Newsletter"`)
			},
			want: ConfigPostSavePlan{MaterialChange: true},
		},
		{
			name: "cache toggle",
			mutate: func(request *ConfigSaveRequest) {
				request.Values["DeletedItemCacheEnabled"] = json.RawMessage(`false`)
			},
			cacheDisabled: true,
			want:          ConfigPostSavePlan{MaterialChange: true, ConfirmationCode: "cache-disabled"},
		},
		{
			name: "enabled cache bounds refresh cache independently",
			mutate: func(request *ConfigSaveRequest) {
				request.Values["DeletedItemCacheMaxItems"] = json.RawMessage(`1200`)
			},
			want: ConfigPostSavePlan{MaterialChange: true, WarmCache: true, ConfirmationCode: "cache-updated"},
		},
		{
			name: "schedule only",
			mutate: func(request *ConfigSaveRequest) {
				request.Values["ScheduleTime"] = json.RawMessage(`"10:45"`)
			},
			want: ConfigPostSavePlan{MaterialChange: true},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			root := normalizedConfigRoot(t)
			request := validConfigSaveRequest(t, ReadConfigEditor(root))
			test.mutate(&request)
			result, fields, err := SaveConfig(root, request, time.Now)
			if err != nil || len(fields) != 0 || !result.Saved {
				t.Fatalf("save: result=%+v fields=%v err=%v", result, fields, err)
			}
			got := result.PostSave
			expectedCacheEnabled := !test.cacheDisabled
			if got.MaterialChange != test.want.MaterialChange || got.RunDiscovery != test.want.RunDiscovery ||
				got.RunIntegration != test.want.RunIntegration || got.RunSMTP != test.want.RunSMTP ||
				got.GeneratePreviews != test.want.GeneratePreviews || got.WarmCache != test.want.WarmCache || got.ConfirmationCode != test.want.ConfirmationCode ||
				got.CacheEnabled != expectedCacheEnabled || got.VerifyCache != expectedCacheEnabled {
				t.Fatalf("post-save plan: got %+v, want effects %+v", got, test.want)
			}
			encoded, _ := json.Marshal(result)
			for _, secret := range []string{"fictional-api-key", "fictional-smtp-secret", "synthetic-new-plex-token"} {
				if strings.Contains(string(encoded), secret) {
					t.Fatalf("post-save response exposed secret %q", secret)
				}
			}
		})
	}
}

func TestNoMaterialChangeSaveDoesNoWork(t *testing.T) {
	root := normalizedConfigRoot(t)
	before := ReadConfigEditor(root)
	backupsBefore, _ := filepath.Glob(filepath.Join(root, "config.backup.*.json"))
	result, fields, err := SaveConfig(root, validConfigSaveRequest(t, before), time.Now)
	if err != nil || len(fields) != 0 {
		t.Fatalf("no-op save: fields=%v err=%v", fields, err)
	}
	if result.Saved || result.PostSave.MaterialChange || result.PostSave.RunDiscovery || result.PostSave.RunIntegration || result.PostSave.RunSMTP || result.PostSave.GeneratePreviews || result.PostSave.WarmCache {
		if !result.PostSave.CacheEnabled || !result.PostSave.VerifyCache {
			t.Fatalf("no-op save did not schedule the enabled-cache verification: %+v", result.PostSave)
		}
		t.Fatalf("no-op save scheduled work: %+v", result)
	}
	if result.Editor.Revision != before.Revision {
		t.Fatalf("no-op save changed revision: got %s want %s", result.Editor.Revision, before.Revision)
	}
	backupsAfter, _ := filepath.Glob(filepath.Join(root, "config.backup.*.json"))
	if len(backupsAfter) != len(backupsBefore) {
		t.Fatalf("no-op save created a backup: before=%d after=%d", len(backupsBefore), len(backupsAfter))
	}
}

func TestPresentationSaveRebasesEvidenceAcrossEveryManagerPackage(t *testing.T) {
	packages := []struct {
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
	for _, platform := range packages {
		t.Run(platform.kind, func(t *testing.T) {
			root := normalizedConfigRoot(t)
			server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, RuntimeRoot: root, Version: "test", RuntimeMode: platform.mode, PackageKind: platform.kind})
			if err != nil {
				t.Fatal(err)
			}
			seedConfigurationEvidence(t, server, ReadConfigEditor(root).Revision)

			request := validConfigSaveRequest(t, ReadConfigEditor(root))
			request.Values["CustomTextCardEnabled"] = json.RawMessage(`true`)
			request.Values["CustomTextCardTitle"] = json.RawMessage(`"SYNTHETIC NOTICE"`)
			request.Values["CustomTextCardBody"] = json.RawMessage(`"Synthetic presentation-only text"`)
			result := saveThroughServer(t, server, request)
			if !result.PostSave.GeneratePreviews || result.PostSave.RunDiscovery || result.PostSave.RunIntegration || result.PostSave.RunSMTP {
				t.Fatalf("presentation save plan: %+v", result.PostSave)
			}
			if !result.PostSave.RetainedDiscovery || !result.PostSave.RetainedIntegration || !result.PostSave.RetainedSMTP {
				t.Fatalf("presentation evidence was not retained: %+v", result.PostSave)
			}
			if result.PostSave.RetainedPreviews {
				t.Fatalf("stale previews were retained: %+v", result.PostSave)
			}
			if discovery := server.discovery.Load(result.Editor.Revision); discovery == nil || discovery.SuggestedPreviewUserID != "42" {
				t.Fatalf("sanitized discovery was not rebased: %+v", discovery)
			}
			status := server.configuration.Load(result.Editor.Revision)
			if status.Steps["choices"].State != "passed" || status.Steps["lan"].State != "passed" || status.Steps["smtp"].State != "passed" || status.Steps["previews"].State != "waiting" || status.Steps["cache"].State != "waiting" {
				t.Fatalf("scoped setup state: %+v", status.Steps)
			}
			if status.LastVerification == nil || status.LastVerification.ConfigRevision != result.Editor.Revision || status.LastSMTPCheck == nil || status.LastSMTPCheck.ConfigRevision != result.Editor.Revision {
				t.Fatalf("rebased verification evidence: verification=%+v smtp=%+v", status.LastVerification, status.LastSMTPCheck)
			}
			raw, err := os.ReadFile(filepath.Join(root, "config.json"))
			if err != nil || !strings.Contains(string(raw), "fictional-api-key") || !strings.Contains(string(raw), "fictional-smtp-secret") {
				t.Fatalf("presentation save did not preserve secrets")
			}
		})
	}
}

func TestSavedConnectionCategoriesInvalidateOnlyRelevantEvidence(t *testing.T) {
	tests := []struct {
		name             string
		mutate           func(*ConfigSaveRequest)
		wantDiscovery    bool
		wantIntegration  bool
		wantSMTP         bool
		wantPreviewState string
		wantChoicesState string
		wantLANState     string
		wantSMTPState    string
		wantCacheState   string
	}{
		{
			name: "Tautulli invalidates discovery and integration",
			mutate: func(request *ConfigSaveRequest) {
				request.Values["TautulliUrl"] = json.RawMessage(`"http://127.0.0.1:8282"`)
			},
			wantSMTP: true, wantPreviewState: "waiting", wantChoicesState: "waiting", wantLANState: "waiting", wantSMTPState: "passed", wantCacheState: "running",
		},
		{
			name: "Plex invalidates integration only",
			mutate: func(request *ConfigSaveRequest) {
				request.Values["PlexServerUrl"] = json.RawMessage(`"http://127.0.0.1:32401"`)
			},
			wantDiscovery: true, wantSMTP: true, wantPreviewState: "waiting", wantChoicesState: "passed", wantLANState: "waiting", wantSMTPState: "passed", wantCacheState: "running",
		},
		{
			name: "SMTP invalidates SMTP only",
			mutate: func(request *ConfigSaveRequest) {
				request.Values["SmtpTimeoutSeconds"] = json.RawMessage(`45`)
			},
			wantDiscovery: true, wantIntegration: true, wantPreviewState: "passed", wantChoicesState: "passed", wantLANState: "passed", wantSMTPState: "waiting", wantCacheState: "waiting",
		},
		{
			name: "library selection invalidates previews only",
			mutate: func(request *ConfigSaveRequest) {
				request.Values["IncludedLibraryIds"] = json.RawMessage(`["7"]`)
			},
			wantDiscovery: true, wantIntegration: true, wantSMTP: true, wantPreviewState: "waiting", wantChoicesState: "passed", wantLANState: "passed", wantSMTPState: "passed", wantCacheState: "running",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			root := normalizedConfigRoot(t)
			server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, RuntimeRoot: root, Version: "test"})
			if err != nil {
				t.Fatal(err)
			}
			seedConfigurationEvidence(t, server, ReadConfigEditor(root).Revision)
			request := validConfigSaveRequest(t, ReadConfigEditor(root))
			test.mutate(&request)
			result := saveThroughServer(t, server, request)
			status := server.configuration.Load(result.Editor.Revision)
			gotDiscovery := server.discovery.Load(result.Editor.Revision) != nil
			if gotDiscovery != test.wantDiscovery || (status.LastVerification != nil) != test.wantIntegration || (status.LastSMTPCheck != nil) != test.wantSMTP {
				t.Fatalf("retained evidence: discovery=%t integration=%t smtp=%t status=%+v plan=%+v", gotDiscovery, status.LastVerification != nil, status.LastSMTPCheck != nil, status, result.PostSave)
			}
			if status.Steps["choices"].State != test.wantChoicesState || status.Steps["lan"].State != test.wantLANState || status.Steps["smtp"].State != test.wantSMTPState || status.Steps["previews"].State != test.wantPreviewState || status.Steps["cache"].State != test.wantCacheState {
				t.Fatalf("scoped steps: got=%+v", status.Steps)
			}
		})
	}
}

func normalizedConfigRoot(t *testing.T) string {
	t.Helper()
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	view := ReadConfigEditor(root)
	result, fields, err := SaveConfig(root, validConfigSaveRequest(t, view), time.Now)
	if err != nil || len(fields) != 0 || !result.Saved {
		t.Fatalf("normalize fixture: result=%+v fields=%v err=%v", result, fields, err)
	}
	return root
}

func seedConfigurationEvidence(t *testing.T, server *Server, revision string) {
	t.Helper()
	now := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC).Format(time.RFC3339)
	discovery := TautulliDiscoveryResult{
		Mode: "real-lan-discovery", NetworkBoundary: "private-and-loopback-only", CompletedAtUTC: now, ConfigRevision: revision,
		Libraries: []DiscoveredLibrary{{ID: "7", Name: "Synthetic Movies", MediaType: "movie"}},
		Users:     []DiscoveredUser{{ID: "42", Name: "Synthetic Owner", Eligibility: "eligible", Role: "owner"}}, SuggestedPreviewUserID: "42",
	}
	if err := server.discovery.Save(discovery); err != nil {
		t.Fatal(err)
	}
	if err := server.configuration.ResetNotRun(revision); err != nil {
		t.Fatal(err)
	}
	if err := server.configuration.Update(revision, "choices", "passed", "Synthetic choices retained."); err != nil {
		t.Fatal(err)
	}
	integration := IntegrationCheckResult{
		Mode: "real-lan", NetworkBoundary: "private-and-loopback-only", Overall: "passed", StartedAtUTC: now, CompletedAtUTC: now, ConfigRevision: revision,
		Steps: []IntegrationCheckStep{{Service: "tautulli", State: "passed", Summary: "Synthetic Tautulli passed."}, {Service: "plex", State: "skipped", Summary: "Synthetic Plex optional."}},
	}
	if err := server.configuration.StoreIntegrationCheck(revision, integration); err != nil {
		t.Fatal(err)
	}
	if err := server.configuration.Update(revision, "lan", "passed", "Synthetic integrations retained."); err != nil {
		t.Fatal(err)
	}
	smtp := SMTPNetworkCheckResult{Mode: "smtp-network", Overall: "passed", State: "passed", Security: "starttls-validated", CompletedAtUTC: now, ConfigRevision: revision, Summary: "Synthetic SMTP passed."}
	if err := server.configuration.StoreSMTPCheck(revision, smtp); err != nil {
		t.Fatal(err)
	}
	if err := server.configuration.Update(revision, "smtp", "passed", "Synthetic SMTP retained."); err != nil {
		t.Fatal(err)
	}
	if err := server.configuration.Update(revision, "previews", "passed", "Synthetic previews generated."); err != nil {
		t.Fatal(err)
	}
}

func saveThroughServer(t *testing.T, server *Server, request ConfigSaveRequest) ConfigSaveResult {
	t.Helper()
	session, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	response := mutationRequestForTest(server, http.MethodPut, "/api/v1/config", body, &http.Cookie{Name: sessionCookieName, Value: session.Token}, session.CSRFToken)
	if response.Code != http.StatusOK {
		t.Fatalf("save response: %d %s", response.Code, response.Body.String())
	}
	var result ConfigSaveResult
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	return result
}
