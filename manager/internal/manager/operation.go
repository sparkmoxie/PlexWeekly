package manager

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	operationSchemaVersion = 1
	operationHistoryLimit  = 20
	operationRetention     = "count-only-fifo"
	maximumOperationLine   = 64 << 10
	operationRecoveryAge   = 24 * time.Hour
)

var (
	ErrOperationBusy           = errors.New("another manager operation is active")
	ErrOperationConfirmation   = errors.New("operation confirmation is required")
	ErrOperationInvalid        = errors.New("operation request is invalid")
	ErrOperationNotFound       = errors.New("operation was not found")
	ErrOperationNotReady       = errors.New("configuration is not ready for the operation")
	ErrOperationUserExcluded   = errors.New("selected user is excluded by saved recipient policy")
	ErrOperationTerminal       = errors.New("operation is already complete")
	ErrOperationNotCancellable = errors.New("operation cannot be cancelled safely")
	ErrOperationUnsupported    = errors.New("operation is unsupported on this platform")
)

type CreateOperationRequest struct {
	Type                  string `json:"type"`
	ExpectedRevision      string `json:"expectedRevision"`
	UserID                string `json:"userId"`
	ConfirmNoSend         bool   `json:"confirmNoSend"`
	ConfirmTestSend       bool   `json:"confirmTestSend"`
	ConfirmProductionSend bool   `json:"confirmProductionSend"`
}

type OperationRecord struct {
	SchemaVersion       int                       `json:"schemaVersion"`
	ID                  string                    `json:"id"`
	Type                string                    `json:"type"`
	Trigger             string                    `json:"trigger"`
	PackageVersion      string                    `json:"packageVersion,omitempty"`
	State               string                    `json:"state"`
	Outcome             string                    `json:"outcome,omitempty"`
	StartedAtUTC        string                    `json:"startedAtUtc"`
	FinishedAtUTC       string                    `json:"finishedAtUtc,omitempty"`
	DurationMS          int64                     `json:"durationMs,omitempty"`
	DeliveryScope       string                    `json:"deliveryScope,omitempty"`
	SMTPAcceptedCount   int                       `json:"smtpAcceptedCount,omitempty"`
	SkippedCount        int                       `json:"skippedCount,omitempty"`
	FailedCount         int                       `json:"failedCount,omitempty"`
	SMTPFailure         *SMTPFailureEvidence      `json:"smtpFailure,omitempty"`
	SkipReasonCounts    *DeliverySkipReasonCounts `json:"skipReasonCounts,omitempty"`
	ExitCode            *int                      `json:"exitCode,omitempty"`
	GeneratedPreviewIDs []string                  `json:"generatedPreviewIds"`
	ErrorCategory       string                    `json:"errorCategory,omitempty"`
	SupportCode         string                    `json:"supportCode,omitempty"`
	Cancellable         bool                      `json:"cancellable"`
}

type OperationHistory struct {
	Operations      []OperationRecord `json:"operations"`
	MaximumEntries  int               `json:"maximumEntries"`
	RetentionPolicy string            `json:"retentionPolicy"`
}

type operationRunner interface {
	RunPreviewAll(ctx context.Context, root, configPath, resultPath, userID string) (int, error)
	RunCacheWarm(ctx context.Context, root, configPath, resultPath string) (int, error)
	RunSendTestAll(ctx context.Context, root, configPath, resultPath, userID string) (int, error)
	RunSendWelcome(ctx context.Context, root, configPath, resultPath, userID string) (int, error)
	RunSendAll(ctx context.Context, root, configPath, resultPath string) (int, error)
}

type operationStore struct {
	currentPath string
	historyPath string
	now         func() time.Time
}

type operationCoordinator struct {
	mu          sync.RWMutex
	root        string
	runtimeRoot string
	dataDir     string
	now         func() time.Time
	runner      operationRunner
	discovery   *tautulliDiscoveryStore
	store       operationStore
	current     *OperationRecord
	cancel      context.CancelFunc
	onComplete  func(OperationRecord, string)
}

