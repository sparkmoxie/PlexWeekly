package manager

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestRendererResultAcceptsSanitizedPreviewAllContract(t *testing.T) {
	path := filepath.Join(t.TempDir(), "result.json")
	result := validPreviewAllRendererResult()
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, encoded, 0o600); err != nil {
		t.Fatal(err)
	}
	decoded, err := readRendererResult(path, "PreviewAll")
	if err != nil {
		t.Fatal(err)
	}
	if decoded.Outcome != "succeeded" || decoded.DeliveryScope != "none" || decoded.DurationMS != 1250 || len(decoded.GeneratedPreviewFiles) != 7 {
		t.Fatalf("unexpected structured result: %+v", decoded)
	}
}

func TestRendererResultRejectsUnknownPrivateAndInconsistentFields(t *testing.T) {
	valid := validPreviewAllRendererResult()
	cases := []struct {
		name   string
		mutate func(*rendererResult)
	}{
		{name: "wrong mode", mutate: func(result *rendererResult) { result.Mode = "SendAll" }},
		{name: "delivery scope", mutate: func(result *rendererResult) { result.DeliveryScope = "production" }},
		{name: "smtp count", mutate: func(result *rendererResult) { result.SMTPAcceptedCount = 1 }},
		{name: "path traversal", mutate: func(result *rendererResult) { result.GeneratedPreviewFiles[0] = `..\private.html` }},
		{name: "missing preview", mutate: func(result *rendererResult) { result.GeneratedPreviewFiles = result.GeneratedPreviewFiles[:6] }},
		{name: "negative count", mutate: func(result *rendererResult) { result.FailedCount = -1 }},
		{name: "time reversal", mutate: func(result *rendererResult) { result.FinishedAtUTC = "2031-04-18T16:29:59Z" }},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			result := valid
			result.GeneratedPreviewFiles = append([]string{}, valid.GeneratedPreviewFiles...)
			test.mutate(&result)
			if validRendererResult(result, "PreviewAll") {
				t.Fatalf("invalid structured result was accepted: %+v", result)
			}
		})
	}

	path := filepath.Join(t.TempDir(), "unknown.json")
	raw := `{"schemaVersion":1,"mode":"PreviewAll","outcome":"failed","deliveryScope":"none","startedAtUtc":"2031-04-18T16:30:00Z","finishedAtUtc":"2031-04-18T16:30:01Z","durationMs":1000,"smtpAcceptedCount":0,"skippedCount":0,"failedCount":0,"generatedPreviewFiles":[],"recipientEmail":"private@example.org"}`
	if err := os.WriteFile(path, []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readRendererResult(path, "PreviewAll"); err == nil {
		t.Fatal("structured result with an unknown recipient field was accepted")
	}
}

func TestRendererResultValidatesSendTestAllAggregateContract(t *testing.T) {
	started := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	valid := rendererResult{
		SchemaVersion:     1,
		Mode:              "SendTestAll",
		Outcome:           "succeeded",
		DeliveryScope:     "test",
		StartedAtUTC:      started.Format(time.RFC3339Nano),
		FinishedAtUTC:     started.Add(2 * time.Second).Format(time.RFC3339Nano),
		DurationMS:        2000,
		SMTPAcceptedCount: 6,
	}
	if !validRendererResult(valid, "SendTestAll") {
		t.Fatalf("valid SendTestAll result was rejected: %+v", valid)
	}

	cases := []struct {
		name   string
		mutate func(*rendererResult)
	}{
		{name: "wrong accepted count", mutate: func(result *rendererResult) { result.SMTPAcceptedCount = 5 }},
		{name: "recipient preview", mutate: func(result *rendererResult) { result.GeneratedPreviewFiles = []string{"preview-private.html"} }},
		{name: "wrong delivery scope", mutate: func(result *rendererResult) { result.DeliveryScope = "production" }},
		{name: "unexpected skip", mutate: func(result *rendererResult) { result.SkippedCount = 1 }},
		{name: "reported failure", mutate: func(result *rendererResult) { result.FailedCount = 1 }},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			result := valid
			test.mutate(&result)
			if validRendererResult(result, "SendTestAll") {
				t.Fatalf("invalid SendTestAll result was accepted: %+v", result)
			}
		})
	}
}

