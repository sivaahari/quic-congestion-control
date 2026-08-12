// common.h -- shared helpers for the PV-Seed msquic survey harness
// (harness/msquic/{server,client}.cpp).
//
// msquic's public API is callback/event driven (QUIC_CONNECTION_CALLBACK,
// QUIC_STREAM_CALLBACK, QUIC_LISTENER_CALLBACK) -- unlike quic-go/quiche's
// synchronous polling APIs used by the other harnesses in this survey. This
// header provides:
//   - the mandatory `MsQuic` global that msquic.hpp's C++ wrapper classes
//     (MsQuicConnection, MsQuicStream, ...) dereference internally. Must be
//     assigned (MsQuic = &ApiInstance;) once in main() before ANY wrapper
//     object is constructed.
//   - a monotonic microsecond clock relative to process start, used to
//     timestamp every log line so STATS/MARKER lines from a run can be
//     correlated by analysis/parse_qlog_msquic.py.
//   - a thread-safe stdout logger. NOTE: msquic itself is built with
//     -DQUIC_LOGGING_TYPE=stdout (see harness/msquic/build.sh and
//     _build/msquic_configure_build.sh), so msquic's OWN internal
//     QuicTraceEvent/QuicTraceLog* calls ALSO write to this process's real
//     stdout, interleaved with our lines. That is intentional -- it is our
//     primary qualitative instrumentation channel (e.g. the literal
//     "Set active (rebind=%hhu)" and "Congestion event" trace lines), never
//     needing LTTng/babeltrace2/CLOG/dotnet. Our own lines are prefixed
//     "[mq_server]"/"[mq_client]" so the parser can tell them apart from
//     msquic's free-form "[conn][%p] ... [EventName:file:line]" lines.
//   - a background QUIC_STATISTICS_V2 polling loop (QUIC_PARAM_CONN_
//     STATISTICS_V2 under the hood, via MsQuicConnection::GetStatistics),
//     shared by both client and server, since both sides poll congestion
//     window / RTT independently.
//
// Deliberately does NOT define QUIC_API_ENABLE_PREVIEW_FEATURES: the library
// was built WITHOUT preview features
// (_build/msquic_configure_build.sh has no -DQUIC_API_ENABLE_PREVIEW_FEATURES),
// so defining it here would desync struct layouts (e.g. QUIC_STATISTICS_V2,
// QUIC_SETTINGS) between this translation unit and the built library -- an
// ABI mismatch. sample.c in the msquic tree can define it because there the
// tool and library are always built together from the same CMake pass.

#pragma once

#include <atomic>
#include <chrono>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>

// msquic.h itself #includes msquic_posix.h on Linux (gives us QUIC_ADDR,
// QuicAddrFromString, QuicAddrToString, QUIC_ADDR_STR, ...). Deliberately
// NOT including msquichelper.h: it pulls in the internal quic_platform.h,
// which defines CX_PLATFORM_TYPE -- and once that macro is defined,
// msquic.hpp's CxPlatEvent/CxPlatLock/CxPlatThread/... convenience wrappers
// (guarded by #ifdef CX_PLATFORM_TYPE) try to compile against internal
// platform primitives (CxPlatLockInitialize, CXPLAT_THREAD, ...) that are
// NOT declared by any public header, i.e. only available inside msquic's
// OWN build (precomp.h etc.), not to an external consumer like this
// harness. Confirmed by first-attempt build errors (~80 undeclared-symbol
// errors, all inside that one #ifdef block) -- see
// _build/harness_build1.log if this needs revisiting. We do not need any of
// those helpers (this harness uses plain std::thread/std::mutex instead),
// so simply never defining CX_PLATFORM_TYPE sidesteps the whole block.
extern "C" {
#include "msquic.h"
}
#include "msquic.hpp"

// Required by msquic.hpp: every MsQuicXxx wrapper struct/class dereferences
// this global via `MsQuic->SomeApiFn(...)`.
const MsQuicApi* MsQuic = nullptr;

namespace pvseed {

// Trivial replacement for msquichelper.h's ConvertArgToAddress (not included
// here -- see the comment above on CX_PLATFORM_TYPE). QuicAddrFromString/
// QuicAddrSetFamily/QuicAddrSetPort come from msquic_posix.h, transitively
// included by msquic.h above.
inline BOOLEAN ConvertArgToAddress(const char* Arg, uint16_t Port, QUIC_ADDR* Address) {
    if (strcmp("*", Arg) == 0) {
        memset(Address, 0, sizeof(*Address));
        QuicAddrSetFamily(Address, QUIC_ADDRESS_FAMILY_UNSPEC);
        QuicAddrSetPort(Address, Port);
        return TRUE;
    }
    return QuicAddrFromString(Arg, Port, Address);
}

inline std::chrono::steady_clock::time_point& ProcessStartRef() {
    static std::chrono::steady_clock::time_point t0 = std::chrono::steady_clock::now();
    return t0;
}
// Call once, first thing in main(), so t_us=0 means "process start" for both
// client and server logs (matches the convention of every other harness in
// this survey: relative_time from connection/process start).
inline void MarkProcessStart() { ProcessStartRef() = std::chrono::steady_clock::now(); }

inline uint64_t NowUs() {
    return (uint64_t)std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now() - ProcessStartRef()).count();
}

