package manager

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

type fixturePreviewRunner struct {
	started              chan struct{}
	release              chan struct{}
	once                 sync.Once
	mu                   sync.Mutex
	userID               string
	runs                 int
	sendAllPartial       bool
	sendAllNoEligible    bool
	sendTestAllFailure   bool
	previewExitCode      int
	previewErrorCategory string
	cacheExitCode        int
	cacheErrorCategory   string
}

func (r *fixturePreviewRunner) RunPreviewAll(ctx context.Context, root, configPath, resultPath, userID string) (int, error) {
	if _, err := os.Stat(configPath); err != nil {
		return 11, err
	}
	r.mu.Lock()
	r.userID = userID
	r.runs++
	r.mu.Unlock()
	if r.started != nil {
		r.once.Do(func() { close(r.started) })
	}
	if r.release != nil {
		select {
		case <-r.release:
		case <-ctx.Done():
			return -1, context.Canceled
		}
	}
	if r.previewExitCode != 0 {
		if r.previewErrorCategory != "" {
			started := time.Now().UTC().Add(-time.Second)
			result := rendererResult{
				SchemaVersion: 1,
				Mode:          "PreviewAll",
				Outcome:       "failed",
				ErrorCategory: r.previewErrorCategory,
				DeliveryScope: "none",
				StartedAtUTC:  started.Format(time.RFC3339Nano),
				FinishedAtUTC: started.Add(time.Second).Format(time.RFC3339Nano),
				DurationMS:    1000,
			}
			encoded, err := json.Marshal(result)
			if err != nil {
				return 14, err
			}
			if err := os.WriteFile(resultPath, encoded, 0o600); err != nil {
				return 15, err
			}
		}
		return r.previewExitCode, errors.New("renderer returned a fixed failure status")
	}
	output := filepath.Join(root, "output")
	if err := os.MkdirAll(output, 0o700); err != nil {
		return 12, err
	}
	files := []string{
		"preview-all-00-INDEX.html",
		"preview-all-01-manual-welcome.html",
		"preview-all-02-new-user-no-history.html",
		"preview-all-03-new-user-with-history.html",
		"preview-all-04-normal-newsletter.html",
		"preview-all-05-established-quiet.html",
		"preview-all-06-established-warmup.html",
	}
	for _, name := range files {
		if err := os.WriteFile(filepath.Join(output, name), []byte("<!doctype html><title>Fictional preview</title>"), 0o600); err != nil {
			return 13, err
		}
	}
	started := time.Now().UTC().Add(-time.Second)
	result := rendererResult{
		SchemaVersion:         1,
		Mode:                  "PreviewAll",
		Outcome:               "succeeded",
		DeliveryScope:         "none",
		StartedAtUTC:          started.Format(time.RFC3339Nano),
		FinishedAtUTC:         started.Add(time.Second).Format(time.RFC3339Nano),
		DurationMS:            1000,
		GeneratedPreviewFiles: files,
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return 14, err
	}
	if err := os.WriteFile(resultPath, encoded, 0o600); err != nil {
		return 15, err
	}
	return 0, nil
}

func (r *fixturePreviewRunner) RunCacheWarm(ctx context.Context, _, configPath, resultPath string) (int, error) {
	if _, err := os.Stat(configPath); err != nil {
		return 21, err
	}
	r.mu.Lock()
	r.userID = ""
	r.runs++
	r.mu.Unlock()
	if r.started != nil {
		r.once.Do(func() { close(r.started) })
	}
	if r.release != nil {
		select {
		case <-r.release:
		case <-ctx.Done():
			return -1, context.Canceled
		}
	}
	started := time.Now().UTC().Add(-time.Second)
	if r.cacheExitCode != 0 {
		if r.cacheErrorCategory != "" {
			result := rendererResult{
				SchemaVersion: 1,
				Mode:          "CacheWarm",
				Outcome:       "failed",
				ErrorCategory: r.cacheErrorCategory,
				DeliveryScope: "none",
				StartedAtUTC:  started.Format(time.RFC3339Nano),
				FinishedAtUTC: started.Add(time.Second).Format(time.RFC3339Nano),
				DurationMS:    1000,
			}
			encoded, err := json.Marshal(result)
			if err != nil {
				return 22, err
			}
			if err := os.WriteFile(resultPath, encoded, 0o600); err != nil {
				return 23, err
			}
		}
		return r.cacheExitCode, errors.New("cache renderer returned a fixed failure status")
	}
	result := rendererResult{
		SchemaVersion: 1,
		Mode:          "CacheWarm",
		Outcome:       "succeeded",
		DeliveryScope: "none",
		StartedAtUTC:  started.Format(time.RFC3339Nano),
		FinishedAtUTC: started.Add(time.Second).Format(time.RFC3339Nano),
		DurationMS:    1000,
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return 22, err
	}
	if err := os.WriteFile(resultPath, encoded, 0o600); err != nil {
		return 23, err
	}
	return 0, nil
}

