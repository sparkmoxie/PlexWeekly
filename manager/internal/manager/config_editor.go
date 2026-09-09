package manager

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/mail"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const missingConfigRevision = "missing"

const (
	maximumUserEmailOverrides = 2000
	maximumDeliveryEmailRunes = 254
)

var (
	ErrConfigConflict            = errors.New("configuration changed after it was loaded")
	ErrConfigInvalid             = errors.New("existing configuration is not valid JSON")
	ErrConfigSecretUnsupported   = errors.New("configuration secret is not supported")
	ErrConfigSecretNotConfigured = errors.New("configuration secret is not configured")
)

type configDefinition struct {
	Name        string
	Label       string
	Group       string
	Type        string
	Required    bool
	Help        string
	Placeholder string
	Default     any
	Options     []string
	Min         *int64
	Max         *int64
}

type ConfigEditorField struct {
	Name        string        `json:"name"`
	Label       string        `json:"label"`
	Group       string        `json:"group"`
	Type        string        `json:"type"`
	Required    bool          `json:"required"`
	Help        string        `json:"help,omitempty"`
	Placeholder string        `json:"placeholder,omitempty"`
	Value       any           `json:"value,omitempty"`
	Secret      *SecretStatus `json:"secret,omitempty"`
	Options     []string      `json:"options,omitempty"`
	Min         *int64        `json:"min,omitempty"`
	Max         *int64        `json:"max,omitempty"`
}

type ConfigEditorView struct {
	SchemaVersion int                 `json:"schemaVersion"`
	Exists        bool                `json:"exists"`
	Valid         bool                `json:"valid"`
	State         string              `json:"state"`
	Revision      string              `json:"revision"`
	Groups        []string            `json:"groups"`
	Fields        []ConfigEditorField `json:"fields"`
	Issues        map[string]string   `json:"issues,omitempty"`
	DirectPlex    DirectPlexStatus    `json:"directPlex"`
}

type DirectPlexStatus struct {
	LegacyFieldsMissing   bool `json:"legacyFieldsMissing"`
	URLConfigured         bool `json:"urlConfigured"`
	TokenConfigured       bool `json:"tokenConfigured"`
	RuntimeTokenAvailable bool `json:"runtimeTokenAvailable"`
}

type SecretChange struct {
	Action string `json:"action"`
	Value  string `json:"value,omitempty"`
}

type ConfigSaveRequest struct {
	ExpectedRevision string                     `json:"expectedRevision"`
	Values           map[string]json.RawMessage `json:"values"`
	Secrets          map[string]SecretChange    `json:"secrets"`
}

type ConfigSaveResult struct {
	Saved            bool               `json:"saved"`
	Backup           string             `json:"backup,omitempty"`
	Editor           ConfigEditorView   `json:"editor"`
	PostSave         ConfigPostSavePlan `json:"postSave"`
	PreviousRevision string             `json:"-"`
}

// ConfigPostSavePlan is computed from normalized in-memory values so the
// browser never needs to classify fields or inspect secret values. Retained
// flags are populated by the server only when sanitized evidence was actually
// rebased to the new full configuration revision.
type ConfigPostSavePlan struct {
	MaterialChange      bool     `json:"materialChange"`
	ChangedCategories   []string `json:"changedCategories,omitempty"`
	ConfirmationCode    string   `json:"confirmationCode,omitempty"`
	RunDiscovery        bool     `json:"runDiscovery"`
	RunIntegration      bool     `json:"runIntegration"`
	RunSMTP             bool     `json:"runSmtp"`
	GeneratePreviews    bool     `json:"generatePreviews"`
	WarmCache           bool     `json:"warmCache"`
	VerifyCache         bool     `json:"verifyCache"`
	CacheEnabled        bool     `json:"cacheEnabled"`
	RetainedDiscovery   bool     `json:"retainedDiscovery"`
	RetainedIntegration bool     `json:"retainedIntegration"`
	RetainedSMTP        bool     `json:"retainedSmtp"`
	RetainedPreviews    bool     `json:"retainedPreviews"`
}

func integerBounds(minimum, maximum int64) (*int64, *int64) {
	return &minimum, &maximum
}

