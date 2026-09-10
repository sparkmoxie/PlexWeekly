package manager

import (
	"context"
	"crypto/subtle"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	sessionCookieName                     = "tautweekly_manager_session"
	windowsManagerSocialImagePath         = "/manager-social-preview.jpg"
	windowsManagerSocialImageRelativePath = "manager-assets/tautweekly-social-preview.jpg"
	windowsManagerBrowserTitle            = "TautWeekly Manager — Your Plex week, delivered."
	windowsManagerSocialTitle             = "TautWeekly — Your Plex week, delivered."
	windowsManagerSocialDescription       = "Create, preview, schedule, and manage personalized weekly Plex recap emails from the password-protected TautWeekly Manager."
	windowsManagerSocialImageAlt          = "TautWeekly product artwork with a weekly Plex recap dashboard."
	windowsManagerDefaultDocumentHead     = "  <title>TautWeekly Manager</title>\n  <link rel=\"icon\" href=\"/favicon.ico\" sizes=\"any\">\n  <link rel=\"apple-touch-icon\" href=\"/tautweekly-icon-180.png\">\n  <link rel=\"manifest\" href=\"/manifest.webmanifest\">"
)

//go:embed web/*
var embeddedWeb embed.FS

type Options struct {
	ListenAddress             string
	DataDir                   string
	TautWeeklyRoot            string
	RuntimeRoot               string
	Version                   string
	RuntimeMode               string
	RuntimeProfile            string
	PackageKind               string
	PackageVersion            string
	HostAdapterVersion        string
	UpdateChannel             string
	RequireAuthentication     bool
	AllowedHosts              []string
	SecureCookies             bool
	Now                       func() time.Time
	operationRunner           operationRunner
	operationCompleted        func(OperationRecord, string)
	scheduleRunner            scheduleMutationRunner
	startupController         startupSettingsController
	updateChecker             updateReleaseChecker
	updateInstaller           updateInstallController
	remoteAccessController    remoteAccessController
	updateMinimumCheckDelay   time.Duration
	updateMinimumFailureDelay time.Duration
	updateMaximumFailureDelay time.Duration
}

type Server struct {
	options             Options
	auth                *authStore
	authLimiter         *attemptLimiter
	configMu            sync.Mutex
	actionStartMu       sync.Mutex
	verificationRunMu   sync.Mutex
	cacheVerificationMu *sync.Mutex
	diagnostics         *diagnosticStore
	discovery           *tautulliDiscoveryStore
	configuration       *configurationStatusStore
	operations          *operationCoordinator
	schedule            *scheduleCoordinator
	startup             startupSettingsController
	updates             *updateCoordinator
	remoteAccess        remoteAccessController
	capabilities        Capabilities
	handler             http.Handler
	bootstrapToken      string
}

// RemoteAccessStatus returns the same sanitized state exposed to the dashboard.
// The Windows notification-area integration uses it without invoking Tailscale
// or exposing a hostname, route, or control-plane detail.
func (s *Server) RemoteAccessStatus(ctx context.Context) TailscaleRemoteAccessStatus {
	return s.remoteAccessStatus(ctx)
}

// EnsurePublicRemoteAccessInactive is used only by trusted local lifecycle
// controls before an explicit application exit. A failed cleanup leaves the
// running Manager and its password boundary in place.
func (s *Server) EnsurePublicRemoteAccessInactive(ctx context.Context) error {
	return cleanupPublicRemoteAccess(ctx, s.remoteAccess)
}

type authRequest struct {
	Token    string `json:"token"`
	Password string `json:"password"`
}

type accessPasswordRequest struct {
	Password string `json:"password"`
}

type accessResponse struct {
	Mode                   string `json:"mode"`
	AuthenticationRequired bool   `json:"authenticationRequired"`
	PasswordConfigured     bool   `json:"passwordConfigured"`
	PasswordLockEnabled    bool   `json:"passwordLockEnabled"`
	PairingRequired        bool   `json:"pairingRequired"`
	RuntimeRequired        bool   `json:"runtimeRequired"`
	CanDisable             bool   `json:"canDisable"`
}

type sessionResponse struct {
	Authenticated bool   `json:"authenticated"`
	CSRFToken     string `json:"csrfToken,omitempty"`
	ExpiresAtUTC  string `json:"expiresAtUtc,omitempty"`
}

type secretRevealRequest struct {
	ExpectedRevision string `json:"expectedRevision"`
	Password         string `json:"password"`
}

type secretRevealResponse struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

type skipConfigurationPreviewsRequest struct {
	ExpectedRevision string `json:"expectedRevision"`
	Reason           string `json:"reason"`
}

type cacheVerificationRequest struct {
	ExpectedRevision string `json:"expectedRevision"`
}

type apiError struct {
	Error struct {
		Code    string            `json:"code"`
		Message string            `json:"message"`
		Fields  map[string]string `json:"fields,omitempty"`
	} `json:"error"`
}

type contextKey string

const sessionContextKey contextKey = "manager-session"

func New(options Options) (*Server, error) {
	if options.Now == nil {
		options.Now = time.Now
	}
	root, err := filepath.Abs(options.TautWeeklyRoot)
	if err != nil {
		return nil, err
	}
	dataDir, err := filepath.Abs(options.DataDir)
	if err != nil {
		return nil, err
	}
	runtimeRoot := options.RuntimeRoot
	if strings.TrimSpace(runtimeRoot) == "" {
		runtimeRoot = root
	}
	runtimeRoot, err = filepath.Abs(runtimeRoot)
	if err != nil {
		return nil, err
	}
	options.TautWeeklyRoot = filepath.Clean(root)
	options.RuntimeRoot = filepath.Clean(runtimeRoot)
	options.DataDir = filepath.Clean(dataDir)
	options.RuntimeMode = normalizedRuntimeMode(options.RuntimeMode)
	if err := normalizeConfigBackups(options.RuntimeRoot); err != nil {
		return nil, fmt.Errorf("normalize configuration backups: %w", err)
	}
	if isManagedServiceRuntimeMode(options.RuntimeMode) {
		options.RequireAuthentication = true
	}
	store, err := newAuthStore(options.DataDir, options.Now, options.RequireAuthentication)
	if err != nil {
		return nil, err
	}
	configuration := newConfigurationStatusStore(options.DataDir, options.Now)
	cacheVerificationMu := &sync.Mutex{}
	options.operationCompleted = func(record OperationRecord, revision string) {
		if !validConfigRevision(revision) {
			return
		}
		editor := ReadConfigEditor(options.RuntimeRoot)
		if editor.State != "ready" || editor.Revision != revision {
			return
		}
		if record.Type == "preview-all" {
			state := "failed"
			summary := "Local preview generation did not complete. Review the Preview operation for its support code."
			if record.State == "succeeded" {
				state = "passed"
				summary = "Six-state local preview generation completed without sending email."
			} else if record.State == "cancelled" {
				state = "skipped"
				summary = "Local preview generation was cancelled before completion."
			}
			_ = configuration.Update(revision, "previews", state, summary)
			return
		}
		if record.Type != "cache-warm" {
			return
		}
		cache := collectDeletedItemCacheStatus(options.RuntimeRoot, false, false, options.Now)
		if !cache.Enabled {
			return
		}
		if record.State != "succeeded" {
			cache.State = "failed"
			cache.Verification = "full"
			cache.Summary = "Deleted-item cache refresh did not inspect every included user and selected-library newsletter item."
			_ = configuration.StoreCache(revision, cache)
			return
		}
		_ = configuration.Update(revision, "cache", "running", "Checking cache storage, bounds, manifests, backup, writability, and artwork integrity locally.")
		cacheVerificationMu.Lock()
		cache = collectDeletedItemCacheStatus(options.RuntimeRoot, true, true, options.Now)
		cacheVerificationMu.Unlock()
		_ = configuration.StoreCache(revision, cache)
	}
	discovery := newTautulliDiscoveryStore(options.DataDir)
	operations, err := newOperationCoordinator(options)
	if err != nil {
		return nil, err
	}
	operations.discovery = discovery
	schedule, err := newScheduleCoordinator(options)
	if err != nil {
		return nil, err
	}
	startup := options.startupController
	if isManagedServiceRuntimeMode(options.RuntimeMode) {
		startup = disabledStartupController{}
	} else if startup == nil {
		startup = newPlatformStartupController(options.TautWeeklyRoot, options.DataDir)
	}
	remoteAccess := options.remoteAccessController
	if remoteAccess == nil {
		remoteAccess = newPlatformRemoteAccessController(options)
	}
	server := &Server{
		options:             options,
		auth:                store,
		authLimiter:         newAttemptLimiter(options.Now),
		diagnostics:         newDiagnosticStore(options.DataDir, options.Now),
		discovery:           discovery,
		cacheVerificationMu: cacheVerificationMu,
		configuration:       configuration,
		operations:          operations,
		schedule:            schedule,
		startup:             startup,
		updates:             newUpdateCoordinator(options),
		remoteAccess:        remoteAccess,
		capabilities:        capabilitiesFor(options),
		bootstrapToken:      store.bootstrapToken,
	}
	server.handler = server.routes()
	return server, nil
}