inline std::mutex& LogMutex() {
    static std::mutex m;
    return m;
}

// All lines: "[tag] t_us=<n> <msg>". `tag` is "mq_server" or "mq_client".
inline void Logf(const char* Tag, const char* Fmt, ...) {
    char Buf[2048];
    va_list Args;
    va_start(Args, Fmt);
    vsnprintf(Buf, sizeof(Buf), Fmt, Args);
    va_end(Args);
    std::lock_guard<std::mutex> lock(LogMutex());
    fprintf(stdout, "[%s] t_us=%llu %s\n", Tag, (unsigned long long)NowUs(), Buf);
    fflush(stdout);
}

inline std::string AddrToString(const QUIC_ADDR* Addr) {
    if (Addr == nullptr) return std::string("<null>");
    QUIC_ADDR_STR Str;
    if (QuicAddrToString(Addr, &Str)) {
        return std::string(Str.Address);
    }
    return std::string("<unprintable>");
}

// Shared background stats-polling loop. Polls QUIC_STATISTICS_V2 off
// `*ConnPtr` (nullptr-safe: skips a cycle if no connection is live yet, e.g.
// before the client has connected) every IntervalMs and logs one STATS line
// per sample. `Tag` distinguishes client/server in the log line.
//
// CSV columns emitted downstream by analysis/parse_qlog_msquic.py:
//   time_us, cwnd, bytes_in_flight, smoothed_rtt, min_rtt, latest_rtt
// QUIC_STATISTICS_V2 has no per-sample bytes_in_flight (that field only
// exists on the PREVIEW-gated QUIC_NETWORK_STATISTICS, which this harness
// does not use -- see the ABI-mismatch note above) so bytes_in_flight is
// left empty in the CSV; documented as a known limitation in the report.
inline void StatsPollLoop(
    const char* Tag,
    std::atomic<bool>* Active,
    std::atomic<MsQuicConnection*>* ConnPtr,
    uint32_t IntervalMs)
{
    while (Active->load(std::memory_order_relaxed)) {
        MsQuicConnection* Conn = ConnPtr->load(std::memory_order_acquire);
        if (Conn != nullptr && Conn->Handle != nullptr) {
            QUIC_STATISTICS_V2 Stats;
            memset(&Stats, 0, sizeof(Stats));
            QUIC_STATUS Status = Conn->GetStatistics(&Stats);
            if (QUIC_SUCCEEDED(Status)) {
                Logf(Tag,
                    "STATS cwnd=%u srtt_us=%u min_rtt_us=%u max_rtt_us=%u "
                    "rtt_var_us=%u cc_events=%u persistent_cc_events=%u "
                    "send_total_bytes=%llu send_stream_bytes=%llu send_mtu=%u",
                    Stats.SendCongestionWindow,
                    Stats.Rtt,
                    Stats.MinRtt,
                    Stats.MaxRtt,
                    Stats.RttVariance,
                    Stats.SendCongestionCount,
                    Stats.SendPersistentCongestionCount,
                    (unsigned long long)Stats.SendTotalBytes,
                    (unsigned long long)Stats.SendTotalStreamBytes,
                    (unsigned)Stats.SendPathMtu);
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(IntervalMs));
    }
}

// Minimal CLI arg parser: "--flag value" pairs only (no short flags, no
// "--flag=value"). Good enough for this harness and keeps parity with the
// quicgo/quiche harnesses' own simple parsers.
inline const char* GetArg(int argc, char** argv, const char* name, const char* def) {
    for (int i = 1; i + 1 < argc; ++i) {
        if (strcmp(argv[i], name) == 0) return argv[i + 1];
    }
    return def;
}
inline bool HasFlag(int argc, char** argv, const char* name) {
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], name) == 0) return true;
    }
    return false;
}
inline uint32_t GetArgU32(int argc, char** argv, const char* name, uint32_t def) {
    const char* v = GetArg(argc, argv, name, nullptr);
    return v ? (uint32_t)strtoul(v, nullptr, 10) : def;
}

} // namespace pvseed