func configDefinitions() []configDefinition {
	portMin, portMax := integerBounds(1, 65535)
	_, shortMax := integerBounds(0, 300)
	_, buttonLabelMax := integerBounds(0, 64)
	_, customTitleMax := integerBounds(0, 120)
	_, customSubheadingMax := integerBounds(0, 200)
	_, customBodyMax := integerBounds(0, 2000)
	_, daysMax := integerBounds(1, 3650)
	opacityMin, opacityMax := integerBounds(0, 100)
	percentMin, percentMax := integerBounds(1, 100)
	countMin, countMax := integerBounds(0, 100)
	itemsMin, itemsMax := integerBounds(1, 10000)
	bytesMin, bytesMax := integerBounds(16, 2048)
	delayMin, delayMax := integerBounds(0, 3600)
	return []configDefinition{
		{Name: "TautulliUrl", Label: "Tautulli URL", Group: "Connections", Type: "url", Required: true, Help: "Base URL reachable from this Manager runtime. Verification runs after a successful save and is restricted to private or loopback destinations.", Placeholder: "http://127.0.0.1:8181", Default: "http://127.0.0.1:8181"},
		{Name: "ApiKey", Label: "Tautulli API key", Group: "Connections", Type: "secret", Required: true, Help: "Leave blank to preserve the stored key. Revealing it requires your Manager password and clears automatically."},
		{Name: "PlexServerUrl", Label: "Direct Plex server URL", Group: "Connections", Type: "url", Help: "Recommended for complete ratings, exact-episode metadata, backgrounds, and selected logos. Must be reachable from this Manager runtime.", Placeholder: "http://plex.example.test:32400", Default: ""},
		{Name: "PlexToken", Label: "Plex token", Group: "Connections", Type: "secret", Help: "Recommended with the direct Plex URL. Leave blank to preserve it. A supported runtime token can be used without copying it into config.json."},
		{Name: "PlexWebUrl", Label: "Open Plex button URL or custom link", Group: "Identity", Type: "url", Required: true, Default: "https://app.plex.tv/desktop/"},
		{Name: "PlexButtonLabel", Label: "Button label", Group: "Identity", Type: "text", Required: true, Default: "Open Plex", Max: buttonLabelMax},
		{Name: "ServerLabel", Label: "Header label", Group: "Identity", Type: "text", Required: true, Default: "PLEX"},
		{Name: "FooterServerName", Label: "Server display name", Group: "Identity", Type: "text", Required: true, Default: "My Plex"},
		{Name: "FromName", Label: "From display name", Group: "Email", Type: "text", Required: true, Default: "TautWeekly for Plex"},
		{Name: "FromEmail", Label: "From email", Group: "Email", Type: "email", Required: true, Placeholder: "newsletter@example.com", Default: ""},
		{Name: "ReplyToEmail", Label: "Reply-to email", Group: "Email", Type: "email", Placeholder: "newsletter@example.com", Default: ""},
		{Name: "TestEmail", Label: "Test recipient", Group: "Email", Type: "email", Required: true, Placeholder: "you@example.com", Default: ""},
		{Name: "SmtpHost", Label: "SMTP host", Group: "SMTP", Type: "text", Required: true, Placeholder: "smtp.example.com", Default: ""},
		{Name: "SmtpPort", Label: "SMTP port", Group: "SMTP", Type: "integer", Required: true, Default: int64(587), Min: portMin, Max: portMax, Help: "Port 465 is unsupported; use a STARTTLS port such as 587."},
		{Name: "SmtpEnableSsl", Label: "Use TLS / STARTTLS", Group: "SMTP", Type: "boolean", Default: true},
		{Name: "SmtpUseAuthentication", Label: "Use SMTP authentication", Group: "SMTP", Type: "boolean", Default: true},
		{Name: "SmtpUsername", Label: "SMTP username", Group: "SMTP", Type: "text", Default: ""},
		{Name: "SmtpPassword", Label: "SMTP password", Group: "SMTP", Type: "secret", Help: "Leave blank to preserve the stored password. Revealing it requires your Manager password and clears automatically."},
		{Name: "SmtpStripPasswordSpaces", Label: "Strip password spaces", Group: "SMTP", Type: "boolean", Default: false},
		{Name: "SmtpAuthenticationMethod", Label: "Authentication method", Group: "SMTP", Type: "select", Required: true, Default: "Auto", Options: []string{"Auto"}},
		{Name: "SmtpTimeoutSeconds", Label: "SMTP timeout (seconds)", Group: "SMTP", Type: "integer", Required: true, Default: int64(30), Min: portMin, Max: shortMax},
		{Name: "ScheduleDay", Label: "Weekly send day", Group: "Schedule", Type: "select", Required: true, Default: "Friday", Options: []string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}},
		{Name: "ScheduleTime", Label: "Weekly local send time", Group: "Schedule", Type: "time", Required: true, Default: "09:30"},
		{Name: "ScheduledTaskName", Label: "Windows task name", Group: "Schedule", Type: "text", Required: true, Default: "TautWeekly for Plex Newsletter"},
		{Name: "DaysBack", Label: "Newsletter history days", Group: "Newsletter", Type: "integer", Required: true, Default: int64(7), Min: portMin, Max: daysMax},
		{Name: "RecentAccessDays", Label: "Recent-access days", Group: "Newsletter", Type: "integer", Required: true, Default: int64(7), Min: portMin, Max: daysMax},
		{Name: "WatchedPercent", Label: "Watched threshold (%)", Group: "Newsletter", Type: "integer", Required: true, Default: int64(85), Min: percentMin, Max: percentMax},
		{Name: "MaxMovies", Label: "Maximum movies", Group: "Newsletter", Type: "integer", Required: true, Default: int64(8), Min: countMin, Max: countMax},
		{Name: "MaxTv", Label: "Maximum TV entries", Group: "Newsletter", Type: "integer", Required: true, Default: int64(8), Min: countMin, Max: countMax},
		{Name: "SendDelaySeconds", Label: "Send delay (seconds)", Group: "Newsletter", Type: "integer", Required: true, Default: int64(30), Min: delayMin, Max: delayMax},
		{Name: "TestSendDelaySeconds", Label: "Test-send delay (seconds)", Group: "Newsletter", Type: "integer", Required: true, Default: int64(10), Min: delayMin, Max: delayMax},
		{Name: "DeletedItemCacheEnabled", Label: "Enable deleted-item cache", Group: "Cache", Type: "boolean", Default: true},
		{Name: "DeletedItemCacheRetentionDays", Label: "Cache retention days", Group: "Cache", Type: "integer", Required: true, Default: int64(365), Min: portMin, Max: daysMax},
		{Name: "DeletedItemCacheMaxItems", Label: "Maximum cached items", Group: "Cache", Type: "integer", Required: true, Default: int64(1000), Min: itemsMin, Max: itemsMax},
		{Name: "DeletedItemCacheMaxBytesMB", Label: "Maximum cache size (MB)", Group: "Cache", Type: "integer", Required: true, Default: int64(256), Min: bytesMin, Max: bytesMax},
		{Name: "CustomTextCardEnabled", Label: "Enable custom text card", Group: "Custom text card", Type: "boolean", Default: false, Help: "When enabled, this card appears before the newsletter release-count and date block in every newsletter state. Disabling it hides the card without clearing its saved content."},
		{Name: "CustomTextCardBorderColor", Label: "Border color", Group: "Custom text card", Type: "color", Default: "#72aef7", Help: "Choose the card accent color. Border opacity controls whether it is visible."},
		{Name: "CustomTextCardBorderOpacity", Label: "Border opacity", Group: "Custom text card", Type: "range", Default: int64(34), Min: opacityMin, Max: opacityMax, Help: "Set to 0% for no border."},
		{Name: "CustomTextCardTitle", Label: "Optional title", Group: "Custom text card", Type: "text", Default: "", Max: customTitleMax, Help: "Gold uppercase label using the Welcome Aboard title size."},
		{Name: "CustomTextCardTitleGif", Label: "Optional title GIF", Group: "Custom text card", Type: "asset-id", Default: "none", Options: []string{"celebrate", "construction", "rocket", "tickets", "warning", "alert"}, Help: "Optional allowlisted GIF displayed beside the uppercase title."},
		{Name: "CustomTextCardSubheading", Label: "Optional subheading", Group: "Custom text card", Type: "text", Default: "", Max: customSubheadingMax, Help: "Large white heading using the Welcome Aboard heading size."},
		{Name: "CustomTextCardBody", Label: "Card body (required when enabled)", Group: "Custom text card", Type: "textarea", Default: "", Max: customBodyMax, Help: "Plain text only. Line breaks are preserved and HTML is always escaped."},
		{Name: "IncludedLibraryIds", Label: "Included library IDs", Group: "Advanced", Type: "string-list", Help: "Comma-separated Tautulli section IDs. Empty retains legacy all-library scope.", Default: []string{}},
		{Name: "ExcludedUserIds", Label: "Excluded user IDs", Group: "Advanced", Type: "string-list", Help: "Comma-separated Tautulli user IDs.", Default: []string{}},
		{Name: "UserEmailOverrides", Label: "Managed-user delivery addresses", Group: "Advanced", Type: "user-email-map", Help: "Private fallback delivery addresses keyed by numeric Tautulli user ID. Manager exposes assignments only in the authenticated guided Config flow.", Default: map[string]string{}},
		{Name: "ExcludedEmails", Label: "Excluded email addresses", Group: "Advanced", Type: "email-list", Help: "Legacy config-file exclusion list preserved by the Manager but not exposed in the GUI.", Default: []string{}},
	}
}