func (s *Server) Handler() http.Handler {
	return s.handler
}

func (s *Server) BootstrapToken() string {
	return s.bootstrapToken
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health/live", s.handleLiveness)
	mux.HandleFunc("GET /api/v1/setup", s.handleSetup)
	mux.HandleFunc("POST /api/v1/auth/pair", s.handlePair)
	mux.HandleFunc("POST /api/v1/auth/login", s.handleLogin)
	mux.HandleFunc("GET /api/v1/auth/session", s.handleSession)
	mux.HandleFunc("POST /api/v1/auth/logout", s.protected(s.handleLogout, true))
	mux.HandleFunc("GET /api/v1/auth/access", s.protected(s.handleAccess, false))
	mux.HandleFunc("POST /api/v1/auth/access/password", s.protected(s.handleAccessPassword, true))
	mux.HandleFunc("POST /api/v1/auth/access/disable", s.protected(s.handleAccessDisable, true))
	mux.HandleFunc("GET /api/v1/about", s.protected(s.handleAbout, false))
	mux.HandleFunc("GET /api/v1/capabilities", s.protected(s.handleCapabilities, false))
	mux.HandleFunc("GET /api/v1/diagnostics", s.protected(s.handleDiagnostics, false))
	mux.HandleFunc("GET /api/v1/status", s.protected(s.handleStatus, false))
	mux.HandleFunc("GET /api/v1/updates", s.protected(s.handleUpdateStatus, false))
	mux.HandleFunc("POST /api/v1/updates/check", s.protected(s.handleUpdateCheck, true))
	mux.HandleFunc("POST /api/v1/updates/install", s.protected(s.handleUpdateInstall, true))
	mux.HandleFunc("GET /api/v1/startup", s.protected(s.handleStartupSettings, false))
	mux.HandleFunc("PUT /api/v1/startup", s.protected(s.handleUpdateStartupSettings, true))
	mux.HandleFunc("GET /api/v1/remote-access/tailscale", s.protected(s.handleTailscaleRemoteAccessStatus, false))
	mux.HandleFunc("POST /api/v1/remote-access/tailscale/verify", s.protected(s.handleVerifyTailscaleRemoteAccess, true))
	mux.HandleFunc("PUT /api/v1/remote-access/tailscale", s.protected(s.handleUpdateTailscaleRemoteAccess, true))
	mux.HandleFunc("GET /api/v1/config", s.protected(s.handleConfig, false))
	mux.HandleFunc("GET /api/v1/config/editor", s.protected(s.handleConfigEditor, false))
	mux.HandleFunc("GET /api/v1/config/status", s.protected(s.handleConfigurationStatus, false))
	mux.HandleFunc("PUT /api/v1/config", s.protected(s.handleSaveConfig, true))
	mux.HandleFunc("POST /api/v1/config/status/previews/skipped", s.protected(s.handleSkipConfigurationPreviews, true))
	mux.HandleFunc("POST /api/v1/config/secrets/{name}/reveal", s.protected(s.handleRevealConfigSecret, true))
	mux.HandleFunc("GET /api/v1/config/backups", s.protected(s.handleConfigBackups, false))
	mux.HandleFunc("POST /api/v1/config/backups/{id}/restore", s.protected(s.handleRestoreConfig, true))
	mux.HandleFunc("DELETE /api/v1/config/backups/{id}", s.protected(s.handleDeleteConfigBackup, true))
	mux.HandleFunc("GET /api/v1/checks/integrations", s.protected(s.handleIntegrationCheckState, false))
	mux.HandleFunc("POST /api/v1/checks/integrations", s.protected(s.handleRunIntegrationCheck, true))
	mux.HandleFunc("POST /api/v1/checks/smtp-network", s.protected(s.handleRunSMTPNetworkCheck, true))
	mux.HandleFunc("POST /api/v1/checks/deleted-item-cache", s.protected(s.handleRunDeletedItemCacheCheck, true))
	mux.HandleFunc("GET /api/v1/discovery/tautulli", s.protected(s.handleTautulliDiscoveryState, false))
	mux.HandleFunc("POST /api/v1/discovery/tautulli", s.protected(s.handleTautulliDiscovery, true))
	mux.HandleFunc("POST /api/v1/operations", s.protected(s.handleCreateOperation, true))
	mux.HandleFunc("GET /api/v1/operations/current", s.protected(s.handleCurrentOperation, false))
	mux.HandleFunc("GET /api/v1/operations/{id}", s.protected(s.handleGetOperation, false))
	mux.HandleFunc("POST /api/v1/operations/{id}/cancel", s.protected(s.handleCancelOperation, true))
	mux.HandleFunc("GET /api/v1/history", s.protected(s.handleOperationHistory, false))
	mux.HandleFunc("GET /api/v1/schedule/operation", s.protected(s.handleScheduleOperation, false))
	mux.HandleFunc("POST /api/v1/schedule/{action}", s.protected(s.handleScheduleMutation, true))
	mux.HandleFunc("GET /api/v1/previews", s.protected(s.handlePreviews, false))
	mux.HandleFunc("GET /preview/{id}", s.protected(s.handlePreview, false))
	mux.HandleFunc("GET /preview-content/{asset...}", s.protected(s.handlePreviewAsset, false))
	mux.Handle("/", s.staticHandler())
	return s.securityHeaders(mux)
}

func (s *Server) staticHandler() http.Handler {
	webRoot, err := fs.Sub(embeddedWeb, "web")
	if err != nil {
		panic(err)
	}
	indexDocument, err := fs.ReadFile(webRoot, "index.html")
	if err != nil {
		panic(err)
	}
	files := http.FileServer(http.FS(webRoot))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			writeAPIError(w, http.StatusMethodNotAllowed, "method-not-allowed", "Method is not allowed.")
			return
		}
		cleaned := path.Clean(r.URL.Path)
		if strings.Contains(cleaned, "..") {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		if s.capabilities.RuntimeMode == runtimeModeWindows || publicRemoteAccessSupported(s.remoteAccess) {
			if cleaned == "/" || cleaned == "/index.html" {
				document, ok := s.windowsManagerIndexDocument(r, indexDocument)
				if !ok {
					http.NotFound(w, r)
					return
				}
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
				w.Header().Set("Content-Length", strconv.Itoa(len(document)))
				w.WriteHeader(http.StatusOK)
				if r.Method == http.MethodGet {
					_, _ = w.Write(document)
				}
				return
			}
			if cleaned == windowsManagerSocialImagePath {
				s.serveWindowsManagerSocialImage(w, r)
				return
			}
			if cleaned == "/favicon.ico" {
				w.Header().Set("Content-Type", "image/x-icon")
			}
		}
		files.ServeHTTP(w, r)
	})
}

func (s *Server) windowsManagerIndexDocument(r *http.Request, source []byte) ([]byte, bool) {
	pageURL, ok := s.requestAbsoluteURL(r, "/")
	if !ok {
		return nil, false
	}
	imageURL, ok := s.requestAbsoluteURL(r, windowsManagerSocialImagePath)
	if !ok {
		return nil, false
	}
	pageURL = html.EscapeString(pageURL)
	imageURL = html.EscapeString(imageURL)
	secureImage := ""
	if s.remoteRequestIsSecure(r) {
		secureImage = fmt.Sprintf("\n  <meta property=\"og:image:secure_url\" content=\"%s\">", imageURL)
	}
	replacement := fmt.Sprintf(`  <title>%s</title>
  <meta name="application-name" content="TautWeekly Manager">
  <meta name="description" content="%s">
  <meta name="theme-color" content="#080909">
  <meta name="robots" content="noindex, nofollow, noarchive">
  <link rel="canonical" href="%s">
  <meta property="og:title" content="%s">
  <meta property="og:type" content="website">
  <meta property="og:image" content="%s">
  <meta property="og:url" content="%s">%s
  <meta property="og:image:type" content="image/jpeg">
  <meta property="og:image:width" content="1280">
  <meta property="og:image:height" content="640">
  <meta property="og:image:alt" content="%s">
  <meta property="og:description" content="%s">
  <meta property="og:site_name" content="TautWeekly">
  <meta property="og:locale" content="en_US">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="%s">
  <meta name="twitter:description" content="%s">
  <meta name="twitter:image" content="%s">
  <meta name="twitter:image:alt" content="%s">
  <link rel="icon" href="/favicon.ico" type="image/x-icon" sizes="16x16 24x24 32x32">
  <link rel="icon" href="/tautweekly-icon-192.png" type="image/png" sizes="192x192">
  <link rel="apple-touch-icon" href="/tautweekly-icon-180.png" sizes="180x180">
  <link rel="manifest" href="/manifest.webmanifest">`,
		windowsManagerBrowserTitle,
		windowsManagerSocialDescription,
		pageURL,
		windowsManagerSocialTitle,
		imageURL,
		pageURL,
		secureImage,
		windowsManagerSocialImageAlt,
		windowsManagerSocialDescription,
		windowsManagerSocialTitle,
		windowsManagerSocialDescription,
		imageURL,
		windowsManagerSocialImageAlt,
	)
	document := strings.Replace(string(source), windowsManagerDefaultDocumentHead, replacement, 1)
	if document == string(source) {
		return nil, false
	}
	return []byte(document), true
}

