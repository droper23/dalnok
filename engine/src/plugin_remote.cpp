// Out-of-process plug-in hosting (ADR-0014).
//
// Engine side: RemotePluginProcessor starts dalnok-plughost, shares one block of memory with it for audio and talks
// to it over a socket pair for everything else. Host side: plughostMain loads the plug-in with the ordinary in-process
// loaders, runs process() on a time-constrained thread woken through the shared block, and serves control requests
// on its main thread inside a run loop (VST3 and CLAP require the main thread for those calls).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "plugin_remote.hpp"
#include "platform/macos/plughost_editor.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <os/os_sync_wait_on_address.h>
#include <os/workgroup.h>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <dlfcn.h>
#include <cstring>
#include <fcntl.h>
#include <mutex>
#include <poll.h>
#include <pthread.h>
#include <spawn.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

extern char **environ;
// posix_spawnattr_set_registered_ports_np sets the child task's registered ports (mach_ports_lookup). libSystem exports
// it but the public SDK does not declare it, so it is looked up at run time; without it only workgroup membership is lost.
using SetRegisteredPorts = int (*)(posix_spawnattr_t *, mach_port_t[], uint32_t);
static SetRegisteredPorts setRegisteredPorts() {
    static const auto fn = reinterpret_cast<SetRegisteredPorts>(dlsym(RTLD_DEFAULT, "posix_spawnattr_set_registered_ports_np"));
    return fn;
}