func ReadConfigEditor(root string) ConfigEditorView {
	values, raw, exists, state := readConfigDocument(root)
	view := ConfigEditorView{SchemaVersion: 1, Exists: exists, Valid: state == "ready" || state == "unconfigured", State: state, Revision: configRevision(raw, exists)}
	_, plexURLPresent := values["PlexServerUrl"]
	_, plexTokenPresent := values["PlexToken"]
	view.DirectPlex = DirectPlexStatus{
		LegacyFieldsMissing:   exists && (!plexURLPresent || !plexTokenPresent),
		URLConfigured:         configValueConfigured(values["PlexServerUrl"]),
		TokenConfigured:       configValueConfigured(values["PlexToken"]),
		RuntimeTokenAvailable: runtimePlexToken(values) != "" && !configValueConfigured(values["PlexToken"]),
	}
	view.Groups = []string{"Connections", "Identity", "Email", "SMTP", "Schedule", "Newsletter", "Cache", "Custom text card", "Advanced"}
	if !view.Valid {
		view.Fields = []ConfigEditorField{}
		return view
	}
	for _, definition := range configDefinitions() {
		if managerPreservesConfigValue(definition.Name) {
			continue
		}
		field := ConfigEditorField{Name: definition.Name, Label: definition.Label, Group: definition.Group, Type: definition.Type, Required: definition.Required, Help: definition.Help, Placeholder: definition.Placeholder, Options: definition.Options, Min: definition.Min, Max: definition.Max}
		if definition.Type == "secret" {
			field.Secret = &SecretStatus{Configured: secretConfigured(values, definition.Name)}
			if definition.Name == "PlexToken" {
				field.Secret.AvailableFromRuntime = view.DirectPlex.RuntimeTokenAvailable
			}
		} else if value, ok := values[definition.Name]; ok {
			field.Value = editorValue(value, definition)
		} else {
			field.Value = definition.Default
		}
		view.Fields = append(view.Fields, field)
	}
	view.Issues = existingConfigIssues(values)
	if exists && len(view.Issues) > 0 {
		view.State = "needs-setup"
	}
	return view
}

