// server.cpp -- PV-Seed msquic survey harness, server half.
//
// Serves exactly ONE QUIC connection, one bidirectional stream: accepts
// whatever the client sends as a "request" (content ignored -- there is only
// one file, mirroring harness/quiche/src/bin/qcserver.rs and
// harness/quicgo/server/main.go's own protocol simplification), then streams
// the requested file's bytes back and closes.
//
// Server-side migration acceptance needs NO special handling from this
// program: msquic's own QuicConnGetPathForPacket / QuicPathSetActive
// machinery (src/core/path.c, src/core/connection.c -- see the source audit
// in the task report) detects the client's new (local,peer) 4-tuple and
// promotes it to the active path by itself. This program only *observes*
// that promotion via QUIC_CONNECTION_EVENT_PEER_ADDRESS_CHANGED and via
// msquic's own internal stdout trace lines (this binary is built with
// -DQUIC_LOGGING_TYPE=stdout, so lines like
// "[conn][%p] Path[%hhu] Set active (rebind=%hhu)" and
// "[conn][%p] Congestion event: IsEcn=%hu" appear interleaved on this
// process's stdout -- see common.h).
//
// Usage:
//   mq_server --listen 10.0.9.1:4433 --cert cert.pem --key key.pem
//             --file bigfile.bin [--cc cubic|bbr] [--idle-timeout-ms 30000]
//             [--stats-interval-ms 20] [--timeout-s 100] [--alpn pvseed-msquic-survey]

#include "common.h"

#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <thread>
#include <vector>

using namespace pvseed;