func (r *fixturePreviewRunner) RunSendTestAll(ctx context.Context, _, configPath, resultPath, userID string) (int, error) {
	if _, err := os.Stat(configPath); err != nil {
		return 31, err
	}
	r.mu.Lock()
	r.userID = userID
	r.runs++
	r.mu.Unlock()
	if r.started != nil {
		r.once.Do(func() { close(r.started) })
	}
	if r.release != nil {
		select {
		case <-r.release:
		case <-ctx.Done():
			return -1, context.Canceled
		}
	}
	started := time.Now().UTC().Add(-time.Second)
	schemaVersion := 1
	outcome := "succeeded"
	accepted := 6
	failed := 0
	exitCode := 0
	var runErr error
	var smtpFailure *SMTPFailureEvidence
	var skipReasons *DeliverySkipReasonCounts
	errorCategory := ""
	if r.sendTestAllFailure {
		schemaVersion = 3
		outcome = "failed"
		accepted = 0
		failed = 1
		exitCode = 1
		runErr = errors.New("renderer returned exit status 1")
		smtpFailure = &SMTPFailureEvidence{Category: "smtp-auth-failed", Stage: "auth", ResponseCode: 535, ResponseClass: 5, BatchFatal: true, Acceptance: "not-attempted"}
		skipReasons = &DeliverySkipReasonCounts{}
		errorCategory = smtpFailure.Category
	}
	result := rendererResult{
		SchemaVersion:         schemaVersion,
		Mode:                  "SendTestAll",
		Outcome:               outcome,
		ErrorCategory:         errorCategory,
		DeliveryScope:         "test",
		StartedAtUTC:          started.Format(time.RFC3339Nano),
		FinishedAtUTC:         started.Add(time.Second).Format(time.RFC3339Nano),
		DurationMS:            1000,
		SMTPAcceptedCount:     accepted,
		FailedCount:           failed,
		SMTPFailure:           smtpFailure,
		SkipReasonCounts:      skipReasons,
		GeneratedPreviewFiles: []string{},
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return 32, err
	}
	if err := os.WriteFile(resultPath, encoded, 0o600); err != nil {
		return 33, err
	}
	return exitCode, runErr
}

func (r *fixturePreviewRunner) RunSendWelcome(ctx context.Context, _, configPath, resultPath, userID string) (int, error) {
	if _, err := os.Stat(configPath); err != nil {
		return 36, err
	}
	r.mu.Lock()
	r.userID = userID
	r.runs++
	r.mu.Unlock()
	if r.started != nil {
		r.once.Do(func() { close(r.started) })
	}
	if r.release != nil {
		select {
		case <-r.release:
		case <-ctx.Done():
			return -1, context.Canceled
		}
	}
	started := time.Now().UTC().Add(-time.Second)
	result := rendererResult{
		SchemaVersion:         1,
		Mode:                  "SendWelcome",
		Outcome:               "succeeded",
		DeliveryScope:         "welcome",
		StartedAtUTC:          started.Format(time.RFC3339Nano),
		FinishedAtUTC:         started.Add(time.Second).Format(time.RFC3339Nano),
		DurationMS:            1000,
		SMTPAcceptedCount:     1,
		GeneratedPreviewFiles: []string{},
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return 37, err
	}
	if err := os.WriteFile(resultPath, encoded, 0o600); err != nil {
		return 38, err
	}
	return 0, nil
}