func SaveConfig(root string, request ConfigSaveRequest, now func() time.Time) (ConfigSaveResult, map[string]string, error) {
	current, raw, exists, state := readConfigDocument(root)
	if state != "ready" && state != "unconfigured" {
		return ConfigSaveResult{}, nil, ErrConfigInvalid
	}
	if request.ExpectedRevision == "" || request.ExpectedRevision != configRevision(raw, exists) {
		return ConfigSaveResult{}, nil, ErrConfigConflict
	}

	definitions := configDefinitions()
	knownValues := make(map[string]configDefinition)
	knownSecrets := make(map[string]configDefinition)
	for _, definition := range definitions {
		if definition.Type == "secret" {
			knownSecrets[definition.Name] = definition
		} else if !managerPreservesConfigValue(definition.Name) {
			knownValues[definition.Name] = definition
		}
	}

	fieldErrors := make(map[string]string)
	for name := range request.Values {
		if _, ok := knownValues[name]; !ok {
			fieldErrors[name] = "This field is not supported by the current Manager schema."
		}
	}
	for name := range request.Secrets {
		if _, ok := knownSecrets[name]; !ok {
			fieldErrors[name] = "This secret is not supported by the current Manager schema."
		}
	}

	next := cloneConfigMap(current)
	for name, definition := range knownValues {
		rawValue, ok := request.Values[name]
		if !ok {
			fieldErrors[name] = "A value is required in the submitted configuration."
			continue
		}
		value, message := parseAndValidateConfigValue(rawValue, definition)
		if message != "" {
			fieldErrors[name] = message
			continue
		}
		next[name] = value
	}

	for name, definition := range knownSecrets {
		change, ok := request.Secrets[name]
		if !ok {
			change.Action = "preserve"
		}
		switch change.Action {
		case "preserve":
			if name == "PlexToken" {
				if _, present := next[name]; !present {
					next[name] = ""
				}
			}
		case "replace":
			if strings.TrimSpace(change.Value) == "" || strings.HasPrefix(strings.ToUpper(strings.TrimSpace(change.Value)), "PASTE_") {
				fieldErrors[name] = "Enter a real value or leave the field blank to preserve the stored secret."
				continue
			}
			next[name] = change.Value
			if name == "SmtpPassword" {
				delete(next, "SmtpAppPassword")
			}
		case "clear":
			delete(next, name)
			if name == "SmtpPassword" {
				delete(next, "SmtpAppPassword")
			}
		default:
			fieldErrors[name] = "Secret action must be preserve, replace, or clear."
		}
		_ = definition
	}

	validateConfigRelationships(next, fieldErrors)
	if len(fieldErrors) > 0 {
		return ConfigSaveResult{}, fieldErrors, nil
	}
	previousRevision := configRevision(raw, exists)
	postSave := classifyConfigPostSave(normalizedConfigValues(current), normalizedConfigValues(next), exists)

	encoded, err := json.MarshalIndent(next, "", "  ")
	if err != nil {
		return ConfigSaveResult{}, nil, fmt.Errorf("encode configuration: %w", err)
	}
	encoded = append(encoded, '\n')
	if exists && bytes.Equal(raw, encoded) {
		return ConfigSaveResult{
			Saved:            false,
			Editor:           ReadConfigEditor(root),
			PostSave:         postSave,
			PreviousRevision: previousRevision,
		}, nil, nil
	}
	if now == nil {
		now = time.Now
	}
	backup, err := writeConfigAtomically(root, raw, exists, encoded, now())
	if err != nil {
		return ConfigSaveResult{}, nil, err
	}
	return ConfigSaveResult{Saved: true, Backup: backup, Editor: ReadConfigEditor(root), PostSave: postSave, PreviousRevision: previousRevision}, nil, nil
}

