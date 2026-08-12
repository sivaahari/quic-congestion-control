// qcclient -- PV-Seed quiche survey harness, client half.
//
// Downloads one file over a single QUIC stream, starting on an explicitly
// bound local address ("path A"), and MIGRATE_AFTER_MS into the transfer
// actively migrates to a second, explicitly bound local address ("path B")
// using quiche's public client-initiated migration API:
//   conn.probe_path(local_b, peer) -> wait for PathEvent::Validated
//   -> conn.migrate(local_b, peer)
// (quiche/quiche/src/lib.rs: pub fn probe_path / pub fn migrate).
//
// This is client-INITIATED migration: a real local-address change (path A
// 4-tuple -> path B 4-tuple), driven entirely by this program, matching the
// picoquic and quic-go harnesses' methodology in this survey.
//
// Both local sockets are bound up front (mirrors quiche/apps/src/client.rs's
// own --perform-migration handling), but the probe is not sent until
// MIGRATE_AFTER_MS has elapsed since the request was sent -- a controlled,
// timed trigger rather than "as soon as technically possible", so the
// migration instant is known for offline qlog analysis.

use std::collections::HashMap;
use std::io::Write;
use std::net::SocketAddr;
use std::time::Duration;
use std::time::Instant;

const MAX_BUF: usize = 65535;
const REQUEST_STREAM_ID: u64 = 0;

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

// Includes a static counter, not just a clock read -- see the matching
// comment in qcserver.rs (issue_spare_scids can call this several times in
// a tight loop, faster than the nanosecond clock is guaranteed to tick).
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
    gen_u128(0xC2B2AE3D27D4EB4Fu128).to_be_bytes()
}

fn gen_reset_token() -> u128 {
    gen_u128(0x165667B19E3779F9u128)
}