func (r *fixturePreviewRunner) RunSendAll(ctx context.Context, _, configPath, resultPath string) (int, error) {
	if _, err := os.Stat(configPath); err != nil {
		return 41, err
	}
	r.mu.Lock()
	r.runs++
	r.mu.Unlock()
	if r.started != nil {
		r.once.Do(func() { close(r.started) })
	}
	if r.release != nil {
		select {
		case <-r.release:
		case <-ctx.Done():
			return -1, context.Canceled
		}
	}
	started := time.Now().UTC().Add(-time.Second)
	outcome := "succeeded"
	accepted := 4
	skipped := 2
	failed := 0
	exitCode := 0
	var runErr error
	if r.sendAllPartial {
		outcome = "partial"
		accepted = 3
		skipped = 1
		failed = 1
		exitCode = 2
		runErr = errors.New("renderer returned exit status 2")
	}
	if r.sendAllNoEligible {
		outcome = "failed"
		accepted = 0
		skipped = 2
		failed = 0
		exitCode = 3
		runErr = errors.New("renderer returned exit status 3")
	}
	skipReasons := &DeliverySkipReasonCounts{InactiveOrDeleted: 1, ExcludedUserID: 1}
	if r.sendAllPartial {
		skipReasons = &DeliverySkipReasonCounts{MissingEmail: 1}
	}
	result := rendererResult{
		SchemaVersion:         2,
		Mode:                  "SendAll",
		Outcome:               outcome,
		DeliveryScope:         "production",
		StartedAtUTC:          started.Format(time.RFC3339Nano),
		FinishedAtUTC:         started.Add(time.Second).Format(time.RFC3339Nano),
		DurationMS:            1000,
		SMTPAcceptedCount:     accepted,
		SkippedCount:          skipped,
		FailedCount:           failed,
		SkipReasonCounts:      skipReasons,
		GeneratedPreviewFiles: []string{},
	}
	if r.sendAllNoEligible {
		result.ErrorCategory = "no-eligible-recipients"
	}
	if r.sendAllPartial {
		result.SchemaVersion = 3
		result.ErrorCategory = "smtp-recipient-rejected"
		result.SMTPFailure = &SMTPFailureEvidence{Category: "smtp-recipient-rejected", Stage: "rcpt-to", ResponseCode: 550, ResponseClass: 5, BatchFatal: false, Acceptance: "not-attempted"}
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return 42, err
	}
	if err := os.WriteFile(resultPath, encoded, 0o600); err != nil {
		return 43, err
	}
	return exitCode, runErr
}