func normalizedConfigValues(values map[string]any) map[string]any {
	normalized := make(map[string]any)
	for _, definition := range configDefinitions() {
		if definition.Type == "secret" {
			value := values[definition.Name]
			if definition.Name == "SmtpPassword" && !configValueConfigured(value) {
				value = values["SmtpAppPassword"]
			}
			if text, ok := value.(string); ok {
				normalized[definition.Name] = text
			} else {
				normalized[definition.Name] = ""
			}
			continue
		}
		value, exists := values[definition.Name]
		if !exists {
			value = definition.Default
		}
		encoded, err := json.Marshal(editorValue(value, definition))
		if err != nil {
			normalized[definition.Name] = value
			continue
		}
		parsed, message := parseAndValidateConfigValue(encoded, definition)
		if message != "" {
			normalized[definition.Name] = editorValue(value, definition)
			continue
		}
		normalized[definition.Name] = parsed
	}
	return normalized
}

func classifyConfigPostSave(current, next map[string]any, existed bool) ConfigPostSavePlan {
	changed := make(map[string]bool)
	for name, nextValue := range next {
		if !configComparisonEqual(current[name], nextValue) {
			changed[name] = true
		}
	}
	if !existed {
		for name := range next {
			changed[name] = true
		}
	}

	plan := ConfigPostSavePlan{}
	category := make(map[string]bool)
	cacheCoverageChanged := false
	for name := range changed {
		switch {
		case name == "TautulliUrl" || name == "ApiKey":
			category["tautulli"] = true
			cacheCoverageChanged = true
			plan.RunDiscovery = true
			plan.RunIntegration = true
			plan.GeneratePreviews = true
		case name == "PlexServerUrl" || name == "PlexToken":
			category["plex"] = true
			cacheCoverageChanged = true
			plan.RunIntegration = true
			plan.GeneratePreviews = true
		case strings.HasPrefix(name, "Smtp"):
			category["smtp"] = true
			plan.RunSMTP = true
		case name == "PlexWebUrl" || name == "PlexButtonLabel" || name == "ServerLabel" || name == "FooterServerName":
			category["identity"] = true
			plan.GeneratePreviews = true
		case name == "FromName" || name == "FromEmail" || name == "ReplyToEmail" || name == "TestEmail":
			category["email"] = true
		case strings.HasPrefix(name, "Schedule") || name == "ScheduledTaskName":
			category["schedule"] = true
		case strings.HasPrefix(name, "DeletedItemCache"):
			category["cache"] = true
			cacheCoverageChanged = true
		case strings.HasPrefix(name, "CustomTextCard"):
			category["custom-text-card"] = true
			plan.GeneratePreviews = true
		case name == "IncludedLibraryIds":
			category["libraries"] = true
			cacheCoverageChanged = true
			plan.GeneratePreviews = true
		case name == "ExcludedUserIds" || name == "ExcludedEmails" || name == "UserEmailOverrides":
			category["recipients"] = true
			cacheCoverageChanged = true
			plan.GeneratePreviews = true
		case name == "DaysBack" || name == "RecentAccessDays" || name == "WatchedPercent" || name == "MaxMovies" || name == "MaxTv":
			category["newsletter"] = true
			cacheCoverageChanged = true
			plan.GeneratePreviews = true
		case name == "SendDelaySeconds" || name == "TestSendDelaySeconds":
			category["newsletter"] = true
		default:
			category["delivery"] = true
		}
	}
	cacheEnabled := true
	if value, exists := next["DeletedItemCacheEnabled"]; exists {
		if parsed, ok := value.(bool); ok {
			cacheEnabled = parsed
		}
	}
	plan.CacheEnabled = cacheEnabled
	plan.WarmCache = cacheEnabled && cacheCoverageChanged
	plan.VerifyCache = cacheEnabled
	plan.MaterialChange = len(changed) > 0
	for _, name := range []string{"tautulli", "plex", "smtp", "identity", "email", "schedule", "newsletter", "cache", "custom-text-card", "libraries", "recipients", "delivery"} {
		if category[name] {
			plan.ChangedCategories = append(plan.ChangedCategories, name)
		}
	}
	if len(category) == 1 && category["cache"] {
		plan.ConfirmationCode = "cache-updated"
		if changed["DeletedItemCacheEnabled"] {
			if enabled, _ := next["DeletedItemCacheEnabled"].(bool); enabled {
				plan.ConfirmationCode = "cache-enabled"
			} else {
				plan.ConfirmationCode = "cache-disabled"
			}
		}
	}
	return plan
}

func configComparisonEqual(left, right any) bool {
	leftJSON, leftErr := json.Marshal(left)
	rightJSON, rightErr := json.Marshal(right)
	return leftErr == nil && rightErr == nil && bytes.Equal(leftJSON, rightJSON)
}

func managerPreservesConfigValue(name string) bool {
	return name == "ExcludedEmails"
}