func (s *Server) requestAbsoluteURL(r *http.Request, requestPath string) (string, bool) {
	scheme := "http"
	if s.remoteRequestIsSecure(r) {
		scheme = "https"
	}
	authority, ok := canonicalAuthority(r.Host, scheme)
	if !ok {
		return "", false
	}
	host := authority.host
	if strings.Contains(host, ":") {
		host = "[" + host + "]"
	}
	defaultPort := "80"
	if scheme == "https" {
		defaultPort = "443"
	}
	if authority.port != defaultPort {
		host = net.JoinHostPort(authority.host, authority.port)
	}
	return (&url.URL{Scheme: scheme, Host: host, Path: requestPath}).String(), true
}

func (s *Server) serveWindowsManagerSocialImage(w http.ResponseWriter, r *http.Request) {
	assetPath := filepath.Join(s.options.TautWeeklyRoot, filepath.FromSlash(windowsManagerSocialImageRelativePath))
	payload, err := os.ReadFile(assetPath)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Content-Length", strconv.Itoa(len(payload)))
	w.WriteHeader(http.StatusOK)
	if r.Method == http.MethodGet {
		_, _ = w.Write(payload)
	}
}

func (s *Server) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !s.allowedHost(r.Host) {
			writeAPIError(w, http.StatusBadRequest, "invalid-host", "Host is not allowed.")
			return
		}
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=()")
		if s.remoteRequestIsSecure(r) {
			w.Header().Set("Strict-Transport-Security", "max-age=31536000")
		}
		if !strings.HasPrefix(r.URL.Path, "/preview/") {
			w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
			w.Header().Set("X-Frame-Options", "DENY")
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) allowedHost(value string) bool {
	authority, ok := canonicalAuthority(value, "http")
	if !ok {
		return false
	}
	host := authority.host
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	if ip != nil {
		return ip.IsLoopback() || isContainerRuntimeMode(s.capabilities.RuntimeMode)
	}
	if s.remoteHostAllowed(host) {
		return true
	}
	if !isManagedServiceRuntimeMode(s.capabilities.RuntimeMode) {
		return false
	}
	for _, allowed := range s.options.AllowedHosts {
		allowedAuthority, valid := canonicalAuthority(strings.TrimSpace(allowed), "http")
		if valid && allowedAuthority.host == host {
			return true
		}
	}
	return false
}

func (s *Server) protected(next http.HandlerFunc, mutation bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		cookie, err := r.Cookie(sessionCookieName)
		if err != nil {
			writeAPIError(w, http.StatusUnauthorized, "authentication-required", "Authentication is required.")
			return
		}
		current, ok := s.auth.authenticate(cookie.Value)
		if !ok {
			writeAPIError(w, http.StatusUnauthorized, "session-expired", "Session is missing or expired.")
			return
		}
		if mutation {
			if rejectionCode := s.originRejectionCode(r); rejectionCode != "" {
				writeAPIError(w, http.StatusForbidden, rejectionCode, "Request origin is not allowed.")
				return
			}
			provided := r.Header.Get("X-CSRF-Token")
			if subtle.ConstantTimeCompare([]byte(provided), []byte(current.CSRFToken)) != 1 {
				writeAPIError(w, http.StatusForbidden, "csrf-rejected", "Request verification failed.")
				return
			}
		}
		ctx := context.WithValue(r.Context(), sessionContextKey, current)
		next(w, r.WithContext(ctx))
	}
}

func (s *Server) originRejectionCode(r *http.Request) string {
	values := r.Header.Values("Origin")
	if len(values) == 0 || len(values) == 1 && values[0] == "" {
		return ""
	}
	if len(values) != 1 || strings.TrimSpace(values[0]) != values[0] || strings.Contains(values[0], ",") {
		return "invalid-origin"
	}
	parsed, err := url.Parse(values[0])
	if err != nil || parsed.Scheme != "http" && parsed.Scheme != "https" || parsed.Opaque != "" || parsed.User != nil || parsed.Path != "" || parsed.RawQuery != "" || parsed.Fragment != "" {
		return "invalid-origin"
	}

	hostProbe, ok := canonicalAuthority(r.Host, "https")
	if !ok {
		return "invalid-origin"
	}
	remoteHost := s.remoteHostAllowed(hostProbe.host)
	remoteHTTPS := remoteHost && hostProbe.port == "443"
	if remoteHost && !remoteHTTPS {
		return "remote-http"
	}
	requestScheme := "http"
	if r.TLS != nil || s.options.SecureCookies || remoteHTTPS {
		requestScheme = "https"
	}
	requestAuthority, ok := canonicalAuthority(r.Host, requestScheme)
	if !ok {
		return "invalid-origin"
	}
	originAuthority, ok := canonicalAuthority(parsed.Host, parsed.Scheme)
	if !ok {
		return "invalid-origin"
	}
	if remoteHTTPS && parsed.Scheme == "http" && originAuthority.host == requestAuthority.host {
		return "remote-http"
	}
	if originAuthority.key != requestAuthority.key {
		return "origin-host-mismatch"
	}
	if parsed.Scheme != requestScheme {
		return "origin-scheme-mismatch"
	}
	return ""
}

type normalizedAuthority struct {
	host string
	key  string
	port string
}

func canonicalAuthority(value, scheme string) (normalizedAuthority, bool) {
	if value == "" || strings.TrimSpace(value) != value || scheme != "http" && scheme != "https" {
		return normalizedAuthority{}, false
	}
	parsed, err := url.Parse("//" + value)
	if err != nil || parsed.User != nil || parsed.Host == "" || parsed.Path != "" || parsed.RawQuery != "" || parsed.Fragment != "" {
		return normalizedAuthority{}, false
	}
	host := strings.ToLower(parsed.Hostname())
	if strings.HasSuffix(host, ".") {
		host = strings.TrimSuffix(host, ".")
	}
	if host == "" || strings.HasSuffix(host, ".") {
		return normalizedAuthority{}, false
	}
	if ip := net.ParseIP(host); ip != nil {
		host = ip.String()
	}
	port := parsed.Port()
	if port == "" {
		if scheme == "https" {
			port = "443"
		} else {
			port = "80"
		}
	} else {
		number, err := strconv.Atoi(port)
		if err != nil || number < 1 || number > 65535 {
			return normalizedAuthority{}, false
		}
		port = strconv.Itoa(number)
	}
	return normalizedAuthority{host: host, key: net.JoinHostPort(host, port), port: port}, true
}

func (s *Server) handleLiveness(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"status": "alive"})
}

func (s *Server) handleSetup(w http.ResponseWriter, _ *http.Request) {
	access := s.accessResponse()
	writeJSON(w, http.StatusOK, map[string]any{
		"paired":                 s.auth.paired(),
		"authenticationRequired": access.AuthenticationRequired,
		"pairingRequired":        access.PairingRequired,
		"runtimeMode":            s.capabilities.RuntimeMode,
		"runtimeProfile":         s.capabilities.RuntimeProfile,
		"networkScope":           s.capabilities.NetworkScope,
	})
}

