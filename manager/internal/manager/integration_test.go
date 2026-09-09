package manager

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestSMTPNetworkProbeCompletesCertificateValidatedSTARTTLSWithoutAuthentication(t *testing.T) {
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
	}
	certificateDER, err := x509.CreateCertificate(rand.Reader, template, template, &privateKey.PublicKey, privateKey)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := x509.ParseCertificate(certificateDER)
	if err != nil {
		t.Fatal(err)
	}
	serverCertificate := tls.Certificate{Certificate: [][]byte{certificateDER}, PrivateKey: privateKey}
	roots := x509.NewCertPool()
	roots.AddCert(certificate)

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	type fixtureResult struct {
		commands []string
		err      error
	}
	finished := make(chan fixtureResult, 1)
	go func() {
		commands, fixtureErr := serveSTARTTLSFixture(listener, serverCertificate)
		finished <- fixtureResult{commands: commands, err: fixtureErr}
	}()

	config := smtpProbeConfig{
		Host:       "127.0.0.1",
		Port:       listener.Addr().(*net.TCPAddr).Port,
		EnableTLS:  true,
		Timeout:    5 * time.Second,
		ClientName: "tautweekly.local",
	}
	dependencies := defaultSMTPProbeDependencies(config.Timeout)
	dependencies.tlsConfig = func(host string) *tls.Config {
		return &tls.Config{ServerName: host, MinVersion: tls.VersionTLS12, RootCAs: roots}
	}
	if err := probeSMTPNetwork(context.Background(), config, dependencies); err != nil {
		t.Fatal(err)
	}
	select {
	case fixture := <-finished:
		if fixture.err != nil {
			t.Fatal(fixture.err)
		}
		if len(fixture.commands) < 4 || !strings.HasPrefix(fixture.commands[0], "EHLO ") || fixture.commands[1] != "STARTTLS" || !strings.HasPrefix(fixture.commands[2], "EHLO ") || fixture.commands[3] != "QUIT" {
			t.Fatalf("unexpected STARTTLS preflight command sequence: %v", fixture.commands)
		}
		for _, command := range fixture.commands {
			for _, forbidden := range []string{"AUTH", "MAIL FROM", "RCPT TO", "DATA"} {
				if strings.HasPrefix(strings.ToUpper(command), forbidden) {
					t.Fatalf("STARTTLS preflight sent forbidden command %q", command)
				}
			}
		}
	case <-time.After(3 * time.Second):
		t.Fatal("STARTTLS fixture did not complete")
	}
}

func TestSMTPDestinationFailuresDistinguishSyntaxFromUnsafeResolution(t *testing.T) {
	dependencies := smtpProbeDependencies{
		lookupIP: func(context.Context, string, string) ([]net.IP, error) {
			return []net.IP{net.ParseIP("0.0.0.0")}, nil
		},
		dialContext: func(context.Context, string, string) (net.Conn, error) {
			t.Fatal("unsafe destination reached dial step")
			return nil, errors.New("unreachable")
		},
		tlsConfig: func(string) *tls.Config { return &tls.Config{} },
	}
	invalid := smtpProbeConfig{Host: "smtp://smtp.example.com", Port: 587, Timeout: time.Second}
	if err := probeSMTPNetwork(context.Background(), invalid, dependencies); !errors.Is(err, errSMTPHost) {
		t.Fatalf("invalid SMTP syntax classification: got %v", err)
	}
	unsafe := smtpProbeConfig{Host: "smtp.example.com", Port: 587, Timeout: time.Second}
	if err := probeSMTPNetwork(context.Background(), unsafe, dependencies); !errors.Is(err, errSMTPUnsafeAddress) {
		t.Fatalf("unsafe SMTP resolution classification: got %v", err)
	}
	if !validSMTPHost("smtp.example.com") || !allowedSMTPIP(net.ParseIP("192.0.2.10")) || !allowedSMTPIP(net.ParseIP("2001:db8::10")) {
		t.Fatal("valid SMTP host or public unicast address was rejected")
	}
}