// ReadConfigSecret returns exactly one supported secret after the caller has
// separately re-authenticated. It never provides a bulk credential view.
func ReadConfigSecret(root, name, expectedRevision string) (string, error) {
	values, raw, exists, state := readConfigDocument(root)
	if state != "ready" || !exists {
		return "", ErrConfigInvalid
	}
	if expectedRevision == "" || expectedRevision != configRevision(raw, true) {
		return "", ErrConfigConflict
	}
	supported := false
	for _, definition := range configDefinitions() {
		if definition.Name == name && definition.Type == "secret" {
			supported = true
			break
		}
	}
	if !supported {
		return "", ErrConfigSecretUnsupported
	}
	value := values[name]
	if name == "SmtpPassword" && !configValueConfigured(value) {
		value = values["SmtpAppPassword"]
	}
	secret, ok := value.(string)
	if !ok || secret == "" {
		return "", ErrConfigSecretNotConfigured
	}
	return secret, nil
}

func readConfigDocument(root string) (map[string]any, []byte, bool, string) {
	path := filepath.Join(root, "config.json")
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]any{}, nil, false, "unconfigured"
	}
	if err != nil {
		return nil, nil, true, "unreadable"
	}
	values, state := decodeConfigDocument(raw)
	return values, raw, true, state
}