func (s *Server) handlePair(w http.ResponseWriter, r *http.Request) {
	if !s.authLimiter.allow() {
		writeAPIError(w, http.StatusTooManyRequests, "authentication-limited", "Too many failed attempts. Try again later.")
		return
	}
	var request authRequest
	if err := decodeJSON(r, &request); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid-request", "Pairing request is invalid.")
		return
	}
	current, err := s.auth.pair(request.Token, request.Password)
	if err != nil {
		s.authLimiter.recordFailure()
		writeAPIError(w, http.StatusBadRequest, "pairing-failed", err.Error())
		return
	}
	s.authLimiter.reset()
	s.bootstrapToken = ""
	s.setSessionCookie(w, r, current)
	writeJSON(w, http.StatusCreated, newSessionResponse(current))
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if !s.authLimiter.allow() {
		writeAPIError(w, http.StatusTooManyRequests, "authentication-limited", "Too many failed attempts. Try again later.")
		return
	}
	var request authRequest
	if err := decodeJSON(r, &request); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid-request", "Login request is invalid.")
		return
	}
	current, err := s.auth.login(request.Password)
	if err != nil {
		s.authLimiter.recordFailure()
		writeAPIError(w, http.StatusUnauthorized, "login-failed", "Password is invalid.")
		return
	}
	s.authLimiter.reset()
	s.setSessionCookie(w, r, current)
	writeJSON(w, http.StatusOK, newSessionResponse(current))
}

func (s *Server) handleSession(w http.ResponseWriter, r *http.Request) {
	if cookie, err := r.Cookie(sessionCookieName); err == nil {
		if current, ok := s.auth.authenticate(cookie.Value); ok {
			writeJSON(w, http.StatusOK, newSessionResponse(current))
			return
		}
	}
	if s.auth.authenticationRequired() {
		writeAPIError(w, http.StatusUnauthorized, "authentication-required", "Authentication is required.")
		return
	}
	current, err := s.auth.newSession()
	if err != nil {
		writeAPIError(w, http.StatusInternalServerError, "session-failed", "A local Manager session could not be created.")
		return
	}
	s.setSessionCookie(w, r, current)
	writeJSON(w, http.StatusOK, newSessionResponse(current))
}

func (s *Server) handleAccess(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.accessResponse())
}

func (s *Server) handleAccessPassword(w http.ResponseWriter, r *http.Request) {
	var request accessPasswordRequest
	if err := decodeJSON(r, &request); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid-request", "Manager access request is invalid.")
		return
	}
	current, _ := r.Context().Value(sessionContextKey).(session)
	if err := s.auth.setPasswordLockForSession(request.Password, current.Token); err != nil {
		writeAPIError(w, http.StatusUnprocessableEntity, "password-invalid", err.Error())
		return
	}
	s.bootstrapToken = ""
	writeJSON(w, http.StatusOK, s.accessResponse())
}

func (s *Server) handleAccessDisable(w http.ResponseWriter, r *http.Request) {
	// Password disable may first require the same explicit Windows approval and
	// exact Funnel verification as the remote-access controls.
	_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(tailscaleResponseTimeout))
	if err := cleanupPublicRemoteAccess(r.Context(), s.remoteAccess); err != nil {
		s.recordDiagnostic("remote-access", "warning", "tailscale-password-disable-blocked")
		writeAPIError(w, http.StatusConflict, "funnel-shutdown-required", "The password lock stayed enabled because TautWeekly could not verify that its public Funnel was off. Restore Tailscale, approve the shutdown, and try again.")
		return
	}
	if err := s.auth.disablePasswordLock(); err != nil {
		writeAPIError(w, http.StatusConflict, "password-required", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, s.accessResponse())
}

func (s *Server) accessResponse() accessResponse {
	required := s.auth.authenticationRequired()
	mode := "trusted-local"
	if required {
		mode = "password"
	}
	return accessResponse{
		Mode:                   mode,
		AuthenticationRequired: required,
		PasswordConfigured:     s.auth.passwordConfigured(),
		PasswordLockEnabled:    s.auth.localPasswordLockEnabled(),
		PairingRequired:        s.auth.pairingRequired(),
		RuntimeRequired:        s.auth.runtimeRequired,
		CanDisable:             !s.auth.runtimeRequired,
	}
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	cookie, _ := r.Cookie(sessionCookieName)
	if cookie != nil {
		s.auth.logout(cookie.Value)
	}
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookieName,
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
		Secure:   s.remoteRequestIsSecure(r),
		MaxAge:   -1,
	})
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAbout(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"name":           "TautWeekly Manager",
		"version":        s.options.Version,
		"packageVersion": readPackageVersion(s.options.TautWeeklyRoot),
		"mode":           s.capabilities.RuntimeMode + "-manager",
	})
}

func (s *Server) handleCapabilities(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.capabilities)
}

func (s *Server) handleDiagnostics(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.diagnostics.History())
}

func (s *Server) recordDiagnostic(area, outcome, code string) {
	s.diagnostics.Record(area, outcome, code)
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, CollectStatus(r.Context(), s.options))
}

func (s *Server) handleConfig(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, ReadRedactedConfig(s.options.RuntimeRoot))
}

func (s *Server) configEditorView() ConfigEditorView {
	editor := ReadConfigEditor(s.options.RuntimeRoot)
	if editor.State != "unconfigured" || s.capabilities.RuntimeMode != runtimeModeMac {
		return editor
	}
	for index := range editor.Fields {
		field := &editor.Fields[index]
		if field.Name != "TautulliUrl" {
			continue
		}
		field.Value = "http://host.docker.internal:8181"
		field.Placeholder = "http://host.docker.internal:8181"
		field.Help = "For Tautulli running on this Mac, use host.docker.internal. Another server must use an address reachable from Docker Desktop. Verification runs after a successful save."
		break
	}
	return editor
}

func (s *Server) handleConfigEditor(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.configEditorView())
}

func (s *Server) handleConfigurationStatus(w http.ResponseWriter, _ *http.Request) {
	editor := ReadConfigEditor(s.options.RuntimeRoot)
	if editor.State != "ready" {
		writeJSON(w, http.StatusOK, unavailableConfigurationStatus())
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, s.configurationStatusWithCache(editor.Revision))
}

func (s *Server) configurationStatusWithCache(revision string) ConfigurationStatus {
	status := s.configuration.Load(revision)
	if status.Cache != nil {
		return status
	}
	cache := collectDeletedItemCacheStatus(s.options.RuntimeRoot, false, false, s.options.Now)
	status.Cache = &cache
	step, exists := status.Steps["cache"]
	if !exists || (step.State != "waiting" && step.State != "running") {
		status.Steps["cache"] = cache.configurationStep()
	}
	return status
}

func (s *Server) handleRunDeletedItemCacheCheck(w http.ResponseWriter, r *http.Request) {
	var request cacheVerificationRequest
	if err := decodeJSON(r, &request); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid-request", "Deleted-item cache verification request is invalid.")
		return
	}
	if !s.cacheVerificationMu.TryLock() {
		writeAPIError(w, http.StatusConflict, "cache-verification-running", "Another deleted-item cache verification is already running.")
		return
	}
	defer s.cacheVerificationMu.Unlock()
	editor := ReadConfigEditor(s.options.RuntimeRoot)
	if editor.State != "ready" || request.ExpectedRevision != editor.Revision {
		writeAPIError(w, http.StatusConflict, "config-conflict", "Configuration changed before the deleted-item cache check could run.")
		return
	}
	s.updateConfigurationStep(request.ExpectedRevision, "cache", "running", "Checking cache storage, bounds, manifests, backup, writability, and artwork integrity locally.")
	status := collectDeletedItemCacheStatus(s.options.RuntimeRoot, true, true, s.options.Now)
	if err := s.configuration.StoreCache(request.ExpectedRevision, status); err != nil {
		writeAPIError(w, http.StatusInternalServerError, "cache-status-write-failed", "Deleted-item cache verification completed, but its aggregate result could not be retained.")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, status)
}

func (s *Server) handleSkipConfigurationPreviews(w http.ResponseWriter, r *http.Request) {
	var request skipConfigurationPreviewsRequest
	if err := decodeJSON(r, &request); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid-request", "Configuration preview status request is invalid.")
		return
	}
	summary := ""
	switch request.Reason {
	case "metadata-not-ready":
		summary = "Metadata readiness was not confirmed. Complete the recommended refreshes, then validate and save again."
	case "discovery-failed":
		summary = "Preview generation was skipped because Tautulli choices could not be refreshed. Review the discovery result, then use Refresh Tautulli choices to continue without another save."
	case "choices-unavailable":
		summary = "Preview generation was skipped because no retained Tautulli choices are available. Refresh Tautulli choices to continue without another save."
	case "owner-not-found":
		summary = "Tautulli did not expose one unambiguous owner or administrator. Choose a user under Previews to run it manually."
	case "operation-active":
		summary = "Another Manager or schedule operation was active. Generate previews manually after it finishes."
	default:
		writeAPIError(w, http.StatusUnprocessableEntity, "invalid-preview-status-reason", "Choose a supported preview status reason.")
		return
	}
	editor := ReadConfigEditor(s.options.RuntimeRoot)
	if editor.State != "ready" || editor.Revision != request.ExpectedRevision {
		writeAPIError(w, http.StatusConflict, "config-conflict", "Configuration changed before preview status could be retained.")
		return
	}
	s.updateConfigurationStep(request.ExpectedRevision, "previews", "skipped", summary)
	writeJSON(w, http.StatusOK, s.configurationStatusWithCache(request.ExpectedRevision))
}