func newOperationCoordinator(options Options) (*operationCoordinator, error) {
	runner := options.operationRunner
	if runner == nil {
		runner = platformPreviewOperationRunner{}
	}
	runtimeRoot := options.RuntimeRoot
	if strings.TrimSpace(runtimeRoot) == "" {
		runtimeRoot = options.TautWeeklyRoot
	}
	coordinator := &operationCoordinator{
		root:        options.TautWeeklyRoot,
		runtimeRoot: runtimeRoot,
		dataDir:     options.DataDir,
		now:         options.Now,
		runner:      runner,
		onComplete:  options.operationCompleted,
		store: operationStore{
			currentPath: filepath.Join(options.DataDir, "operation-current.json"),
			historyPath: filepath.Join(options.DataDir, "operation-history.jsonl"),
			now:         options.Now,
		},
	}
	if coordinator.now == nil {
		coordinator.now = time.Now
		coordinator.store.now = time.Now
	}
	if err := coordinator.store.pruneHistory(); err != nil {
		return nil, fmt.Errorf("normalize operation history: %w", err)
	}
	coordinator.current = coordinator.store.readCurrent()
	if coordinator.current != nil && operationActive(coordinator.current.State) {
		record := *coordinator.current
		revision := operationSnapshotRevision(coordinator.snapshotPath(record.ID))
		if recoverableDeliveryOperation(record.Type) && revision != "" {
			go coordinator.recoverDelivery(record, revision)
		} else if err := coordinator.failInterruptedOperation(record, revision); err != nil {
			return nil, err
		}
	}
	coordinator.removeStaleSnapshots()
	return coordinator, nil
}