namespace dalnok {
namespace {

constexpr int kMaxFrames = 8192;
constexpr int kMaxNotes = 1024;
constexpr int kMaxAutomation = 64;
constexpr uint32_t kMagic = 0x444C4E48; // "DLNH"

// The shared block. Both processes are the same build, so the layout matches by construction; `magic` and `size`
// still guard against a stale host binary.
struct Shared {
    uint32_t magic, size;
    alignas(64) std::atomic<uint32_t> request; // engine: bumped after writing a block's inputs
    alignas(64) std::atomic<uint32_t> done;    // host: set to `request` after writing the outputs
    alignas(64) std::atomic<uint32_t> quit;
    int32_t frames, noteCount, automationCount, sidechain;
    PluginNote notes[kMaxNotes];
    struct { uint32_t id; double value; } automation[kMaxAutomation];
    float inL[kMaxFrames], inR[kMaxFrames], outL[kMaxFrames], outR[kMaxFrames], scL[kMaxFrames], scR[kMaxFrames];
    // Keys the editor's window did not use (host main thread writes, engine main thread reads; ADR-0015).
    struct Key { uint16_t keyCode; uint64_t modifiers; char characters[16], charactersIgnoringModifiers[16]; };
    static constexpr uint32_t kKeys = 16;
    Key keys[kKeys];
    alignas(64) std::atomic<uint32_t> keyWrite; // host
    alignas(64) std::atomic<uint32_t> keyRead;  // engine
};
static_assert(std::atomic<uint32_t>::is_always_lock_free);

// ---- Wake/wait on a shared 32-bit counter -------------------------------------------------------------------

void wake(std::atomic<uint32_t> &a) noexcept {
    if (__builtin_available(macOS 14.4, *))
        os_sync_wake_by_address_any(&a, sizeof(uint32_t), OS_SYNC_WAKE_BY_ADDRESS_SHARED);
}

// Reads the commpage (no syscall or lock); the SDK does not annotate it, so the effect check is suppressed here only.
uint64_t nowNs() DALNOK_NONBLOCKING {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#pragma clang diagnostic pop
}

// Waits until `a` differs from `old`, at most `timeoutNs` (0 = forever). True if it changed.
bool waitChange(std::atomic<uint32_t> &a, uint32_t old, uint64_t timeoutNs) noexcept {
    const uint64_t deadline = timeoutNs ? nowNs() + timeoutNs : 0;
    while (a.load(std::memory_order_acquire) == old) {
        const uint64_t now = nowNs();
        if (deadline && now >= deadline) return false;
        if (__builtin_available(macOS 14.4, *)) {
            if (deadline) {
                mach_timebase_info_data_t tb;
                mach_timebase_info(&tb);
                const uint64_t ticks = (deadline - now) * tb.denom / tb.numer;
                os_sync_wait_on_address_with_timeout(&a, old, sizeof(uint32_t), OS_SYNC_WAIT_ON_ADDRESS_SHARED,
                                                     OS_CLOCK_MACH_ABSOLUTE_TIME, ticks ? ticks : 1);
            } else {
                os_sync_wait_on_address(&a, old, sizeof(uint32_t), OS_SYNC_WAIT_ON_ADDRESS_SHARED);
            }
        } else {
            std::this_thread::yield(); // macOS 14.0–14.3: no shared address wait; spin politely
        }
    }
    return true;
}

// ---- Control messages: [u32 length][u8 op or status][payload] -----------------------------------------------

enum Op : uint8_t {
    opHello = 1, opGetState, opSetState, opSetStateDocument, opStateError, opParameterCount, opParameter,
    opParameterText, opSetParameter, opTouched, opEditCount, opAutomationRange, opResponse, opLatency, opQuit,
    opInit, // engine → host once after starting: [u8 has state][u8 from document][str state]
    opHasEditor, opShowEditor, opCloseEditor, opEditorWindow, opEditorSnapshot, // ADR-0015
    opIsolationStats
};
// Reply heads: 0 = refused (payload: reason), 1 = done, 2 = the host is crashing (payload: str reason; see onCrash).
constexpr uint8_t kCrashed = 2;

struct Writer {
    std::string b;
    void u8(uint8_t v) { b.push_back(static_cast<char>(v)); }
    void u32(uint32_t v) { b.append(reinterpret_cast<const char *>(&v), 4); }
    void i32(int32_t v) { u32(static_cast<uint32_t>(v)); }
    void f64(double v) { b.append(reinterpret_cast<const char *>(&v), 8); }
    void str(const std::string &s) { u32(static_cast<uint32_t>(s.size())); b += s; }
};

struct Reader {
    const std::string &b;
    size_t p = 0;
    bool ok = true;
    template <typename T> T raw() {
        T v{};
        if (p + sizeof(T) > b.size()) { ok = false; return v; }
        std::memcpy(&v, b.data() + p, sizeof(T));
        p += sizeof(T);
        return v;
    }
    uint8_t u8() { return raw<uint8_t>(); }
    uint32_t u32() { return raw<uint32_t>(); }
    int32_t i32() { return raw<int32_t>(); }
    double f64() { return raw<double>(); }
    std::string str() {
        const uint32_t n = u32();
        if (!ok || p + n > b.size()) { ok = false; return {}; }
        std::string s = b.substr(p, n);
        p += n;
        return s;
    }
};

bool writeAll(int fd, const std::string &bytes) {
    size_t off = 0;
    while (off < bytes.size()) {
        const ssize_t n = ::write(fd, bytes.data() + off, bytes.size() - off);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        off += static_cast<size_t>(n);
    }
    return true;
}

// Reads exactly `n` bytes before `deadlineNs` (0 = no deadline).
bool readAll(int fd, char *out, size_t n, uint64_t deadlineNs) {
    size_t off = 0;
    while (off < n) {
        if (deadlineNs) {
            const uint64_t now = nowNs();
            if (now >= deadlineNs) return false;
            pollfd p{fd, POLLIN, 0};
            const int r = ::poll(&p, 1, static_cast<int>(std::max<uint64_t>(1, (deadlineNs - now) / 1'000'000)));
            if (r < 0 && errno == EINTR) continue;
            if (r <= 0) continue; // loop re-checks the deadline
        }
        const ssize_t got = ::read(fd, out + off, n - off);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return false;
        off += static_cast<size_t>(got);
    }
    return true;
}

bool sendMessage(int fd, uint8_t head, const std::string &payload) {
    Writer w;
    w.u32(static_cast<uint32_t>(payload.size() + 1));
    w.u8(head);
    w.b += payload;
    return writeAll(fd, w.b);
}

bool receiveMessage(int fd, uint8_t &head, std::string &payload, uint64_t deadlineNs) {
    uint32_t len = 0;
    if (!readAll(fd, reinterpret_cast<char *>(&len), 4, deadlineNs) || len == 0 || len > (1u << 30)) return false;
    std::string body(len, '\0');
    if (!readAll(fd, body.data(), len, deadlineNs)) return false;
    head = static_cast<uint8_t>(body[0]);
    payload = body.substr(1);
    return true;
}

// ---- Audio workgroup hand-off (Mach ports) ------------------------------------------------------------------
// At spawn the engine registers a send right to a rendezvous port in the host (posix_spawnattr_set_registered_ports_np).
// The host answers on it with a send right to its own port, over which the engine later sends the device's workgroup
// port (os_workgroup_copy_port) whenever the device starts, changes or stops. Workgroups are made to be shared this way.

struct PortMessage {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port;
};
struct PortMessageReceived {
    PortMessage m;
    mach_msg_trailer_t trailer;
};

// Sends `port` (as `disposition`; MACH_PORT_NULL is allowed) to `to`. Never blocks.
bool sendPort(mach_port_t to, mach_port_t port, mach_msg_type_name_t disposition) {
    PortMessage m{};
    m.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    m.header.msgh_size = sizeof m;
    m.header.msgh_remote_port = to;
    m.body.msgh_descriptor_count = 1;
    m.port.name = port;
    m.port.disposition = port ? disposition : MACH_MSG_TYPE_COPY_SEND;
    m.port.type = MACH_MSG_PORT_DESCRIPTOR;
    return mach_msg(&m.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL) ==
           MACH_MSG_SUCCESS;
}

// Receives one port from `on`: waits for it if `wait`, else only takes one already queued (within `timeoutMs`).
bool receivePort(mach_port_t on, mach_port_t &port, bool wait, mach_msg_timeout_t timeoutMs = 0) {
    PortMessageReceived r{};
    const mach_msg_option_t options = MACH_RCV_MSG | (wait ? 0 : MACH_RCV_TIMEOUT);
    if (mach_msg(&r.m.header, options, 0, sizeof r, on, timeoutMs, MACH_PORT_NULL) != MACH_MSG_SUCCESS) return false;
    port = r.m.body.msgh_descriptor_count == 1 ? r.m.port.name : MACH_PORT_NULL;
    return true;
}

std::string shmName() {
    static std::atomic<uint32_t> counter{0};
    return "/dalnok." + std::to_string(::getpid()) + "." + std::to_string(counter.fetch_add(1));
}

// ---- Engine side -----------------------------------------------------------------------------------------

class RemotePluginProcessor final : public PluginProcessor {
public:
    ~RemotePluginProcessor() override {
        if (shared_) {
            shared_->quit.store(1, std::memory_order_release);
            shared_->request.fetch_add(1, std::memory_order_release);
            wake(shared_->request);
        }
        if (fd_ >= 0) {
            (void)sendMessage(fd_, opQuit, {});
            ::close(fd_);
        }
        if (pid_ > 0 && !launched_) killAndReap(); // still loading (cancelled or failed): nothing to shut down cleanly
        if (pid_ > 0) {
            int status = 0;
            const uint64_t deadline = nowNs() + 500'000'000;
            while (::waitpid(pid_, &status, WNOHANG) == 0) {
                if (nowNs() > deadline) { ::kill(pid_, SIGKILL); ::waitpid(pid_, &status, 0); break; }
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
        }
        if (shared_) ::munmap(shared_, sizeof(Shared));
        unlinkName();
        closeRendezvous();
        if (hostPort_) mach_port_deallocate(mach_task_self(), hostPort_);
    }

    // Starts the host without waiting for it (ADR-0014 stage 2). `state` (may be null) is sent with the start request and
    // applied by the host before it answers, so neither loading nor restoring ever blocks the caller; pollLaunch
    // reports the outcome.
    bool launch(const std::string &host, const std::string &format, const std::string &path, const std::string &classId,
                double sampleRate, int maxBlock, bool offline, int loadTimeoutMs, const std::string *state, bool document,
                std::string &err) {
        loadTimeoutMs_ = loadTimeoutMs;
        offline_ = offline;
        sampleRate_ = sampleRate;
        if (maxBlock > kMaxFrames) { err = "block too large for an isolated plug-in"; return false; }
        const std::string name = shmName();
        const int shm = ::shm_open(name.c_str(), O_RDWR | O_CREAT | O_EXCL, 0600);
        if (shm < 0) { err = std::string("cannot create shared memory: ") + std::strerror(errno); return false; }
        const bool sized = ::ftruncate(shm, sizeof(Shared)) == 0;
        void *mem = sized ? ::mmap(nullptr, sizeof(Shared), PROT_READ | PROT_WRITE, MAP_SHARED, shm, 0) : MAP_FAILED;
        ::close(shm);
        if (mem == MAP_FAILED) { ::shm_unlink(name.c_str()); err = "cannot map shared memory"; return false; }
        shared_ = static_cast<Shared *>(mem);
        shared_->magic = kMagic;
        shared_->size = sizeof(Shared);

        int sv[2];
        if (::socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { ::shm_unlink(name.c_str()); err = "cannot create socket"; return false; }
        ::fcntl(sv[0], F_SETFD, FD_CLOEXEC);
        // A crashed host closes its end; writing to it must fail with EPIPE, never raise SIGPIPE in the app.
        const int on = 1;
        ::setsockopt(sv[0], SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_adddup2(&actions, sv[1], 3);
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0); // plug-ins print; keep it out of ours
        posix_spawnattr_t attr;
        posix_spawnattr_init(&attr);
        // Live hosts get a rendezvous port for the audio workgroup hand-off (offline renders need no workgroup).
        bool registered = false;
        if (!offline && setRegisteredPorts() &&
            mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &rendezvous_) == KERN_SUCCESS) {
            if (mach_port_insert_right(mach_task_self(), rendezvous_, rendezvous_, MACH_MSG_TYPE_MAKE_SEND) == KERN_SUCCESS) {
                mach_port_t ports[1] = {rendezvous_};
                registered = setRegisteredPorts()(&attr, ports, 1) == 0;
                if (!registered) mach_port_deallocate(mach_task_self(), rendezvous_);
            }
            if (!registered) closeRendezvous();
        }
        const std::string rate = std::to_string(sampleRate), block = std::to_string(maxBlock);
        std::vector<std::string> args = {host, "--shm", name, "--format", format, "--path", path, "--class", classId,
                                         "--rate", rate, "--block", block};
        if (offline) args.push_back("--offline");
        // Only when our port really is registered: otherwise the child inherits our own registered ports.
        if (rendezvous_) args.push_back("--rendezvous");
        std::vector<char *> argv;
        for (auto &a : args) argv.push_back(a.data());
        argv.push_back(nullptr);
        const int spawned = ::posix_spawn(&pid_, host.c_str(), &actions, &attr, argv.data(), environ);
        posix_spawn_file_actions_destroy(&actions);
        posix_spawnattr_destroy(&attr);
        if (registered) mach_port_deallocate(mach_task_self(), rendezvous_); // the host holds its own send right now
        ::close(sv[1]);
        fd_ = sv[0];
        if (spawned != 0) {
            ::shm_unlink(name.c_str());
            pid_ = 0;
            err = "cannot start the plug-in host: " + std::string(std::strerror(spawned));
            return false;
        }
        shmName_ = name;
        launchDeadline_ = nowNs() + uint64_t(loadTimeoutMs) * 1'000'000;
        Writer init;
        init.u8(state != nullptr);
        init.u8(document);
        init.str(state ? *state : std::string());
        Writer framed;
        framed.u32(static_cast<uint32_t>(init.b.size() + 1));
        framed.u8(opInit);
        outbox_ = framed.b + init.b;
        return true;
    }

    enum class Launch { loading, ready, failed };
    // Never blocks for long: sends what the socket takes of the start request and reads the host's answer if it is
    // there. A host that crashes, exits or outlives the load timeout fails the launch.
    Launch pollLaunch(std::string &err) {
        if (launched_) return Launch::ready;
        while (outboxSent_ < outbox_.size()) {
            const ssize_t n = ::send(fd_, outbox_.data() + outboxSent_, outbox_.size() - outboxSent_, MSG_DONTWAIT);
            if (n > 0) { outboxSent_ += static_cast<size_t>(n); continue; }
            if (n < 0 && errno == EINTR) continue;
            break; // full (the host is still loading) or closed (reported below)
        }
        pollfd p{fd_, POLLIN, 0};
        const bool readable = ::poll(&p, 1, 0) > 0;
        if (!readable) {
            if (nowNs() < launchDeadline_) return Launch::loading;
            unlinkName();
            reapForError(err, loadTimeoutMs_);
            return Launch::failed;
        }
        unlinkName(); // both processes have it mapped (or the host is gone); the name is no longer needed
        uint8_t status = 0;
        std::string reply;
        if (!receiveMessage(fd_, status, reply, nowNs() + 1'000'000'000ull)) {
            const std::string why = exitReason();
            if (why.empty()) reapForError(err, loadTimeoutMs_);
            else err = "the plug-in host failed while loading: " + why;
            return Launch::failed;
        }
        Reader r{reply};
        if (status == kCrashed) { err = "the plug-in " + r.str() + " while loading"; killAndReap(); return Launch::failed; }
        if (status != 1) { err = r.str(); return Launch::failed; }
        instrument_ = r.u8();
        sidechain_ = r.u8();
        latency_.store(r.u32());
        name_ = r.str();
        vendor_ = r.str();
        classId_ = r.str();
        categories_ = r.str();
        stateAccepted_ = r.u8();
        launchStateError_ = r.str();
        if (!r.ok) { err = "the plug-in host sent a damaged reply"; return Launch::failed; }
        launched_ = true;
        outbox_.clear();
        // The host answered the rendezvous before loading the plug-in, so its port is already queued.
        if (rendezvous_) {
            mach_port_t hostPort = MACH_PORT_NULL;
            if (receivePort(rendezvous_, hostPort, false, 100)) hostPort_ = hostPort;
            closeRendezvous();
        }
        return Launch::ready;
    }
    bool stateAccepted() const { return stateAccepted_; }
    const std::string &launchStateError() const { return launchStateError_; }
    pid_t pid() const { return pid_; }

    bool start(const std::string &host, const std::string &format, const std::string &path, const std::string &classId,
               double sampleRate, int maxBlock, bool offline, int loadTimeoutMs, std::string &err) {
        if (!launch(host, format, path, classId, sampleRate, maxBlock, offline, loadTimeoutMs, nullptr, false, err)) return false;
        while (true) {
            switch (pollLaunch(err)) {
                case Launch::ready: return true;
                case Launch::failed: return false;
                case Launch::loading: break;
            }
            pollfd p{fd_, POLLIN, 0};
            (void)::poll(&p, 1, 20);
        }
    }

    bool instrument() const override { return instrument_; }
    uint32_t latency() const override {
        Writer w;
        std::string reply;
        if (call(opLatency, w.b, reply)) {
            Reader r{reply};
            const uint32_t v = r.u32();
            if (r.ok) latency_.store(v, std::memory_order_relaxed);
        }
        return latency_.load(std::memory_order_relaxed);
    }
    const std::string &name() const override { return name_; }
    const std::string &vendor() const override { return vendor_; }
    std::string categories() const override { return categories_; }
    const std::string &classId() const override { return classId_; }
    bool hasSidechain() const override { return sidechain_; }
    bool isolated() const override { return true; }

    void process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING override {
        Shared *s = shared_;
        const int automation = autoCount_;
        autoCount_ = 0;
        if (failed_.load(std::memory_order_acquire) || frames <= 0 || frames > kMaxFrames) { silenceIfInstrument(left, right, frames); return; }
        const uint32_t request = s->request.load(std::memory_order_relaxed);
        if (s->done.load(std::memory_order_acquire) != request) { // the previous block is still in the host
            missed(); silenceIfInstrument(left, right, frames); return;
        }
        // Live: the callback's shared budget. Once other isolated plug-ins have spent it, this one passes for a block
        // without being blamed (budget skips never count towards "stopped responding").
        uint64_t timeout = offline_ ? 10'000'000'000ull
                                    : static_cast<uint64_t>(0.4e9 * frames / (sampleRate_ > 0 ? sampleRate_ : 48000));
        if (!offline_ && deadlineNs_) {
            const uint64_t now = nowNs();
            if (now >= deadlineNs_) {
                budgetSkips_.fetch_add(1, std::memory_order_relaxed);
                silenceIfInstrument(left, right, frames);
                return;
            }
            timeout = std::min(timeout, deadlineNs_ - now);
        }
        for (int i = 0; i < frames; ++i) { s->inL[i] = left[i]; s->inR[i] = right[i]; }
        s->sidechain = scL_ && scR_ ? 1 : 0;
        if (s->sidechain) for (int i = 0; i < frames; ++i) { s->scL[i] = scL_[i]; s->scR[i] = scR_[i]; }
        const int n = noteCount < kMaxNotes ? noteCount : kMaxNotes;
        for (int i = 0; i < n; ++i) s->notes[i] = notes[i];
        s->noteCount = n;
        for (int i = 0; i < automation; ++i) s->automation[i] = {autoQueue_[i].id, autoQueue_[i].value};
        s->automationCount = automation;
        s->frames = frames;
        s->request.store(request + 1, std::memory_order_release);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
        // The one IPC exception on the audio thread (ADR-0014): a bounded wake and a bounded wait.
        wake(s->request);
        const bool answered = waitChange(s->done, request, timeout);
#pragma clang diagnostic pop
        if (!answered) { missed(); silenceIfInstrument(left, right, frames); return; }
        consecutiveMisses_.store(0, std::memory_order_relaxed);
        for (int i = 0; i < frames; ++i) { left[i] = s->outL[i]; right[i] = s->outR[i]; }
    }

    // Stopped transport: about every 50 ms, a request without audio lets the host give the plug-in its idle call (a
    // CLAP plug-in's parameter flush). Bounded by the callback's budget like a block; an unanswered one is not a miss.
    void idle() DALNOK_NONBLOCKING override {
        Shared *s = shared_;
        if (offline_ || failed_.load(std::memory_order_acquire)) return;
        const uint64_t now = nowNs();
        if (now - lastIdleNs_ < 50'000'000 || (deadlineNs_ && now >= deadlineNs_)) return;
        const uint32_t request = s->request.load(std::memory_order_relaxed);
        if (s->done.load(std::memory_order_acquire) != request) return; // still busy
        lastIdleNs_ = now;
        s->automationCount = 0;
        s->noteCount = 0;
        s->frames = 0;
        s->request.store(request + 1, std::memory_order_release);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
        wake(s->request);
        (void)waitChange(s->done, request, deadlineNs_ > now ? deadlineNs_ - now : 2'000'000);
#pragma clang diagnostic pop
    }

    bool response(const double *hz, int count, double *db) override {
        Writer w;
        w.u32(static_cast<uint32_t>(count));
        for (int i = 0; i < count; ++i) w.f64(hz[i]);
        std::string reply;
        if (!call(opResponse, w.b, reply)) return false;
        Reader r{reply};
        if (!r.u8()) return false;
        for (int i = 0; i < count; ++i) db[i] = r.f64();
        return r.ok;
    }
    bool getState(std::string &bytes) override {
        std::string reply;
        if (!call(opGetState, {}, reply)) return false;
        Reader r{reply};
        const bool ok = r.u8();
        bytes = r.str();
        return ok && r.ok;
    }
    bool setState(const std::string &bytes) override { return setStateVia(opSetState, bytes); }
    bool setStateFromDocument(const std::string &bytes) override { return setStateVia(opSetStateDocument, bytes); }
    std::string stateError() const override {
        std::string reply;
        if (!call(opStateError, {}, reply)) return failure();
        Reader r{reply};
        return r.str();
    }
    int32_t parameterCount() override {
        std::string reply;
        if (!call(opParameterCount, {}, reply)) return 0;
        Reader r{reply};
        const int32_t n = r.i32();
        return r.ok ? n : 0;
    }
    bool parameter(int32_t index, PluginParameter &out) override {
        Writer w;
        w.i32(index);
        std::string reply;
        if (!call(opParameter, w.b, reply)) return false;
        Reader r{reply};
        if (!r.u8()) return false;
        out.id = r.u32();
        out.title = r.str(); out.units = r.str(); out.display = r.str();
        out.value = r.f64(); out.defaultValue = r.f64();
        out.stepCount = r.i32();
        out.automatable = r.u8(); out.readOnly = r.u8(); out.hidden = r.u8();
        return r.ok;
    }
    bool parameterText(uint32_t id, double normalized, std::string &out) override {
        Writer w;
        w.u32(id); w.f64(normalized);
        std::string reply;
        if (!call(opParameterText, w.b, reply)) return false;
        Reader r{reply};
        const bool ok = r.u8();
        out = r.str();
        return ok && r.ok;
    }
    bool setParameter(uint32_t id, double normalized) override {
        Writer w;
        w.u32(id); w.f64(normalized);
        std::string reply;
        if (!call(opSetParameter, w.b, reply)) return false;
        Reader r{reply};
        return r.u8() && r.ok;
    }
    void touchedParameters(std::vector<std::pair<uint32_t, double>> &out) override {
        std::string reply;
        if (!call(opTouched, {}, reply)) return;
        Reader r{reply};
        const uint32_t n = r.u32();
        for (uint32_t i = 0; i < n && r.ok; ++i) {
            const uint32_t id = r.u32();
            const double v = r.f64();
            if (r.ok) out.push_back({id, v});
        }
    }
    uint64_t editCount() const override {
        std::string reply;
        if (call(opEditCount, {}, reply)) {
            Reader r{reply};
            const uint64_t v = r.raw<uint64_t>();
            if (r.ok) edits_ = v;
        }
        return edits_;
    }
    bool automationRange(uint32_t id, double &lo, double &hi) override {
        Writer w;
        w.u32(id);
        std::string reply;
        lo = 0; hi = 1;
        if (!call(opAutomationRange, w.b, reply)) return true;
        Reader r{reply};
        const bool ok = r.u8();
        const double a = r.f64(), b = r.f64();
        if (r.ok) { lo = a; hi = b; }
        return ok;
    }

    // Editors (ADR-0015): the plug-in's process owns the editor's window; it cannot be embedded in one of Dalnok's.
    bool hasEditor() override {
        std::string reply;
        if (!call(opHasEditor, {}, reply)) return false;
        Reader r{reply};
        return r.u8() && r.ok;
    }
    bool openEditor(void *, int32_t &, int32_t &, void (*)(void *, int32_t, int32_t), void *, std::string &err) override {
        err = "this plug-in runs in its own process; its editor opens in its own window (showEditorWindow)";
        return false;
    }
    bool showEditorWindow(const std::string &title, double x, double y, std::string &err) override {
        Writer w;
        w.str(title); w.f64(x); w.f64(y);
        std::string reply;
        if (!call(opShowEditor, w.b, reply)) {
            Reader r{reply};
            err = failure().empty() ? r.str() : failure();
            if (err.empty()) err = "the editor could not be opened";
            return false;
        }
        return true;
    }
    void closeEditor() override { std::string reply; (void)call(opCloseEditor, {}, reply); }
    bool editorWindow(EditorWindowInfo &out) override {
        std::string reply;
        if (!call(opEditorWindow, {}, reply)) return false;
        Reader r{reply};
        out.visible = r.u8(); out.open = r.u8();
        out.x = r.f64(); out.y = r.f64(); out.width = r.f64(); out.height = r.f64();
        out.contentWidth = r.f64(); out.contentHeight = r.f64();
        out.windowNumber = r.raw<int64_t>(); out.level = r.raw<int64_t>();
        out.processId = pid_;
        return r.ok;
    }
    bool editorSnapshot(const std::string &path) override {
        Writer w;
        w.str(path);
        std::string reply;
        return call(opEditorSnapshot, w.b, reply);
    }

    void shareWorkgroup(uint32_t port) override {
        if (hostPort_ && !failed_.load(std::memory_order_acquire)) (void)sendPort(hostPort_, port, MACH_MSG_TYPE_COPY_SEND);
    }
    bool isolationStats(IsolationStats &out) override {
        out.missedBlocks = misses_.load(std::memory_order_relaxed);
        out.budgetSkips = budgetSkips_.load(std::memory_order_relaxed);
        std::string reply;
        if (!call(opIsolationStats, {}, reply)) return true;
        Reader r{reply};
        const uint8_t joined = r.u8();
        const int32_t error = r.i32();
        const uint32_t joins = r.u32();
        if (r.ok) { out.workgroupJoined = joined; out.workgroupError = error; out.workgroupJoins = joins; }
        return true;
    }

    std::string failure() const override {
        std::lock_guard lock(failureMutex_);
        return failure_;
    }
    bool takeEditorKey(EditorKey &out) override {
        if (!shared_) return false;
        const uint32_t r = shared_->keyRead.load(std::memory_order_relaxed);
        if (r == shared_->keyWrite.load(std::memory_order_acquire)) return false;
        const Shared::Key &k = shared_->keys[r % Shared::kKeys];
        out.keyCode = k.keyCode;
        out.modifiers = k.modifiers;
        std::memcpy(out.characters, k.characters, sizeof out.characters);
        std::memcpy(out.charactersIgnoringModifiers, k.charactersIgnoringModifiers, sizeof out.charactersIgnoringModifiers);
        out.characters[sizeof out.characters - 1] = out.charactersIgnoringModifiers[sizeof out.charactersIgnoringModifiers - 1] = 0;
        shared_->keyRead.store(r + 1, std::memory_order_release);
        return true;
    }
    void poll() override {
        if (failed_.load(std::memory_order_acquire)) return;
        int status = 0;
        if (pid_ > 0 && ::waitpid(pid_, &status, WNOHANG) == pid_) {
            pid_ = 0;
            fail(WIFSIGNALED(status) ? std::string("crashed (") + strsignal(WTERMSIG(status)) + ")"
                                     : "its process exited (status " + std::to_string(WEXITSTATUS(status)) + ")");
            return;
        }
        // Live blocks only: about 2 s of consecutive missed deadlines means the plug-in has stopped answering.
        const double perBlock = 512.0 / (sampleRate_ > 0 ? sampleRate_ : 48000);
        if (!offline_ && consecutiveMisses_.load(std::memory_order_relaxed) * perBlock > 2.0) {
            if (pid_ > 0) { ::kill(pid_, SIGKILL); ::waitpid(pid_, &status, 0); pid_ = 0; }
            fail("stopped responding");
        }
    }

private:
    void closeRendezvous() {
        if (rendezvous_) mach_port_mod_refs(mach_task_self(), rendezvous_, MACH_PORT_RIGHT_RECEIVE, -1);
        rendezvous_ = MACH_PORT_NULL;
    }
    // The crash reporter can hold a dying process for seconds; its report comes from a copy, so end it now.
    void killAndReap() const {
        if (pid_ <= 0) return;
        int status = 0;
        ::kill(pid_, SIGKILL);
        ::waitpid(pid_, &status, 0);
        pid_ = 0;
    }
    void unlinkName() {
        if (!shmName_.empty()) { ::shm_unlink(shmName_.c_str()); shmName_.clear(); }
    }
    void silenceIfInstrument(float *left, float *right, int frames) DALNOK_NONBLOCKING {
        if (!instrument_) return; // effects pass the dry signal through
        for (int i = 0; i < frames; ++i) left[i] = right[i] = 0.0f;
    }
    void missed() DALNOK_NONBLOCKING {
        misses_.fetch_add(1, std::memory_order_relaxed);
        consecutiveMisses_.fetch_add(1, std::memory_order_relaxed);
    }
    void fail(std::string why) const {
        if (why.empty()) why = "failed";
        {
            std::lock_guard lock(failureMutex_);
            if (!failure_.empty()) return;
            failure_ = why;
        }
        failed_.store(true, std::memory_order_release);
    }
    bool setStateVia(Op op, const std::string &bytes) {
        Writer w;
        w.str(bytes);
        std::string reply;
        if (!call(op, w.b, reply)) return false;
        Reader r{reply};
        return r.u8() && r.ok;
    }
    // One request and its reply, with a timeout. A host that does not answer is treated as failed.
    bool call(Op op, const std::string &payload, std::string &reply) const {
        if (failed_.load(std::memory_order_acquire) || fd_ < 0) return false;
        std::lock_guard lock(callMutex_);
        uint8_t status = 0;
        if (!sendMessage(fd_, op, payload) || !receiveMessage(fd_, status, reply, nowNs() + 5'000'000'000ull)) {
            const std::string reason = exitReason(); // reaps the child: call once
            fail(reason.empty() ? "stopped responding" : reason);
            return false;
        }
        if (status == kCrashed) { Reader r{reply}; fail(r.str()); killAndReap(); return false; }
        return status == 1;
    }
    // Why the host process ended, if it did within a moment (a closed socket usually means it just died).
    std::string exitReason() const {
        if (pid_ <= 0) return {};
        int status = 0;
        for (int i = 0; i < 50; ++i) {
            if (::waitpid(pid_, &status, WNOHANG) == pid_) {
                pid_ = 0;
                return WIFSIGNALED(status) ? std::string("crashed (") + strsignal(WTERMSIG(status)) + ")"
                                           : "its process exited (status " + std::to_string(WEXITSTATUS(status)) + ")";
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
        return {};
    }
    void reapForError(std::string &err, int timeoutMs) {
        int status = 0;
        if (::waitpid(pid_, &status, WNOHANG) == pid_) {
            err = WIFSIGNALED(status) ? std::string("the plug-in crashed while loading (") + strsignal(WTERMSIG(status)) + ")"
                                      : "the plug-in host exited while loading";
        } else {
            ::kill(pid_, SIGKILL);
            ::waitpid(pid_, &status, 0);
            err = "the plug-in did not finish loading within " + std::to_string(timeoutMs / 1000) + " s";
        }
        pid_ = 0;
    }

    Shared *shared_ = nullptr;
    mach_port_t rendezvous_ = MACH_PORT_NULL, hostPort_ = MACH_PORT_NULL;
    std::string shmName_, outbox_, launchStateError_;
    size_t outboxSent_ = 0;
    uint64_t launchDeadline_ = 0;
    int loadTimeoutMs_ = 60'000;
    bool launched_ = false, stateAccepted_ = true;
    mutable pid_t pid_ = 0;
    int fd_ = -1;
    bool offline_ = false, instrument_ = false, sidechain_ = false;
    double sampleRate_ = 48000;
    std::string name_, vendor_, classId_, categories_;
    mutable std::atomic<uint32_t> latency_{0};
    mutable uint64_t edits_ = 0;
    uint64_t lastIdleNs_ = 0; // audio thread
    mutable std::mutex callMutex_, failureMutex_;
    mutable std::string failure_;
    mutable std::atomic<bool> failed_{false};
    std::atomic<uint64_t> misses_{0}, consecutiveMisses_{0}, budgetSkips_{0};
};

// ---- Host side --------------------------------------------------------------------------------------------

struct Host {
    std::unique_ptr<PluginProcessor> plugin;
    Shared *shared = nullptr;
    int fd = 3;
    // The audio device's workgroup, offered by the engine (listener thread) and joined by the processing thread.
    std::atomic<os_workgroup_t> offered{nullptr};
    std::atomic<uint32_t> offers{0};
    std::atomic<bool> joined{false};
    std::atomic<int32_t> joinError{0};
    std::atomic<uint32_t> joins{0};
};

// Answers the engine's rendezvous with a port of our own, then receives workgroup ports for as long as we live.
void startWorkgroupListener(Host *h, bool rendezvousGiven) {
    if (!rendezvousGiven) return; // registered ports would be ones inherited from the engine's process, not ours
    mach_port_array_t ports = nullptr;
    mach_msg_type_number_t count = 0;
    if (mach_ports_lookup(mach_task_self(), &ports, &count) != KERN_SUCCESS) return;
    const mach_port_t rendezvous = count > 0 ? ports[0] : MACH_PORT_NULL;
    vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(ports), count * sizeof(mach_port_t));
    mach_port_t mine = MACH_PORT_NULL;
    if (!rendezvous || mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &mine) != KERN_SUCCESS) return;
    const bool sent = sendPort(rendezvous, mine, MACH_MSG_TYPE_MAKE_SEND);
    mach_port_deallocate(mach_task_self(), rendezvous);
    if (!sent) return;
    std::thread([h, mine] {
        while (true) {
            mach_port_t port = MACH_PORT_NULL;
            if (!receivePort(mine, port, true)) return;
            os_workgroup_t wg = port ? os_workgroup_create_with_port("dalnok-plughost", port) : nullptr;
            if (port) mach_port_deallocate(mach_task_self(), port);
            if (os_workgroup_t old = h->offered.exchange(wg, std::memory_order_acq_rel)) os_release(old); // never joined
            h->offers.fetch_add(1, std::memory_order_release);
        }
    }).detach();
}

// On the processing thread: leave the current workgroup and join the newest one offered.
void adoptWorkgroup(Host *h, os_workgroup_t &current, os_workgroup_join_token_s &token) {
    if (current) {
        os_workgroup_leave(current, &token);
        os_release(current);
        current = nullptr;
        h->joined.store(false, std::memory_order_relaxed);
    }
    os_workgroup_t next = h->offered.exchange(nullptr, std::memory_order_acq_rel);
    if (!next) return;
    const int r = os_workgroup_join(next, &token);
    h->joinError.store(r, std::memory_order_relaxed);
    if (r == 0) {
        current = next;
        h->joined.store(true, std::memory_order_relaxed);
        h->joins.fetch_add(1, std::memory_order_relaxed);
    } else {
        os_release(next);
    }
}
Host *gHost = nullptr;

void setRealtime() {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    const double msToTicks = 1e6 * tb.denom / tb.numer;
    thread_time_constraint_policy_data_t p;
    p.period = static_cast<uint32_t>(5 * msToTicks);
    p.computation = static_cast<uint32_t>(1 * msToTicks);
    p.constraint = static_cast<uint32_t>(4 * msToTicks);
    p.preemptible = 1;
    thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
                      reinterpret_cast<thread_policy_t>(&p), THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}

void audioLoop(Host *h) {
    setRealtime();
    Shared *s = h->shared;
    uint32_t seen = s->request.load(std::memory_order_acquire);
    PluginNote notes[kMaxNotes];
    os_workgroup_t workgroup = nullptr;
    os_workgroup_join_token_s token{};
    uint32_t offersSeen = 0;
    while (true) {
        waitChange(s->request, seen, 0);
        seen = s->request.load(std::memory_order_acquire);
        if (s->quit.load(std::memory_order_acquire)) {
            // A thread that exits while still in a workgroup makes libdispatch trap (a crash report per host on every
            // quit while the device runs), so leave it first.
            if (workgroup) { os_workgroup_leave(workgroup, &token); os_release(workgroup); }
            h->joined.store(false, std::memory_order_relaxed);
            return;
        }
        if (const uint32_t offers = h->offers.load(std::memory_order_acquire); offers != offersSeen) {
            offersSeen = offers;
            adoptWorkgroup(h, workgroup, token);
        }
        const int frames = s->frames;
        if (frames == 0) h->plugin->idle(); // the engine's transport is stopped (parameter flushes)
        if (frames <= 0 || frames > kMaxFrames) { s->done.store(seen, std::memory_order_release); wake(s->done); continue; }
        for (int i = 0; i < s->automationCount && i < kMaxAutomation; ++i) h->plugin->automate(s->automation[i].id, s->automation[i].value);
        const int n = std::min(s->noteCount, kMaxNotes);
        for (int i = 0; i < n; ++i) notes[i] = s->notes[i];
        h->plugin->setSidechain(s->sidechain ? s->scL : nullptr, s->sidechain ? s->scR : nullptr);
        std::memcpy(s->outL, s->inL, sizeof(float) * size_t(frames));
        std::memcpy(s->outR, s->inR, sizeof(float) * size_t(frames));
        h->plugin->process(s->outL, s->outR, frames, notes, n);
        s->done.store(seen, std::memory_order_release);
        wake(s->done);
    }
}

void reply(int fd, bool ok, const std::string &payload = {}) { (void)sendMessage(fd, ok ? 1 : 0, payload); }

// A crashing host tells the engine at once, before the system's crash reporter holds the dying process for seconds:
// the signal handler writes a prepared kCrashed message and re-raises the signal.
char gCrashMessage[6][64];
size_t gCrashLength[6];
constexpr int kCrashSignals[6] = {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP};

void onCrash(int sig) {
    for (int i = 0; i < 6; ++i)
        if (kCrashSignals[i] == sig) { (void)!::write(3, gCrashMessage[i], gCrashLength[i]); break; }
    ::signal(sig, SIG_DFL);
    ::raise(sig);
}

void installCrashReporter() {
    static char altStack[64 * 1024]; // a stack overflow still reports
    stack_t ss{};
    ss.ss_sp = altStack;
    ss.ss_size = sizeof altStack;
    ::sigaltstack(&ss, nullptr);
    for (int i = 0; i < 6; ++i) {
        Writer payload;
        payload.str(std::string("crashed (") + strsignal(kCrashSignals[i]) + ")");
        Writer framed;
        framed.u32(static_cast<uint32_t>(payload.b.size() + 1));
        framed.u8(kCrashed);
        framed.b += payload.b;
        std::memcpy(gCrashMessage[i], framed.b.data(), std::min(framed.b.size(), sizeof gCrashMessage[i]));
        gCrashLength[i] = std::min(framed.b.size(), sizeof gCrashMessage[i]);
        struct sigaction sa{};
        sa.sa_handler = onCrash;
        sa.sa_flags = SA_ONSTACK | SA_RESETHAND;
        ::sigaction(kCrashSignals[i], &sa, nullptr);
    }
}

void serve(Host *h, uint8_t op, const std::string &payload) {
    PluginProcessor &p = *h->plugin;
    Reader r{payload};
    Writer w;
    switch (op) {
        case opGetState: { std::string s; const bool ok = p.getState(s); w.u8(ok); w.str(s); break; }
        case opSetState: { const std::string s = r.str(); w.u8(r.ok && p.setState(s)); break; }
        case opSetStateDocument: { const std::string s = r.str(); w.u8(r.ok && p.setStateFromDocument(s)); break; }
        case opStateError: w.str(p.stateError()); break;
        case opParameterCount: w.i32(p.parameterCount()); break;
        case opParameter: {
            PluginParameter q;
            const int32_t index = r.i32();
            const bool ok = r.ok && p.parameter(index, q);
            w.u8(ok);
            if (ok) {
                w.u32(q.id); w.str(q.title); w.str(q.units); w.str(q.display);
                w.f64(q.value); w.f64(q.defaultValue); w.i32(q.stepCount);
                w.u8(q.automatable); w.u8(q.readOnly); w.u8(q.hidden);
            }
            break;
        }
        case opParameterText: {
            const uint32_t id = r.u32();
            const double v = r.f64();
            std::string text;
            const bool ok = r.ok && p.parameterText(id, v, text);
            w.u8(ok); w.str(text);
            break;
        }
        case opSetParameter: { const uint32_t id = r.u32(); const double v = r.f64(); w.u8(r.ok && p.setParameter(id, v)); break; }
        case opTouched: {
            std::vector<std::pair<uint32_t, double>> t;
            p.touchedParameters(t);
            w.u32(static_cast<uint32_t>(t.size()));
            for (const auto &[id, v] : t) { w.u32(id); w.f64(v); }
            break;
        }
        case opEditCount: { const uint64_t v = p.editCount(); w.b.append(reinterpret_cast<const char *>(&v), 8); break; }
        case opAutomationRange: { double lo = 0, hi = 1; const uint32_t id = r.u32(); const bool ok = p.automationRange(id, lo, hi); w.u8(ok); w.f64(lo); w.f64(hi); break; }
        case opResponse: {
            const uint32_t n = std::min<uint32_t>(r.u32(), 1u << 16);
            std::vector<double> hz(n), db(n);
            for (uint32_t i = 0; i < n; ++i) hz[i] = r.f64();
            const bool ok = r.ok && p.response(hz.data(), static_cast<int>(n), db.data());
            w.u8(ok);
            for (double v : db) w.f64(v);
            break;
        }
        case opLatency: w.u32(p.latency()); break;
        case opHasEditor: w.u8(p.hasEditor()); break;
        case opIsolationStats:
            w.u8(h->joined.load(std::memory_order_relaxed));
            w.i32(h->joinError.load(std::memory_order_relaxed));
            w.u32(h->joins.load(std::memory_order_relaxed));
            break;
        case opShowEditor: {
            const std::string title = r.str();
            const double x = r.f64(), y = r.f64();
            int32_t width = 0, height = 0;
            std::string why;
            const bool first = !hostui::appStarted();
            if (!r.ok || !hostui::showEditor(p, title, x, y, width, height, why)) {
                Writer e;
                e.str(why);
                reply(h->fd, false, e.b);
                return;
            }
            // From now on the main thread runs AppKit's event loop (plughostMain switches to it).
            if (first) CFRunLoopStop(CFRunLoopGetMain());
            w.i32(width); w.i32(height);
            break;
        }
        case opCloseEditor: hostui::closeEditor(); break;
        case opEditorWindow: {
            const hostui::EditorWindow e = hostui::editorWindow();
            w.u8(e.visible); w.u8(e.open);
            w.f64(e.x); w.f64(e.y); w.f64(e.width); w.f64(e.height); w.f64(e.contentWidth); w.f64(e.contentHeight);
            w.b.append(reinterpret_cast<const char *>(&e.windowNumber), 8);
            w.b.append(reinterpret_cast<const char *>(&e.level), 8);
            break;
        }
        case opEditorSnapshot: {
            const std::string path = r.str();
            if (!r.ok || !hostui::snapshot(path)) { reply(h->fd, false); return; }
            break;
        }
        default: reply(h->fd, false); return;
    }
    reply(h->fd, true, w.b);
}

void onControl(CFFileDescriptorRef ref, CFOptionFlags, void *) {
    Host *h = gHost;
    uint8_t op = 0;
    std::string payload;
    // One message per callback; the descriptor is re-armed below so the run loop keeps serving.
    if (!receiveMessage(h->fd, op, payload, 0) || op == opQuit) _exit(0); // engine gone or done: skip plug-in teardown
    serve(h, op, payload);
    CFFileDescriptorEnableCallBacks(ref, kCFFileDescriptorReadCallBack);
}

} // namespace

namespace {
class Launch final : public RemotePluginLaunch {
public:
    std::unique_ptr<RemotePluginProcessor> p = std::make_unique<RemotePluginProcessor>();
    Status poll(std::string &err) override {
        if (!p) return Status::failed;
        switch (p->pollLaunch(err)) {
            case RemotePluginProcessor::Launch::ready: return Status::ready;
            case RemotePluginProcessor::Launch::failed: return Status::failed;
            default: return Status::loading;
        }
    }
    std::unique_ptr<PluginProcessor> take() override { return std::move(p); }
    bool stateAccepted() const override { return p && p->stateAccepted(); }
    std::string stateError() const override { return p ? p->launchStateError() : std::string(); }
};
} // namespace

std::unique_ptr<RemotePluginLaunch> launchRemotePlugin(const std::string &hostPath, const std::string &format,
                                                       const std::string &path, const std::string &classId,
                                                       double sampleRate, int maxBlock, int loadTimeoutMs,
                                                       const std::string *state, bool document, std::string &err) {
    auto l = std::make_unique<Launch>();
    if (!l->p->launch(hostPath, format, path, classId, sampleRate, maxBlock, false, loadTimeoutMs, state, document, err))
        return nullptr;
    return l;
}

std::unique_ptr<PluginProcessor> loadRemotePlugin(const std::string &hostPath, const std::string &format,
                                                  const std::string &path, const std::string &classId,
                                                  double sampleRate, int maxBlock, bool offline, int loadTimeoutMs,
                                                  std::string &err) {
    auto p = std::make_unique<RemotePluginProcessor>();
    if (!p->start(hostPath, format, path, classId, sampleRate, maxBlock, offline, loadTimeoutMs, err)) return nullptr;
    return p;
}

int plughostMain(int argc, char **argv) {
    std::string shm, format, path, classId;
    double rate = 48000;
    int block = 512;
    bool offline = false, rendezvous = false;
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        auto next = [&]() -> std::string { return i + 1 < argc ? argv[++i] : ""; };
        if (a == "--shm") shm = next();
        else if (a == "--format") format = next();
        else if (a == "--path") path = next();
        else if (a == "--class") classId = next();
        else if (a == "--rate") rate = std::atof(next().c_str());
        else if (a == "--block") block = std::atoi(next().c_str());
        else if (a == "--offline") offline = true;
        else if (a == "--rendezvous") rendezvous = true;
    }
    std::signal(SIGPIPE, SIG_IGN);
    Host host;
    gHost = &host;
    const int fd = ::shm_open(shm.c_str(), O_RDWR, 0);
    void *mem = fd >= 0 ? ::mmap(nullptr, sizeof(Shared), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) : MAP_FAILED;
    if (fd >= 0) ::close(fd);
    Writer err;
    if (mem == MAP_FAILED || static_cast<Shared *>(mem)->magic != kMagic || static_cast<Shared *>(mem)->size != sizeof(Shared)) {
        err.str("the plug-in host could not attach to the engine (version mismatch?)");
        reply(host.fd, false, err.b);
        return 2;
    }
    host.shared = static_cast<Shared *>(mem);
    hostui::setKeySink([](uint16_t code, uint64_t mods, const char *chars, const char *bare) {
        Shared *sh = gHost->shared;
        const uint32_t w = sh->keyWrite.load(std::memory_order_relaxed);
        if (w - sh->keyRead.load(std::memory_order_acquire) >= Shared::kKeys) return; // Dalnok is not collecting: drop
        Shared::Key &k = sh->keys[w % Shared::kKeys];
        k.keyCode = code;
        k.modifiers = mods;
        std::snprintf(k.characters, sizeof k.characters, "%s", chars);
        std::snprintf(k.charactersIgnoringModifiers, sizeof k.charactersIgnoringModifiers, "%s", bare);
        sh->keyWrite.store(w + 1, std::memory_order_release);
    });
    installCrashReporter();
    startWorkgroupListener(&host, rendezvous);
    std::string why;
    host.plugin = loadPlugin(format, path, classId, rate, block, offline, why);
    if (!host.plugin) {
        err.str(why);
        reply(host.fd, false, err.b);
        return 2;
    }
    // The start request carries the saved state, so restoring it is part of loading and never blocks the engine.
    uint8_t op = 0;
    std::string init;
    if (!receiveMessage(host.fd, op, init, 0) || op != opInit) return 0; // the engine gave up on us
    Reader ir{init};
    const bool hasState = ir.u8(), document = ir.u8();
    const std::string state = ir.str();
    bool stateAccepted = true;
    std::string stateError;
    if (hasState && ir.ok) {
        stateAccepted = document ? host.plugin->setStateFromDocument(state) : host.plugin->setState(state);
        if (!stateAccepted) stateError = host.plugin->stateError();
    }
    std::thread(audioLoop, &host).detach();
    Writer hello;
    hello.u8(host.plugin->instrument());
    hello.u8(host.plugin->hasSidechain());
    hello.u32(host.plugin->latency());
    hello.str(host.plugin->name());
    hello.str(host.plugin->vendor());
    hello.str(host.plugin->classId());
    hello.str(host.plugin->categories());
    hello.u8(stateAccepted);
    hello.str(stateError);
    reply(host.fd, true, hello.b);
    // Control requests are served on the main thread inside its run loop, as the plug-in formats expect.
    CFFileDescriptorRef ref = CFFileDescriptorCreate(nullptr, host.fd, false, onControl, nullptr);
    CFRunLoopSourceRef source = CFFileDescriptorCreateRunLoopSource(nullptr, ref, 0);
    // Common modes: requests are still served while an editor tracks the mouse or runs a modal dialog, so holding a
    // knob never looks like a hang to the engine.
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CFFileDescriptorEnableCallBacks(ref, kCFFileDescriptorReadCallBack);
    CFRunLoopRun();
    if (hostui::appStarted()) hostui::runApp(); // the first editor turned the host into an AppKit application
    return 0;
}

void releaseMachSendRight(uint32_t port) {
    if (port) mach_port_deallocate(mach_task_self(), port);
}

} // namespace dalnok

extern "C" int dalnok_plughost_main(int argc, char **argv) { return dalnok::plughostMain(argc, argv); }