func (s *Server) updateConfigurationStep(revision, name, state, summary string) {
	editor := ReadConfigEditor(s.options.RuntimeRoot)
	if editor.State != "ready" || editor.Revision != revision {
		return
	}
	if err := s.configuration.Update(revision, name, state, summary); err != nil {
		s.recordDiagnostic("configuration", "warning", "config-status-write-failed")
	}
}

func (s *Server) handleRevealConfigSecret(w http.ResponseWriter, r *http.Request) {
	if !s.authLimiter.allow() {
		writeAPIError(w, http.StatusTooManyRequests, "authentication-limited", "Too many failed attempts. Try again later.")
		return
	}
	var request secretRevealRequest
	if err := decodeJSON(r, &request); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid-request", "Secret reveal request is invalid.")
		return
	}
	if s.auth.authenticationRequired() && !s.auth.verifyPassword(request.Password) {
		s.authLimiter.recordFailure()
		writeAPIError(w, http.StatusUnauthorized, "reauthentication-failed", "Administrator password is invalid.")
		return
	}
	s.authLimiter.reset()

	name := r.PathValue("name")
	s.configMu.Lock()
	value, err := ReadConfigSecret(s.options.RuntimeRoot, name, request.ExpectedRevision)
	s.configMu.Unlock()
	switch {
	case errors.Is(err, ErrConfigConflict):
		writeAPIError(w, http.StatusConflict, "config-conflict", "Configuration changed after this form was loaded. Refresh before revealing a secret.")
		return
	case errors.Is(err, ErrConfigInvalid):
		writeAPIError(w, http.StatusConflict, "config-invalid-source", "The existing config.json is invalid or unreadable.")
		return
	case errors.Is(err, ErrConfigSecretUnsupported):
		writeAPIError(w, http.StatusNotFound, "secret-not-found", "The requested secret is unavailable.")
		return
	case errors.Is(err, ErrConfigSecretNotConfigured):
		writeAPIError(w, http.StatusNotFound, "secret-not-configured", "The requested secret is not configured.")
		return
	case err != nil:
		writeAPIError(w, http.StatusInternalServerError, "secret-reveal-failed", "The requested secret could not be revealed safely.")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, secretRevealResponse{Name: name, Value: value})
}