func (c *operationCoordinator) Start(request CreateOperationRequest) (OperationRecord, error) {
	if request.Type != "preview-all" && request.Type != "cache-warm" && request.Type != "send-test-all" && request.Type != "send-welcome" && request.Type != "send-all" {
		return OperationRecord{}, ErrOperationInvalid
	}
	if request.Type == "preview-all" {
		if request.ConfirmTestSend || request.ConfirmProductionSend {
			return OperationRecord{}, ErrOperationInvalid
		}
		if !request.ConfirmNoSend {
			return OperationRecord{}, ErrOperationConfirmation
		}
	}
	if request.Type == "cache-warm" && (request.ConfirmNoSend || request.ConfirmTestSend || request.ConfirmProductionSend) {
		return OperationRecord{}, ErrOperationInvalid
	}
	if request.Type == "send-test-all" {
		if request.ConfirmNoSend || request.ConfirmProductionSend {
			return OperationRecord{}, ErrOperationInvalid
		}
		if !request.ConfirmTestSend {
			return OperationRecord{}, ErrOperationConfirmation
		}
	}
	if request.Type == "send-welcome" || request.Type == "send-all" {
		if request.ConfirmNoSend || request.ConfirmTestSend {
			return OperationRecord{}, ErrOperationInvalid
		}
		if !request.ConfirmProductionSend {
			return OperationRecord{}, ErrOperationConfirmation
		}
	}
	userID := strings.TrimSpace(request.UserID)
	requiresUser := request.Type == "preview-all" || request.Type == "send-test-all" || request.Type == "send-welcome"
	if (requiresUser && !validTautulliUserID(userID)) || (!requiresUser && userID != "") {
		return OperationRecord{}, ErrOperationInvalid
	}
	values, raw, exists, state := readConfigDocument(c.runtimeRoot)
	if state != "ready" || !exists || len(existingConfigIssues(values)) > 0 {
		return OperationRecord{}, ErrOperationNotReady
	}
	revision := configRevision(raw, true)
	if request.ExpectedRevision == "" || request.ExpectedRevision != revision {
		return OperationRecord{}, ErrConfigConflict
	}
	if requiresUser && (savedOperationUserExcluded(values, userID) || c.savedDiscoveryUserExcluded(revision, userID)) {
		return OperationRecord{}, ErrOperationUserExcluded
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	if c.current != nil && operationActive(c.current.State) {
		return OperationRecord{}, ErrOperationBusy
	}
	id, err := randomToken(12)
	if err != nil {
		return OperationRecord{}, err
	}
	snapshotPath := c.snapshotPath(id)
	if err := writePrivateFile(snapshotPath, raw, os.O_CREATE|os.O_EXCL); err != nil {
		return OperationRecord{}, fmt.Errorf("create operation configuration snapshot: %w", err)
	}
	now := c.now().UTC()
	previewBaseline := map[string]previewFingerprint{}
	if request.Type == "preview-all" {
		previewBaseline = previewFingerprints(c.runtimeRoot)
	}
	resultPath := c.resultPath(id)
	record := OperationRecord{
		SchemaVersion:       operationSchemaVersion,
		ID:                  id,
		Type:                request.Type,
		Trigger:             "gui",
		PackageVersion:      readPackageVersion(c.root),
		State:               "queued",
		StartedAtUTC:        now.Format(time.RFC3339),
		GeneratedPreviewIDs: []string{},
		Cancellable:         request.Type == "preview-all" || request.Type == "cache-warm",
	}
	if err := c.store.saveCurrent(record); err != nil {
		_ = os.Remove(snapshotPath)
		return OperationRecord{}, err
	}
	operationContext, cancel := context.WithCancel(context.Background())
	c.cancel = cancel
	c.current = &record
	go c.run(operationContext, record, revision, snapshotPath, resultPath, userID, previewBaseline)
	return record, nil
}

func (c *operationCoordinator) savedDiscoveryUserExcluded(revision, userID string) bool {
	if c.discovery == nil {
		return false
	}
	discovery := c.discovery.Load(revision)
	if discovery == nil {
		return false
	}
	for _, user := range discovery.Users {
		if user.ID == userID {
			return user.LegacyRuleExcluded
		}
	}
	return false
}

func savedOperationUserExcluded(values map[string]any, userID string) bool {
	if configStringListContains(values["ExcludedUserIds"], userID, false) {
		return true
	}
	effectiveAddress := configUserEmailOverride(values["UserEmailOverrides"], userID)
	return effectiveAddress != "" && configStringListContains(values["ExcludedEmails"], effectiveAddress, true)
}

func configStringListContains(value any, candidate string, fold bool) bool {
	matches := func(item any) bool {
		text, ok := item.(string)
		if !ok {
			return false
		}
		text = strings.TrimSpace(text)
		if fold {
			return strings.EqualFold(text, strings.TrimSpace(candidate))
		}
		return text == strings.TrimSpace(candidate)
	}
	switch typed := value.(type) {
	case []any:
		for _, item := range typed {
			if matches(item) {
				return true
			}
		}
	case []string:
		for _, item := range typed {
			if matches(item) {
				return true
			}
		}
	}
	return false
}

func configUserEmailOverride(value any, userID string) string {
	var address any
	switch typed := value.(type) {
	case map[string]any:
		address = typed[userID]
	case map[string]string:
		address = typed[userID]
	default:
		return ""
	}
	text, ok := address.(string)
	if !ok {
		return ""
	}
	return strings.TrimSpace(text)
}

func (c *operationCoordinator) run(ctx context.Context, record OperationRecord, revision, snapshotPath, resultPath, userID string, previewBaseline map[string]previewFingerprint) {
	defer os.Remove(snapshotPath)
	defer os.Remove(resultPath)
	c.setRunning(record.ID)
	mode := "PreviewAll"
	var exitCode int
	var runErr error
	if record.Type == "send-all" {
		mode = "SendAll"
		exitCode, runErr = c.runner.RunSendAll(ctx, c.root, snapshotPath, resultPath)
	} else if record.Type == "send-welcome" {
		mode = "SendWelcome"
		exitCode, runErr = c.runner.RunSendWelcome(ctx, c.root, snapshotPath, resultPath, userID)
	} else if record.Type == "send-test-all" {
		mode = "SendTestAll"
		exitCode, runErr = c.runner.RunSendTestAll(ctx, c.root, snapshotPath, resultPath, userID)
	} else if record.Type == "cache-warm" {
		mode = "CacheWarm"
		exitCode, runErr = c.runner.RunCacheWarm(ctx, c.root, snapshotPath, resultPath)
	} else {
		exitCode, runErr = c.runner.RunPreviewAll(ctx, c.root, snapshotPath, resultPath, userID)
	}
	structuredResult, resultErr := readRendererResult(resultPath, mode)
	finished := c.now().UTC()
	record.FinishedAtUTC = finished.Format(time.RFC3339)
	record.Cancellable = false
	record.ExitCode = &exitCode
	if record.Type == "preview-all" {
		record.GeneratedPreviewIDs = changedPreviewIDs(c.runtimeRoot, previewBaseline)
	}
	if resultErr == nil {
		record.DurationMS = structuredResult.DurationMS
		record.DeliveryScope = structuredResult.DeliveryScope
		record.SMTPAcceptedCount = structuredResult.SMTPAcceptedCount
		record.SkippedCount = structuredResult.SkippedCount
		record.FailedCount = structuredResult.FailedCount
		record.SMTPFailure = structuredResult.SMTPFailure
		record.SkipReasonCounts = structuredResult.SkipReasonCounts
		if record.Type == "send-all" {
			_ = writePrivateJSON(filepath.Join(c.runtimeRoot, "last-run.json"), structuredResult)
		}
	}
	switch {
	case errors.Is(ctx.Err(), context.Canceled), errors.Is(runErr, context.Canceled):
		record.State = "cancelled"
		record.Outcome = "cancelled"
		record.ErrorCategory = "cancelled"
	case errors.Is(runErr, ErrOperationUnsupported):
		record.State = "failed"
		record.Outcome = "failed"
		record.ErrorCategory = "platform-unsupported"
		record.SupportCode = operationSupportCode(record.ID)
	case record.Type == "send-all" && resultErr == nil && structuredResult.Outcome == "partial":
		record.State = "partial"
		record.Outcome = "partial"
		record.ErrorCategory = structuredResult.ErrorCategory
		record.SupportCode = operationSupportCode(record.ID)
	case runErr != nil:
		record.State = "failed"
		record.Outcome = "failed"
		record.ErrorCategory = rendererOperationErrorCategory(exitCode, structuredResult, resultErr)
		record.SupportCode = operationSupportCode(record.ID)
	case resultErr != nil:
		record.State = "failed"
		record.Outcome = "failed"
		record.ErrorCategory = "renderer-result-invalid"
		record.SupportCode = operationSupportCode(record.ID)
	case structuredResult.Outcome != "succeeded":
		record.State = "failed"
		record.Outcome = "failed"
		record.ErrorCategory = rendererOperationErrorCategory(exitCode, structuredResult, resultErr)
		record.SupportCode = operationSupportCode(record.ID)
	case record.Type == "preview-all" && len(record.GeneratedPreviewIDs) != len(structuredResult.GeneratedPreviewFiles):
		record.State = "failed"
		record.Outcome = "failed"
		record.ErrorCategory = "renderer-result-mismatch"
		record.SupportCode = operationSupportCode(record.ID)
	default:
		record.State = "succeeded"
		record.Outcome = "success"
	}
	_ = c.commitTerminalOperation(record, revision, true, snapshotPath, resultPath)
}

func rendererOperationErrorCategory(exitCode int, result rendererResult, resultErr error) string {
	if exitCode == 75 {
		return "operation-busy"
	}
	if resultErr == nil && validRendererErrorCategory(result.ErrorCategory) {
		return result.ErrorCategory
	}
	return "renderer-failed"
}

func recoverableDeliveryOperation(operationType string) bool {
	return operationType == "send-test-all" || operationType == "send-welcome" || operationType == "send-all"
}

func operationMode(operationType string) string {
	switch operationType {
	case "send-test-all":
		return "SendTestAll"
	case "send-welcome":
		return "SendWelcome"
	case "send-all":
		return "SendAll"
	default:
		return ""
	}
}

func (c *operationCoordinator) recoverDelivery(record OperationRecord, revision string) {
	resultPath := c.resultPath(record.ID)
	snapshotPath := c.snapshotPath(record.ID)
	deadline := c.now().UTC().Add(operationRecoveryAge)
	if started, err := time.Parse(time.RFC3339, record.StartedAtUTC); err == nil {
		deadline = started.UTC().Add(operationRecoveryAge)
	}
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for {
		result, err := readRendererResult(resultPath, operationMode(record.Type))
		if err == nil {
			c.finishRecoveredDelivery(record, revision, result, snapshotPath, resultPath)
			return
		}
		if !c.now().UTC().Before(deadline) {
			_ = c.failInterruptedOperation(record, revision, snapshotPath, resultPath)
			return
		}
		<-ticker.C
	}
}

func (c *operationCoordinator) finishRecoveredDelivery(record OperationRecord, revision string, result rendererResult, cleanupPaths ...string) {
	record.Cancellable = false
	record.FinishedAtUTC = result.FinishedAtUTC
	record.DurationMS = result.DurationMS
	record.DeliveryScope = result.DeliveryScope
	record.SMTPAcceptedCount = result.SMTPAcceptedCount
	record.SkippedCount = result.SkippedCount
	record.FailedCount = result.FailedCount
	record.SkipReasonCounts = result.SkipReasonCounts
	switch {
	case record.Type == "send-all" && result.Outcome == "partial":
		record.State = "partial"
		record.Outcome = "partial"
		record.SupportCode = operationSupportCode(record.ID)
	case result.Outcome == "succeeded":
		record.State = "succeeded"
		record.Outcome = "success"
	default:
		record.State = "failed"
		record.Outcome = "failed"
		record.ErrorCategory = rendererOperationErrorCategory(0, result, nil)
		record.SupportCode = operationSupportCode(record.ID)
	}
	_ = c.commitTerminalOperation(record, revision, true, cleanupPaths...)
}

func (c *operationCoordinator) failInterruptedOperation(record OperationRecord, revision string, cleanupPaths ...string) error {
	record.State = "failed"
	record.Outcome = "failed"
	record.Cancellable = false
	record.FinishedAtUTC = c.now().UTC().Format(time.RFC3339)
	record.ErrorCategory = "manager-restarted"
	record.SupportCode = operationSupportCode(record.ID)
	return c.commitTerminalOperation(record, revision, true, cleanupPaths...)
}

func (c *operationCoordinator) commitTerminalOperation(record OperationRecord, revision string, requireActive bool, cleanupPaths ...string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if requireActive && (c.current == nil || c.current.ID != record.ID || !operationActive(c.current.State)) {
		return nil
	}
	saveErr := c.store.saveCurrent(record)
	var historyErr error
	if saveErr == nil {
		historyErr = c.store.appendHistory(record)
	}
	c.cancel = nil
	c.current = &record
	// Remove recovery inputs only after the terminal record is durable. If that
	// write fails, the live Manager can still report the terminal state while a
	// later restart reconciles the retained renderer result safely.
	if saveErr == nil {
		for _, path := range cleanupPaths {
			_ = os.Remove(path)
		}
	}
	if c.onComplete != nil {
		c.onComplete(record, revision)
	}
	if saveErr != nil {
		return saveErr
	}
	return historyErr
}

func operationSnapshotRevision(snapshotPath string) string {
	raw, err := os.ReadFile(snapshotPath)
	if err != nil {
		return ""
	}
	if _, state := decodeConfigDocument(raw); state != "ready" {
		return ""
	}
	return configRevision(raw, true)
}

func (c *operationCoordinator) setRunning(id string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.current == nil || c.current.ID != id || c.current.State != "queued" {
		return
	}
	c.current.State = "running"
	_ = c.store.saveCurrent(*c.current)
}

func (c *operationCoordinator) Current() *OperationRecord {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if c.current == nil {
		return nil
	}
	copy := *c.current
	copy.GeneratedPreviewIDs = append([]string{}, c.current.GeneratedPreviewIDs...)
	return &copy
}

func (c *operationCoordinator) Get(id string) (OperationRecord, error) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if c.current != nil && c.current.ID == id {
		copy := *c.current
		copy.GeneratedPreviewIDs = append([]string{}, c.current.GeneratedPreviewIDs...)
		return copy, nil
	}
	for _, record := range c.store.readHistory() {
		if record.ID == id {
			return record, nil
		}
	}
	return OperationRecord{}, ErrOperationNotFound
}