func TestRendererResultV2ValidatesProductionEligibilityEvidence(t *testing.T) {
	started := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	valid := rendererResult{
		SchemaVersion:     2,
		Mode:              "SendAll",
		Outcome:           "succeeded",
		DeliveryScope:     "production",
		StartedAtUTC:      started.Format(time.RFC3339Nano),
		FinishedAtUTC:     started.Add(time.Second).Format(time.RFC3339Nano),
		DurationMS:        1000,
		SMTPAcceptedCount: 2,
		SkippedCount:      4,
		SkipReasonCounts: &DeliverySkipReasonCounts{
			InactiveOrDeleted: 1,
			MissingEmail:      1,
			ExcludedUserID:    1,
			ExcludedEmail:     1,
		},
	}
	if !validRendererResult(valid, "SendAll") {
		t.Fatalf("valid schema-v2 SendAll result was rejected: %+v", valid)
	}

	cases := []struct {
		name   string
		mutate func(*rendererResult)
	}{
		{name: "missing fixed reason counts", mutate: func(result *rendererResult) { result.SkipReasonCounts = nil }},
		{name: "reason sum mismatch", mutate: func(result *rendererResult) { result.SkipReasonCounts.ExcludedEmail = 0 }},
		{name: "negative reason", mutate: func(result *rendererResult) { result.SkipReasonCounts.MissingEmail = -1 }},
		{name: "successful zero acceptance", mutate: func(result *rendererResult) { result.SMTPAcceptedCount = 0 }},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			result := valid
			counts := *valid.SkipReasonCounts
			result.SkipReasonCounts = &counts
			test.mutate(&result)
			if validRendererResult(result, "SendAll") {
				t.Fatalf("invalid schema-v2 result was accepted: %+v", result)
			}
		})
	}

	noEligible := valid
	noEligible.Outcome = "failed"
	noEligible.ErrorCategory = "no-eligible-recipients"
	noEligible.SMTPAcceptedCount = 0
	if !validRendererResult(noEligible, "SendAll") {
		t.Fatalf("valid no-eligible-recipient result was rejected: %+v", noEligible)
	}
	noEligible.FailedCount = 1
	if validRendererResult(noEligible, "SendAll") {
		t.Fatalf("no-eligible-recipient result with an SMTP failure was accepted: %+v", noEligible)
	}
	wrongMode := validPreviewAllRendererResult()
	wrongMode.Outcome = "failed"
	wrongMode.GeneratedPreviewFiles = nil
	wrongMode.ErrorCategory = "no-eligible-recipients"
	if validRendererResult(wrongMode, "PreviewAll") {
		t.Fatalf("recipient-only error category was accepted for PreviewAll: %+v", wrongMode)
	}

	rosterFailure := valid
	rosterFailure.Outcome = "failed"
	rosterFailure.ErrorCategory = "user-roster-refresh-failed"
	rosterFailure.SMTPAcceptedCount = 0
	rosterFailure.SkippedCount = 0
	rosterFailure.SkipReasonCounts = &DeliverySkipReasonCounts{}
	if !validRendererResult(rosterFailure, "SendAll") {
		t.Fatalf("valid fail-closed roster-refresh result was rejected: %+v", rosterFailure)
	}
	rosterFailure.SkippedCount = 1
	if validRendererResult(rosterFailure, "SendAll") {
		t.Fatalf("roster-refresh failure with delivery classification was accepted: %+v", rosterFailure)
	}
	wrongMode.ErrorCategory = "user-roster-refresh-failed"
	if validRendererResult(wrongMode, "PreviewAll") {
		t.Fatalf("SendAll-only roster-refresh category was accepted for PreviewAll: %+v", wrongMode)
	}
}

