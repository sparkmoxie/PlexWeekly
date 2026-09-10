package manager

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const maximumRendererResultBytes = 64 << 10

var errRendererResultInvalid = errors.New("renderer result is invalid")

type rendererResult struct {
	SchemaVersion         int                       `json:"schemaVersion"`
	Mode                  string                    `json:"mode"`
	Outcome               string                    `json:"outcome"`
	ErrorCategory         string                    `json:"errorCategory,omitempty"`
	DeliveryScope         string                    `json:"deliveryScope"`
	StartedAtUTC          string                    `json:"startedAtUtc"`
	FinishedAtUTC         string                    `json:"finishedAtUtc"`
	DurationMS            int64                     `json:"durationMs"`
	SMTPAcceptedCount     int                       `json:"smtpAcceptedCount"`
	SkippedCount          int                       `json:"skippedCount"`
	FailedCount           int                       `json:"failedCount"`
	SMTPFailure           *SMTPFailureEvidence      `json:"smtpFailure"`
	SkipReasonCounts      *DeliverySkipReasonCounts `json:"skipReasonCounts,omitempty"`
	GeneratedPreviewFiles []string                  `json:"generatedPreviewFiles"`
}

type SMTPFailureEvidence struct {
	Category      string `json:"category"`
	Stage         string `json:"stage"`
	ResponseCode  int    `json:"responseCode"`
	ResponseClass int    `json:"responseClass"`
	BatchFatal    bool   `json:"batchFatal"`
	Acceptance    string `json:"acceptance"`
}

type DeliverySkipReasonCounts struct {
	InactiveOrDeleted int `json:"inactiveOrDeleted"`
	MissingEmail      int `json:"missingEmail"`
	ExcludedUserID    int `json:"excludedUserId"`
	ExcludedEmail     int `json:"excludedEmail"`
}

func readRendererResult(path, expectedMode string) (rendererResult, error) {
	var result rendererResult
	file, err := os.Open(path)
	if err != nil {
		return result, errRendererResultInvalid
	}
	defer file.Close()
	raw, err := io.ReadAll(io.LimitReader(file, maximumRendererResultBytes+1))
	if err != nil || len(raw) > maximumRendererResultBytes {
		return result, errRendererResultInvalid
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&result) != nil || decoder.Decode(&struct{}{}) != io.EOF {
		return rendererResult{}, errRendererResultInvalid
	}
	if !validRendererResult(result, expectedMode) {
		return rendererResult{}, errRendererResultInvalid
	}
	return result, nil
}