func (c *operationCoordinator) History() OperationHistory {
	c.mu.Lock()
	defer c.mu.Unlock()
	_ = c.store.pruneHistory()
	records := c.store.readHistory()
	return OperationHistory{
		Operations:      records,
		MaximumEntries:  operationHistoryLimit,
		RetentionPolicy: operationRetention,
	}
}

func (c *operationCoordinator) Cancel(id string) (OperationRecord, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.current == nil || c.current.ID != id {
		return OperationRecord{}, ErrOperationNotFound
	}
	if !operationActive(c.current.State) {
		return OperationRecord{}, ErrOperationTerminal
	}
	if !c.current.Cancellable {
		return OperationRecord{}, ErrOperationNotCancellable
	}
	c.current.State = "cancelling"
	c.current.Cancellable = false
	_ = c.store.saveCurrent(*c.current)
	if c.cancel != nil {
		c.cancel()
	}
	return *c.current, nil
}

func (c *operationCoordinator) snapshotPath(id string) string {
	return filepath.Join(c.dataDir, "operation-"+id+".config.json")
}

func (c *operationCoordinator) resultPath(id string) string {
	return filepath.Join(c.dataDir, "operation-"+id+".result.json")
}

func (c *operationCoordinator) removeStaleSnapshots() {
	entries, err := os.ReadDir(c.dataDir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		name := entry.Name()
		if c.current != nil && operationActive(c.current.State) && strings.HasPrefix(name, "operation-"+c.current.ID+".") {
			continue
		}
		if entry.Type().IsRegular() && strings.HasPrefix(name, "operation-") && (strings.HasSuffix(name, ".config.json") || strings.HasSuffix(name, ".result.json")) {
			_ = os.Remove(filepath.Join(c.dataDir, name))
		}
	}
}