func TestRendererResultV3ValidatesSanitizedSMTPFailureEvidence(t *testing.T) {
	started := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	valid := rendererResult{
		SchemaVersion:    3,
		Mode:             "SendAll",
		Outcome:          "failed",
		ErrorCategory:    "smtp-rate-limited",
		DeliveryScope:    "production",
		StartedAtUTC:     started.Format(time.RFC3339Nano),
		FinishedAtUTC:    started.Add(time.Second).Format(time.RFC3339Nano),
		DurationMS:       1000,
		FailedCount:      1,
		SkipReasonCounts: &DeliverySkipReasonCounts{},
		SMTPFailure:      &SMTPFailureEvidence{Category: "smtp-rate-limited", Stage: "greeting", ResponseCode: 421, ResponseClass: 4, BatchFatal: true, Acceptance: "not-attempted"},
	}
	if !validRendererResult(valid, "SendAll") {
		t.Fatalf("valid schema-v3 SMTP failure was rejected: %+v", valid)
	}

	partial := valid
	partial.Outcome = "partial"
	partial.ErrorCategory = "smtp-recipient-rejected"
	partial.SMTPAcceptedCount = 2
	partial.SMTPFailure = &SMTPFailureEvidence{Category: "smtp-recipient-rejected", Stage: "rcpt-to", ResponseCode: 550, ResponseClass: 5, BatchFatal: false, Acceptance: "not-attempted"}
	if !validRendererResult(partial, "SendAll") {
		t.Fatalf("valid schema-v3 recipient-specific partial result was rejected: %+v", partial)
	}

	ambiguous := valid
	ambiguous.ErrorCategory = "smtp-acceptance-unknown"
	ambiguous.SMTPFailure = &SMTPFailureEvidence{Category: "smtp-acceptance-unknown", Stage: "data-acceptance", ResponseCode: 0, ResponseClass: 0, BatchFatal: true, Acceptance: "unknown"}
	if !validRendererResult(ambiguous, "SendAll") {
		t.Fatalf("valid ambiguous-acceptance evidence was rejected: %+v", ambiguous)
	}

	for _, delivery := range []struct {
		mode          string
		deliveryScope string
		accepted      int
	}{
		{mode: "SendTest", deliveryScope: "test", accepted: 0},
		{mode: "SendTestAll", deliveryScope: "test", accepted: 2},
		{mode: "SendWelcome", deliveryScope: "welcome", accepted: 0},
	} {
		result := valid
		result.Mode = delivery.mode
		result.DeliveryScope = delivery.deliveryScope
		result.SMTPAcceptedCount = delivery.accepted
		result.SkippedCount = 0
		result.SkipReasonCounts = &DeliverySkipReasonCounts{}
		if !validRendererResult(result, delivery.mode) {
			t.Fatalf("valid %s SMTP failure evidence was rejected: %+v", delivery.mode, result)
		}
	}

	invalidTestAll := valid
	invalidTestAll.Mode = "SendTestAll"
	invalidTestAll.DeliveryScope = "test"
	invalidTestAll.SMTPAcceptedCount = 6
	invalidTestAll.SkippedCount = 0
	invalidTestAll.SkipReasonCounts = &DeliverySkipReasonCounts{}
	if validRendererResult(invalidTestAll, "SendTestAll") {
		t.Fatalf("SendTestAll accepted SMTP failure evidence after all six messages: %+v", invalidTestAll)
	}

	cases := []struct {
		name   string
		mutate func(*rendererResult)
	}{
		{name: "missing evidence", mutate: func(result *rendererResult) { result.SMTPFailure = nil }},
		{name: "category mismatch", mutate: func(result *rendererResult) { result.SMTPFailure.Category = "smtp-auth-failed" }},
		{name: "response class mismatch", mutate: func(result *rendererResult) { result.SMTPFailure.ResponseClass = 5 }},
		{name: "unsafe stage", mutate: func(result *rendererResult) { result.SMTPFailure.Stage = "private-host.example" }},
		{name: "rate limit allowed to continue", mutate: func(result *rendererResult) { result.SMTPFailure.BatchFatal = false }},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			result := valid
			evidence := *valid.SMTPFailure
			result.SMTPFailure = &evidence
			test.mutate(&result)
			if validRendererResult(result, "SendAll") {
				t.Fatalf("invalid schema-v3 SMTP evidence was accepted: %+v", result)
			}
		})
	}

	wrongMode := validPreviewAllRendererResult()
	wrongMode.SchemaVersion = 3
	wrongMode.Outcome = "failed"
	wrongMode.ErrorCategory = "smtp-rate-limited"
	wrongMode.GeneratedPreviewFiles = nil
	wrongMode.SkipReasonCounts = &DeliverySkipReasonCounts{}
	wrongMode.SMTPFailure = valid.SMTPFailure
	if validRendererResult(wrongMode, "PreviewAll") {
		t.Fatalf("production SMTP evidence was accepted for PreviewAll: %+v", wrongMode)
	}
}

