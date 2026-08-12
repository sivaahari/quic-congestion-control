// client.cpp -- PV-Seed msquic survey harness, client half.
//
// Downloads one file over a single QUIC stream, starting on an explicitly
// bound local address ("path A"), and MIGRATE_AFTER_MS into the transfer
// actively migrates the QUIC connection to a second, explicitly bound local
// address ("path B") using msquic's public client-initiated migration API:
//   MsQuicConnection::SetLocalAddr(QuicAddr)
//     -> MsQuic->SetParam(Handle, QUIC_PARAM_CONN_LOCAL_ADDRESS, ...)
// (src/inc/msquic.hpp; underlying handler at src/core/connection.c, the
// QUIC_PARAM_CONN_LOCAL_ADDRESS case of QuicConnParamSet -- see the source
// audit in the task report).
//
// This is client-INITIATED migration: a real local-address change (path A
// 4-tuple -> path B 4-tuple), driven entirely by this program, matching the
// picoquic/quic-go/quiche harnesses' methodology in this survey.
//
// SetParam() returning success does NOT mean the rebind has taken visible
// effect yet (msquic marshals it onto the connection's own worker thread) --
// this program polls GetLocalAddr() for the observable cutover, mirroring
// the same defensive pattern used in harness/quicgo/client/main.go, AND
// separately logs the async QUIC_CONNECTION_EVENT_LOCAL_ADDRESS_CHANGED
// event as an independent confirmation.
//
// Usage:
//   mq_client --server-addr 10.0.9.1:4433 --local-a 10.0.1.1:0 --local-b 10.0.3.1:0
//             --migrate-after-ms 5000 --sni pvseed.test --out downloaded.bin
//             [--cc cubic|bbr] [--timeout-s 90] [--stats-interval-ms 20]
//             [--alpn pvseed-msquic-survey]

#include "common.h"

#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <string>
#include <thread>

using namespace pvseed;