func serveSTARTTLSFixture(listener net.Listener, certificate tls.Certificate) ([]string, error) {
	connection, err := listener.Accept()
	if err != nil {
		return nil, err
	}
	defer connection.Close()
	commands := []string{}
	reader := bufio.NewReader(connection)
	writer := bufio.NewWriter(connection)
	if _, err := writer.WriteString("220 smtp.fixture.test ESMTP\r\n"); err != nil {
		return commands, err
	}
	if err := writer.Flush(); err != nil {
		return commands, err
	}
	line, err := reader.ReadString('\n')
	if err != nil {
		return commands, err
	}
	commands = append(commands, strings.TrimSpace(line))
	if _, err := writer.WriteString("250-smtp.fixture.test\r\n250-STARTTLS\r\n250 SIZE 1024\r\n"); err != nil {
		return commands, err
	}
	if err := writer.Flush(); err != nil {
		return commands, err
	}
	line, err = reader.ReadString('\n')
	if err != nil {
		return commands, err
	}
	commands = append(commands, strings.TrimSpace(line))
	if _, err := writer.WriteString("220 begin TLS\r\n"); err != nil {
		return commands, err
	}
	if err := writer.Flush(); err != nil {
		return commands, err
	}
	tlsConnection := tls.Server(connection, &tls.Config{Certificates: []tls.Certificate{certificate}, MinVersion: tls.VersionTLS12})
	if err := tlsConnection.Handshake(); err != nil {
		return commands, err
	}
	reader = bufio.NewReader(tlsConnection)
	writer = bufio.NewWriter(tlsConnection)
	line, err = reader.ReadString('\n')
	if err != nil {
		return commands, err
	}
	commands = append(commands, strings.TrimSpace(line))
	if _, err := writer.WriteString("250 smtp.fixture.test\r\n"); err != nil {
		return commands, err
	}
	if err := writer.Flush(); err != nil {
		return commands, err
	}
	line, err = reader.ReadString('\n')
	if err != nil {
		return commands, err
	}
	commands = append(commands, strings.TrimSpace(line))
	return commands, nil
}

func TestSMTPNetworkCheckStopsBeforeAuthenticationOrDelivery(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	commands := make(chan []string, 1)
	go serveSMTPPreflightFixture(listener, false, commands)

	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	setIntegrationConfigValues(t, root, map[string]any{
		"SmtpHost":      "127.0.0.1",
		"SmtpPort":      int64(listener.Addr().(*net.TCPAddr).Port),
		"SmtpEnableSsl": false,
	})
	view := ReadConfigEditor(root)
	result, err := RunSMTPNetworkCheck(context.Background(), root, SMTPNetworkCheckRequest{
		ExpectedRevision:   view.Revision,
		ConfirmRealNetwork: true,
	}, func() time.Time { return time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC) })
	if err != nil {
		t.Fatal(err)
	}
	if result.Overall != "warning" || result.State != "warning" || result.Security != "plaintext-configured" {
		t.Fatalf("unexpected SMTP preflight result: %+v", result)
	}
	select {
	case observed := <-commands:
		if len(observed) == 0 || !strings.HasPrefix(observed[0], "EHLO ") {
			t.Fatalf("SMTP preflight omitted EHLO: %v", observed)
		}
		for _, forbidden := range []string{"AUTH", "MAIL FROM", "RCPT TO", "DATA"} {
			for _, command := range observed {
				if strings.HasPrefix(strings.ToUpper(command), forbidden) {
					t.Fatalf("SMTP preflight sent forbidden command %q", command)
				}
			}
		}
	case <-time.After(3 * time.Second):
		t.Fatal("SMTP fixture did not complete")
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	for _, private := range []string{"127.0.0.1", "fictional-smtp-secret", "newsletter@example.org"} {
		if strings.Contains(string(encoded), private) {
			t.Fatalf("SMTP preflight returned private value %q", private)
		}
	}
}