func (s *Server) handleSaveConfig(w http.ResponseWriter, r *http.Request) {
	var request ConfigSaveRequest
	if err := decodeJSON(r, &request); err != nil {
		s.recordDiagnostic("configuration", "failed", "config-request-invalid")
		writeAPIError(w, http.StatusBadRequest, "invalid-request", "Configuration request is invalid.")
		return
	}
	s.configMu.Lock()
	defer s.configMu.Unlock()
	result, fieldErrors, err := SaveConfig(s.options.RuntimeRoot, request, s.options.Now)
	if errors.Is(err, ErrConfigConflict) {
		s.recordDiagnostic("configuration", "warning", "config-conflict")
		writeAPIError(w, http.StatusConflict, "config-conflict", "Configuration changed after this form was loaded. Refresh and review the latest values.")
		return
	}
	if errors.Is(err, ErrConfigInvalid) {
		s.recordDiagnostic("configuration", "failed", "config-invalid-source")
		writeAPIError(w, http.StatusConflict, "config-invalid-source", "The existing config.json is invalid or unreadable and was not replaced.")
		return
	}
	if err != nil {
		s.recordDiagnostic("configuration", "failed", "config-save-failed")
		writeAPIError(w, http.StatusInternalServerError, "config-save-failed", "Configuration could not be saved safely.")
		return
	}
	if len(fieldErrors) > 0 {
		s.recordDiagnostic("configuration", "warning", "config-validation-failed")
		writeAPIFieldErrors(w, http.StatusUnprocessableEntity, "config-validation-failed", "Review the highlighted configuration fields.", fieldErrors)
		return
	}
	if result.Saved {
		if !result.PostSave.RunDiscovery {
			retained, rebaseErr := s.discovery.Rebase(result.PreviousRevision, result.Editor.Revision)
			result.PostSave.RetainedDiscovery = retained
			if rebaseErr != nil {
				s.recordDiagnostic("configuration", "warning", "discovery-rebase-failed")
			}
		}
		if err := s.configuration.Rebase(result.PreviousRevision, result.Editor.Revision, &result.PostSave); err != nil {
			s.recordDiagnostic("configuration", "warning", "config-status-write-failed")
		}
	} else {
		s.recordDiagnostic("configuration", "passed", "config-unchanged")
		writeJSON(w, http.StatusOK, result)
		return
	}
	s.recordDiagnostic("configuration", "passed", "config-saved")
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleConfigBackups(w http.ResponseWriter, _ *http.Request) {
	s.configMu.Lock()
	defer s.configMu.Unlock()
	writeJSON(w, http.StatusOK, ListConfigBackups(s.options.RuntimeRoot))
}

func (s *Server) handleRestoreConfig(w http.ResponseWriter, r *http.Request) {
	var request ConfigRestoreRequest
	if err := decodeJSON(r, &request); err != nil {
		s.recordDiagnostic("recovery", "failed", "backup-request-invalid")
		writeAPIError(w, http.StatusBadRequest, "invalid-request", "Backup restore request is invalid.")
		return
	}
	s.configMu.Lock()
	defer s.configMu.Unlock()
	result, fieldErrors, err := RestoreConfigBackup(s.options.RuntimeRoot, r.PathValue("id"), request.ExpectedRevision, s.options.Now)
	switch {
	case errors.Is(err, ErrBackupNotFound):
		s.recordDiagnostic("recovery", "warning", "backup-not-found")
		writeAPIError(w, http.StatusNotFound, "backup-not-found", "The selected configuration backup is unavailable.")
		return
	case errors.Is(err, ErrConfigConflict):
		s.recordDiagnostic("recovery", "warning", "config-conflict")
		writeAPIError(w, http.StatusConflict, "config-conflict", "Configuration changed after this backup list was loaded. Refresh before restoring.")
		return
	case errors.Is(err, ErrConfigInvalid):
		s.recordDiagnostic("recovery", "failed", "config-invalid-source")
		writeAPIError(w, http.StatusConflict, "config-invalid-source", "The current config.json is invalid or unreadable and was not replaced.")
		return
	case errors.Is(err, ErrBackupInvalid) && len(fieldErrors) > 0:
		s.recordDiagnostic("recovery", "warning", "backup-validation-failed")
		writeAPIFieldErrors(w, http.StatusUnprocessableEntity, "backup-validation-failed", "The selected backup does not pass the current configuration schema.", fieldErrors)
		return
	case errors.Is(err, ErrBackupInvalid):
		s.recordDiagnostic("recovery", "failed", "backup-invalid")
		writeAPIError(w, http.StatusUnprocessableEntity, "backup-invalid", "The selected backup is not a valid configuration document.")
		return
	case err != nil:
		s.recordDiagnostic("recovery", "failed", "backup-restore-failed")
		writeAPIError(w, http.StatusInternalServerError, "backup-restore-failed", "The backup could not be restored safely.")
		return
	}
	if err := s.configuration.ResetNotRun(result.Editor.Revision); err != nil {
		s.recordDiagnostic("configuration", "warning", "config-status-write-failed")
	}
	s.recordDiagnostic("recovery", "passed", "backup-restored")
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleDeleteConfigBackup(w http.ResponseWriter, r *http.Request) {
	s.configMu.Lock()
	defer s.configMu.Unlock()
	result, err := DeleteConfigBackup(s.options.RuntimeRoot, r.PathValue("id"))
	switch {
	case errors.Is(err, ErrBackupNotFound):
		s.recordDiagnostic("recovery", "warning", "backup-not-found")
		writeAPIError(w, http.StatusNotFound, "backup-not-found", "The selected configuration backup is unavailable.")
		return
	case err != nil:
		s.recordDiagnostic("recovery", "failed", "backup-delete-failed")
		writeAPIError(w, http.StatusInternalServerError, "backup-delete-failed", "The backup could not be deleted safely.")
		return
	}
	s.recordDiagnostic("recovery", "passed", "backup-deleted")
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleIntegrationCheckState(w http.ResponseWriter, _ *http.Request) {
	editor := ReadConfigEditor(s.options.RuntimeRoot)
	status := s.configuration.Load(editor.Revision)
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"last": status.LastVerification, "smtp": status.LastSMTPCheck})
}

func (s *Server) handleRunIntegrationCheck(w http.ResponseWriter, r *http.Request) {
	var request RealIntegrationCheckRequest
	if err := decodeJSON(r, &request); err != nil {
		s.recordDiagnostic("lan-verification", "failed", "verification-request-invalid")
		writeAPIError(w, http.StatusBadRequest, "invalid-request", "Integration verification request is invalid.")
		return
	}
	if !s.verificationRunMu.TryLock() {
		writeAPIError(w, http.StatusConflict, "verification-running", "An integration verification is already running.")
		return
	}
	defer s.verificationRunMu.Unlock()
	s.updateConfigurationStep(request.ExpectedRevision, "lan", "running", "Testing the saved Tautulli and direct Plex endpoints.")
	result, err := RunRealIntegrationCheck(r.Context(), s.options.RuntimeRoot, request, s.options.Now)
	switch {
	case errors.Is(err, ErrRealCheckConfirmation):
		s.updateConfigurationStep(request.ExpectedRevision, "lan", "skipped", "Connection verification requires explicit confirmation before contacting saved services.")
		writeAPIError(w, http.StatusUnprocessableEntity, "verification-confirmation-required", "Confirm that this test may contact the configured services.")
		return
	case errors.Is(err, ErrRealCheckNotReady):
		s.updateConfigurationStep(request.ExpectedRevision, "lan", "failed", "Configuration is incomplete, so Tautulli and Plex could not be verified.")
		s.recordDiagnostic("lan-verification", "warning", "verification-not-ready")
		writeAPIError(w, http.StatusConflict, "verification-not-ready", "Complete and save configuration before running connection checks.")
		return
	case errors.Is(err, ErrConfigConflict):
		s.updateConfigurationStep(request.ExpectedRevision, "lan", "failed", "Configuration changed before Tautulli and Plex verification could finish.")
		s.recordDiagnostic("lan-verification", "warning", "verification-conflict")
		writeAPIError(w, http.StatusConflict, "config-conflict", "Configuration changed after this verification page was loaded. Refresh before testing.")
		return
	case err != nil:
		s.updateConfigurationStep(request.ExpectedRevision, "lan", "failed", "Tautulli and Plex verification could not be completed safely.")
		s.recordDiagnostic("lan-verification", "failed", "verification-failed")
		writeAPIError(w, http.StatusInternalServerError, "verification-failed", "Integration verification could not be completed safely.")
		return
	}
	s.configMu.Lock()
	if ReadConfigEditor(s.options.RuntimeRoot).Revision != result.ConfigRevision {
		s.configMu.Unlock()
		s.updateConfigurationStep(request.ExpectedRevision, "lan", "failed", "Configuration changed while Tautulli and Plex verification was running.")
		s.recordDiagnostic("lan-verification", "warning", "verification-config-changed")
		writeAPIError(w, http.StatusConflict, "config-changed-during-verification", "Configuration changed while the real connection test was running. Review the new settings and run it again.")
		return
	}
	if err := s.configuration.StoreIntegrationCheck(result.ConfigRevision, result); err != nil {
		s.recordDiagnostic("lan-verification", "warning", "verification-status-write-failed")
	}
	s.configMu.Unlock()
	lanState, lanSummary, diagnosticCode := integrationCheckPresentation(result)
	s.updateConfigurationStep(result.ConfigRevision, "lan", lanState, lanSummary)
	s.recordDiagnostic("lan-verification", diagnosticOutcome(lanState), diagnosticCode)
	writeJSON(w, http.StatusOK, result)
}

func integrationCheckPresentation(result IntegrationCheckResult) (state, summary, diagnosticCode string) {
	state = result.Overall
	if state != "passed" && state != "warning" && state != "failed" {
		state = "warning"
	}

	failedTautulli := false
	failedPlex := false
	plexSkipped := false
	for _, step := range result.Steps {
		switch {
		case step.Service == "tautulli" && step.State == "failed":
			failedTautulli = true
		case step.Service == "plex" && step.State == "failed":
			failedPlex = true
		case step.Service == "plex" && step.State == "skipped":
			plexSkipped = true
		}
	}

	switch {
	case failedTautulli && failedPlex:
		return "failed", "Tautulli and direct Plex verification failed. Review Verify for the sanitized component results.", "verification-multiple-failed"
	case failedTautulli:
		return "failed", "Tautulli verification failed. Review Verify for the sanitized component result.", "verification-tautulli-failed"
	case failedPlex:
		return "failed", "Direct Plex verification failed. Review Verify for the sanitized component result.", "verification-plex-failed"
	case state == "passed" && plexSkipped:
		return "passed", "Tautulli verification passed. Optional direct Plex verification was skipped because a complete URL and token were not available.", "verification-passed-plex-skipped"
	case state == "passed":
		return "passed", "Tautulli and direct Plex verification passed.", "verification-passed"
	case state == "failed":
		return "failed", "One or more connection checks failed. Review Verify for the sanitized component results.", "verification-result-failed"
	default:
		return "warning", "Connection verification completed with a result that needs review under Verify.", "verification-warning"
	}
}

func (s *Server) handleRunSMTPNetworkCheck(w http.ResponseWriter, r *http.Request) {
	var request SMTPNetworkCheckRequest
	if err := decodeJSON(r, &request); err != nil {
		s.recordDiagnostic("smtp-preflight", "failed", "smtp-request-invalid")
		writeAPIError(w, http.StatusBadRequest, "invalid-request", "SMTP preflight request is invalid.")
		return
	}
	if !s.verificationRunMu.TryLock() {
		writeAPIError(w, http.StatusConflict, "verification-running", "A real network verification or discovery request is already running.")
		return
	}
	defer s.verificationRunMu.Unlock()
	s.updateConfigurationStep(request.ExpectedRevision, "smtp", "running", "Checking SMTP reachability and certificate-validated STARTTLS without authenticating or sending.")
	result, err := RunSMTPNetworkCheck(r.Context(), s.options.RuntimeRoot, request, s.options.Now)
	switch {
	case errors.Is(err, ErrRealCheckConfirmation):
		s.updateConfigurationStep(request.ExpectedRevision, "smtp", "skipped", "SMTP preflight requires explicit confirmation before contacting the saved endpoint.")
		writeAPIError(w, http.StatusUnprocessableEntity, "smtp-confirmation-required", "Confirm that this preflight may contact the saved SMTP endpoint.")
		return
	case errors.Is(err, ErrRealCheckNotReady):
		s.updateConfigurationStep(request.ExpectedRevision, "smtp", "failed", "Configuration is incomplete, so SMTP preflight could not run.")
		s.recordDiagnostic("smtp-preflight", "warning", "smtp-not-ready")
		writeAPIError(w, http.StatusConflict, "smtp-not-ready", "Complete and save configuration before running SMTP preflight.")
		return
	case errors.Is(err, ErrConfigConflict):
		s.updateConfigurationStep(request.ExpectedRevision, "smtp", "failed", "Configuration changed before SMTP preflight could finish.")
		s.recordDiagnostic("smtp-preflight", "warning", "smtp-conflict")
		writeAPIError(w, http.StatusConflict, "config-conflict", "Configuration changed after this verification page was loaded. Refresh before testing SMTP.")
		return
	case err != nil:
		s.updateConfigurationStep(request.ExpectedRevision, "smtp", "failed", "SMTP preflight could not be completed safely.")
		s.recordDiagnostic("smtp-preflight", "failed", "smtp-preflight-failed")
		writeAPIError(w, http.StatusInternalServerError, "smtp-preflight-failed", "SMTP preflight could not be completed safely.")
		return
	}
	s.configMu.Lock()
	if ReadConfigEditor(s.options.RuntimeRoot).Revision != result.ConfigRevision {
		s.configMu.Unlock()
		s.updateConfigurationStep(request.ExpectedRevision, "smtp", "failed", "Configuration changed while SMTP preflight was running.")
		s.recordDiagnostic("smtp-preflight", "warning", "smtp-config-changed")
		writeAPIError(w, http.StatusConflict, "config-changed-during-verification", "Configuration changed while SMTP preflight was running. Review the new settings and run it again.")
		return
	}
	if err := s.configuration.StoreSMTPCheck(result.ConfigRevision, result); err != nil {
		s.recordDiagnostic("smtp-preflight", "warning", "smtp-status-write-failed")
	}
	s.configMu.Unlock()
	smtpState := result.Overall
	if smtpState != "passed" && smtpState != "warning" && smtpState != "failed" {
		smtpState = "warning"
	}
	s.updateConfigurationStep(result.ConfigRevision, "smtp", smtpState, result.Summary)
	s.recordDiagnostic("smtp-preflight", diagnosticOutcome(result.Overall), "smtp-"+diagnosticResultCode(result.Overall))
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleTautulliDiscoveryState(w http.ResponseWriter, _ *http.Request) {
	revision := ReadConfigEditor(s.options.RuntimeRoot).Revision
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"last": s.discovery.Load(revision)})
}

