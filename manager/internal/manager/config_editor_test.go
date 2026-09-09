package manager

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestReadConfigEditorUsesSafeDefaultsWithoutSecrets(t *testing.T) {
	root := t.TempDir()
	view := ReadConfigEditor(root)
	if view.Exists || !view.Valid || view.State != "unconfigured" || view.Revision != missingConfigRevision {
		t.Fatalf("unexpected editor state: %+v", view)
	}
	for _, name := range []string{"ApiKey", "FromEmail", "SmtpHost", "SmtpPassword", "TestEmail"} {
		if view.Issues[name] == "" {
			t.Fatalf("missing setup issue for %s: %v", name, view.Issues)
		}
	}
	apiKey := editorField(t, view, "ApiKey")
	if apiKey.Secret == nil || apiKey.Secret.Configured || apiKey.Value != nil {
		t.Fatalf("unexpected API key editor field: %+v", apiKey)
	}
	if value := editorField(t, view, "SmtpPort").Value; value != int64(587) {
		t.Fatalf("SMTP port default: got %#v", value)
	}
	overrides, ok := editorField(t, view, "UserEmailOverrides").Value.(map[string]string)
	if !ok || len(overrides) != 0 {
		t.Fatalf("unexpected managed-user delivery default: %#v", editorField(t, view, "UserEmailOverrides").Value)
	}
	plexURL := editorField(t, view, "PlexWebUrl")
	if plexURL.Label != "Open Plex button URL or custom link" || plexURL.Value != "https://app.plex.tv/desktop/" {
		t.Fatalf("unexpected custom-link field: %+v", plexURL)
	}
	buttonLabel := editorField(t, view, "PlexButtonLabel")
	if buttonLabel.Label != "Button label" || buttonLabel.Value != "Open Plex" || buttonLabel.Max == nil || *buttonLabel.Max != 64 {
		t.Fatalf("unexpected button-label default: %+v", buttonLabel)
	}
	customEnabled := editorField(t, view, "CustomTextCardEnabled")
	customBorder := editorField(t, view, "CustomTextCardBorderColor")
	customOpacity := editorField(t, view, "CustomTextCardBorderOpacity")
	customTitleGif := editorField(t, view, "CustomTextCardTitleGif")
	customBody := editorField(t, view, "CustomTextCardBody")
	if customEnabled.Value != false || customBorder.Value != "#72aef7" || customOpacity.Value != int64(34) || customTitleGif.Value != "none" || customBody.Value != "" {
		t.Fatalf("unexpected custom-text-card defaults: enabled=%#v border=%#v opacity=%#v titleGif=%#v body=%#v", customEnabled.Value, customBorder.Value, customOpacity.Value, customTitleGif.Value, customBody.Value)
	}
	cacheGroup := -1
	customGroup := -1
	for index, group := range view.Groups {
		if group == "Cache" {
			cacheGroup = index
		}
		if group == "Custom text card" {
			customGroup = index
		}
	}
	if customGroup != cacheGroup+1 {
		t.Fatalf("custom text card group is not immediately after Cache: %v", view.Groups)
	}
}

func TestReadConfigEditorNeverReturnsStoredSecrets(t *testing.T) {
	root := t.TempDir()
	config := `{"ApiKey":"editor-api-secret","PlexToken":"editor-plex-secret","SmtpAppPassword":"editor-smtp-secret"}`
	if err := os.WriteFile(filepath.Join(root, "config.json"), []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	view := ReadConfigEditor(root)
	encoded, err := json.Marshal(view)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"editor-api-secret", "editor-plex-secret", "editor-smtp-secret"} {
		if strings.Contains(string(encoded), secret) {
			t.Fatalf("editor response returned %q", secret)
		}
	}
	for _, name := range []string{"ApiKey", "PlexToken", "SmtpPassword"} {
		field := editorField(t, view, name)
		if field.Secret == nil || !field.Secret.Configured {
			t.Fatalf("%s was not reported as configured", name)
		}
	}
}