namespace {

std::atomic<bool> g_StatsActive{true};
std::atomic<MsQuicConnection*> g_ActiveConn{nullptr};

std::mutex g_DoneMutex;
std::condition_variable g_DoneCv;
bool g_Done = false;

// Whole-file buffer, loaded once at startup and never mutated. QUIC_BUFFERs
// handed to StreamSend point directly into this (no per-chunk copy) --
// see SendNextChunk. Lifetime = whole process, so this is safe.
std::vector<uint8_t> g_FileData;
uint32_t g_ChunkSize = 65536;

struct SendChunkCtx {
    QUIC_BUFFER Buf;
};

struct StreamCtx {
    MsQuicStream* Stream = nullptr;
    uint64_t Offset = 0;
    bool RequestSeen = false;
};

void SendNextChunk(StreamCtx* Ctx) {
    if (Ctx->Offset >= g_FileData.size()) {
        return;
    }
    uint64_t Remaining = g_FileData.size() - Ctx->Offset;
    uint32_t ThisLen = (uint32_t)(Remaining < g_ChunkSize ? Remaining : g_ChunkSize);

    auto* SendCtx = new SendChunkCtx();
    SendCtx->Buf.Buffer = (uint8_t*)g_FileData.data() + Ctx->Offset;
    SendCtx->Buf.Length = ThisLen;
    Ctx->Offset += ThisLen;

    QUIC_SEND_FLAGS Flags = (Ctx->Offset >= g_FileData.size()) ? QUIC_SEND_FLAG_FIN : QUIC_SEND_FLAG_NONE;

    QUIC_STATUS Status = Ctx->Stream->Send(&SendCtx->Buf, 1, Flags, SendCtx);
    if (QUIC_FAILED(Status)) {
        Logf("mq_server", "ERROR StreamSend failed 0x%x", Status);
        delete SendCtx;
    }
}

QUIC_STATUS QUIC_API ServerStreamCallback(MsQuicStream* Stream, void* Context, QUIC_STREAM_EVENT* Event) {
    auto* Ctx = (StreamCtx*)Context;
    switch (Event->Type) {
    case QUIC_STREAM_EVENT_START_COMPLETE:
        break;
    case QUIC_STREAM_EVENT_RECEIVE:
        if (!Ctx->RequestSeen) {
            Ctx->RequestSeen = true;
            Logf("mq_server", "REQUEST_SEEN stream_bytes_queued=%zu", g_FileData.size());
            SendNextChunk(Ctx);
        }
        break;
    case QUIC_STREAM_EVENT_SEND_COMPLETE: {
        auto* SendCtx = (SendChunkCtx*)Event->SEND_COMPLETE.ClientContext;
        delete SendCtx;
        if (!Event->SEND_COMPLETE.Canceled) {
            SendNextChunk(Ctx);
        }
        break;
    }
    case QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN:
        break;
    case QUIC_STREAM_EVENT_PEER_SEND_ABORTED:
        Logf("mq_server", "STREAM_PEER_SEND_ABORTED");
        break;
    case QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE:
        Logf("mq_server", "STREAM_SHUTDOWN_COMPLETE bytes_sent=%llu", (unsigned long long)Ctx->Offset);
        delete Ctx->Stream;
        delete Ctx;
        break;
    default:
        break;
    }
    return QUIC_STATUS_SUCCESS;
}

QUIC_STATUS QUIC_API ServerConnectionCallback(MsQuicConnection* Connection, void* /*Context*/, QUIC_CONNECTION_EVENT* Event) {
    switch (Event->Type) {
    case QUIC_CONNECTION_EVENT_CONNECTED: {
        QuicAddr Local, Remote;
        Connection->GetLocalAddr(Local);
        Connection->GetRemoteAddr(Remote);
        Logf("mq_server", "CONNECTED local=%s remote=%s",
             AddrToString(Local).c_str(), AddrToString(Remote).c_str());
        g_ActiveConn.store(Connection, std::memory_order_release);
        break;
    }
    case QUIC_CONNECTION_EVENT_PEER_STREAM_STARTED: {
        auto* Ctx = new StreamCtx();
        Ctx->Stream = new MsQuicStream(
            Event->PEER_STREAM_STARTED.Stream, CleanUpManual, ServerStreamCallback, Ctx);
        Logf("mq_server", "PEER_STREAM_STARTED");
        break;
    }
    case QUIC_CONNECTION_EVENT_LOCAL_ADDRESS_CHANGED:
        Logf("mq_server", "SERVER_LOCAL_ADDR_CHANGED new_local=%s",
             AddrToString(Event->LOCAL_ADDRESS_CHANGED.Address).c_str());
        break;
    case QUIC_CONNECTION_EVENT_PEER_ADDRESS_CHANGED:
        // The reactive-promotion marker: fires when msquic (server side)
        // observes the peer sending from a new 4-tuple and promotes it to
        // the active path (src/core/connection.c QuicConnRecvDecryptAndAuthenticate
        // -> QuicPathSetActive, see the task report's Q1 source audit).
        Logf("mq_server", "SERVER_PEER_ADDR_CHANGED new_remote=%s",
             AddrToString(Event->PEER_ADDRESS_CHANGED.Address).c_str());
        break;
    case QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_TRANSPORT:
        Logf("mq_server", "SHUTDOWN_INITIATED_BY_TRANSPORT status=0x%x", Event->SHUTDOWN_INITIATED_BY_TRANSPORT.Status);
        break;
    case QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_PEER:
        Logf("mq_server", "SHUTDOWN_INITIATED_BY_PEER errorcode=%llu",
             (unsigned long long)Event->SHUTDOWN_INITIATED_BY_PEER.ErrorCode);
        break;
    case QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE:
        Logf("mq_server", "SHUTDOWN_COMPLETE");
        g_ActiveConn.store(nullptr, std::memory_order_release);
        {
            std::lock_guard<std::mutex> lock(g_DoneMutex);
            g_Done = true;
        }
        g_DoneCv.notify_all();
        break;
    default:
        break;
    }
    return QUIC_STATUS_SUCCESS;
}

// NOT a public msquic type -- src/tools/sample/sample.c defines this same
// helper locally (it is not declared in any installed header), so this
// harness must define it too.
typedef struct QUIC_CREDENTIAL_CONFIG_HELPER {
    QUIC_CREDENTIAL_CONFIG CredConfig;
    QUIC_CERTIFICATE_FILE CertFile;
} QUIC_CREDENTIAL_CONFIG_HELPER;

bool LoadFile(const char* Path) {
    FILE* f = fopen(Path, "rb");
    if (!f) {
        fprintf(stderr, "cannot open --file %s\n", Path);
        return false;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) { fclose(f); return false; }
    g_FileData.resize((size_t)sz);
    size_t got = fread(g_FileData.data(), 1, (size_t)sz, f);
    fclose(f);
    return got == (size_t)sz;
}

} // namespace