func (s *Server) handleTautulliDiscovery(w http.ResponseWriter, r *http.Request) {
	var request TautulliDiscoveryRequest
	if err := decodeJSON(r, &request); err != nil {
		s.recordDiagnostic("tautulli-discovery", "failed", "discovery-request-invalid")
		writeAPIError(w, http.StatusBadRequest, "invalid-request", "Tautulli discovery request is invalid.")
		return
	}
	if !s.verificationRunMu.TryLock() {
		writeAPIError(w, http.StatusConflict, "verification-running", "A connection verification or discovery request is already running.")
		return
	}
	defer s.verificationRunMu.Unlock()
	s.updateConfigurationStep(request.ExpectedRevision, "choices", "running", "Loading active libraries, users, and explicit owner or administrator roles from Tautulli.")
	result, err := DiscoverTautulliChoices(r.Context(), s.options.RuntimeRoot, request, s.options.Now)
	switch {
	case errors.Is(err, ErrRealCheckConfirmation):
		s.updateConfigurationStep(request.ExpectedRevision, "choices", "skipped", "Tautulli lookup requires explicit confirmation before contacting the saved service.")
		writeAPIError(w, http.StatusUnprocessableEntity, "discovery-confirmation-required", "Confirm that this lookup may contact the configured Tautulli service.")
		return
	case errors.Is(err, ErrRealCheckNotReady):
		s.updateConfigurationStep(request.ExpectedRevision, "choices", "failed", "Configuration is incomplete, so Tautulli libraries and users could not be loaded.")
		s.recordDiagnostic("tautulli-discovery", "warning", "discovery-not-ready")
		writeAPIError(w, http.StatusConflict, "discovery-not-ready", "Save a complete configuration before loading Tautulli choices.")
		return
	case errors.Is(err, ErrConfigConflict):
		s.updateConfigurationStep(request.ExpectedRevision, "choices", "failed", "Configuration changed before Tautulli libraries and users could be loaded.")
		s.recordDiagnostic("tautulli-discovery", "warning", "discovery-conflict")
		writeAPIError(w, http.StatusConflict, "config-conflict", "Configuration changed after this page was loaded. Refresh before loading choices.")
		return
	case errors.Is(err, errLANOnlyDestination):
		s.updateConfigurationStep(request.ExpectedRevision, "choices", "failed", "The saved Tautulli destination is outside the private or loopback network boundary.")
		s.recordDiagnostic("tautulli-discovery", "failed", "discovery-boundary")
		writeAPIError(w, http.StatusUnprocessableEntity, "discovery-boundary", "The configured Tautulli destination is outside the private or loopback network boundary.")
		return
	case err != nil:
		stage := tautulliDiscoveryFailureStage(err)
		retained := s.discovery.Load(request.ExpectedRevision) != nil
		summary, message := failedDiscoveryCopy(stage, err, retained)
		s.updateConfigurationStep(request.ExpectedRevision, "choices", "failed", summary)
		s.recordDiagnostic("tautulli-discovery", "failed", "discovery-"+stage+"-failed")
		writeAPIError(w, http.StatusBadGateway, "discovery-"+stage+"-failed", message)
		return
	}
	s.configMu.Lock()
	if ReadConfigEditor(s.options.RuntimeRoot).Revision != result.ConfigRevision {
		s.configMu.Unlock()
		s.updateConfigurationStep(request.ExpectedRevision, "choices", "failed", "Configuration changed while Tautulli libraries and users were loading.")
		s.recordDiagnostic("tautulli-discovery", "warning", "discovery-config-changed")
		writeAPIError(w, http.StatusConflict, "config-changed-during-discovery", "Configuration changed while Tautulli choices were loading. Refresh and try again.")
		return
	}
	cacheErr := s.discovery.Save(result)
	s.configMu.Unlock()
	if cacheErr != nil {
		s.updateConfigurationStep(result.ConfigRevision, "choices", "warning", "Tautulli libraries and users loaded, but their sanitized local cache could not be updated.")
		s.recordDiagnostic("tautulli-discovery", "warning", "discovery-cache-failed")
	} else {
		s.updateConfigurationStep(result.ConfigRevision, "choices", "passed", fmt.Sprintf("%d active libraries and %d users loaded and retained locally.", len(result.Libraries), len(result.Users)))
		s.recordDiagnostic("tautulli-discovery", "passed", "discovery-completed")
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, result)
}

func failedDiscoveryCopy(stage string, err error, retained bool) (summary, message string) {
	label := discoveryStageLabel(stage)
	summary = "Live Tautulli " + label + " refresh failed."
	if retained {
		summary += " The previous sanitized choices remain retained and usable."
	}
	switch {
	case errors.Is(err, errIntegrationConnection), errors.Is(err, context.DeadlineExceeded):
		message = "Live Tautulli " + label + " refresh failed because the saved service could not be reached before the bounded timeout."
	case errorChainContains(err, "authentication rejected"):
		message = "Live Tautulli " + label + " refresh failed because Tautulli rejected the saved API credential."
	case errorChainContains(err, "unexpected HTTP status"):
		message = "Live Tautulli " + label + " refresh failed because Tautulli returned an unexpected HTTP status."
	case errors.Is(err, errIntegrationResponse):
		message = "Live Tautulli " + label + " refresh failed because neither the primary response nor its table-backed fallback contained usable choices."
	default:
		message = "Live Tautulli " + label + " refresh failed safely."
	}
	message += " Run a fresh Tautulli/Plex check under Verify to compare current connection evidence."
	return summary, message
}

func errorChainContains(err error, fragment string) bool {
	for current := err; current != nil; current = errors.Unwrap(current) {
		if strings.Contains(current.Error(), fragment) {
			return true
		}
	}
	return false
}

func discoveryStageLabel(stage string) string {
	switch stage {
	case "libraries":
		return "library roster"
	case "users":
		return "user roster"
	default:
		return "connection"
	}
}

func (s *Server) handleCreateOperation(w http.ResponseWriter, r *http.Request) {
	var request CreateOperationRequest
	if err := decodeJSON(r, &request); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid-request", "Operation request is invalid.")
		return
	}
	s.actionStartMu.Lock()
	defer s.actionStartMu.Unlock()
	if current := s.schedule.Current(); current != nil && scheduleOperationActive(current.State) {
		if request.Type == "preview-all" {
			s.updateConfigurationStep(request.ExpectedRevision, "previews", "skipped", "A schedule operation was active. Generate previews manually after it finishes.")
		} else if request.Type == "cache-warm" {
			s.updateConfigurationStep(request.ExpectedRevision, "cache", "failed", "Deleted-item cache refresh could not start while a schedule operation was active.")
		}
		writeAPIError(w, http.StatusConflict, "schedule-busy", "Wait for the active schedule change before starting a Manager operation.")
		return
	}
	s.configMu.Lock()
	record, err := s.operations.Start(request)
	s.configMu.Unlock()
	switch {
	case errors.Is(err, ErrOperationConfirmation):
		if request.Type == "preview-all" {
			s.updateConfigurationStep(request.ExpectedRevision, "previews", "skipped", "Preview generation requires explicit confirmation that no email will be sent.")
		}
		message := "Confirm that this operation creates local previews and sends no email."
		if request.Type == "send-test-all" {
			message = "Confirm that this operation sends six real test messages only to the configured TestEmail."
		} else if request.Type == "send-welcome" {
			message = "Confirm that this operation sends one real Manual Welcome newsletter to the selected Tautulli user."
		} else if request.Type == "send-all" {
			message = "Confirm that this operation sends the production newsletter to all currently eligible recipients."
		}
		writeAPIError(w, http.StatusUnprocessableEntity, "operation-confirmation-required", message)
		return
	case errors.Is(err, ErrOperationInvalid):
		if request.Type == "preview-all" {
			s.updateConfigurationStep(request.ExpectedRevision, "previews", "failed", "Preview generation could not start because its user selection was invalid.")
		} else if request.Type == "cache-warm" {
			s.updateConfigurationStep(request.ExpectedRevision, "cache", "failed", "Deleted-item cache refresh could not start because its request was invalid.")
		}
		writeAPIError(w, http.StatusUnprocessableEntity, "operation-invalid", "Choose a supported operation and provide only the inputs required for that operation.")
		return
	case errors.Is(err, ErrOperationNotReady):
		if request.Type == "preview-all" {
			s.updateConfigurationStep(request.ExpectedRevision, "previews", "failed", "Configuration is incomplete, so local previews could not be generated.")
		} else if request.Type == "cache-warm" {
			s.updateConfigurationStep(request.ExpectedRevision, "cache", "failed", "Configuration is incomplete, so deleted-item cache refresh could not start.")
		}
		writeAPIError(w, http.StatusConflict, "operation-not-ready", "Complete and save configuration before starting this operation.")
		return
	case errors.Is(err, ErrOperationUserExcluded):
		if request.Type == "preview-all" {
			s.updateConfigurationStep(request.ExpectedRevision, "previews", "skipped", "The selected user is excluded by the saved recipient policy. Include and save that user before generating previews.")
		}
		writeAPIError(w, http.StatusUnprocessableEntity, "operation-user-excluded", "The selected user is excluded by the saved recipient policy. Uncheck the exclusion and save before previewing, testing, or sending to that user.")
		return
	case errors.Is(err, ErrOperationBusy):
		if request.Type == "preview-all" {
			s.updateConfigurationStep(request.ExpectedRevision, "previews", "skipped", "Another Manager operation was active. Generate previews manually after it finishes.")
		} else if request.Type == "cache-warm" {
			s.updateConfigurationStep(request.ExpectedRevision, "cache", "failed", "Deleted-item cache refresh could not start while another Manager operation was active.")
		}
		writeAPIError(w, http.StatusConflict, "operation-busy", "Another Manager operation is already running.")
		return
	case errors.Is(err, ErrConfigConflict):
		if request.Type == "preview-all" {
			s.updateConfigurationStep(request.ExpectedRevision, "previews", "failed", "Configuration changed before local preview generation could start.")
		} else if request.Type == "cache-warm" {
			s.updateConfigurationStep(request.ExpectedRevision, "cache", "failed", "Configuration changed before deleted-item cache refresh could start.")
		}
		writeAPIError(w, http.StatusConflict, "config-conflict", "Configuration changed after this page was loaded. Refresh before generating previews.")
		return
	case err != nil:
		if request.Type == "preview-all" {
			s.updateConfigurationStep(request.ExpectedRevision, "previews", "failed", "Local preview generation could not be started safely.")
		} else if request.Type == "cache-warm" {
			s.updateConfigurationStep(request.ExpectedRevision, "cache", "failed", "Deleted-item cache refresh could not be started safely.")
		}
		writeAPIError(w, http.StatusInternalServerError, "operation-start-failed", "The Manager operation could not be started safely.")
		return
	}
	if request.Type == "preview-all" {
		s.updateConfigurationStep(request.ExpectedRevision, "previews", "running", "Generating six local preview states without sending email.")
	} else if request.Type == "cache-warm" {
		s.updateConfigurationStep(request.ExpectedRevision, "cache", "running", "Refreshing cache coverage for every included user's selected-library newsletter items.")
	}
	writeJSON(w, http.StatusAccepted, record)
}