func validRendererResult(result rendererResult, expectedMode string) bool {
	if (result.SchemaVersion != 1 && result.SchemaVersion != 2 && result.SchemaVersion != 3) || result.Mode != expectedMode || expectedDeliveryScope(result.Mode) == "" {
		return false
	}
	if result.Outcome != "succeeded" && result.Outcome != "partial" && result.Outcome != "failed" {
		return false
	}
	if result.ErrorCategory != "" {
		if (result.Outcome != "failed" && !(result.Mode == "SendAll" && result.Outcome == "partial")) || !validRendererErrorCategory(result.ErrorCategory) {
			return false
		}
		if (result.ErrorCategory == "no-eligible-recipients" || result.ErrorCategory == "user-roster-refresh-failed") && result.Mode != "SendAll" {
			return false
		}
		if structuredSMTPFailureCategory(result.ErrorCategory) && !smtpDeliveryMode(result.Mode) {
			return false
		}
	}
	if result.SchemaVersion < 3 {
		if result.SMTPFailure != nil {
			return false
		}
	} else if result.SMTPFailure != nil {
		if !smtpDeliveryMode(result.Mode) || (result.Outcome != "failed" && !(result.Mode == "SendAll" && result.Outcome == "partial")) || result.ErrorCategory != result.SMTPFailure.Category || !validSMTPFailureEvidence(*result.SMTPFailure) {
			return false
		}
	} else if structuredSMTPFailureCategory(result.ErrorCategory) {
		return false
	}
	if result.DeliveryScope != expectedDeliveryScope(result.Mode) {
		return false
	}
	started, startErr := time.Parse(time.RFC3339Nano, result.StartedAtUTC)
	finished, finishErr := time.Parse(time.RFC3339Nano, result.FinishedAtUTC)
	if startErr != nil || finishErr != nil || finished.Before(started) || result.DurationMS < 0 || result.DurationMS > int64((24*time.Hour)/time.Millisecond) {
		return false
	}
	for _, count := range []int{result.SMTPAcceptedCount, result.SkippedCount, result.FailedCount} {
		if count < 0 || count > 1_000_000 {
			return false
		}
	}
	if result.SchemaVersion == 1 {
		if result.SkipReasonCounts != nil {
			return false
		}
	} else {
		if result.SkipReasonCounts == nil || !validDeliverySkipReasonCounts(*result.SkipReasonCounts) {
			return false
		}
		if result.Mode == "SendAll" {
			if result.SkipReasonCounts.total() != result.SkippedCount {
				return false
			}
		} else if result.SkipReasonCounts.total() != 0 {
			return false
		}
	}
	if len(result.GeneratedPreviewFiles) > 20 {
		return false
	}
	seen := make(map[string]struct{}, len(result.GeneratedPreviewFiles))
	for _, name := range result.GeneratedPreviewFiles {
		if name == "" || filepath.Base(name) != name || !strings.EqualFold(filepath.Ext(name), ".html") || !strings.HasPrefix(strings.ToLower(name), "preview") {
			return false
		}
		key := strings.ToLower(name)
		if _, duplicate := seen[key]; duplicate {
			return false
		}
		seen[key] = struct{}{}
	}
	switch result.Mode {
	case "CacheWarm":
		if len(seen) != 0 || result.SMTPAcceptedCount != 0 || result.SkippedCount != 0 || result.FailedCount != 0 || result.Outcome == "partial" {
			return false
		}
	case "PreviewAll":
		if result.SMTPAcceptedCount != 0 || result.SkippedCount != 0 || result.FailedCount != 0 {
			return false
		}
		if result.Outcome == "succeeded" && !previewAllResultFilesValid(seen) {
			return false
		}
	case "Preview":
		if result.SMTPAcceptedCount != 0 || result.SkippedCount != 0 || result.FailedCount != 0 || (result.Outcome == "succeeded" && len(seen) != 1) {
			return false
		}
	case "SendTest":
		if len(seen) != 0 || result.SkippedCount != 0 || (result.Outcome == "succeeded" && (result.SMTPAcceptedCount != 1 || result.FailedCount != 0)) || (result.SMTPFailure != nil && (result.SMTPAcceptedCount != 0 || result.FailedCount != 1)) {
			return false
		}
	case "SendTestAll":
		if len(seen) != 0 || result.SkippedCount != 0 || (result.Outcome == "succeeded" && (result.SMTPAcceptedCount != 6 || result.FailedCount != 0)) || (result.SMTPFailure != nil && (result.SMTPAcceptedCount >= 6 || result.FailedCount != 1)) {
			return false
		}
	case "SendWelcome":
		if len(seen) != 0 || result.SkippedCount != 0 || (result.Outcome == "succeeded" && (result.SMTPAcceptedCount != 1 || result.FailedCount != 0)) || (result.SMTPFailure != nil && (result.SMTPAcceptedCount != 0 || result.FailedCount != 1)) {
			return false
		}
	case "SendAll":
		if len(seen) != 0 || (result.Outcome == "succeeded" && (result.FailedCount != 0 || (result.SchemaVersion >= 2 && result.SMTPAcceptedCount == 0))) || (result.Outcome == "partial" && (result.SMTPAcceptedCount == 0 || result.FailedCount == 0)) {
			return false
		}
		if result.ErrorCategory == "no-eligible-recipients" && (result.Outcome != "failed" || result.SMTPAcceptedCount != 0 || result.FailedCount != 0) {
			return false
		}
		if result.ErrorCategory == "user-roster-refresh-failed" && (result.Outcome != "failed" || result.SMTPAcceptedCount != 0 || result.SkippedCount != 0 || result.FailedCount != 0) {
			return false
		}
	case "ListUsers", "VerifyPlex":
		if len(seen) != 0 || result.SMTPAcceptedCount != 0 || result.SkippedCount != 0 || result.FailedCount != 0 || result.Outcome == "partial" {
			return false
		}
	}
	return true
}