/// See qcserver.rs's issue_spare_scids for why this matters: our own
/// probe_path() call needs available_dcids() > 0, which only becomes true
/// once the SERVER's NEW_CONNECTION_ID frames arrive -- this function is the
/// client-side half of the same exchange (handing spare SCIDs to the server),
/// kept for protocol symmetry/robustness even though this harness's server
/// never itself calls migrate()/probe_path().
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
/// instead of silently discarding it -- see the long comment on this same
/// function in qcserver.rs for why this matters (it is the fix for a
/// confirmed ~600KB permanent stream-delivery gap this harness produced
/// before the fix existed).
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

    let server_addr: SocketAddr = args
        .get("--server-addr")
        .expect("--server-addr ADDR:PORT is required")
        .parse()
        .expect("--server-addr must be ADDR:PORT");
    let local_a: SocketAddr = args
        .get("--local-a")
        .expect("--local-a ADDR:PORT is required (path A bind)")
        .parse()
        .expect("--local-a must be ADDR:PORT");
    let local_b: SocketAddr = args
        .get("--local-b")
        .expect("--local-b ADDR:PORT is required (path B bind)")
        .parse()
        .expect("--local-b must be ADDR:PORT");
    let migrate_after_ms: u64 = args
        .get("--migrate-after-ms")
        .map(|s| s.parse().unwrap())
        .unwrap_or(5000);
    let sni = args
        .get("--sni")
        .cloned()
        .unwrap_or_else(|| "pvseed.test".to_string());
    let ca_path = args.get("--ca").expect("--ca PATH is required").clone();
    let out_path = args.get("--out").cloned();
    let overall_timeout_s: u64 = args
        .get("--timeout-s")
        .map(|s| s.parse().unwrap())
        .unwrap_or(90);
    let request = args
        .get("--request")
        .cloned()
        .unwrap_or_else(|| "GET bigfile.bin\n".to_string());
    let cc_algorithm = args
        .get("--cc-algorithm")
        .cloned()
        .unwrap_or_else(|| "cubic".to_string());

    // --- sockets: BOTH bound explicitly up front (path A always used first;
    // path B only starts carrying traffic once probe_path()/migrate() run) ---
    let mut socket_a = mio::net::UdpSocket::bind(local_a)
        .unwrap_or_else(|e| panic!("[qcclient] bind --local-a {local_a}: {e:?}"));
    let mut socket_b = mio::net::UdpSocket::bind(local_b)
        .unwrap_or_else(|e| panic!("[qcclient] bind --local-b {local_b}: {e:?}"));
    let bound_a = socket_a.local_addr().unwrap();
    let bound_b = socket_b.local_addr().unwrap();

    let mut poll = mio::Poll::new().unwrap();
    poll.registry()
        .register(&mut socket_a, mio::Token(0), mio::Interest::READABLE)
        .unwrap();
    poll.registry()
        .register(&mut socket_b, mio::Token(1), mio::Interest::READABLE)
        .unwrap();
    let mut events = mio::Events::with_capacity(1024);

    // --- TLS / QUIC config ---
    let mut config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
    config
        .load_verify_locations_from_file(&ca_path)
        .unwrap_or_else(|e| panic!("[qcclient] load --ca {ca_path}: {e:?}"));
    config.verify_peer(true);
    config
        .set_application_protos(&[b"pvseed-quiche-survey"])
        .unwrap();
    config.set_max_idle_timeout(30_000);
    // See the matching (longer) comment in qcserver.rs: these must stay
    // larger than any test file this harness serves, or the sender hits
    // STREAM_DATA_BLOCKED and the transfer stalls permanently.
    config.set_initial_max_data(512 * 1024 * 1024);
    config.set_initial_max_stream_data_bidi_local(256 * 1024 * 1024);
    config.set_initial_max_stream_data_bidi_remote(256 * 1024 * 1024);
    config.set_initial_max_streams_bidi(4);
    // Library defaults for max_send_udp_payload_size / initial cwnd / initial
    // RTT -- see the matching comment in qcserver.rs.
    config
        .set_cc_algorithm_name(&cc_algorithm)
        .unwrap_or_else(|e| panic!("[qcclient] bad --cc-algorithm {cc_algorithm}: {e:?}"));

    let scid_bytes = gen_cid();
    let scid = quiche::ConnectionId::from_ref(&scid_bytes);

    eprintln!(
        "[qcclient] connecting to {server_addr} from {bound_a} (path A) sni={sni} at {:?}",
        Instant::now()
    );

    let mut conn = quiche::connect(Some(&sni), &scid, bound_a, server_addr, &mut config)
        .unwrap_or_else(|e| panic!("[qcclient] connect: {e:?}"));

    if let Ok(dir) = std::env::var("QLOGDIR") {
        let id = format!("{scid:?}")
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .collect::<String>();
        let path = format!("{dir}/client-{id}.sqlog");
        match std::fs::File::create(&path) {
            Ok(f) => {
                conn.set_qlog(
                    Box::new(std::io::BufWriter::new(f)),
                    "qcclient qlog".to_string(),
                    format!("qcclient id={id}"),
                );
                eprintln!("[qcclient] qlog -> {path}");
            },
            Err(e) => eprintln!("[qcclient] could not create qlog file {path}: {e:?}"),
        }
    }

    let mut buf = [0u8; MAX_BUF];
    let mut out = [0u8; MAX_BUF];

    // Initial flight, always on path A.
    let (write, send_info) = conn.send(&mut out).expect("[qcclient] initial send failed");
    if !send_with_retry(&socket_a, &out[..write], send_info.to, "qcclient") {
        panic!("[qcclient] initial send_to failed even after retrying");
    }

    let mut out_file = out_path.as_ref().map(|p| {
        std::fs::File::create(p).unwrap_or_else(|e| panic!("[qcclient] create --out {p}: {e:?}"))
    });

    let mut request_sent = false;
    let mut transfer_start: Option<Instant> = None;
    let mut probe_triggered_log = false;
    let mut probe_sent = false;
    let mut migrated = false;
    let mut migrate_deadline_confirmed = false;
    let mut total_bytes: u64 = 0;
    let mut fin_received = false;
    let mut last_progress_log = Instant::now();
    // Pacing -- see the detailed comment in qcserver.rs. Same fix: stop
    // asking conn.send_on_path() for more packets once it hands back one
    // scheduled for the future, and bound the next poll() timeout by that
    // instant instead of spinning a tight send loop.
    let mut next_send_at: Option<Instant> = None;

    let proc_start = Instant::now();
    let overall_deadline = proc_start + Duration::from_secs(overall_timeout_s);

    loop {
        if Instant::now() > overall_deadline {
            eprintln!("[qcclient] FATAL overall --timeout-s exceeded, exiting");
            drop(conn);
            std::io::stdout().flush().ok();
            std::io::stderr().flush().ok();
            std::process::exit(1);
        }

        let now = Instant::now();
        let pacing_wait = next_send_at.map(|at| at.saturating_duration_since(now));
        let poll_timeout = conn
            .timeout()
            .map(|d| d.min(Duration::from_millis(100)))
            .or(Some(Duration::from_millis(100)))
            .map(|d| match pacing_wait {
                Some(pw) => d.min(pw),
                None => d,
            });
        poll.poll(&mut events, poll_timeout).unwrap();

        if events.is_empty() {
            conn.on_timeout();
        }

        for event in &events {
            let (socket, local_addr) = match event.token() {
                mio::Token(0) => (&socket_a, bound_a),
                mio::Token(1) => (&socket_b, bound_b),
                _ => continue,
            };

            loop {
                let (len, from) = match socket.recv_from(&mut buf) {
                    Ok(v) => v,
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                    Err(e) => {
                        eprintln!("[qcclient] recv_from({local_addr}) error: {e:?}");
                        break;
                    },
                };

                let recv_info = quiche::RecvInfo {
                    to: local_addr,
                    from,
                };
                if let Err(e) = conn.recv(&mut buf[..len], recv_info) {
                    eprintln!("[qcclient] conn.recv from {from} failed: {e:?}");
                }
            }
        }

        if conn.is_established() {
            issue_spare_scids(&mut conn);
        }

        if conn.is_established() && !request_sent {
            conn.stream_send(REQUEST_STREAM_ID, request.as_bytes(), true)
                .unwrap_or_else(|e| panic!("[qcclient] initial stream_send failed: {e:?}"));
            request_sent = true;
            transfer_start = Some(Instant::now());
            eprintln!(
                "[qcclient] REQUEST_SENT {:?} at {:?} (local={} peer={})",
                request.trim_end(),
                transfer_start.unwrap(),
                bound_a,
                server_addr
            );
        }

        // --- timed migration trigger ---
        // conn.probe_path() needs a spare Destination Connection ID (the
        // server sends these via NEW_CONNECTION_ID frames shortly after the
        // handshake completes -- quiche/apps/src/client.rs gates its own
        // --perform-migration probe on `conn.available_dcids() > 0` for
        // exactly this reason). If the elapsed-time trigger fires before a
        // spare DCID has arrived, retry on subsequent loop iterations rather
        // than giving up -- in the real (multi-second) testbed trigger this
        // will not be observably different, but under a very fast/short
        // trigger (e.g. a loopback smoke test) the DCID can legitimately not
        // have arrived yet.
        if request_sent && !probe_triggered_log {
            if let Some(t0) = transfer_start {
                if t0.elapsed() >= Duration::from_millis(migrate_after_ms) {
                    eprintln!(
                        "[qcclient] MIGRATE_TRIGGER at {:?} (t+{:?} since request sent) local_b={bound_b}",
                        Instant::now(),
                        t0.elapsed()
                    );
                    probe_triggered_log = true;
                }
            }
        }

        if probe_triggered_log && !probe_sent && conn.available_dcids() > 0 {
            match conn.probe_path(bound_b, server_addr) {
                Ok(dcid_seq) => {
                    eprintln!(
                        "[qcclient] MIGRATE_PROBE_SENT dcid_seq={dcid_seq} at {:?}",
                        Instant::now()
                    );
                    probe_sent = true;
                },
                Err(quiche::Error::OutOfIdentifiers) => {
                    // Transient: retry next loop iteration.
                },
                Err(e) => {
                    eprintln!("[qcclient] MIGRATE_PROBE_FAILED (terminal): {e:?}");
                    probe_sent = true; // stop retrying on non-transient errors
                },
            }
        }

        // --- path events: on validation, commit the migration ---
        while let Some(pe) = conn.path_event_next() {
            eprintln!("[qcclient] PATH_EVENT {pe:?} at {:?}", Instant::now());
            match pe {
                quiche::PathEvent::Validated(la, pa) if la == bound_b && !migrated => {
                    match conn.migrate(la, pa) {
                        Ok(_) => {
                            migrated = true;
                            eprintln!(
                                "[qcclient] MIGRATE_SWITCH_CALLED at {:?} (conn.migrate({la}, {pa}) returned Ok; \
                                 quiche's migrate() switches the active path synchronously)",
                                Instant::now()
                            );
                        },
                        Err(e) => {
                            eprintln!("[qcclient] MIGRATE_SWITCH_FAILED: {e:?}");
                        },
                    }
                },
                quiche::PathEvent::FailedValidation(la, pa) => {
                    eprintln!("[qcclient] MIGRATE_VALIDATION_FAILED local={la} peer={pa}");
                },
                _ => {},
            }
        }

        if migrated && !migrate_deadline_confirmed {
            for ps in conn.path_stats() {
                if ps.local_addr == bound_b && ps.active {
                    eprintln!(
                        "[qcclient] MIGRATE_CUTOVER_CONFIRMED at {:?}: path_stats active=true for local={} peer={} cwnd={} rtt={:?}",
                        Instant::now(), ps.local_addr, ps.peer_addr, ps.cwnd, ps.rtt
                    );
                    migrate_deadline_confirmed = true;
                }
            }
        }

        // --- read any available response bytes ---
        if std::env::var_os("QCCLIENT_DEBUG_READABLE").is_some() {
            let ids: Vec<u64> = conn.readable().collect();
            if !ids.is_empty() || last_progress_log.elapsed() < Duration::from_millis(50) {
                eprintln!(
                    "[qcclient][DEBUG] readable={ids:?} total_bytes={total_bytes} stream0_finished={} at {:?}",
                    conn.stream_finished(REQUEST_STREAM_ID),
                    Instant::now()
                );
            }
        }
        for sid in conn.readable() {
            if sid != REQUEST_STREAM_ID {
                eprintln!("[qcclient] UNEXPECTED readable stream id {sid} (expected {REQUEST_STREAM_ID})");
                continue;
            }
            loop {
                match conn.stream_recv(sid, &mut buf) {
                    Ok((n, fin)) => {
                        if let Some(f) = out_file.as_mut() {
                            f.write_all(&buf[..n]).expect("[qcclient] write --out failed");
                        }
                        total_bytes += n as u64;
                        if fin {
                            fin_received = true;
                            eprintln!(
                                "[qcclient] DOWNLOAD_COMPLETE {total_bytes} bytes at {:?} (t+{:?})",
                                Instant::now(),
                                transfer_start.map(|t| t.elapsed()).unwrap_or_default()
                            );
                        }
                    },
                    Err(quiche::Error::Done) => break,
                    Err(e) => {
                        eprintln!("[qcclient] stream_recv error: {e:?}");
                        break;
                    },
                }
            }
        }

        if last_progress_log.elapsed() >= Duration::from_secs(1) {
            eprintln!(
                "[qcclient] progress: {total_bytes} bytes at t+{:?}",
                transfer_start.map(|t| t.elapsed()).unwrap_or_default()
            );
            last_progress_log = Instant::now();
        }

        // --- send phase: pump both sockets on every path known to quiche ---
        next_send_at = None;
        for (socket, local_addr) in [(&socket_a, bound_a), (&socket_b, bound_b)] {
            for peer_addr in conn.paths_iter(local_addr) {
                loop {
                    let (write, send_info) =
                        match conn.send_on_path(&mut out, Some(local_addr), Some(peer_addr)) {
                            Ok(v) => v,
                            Err(quiche::Error::Done) => break,
                            Err(e) => {
                                eprintln!(
                                    "[qcclient] send_on_path({local_addr}->{peer_addr}) error: {e:?}"
                                );
                                conn.close(false, 0x1, b"fail").ok();
                                break;
                            },
                        };

                    if !send_with_retry(socket, &out[..write], send_info.to, "qcclient") {
                        break;
                    }

                    if send_info.at > Instant::now() {
                        next_send_at = Some(match next_send_at {
                            Some(existing) => existing.min(send_info.at),
                            None => send_info.at,
                        });
                        break;
                    }
                }
            }
        }

        if fin_received && !conn.is_closed() {
            conn.close(true, 0x00, b"done").ok();
        }

        if conn.is_closed() {
            eprintln!("[qcclient] connection closed. stats={:?}", conn.stats());
            for ps in conn.path_stats() {
                eprintln!("[qcclient] path_stats: {ps:?}");
            }
            break;
        }
    }

    if let Some(f) = out_file.as_mut() {
        f.flush().ok();
    }

    if !fin_received {
        eprintln!("[qcclient] WARNING: connection closed before download completed ({total_bytes} bytes received)");
        println!("[qcclient] DONE_INCOMPLETE");
        // std::process::exit() skips running destructors process-wide, which
        // would leave `conn`'s qlog BufWriter unflushed and its .sqlog file
        // truncated with a corrupt final record. Explicitly drop `conn` (and
        // flush stdout/stderr) first so the qlog -- often the MOST important
        // artifact from a failed run -- is still fully readable afterward.
        drop(conn);
        std::io::stdout().flush().ok();
        std::io::stderr().flush().ok();
        std::process::exit(1);
    }

    println!("[qcclient] DONE");
}