func (s operationStore) readCurrent() *OperationRecord {
	raw, err := os.ReadFile(s.currentPath)
	if err != nil || len(raw) > maximumOperationLine {
		return nil
	}
	var record OperationRecord
	if json.Unmarshal(raw, &record) != nil || !validOperationRecord(record) {
		return nil
	}
	return &record
}

func (s operationStore) saveCurrent(record OperationRecord) error {
	if err := writePrivateJSON(s.currentPath, record); err != nil {
		return fmt.Errorf("save current operation: %w", err)
	}
	return nil
}

func (s operationStore) appendHistory(record OperationRecord) error {
	encoded, err := json.Marshal(record)
	if err != nil {
		return fmt.Errorf("encode operation history: %w", err)
	}
	encoded = append(encoded, '\n')
	if err := writePrivateFile(s.historyPath, encoded, os.O_CREATE|os.O_APPEND); err != nil {
		return fmt.Errorf("append operation history: %w", err)
	}
	return s.pruneHistory()
}

func (s operationStore) readHistory() []OperationRecord {
	file, err := os.Open(s.historyPath)
	if err != nil {
		return []OperationRecord{}
	}
	defer file.Close()
	records := []OperationRecord{}
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 4096), maximumOperationLine)
	for scanner.Scan() {
		var record OperationRecord
		if json.Unmarshal(scanner.Bytes(), &record) == nil && validOperationRecord(record) {
			records = append(records, record)
		}
	}
	sort.SliceStable(records, func(i, j int) bool {
		return records[i].StartedAtUTC > records[j].StartedAtUTC
	})
	return records
}