func TestLegacyDirectPlexFieldsAreExplainedAndNormalizedWithoutCopyingRuntimeToken(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	path := filepath.Join(root, "config.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	values := map[string]any{}
	if err := json.Unmarshal(raw, &values); err != nil {
		t.Fatal(err)
	}
	delete(values, "PlexServerUrl")
	delete(values, "PlexToken")
	raw, _ = json.Marshal(values)
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PLEX_TOKEN", "fictional-runtime-only-token")

	view := ReadConfigEditor(root)
	if !view.DirectPlex.LegacyFieldsMissing || view.DirectPlex.URLConfigured || view.DirectPlex.TokenConfigured || !view.DirectPlex.RuntimeTokenAvailable {
		t.Fatalf("unexpected legacy direct Plex status: %+v", view.DirectPlex)
	}
	plexTokenField := editorField(t, view, "PlexToken")
	if plexTokenField.Secret == nil || plexTokenField.Secret.Configured || !plexTokenField.Secret.AvailableFromRuntime {
		t.Fatalf("runtime Plex token status was not redacted correctly: %+v", plexTokenField)
	}

	request := validConfigSaveRequest(t, view)
	result, fieldErrors, err := SaveConfig(root, request, time.Now)
	if err != nil || len(fieldErrors) != 0 || !result.Saved {
		t.Fatalf("normalize legacy config: result=%+v fields=%v err=%v", result, fieldErrors, err)
	}
	if result.Editor.DirectPlex.LegacyFieldsMissing {
		t.Fatalf("legacy direct Plex fields remained absent after save: %+v", result.Editor.DirectPlex)
	}
	raw, err = os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "fictional-runtime-only-token") {
		t.Fatal("runtime Plex token was copied into config.json")
	}
	if !strings.Contains(string(raw), `"PlexServerUrl": ""`) || !strings.Contains(string(raw), `"PlexToken": ""`) {
		t.Fatalf("normalized direct Plex fields are missing: %s", raw)
	}
	if !strings.Contains(string(raw), `"PlexButtonLabel": "Open Plex"`) {
		t.Fatalf("default button label was not added to the legacy config: %s", raw)
	}
}