func TestPreviewOperationCompletesWithSanitizedDurableHistory(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "operation-api-secret", "", "")
	if err := os.MkdirAll(filepath.Join(root, "output"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "output", "preview-all-99-existing.html"), []byte("<!doctype html><title>Existing preview</title>"), 0o600); err != nil {
		t.Fatal(err)
	}
	data := t.TempDir()
	runner := &fixturePreviewRunner{started: make(chan struct{})}
	completedRevision := make(chan string, 1)
	coordinator, err := newOperationCoordinator(Options{
		DataDir:         data,
		TautWeeklyRoot:  root,
		Now:             time.Now,
		operationRunner: runner,
		operationCompleted: func(_ OperationRecord, revision string) {
			completedRevision <- revision
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	const privateUserID = "9876543210123456789"
	view := ReadConfigEditor(root)
	started, err := coordinator.Start(CreateOperationRequest{
		Type:             "preview-all",
		ExpectedRevision: view.Revision,
		UserID:           privateUserID,
		ConfirmNoSend:    true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if started.Type != "preview-all" || started.State != "queued" || !started.Cancellable {
		t.Fatalf("unexpected start record: %+v", started)
	}
	finished := waitForOperationState(t, coordinator, "succeeded")
	if finished.Outcome != "success" || finished.ExitCode == nil || *finished.ExitCode != 0 || finished.DurationMS != 1000 || len(finished.GeneratedPreviewIDs) != 7 {
		t.Fatalf("unexpected completed record: %+v", finished)
	}
	select {
	case revision := <-completedRevision:
		if revision != view.Revision {
			t.Fatalf("completion revision: got %q, want %q", revision, view.Revision)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("operation completion callback was not invoked")
	}
	history := coordinator.History()
	if len(history.Operations) != 1 || history.Operations[0].ID != finished.ID {
		t.Fatalf("unexpected history: %+v", history)
	}
	for _, name := range []string{"operation-current.json", "operation-history.jsonl"} {
		raw, err := os.ReadFile(filepath.Join(data, name))
		if err != nil {
			t.Fatal(err)
		}
		for _, forbidden := range []string{privateUserID, "operation-api-secret", "127.0.0.1", view.Revision} {
			if strings.Contains(string(raw), forbidden) {
				t.Fatalf("%s retained private value %q", name, forbidden)
			}
		}
	}
	matches, err := filepath.Glob(filepath.Join(data, "operation-*.config.json"))
	if err != nil || len(matches) != 0 {
		t.Fatalf("operation configuration snapshot was not removed: %v, %v", matches, err)
	}
	resultMatches, err := filepath.Glob(filepath.Join(data, "operation-*.result.json"))
	if err != nil || len(resultMatches) != 0 {
		t.Fatalf("operation renderer result was not removed: %v, %v", resultMatches, err)
	}
}

func TestPreviewOperationCancellationAndBusyGuard(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	runner := &fixturePreviewRunner{started: make(chan struct{}), release: make(chan struct{})}
	coordinator, err := newOperationCoordinator(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Now: time.Now, operationRunner: runner})
	if err != nil {
		t.Fatal(err)
	}
	view := ReadConfigEditor(root)
	request := CreateOperationRequest{Type: "preview-all", ExpectedRevision: view.Revision, UserID: "42", ConfirmNoSend: true}
	started, err := coordinator.Start(request)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-runner.started:
	case <-time.After(3 * time.Second):
		t.Fatal("fixture operation did not start")
	}
	if _, err := coordinator.Start(request); !errors.Is(err, ErrOperationBusy) {
		t.Fatalf("second operation error: got %v", err)
	}
	cancelling, err := coordinator.Cancel(started.ID)
	if err != nil || cancelling.State != "cancelling" || cancelling.Cancellable {
		t.Fatalf("cancel operation: record=%+v err=%v", cancelling, err)
	}
	finished := waitForOperationState(t, coordinator, "cancelled")
	if finished.Outcome != "cancelled" || finished.ErrorCategory != "cancelled" {
		t.Fatalf("unexpected cancelled record: %+v", finished)
	}
	if _, err := coordinator.Cancel(started.ID); !errors.Is(err, ErrOperationTerminal) {
		t.Fatalf("terminal cancellation error: got %v", err)
	}
}

func TestPreviewOperationRetainsSanitizedRendererFailureCategory(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	runner := &fixturePreviewRunner{previewExitCode: 1, previewErrorCategory: "tautulli-unavailable"}
	coordinator, err := newOperationCoordinator(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Now: time.Now, operationRunner: runner})
	if err != nil {
		t.Fatal(err)
	}
	view := ReadConfigEditor(root)
	if _, err := coordinator.Start(CreateOperationRequest{Type: "preview-all", ExpectedRevision: view.Revision, UserID: "42", ConfirmNoSend: true}); err != nil {
		t.Fatal(err)
	}
	finished := waitForOperationState(t, coordinator, "failed")
	if finished.ErrorCategory != "tautulli-unavailable" || finished.SupportCode == "" || finished.ExitCode == nil || *finished.ExitCode != 1 {
		t.Fatalf("unexpected categorized preview failure: %+v", finished)
	}
}

func TestPreviewOperationMapsServiceLockExitToBusy(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	runner := &fixturePreviewRunner{previewExitCode: 75}
	coordinator, err := newOperationCoordinator(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Now: time.Now, operationRunner: runner})
	if err != nil {
		t.Fatal(err)
	}
	view := ReadConfigEditor(root)
	if _, err := coordinator.Start(CreateOperationRequest{Type: "preview-all", ExpectedRevision: view.Revision, UserID: "42", ConfirmNoSend: true}); err != nil {
		t.Fatal(err)
	}
	finished := waitForOperationState(t, coordinator, "failed")
	if finished.ErrorCategory != "operation-busy" || finished.SupportCode == "" || finished.ExitCode == nil || *finished.ExitCode != 75 {
		t.Fatalf("unexpected busy preview failure: %+v", finished)
	}
}

func TestSendTestAllOperationRecordsAggregateSMTPAcceptanceAndCannotCancel(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	runner := &fixturePreviewRunner{started: make(chan struct{}), release: make(chan struct{})}
	coordinator, err := newOperationCoordinator(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Now: time.Now, operationRunner: runner})
	if err != nil {
		t.Fatal(err)
	}
	view := ReadConfigEditor(root)
	request := CreateOperationRequest{Type: "send-test-all", ExpectedRevision: view.Revision, UserID: "42", ConfirmTestSend: true}
	started, err := coordinator.Start(request)
	if err != nil {
		t.Fatal(err)
	}
	if started.Cancellable || started.Type != "send-test-all" {
		t.Fatalf("test-send operation exposed unsafe cancellation: %+v", started)
	}
	select {
	case <-runner.started:
	case <-time.After(3 * time.Second):
		t.Fatal("fixture test-send did not start")
	}
	if _, err := coordinator.Cancel(started.ID); !errors.Is(err, ErrOperationNotCancellable) {
		t.Fatalf("test-send cancellation error: got %v", err)
	}
	close(runner.release)
	finished := waitForOperationState(t, coordinator, "succeeded")
	if finished.DeliveryScope != "test" || finished.SMTPAcceptedCount != 6 || finished.FailedCount != 0 || len(finished.GeneratedPreviewIDs) != 0 {
		t.Fatalf("unexpected test-send result: %+v", finished)
	}
	for _, request := range []CreateOperationRequest{
		{Type: "send-test-all", ExpectedRevision: view.Revision, UserID: "42"},
		{Type: "send-test-all", ExpectedRevision: view.Revision, UserID: "42", ConfirmNoSend: true, ConfirmTestSend: true},
	} {
		if _, err := coordinator.Start(request); err == nil {
			t.Fatalf("unsafe test-send request was accepted: %+v", request)
		}
	}
}

