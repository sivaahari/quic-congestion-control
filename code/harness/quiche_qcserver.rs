// qcserver -- PV-Seed quiche survey harness, server half.
//
// Serves exactly ONE QUIC connection, one bidirectional stream: reads a
// one-line request (content ignored -- there is only one file, mirroring
// harness/quicgo/server/main.go's protocol), then streams the requested
// file's bytes back and closes. This is deliberately NOT HTTP/3, so qlog
// traces reflect only QUIC-layer congestion/RTT behaviour.
//
// Server-side migration acceptance needs no special handling: this process
// binds ONE socket to the stable service address and keeps calling
// conn.recv() with whatever `from` address each datagram arrived from.
// quiche's own PathMap logic (src/lib.rs recv_single / on_peer_migrated)
// detects the new (local, peer) 4-tuple and switches the active path
// itself -- see the source audit in the task report.

use std::collections::HashMap;
use std::io::Write;
use std::net::SocketAddr;
use std::time::Duration;
use std::time::Instant;

const MAX_BUF: usize = 65535;

fn parse_args() -> HashMap<String, String> {
    let mut m = HashMap::new();
    let mut it = std::env::args().skip(1);
    while let Some(k) = it.next() {
        if let Some(stripped) = k.strip_prefix("--") {
            let v = it.next().unwrap_or_default();
            m.insert(format!("--{stripped}"), v);
        }
    }
    m
}

// Not security-sensitive (private test harness, single expected client) --
// just needs to be unique per process, not cryptographically unpredictable.
// Includes a static counter (not just a clock read) because new_scid() below
// calls this in a tight loop to mint several spare connection IDs, faster
// than the nanosecond clock is guaranteed to visibly tick on every platform.
static ID_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn gen_u128(salt: u128) -> u128 {
    use std::time::SystemTime;
    use std::time::UNIX_EPOCH;
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let pid = std::process::id() as u128;
    let counter = ID_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed) as u128;
    nanos ^ (pid << 64) ^ (counter << 32) ^ salt
}

fn gen_cid() -> [u8; 16] {
    gen_u128(0x9E3779B97F4A7C15u128).to_be_bytes()
}

fn gen_reset_token() -> u128 {
    gen_u128(0x517CC1B727220A95u128)
}

/// Hands out as many spare Source Connection IDs to the peer as it will
/// accept (NEW_CONNECTION_ID frames). The PEER needs at least one of these
/// as a spare Destination CID before it can call probe_path()/migrate() to
/// address us on a new path -- quiche/apps/src/client.rs's own
/// --perform-migration gates its probe on `conn.available_dcids() > 0` for
/// exactly this reason, which only becomes true once frames from this loop
/// (run by whichever side is NOT initiating migration) have arrived.
fn issue_spare_scids(c: &mut quiche::Connection) {
    while c.scids_left() > 0 {
        let scid = quiche::ConnectionId::from_vec(gen_cid().to_vec());
        let reset_token = gen_reset_token();
        if c.new_scid(&scid, reset_token, false).is_err() {
            break;
        }
    }
}

/// Sends one already-serialized UDP datagram, retrying briefly on WouldBlock
/// instead of silently discarding it.
///
/// This matters a great deal: by the time conn.send() hands back a packet,
/// quiche has ALREADY recorded it internally as sent (added to
/// bytes_in_flight, given a packet number, awaiting ACK/loss-detection). If
/// socket.send_to() then fails and the caller just drops the packet, quiche
/// has no way to know the transmission never actually happened -- the peer
/// will simply never receive those bytes until (if ever) normal
/// time-threshold loss detection notices and retransmits, which can take a
/// long time or, in the case actually hit while building this harness,
/// effectively never happen. Under a rate-shaped path this is not a rare
/// edge case: a burst of WouldBlock errors (local socket/interface transmit
/// backpressure) right around a bufferbloat/congestion event can silently
/// open a gap in stream delivery. This is exactly what caused an earlier
/// version of this harness (which did `if would_block { break }`, discarding
/// the packet) to stall permanently a few hundred KB after every migration:
/// qlog diffing of client-received vs server-sent stream offsets found a
/// single confirmed ~600KB gap in the received byte range, with zero
/// packet_lost events recorded on the sender -- consistent with a packet
/// quiche believed it sent but that never actually reached the socket.
fn send_with_retry(
    socket: &mio::net::UdpSocket, buf: &[u8], to: std::net::SocketAddr,
    who: &str,
) -> bool {
    let deadline = Instant::now() + Duration::from_millis(500);
    loop {
        match socket.send_to(buf, to) {
            Ok(_) => return true,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                if Instant::now() >= deadline {
                    eprintln!(
                        "[{who}] DROPPED PACKET: send_to {to} kept returning \
                         WouldBlock for 500ms, giving up on this datagram \
                         ({} bytes) -- quiche believes this packet was sent",
                        buf.len()
                    );
                    return false;
                }
                std::thread::sleep(Duration::from_micros(200));
            },
            Err(e) => {
                eprintln!("[{who}] socket send_to {to} error: {e:?}");
                return false;
            },
        }
    }
}