func validRendererErrorCategory(category string) bool {
	switch category {
	case "operation-busy",
		"configuration-invalid",
		"tautulli-unavailable",
		"plex-unavailable",
		"asset-unavailable",
		"render-failed",
		"output-failed",
		"smtp-failed",
		"smtp-auth-failed",
		"smtp-rate-limited",
		"smtp-recipient-rejected",
		"smtp-provider-rejected",
		"smtp-transport-failed",
		"smtp-acceptance-unknown",
		"user-roster-refresh-failed",
		"user-excluded",
		"no-eligible-recipients",
		"renderer-failed":
		return true
	default:
		return false
	}
}

func structuredSMTPFailureCategory(category string) bool {
	switch category {
	case "smtp-auth-failed", "smtp-rate-limited", "smtp-recipient-rejected", "smtp-provider-rejected", "smtp-transport-failed", "smtp-acceptance-unknown":
		return true
	default:
		return false
	}
}

func smtpDeliveryMode(mode string) bool {
	switch mode {
	case "SendTest", "SendTestAll", "SendWelcome", "SendAll":
		return true
	default:
		return false
	}
}

func validSMTPFailureEvidence(evidence SMTPFailureEvidence) bool {
	if !structuredSMTPFailureCategory(evidence.Category) {
		return false
	}
	validStage := false
	for _, stage := range []string{"configuration", "mime", "connect", "greeting", "ehlo", "starttls", "tls", "auth", "mail-from", "rcpt-to", "data-command", "data-acceptance"} {
		if evidence.Stage == stage {
			validStage = true
			break
		}
	}
	if !validStage || (evidence.Acceptance != "not-attempted" && evidence.Acceptance != "rejected" && evidence.Acceptance != "unknown") {
		return false
	}
	if evidence.ResponseCode == 0 {
		if evidence.ResponseClass != 0 {
			return false
		}
	} else if evidence.ResponseCode < 200 || evidence.ResponseCode > 599 || evidence.ResponseClass != evidence.ResponseCode/100 {
		return false
	}
	switch evidence.Category {
	case "smtp-auth-failed":
		return evidence.BatchFatal && evidence.Stage == "auth" && evidence.Acceptance == "not-attempted"
	case "smtp-rate-limited":
		return evidence.BatchFatal && evidence.ResponseClass == 4
	case "smtp-recipient-rejected":
		return !evidence.BatchFatal && evidence.Stage == "rcpt-to" && evidence.ResponseClass == 5 && evidence.Acceptance == "not-attempted"
	case "smtp-provider-rejected":
		return evidence.BatchFatal && evidence.ResponseCode > 0 && evidence.ResponseClass != 4
	case "smtp-transport-failed":
		return evidence.BatchFatal && evidence.ResponseCode == 0 && evidence.Acceptance == "not-attempted"
	case "smtp-acceptance-unknown":
		return evidence.BatchFatal && evidence.Stage == "data-acceptance" && evidence.ResponseCode == 0 && evidence.Acceptance == "unknown"
	default:
		return false
	}
}

func validDeliverySkipReasonCounts(counts DeliverySkipReasonCounts) bool {
	for _, count := range []int{counts.InactiveOrDeleted, counts.MissingEmail, counts.ExcludedUserID, counts.ExcludedEmail} {
		if count < 0 || count > 1_000_000 {
			return false
		}
	}
	return true
}

func (counts DeliverySkipReasonCounts) total() int {
	return counts.InactiveOrDeleted + counts.MissingEmail + counts.ExcludedUserID + counts.ExcludedEmail
}

func expectedDeliveryScope(mode string) string {
	switch mode {
	case "SendTest", "SendTestAll":
		return "test"
	case "SendWelcome":
		return "welcome"
	case "SendAll":
		return "production"
	case "Preview", "PreviewAll", "CacheWarm", "ListUsers", "VerifyPlex":
		return "none"
	default:
		return ""
	}
}

func previewAllResultFilesValid(files map[string]struct{}) bool {
	expected := []string{
		"preview-all-00-index.html",
		"preview-all-01-manual-welcome.html",
		"preview-all-02-new-user-no-history.html",
		"preview-all-03-new-user-with-history.html",
		"preview-all-04-normal-newsletter.html",
		"preview-all-05-established-quiet.html",
		"preview-all-06-established-warmup.html",
	}
	if len(files) != len(expected) {
		return false
	}
	for _, name := range expected {
		if _, exists := files[name]; !exists {
			return false
		}
	}
	return true
}