func TestSendTestAllOperationRetainsSanitizedSMTPFailureEvidence(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	runner := &fixturePreviewRunner{sendTestAllFailure: true}
	coordinator, err := newOperationCoordinator(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Now: time.Now, operationRunner: runner})
	if err != nil {
		t.Fatal(err)
	}
	view := ReadConfigEditor(root)
	if _, err := coordinator.Start(CreateOperationRequest{Type: "send-test-all", ExpectedRevision: view.Revision, UserID: "42", ConfirmTestSend: true}); err != nil {
		t.Fatal(err)
	}
	finished := waitForOperationState(t, coordinator, "failed")
	if finished.DeliveryScope != "test" || finished.SMTPAcceptedCount != 0 || finished.FailedCount != 1 || finished.ErrorCategory != "smtp-auth-failed" || finished.SMTPFailure == nil || finished.SMTPFailure.Stage != "auth" || finished.SMTPFailure.ResponseCode != 535 || finished.SupportCode == "" {
		t.Fatalf("unexpected sanitized test-send failure: %+v", finished)
	}
}

func TestSendAllOperationRequiresProductionConfirmationAndRecordsOnlyAggregates(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	runner := &fixturePreviewRunner{started: make(chan struct{})}
	coordinator, err := newOperationCoordinator(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Now: time.Now, operationRunner: runner})
	if err != nil {
		t.Fatal(err)
	}
	view := ReadConfigEditor(root)
	request := CreateOperationRequest{Type: "send-all", ExpectedRevision: view.Revision}
	if _, err := coordinator.Start(request); !errors.Is(err, ErrOperationConfirmation) {
		t.Fatalf("unconfirmed production send error: got %v", err)
	}
	request.ConfirmProductionSend = true
	started, err := coordinator.Start(request)
	if err != nil {
		t.Fatal(err)
	}
	if started.Cancellable || started.Type != "send-all" {
		t.Fatalf("production send exposed unsafe cancellation: %+v", started)
	}
	finished := waitForOperationState(t, coordinator, "succeeded")
	if finished.DeliveryScope != "production" || finished.SMTPAcceptedCount != 4 || finished.SkippedCount != 2 || finished.FailedCount != 0 || len(finished.GeneratedPreviewIDs) != 0 {
		t.Fatalf("unexpected production send result: %+v", finished)
	}
	if finished.SkipReasonCounts == nil || finished.SkipReasonCounts.InactiveOrDeleted != 1 || finished.SkipReasonCounts.ExcludedUserID != 1 {
		t.Fatalf("production send omitted sanitized skip reasons: %+v", finished)
	}
	request.UserID = "42"
	if _, err := coordinator.Start(request); !errors.Is(err, ErrOperationInvalid) {
		t.Fatalf("production send accepted an unnecessary user ID: %v", err)
	}
}

func TestSendWelcomeOperationRequiresSelectedUserAndProductionConfirmation(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	runner := &fixturePreviewRunner{}
	coordinator, err := newOperationCoordinator(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Now: time.Now, operationRunner: runner})
	if err != nil {
		t.Fatal(err)
	}
	view := ReadConfigEditor(root)
	request := CreateOperationRequest{Type: "send-welcome", ExpectedRevision: view.Revision, UserID: "42"}
	if _, err := coordinator.Start(request); !errors.Is(err, ErrOperationConfirmation) {
		t.Fatalf("unconfirmed Manual Welcome error: got %v", err)
	}
	request.ConfirmProductionSend = true
	started, err := coordinator.Start(request)
	if err != nil {
		t.Fatal(err)
	}
	if started.Cancellable || started.Type != "send-welcome" {
		t.Fatalf("Manual Welcome exposed unsafe cancellation: %+v", started)
	}
	finished := waitForOperationState(t, coordinator, "succeeded")
	if finished.DeliveryScope != "welcome" || finished.SMTPAcceptedCount != 1 || finished.SkippedCount != 0 || finished.FailedCount != 0 {
		t.Fatalf("unexpected Manual Welcome result: %+v", finished)
	}
	runner.mu.Lock()
	selectedUserID := runner.userID
	runner.mu.Unlock()
	if selectedUserID != "42" {
		t.Fatalf("Manual Welcome selected user: got %q", selectedUserID)
	}
	request.UserID = ""
	if _, err := coordinator.Start(request); !errors.Is(err, ErrOperationInvalid) {
		t.Fatalf("Manual Welcome accepted no selected user: %v", err)
	}
}