func TestReadConfigSecretReturnsOnlyRequestedValueWithCurrentRevision(t *testing.T) {
	root := t.TempDir()
	config := `{"ApiKey":"requested-api-secret","PlexToken":"other-plex-secret","SmtpAppPassword":"legacy-smtp-secret"}`
	if err := os.WriteFile(filepath.Join(root, "config.json"), []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	view := ReadConfigEditor(root)
	value, err := ReadConfigSecret(root, "ApiKey", view.Revision)
	if err != nil || value != "requested-api-secret" {
		t.Fatalf("read API secret: value=%q err=%v", value, err)
	}
	value, err = ReadConfigSecret(root, "SmtpPassword", view.Revision)
	if err != nil || value != "legacy-smtp-secret" {
		t.Fatalf("read legacy SMTP secret: value=%q err=%v", value, err)
	}
	if _, err := ReadConfigSecret(root, "FromEmail", view.Revision); !errors.Is(err, ErrConfigSecretUnsupported) {
		t.Fatalf("non-secret field reveal: got %v", err)
	}
	if _, err := ReadConfigSecret(root, "ApiKey", "stale"); !errors.Is(err, ErrConfigConflict) {
		t.Fatalf("stale secret reveal: got %v", err)
	}
}

func TestEditorHidesLegacyEmailExclusionsAndPreservesThemOnSave(t *testing.T) {
	root := t.TempDir()
	view := ReadConfigEditor(root)
	request := validConfigSaveRequest(t, view)
	request.Secrets["ApiKey"] = SecretChange{Action: "replace", Value: "fictional-api-key"}
	request.Secrets["SmtpPassword"] = SecretChange{Action: "replace", Value: "fictional-smtp-password"}
	_, fieldErrors, err := SaveConfig(root, request, time.Now)
	if err != nil || len(fieldErrors) != 0 {
		t.Fatalf("create config: fields=%v err=%v", fieldErrors, err)
	}
	path := filepath.Join(root, "config.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	values := map[string]any{}
	if err := json.Unmarshal(raw, &values); err != nil {
		t.Fatal(err)
	}
	values["ExcludedEmails"] = []string{"legacy@example.org"}
	raw, _ = json.Marshal(values)
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	view = ReadConfigEditor(root)
	for _, field := range view.Fields {
		if field.Name == "ExcludedEmails" {
			t.Fatal("legacy email exclusion was exposed in the Manager editor")
		}
	}
	update := validConfigSaveRequest(t, view)
	result, fieldErrors, err := SaveConfig(root, update, time.Now)
	if err != nil || len(fieldErrors) != 0 || !result.Saved {
		t.Fatalf("update config: result=%+v fields=%v err=%v", result, fieldErrors, err)
	}
	raw, _ = os.ReadFile(path)
	if !strings.Contains(string(raw), "legacy@example.org") {
		t.Fatal("hidden legacy email exclusion was not preserved")
	}
}

func TestSaveConfigValidatesAndNormalizesUserEmailOverrides(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	tests := []struct {
		name string
		raw  json.RawMessage
	}{
		{name: "array", raw: json.RawMessage(`[]`)},
		{name: "non numeric id", raw: json.RawMessage(`{"viewer":"viewer@example.org"}`)},
		{name: "oversized id", raw: json.RawMessage(`{"123456789012345678901":"viewer@example.org"}`)},
		{name: "overflowing id", raw: json.RawMessage(`{"18446744073709551616":"viewer@example.org"}`)},
		{name: "non string address", raw: json.RawMessage(`{"42":42}`)},
		{name: "invalid address", raw: json.RawMessage(`{"42":"not-an-address"}`)},
		{name: "duplicate id", raw: json.RawMessage(`{"42":"one@example.org","42":"two@example.org"}`)},
		{name: "duplicate normalized id", raw: json.RawMessage(`{"42":"one@example.org"," 42 ":"two@example.org"}`)},
	}
	longAddress, _ := json.Marshal(map[string]string{"42": strings.Repeat("a", 245) + "@example.org"})
	tests = append(tests, struct {
		name string
		raw  json.RawMessage
	}{name: "oversized address", raw: longAddress})
	tooMany := make(map[string]string, maximumUserEmailOverrides+1)
	for index := 0; index <= maximumUserEmailOverrides; index++ {
		tooMany[fmt.Sprint(index)] = "shared@example.org"
	}
	tooManyRaw, _ := json.Marshal(tooMany)
	tests = append(tests, struct {
		name string
		raw  json.RawMessage
	}{name: "too many assignments", raw: tooManyRaw})

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := validConfigSaveRequest(t, ReadConfigEditor(root))
			request.Values["UserEmailOverrides"] = test.raw
			result, fields, err := SaveConfig(root, request, time.Now)
			if err != nil || result.Saved || fields["UserEmailOverrides"] == "" {
				t.Fatalf("invalid mapping result=%+v fields=%v err=%v", result, fields, err)
			}
		})
	}

	request := validConfigSaveRequest(t, ReadConfigEditor(root))
	request.Values["UserEmailOverrides"] = json.RawMessage(`{"42":" shared@example.org ","43":"shared@example.org","44":""}`)
	result, fields, err := SaveConfig(root, request, time.Now)
	if err != nil || len(fields) != 0 || !result.Saved || !result.PostSave.WarmCache || result.PostSave.ChangedCategories[0] != "recipients" {
		t.Fatalf("valid mapping result=%+v fields=%v err=%v", result, fields, err)
	}
	stored := editorField(t, result.Editor, "UserEmailOverrides").Value.(map[string]any)
	if len(stored) != 2 || stored["42"] != "shared@example.org" || stored["43"] != "shared@example.org" {
		t.Fatalf("mapping normalization or duplicate-address support failed: %#v", stored)
	}
}

func TestUserEmailOverridesSaveEditClearPreservesOrphansAndRecipientState(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	accessState := []byte(`{"Users":{"42":{"WelcomeSentUtc":"2031-04-18T16:30:00Z"}}}`)
	accessPath := filepath.Join(root, "access-state.json")
	if err := os.WriteFile(accessPath, accessState, 0o600); err != nil {
		t.Fatal(err)
	}
	request := validConfigSaveRequest(t, ReadConfigEditor(root))
	request.Values["UserEmailOverrides"] = json.RawMessage(`{"42":"assigned@example.org","999":"orphan@example.org"}`)
	created, fields, err := SaveConfig(root, request, time.Now)
	if err != nil || len(fields) != 0 || !created.Saved {
		t.Fatalf("create mapping: result=%+v fields=%v err=%v", created, fields, err)
	}
	request = validConfigSaveRequest(t, created.Editor)
	request.Values["UserEmailOverrides"] = json.RawMessage(`{"999":"orphan@example.org"}`)
	cleared, fields, err := SaveConfig(root, request, time.Now)
	if err != nil || len(fields) != 0 || !cleared.Saved {
		t.Fatalf("clear mapping: result=%+v fields=%v err=%v", cleared, fields, err)
	}
	stored := editorField(t, cleared.Editor, "UserEmailOverrides").Value.(map[string]any)
	if len(stored) != 1 || stored["999"] != "orphan@example.org" {
		t.Fatalf("orphan mapping was not preserved while active mapping cleared: %#v", stored)
	}
	if current, err := os.ReadFile(accessPath); err != nil || string(current) != string(accessState) {
		t.Fatalf("assignment changes altered welcome/access history: %q err=%v", current, err)
	}
	backup, err := os.ReadFile(filepath.Join(root, cleared.Backup))
	if err != nil || !strings.Contains(string(backup), "assigned@example.org") {
		t.Fatalf("private config backup did not retain the previous assignment: err=%v", err)
	}
}