namespace {

std::atomic<bool> g_StatsActive{true};
std::atomic<MsQuicConnection*> g_ActiveConn{nullptr};

std::mutex g_DoneMutex;
std::condition_variable g_DoneCv;
bool g_Done = false;
bool g_DownloadOk = false;
// Cheap lock-free mirror of g_Done, polled by MigrationThreadFn's sleep loop
// so it can cancel itself early. Needed because --migrate-after-ms can
// legitimately be set far beyond the transfer's lifetime (e.g. the smoke
// test disables migration this way); without early cancellation the thread
// sits in a long sleep and main()'s MigThread.join() blocks past the
// connection's own SHUTDOWN_COMPLETE, so an external `timeout` wrapper can
// kill the whole process before fclose(g_OutFile) ever runs -- truncating
// the last buffered block of the output file. Discovered via exactly that
// symptom in testbed/scenarios/msquic_smoke.sh (520192/524288 bytes
// written, short by one 4096-byte stdio buffer).
std::atomic<bool> g_ConnDone{false};

FILE* g_OutFile = nullptr;
std::atomic<uint64_t> g_TotalBytes{0};
std::atomic<bool> g_FinReceived{false};

struct StreamCtx {
    MsQuicStream* Stream = nullptr;
};

QUIC_STATUS QUIC_API ClientStreamCallback(MsQuicStream* /*Stream*/, void* /*Context*/, QUIC_STREAM_EVENT* Event) {
    switch (Event->Type) {
    case QUIC_STREAM_EVENT_RECEIVE: {
        for (uint32_t i = 0; i < Event->RECEIVE.BufferCount; ++i) {
            const QUIC_BUFFER& B = Event->RECEIVE.Buffers[i];
            if (g_OutFile && B.Length > 0) {
                fwrite(B.Buffer, 1, B.Length, g_OutFile);
            }
            g_TotalBytes.fetch_add(B.Length);
        }
        break;
    }
    case QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN: {
        g_FinReceived.store(true);
        Logf("mq_client", "DOWNLOAD_COMPLETE %llu bytes", (unsigned long long)g_TotalBytes.load());
        // Close the connection now instead of relying on --idle-timeout-ms
        // (default 30s) to eventually notice inactivity: picoquic/quic-go/
        // quiche's harnesses all close explicitly right after the transfer
        // completes, and without this every repetition in
        // msquic_migrate_demo.sh would otherwise burn a full extra
        // idle-timeout period doing nothing.
        MsQuicConnection* Conn = g_ActiveConn.load(std::memory_order_acquire);
        if (Conn != nullptr) {
            Conn->Shutdown(0);
        }
        break;
    }
    case QUIC_STREAM_EVENT_SEND_COMPLETE:
        break;
    case QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE:
        Logf("mq_client", "STREAM_SHUTDOWN_COMPLETE");
        break;
    default:
        break;
    }
    return QUIC_STATUS_SUCCESS;
}

QUIC_STATUS QUIC_API ClientConnectionCallback(MsQuicConnection* Connection, void* /*Context*/, QUIC_CONNECTION_EVENT* Event) {
    switch (Event->Type) {
    case QUIC_CONNECTION_EVENT_CONNECTED: {
        QuicAddr Local, Remote;
        Connection->GetLocalAddr(Local);
        Connection->GetRemoteAddr(Remote);
        Logf("mq_client", "CONNECTED local=%s remote=%s",
             AddrToString(Local).c_str(), AddrToString(Remote).c_str());
        g_ActiveConn.store(Connection, std::memory_order_release);
        break;
    }
    case QUIC_CONNECTION_EVENT_LOCAL_ADDRESS_CHANGED:
        // Event-driven confirmation of our OWN migration, independent of the
        // polling loop in MigrationThreadFn below.
        Logf("mq_client", "MIGRATE_LOCAL_ADDR_CHANGED_EVENT new_local=%s",
             AddrToString(Event->LOCAL_ADDRESS_CHANGED.Address).c_str());
        break;
    case QUIC_CONNECTION_EVENT_PEER_ADDRESS_CHANGED:
        Logf("mq_client", "CLIENT_PEER_ADDR_CHANGED new_remote=%s",
             AddrToString(Event->PEER_ADDRESS_CHANGED.Address).c_str());
        break;
    case QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_TRANSPORT:
        Logf("mq_client", "SHUTDOWN_INITIATED_BY_TRANSPORT status=0x%x", Event->SHUTDOWN_INITIATED_BY_TRANSPORT.Status);
        break;
    case QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_PEER:
        Logf("mq_client", "SHUTDOWN_INITIATED_BY_PEER errorcode=%llu",
             (unsigned long long)Event->SHUTDOWN_INITIATED_BY_PEER.ErrorCode);
        break;
    case QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE:
        Logf("mq_client", "SHUTDOWN_COMPLETE");
        g_ActiveConn.store(nullptr, std::memory_order_release);
        g_ConnDone.store(true, std::memory_order_release);
        {
            std::lock_guard<std::mutex> lock(g_DoneMutex);
            g_Done = true;
            g_DownloadOk = g_FinReceived.load();
        }
        g_DoneCv.notify_all();
        break;
    default:
        break;
    }
    return QUIC_STATUS_SUCCESS;
}

void MigrationThreadFn(MsQuicConnection* Connection, std::string LocalBArg, uint32_t MigrateAfterMs) {
    // Sleep in short slices, polling g_ConnDone, instead of one long
    // sleep_for(MigrateAfterMs) -- see the g_ConnDone comment above for why
    // (a --migrate-after-ms set beyond the connection's actual lifetime
    // must not block MigThread.join() in main() past process shutdown).
    auto WakeAt = std::chrono::steady_clock::now() + std::chrono::milliseconds(MigrateAfterMs);
    while (std::chrono::steady_clock::now() < WakeAt) {
        if (g_ConnDone.load(std::memory_order_acquire)) {
            Logf("mq_client", "MIGRATE_SKIPPED connection already done before migrate-after-ms elapsed");
            return;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    if (g_ConnDone.load(std::memory_order_acquire)) {
        Logf("mq_client", "MIGRATE_SKIPPED connection already done before migrate-after-ms elapsed");
        return;
    }

    QuicAddr PreAddr;
    Connection->GetLocalAddr(PreAddr);
    std::string PreStr = AddrToString(PreAddr);

    Logf("mq_client", "MIGRATE_TRIGGER local_b_target=%s (pre-migration local=%s)",
         LocalBArg.c_str(), PreStr.c_str());

    size_t colon = LocalBArg.rfind(':');
    std::string ip = colon == std::string::npos ? LocalBArg : LocalBArg.substr(0, colon);
    uint16_t port = colon == std::string::npos ? 0 : (uint16_t)atoi(LocalBArg.substr(colon + 1).c_str());

    QUIC_ADDR RawAddr;
    memset(&RawAddr, 0, sizeof(RawAddr));
    if (!ConvertArgToAddress(ip.c_str(), port, &RawAddr)) {
        Logf("mq_client", "MIGRATE_FAILED bad --local-b address %s", LocalBArg.c_str());
        return;
    }
    QuicAddr LocalB;
    LocalB.SockAddr = RawAddr;

    QUIC_STATUS Status = Connection->SetLocalAddr(LocalB);
    Logf("mq_client", "MIGRATE_SETLOCALADDR_CALLED status=0x%x", Status);
    if (QUIC_FAILED(Status)) {
        Logf("mq_client", "MIGRATE_FAILED SetLocalAddr returned 0x%x", Status);
        return;
    }

    // Poll for the observable cutover (SetParam is marshaled onto the
    // connection's worker thread; success here only means it was queued).
    auto Deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    bool Confirmed = false;
    while (std::chrono::steady_clock::now() < Deadline) {
        if (g_ConnDone.load(std::memory_order_acquire)) {
            Logf("mq_client", "MIGRATE_CUTOVER_ABANDONED connection ended while waiting for cutover confirmation");
            return;
        }
        QuicAddr Cur;
        if (QUIC_SUCCEEDED(Connection->GetLocalAddr(Cur))) {
            if (AddrToString(Cur) != PreStr) {
                Confirmed = true;
                Logf("mq_client", "MIGRATE_CUTOVER_CONFIRMED new_local=%s (was %s)",
                     AddrToString(Cur).c_str(), PreStr.c_str());
                break;
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    if (!Confirmed) {
        Logf("mq_client", "MIGRATE_CUTOVER_TIMEOUT local address never changed from %s within 5s", PreStr.c_str());
    }
}

} // namespace

int main(int argc, char** argv) {
    MarkProcessStart();

    const char* ServerAddrArg = GetArg(argc, argv, "--server-addr", "10.0.9.1:4433");
    const char* LocalAArg = GetArg(argc, argv, "--local-a", "10.0.1.1:0");
    const char* LocalBArg = GetArg(argc, argv, "--local-b", "10.0.3.1:0");
    const char* Sni = GetArg(argc, argv, "--sni", "pvseed.test");
    const char* OutPath = GetArg(argc, argv, "--out", nullptr);
    const char* CcAlgo = GetArg(argc, argv, "--cc", "cubic");
    const char* Alpn = GetArg(argc, argv, "--alpn", "pvseed-msquic-survey");
    const char* Request = GetArg(argc, argv, "--request", "GET bigfile.bin\n");
    uint32_t MigrateAfterMs = GetArgU32(argc, argv, "--migrate-after-ms", 5000);
    uint32_t TimeoutS = GetArgU32(argc, argv, "--timeout-s", 90);
    uint32_t IdleTimeoutMs = GetArgU32(argc, argv, "--idle-timeout-ms", 30000);
    uint32_t StatsIntervalMs = GetArgU32(argc, argv, "--stats-interval-ms", 20);

    if (OutPath) {
        g_OutFile = fopen(OutPath, "wb");
        if (!g_OutFile) {
            fprintf(stderr, "cannot create --out %s\n", OutPath);
            return 2;
        }
    }

    MsQuicApi Api;
    if (!Api.IsValid()) {
        fprintf(stderr, "MsQuicOpen2 failed: 0x%x\n", Api.GetInitStatus());
        return 1;
    }
    MsQuic = &Api;

    MsQuicRegistration Registration("pvseed-msquic-survey-client", QUIC_EXECUTION_PROFILE_LOW_LATENCY, true);
    if (!Registration.IsValid()) {
        fprintf(stderr, "RegistrationOpen failed: 0x%x\n", Registration.GetInitStatus());
        return 1;
    }

    MsQuicSettings Settings;
    Settings.SetIdleTimeoutMs(IdleTimeoutMs);
    // QUIC_CONGESTION_CONTROL_ALGORITHM_BBR exists in msquic's source
    // (src/core/bbr.c) but its enum value is compiled in only under
    // QUIC_API_ENABLE_PREVIEW_FEATURES (src/inc/msquic.h), which this
    // harness's library build deliberately does not enable (see common.h's
    // note on ABI consistency). Cubic is msquic's default and the only
    // algorithm this build's enum exposes; --cc is kept for interface
    // parity with the picoquic/quiche harnesses but only "cubic" is valid.
    if (strcmp(CcAlgo, "cubic") != 0) {
        fprintf(stderr, "WARNING: --cc %s requested but this build only supports cubic "
                         "(BBR is preview-gated in msquic; see common.h); using cubic\n", CcAlgo);
    }
    Settings.SetCongestionControlAlgorithm(QUIC_CONGESTION_CONTROL_ALGORITHM_CUBIC);

    // Private isolated netns testbed, single expected server -- skip cert
    // validation rather than pin a CA (matches src/tools/sample/sample.c's
    // own -unsecure convention for a test client).
    MsQuicCredentialConfig CredConfig(
        (QUIC_CREDENTIAL_FLAGS)(QUIC_CREDENTIAL_FLAG_CLIENT | QUIC_CREDENTIAL_FLAG_NO_CERTIFICATE_VALIDATION));

    MsQuicAlpn AlpnCfg(Alpn);
    MsQuicConfiguration Configuration(Registration, AlpnCfg, Settings, CredConfig);
    if (!Configuration.IsValid()) {
        fprintf(stderr, "ConfigurationOpen/LoadCredential failed: 0x%x\n", Configuration.GetInitStatus());
        return 1;
    }

    MsQuicConnection Connection(Registration, CleanUpManual, ClientConnectionCallback, nullptr);
    if (!Connection.IsValid()) {
        fprintf(stderr, "ConnectionOpen failed: 0x%x\n", Connection.GetInitStatus());
        return 1;
    }

    // --- bind path A explicitly BEFORE Start(), matching this survey's
    // source-based-routing testbed requirement (a socket must bind an
    // explicit source address to pick its path) ---
    {
        std::string s(LocalAArg);
        size_t colon = s.rfind(':');
        std::string ip = colon == std::string::npos ? s : s.substr(0, colon);
        uint16_t port = colon == std::string::npos ? 0 : (uint16_t)atoi(s.substr(colon + 1).c_str());
        QUIC_ADDR Raw;
        memset(&Raw, 0, sizeof(Raw));
        if (!ConvertArgToAddress(ip.c_str(), port, &Raw)) {
            fprintf(stderr, "bad --local-a address %s\n", LocalAArg);
            return 2;
        }
        QuicAddr LocalA;
        LocalA.SockAddr = Raw;
        QUIC_STATUS St = Connection.SetLocalAddr(LocalA);
        if (QUIC_FAILED(St)) {
            fprintf(stderr, "SetLocalAddr(--local-a %s) failed: 0x%x\n", LocalAArg, St);
            return 1;
        }
    }

    // --- pre-set the remote address so ConnectionStart skips DNS
    // resolution of --sni (src/core/connection.c QuicConnStart only
    // resolves ServerName when RemoteAddressSet is still false) ---
    uint16_t ServerPort = 4433;
    {
        std::string s(ServerAddrArg);
        size_t colon = s.rfind(':');
        std::string ip = colon == std::string::npos ? s : s.substr(0, colon);
        ServerPort = colon == std::string::npos ? 4433 : (uint16_t)atoi(s.substr(colon + 1).c_str());
        QUIC_ADDR Raw;
        memset(&Raw, 0, sizeof(Raw));
        if (!ConvertArgToAddress(ip.c_str(), ServerPort, &Raw)) {
            fprintf(stderr, "bad --server-addr address %s\n", ServerAddrArg);
            return 2;
        }
        QuicAddr RemoteAddr;
        RemoteAddr.SockAddr = Raw;
        QUIC_STATUS St = Connection.SetRemoteAddr(RemoteAddr);
        if (QUIC_FAILED(St)) {
            fprintf(stderr, "SetRemoteAddr(--server-addr %s) failed: 0x%x\n", ServerAddrArg, St);
            return 1;
        }
    }

    Logf("mq_client", "DIALING server=%s from local-a=%s sni=%s cc=%s", ServerAddrArg, LocalAArg, Sni, CcAlgo);
    QUIC_STATUS StartStatus = Connection.Start(Configuration, QUIC_ADDRESS_FAMILY_INET, Sni, ServerPort);
    if (QUIC_FAILED(StartStatus)) {
        fprintf(stderr, "ConnectionStart failed: 0x%x\n", StartStatus);
        return 1;
    }

    std::thread StatsThread(StatsPollLoop, "mq_client", &g_StatsActive, &g_ActiveConn, StatsIntervalMs);

    // --- stream: send the (tiny, FIN'd immediately) request, then just
    // receive -- server starts streaming back as soon as it sees any bytes.
    StreamCtx SCtx;
    MsQuicStream Stream(Connection, QUIC_STREAM_OPEN_FLAG_NONE, CleanUpManual, ClientStreamCallback, &SCtx);
    if (!Stream.IsValid()) {
        fprintf(stderr, "StreamOpen failed: 0x%x\n", Stream.GetInitStatus());
        return 1;
    }
    SCtx.Stream = &Stream;
    QUIC_STATUS St = Stream.Start();
    if (QUIC_FAILED(St)) {
        fprintf(stderr, "StreamStart failed: 0x%x\n", St);
        return 1;
    }
    QUIC_BUFFER ReqBuf;
    ReqBuf.Buffer = (uint8_t*)Request;
    ReqBuf.Length = (uint32_t)strlen(Request);
    Stream.Send(&ReqBuf, 1, QUIC_SEND_FLAG_FIN, nullptr);
    Logf("mq_client", "REQUEST_SENT %s", Request);

    // --- migration thread: fires MigrateAfterMs after process start (== a
    // fixed point in the transfer, since the request is sent immediately
    // above); matches quicgo/quiche harnesses' fixed-delay trigger design.
    std::thread MigThread(MigrationThreadFn, &Connection, std::string(LocalBArg), MigrateAfterMs);

    {
        std::unique_lock<std::mutex> lock(g_DoneMutex);
        g_DoneCv.wait_for(lock, std::chrono::seconds(TimeoutS), [] { return g_Done; });
    }
    if (!g_Done) {
        Logf("mq_client", "FATAL overall --timeout-s %u exceeded", TimeoutS);
    }

    MigThread.join();
    g_StatsActive.store(false);
    StatsThread.join();

    if (g_OutFile) {
        fclose(g_OutFile);
    }

    Logf("mq_client", "%s total_bytes=%llu",
         g_DownloadOk ? "DONE" : "DONE_INCOMPLETE",
         (unsigned long long)g_TotalBytes.load());
    printf("[mq_client] %s\n", g_DownloadOk ? "DONE" : "DONE_INCOMPLETE");
    return g_DownloadOk ? 0 : 1;
}