func TestUserScopedOperationsRejectSavedExclusionsBeforeRunnerStart(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	setIntegrationConfigValues(t, root, map[string]any{
		"ExcludedUserIds":    []string{"42"},
		"ExcludedEmails":     []string{"blocked@example.org"},
		"UserEmailOverrides": map[string]string{"43": "BLOCKED@example.org"},
	})
	view := ReadConfigEditor(root)
	for _, test := range []struct {
		operationType string
		userID        string
	}{
		{operationType: "preview-all", userID: "42"},
		{operationType: "send-test-all", userID: "42"},
		{operationType: "send-welcome", userID: "42"},
		{operationType: "preview-all", userID: "43"},
	} {
		t.Run(test.operationType+"-"+test.userID, func(t *testing.T) {
			runner := &fixturePreviewRunner{}
			coordinator, err := newOperationCoordinator(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Now: time.Now, operationRunner: runner})
			if err != nil {
				t.Fatal(err)
			}
			request := CreateOperationRequest{Type: test.operationType, ExpectedRevision: view.Revision, UserID: test.userID}
			request.ConfirmNoSend = test.operationType == "preview-all"
			request.ConfirmTestSend = test.operationType == "send-test-all"
			request.ConfirmProductionSend = test.operationType == "send-welcome"
			if _, err := coordinator.Start(request); !errors.Is(err, ErrOperationUserExcluded) {
				t.Fatalf("saved exclusion was not rejected: %v", err)
			}
			if coordinator.Current() != nil {
				t.Fatal("excluded operation created durable state")
			}
		})
	}
}

func TestUserScopedOperationsRejectCurrentDiscoveryLegacyExclusions(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	data := t.TempDir()
	view := ReadConfigEditor(root)
	discovery := newTautulliDiscoveryStore(data)
	if err := discovery.Save(TautulliDiscoveryResult{
		Mode:            "real-lan-discovery",
		NetworkBoundary: "private-and-loopback-only",
		CompletedAtUTC:  time.Now().UTC().Format(time.RFC3339),
		ConfigRevision:  view.Revision,
		Libraries:       []DiscoveredLibrary{{ID: "1", Name: "Synthetic Movies", MediaType: "movie"}},
		Users:           []DiscoveredUser{{ID: "44", Name: "Synthetic Viewer", Eligibility: "eligible", LegacyRuleExcluded: true}},
	}); err != nil {
		t.Fatal(err)
	}
	coordinator, err := newOperationCoordinator(Options{DataDir: data, TautWeeklyRoot: root, Now: time.Now, operationRunner: &fixturePreviewRunner{}})
	if err != nil {
		t.Fatal(err)
	}
	coordinator.discovery = discovery
	request := CreateOperationRequest{Type: "preview-all", ExpectedRevision: view.Revision, UserID: "44", ConfirmNoSend: true}
	if _, err := coordinator.Start(request); !errors.Is(err, ErrOperationUserExcluded) {
		t.Fatalf("current discovery legacy exclusion was not rejected: %v", err)
	}
	if coordinator.Current() != nil {
		t.Fatal("legacy-excluded operation created durable state")
	}
}

func TestSendAllOperationRetainsStructuredPartialDeliveryEvidence(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	runner := &fixturePreviewRunner{sendAllPartial: true}
	coordinator, err := newOperationCoordinator(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Now: time.Now, operationRunner: runner})
	if err != nil {
		t.Fatal(err)
	}
	view := ReadConfigEditor(root)
	if _, err := coordinator.Start(CreateOperationRequest{Type: "send-all", ExpectedRevision: view.Revision, ConfirmProductionSend: true}); err != nil {
		t.Fatal(err)
	}
	finished := waitForOperationState(t, coordinator, "partial")
	if finished.Outcome != "partial" || finished.ExitCode == nil || *finished.ExitCode != 2 || finished.SMTPAcceptedCount != 3 || finished.SkippedCount != 1 || finished.FailedCount != 1 || finished.ErrorCategory != "smtp-recipient-rejected" || finished.SMTPFailure == nil || finished.SMTPFailure.ResponseCode != 550 || finished.SupportCode == "" {
		t.Fatalf("unexpected partial production result: %+v", finished)
	}
}

func TestSendAllOperationReportsZeroEligibleRecipientsAsFailure(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	runner := &fixturePreviewRunner{sendAllNoEligible: true}
	coordinator, err := newOperationCoordinator(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Now: time.Now, operationRunner: runner})
	if err != nil {
		t.Fatal(err)
	}
	view := ReadConfigEditor(root)
	if _, err := coordinator.Start(CreateOperationRequest{Type: "send-all", ExpectedRevision: view.Revision, ConfirmProductionSend: true}); err != nil {
		t.Fatal(err)
	}
	finished := waitForOperationState(t, coordinator, "failed")
	if finished.ErrorCategory != "no-eligible-recipients" || finished.SMTPAcceptedCount != 0 || finished.SkippedCount != 2 || finished.FailedCount != 0 || finished.SkipReasonCounts == nil || finished.SupportCode == "" {
		t.Fatalf("zero-eligible production result was not explicit and sanitized: %+v", finished)
	}
}