func TestSMTPNetworkCheckRequiresAdvertisedSTARTTLS(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	commands := make(chan []string, 1)
	go serveSMTPPreflightFixture(listener, false, commands)

	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	setIntegrationConfigValues(t, root, map[string]any{
		"SmtpHost":      "127.0.0.1",
		"SmtpPort":      int64(listener.Addr().(*net.TCPAddr).Port),
		"SmtpEnableSsl": true,
	})
	view := ReadConfigEditor(root)
	result, err := RunSMTPNetworkCheck(context.Background(), root, SMTPNetworkCheckRequest{
		ExpectedRevision:   view.Revision,
		ConfirmRealNetwork: true,
	}, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	if result.Overall != "failed" || result.State != "failed" || result.Security != "not-established" || !strings.Contains(result.Summary, "STARTTLS") {
		t.Fatalf("missing STARTTLS was not reported safely: %+v", result)
	}
	select {
	case <-commands:
	case <-time.After(3 * time.Second):
		t.Fatal("SMTP fixture did not complete")
	}
}

func serveSMTPPreflightFixture(listener net.Listener, advertiseSTARTTLS bool, observed chan<- []string) {
	commands := []string{}
	defer func() { observed <- commands }()
	connection, err := listener.Accept()
	if err != nil {
		return
	}
	defer connection.Close()
	reader := bufio.NewReader(connection)
	writer := bufio.NewWriter(connection)
	_, _ = writer.WriteString("220 smtp.fixture.test ESMTP\r\n")
	_ = writer.Flush()
	for {
		line, readErr := reader.ReadString('\n')
		if readErr != nil {
			return
		}
		line = strings.TrimSpace(line)
		commands = append(commands, line)
		switch {
		case strings.HasPrefix(strings.ToUpper(line), "EHLO "):
			_, _ = writer.WriteString("250-smtp.fixture.test\r\n")
			if advertiseSTARTTLS {
				_, _ = writer.WriteString("250-STARTTLS\r\n")
			}
			_, _ = writer.WriteString("250 SIZE 1024\r\n")
			_ = writer.Flush()
		case strings.EqualFold(line, "QUIT"):
			_, _ = writer.WriteString("221 bye\r\n")
			_ = writer.Flush()
			return
		default:
			_, _ = writer.WriteString("500 unsupported\r\n")
			_ = writer.Flush()
			return
		}
	}
}

func setIntegrationConfigValues(t *testing.T, root string, updates map[string]any) {
	t.Helper()
	path := filepath.Join(root, "config.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	values := map[string]any{}
	if err := json.Unmarshal(raw, &values); err != nil {
		t.Fatal(err)
	}
	for name, value := range updates {
		values[name] = value
	}
	raw, err = json.Marshal(values)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if view := ReadConfigEditor(root); !view.Valid || view.State != "ready" {
		t.Fatalf("updated fixture configuration is not ready: %+v", view.Issues)
	}
}

func TestRealIntegrationCheckUsesLANServicesWithoutReturningSecrets(t *testing.T) {
	const tautulliSecret = "fictional-tautulli-secret"
	const plexSecret = "fictional-plex-secret"
	plex := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Plex-Token") != plexSecret {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/identity":
			_, _ = w.Write([]byte(`{"MediaContainer":{"machineIdentifier":"fictional-machine"}}`))
		case "/library/sections":
			_, _ = w.Write([]byte(`{"MediaContainer":{"size":2,"Directory":[]}}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer plex.Close()

	tautulli := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v2" || r.URL.Query().Get("apikey") != tautulliSecret {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		var data any
		switch r.URL.Query().Get("cmd") {
		case "get_tautulli_info":
			data = map[string]any{"tautulli_version": "2.16.0-fixture"}
		case "get_user_names":
			data = []any{map[string]any{"user_id": "1"}, map[string]any{"user_id": "2"}}
		case "get_libraries":
			data = []any{
				map[string]any{"section_id": "10", "section_type": "movie", "is_active": 1},
				map[string]any{"section_id": "20", "section_type": "show", "is_active": 1},
			}
		case "get_server_info":
			data = map[string]any{"pms_url": plex.URL, "pms_identifier": "fictional-machine"}
		default:
			http.Error(w, "unsupported", http.StatusBadRequest)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"response": map[string]any{"result": "success", "message": "", "data": data}})
	}))
	defer tautulli.Close()

	root := integrationConfigRoot(t, tautulli.URL, tautulliSecret, plex.URL, plexSecret)
	view := ReadConfigEditor(root)
	result, err := RunRealIntegrationCheck(context.Background(), root, RealIntegrationCheckRequest{
		ExpectedRevision:   view.Revision,
		ConfirmRealNetwork: true,
	}, func() time.Time { return time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC) })
	if err != nil {
		t.Fatal(err)
	}
	if result.Overall != "passed" || len(result.Steps) != 2 || result.Steps[0].State != "passed" || result.Steps[1].State != "passed" {
		t.Fatalf("unexpected verification result: %+v", result)
	}
	setIntegrationConfigValues(t, root, map[string]any{"PlexServerUrl": "", "PlexToken": ""})
	t.Setenv("PLEX_TOKEN", plexSecret)
	runtimeView := ReadConfigEditor(root)
	runtimeResult, err := RunRealIntegrationCheck(context.Background(), root, RealIntegrationCheckRequest{
		ExpectedRevision:   runtimeView.Revision,
		ConfirmRealNetwork: true,
	}, time.Now)
	if err != nil || runtimeResult.Overall != "passed" || runtimeResult.Steps[1].State != "passed" {
		t.Fatalf("runtime Plex fallback verification: result=%+v err=%v", runtimeResult, err)
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{tautulliSecret, plexSecret} {
		if strings.Contains(string(encoded), secret) {
			t.Fatalf("verification response returned secret %q", secret)
		}
	}
}

func TestIntegrationCheckOverallTreatsOptionalDirectPlexSkipAsPassed(t *testing.T) {
	steps := []IntegrationCheckStep{
		{Service: "tautulli", State: "passed"},
		{Service: "plex", State: "skipped"},
	}
	if result := integrationCheckOverall(steps); result != "passed" {
		t.Fatalf("optional Plex result: got %q, want passed", result)
	}
	steps[1].State = "failed"
	if result := integrationCheckOverall(steps); result != "failed" {
		t.Fatalf("failed Plex result: got %q, want failed", result)
	}
}

func TestRealIntegrationCheckRequiresConfirmationRevisionAndLAN(t *testing.T) {
	root := integrationConfigRoot(t, "http://203.0.113.10:8181", "fictional-api-key", "", "")
	view := ReadConfigEditor(root)
	_, err := RunRealIntegrationCheck(context.Background(), root, RealIntegrationCheckRequest{ExpectedRevision: view.Revision}, time.Now)
	if !errors.Is(err, ErrRealCheckConfirmation) {
		t.Fatalf("missing confirmation error: got %v", err)
	}
	_, err = RunRealIntegrationCheck(context.Background(), root, RealIntegrationCheckRequest{ExpectedRevision: "stale", ConfirmRealNetwork: true}, time.Now)
	if !errors.Is(err, ErrConfigConflict) {
		t.Fatalf("stale revision error: got %v", err)
	}
	result, err := RunRealIntegrationCheck(context.Background(), root, RealIntegrationCheckRequest{ExpectedRevision: view.Revision, ConfirmRealNetwork: true}, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	if result.Overall != "failed" || result.Steps[0].State != "failed" || !strings.Contains(result.Steps[0].Summary, "private or loopback") {
		t.Fatalf("public destination was not blocked safely: %+v", result)
	}
}

func TestTautulliDiscoveryReturnsSanitizedChoicesWithoutEmailOrSecrets(t *testing.T) {
	const secret = "fictional-discovery-secret"
	tautulli := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v2" || r.URL.Query().Get("apikey") != secret {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		var data any
		switch r.URL.Query().Get("cmd") {
		case "get_libraries":
			data = []any{
				map[string]any{"section_id": "20", "section_name": "Fictional Shows", "section_type": "show", "is_active": 1, "count": 12},
				map[string]any{"section_id": "10", "section_name": "Fictional Movies", "section_type": "movie", "is_active": true, "count": 34},
				map[string]any{"section_id": "30", "section_name": "Music", "section_type": "artist", "is_active": 1},
			}
		case "get_user_names":
			data = []any{
				map[string]any{"user_id": "2", "friendly_name": "Fictional Viewer"},
				map[string]any{"user_id": "3", "friendly_name": "Fictional Managed Viewer"},
				map[string]any{"user_id": int64(1234567890123456789), "friendly_name": "Fictional Archived Viewer"},
			}
		case "get_users":
			data = []any{
				map[string]any{"user_id": "1", "friendly_name": "Fictional Admin", "is_active": 1, "do_notify": 0, "is_admin": 1},
				map[string]any{"user_id": "2", "username": "viewer", "email": "private-viewer@example.org", "is_active": 0, "do_notify": 1},
				map[string]any{"user_id": "3", "username": "managed", "email": "", "is_active": 1, "do_notify": 1},
			}
		case "get_users_table":
			if r.URL.Query().Get("start") != "0" || r.URL.Query().Get("length") != strconv.Itoa(maximumDiscoveryChoices) {
				http.Error(w, "invalid table window", http.StatusBadRequest)
				return
			}
			data = map[string]any{"data": []any{
				map[string]any{"user_id": "1", "friendly_name": "Fictional Admin", "email": "private-admin@example.org", "is_active": 1, "do_notify": 0},
			}}
		default:
			http.Error(w, "unsupported", http.StatusBadRequest)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"response": map[string]any{"result": "success", "data": data}})
	}))
	defer tautulli.Close()

	root := integrationConfigRoot(t, tautulli.URL, secret, "", "")
	setIntegrationConfigValues(t, root, map[string]any{
		"ExcludedEmails": []string{"PRIVATE-ADMIN@example.org", "unmatched-legacy@example.org"},
	})
	view := ReadConfigEditor(root)
	result, err := DiscoverTautulliChoices(context.Background(), root, TautulliDiscoveryRequest{
		ExpectedRevision:   view.Revision,
		ConfirmRealNetwork: true,
	}, func() time.Time { return time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC) })
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Libraries) != 2 || result.Libraries[0].ID != "10" || len(result.Users) != 4 {
		t.Fatalf("unexpected discovery result: %+v", result)
	}
	if result.SuggestedPreviewUserID != "1" || result.Users[0].Role != "administrator" {
		t.Fatalf("explicit administrator was not selected safely: %+v", result)
	}
	if result.Users[0].Eligibility != "eligible" || result.Users[1].Eligibility != "unknown" || result.Users[1].ID != "1234567890123456789" || result.Users[2].Eligibility != "address-needed" || !result.Users[2].NeedsDeliveryAddress || result.Users[3].Eligibility != "skipped" || result.Users[3].NeedsDeliveryAddress {
		t.Fatalf("unexpected eligibility normalization: %+v", result.Users)
	}
	if result.LegacyRuleCount != 2 || result.MatchedLegacyRuleCount != 1 || !result.Users[0].LegacyRuleExcluded || result.Users[1].LegacyRuleExcluded || result.Users[2].LegacyRuleExcluded || result.Users[3].LegacyRuleExcluded {
		t.Fatalf("legacy rules were not matched without disclosure: %+v", result)
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	for _, private := range []string{secret, "private-admin@example.org", "private-viewer@example.org", "unmatched-legacy@example.org", tautulli.URL} {
		if strings.Contains(string(encoded), private) {
			t.Fatalf("discovery response returned private value %q", private)
		}
	}
}

func TestTautulliDiscoveryFallsBackToTableBackedLibrariesAndUsers(t *testing.T) {
	const secret = "fictional-table-fallback-secret"
	commands := map[string]int{}
	tautulli := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v2" || r.URL.Query().Get("apikey") != secret {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		command := r.URL.Query().Get("cmd")
		commands[command]++
		var result = "success"
		var data any
		switch command {
		case "get_libraries":
			// Tautulli's live PMS-backed command can answer successfully with no
			// current data while its local table still contains usable choices.
			data = nil
		case "get_libraries_table":
			data = map[string]any{"data": []any{
				map[string]any{"section_id": 10, "section_name": "Fictional Movies", "section_type": "Movie", "is_active": "1", "count": 34},
				map[string]any{"section_id": 20, "section_name": "Fictional Shows", "section_type": "Show", "is_active": true, "count": "12"},
			}}
		case "get_user_names":
			result = "error"
			data = map[string]any{"private": "must-not-escape"}
		case "get_users":
			data = nil
		case "get_users_table":
			data = map[string]any{"data": []any{
				map[string]any{"user_id": 1, "friendly_name": "Fictional Owner", "email": "private-owner@example.org", "is_active": "1", "is_owner": true},
				map[string]any{"user_id": "2", "friendly_name": "Fictional Viewer", "email": "private-viewer@example.org", "is_active": 1},
			}}
		default:
			http.Error(w, "unsupported", http.StatusBadRequest)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"response": map[string]any{"result": result, "data": data}})
	}))
	defer tautulli.Close()

	root := integrationConfigRoot(t, tautulli.URL, secret, "", "")
	view := ReadConfigEditor(root)
	result, err := DiscoverTautulliChoices(context.Background(), root, TautulliDiscoveryRequest{
		ExpectedRevision:   view.Revision,
		ConfirmRealNetwork: true,
	}, func() time.Time { return time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC) })
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Libraries) != 2 || result.Libraries[0].ID != "10" || len(result.Users) != 2 {
		t.Fatalf("unexpected table-backed discovery result: %+v", result)
	}
	if result.SuggestedPreviewUserID != "1" || result.Users[0].Role != "owner" || result.Users[0].Eligibility != "eligible" {
		t.Fatalf("table-backed user details were not normalized safely: %+v", result.Users)
	}
	for _, command := range []string{"get_libraries", "get_libraries_table", "get_user_names", "get_users", "get_users_table"} {
		if commands[command] != 1 {
			t.Fatalf("command %s calls: got %d, want 1", command, commands[command])
		}
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	for _, private := range []string{secret, tautulli.URL, "private-owner@example.org", "private-viewer@example.org", "must-not-escape"} {
		if strings.Contains(string(encoded), private) {
			t.Fatalf("table-backed discovery returned private value %q", private)
		}
	}
}

func TestTautulliDiscoveryReportsSanitizedUserStageAfterFallbacks(t *testing.T) {
	const secret = "fictional-user-stage-secret"
	tautulli := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v2" || r.URL.Query().Get("apikey") != secret {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		var result = "success"
		var data any
		switch r.URL.Query().Get("cmd") {
		case "get_libraries":
			data = []any{map[string]any{"section_id": 10, "section_name": "Fictional Movies", "section_type": "movie", "is_active": true}}
		case "get_user_names", "get_users", "get_users_table":
			result = "error"
			data = map[string]any{"private": "must-not-escape"}
		default:
			http.Error(w, "unsupported", http.StatusBadRequest)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"response": map[string]any{"result": result, "data": data}})
	}))
	defer tautulli.Close()

	root := integrationConfigRoot(t, tautulli.URL, secret, "", "")
	view := ReadConfigEditor(root)
	_, err := DiscoverTautulliChoices(context.Background(), root, TautulliDiscoveryRequest{
		ExpectedRevision:   view.Revision,
		ConfirmRealNetwork: true,
	}, time.Now)
	if err == nil || tautulliDiscoveryFailureStage(err) != "users" {
		t.Fatalf("user fallback failure stage: got %v", err)
	}
	for _, private := range []string{secret, tautulli.URL, "must-not-escape"} {
		if strings.Contains(err.Error(), private) {
			t.Fatalf("user fallback failure returned private value %q: %v", private, err)
		}
	}
}

func TestSuggestedPreviewUserIDRequiresOneExplicitRole(t *testing.T) {
	tests := []struct {
		name  string
		users []DiscoveredUser
		want  string
	}{
		{name: "no inferred role", users: []DiscoveredUser{{ID: "1", Name: "Owner-like name"}}},
		{name: "one administrator", users: []DiscoveredUser{{ID: "1", Role: "administrator"}}, want: "1"},
		{name: "ambiguous administrators", users: []DiscoveredUser{{ID: "1", Role: "administrator"}, {ID: "2", Role: "administrator"}}},
		{name: "owner preferred", users: []DiscoveredUser{{ID: "1", Role: "administrator"}, {ID: "2", Role: "owner"}}, want: "2"},
		{name: "ambiguous owners", users: []DiscoveredUser{{ID: "1", Role: "owner"}, {ID: "2", Role: "owner"}, {ID: "3", Role: "administrator"}}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := suggestedPreviewUserID(test.users); got != test.want {
				t.Fatalf("suggestedPreviewUserID() = %q, want %q", got, test.want)
			}
		})
	}
}

func integrationConfigRoot(t *testing.T, tautulliURL, tautulliSecret, plexURL, plexSecret string) string {
	t.Helper()
	root := t.TempDir()
	config := map[string]any{
		"TautulliUrl":           tautulliURL,
		"ApiKey":                tautulliSecret,
		"PlexServerUrl":         plexURL,
		"PlexToken":             plexSecret,
		"FromEmail":             "newsletter@example.org",
		"ReplyToEmail":          "newsletter@example.org",
		"TestEmail":             "admin@example.org",
		"SmtpHost":              "smtp.example.test",
		"SmtpUseAuthentication": true,
		"SmtpUsername":          "newsletter@example.org",
		"SmtpPassword":          "fictional-smtp-secret",
	}
	raw, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "config.json"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if view := ReadConfigEditor(root); !view.Valid || view.State != "ready" {
		t.Fatalf("fixture configuration is not ready: %+v", view.Issues)
	}
	return root
}
