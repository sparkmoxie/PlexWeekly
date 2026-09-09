package manager

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

var secretConfigKeys = map[string]struct{}{
	"apikey":          {},
	"plextoken":       {},
	"smtppassword":    {},
	"smtpapppassword": {},
}

var privateConfigKeys = map[string]struct{}{
	"useremailoverrides": {},
}

type SecretStatus struct {
	Configured           bool `json:"configured"`
	AvailableFromRuntime bool `json:"availableFromRuntime,omitempty"`
}

type ConfigField struct {
	Name   string        `json:"name"`
	Type   string        `json:"type"`
	Value  any           `json:"value,omitempty"`
	Secret *SecretStatus `json:"secret,omitempty"`
}

type ConfigView struct {
	Exists bool          `json:"exists"`
	Valid  bool          `json:"valid"`
	State  string        `json:"state"`
	Fields []ConfigField `json:"fields"`
}

func ReadRedactedConfig(root string) ConfigView {
	path := filepath.Join(root, "config.json")
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return ConfigView{Exists: false, Valid: false, State: "unconfigured", Fields: []ConfigField{}}
	}
	if err != nil {
		return ConfigView{Exists: true, Valid: false, State: "unreadable", Fields: []ConfigField{}}
	}

	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	values := make(map[string]any)
	if err := decoder.Decode(&values); err != nil {
		return ConfigView{Exists: true, Valid: false, State: "invalid-json", Fields: []ConfigField{}}
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return ConfigView{Exists: true, Valid: false, State: "invalid-json", Fields: []ConfigField{}}
	}

	names := make([]string, 0, len(values))
	for name := range values {
		names = append(names, name)
	}
	sort.Strings(names)

	fields := make([]ConfigField, 0, len(names))
	for _, name := range names {
		value := values[name]
		if _, secret := secretConfigKeys[strings.ToLower(name)]; secret {
			fields = append(fields, ConfigField{
				Name:   name,
				Type:   "secret",
				Secret: &SecretStatus{Configured: configValueConfigured(value)},
			})
			continue
		}
		if _, private := privateConfigKeys[strings.ToLower(name)]; private {
			fields = append(fields, ConfigField{
				Name:   name,
				Type:   "secret",
				Secret: &SecretStatus{Configured: privateConfigValueConfigured(value)},
			})
			continue
		}
		fields = append(fields, ConfigField{
			Name:  name,
			Type:  jsonType(value),
			Value: value,
		})
	}

	return ConfigView{
		Exists: true,
		Valid:  true,
		State:  "ready",
		Fields: fields,
	}
}

func privateConfigValueConfigured(value any) bool {
	switch typed := value.(type) {
	case map[string]any:
		return len(typed) > 0
	case map[string]string:
		return len(typed) > 0
	default:
		return false
	}
}

func configValueConfigured(value any) bool {
	text, ok := value.(string)
	if !ok {
		return value != nil
	}
	text = strings.TrimSpace(text)
	return text != "" && !strings.HasPrefix(strings.ToUpper(text), "PASTE_")
}

func jsonType(value any) string {
	switch value.(type) {
	case nil:
		return "null"
	case bool:
		return "boolean"
	case json.Number:
		return "number"
	case string:
		return "string"
	case []any:
		return "array"
	case map[string]any:
		return "object"
	default:
		return fmt.Sprintf("%T", value)
	}
}

func configString(view ConfigView, name, fallback string) string {
	for _, field := range view.Fields {
		if strings.EqualFold(field.Name, name) {
			if value, ok := field.Value.(string); ok && strings.TrimSpace(value) != "" {
				return value
			}
		}
	}
	return fallback
}