func (s operationStore) pruneHistory() error {
	records := s.readHistory()
	kept := make([]OperationRecord, 0, len(records))
	for _, record := range records {
		kept = append(kept, record)
		if len(kept) == operationHistoryLimit {
			break
		}
	}
	if len(kept) == len(records) {
		return nil
	}
	sort.SliceStable(kept, func(i, j int) bool {
		return kept[i].StartedAtUTC < kept[j].StartedAtUTC
	})
	var buffer bytes.Buffer
	for _, record := range kept {
		encoded, err := json.Marshal(record)
		if err != nil {
			continue
		}
		buffer.Write(encoded)
		buffer.WriteByte('\n')
	}
	return writePrivateBytes(s.historyPath, buffer.Bytes())
}

func validTautulliUserID(value string) bool {
	if value == "" || len(value) > 20 {
		return false
	}
	id, err := strconv.ParseUint(value, 10, 64)
	return err == nil && id != 0
}

// Tautulli reserves numeric zero for unauthenticated/unknown playback, not a
// newsletter recipient. Keep this separate from the library ID contract.
func reservedTautulliUserID(value string) bool {
	return value != "" && len(value) <= 20 && strings.Trim(value, "0") == ""
}

func validOperationRecord(record OperationRecord) bool {
	return record.SchemaVersion == operationSchemaVersion && record.ID != "" && (record.Type == "preview-all" || record.Type == "cache-warm" || record.Type == "send-test-all" || record.Type == "send-welcome" || record.Type == "send-all") && record.StartedAtUTC != ""
}

func operationActive(state string) bool {
	return state == "queued" || state == "running" || state == "cancelling"
}

func operationSupportCode(id string) string {
	id = strings.ToUpper(strings.ReplaceAll(id, "_", ""))
	if len(id) > 8 {
		id = id[:8]
	}
	return "TW-" + id
}

type previewFingerprint struct {
	modifiedUnixNano int64
	sizeBytes        int64
}

func previewFingerprints(root string) map[string]previewFingerprint {
	previews, _ := listPreviews(root)
	fingerprints := make(map[string]previewFingerprint, len(previews))
	for _, preview := range previews {
		if strings.HasPrefix(strings.ToLower(preview.Name), "preview-all-") {
			fingerprints[preview.ID] = previewFingerprint{modifiedUnixNano: preview.ModifiedUTC.UnixNano(), sizeBytes: preview.SizeBytes}
		}
	}
	return fingerprints
}

func changedPreviewIDs(root string, before map[string]previewFingerprint) []string {
	after := previewFingerprints(root)
	ids := make([]string, 0, len(after))
	for id, fingerprint := range after {
		if previous, exists := before[id]; !exists || previous != fingerprint {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	return ids
}

func writePrivateBytes(path string, content []byte) error {
	temporary, err := os.CreateTemp(filepath.Dir(path), ".manager-private-*.tmp")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(content); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := hardenPrivateFile(temporaryPath); err != nil {
		return err
	}
	return os.Rename(temporaryPath, path)
}
