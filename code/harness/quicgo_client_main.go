// Command qgclient is the client half of the PV-Seed quic-go survey
// harness (Phase 2). It downloads one file over a single bidirectional
// QUIC stream, starting on an explicitly-bound local address ("path A"),
// and MIGRATE_AFTER into the transfer actively migrates the QUIC
// connection to a second, explicitly-bound local address ("path B") using
// quic-go's public Conn.AddPath / Path.Probe / Path.Switch API
// (path_manager_outgoing.go, added in quic-go PR #4960).
//
// This is client-INITIATED migration: a real local-address change, driven
// entirely by this program, not a NAT-rebinding simulation.
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"sync/atomic"
	"time"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/qlog"
)

// progressWriter counts bytes written through it and lets a ticker report
// throughput without touching the hot path.
type progressWriter struct {
	w     io.Writer
	total atomic.Int64
}

func (p *progressWriter) Write(b []byte) (int, error) {
	n, err := p.w.Write(b)
	p.total.Add(int64(n))
	return n, err
}

func mustResolveUDP(addr string) *net.UDPAddr {
	a, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		log.Fatalf("resolve %s: %v", addr, err)
	}
	return a
}

func main() {
	serverAddr := flag.String("server-addr", "10.0.9.1:4433", "server address:port")
	localA := flag.String("local-a", "10.0.1.1:0", "initial local bind address:port (path A)")
	localB := flag.String("local-b", "10.0.3.1:0", "migration-target local bind address:port (path B)")
	migrateAfter := flag.Duration("migrate-after", 5*time.Second, "time after stream open to trigger migration")
	outPath := flag.String("out", "", "path to write downloaded bytes (optional)")
	sni := flag.String("sni", "pvseed.test", "TLS server name")
	caFile := flag.String("ca", "", "PEM file containing the trusted server certificate (pinned CA)")
	overallTimeout := flag.Duration("timeout", 90*time.Second, "overall client timeout")
	probeTimeout := flag.Duration("probe-timeout", 10*time.Second, "PATH_CHALLENGE probe timeout")
	flag.Parse()

	if *caFile == "" {
		log.Fatal("must set -ca (path to the server's certificate, used as a pinned trust root; " +
			"we deliberately do not support -insecure-skip-verify)")
	}
	caPEM, err := os.ReadFile(*caFile)
	if err != nil {
		log.Fatalf("read -ca file: %v", err)
	}
	certPool := x509.NewCertPool()
	if !certPool.AppendCertsFromPEM(caPEM) {
		log.Fatalf("no certificates found in -ca file %s", *caFile)
	}
	tlsConf := &tls.Config{
		RootCAs:    certPool,
		NextProtos: []string{"pvseed-quicgo-survey"},
		ServerName: *sni,
	}
	quicConf := &quic.Config{
		MaxIdleTimeout: 30 * time.Second,
		Tracer:         qlog.DefaultConnectionTracer,
	}

	udpAddrA := mustResolveUDP(*localA)
	connA, err := net.ListenUDP("udp", udpAddrA)
	if err != nil {
		log.Fatalf("bind local-a %s: %v", *localA, err)
	}
	defer connA.Close()
	tr1 := &quic.Transport{Conn: connA}
	defer tr1.Close()

	serverUDPAddr := mustResolveUDP(*serverAddr)

	ctx, cancel := context.WithTimeout(context.Background(), *overallTimeout)
	defer cancel()

	log.Printf("[qgclient] dialing %s from %s at %s", serverUDPAddr, connA.LocalAddr(), time.Now().Format(time.RFC3339Nano))
	conn, err := tr1.Dial(ctx, serverUDPAddr, tlsConf, quicConf)
	if err != nil {
		log.Fatalf("dial: %v", err)
	}
	log.Printf("[qgclient] connected, local=%s remote=%s at %s", conn.LocalAddr(), conn.RemoteAddr(), time.Now().Format(time.RFC3339Nano))

	str, err := conn.OpenStreamSync(ctx)
	if err != nil {
		log.Fatalf("open stream: %v", err)
	}
	if _, err := str.Write([]byte("GET bigfile.bin\n")); err != nil {
		log.Fatalf("write request: %v", err)
	}
	transferStart := time.Now()
	log.Printf("[qgclient] stream %d opened, request sent at %s", str.StreamID(), transferStart.Format(time.RFC3339Nano))

	// --- migration goroutine ---
	migErrCh := make(chan error, 1)
	go func() {
		select {
		case <-time.After(*migrateAfter):
		case <-ctx.Done():
			migErrCh <- ctx.Err()
			return
		}
		log.Printf("[qgclient] MIGRATE_TRIGGER at %s (t+%s since stream open)", time.Now().Format(time.RFC3339Nano), time.Since(transferStart))

		udpAddrB := mustResolveUDP(*localB)
		connB, err := net.ListenUDP("udp", udpAddrB)
		if err != nil {
			migErrCh <- fmt.Errorf("bind local-b %s: %w", *localB, err)
			return
		}
		tr2 := &quic.Transport{Conn: connB}

		path, err := conn.AddPath(tr2)
		if err != nil {
			migErrCh <- fmt.Errorf("AddPath: %w", err)
			return
		}
		log.Printf("[qgclient] MIGRATE_ADDPATH_OK local=%s at %s", connB.LocalAddr(), time.Now().Format(time.RFC3339Nano))

		probeCtx, probeCancel := context.WithTimeout(ctx, *probeTimeout)
		defer probeCancel()
		probeStart := time.Now()
		if err := path.Probe(probeCtx); err != nil {
			migErrCh <- fmt.Errorf("Probe: %w", err)
			return
		}
		log.Printf("[qgclient] MIGRATE_VALIDATED at %s (probe RTT-ish %s)", time.Now().Format(time.RFC3339Nano), time.Since(probeStart))

		preSwitchAddr := conn.LocalAddr().String()
		switchCallTime := time.Now()
		if err := path.Switch(); err != nil {
			migErrCh <- fmt.Errorf("Switch: %w", err)
			return
		}
		log.Printf("[qgclient] MIGRATE_SWITCH_CALLED at %s (Switch() only flags the pending change; "+
			"the connection's run loop performs the actual cutover asynchronously -- polling conn.LocalAddr() below "+
			"for the real cutover instant rather than trusting this timestamp)", switchCallTime.Format(time.RFC3339Nano))

		// Switch() returning nil does not mean the cutover has happened yet:
		// it only sets pathToSwitchTo, which the connection's run() loop picks
		// up on its next iteration (see connection.go switchToNewPath). Poll
		// for the observable address change so we log the REAL cutover time.
		var confirmed bool
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			if conn.LocalAddr().String() != preSwitchAddr {
				confirmed = true
				break
			}
			time.Sleep(2 * time.Millisecond)
		}
		cutoverTime := time.Now()
		if !confirmed {
			migErrCh <- fmt.Errorf("conn.LocalAddr() never changed from %s within 5s of Switch() returning", preSwitchAddr)
			return
		}
		log.Printf("[qgclient] MIGRATE_CUTOVER_CONFIRMED at %s (+%s after Switch() call), conn.LocalAddr()=%s (was %s)",
			cutoverTime.Format(time.RFC3339Nano), cutoverTime.Sub(switchCallTime), conn.LocalAddr(), preSwitchAddr)
		migErrCh <- nil
	}()

	// --- download + progress reporting ---
	var out io.Writer = io.Discard
	var outFile *os.File
	if *outPath != "" {
		outFile, err = os.Create(*outPath)
		if err != nil {
			log.Fatalf("create out file: %v", err)
		}
		defer outFile.Close()
		out = outFile
	}
	pw := &progressWriter{w: out}

	// stopProgress is closed exactly once, by main, after the download loop
	// below finishes; the goroutine only ever receives from it, so there is
	// no double-close race even though ctx.Done() is also a receive-only case.
	stopProgress := make(chan struct{})
	go func() {
		ticker := time.NewTicker(1 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				log.Printf("[qgclient] progress: %d bytes at t+%s", pw.total.Load(), time.Since(transferStart))
			case <-ctx.Done():
				return
			case <-stopProgress:
				return
			}
		}
	}()

	copyStart := time.Now()
	n, copyErr := io.Copy(pw, str)
	elapsed := time.Since(copyStart)
	close(stopProgress)

	if copyErr != nil {
		log.Printf("[qgclient] WARNING: stream read ended with error: %v", copyErr)
	}
	log.Printf("[qgclient] download complete: %d bytes in %s (%.2f Mbit/s)", n, elapsed, float64(n)*8/1e6/elapsed.Seconds())

	// Wait (briefly) for the migration goroutine to report its outcome, if it hasn't already.
	select {
	case migErr := <-migErrCh:
		if migErr != nil {
			log.Printf("[qgclient] MIGRATION FAILED: %v", migErr)
		} else {
			log.Printf("[qgclient] MIGRATION_TRIGGER_FIRED")
		}
	case <-time.After(2 * time.Second):
		log.Printf("[qgclient] WARNING: migration goroutine did not report within grace period")
	}

	if err := conn.CloseWithError(0, "done"); err != nil {
		log.Printf("[qgclient] conn close: %v", err)
	}
	fmt.Println("[qgclient] DONE")
}