func TestRendererResultAcceptsOnlyAllowlistedFailureCategories(t *testing.T) {
	failed := validPreviewAllRendererResult()
	failed.Outcome = "failed"
	failed.GeneratedPreviewFiles = nil
	failed.ErrorCategory = "tautulli-unavailable"
	if !validRendererResult(failed, "PreviewAll") {
		t.Fatalf("allowlisted renderer failure category was rejected: %+v", failed)
	}

	unknown := failed
	unknown.ErrorCategory = "private-hostname-or-raw-error"
	if validRendererResult(unknown, "PreviewAll") {
		t.Fatalf("unknown renderer failure category was accepted: %+v", unknown)
	}

	succeeded := validPreviewAllRendererResult()
	succeeded.ErrorCategory = "render-failed"
	if validRendererResult(succeeded, "PreviewAll") {
		t.Fatalf("successful renderer result retained a failure category: %+v", succeeded)
	}

	legacy := failed
	legacy.ErrorCategory = ""
	if !validRendererResult(legacy, "PreviewAll") {
		t.Fatalf("legacy category-free failure was rejected: %+v", legacy)
	}

	for _, mode := range []struct {
		name          string
		deliveryScope string
	}{
		{name: "Preview", deliveryScope: "none"},
		{name: "PreviewAll", deliveryScope: "none"},
		{name: "SendTest", deliveryScope: "test"},
		{name: "SendTestAll", deliveryScope: "test"},
		{name: "SendWelcome", deliveryScope: "welcome"},
	} {
		result := failed
		result.Mode = mode.name
		result.DeliveryScope = mode.deliveryScope
		result.ErrorCategory = "user-excluded"
		if !validRendererResult(result, mode.name) {
			t.Fatalf("valid %s user-excluded result was rejected: %+v", mode.name, result)
		}
	}
}

func validPreviewAllRendererResult() rendererResult {
	started := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	return rendererResult{
		SchemaVersion: 1,
		Mode:          "PreviewAll",
		Outcome:       "succeeded",
		DeliveryScope: "none",
		StartedAtUTC:  started.Format(time.RFC3339Nano),
		FinishedAtUTC: started.Add(1250 * time.Millisecond).Format(time.RFC3339Nano),
		DurationMS:    1250,
		GeneratedPreviewFiles: []string{
			"preview-all-00-INDEX.html",
			"preview-all-01-manual-welcome.html",
			"preview-all-02-new-user-no-history.html",
			"preview-all-03-new-user-with-history.html",
			"preview-all-04-normal-newsletter.html",
			"preview-all-05-established-quiet.html",
			"preview-all-06-established-warmup.html",
		},
	}
}