func (s *Server) handleCurrentOperation(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"current": s.operations.Current()})
}

func (s *Server) handleGetOperation(w http.ResponseWriter, r *http.Request) {
	record, err := s.operations.Get(r.PathValue("id"))
	if errors.Is(err, ErrOperationNotFound) {
		writeAPIError(w, http.StatusNotFound, "operation-not-found", "The requested operation is unavailable.")
		return
	}
	writeJSON(w, http.StatusOK, record)
}

func (s *Server) handleCancelOperation(w http.ResponseWriter, r *http.Request) {
	record, err := s.operations.Cancel(r.PathValue("id"))
	switch {
	case errors.Is(err, ErrOperationNotFound):
		writeAPIError(w, http.StatusNotFound, "operation-not-found", "The requested operation is unavailable.")
		return
	case errors.Is(err, ErrOperationTerminal):
		writeAPIError(w, http.StatusConflict, "operation-complete", "The operation has already completed.")
		return
	case errors.Is(err, ErrOperationNotCancellable):
		writeAPIError(w, http.StatusConflict, "operation-not-cancellable", "This operation cannot be cancelled safely after it starts.")
		return
	case err != nil:
		writeAPIError(w, http.StatusInternalServerError, "operation-cancel-failed", "The preview operation could not be cancelled safely.")
		return
	}
	writeJSON(w, http.StatusAccepted, record)
}

func (s *Server) handleOperationHistory(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.operations.History())
}

func (s *Server) handleScheduleOperation(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"current": s.schedule.Current()})
}

func (s *Server) handleScheduleMutation(w http.ResponseWriter, r *http.Request) {
	var request ScheduleMutationRequest
	if err := decodeJSON(r, &request); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid-request", "Schedule request is invalid.")
		return
	}
	s.actionStartMu.Lock()
	defer s.actionStartMu.Unlock()
	if current := s.operations.Current(); current != nil && operationActive(current.State) {
		writeAPIError(w, http.StatusConflict, "operation-busy", "Wait for the active Manager operation before changing the schedule.")
		return
	}
	s.configMu.Lock()
	record, err := s.schedule.Start(r.PathValue("action"), request)
	s.configMu.Unlock()
	switch {
	case errors.Is(err, ErrScheduleConfirmation):
		message := "Confirm the selected Windows Task Scheduler change."
		if isManagedServiceRuntimeMode(s.capabilities.RuntimeMode) {
			message = "Confirm the selected embedded scheduler change."
		}
		writeAPIError(w, http.StatusUnprocessableEntity, "schedule-confirmation-required", message)
		return
	case errors.Is(err, ErrScheduleInvalid):
		message := "Choose install, enable, disable, or remove."
		if isManagedServiceRuntimeMode(s.capabilities.RuntimeMode) {
			message = "Choose enable or disable for the embedded scheduler."
		}
		writeAPIError(w, http.StatusUnprocessableEntity, "schedule-action-invalid", message)
		return
	case errors.Is(err, ErrScheduleNotReady):
		writeAPIError(w, http.StatusConflict, "schedule-not-ready", "Complete and save configuration before changing the schedule.")
		return
	case errors.Is(err, ErrScheduleBusy):
		message := "Another schedule change is waiting for elevation or still running."
		if isManagedServiceRuntimeMode(s.capabilities.RuntimeMode) {
			message = "Another embedded scheduler change is still running."
		}
		writeAPIError(w, http.StatusConflict, "schedule-busy", message)
		return
	case errors.Is(err, ErrConfigConflict):
		writeAPIError(w, http.StatusConflict, "config-conflict", "Configuration changed after this schedule view was loaded. Refresh before continuing.")
		return
	case err != nil:
		writeAPIError(w, http.StatusInternalServerError, "schedule-start-failed", "The typed schedule operation could not be started safely.")
		return
	}
	writeJSON(w, http.StatusAccepted, record)
}

func (s *Server) handlePreviews(w http.ResponseWriter, _ *http.Request) {
	previews, _ := listPreviews(s.options.RuntimeRoot)
	writeJSON(w, http.StatusOK, map[string]any{"previews": previews})
}

func (s *Server) handlePreview(w http.ResponseWriter, r *http.Request) {
	_, paths := listPreviews(s.options.RuntimeRoot)
	previewPath, ok := paths[r.PathValue("id")]
	if !ok {
		writeAPIError(w, http.StatusNotFound, "preview-not-found", "Preview is unavailable.")
		return
	}
	servePreview(w, previewPath)
}

func (s *Server) handlePreviewAsset(w http.ResponseWriter, r *http.Request) {
	servePreviewAsset(w, r, s.options.RuntimeRoot, r.PathValue("asset"))
}

func (s *Server) setSessionCookie(w http.ResponseWriter, r *http.Request, current session) {
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookieName,
		Value:    current.Token,
		Path:     "/",
		HttpOnly: true,
		Secure:   s.remoteRequestIsSecure(r),
		SameSite: http.SameSiteStrictMode,
		Expires:  current.ExpiresAt,
		MaxAge:   int(current.ExpiresAt.Sub(s.options.Now()).Seconds()),
	})
}

func newSessionResponse(current session) sessionResponse {
	return sessionResponse{
		Authenticated: true,
		CSRFToken:     current.CSRFToken,
		ExpiresAtUTC:  current.ExpiresAt.UTC().Format(time.RFC3339),
	}
}

func decodeJSON(r *http.Request, target any) error {
	decoder := json.NewDecoder(io.LimitReader(r.Body, (1<<20)+1))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		if err == nil {
			return errors.New("multiple JSON values are not allowed")
		}
		return errors.New("request contains trailing data")
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeAPIError(w http.ResponseWriter, status int, code, message string) {
	var response apiError
	response.Error.Code = code
	response.Error.Message = message
	writeJSON(w, status, response)
}

func writeAPIFieldErrors(w http.ResponseWriter, status int, code, message string, fields map[string]string) {
	var response apiError
	response.Error.Code = code
	response.Error.Message = message
	response.Error.Fields = fields
	writeJSON(w, status, response)
}