func TestSaveConfigCreatesAndUpdatesWithBackup(t *testing.T) {
	root := t.TempDir()
	now := func() time.Time { return time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC) }
	view := ReadConfigEditor(root)
	request := validConfigSaveRequest(t, view)
	request.Secrets["ApiKey"] = SecretChange{Action: "replace", Value: "fictional-api-key"}
	request.Secrets["SmtpPassword"] = SecretChange{Action: "replace", Value: "fictional-smtp-password"}

	created, fieldErrors, err := SaveConfig(root, request, now)
	if err != nil || len(fieldErrors) != 0 {
		t.Fatalf("create config: result=%+v fields=%v err=%v", created, fieldErrors, err)
	}
	if !created.Saved || created.Backup != "" || !created.Editor.Exists || !created.Editor.Valid {
		t.Fatalf("unexpected create result: %+v", created)
	}
	encodedResult, err := json.Marshal(created)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encodedResult), "fictional-api-key") || strings.Contains(string(encodedResult), "fictional-smtp-password") {
		t.Fatal("save response returned a submitted secret")
	}

	raw, err := os.ReadFile(filepath.Join(root, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), "fictional-api-key") || !strings.Contains(string(raw), "fictional-smtp-password") {
		t.Fatal("saved configuration did not contain the submitted credentials")
	}

	update := validConfigSaveRequest(t, created.Editor)
	update.Secrets["ApiKey"] = SecretChange{Action: "preserve"}
	update.Secrets["SmtpPassword"] = SecretChange{Action: "preserve"}
	update.Values["FooterServerName"] = json.RawMessage(`"Fictional Home"`)
	updated, fieldErrors, err := SaveConfig(root, update, now)
	if err != nil || len(fieldErrors) != 0 {
		t.Fatalf("update config: result=%+v fields=%v err=%v", updated, fieldErrors, err)
	}
	if updated.Backup == "" {
		t.Fatal("updating an existing configuration did not create a backup")
	}
	if _, err := os.Stat(filepath.Join(root, updated.Backup)); err != nil {
		t.Fatalf("configuration backup is unavailable: %v", err)
	}
	raw, err = os.ReadFile(filepath.Join(root, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{"fictional-api-key", "fictional-smtp-password", "Fictional Home"} {
		if !strings.Contains(string(raw), expected) {
			t.Fatalf("updated configuration did not preserve %q", expected)
		}
	}
}

func TestSaveConfigValidationAndRevisionConflict(t *testing.T) {
	root := t.TempDir()
	view := ReadConfigEditor(root)
	request := validConfigSaveRequest(t, view)
	request.Secrets["ApiKey"] = SecretChange{Action: "clear"}
	request.Secrets["SmtpPassword"] = SecretChange{Action: "replace", Value: "fictional-password"}
	request.Values["SmtpPort"] = json.RawMessage(`465`)
	_, fieldErrors, err := SaveConfig(root, request, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	if fieldErrors["ApiKey"] == "" || fieldErrors["SmtpPort"] == "" {
		t.Fatalf("expected API key and SMTP port errors, got %v", fieldErrors)
	}

	request = validConfigSaveRequest(t, view)
	request.ExpectedRevision = "stale"
	_, _, err = SaveConfig(root, request, time.Now)
	if !errors.Is(err, ErrConfigConflict) {
		t.Fatalf("stale revision error: got %v", err)
	}
}

func TestSaveConfigRejectsSMTPURLInsteadOfReportingUnsafeDNS(t *testing.T) {
	definition := configDefinition{Name: "SmtpHost", Type: "text", Required: true}
	_, message := parseAndValidateConfigValue(json.RawMessage(`"smtp://smtp.example.com:587"`), definition)
	if !strings.Contains(message, "hostname only") {
		t.Fatalf("SMTP URL validation message: %q", message)
	}
}

func TestSaveConfigRejectsUnsafeOrOversizedButtonLabels(t *testing.T) {
	maximum := int64(64)
	definition := configDefinition{Name: "PlexButtonLabel", Type: "text", Required: true, Max: &maximum}
	if _, message := parseAndValidateConfigValue(json.RawMessage(`"Open\nRequests"`), definition); !strings.Contains(message, "single line") {
		t.Fatalf("control-character validation message: %q", message)
	}
	if _, message := parseAndValidateConfigValue(json.RawMessage(`"`+strings.Repeat("x", 65)+`"`), definition); !strings.Contains(message, "64 characters") {
		t.Fatalf("length validation message: %q", message)
	}
}

func TestCustomTextCardValidationIsConditionalAndPlainTextOnly(t *testing.T) {
	root := t.TempDir()
	view := ReadConfigEditor(root)
	request := validConfigSaveRequest(t, view)
	request.Secrets["ApiKey"] = SecretChange{Action: "replace", Value: "fictional-api-key"}
	request.Secrets["SmtpPassword"] = SecretChange{Action: "replace", Value: "fictional-smtp-password"}
	request.Values["CustomTextCardEnabled"] = json.RawMessage(`true`)
	request.Values["CustomTextCardBody"] = json.RawMessage(`""`)
	request.Values["CustomTextCardBorderColor"] = json.RawMessage(`"blue"`)
	request.Values["CustomTextCardTitleGif"] = json.RawMessage(`"../alert.gif"`)

	_, fieldErrors, err := SaveConfig(root, request, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	if fieldErrors["CustomTextCardBody"] == "" || fieldErrors["CustomTextCardBorderColor"] == "" || fieldErrors["CustomTextCardTitleGif"] == "" {
		t.Fatalf("expected conditional body and color errors, got %v", fieldErrors)
	}

	request.Values["CustomTextCardBody"] = json.RawMessage("\"First line\\r\\nSecond <line> & safe\"")
	request.Values["CustomTextCardBorderColor"] = json.RawMessage(`"#72aef7"`)
	request.Values["CustomTextCardTitleGif"] = json.RawMessage(`"Celebrate"`)
	request.Values["CustomTextCardBorderOpacity"] = json.RawMessage(`101`)
	_, fieldErrors, err = SaveConfig(root, request, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	if fieldErrors["CustomTextCardBorderOpacity"] == "" {
		t.Fatalf("expected opacity range error, got %v", fieldErrors)
	}

	request.Values["CustomTextCardBorderOpacity"] = json.RawMessage(`34`)
	result, fieldErrors, err := SaveConfig(root, request, time.Now)
	if err != nil || len(fieldErrors) != 0 || !result.Saved {
		t.Fatalf("save custom text card: result=%+v fields=%v err=%v", result, fieldErrors, err)
	}
	raw, err := os.ReadFile(filepath.Join(root, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	stored := map[string]any{}
	if err := json.Unmarshal(raw, &stored); err != nil {
		t.Fatal(err)
	}
	if stored["CustomTextCardEnabled"] != true || stored["CustomTextCardTitleGif"] != "celebrate" || stored["CustomTextCardBody"] != "First line\nSecond <line> & safe" {
		t.Fatalf("custom text card values were not stored as normalized plain text: %#v", stored)
	}
}

func TestCustomTextCardDisablePreservesSavedContent(t *testing.T) {
	root := t.TempDir()
	view := ReadConfigEditor(root)
	request := validConfigSaveRequest(t, view)
	request.Secrets["ApiKey"] = SecretChange{Action: "replace", Value: "fictional-api-key"}
	request.Secrets["SmtpPassword"] = SecretChange{Action: "replace", Value: "fictional-smtp-password"}
	request.Values["CustomTextCardEnabled"] = json.RawMessage(`true`)
	request.Values["CustomTextCardBorderColor"] = json.RawMessage(`"#123abc"`)
	request.Values["CustomTextCardBorderOpacity"] = json.RawMessage(`47`)
	request.Values["CustomTextCardTitle"] = json.RawMessage(`"MAINTENANCE NOTICE"`)
	request.Values["CustomTextCardTitleGif"] = json.RawMessage(`"warning"`)
	request.Values["CustomTextCardSubheading"] = json.RawMessage(`"Synthetic maintenance window"`)
	request.Values["CustomTextCardBody"] = json.RawMessage(`"Synthetic details remain saved while hidden."`)

	result, fieldErrors, err := SaveConfig(root, request, time.Now)
	if err != nil || len(fieldErrors) != 0 || !result.Saved {
		t.Fatalf("save enabled custom text card: result=%+v fields=%v err=%v", result, fieldErrors, err)
	}

	view = ReadConfigEditor(root)
	request = validConfigSaveRequest(t, view)
	request.Values["CustomTextCardEnabled"] = json.RawMessage(`false`)
	result, fieldErrors, err = SaveConfig(root, request, time.Now)
	if err != nil || len(fieldErrors) != 0 || !result.Saved {
		t.Fatalf("disable custom text card: result=%+v fields=%v err=%v", result, fieldErrors, err)
	}

	assertCustomTextCard := func(wantEnabled string) ConfigEditorView {
		t.Helper()
		current := ReadConfigEditor(root)
		want := map[string]string{
			"CustomTextCardEnabled":       wantEnabled,
			"CustomTextCardBorderColor":   "#123abc",
			"CustomTextCardBorderOpacity": "47",
			"CustomTextCardTitle":         "MAINTENANCE NOTICE",
			"CustomTextCardTitleGif":      "warning",
			"CustomTextCardSubheading":    "Synthetic maintenance window",
			"CustomTextCardBody":          "Synthetic details remain saved while hidden.",
		}
		for name, expected := range want {
			if got := fmt.Sprint(editorField(t, current, name).Value); got != expected {
				t.Errorf("%s after toggle: got %q, want %q", name, got, expected)
			}
		}
		return current
	}

	view = assertCustomTextCard("false")
	request = validConfigSaveRequest(t, view)
	request.Values["CustomTextCardEnabled"] = json.RawMessage(`true`)
	result, fieldErrors, err = SaveConfig(root, request, time.Now)
	if err != nil || len(fieldErrors) != 0 || !result.Saved {
		t.Fatalf("re-enable custom text card: result=%+v fields=%v err=%v", result, fieldErrors, err)
	}
	assertCustomTextCard("true")
}

func TestReadConfigEditorNormalizesUnsafeStoredTitleGifWithoutBreakingStartup(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	path := filepath.Join(root, "config.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	values := map[string]any{}
	if err := json.Unmarshal(raw, &values); err != nil {
		t.Fatal(err)
	}
	values["CustomTextCardTitleGif"] = "../../unsafe.gif"
	raw, err = json.Marshal(values)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	view := ReadConfigEditor(root)
	if value := editorField(t, view, "CustomTextCardTitleGif").Value; value != "none" {
		t.Fatalf("unsafe stored title GIF was not normalized: %#v", value)
	}
	if issue := view.Issues["CustomTextCardTitleGif"]; issue != "" {
		t.Fatalf("unsafe stored title GIF broke startup: %q", issue)
	}
}

func validConfigSaveRequest(t *testing.T, view ConfigEditorView) ConfigSaveRequest {
	t.Helper()
	request := ConfigSaveRequest{ExpectedRevision: view.Revision, Values: map[string]json.RawMessage{}, Secrets: map[string]SecretChange{}}
	for _, field := range view.Fields {
		if field.Type == "secret" {
			request.Secrets[field.Name] = SecretChange{Action: "preserve"}
			continue
		}
		value := field.Value
		switch field.Name {
		case "FromEmail", "ReplyToEmail":
			value = "newsletter@example.org"
		case "TestEmail":
			value = "admin@example.org"
		case "SmtpHost":
			value = "smtp.example.test"
		case "SmtpUsername":
			value = "newsletter@example.org"
		}
		encoded, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		request.Values[field.Name] = encoded
	}
	return request
}

func editorField(t *testing.T, view ConfigEditorView, name string) ConfigEditorField {
	t.Helper()
	for _, field := range view.Fields {
		if field.Name == name {
			return field
		}
	}
	t.Fatalf("editor field %s not found", name)
	return ConfigEditorField{}
}