func decodeConfigDocument(raw []byte) (map[string]any, string) {
	if len(raw) > maximumConfigBytes {
		return nil, "invalid-json"
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	values := make(map[string]any)
	if err := decoder.Decode(&values); err != nil {
		return nil, "invalid-json"
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return nil, "invalid-json"
	}
	return values, "ready"
}

func configRevision(raw []byte, exists bool) string {
	if !exists {
		return missingConfigRevision
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

func secretConfigured(values map[string]any, name string) bool {
	if configValueConfigured(values[name]) {
		return true
	}
	return name == "SmtpPassword" && configValueConfigured(values["SmtpAppPassword"])
}

func editorValue(value any, definition configDefinition) any {
	if definition.Type == "asset-id" {
		return normalizeCustomTextCardTitleGif(value)
	}
	if definition.Type == "string-list" || definition.Type == "email-list" {
		result := []string{}
		if values, ok := value.([]any); ok {
			for _, item := range values {
				if text, ok := item.(string); ok {
					result = append(result, text)
				}
			}
		}
		if values, ok := value.([]string); ok {
			result = append(result, values...)
		}
		return result
	}
	if definition.Type == "user-email-map" {
		return value
	}
	if number, ok := value.(json.Number); ok {
		parsed, err := number.Int64()
		if err == nil {
			return parsed
		}
	}
	return value
}

func parseAndValidateConfigValue(raw json.RawMessage, definition configDefinition) (any, string) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, "The submitted value is not valid JSON."
	}
	switch definition.Type {
	case "boolean":
		parsed, ok := value.(bool)
		if !ok {
			return nil, "Choose enabled or disabled."
		}
		return parsed, ""
	case "integer", "range":
		number, ok := value.(json.Number)
		if !ok {
			return nil, "Enter a whole number."
		}
		parsed, err := number.Int64()
		if err != nil {
			return nil, "Enter a whole number."
		}
		if definition.Min != nil && parsed < *definition.Min || definition.Max != nil && parsed > *definition.Max {
			return nil, fmt.Sprintf("Enter a value from %d through %d.", *definition.Min, *definition.Max)
		}
		if definition.Name == "SmtpPort" && parsed == 465 {
			return nil, "Port 465 uses implicit SMTPS and is unsupported; use a STARTTLS port such as 587."
		}
		return parsed, ""
	case "string-list", "email-list":
		items, ok := value.([]any)
		if !ok {
			return nil, "Enter a comma-separated list."
		}
		seen := make(map[string]struct{})
		result := []string{}
		for _, item := range items {
			text, ok := item.(string)
			if !ok {
				return nil, "Every list value must be text."
			}
			text = strings.TrimSpace(text)
			if text == "" {
				continue
			}
			if definition.Type == "email-list" && !validEmail(text) {
				return nil, fmt.Sprintf("%s is not a valid email address.", text)
			}
			if _, duplicate := seen[strings.ToLower(text)]; !duplicate {
				seen[strings.ToLower(text)] = struct{}{}
				result = append(result, text)
			}
		}
		return result, ""
	case "user-email-map":
		if hasDuplicateUserEmailOverrideKeys(raw) {
			return nil, "Each Tautulli user ID may appear only once."
		}
		items, ok := value.(map[string]any)
		if !ok {
			return nil, "Submit delivery addresses as an object keyed by Tautulli user ID."
		}
		result := make(map[string]string, len(items))
		seen := make(map[string]struct{}, len(items))
		for rawID, rawAddress := range items {
			id := strings.TrimSpace(rawID)
			// Preserve legacy Local mappings as inert config. Recipient discovery
			// and delivery reject zero; upgrading must not invalidate other users.
			if !validTautulliUserID(id) && !reservedTautulliUserID(id) {
				return nil, "Every delivery-address key must be a valid numeric Tautulli user ID."
			}
			if _, duplicate := seen[id]; duplicate {
				return nil, "Each normalized Tautulli user ID may appear only once."
			}
			seen[id] = struct{}{}
			address, ok := rawAddress.(string)
			if !ok {
				return nil, fmt.Sprintf("Delivery address for user %s must be text.", id)
			}
			address = strings.TrimSpace(address)
			if address == "" {
				continue
			}
			if utf8.RuneCountInString(address) > maximumDeliveryEmailRunes || !validEmail(address) {
				return nil, fmt.Sprintf("Delivery address for user %s is not a valid email address of %d characters or fewer.", id, maximumDeliveryEmailRunes)
			}
			result[id] = address
		}
		if len(result) > maximumUserEmailOverrides {
			return nil, fmt.Sprintf("Configure no more than %d managed-user delivery addresses.", maximumUserEmailOverrides)
		}
		return result, ""
	default:
		text, ok := value.(string)
		if !ok {
			return nil, "Enter a text value."
		}
		text = strings.TrimSpace(text)
		if definition.Type == "asset-id" {
			normalized := strings.ToLower(text)
			if normalized == "none" || containsFold(definition.Options, normalized) {
				return normalized, ""
			}
			return nil, "Choose one of the available title GIFs or clear the selection."
		}
		if definition.Required && text == "" {
			return nil, "This field is required."
		}
		if definition.Type == "email" && text != "" && !validEmail(text) {
			return nil, "Enter a valid email address."
		}
		if definition.Type == "url" && text != "" && !validHTTPURL(text) {
			return nil, "Enter a complete http:// or https:// URL."
		}
		if definition.Type == "color" && text != "" && !validHexColor(text) {
			return nil, "Choose a six-digit hexadecimal color."
		}
		if strings.HasPrefix(definition.Name, "CustomTextCard") {
			if definition.Type == "textarea" {
				if strings.IndexFunc(text, func(r rune) bool { return unicode.IsControl(r) && r != '\r' && r != '\n' && r != '\t' }) >= 0 {
					return nil, "Use plain text with line breaks only."
				}
				text = strings.ReplaceAll(text, "\r\n", "\n")
				text = strings.ReplaceAll(text, "\r", "\n")
			} else if strings.IndexFunc(text, unicode.IsControl) >= 0 {
				return nil, "Use a single line without control characters."
			}
			if definition.Max != nil && int64(utf8.RuneCountInString(text)) > *definition.Max {
				return nil, fmt.Sprintf("Use %d characters or fewer.", *definition.Max)
			}
		}
		if definition.Name == "PlexButtonLabel" {
			if strings.IndexFunc(text, unicode.IsControl) >= 0 {
				return nil, "Use a single line without control characters."
			}
			if definition.Max != nil && int64(utf8.RuneCountInString(text)) > *definition.Max {
				return nil, fmt.Sprintf("Use %d characters or fewer.", *definition.Max)
			}
		}
		if definition.Name == "SmtpHost" && text != "" && !validSMTPHost(text) {
			return nil, "Enter a hostname only, such as smtp.example.com; do not include smtp:// or a port."
		}
		if definition.Type == "time" && text != "" {
			if _, err := time.Parse("15:04", text); err != nil || len(text) != 5 {
				return nil, "Use 24-hour HH:mm format, such as 09:30."
			}
		}
		if definition.Type == "select" && text != "" && !containsFold(definition.Options, text) {
			return nil, "Choose one of the available values."
		}
		if definition.Name == "TautulliUrl" {
			text = strings.TrimRight(text, "/")
		}
		return text, ""
	}
}

func normalizeCustomTextCardTitleGif(value any) string {
	text, ok := value.(string)
	if !ok {
		return "none"
	}
	text = strings.ToLower(strings.TrimSpace(text))
	for _, allowed := range []string{"celebrate", "construction", "rocket", "tickets", "warning", "alert"} {
		if text == allowed {
			return allowed
		}
	}
	return "none"
}

func validateConfigRelationships(values map[string]any, fieldErrors map[string]string) {
	customTextCardEnabled, _ := values["CustomTextCardEnabled"].(bool)
	if customTextCardEnabled && strings.TrimSpace(fmt.Sprint(values["CustomTextCardBody"])) == "" {
		fieldErrors["CustomTextCardBody"] = "Card body text is required when the custom text card is enabled."
	}
	if !secretConfigured(values, "ApiKey") {
		fieldErrors["ApiKey"] = "A Tautulli API key is required."
	}
	authentication, _ := values["SmtpUseAuthentication"].(bool)
	if authentication {
		if strings.TrimSpace(fmt.Sprint(values["SmtpUsername"])) == "" {
			fieldErrors["SmtpUsername"] = "SMTP username is required when authentication is enabled."
		}
		if !secretConfigured(values, "SmtpPassword") {
			fieldErrors["SmtpPassword"] = "SMTP password is required when authentication is enabled."
		}
	}
	if strings.EqualFold(strings.TrimSpace(fmt.Sprint(values["SmtpHost"])), "smtp.example.com") {
		fieldErrors["SmtpHost"] = "Replace the example SMTP host before saving."
	}
	for _, name := range []string{"FromEmail", "ReplyToEmail", "TestEmail"} {
		value := strings.ToLower(strings.TrimSpace(fmt.Sprint(values[name])))
		if strings.HasSuffix(value, "@example.com") {
			fieldErrors[name] = "Replace the example email address before saving."
		}
	}
}

func existingConfigIssues(values map[string]any) map[string]string {
	issues := make(map[string]string)
	normalized := cloneConfigMap(values)
	for _, definition := range configDefinitions() {
		if definition.Type == "secret" || managerPreservesConfigValue(definition.Name) {
			continue
		}
		value, exists := values[definition.Name]
		if !exists {
			value = definition.Default
		}
		raw, err := json.Marshal(editorValue(value, definition))
		if err != nil {
			issues[definition.Name] = "The stored value cannot be represented safely."
			continue
		}
		parsed, message := parseAndValidateConfigValue(raw, definition)
		if message != "" {
			issues[definition.Name] = message
			continue
		}
		normalized[definition.Name] = parsed
	}
	validateConfigRelationships(normalized, issues)
	return issues
}

func validEmail(value string) bool {
	address, err := mail.ParseAddress(value)
	return err == nil && address.Address == value
}

func hasDuplicateUserEmailOverrideKeys(raw json.RawMessage) bool {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	opening, err := decoder.Token()
	if err != nil || opening != json.Delim('{') {
		return false
	}
	seen := make(map[string]struct{})
	for decoder.More() {
		key, err := decoder.Token()
		if err != nil {
			return false
		}
		normalized := strings.TrimSpace(fmt.Sprint(key))
		if _, duplicate := seen[normalized]; duplicate {
			return true
		}
		seen[normalized] = struct{}{}
		var ignored json.RawMessage
		if decoder.Decode(&ignored) != nil {
			return false
		}
	}
	return false
}

func validHTTPURL(value string) bool {
	parsed, err := url.Parse(value)
	return err == nil && (parsed.Scheme == "http" || parsed.Scheme == "https") && parsed.Host != ""
}

func validHexColor(value string) bool {
	if len(value) != 7 || value[0] != '#' {
		return false
	}
	_, err := strconv.ParseUint(value[1:], 16, 24)
	return err == nil
}

func containsFold(values []string, candidate string) bool {
	for _, value := range values {
		if strings.EqualFold(value, candidate) {
			return true
		}
	}
	return false
}

func cloneConfigMap(source map[string]any) map[string]any {
	result := make(map[string]any, len(source))
	for key, value := range source {
		result[key] = value
	}
	return result
}

func writeConfigAtomically(root string, previous []byte, existed bool, content []byte, now time.Time) (string, error) {
	if err := os.MkdirAll(root, 0o700); err != nil {
		return "", fmt.Errorf("create configuration directory: %w", err)
	}
	backup := ""
	if existed {
		backup = "config.backup." + now.UTC().Format("20060102-150405.000000000Z") + ".json"
		if err := writePrivateFile(filepath.Join(root, backup), previous, os.O_CREATE|os.O_EXCL); err != nil {
			return "", fmt.Errorf("create configuration backup: %w", err)
		}
		if err := normalizeConfigBackups(root); err != nil {
			return "", fmt.Errorf("apply configuration backup retention: %w", err)
		}
	}

	temporary, err := os.CreateTemp(root, ".config-*.tmp")
	if err != nil {
		return "", fmt.Errorf("create temporary configuration: %w", err)
	}
	temporaryPath := temporary.Name()
	keep := false
	defer func() {
		_ = temporary.Close()
		if !keep {
			_ = os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(0o600); err != nil {
		return "", fmt.Errorf("protect temporary configuration: %w", err)
	}
	if _, err := temporary.Write(content); err != nil {
		return "", fmt.Errorf("write temporary configuration: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		return "", fmt.Errorf("flush temporary configuration: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return "", fmt.Errorf("close temporary configuration: %w", err)
	}
	if err := hardenPrivateFile(temporaryPath); err != nil {
		return "", fmt.Errorf("restrict configuration permissions: %w", err)
	}
	if err := os.Rename(temporaryPath, filepath.Join(root, "config.json")); err != nil {
		return "", fmt.Errorf("replace configuration atomically: %w", err)
	}
	keep = true
	return backup, nil
}

func writePrivateFile(path string, content []byte, flags int) error {
	file, err := os.OpenFile(path, flags|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err := file.Write(content); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return hardenPrivateFile(path)
}

func sortedConfigErrorNames(fieldErrors map[string]string) []string {
	names := make([]string, 0, len(fieldErrors))
	for name := range fieldErrors {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

func configInteger(values map[string]any, name string) int64 {
	switch value := values[name].(type) {
	case int64:
		return value
	case json.Number:
		parsed, _ := value.Int64()
		return parsed
	case float64:
		return int64(value)
	case string:
		parsed, _ := strconv.ParseInt(value, 10, 64)
		return parsed
	default:
		return 0
	}
}