func TestPreviewOperationValidationAndRestartRecovery(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	data := t.TempDir()
	runner := &fixturePreviewRunner{started: make(chan struct{}), release: make(chan struct{})}
	coordinator, err := newOperationCoordinator(Options{DataDir: data, TautWeeklyRoot: root, Now: time.Now, operationRunner: runner})
	if err != nil {
		t.Fatal(err)
	}
	view := ReadConfigEditor(root)
	for _, request := range []CreateOperationRequest{
		{Type: "preview-all", ExpectedRevision: view.Revision, UserID: "not-numeric", ConfirmNoSend: true},
		{Type: "preview-all", ExpectedRevision: view.Revision, UserID: "1", ConfirmNoSend: false},
		{Type: "arbitrary-command", ExpectedRevision: view.Revision, UserID: "1", ConfirmNoSend: true},
	} {
		if _, err := coordinator.Start(request); err == nil {
			t.Fatalf("invalid operation was accepted: %+v", request)
		}
	}
	if _, err := coordinator.Start(CreateOperationRequest{Type: "preview-all", ExpectedRevision: "stale", UserID: "1", ConfirmNoSend: true}); !errors.Is(err, ErrConfigConflict) {
		t.Fatalf("stale revision error: got %v", err)
	}

	active := OperationRecord{
		SchemaVersion:       operationSchemaVersion,
		ID:                  "restart-fixture",
		Type:                "preview-all",
		Trigger:             "gui",
		State:               "running",
		StartedAtUTC:        time.Now().Add(-time.Minute).UTC().Format(time.RFC3339),
		GeneratedPreviewIDs: []string{},
		Cancellable:         true,
	}
	if err := coordinator.store.saveCurrent(active); err != nil {
		t.Fatal(err)
	}
	staleSnapshot := filepath.Join(data, "operation-restart-fixture.config.json")
	if err := os.WriteFile(staleSnapshot, []byte(`{"ApiKey":"stale-secret"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	staleResult := filepath.Join(data, "operation-restart-fixture.result.json")
	if err := os.WriteFile(staleResult, []byte(`{"recipientEmail":"private@example.org"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	recovered, err := newOperationCoordinator(Options{DataDir: data, TautWeeklyRoot: root, Now: time.Now, operationRunner: runner})
	if err != nil {
		t.Fatal(err)
	}
	current := recovered.Current()
	if current == nil || current.State != "failed" || current.ErrorCategory != "manager-restarted" || current.Cancellable {
		t.Fatalf("unexpected recovered operation: %+v", current)
	}
	if _, err := os.Stat(staleSnapshot); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale secret snapshot was not removed: %v", err)
	}
	if _, err := os.Stat(staleResult); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale renderer result was not removed: %v", err)
	}
}

func TestNonCancellableDeliverySurvivesManagerRestartAndReconcilesResult(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	data := t.TempDir()
	started := time.Now().Add(-time.Minute).UTC()
	record := OperationRecord{
		SchemaVersion:       operationSchemaVersion,
		ID:                  "delivery-restart-fixture",
		Type:                "send-all",
		Trigger:             "gui",
		State:               "running",
		StartedAtUTC:        started.Format(time.RFC3339),
		GeneratedPreviewIDs: []string{},
	}
	store := operationStore{currentPath: filepath.Join(data, "operation-current.json"), historyPath: filepath.Join(data, "operation-history.jsonl"), now: time.Now}
	if err := store.saveCurrent(record); err != nil {
		t.Fatal(err)
	}
	config, err := os.ReadFile(filepath.Join(root, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	snapshotPath := filepath.Join(data, "operation-"+record.ID+".config.json")
	if err := os.WriteFile(snapshotPath, config, 0o600); err != nil {
		t.Fatal(err)
	}
	coordinator, err := newOperationCoordinator(Options{DataDir: data, TautWeeklyRoot: root, Now: time.Now, operationRunner: &fixturePreviewRunner{}})
	if err != nil {
		t.Fatal(err)
	}
	if current := coordinator.Current(); current == nil || current.State != "running" {
		t.Fatalf("delivery was not preserved across restart: %+v", current)
	}
	if _, err := os.Stat(snapshotPath); err != nil {
		t.Fatalf("active delivery snapshot was removed: %v", err)
	}
	result := rendererResult{
		SchemaVersion:     1,
		Mode:              "SendAll",
		Outcome:           "succeeded",
		DeliveryScope:     "production",
		StartedAtUTC:      started.Format(time.RFC3339Nano),
		FinishedAtUTC:     started.Add(2 * time.Minute).Format(time.RFC3339Nano),
		DurationMS:        120000,
		SMTPAcceptedCount: 3,
		SkippedCount:      1,
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	resultPath := filepath.Join(data, "operation-"+record.ID+".result.json")
	if err := os.WriteFile(resultPath, encoded, 0o600); err != nil {
		t.Fatal(err)
	}
	finished := waitForOperationState(t, coordinator, "succeeded")
	if finished.Outcome != "success" || finished.SMTPAcceptedCount != 3 || finished.SkippedCount != 1 || finished.ExitCode != nil {
		t.Fatalf("reconciled delivery result: %+v", finished)
	}
	for _, path := range []string{snapshotPath, resultPath} {
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("reconciled private runtime file was not removed: %s (%v)", path, err)
		}
	}
}

func TestTautulliUserIDValidationExcludesReservedLocal(t *testing.T) {
	for _, value := range []string{"1", "001", "18446744073709551615"} {
		if !validTautulliUserID(value) {
			t.Fatalf("valid Tautulli user ID %q was rejected", value)
		}
	}
	for _, value := range []string{"0", "00", "00000000000000000000", "", "-1", "not-numeric", "18446744073709551616", "000000000000000000000"} {
		if validTautulliUserID(value) {
			t.Fatalf("invalid Tautulli user ID %q was accepted", value)
		}
	}
}

func TestOperationHistorySkipsMalformedEntries(t *testing.T) {
	data := t.TempDir()
	path := filepath.Join(data, "operation-history.jsonl")
	valid := OperationRecord{SchemaVersion: 1, ID: "valid", Type: "preview-all", Trigger: "gui", State: "succeeded", Outcome: "success", StartedAtUTC: time.Now().UTC().Format(time.RFC3339), GeneratedPreviewIDs: []string{}}
	encoded, err := json.Marshal(valid)
	if err != nil {
		t.Fatal(err)
	}
	content := append([]byte("not-json\n"), encoded...)
	content = append(content, '\n')
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}
	store := operationStore{historyPath: path, now: time.Now}
	records := store.readHistory()
	if len(records) != 1 || records[0].ID != "valid" {
		t.Fatalf("unexpected sanitized history: %+v", records)
	}
}

func TestOperationHistoryUsesCountOnlyFIFOAndNormalizesAtStartup(t *testing.T) {
	data := t.TempDir()
	path := filepath.Join(data, "operation-history.jsonl")
	now := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	var content bytes.Buffer
	writeRecord := func(id string, started time.Time) {
		record := OperationRecord{
			SchemaVersion:       operationSchemaVersion,
			ID:                  id,
			Type:                "preview-all",
			Trigger:             "gui",
			State:               "succeeded",
			Outcome:             "success",
			StartedAtUTC:        started.UTC().Format(time.RFC3339),
			FinishedAtUTC:       started.Add(time.Minute).UTC().Format(time.RFC3339),
			GeneratedPreviewIDs: []string{},
		}
		encoded, err := json.Marshal(record)
		if err != nil {
			t.Fatal(err)
		}
		content.Write(encoded)
		content.WriteByte('\n')
	}
	for index := 0; index < operationHistoryLimit-1; index++ {
		writeRecord("recent-"+strconv.Itoa(index), now.Add(-time.Duration(index)*time.Minute))
	}
	writeRecord("old-but-valid", now.Add(-400*24*time.Hour))
	for index := 0; index < 10; index++ {
		writeRecord("overflow-"+strconv.Itoa(index), now.Add(-time.Duration(500+index)*24*time.Hour))
	}
	if err := os.WriteFile(path, content.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
	coordinator, err := newOperationCoordinator(Options{DataDir: data, TautWeeklyRoot: t.TempDir(), Now: func() time.Time { return now }})
	if err != nil {
		t.Fatal(err)
	}
	history := coordinator.History()
	records := history.Operations
	if len(records) != operationHistoryLimit {
		t.Fatalf("pruned record count: got %d, want %d", len(records), operationHistoryLimit)
	}
	if records[0].ID != "recent-0" || records[len(records)-1].ID != "old-but-valid" {
		t.Fatalf("history did not retain the newest bounded records: first=%s last=%s", records[0].ID, records[len(records)-1].ID)
	}
	if history.MaximumEntries != operationHistoryLimit || history.RetentionPolicy != "count-only-fifo" {
		t.Fatalf("unexpected retention metadata: %+v", history)
	}
}

func waitForOperationState(t *testing.T, coordinator *operationCoordinator, expected string) OperationRecord {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		current := coordinator.Current()
		if current != nil && current.State == expected {
			return *current
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("operation did not reach %s; current=%+v", expected, coordinator.Current())
	return OperationRecord{}
}