fn main() {
    let args = parse_args();

    let listen: SocketAddr = args
        .get("--listen")
        .expect("--listen ADDR:PORT is required")
        .parse()
        .expect("--listen must be a valid ADDR:PORT");
    let cert = args.get("--cert").expect("--cert PATH is required").clone();
    let key = args.get("--key").expect("--key PATH is required").clone();
    let file_path = args.get("--file").expect("--file PATH is required").clone();
    let idle_timeout_ms: u64 = args
        .get("--idle-timeout-ms")
        .map(|s| s.parse().unwrap())
        .unwrap_or(30_000);
    let overall_timeout_s: u64 = args
        .get("--timeout-s")
        .map(|s| s.parse().unwrap())
        .unwrap_or(120);
    let cc_algorithm = args
        .get("--cc-algorithm")
        .cloned()
        .unwrap_or_else(|| "cubic".to_string());

    let file_data = std::fs::read(&file_path)
        .unwrap_or_else(|e| panic!("[qcserver] read --file {file_path}: {e:?}"));
    eprintln!(
        "[qcserver] loaded {} bytes from {}",
        file_data.len(),
        file_path
    );

    let mut socket = mio::net::UdpSocket::bind(listen)
        .unwrap_or_else(|e| panic!("[qcserver] bind {listen}: {e:?}"));
    let local_addr = socket.local_addr().unwrap();

    let mut poll = mio::Poll::new().unwrap();
    poll.registry()
        .register(&mut socket, mio::Token(0), mio::Interest::READABLE)
        .unwrap();
    let mut events = mio::Events::with_capacity(1024);

    let mut config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
    config
        .load_cert_chain_from_pem_file(&cert)
        .unwrap_or_else(|e| panic!("[qcserver] load cert {cert}: {e:?}"));
    config
        .load_priv_key_from_pem_file(&key)
        .unwrap_or_else(|e| panic!("[qcserver] load key {key}: {e:?}"));
    config
        .set_application_protos(&[b"pvseed-quiche-survey"])
        .unwrap();
    config.set_max_idle_timeout(idle_timeout_ms);
    // Flow-control windows LARGER than any test file this harness will ever
    // serve, so stream/connection flow control can never become the
    // bottleneck -- congestion control should be the only thing gating
    // throughput, since that is what this survey measures. (An earlier
    // version of this harness used 32/64MB, smaller than the 40MB test
    // file used by testbed/scenarios/quiche_migrate_demo.sh -- the server
    // hit STREAM_DATA_BLOCKED at the 32MB wall and the transfer stalled
    // permanently; confirmed via qlog "quic:packet_sent" frame_type
    // "stream_data_blocked", limit=33554432. Fixed by raising both limits
    // well above any realistic file size used in this survey.)
    config.set_initial_max_data(512 * 1024 * 1024);
    config.set_initial_max_stream_data_bidi_local(256 * 1024 * 1024);
    config.set_initial_max_stream_data_bidi_remote(256 * 1024 * 1024);
    config.set_initial_max_streams_bidi(4);
    // Deliberately NOT overriding max_send_udp_payload_size or
    // initial_congestion_window_packets: library defaults throughout
    // (MAX_SEND_UDP_PAYLOAD_SIZE=1200, DEFAULT_INITIAL_CONGESTION_WINDOW_PACKETS=10,
    // DEFAULT_INITIAL_RTT=333ms -- see quiche/quiche/src/lib.rs), so the
    // discriminator constants computed from source apply directly, with no
    // "which demo-app override did you use" ambiguity.
    config
        .set_cc_algorithm_name(&cc_algorithm)
        .unwrap_or_else(|e| panic!("[qcserver] bad --cc-algorithm {cc_algorithm}: {e:?}"));

    eprintln!(
        "[qcserver] listening on {local_addr} cc_algorithm={cc_algorithm} idle_timeout_ms={idle_timeout_ms}"
    );

    let mut buf = [0u8; MAX_BUF];
    let mut out = [0u8; MAX_BUF];

    let mut conn: Option<quiche::Connection> = None;
    let mut req_seen = false;
    let mut stream_id: u64 = 0;
    let mut file_offset: usize = 0;
    let mut sent_fin = false;

    // Pacing: quiche (pacing enabled by default -- RecoveryConfig.pacing,
    // set true in Config::with_tls_ctx) hands back each packet's intended
    // release time in SendInfo.at and expects the APPLICATION to respect it
    // (see the "Pacing" section of quiche/quiche/src/lib.rs's module docs).
    // Ignoring `at` and blasting every cwnd-sized batch of packets back to
    // back as fast as the loop can execute defeats that pacing and can
    // overrun the shaped path's small tbf token bucket, causing bursty loss
    // and severe self-inflicted queueing delay (observed live: RTT samples
    // of 260-270ms on a path shaped for ~40ms, before the transfer stalled
    // outright on STREAM_DATA_BLOCKED -- see the flow-control comment above).
    // Fix: still send whatever conn.send() returns immediately (it is
    // already serialized and quiche has already recorded it as in-flight,
    // so withholding it would desync quiche's own bookkeeping), but stop
    // asking for MORE packets once `at` is in the future, and use that
    // instant to bound the next poll() timeout instead of a tight loop.
    let mut next_send_at: Option<Instant> = None;

    let start = Instant::now();
    let overall_deadline = start + Duration::from_secs(overall_timeout_s);

    loop {
        if Instant::now() > overall_deadline {
            eprintln!("[qcserver] FATAL overall --timeout-s exceeded, exiting");
            // See the matching comment in qcclient.rs: drop `conn` explicitly
            // first so its qlog BufWriter flushes before process::exit skips
            // all destructors.
            drop(conn);
            std::io::stdout().flush().ok();
            std::io::stderr().flush().ok();
            std::process::exit(1);
        }

        let now = Instant::now();
        let pacing_wait = next_send_at.map(|at| at.saturating_duration_since(now));
        let poll_timeout = conn
            .as_ref()
            .and_then(|c| c.timeout())
            .map(|d| d.min(Duration::from_millis(200)))
            .or(Some(Duration::from_millis(200)))
            .map(|d| match pacing_wait {
                Some(pw) => d.min(pw),
                None => d,
            });
        poll.poll(&mut events, poll_timeout).unwrap();

        if events.is_empty() {
            if let Some(c) = conn.as_mut() {
                c.on_timeout();
            }
        }

        'read: loop {
            let (len, from) = match socket.recv_from(&mut buf) {
                Ok(v) => v,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break 'read,
                Err(e) => {
                    eprintln!("[qcserver] recv_from error: {e:?}");
                    break 'read;
                },
            };

            let pkt_buf = &mut buf[..len];

            if conn.is_none() {
                let hdr = match quiche::Header::from_slice(pkt_buf, quiche::MAX_CONN_ID_LEN) {
                    Ok(v) => v,
                    Err(e) => {
                        eprintln!("[qcserver] header parse failed: {e:?}");
                        continue 'read;
                    },
                };

                if hdr.ty != quiche::Type::Initial {
                    eprintln!(
                        "[qcserver] first packet from {from} is not Initial (ty={:?}), dropping",
                        hdr.ty
                    );
                    continue 'read;
                }

                if !quiche::version_is_supported(hdr.version) {
                    eprintln!("[qcserver] unsupported version, sending negotiation");
                    let len =
                        quiche::negotiate_version(&hdr.scid, &hdr.dcid, &mut out).unwrap();
                    socket.send_to(&out[..len], from).ok();
                    continue 'read;
                }

                let scid_bytes = gen_cid();
                let scid = quiche::ConnectionId::from_vec(scid_bytes.to_vec());

                eprintln!(
                    "[qcserver] SERVER_ACCEPT new connection from {from} dcid={:?} scid={:?} at {:?}",
                    hdr.dcid, scid, Instant::now()
                );

                let mut new_conn = quiche::accept(&scid, None, local_addr, from, &mut config)
                    .unwrap_or_else(|e| panic!("[qcserver] accept: {e:?}"));

                if let Ok(dir) = std::env::var("QLOGDIR") {
                    let id = format!("{scid:?}")
                        .chars()
                        .filter(|c| c.is_ascii_alphanumeric())
                        .collect::<String>();
                    let path = format!("{dir}/server-{id}.sqlog");
                    match std::fs::File::create(&path) {
                        Ok(f) => {
                            new_conn.set_qlog(
                                Box::new(std::io::BufWriter::new(f)),
                                "qcserver qlog".to_string(),
                                format!("qcserver id={id}"),
                            );
                            eprintln!("[qcserver] qlog -> {path}");
                        },
                        Err(e) => eprintln!("[qcserver] could not create qlog file {path}: {e:?}"),
                    }
                }

                conn = Some(new_conn);
            }

            let c = conn.as_mut().unwrap();
            let recv_info = quiche::RecvInfo {
                to: local_addr,
                from,
            };
            if let Err(e) = c.recv(pkt_buf, recv_info) {
                eprintln!("[qcserver] conn.recv from {from} failed: {e:?}");
            }
        }

        if let Some(c) = conn.as_mut() {
            if c.is_established() {
                issue_spare_scids(c);
            }

            // Surface path events for visibility (server side sees New /
            // PeerMigrated once the peer's non-probing packets arrive from a
            // new 4-tuple).
            while let Some(pe) = c.path_event_next() {
                eprintln!("[qcserver] PATH_EVENT {pe:?} at {:?}", Instant::now());
            }

            if c.is_established() && !req_seen {
                let mut got_any = false;
                for sid in c.readable() {
                    let mut rbuf = [0u8; 512];
                    loop {
                        match c.stream_recv(sid, &mut rbuf) {
                            Ok((n, fin)) => {
                                got_any = true;
                                eprintln!(
                                    "[qcserver] got {n} request bytes on stream {sid} (fin={fin})"
                                );
                            },
                            Err(quiche::Error::Done) => break,
                            Err(e) => {
                                eprintln!("[qcserver] stream_recv error: {e:?}");
                                break;
                            },
                        }
                    }
                    if got_any {
                        stream_id = sid;
                        req_seen = true;
                        break;
                    }
                }
            }

            if req_seen && !sent_fin {
                loop {
                    let end = std::cmp::min(file_offset + 8192, file_data.len());
                    let chunk = &file_data[file_offset..end];
                    let is_last = end == file_data.len();
                    match c.stream_send(stream_id, chunk, is_last) {
                        Ok(n) => {
                            file_offset += n;
                            if is_last && file_offset == file_data.len() {
                                sent_fin = true;
                                eprintln!(
                                    "[qcserver] SERVER_SENT_ALL {} bytes, fin sent at {:?}",
                                    file_data.len(),
                                    Instant::now()
                                );
                                break;
                            }
                            if n == 0 {
                                break;
                            }
                        },
                        Err(quiche::Error::Done) => break,
                        Err(e) => {
                            eprintln!("[qcserver] stream_send error: {e:?}");
                            break;
                        },
                    }
                }
            }

            next_send_at = None;
            loop {
                let (write, send_info) = match c.send(&mut out) {
                    Ok(v) => v,
                    Err(quiche::Error::Done) => break,
                    Err(e) => {
                        eprintln!("[qcserver] send error: {e:?}");
                        c.close(false, 0x1, b"fail").ok();
                        break;
                    },
                };

                if !send_with_retry(&socket, &out[..write], send_info.to, "qcserver") {
                    break;
                }

                if send_info.at > Instant::now() {
                    // This packet was already sent (see comment above), but
                    // quiche wants the NEXT one paced later -- stop asking
                    // for more until then.
                    next_send_at = Some(send_info.at);
                    break;
                }
            }

            if c.is_closed() {
                eprintln!("[qcserver] connection closed. stats={:?}", c.stats());
                for ps in c.path_stats() {
                    eprintln!("[qcserver] path_stats: {ps:?}");
                }
                println!("[qcserver] DONE");
                break;
            }
        }
    }

    std::io::stdout().flush().ok();
}
