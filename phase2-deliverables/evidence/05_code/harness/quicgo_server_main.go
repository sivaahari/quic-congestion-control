// Command qgserver is a minimal single-connection QUIC file-serving harness
// for the PV-Seed quic-go survey (Phase 2). It is deliberately NOT HTTP/3:
// it speaks a trivial length-free protocol over one bidirectional QUIC
// stream (client opens a stream, sends a one-line request, server streams
// the requested file back and closes the stream) so that the measurement
// is of QUIC-layer congestion/RTT behaviour, not an HTTP stack.
//
// Mirrors picoquicdemo's "-1" behaviour: serve exactly one connection, then
// exit cleanly so the qlog file is finalized (not truncated by a SIGTERM).
package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"time"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/qlog"
)

func main() {
	addr := flag.String("addr", "10.0.9.1:4433", "address:port to bind")
	certFile := flag.String("cert", "", "TLS certificate PEM path")
	keyFile := flag.String("key", "", "TLS key PEM path")
	filePath := flag.String("file", "", "file to serve on every stream request")
	idleTimeout := flag.Duration("idle-timeout", 30*time.Second, "max idle timeout")
	flag.Parse()

	if *certFile == "" || *keyFile == "" || *filePath == "" {
		log.Fatal("must set -cert -key -file")
	}

	cert, err := tls.LoadX509KeyPair(*certFile, *keyFile)
	if err != nil {
		log.Fatalf("load cert: %v", err)
	}
	tlsConf := &tls.Config{
		Certificates: []tls.Certificate{cert},
		NextProtos:   []string{"pvseed-quicgo-survey"},
	}

	udpAddr, err := net.ResolveUDPAddr("udp", *addr)
	if err != nil {
		log.Fatalf("resolve addr: %v", err)
	}
	udpConn, err := net.ListenUDP("udp", udpAddr)
	if err != nil {
		log.Fatalf("listen udp %s: %v", *addr, err)
	}
	defer udpConn.Close()

	tr := &quic.Transport{Conn: udpConn}
	quicConf := &quic.Config{
		MaxIdleTimeout:  *idleTimeout,
		Tracer:          qlog.DefaultConnectionTracer,
		EnableDatagrams: false,
	}

	ln, err := tr.Listen(tlsConf, quicConf)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	defer ln.Close()

	fi, err := os.Stat(*filePath)
	if err != nil {
		log.Fatalf("stat file: %v", err)
	}
	log.Printf("[qgserver] listening on %s, will serve %s (%d bytes) for one connection", *addr, *filePath, fi.Size())

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	conn, err := ln.Accept(ctx)
	if err != nil {
		log.Fatalf("accept: %v", err)
	}
	log.Printf("[qgserver] accepted connection from %s at %s", conn.RemoteAddr(), time.Now().Format(time.RFC3339Nano))

	str, err := conn.AcceptStream(ctx)
	if err != nil {
		log.Fatalf("accept stream: %v", err)
	}
	log.Printf("[qgserver] accepted stream %d at %s", str.StreamID(), time.Now().Format(time.RFC3339Nano))

	// Read the one-line request (we ignore its content -- there is only one file).
	reqBuf := make([]byte, 256)
	n, err := str.Read(reqBuf)
	if err != nil && err != io.EOF {
		log.Fatalf("read request: %v", err)
	}
	log.Printf("[qgserver] got request: %q", string(reqBuf[:n]))

	f, err := os.Open(*filePath)
	if err != nil {
		log.Fatalf("open file: %v", err)
	}
	defer f.Close()

	start := time.Now()
	written, err := io.Copy(str, f)
	elapsed := time.Since(start)
	if err != nil {
		log.Fatalf("write file to stream: %v", err)
	}
	log.Printf("[qgserver] sent %d bytes in %s (%.2f Mbit/s) at %s", written, elapsed, float64(written)*8/1e6/elapsed.Seconds(), time.Now().Format(time.RFC3339Nano))

	if err := str.Close(); err != nil {
		log.Printf("[qgserver] stream close: %v", err)
	}

	// Give the client a chance to finish reading / ACK before we tear down.
	time.Sleep(2 * time.Second)

	if err := conn.CloseWithError(0, "done"); err != nil {
		log.Printf("[qgserver] conn close: %v", err)
	}
	fmt.Println("[qgserver] DONE")
}