int main(int argc, char** argv) {
    MarkProcessStart();

    const char* ListenArg = GetArg(argc, argv, "--listen", "10.0.9.1:4433");
    const char* CertFile = GetArg(argc, argv, "--cert", nullptr);
    const char* KeyFile = GetArg(argc, argv, "--key", nullptr);
    const char* FilePath = GetArg(argc, argv, "--file", nullptr);
    const char* CcAlgo = GetArg(argc, argv, "--cc", "cubic");
    const char* Alpn = GetArg(argc, argv, "--alpn", "pvseed-msquic-survey");
    uint32_t IdleTimeoutMs = GetArgU32(argc, argv, "--idle-timeout-ms", 30000);
    uint32_t StatsIntervalMs = GetArgU32(argc, argv, "--stats-interval-ms", 20);
    uint32_t TimeoutS = GetArgU32(argc, argv, "--timeout-s", 100);
    g_ChunkSize = GetArgU32(argc, argv, "--chunk-bytes", 65536);

    if (!CertFile || !KeyFile || !FilePath) {
        fprintf(stderr, "usage: mq_server --listen IP:PORT --cert FILE --key FILE --file FILE "
                         "[--cc cubic|bbr] [--idle-timeout-ms N] [--stats-interval-ms N] [--timeout-s N]\n");
        return 2;
    }
    if (!LoadFile(FilePath)) {
        fprintf(stderr, "failed to load --file %s\n", FilePath);
        return 2;
    }
    Logf("mq_server", "loaded file %s (%zu bytes)", FilePath, g_FileData.size());

    MsQuicApi Api;
    if (!Api.IsValid()) {
        fprintf(stderr, "MsQuicOpen2 failed: 0x%x\n", Api.GetInitStatus());
        return 1;
    }
    MsQuic = &Api;

    MsQuicRegistration Registration("pvseed-msquic-survey-server", QUIC_EXECUTION_PROFILE_LOW_LATENCY, true);
    if (!Registration.IsValid()) {
        fprintf(stderr, "RegistrationOpen failed: 0x%x\n", Registration.GetInitStatus());
        return 1;
    }

    MsQuicSettings Settings;
    Settings.SetIdleTimeoutMs(IdleTimeoutMs);
    Settings.SetPeerBidiStreamCount(1);
    Settings.SetServerResumptionLevel(QUIC_SERVER_NO_RESUME);
    // See the matching comment in client.cpp: BBR's enum value is
    // preview-gated and this build does not enable preview features.
    if (strcmp(CcAlgo, "cubic") != 0) {
        fprintf(stderr, "WARNING: --cc %s requested but this build only supports cubic; using cubic\n", CcAlgo);
    }
    Settings.SetCongestionControlAlgorithm(QUIC_CONGESTION_CONTROL_ALGORITHM_CUBIC);

    QUIC_CREDENTIAL_CONFIG_HELPER CredHelper;
    memset(&CredHelper, 0, sizeof(CredHelper));
    CredHelper.CredConfig.Flags = QUIC_CREDENTIAL_FLAG_NONE;
    CredHelper.CredConfig.Type = QUIC_CREDENTIAL_TYPE_CERTIFICATE_FILE;
    CredHelper.CertFile.CertificateFile = (char*)CertFile;
    CredHelper.CertFile.PrivateKeyFile = (char*)KeyFile;
    CredHelper.CredConfig.CertificateFile = &CredHelper.CertFile;

    MsQuicAlpn AlpnCfg(Alpn);
    MsQuicConfiguration Configuration(Registration, AlpnCfg, Settings, MsQuicCredentialConfig(CredHelper.CredConfig));
    if (!Configuration.IsValid()) {
        fprintf(stderr, "ConfigurationOpen/LoadCredential failed: 0x%x\n", Configuration.GetInitStatus());
        return 1;
    }

    QUIC_ADDR ListenAddr;
    memset(&ListenAddr, 0, sizeof(ListenAddr));
    {
        // Split "IP:PORT".
        std::string s(ListenArg);
        size_t colon = s.rfind(':');
        std::string ip = colon == std::string::npos ? s : s.substr(0, colon);
        uint16_t port = colon == std::string::npos ? 4433 : (uint16_t)atoi(s.substr(colon + 1).c_str());
        if (!ConvertArgToAddress(ip.c_str(), port, &ListenAddr)) {
            fprintf(stderr, "bad --listen address %s\n", ListenArg);
            return 2;
        }
    }

    MsQuicAutoAcceptListener Listener(Registration, Configuration, ServerConnectionCallback, nullptr);
    if (!Listener.IsValid()) {
        fprintf(stderr, "ListenerOpen failed: 0x%x\n", Listener.GetInitStatus());
        return 1;
    }
    QUIC_STATUS Status = Listener.Start(AlpnCfg, &ListenAddr);
    if (QUIC_FAILED(Status)) {
        fprintf(stderr, "ListenerStart failed: 0x%x\n", Status);
        return 1;
    }
    Logf("mq_server", "LISTENING on %s cc=%s", ListenArg, CcAlgo);

    std::thread StatsThread(StatsPollLoop, "mq_server", &g_StatsActive, &g_ActiveConn, StatsIntervalMs);

    {
        std::unique_lock<std::mutex> lock(g_DoneMutex);
        g_DoneCv.wait_for(lock, std::chrono::seconds(TimeoutS), [] { return g_Done; });
    }
    if (!g_Done) {
        Logf("mq_server", "TIMEOUT waiting for connection to complete (--timeout-s %u)", TimeoutS);
    }

    g_StatsActive.store(false);
    StatsThread.join();

    Logf("mq_server", "EXITING");
    return g_Done ? 0 : 1;
}
