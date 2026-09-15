//  LocalLink.m
//  BSD ソケットで書いてある。Network.framework だと拡張側の制約が読みにくいので、
//  拒否が出たときにどのシステムコールかがそのまま分かる形にした。

#import "LocalLink.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <os/log.h>
#import <stdatomic.h>

static os_log_t ETLinkLog(void) {
    static os_log_t l;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = os_log_create("ai.nemut.effetune", "link"); });
    return l;
}

// ---- 送り手 ----

#define SEND_RING_SAMPLES (48000 * 2 * 2)   // 2 秒

@implementation ETLinkSender {
    int _fd;
    dispatch_queue_t _q;
    dispatch_source_t _timer;
    float *_ring;
    _Atomic uint64_t _w;
    uint64_t _r;
    BOOL _running;
}

+ (ETLinkSender *)shared {
    static ETLinkSender *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[ETLinkSender alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _fd = -1;
        _q = dispatch_queue_create("ai.nemut.effetune.link.send", DISPATCH_QUEUE_SERIAL);
        _ring = calloc(SEND_RING_SAMPLES, sizeof(float));
    }
    return self;
}

- (BOOL)connected { return _fd >= 0; }

- (void)start {
    if (_running) return;
    _running = YES;
    _r = atomic_load(&_w);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
    // 10ms ごとに溜まったぶんを送る。接続が無ければ張り直す。
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
    __weak typeof(self) weak = self;
    dispatch_source_set_event_handler(_timer, ^{ [weak pump]; });
    dispatch_resume(_timer);
    os_log(ETLinkLog(), "sender 開始");
}

- (void)stop {
    _running = NO;
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    dispatch_async(_q, ^{
        if (self->_fd >= 0) { close(self->_fd); self->_fd = -1; }
    });
    os_log(ETLinkLog(), "sender 停止 sent=%llu", (unsigned long long)_sentFrames);
}

- (void)pushInterleaved:(const float *)samples frames:(uint32_t)frames channels:(uint32_t)channels {
    if (!samples || frames == 0) return;
    uint64_t w = atomic_load_explicit(&_w, memory_order_relaxed);
    for (uint32_t i = 0; i < frames; i++) {
        float l = samples[i * channels];
        float r = (channels > 1) ? samples[i * channels + 1] : l;
        _ring[(w + 0) % SEND_RING_SAMPLES] = l;
        _ring[(w + 1) % SEND_RING_SAMPLES] = r;
        w += 2;
    }
    atomic_store_explicit(&_w, w, memory_order_release);
}

- (void)ensureConnected {
    if (_fd >= 0) return;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        os_log_error(ETLinkLog(), "socket 失敗 errno=%d", errno);
        return;
    }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(ET_LINK_PORT);
    inet_pton(AF_INET, ET_LINK_HOST, &a.sin_addr);

    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) != 0) {
        static int logged = 0;
        if (logged++ < 3) os_log_error(ETLinkLog(), "connect 失敗 errno=%d", errno);
        close(fd);
        return;
    }
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    _fd = fd;
    _r = atomic_load(&_w);   // 繋がった時点から送る
    os_log(ETLinkLog(), "connect 成功 port=%d", ET_LINK_PORT);
}

- (void)pump {
    if (!_running) return;
    [self ensureConnected];
    if (_fd < 0) return;

    uint64_t w = atomic_load_explicit(&_w, memory_order_acquire);
    uint64_t r = _r;
    if (w <= r) return;
    uint64_t avail = w - r;
    if (avail > SEND_RING_SAMPLES) { r = w - SEND_RING_SAMPLES; avail = SEND_RING_SAMPLES; }

    static float buf[4096];
    while (avail > 0) {
        uint32_t n = (uint32_t)MIN(avail, (uint64_t)(sizeof(buf) / sizeof(float)));
        for (uint32_t i = 0; i < n; i++) buf[i] = _ring[(r + i) % SEND_RING_SAMPLES];
        ssize_t sent = send(_fd, buf, n * sizeof(float), 0);
        if (sent <= 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            os_log_error(ETLinkLog(), "send 失敗 errno=%d", errno);
            close(_fd); _fd = -1;
            return;
        }
        uint32_t sentSamples = (uint32_t)(sent / sizeof(float));
        r += sentSamples;
        avail -= sentSamples;
        _sentFrames += sentSamples / 2;
        if (sentSamples < n) break;
    }
    _r = r;
}

@end

// ---- 受け手 ----

#define RECV_RING_SAMPLES (48000 * 2 * 2)

@implementation ETLinkReceiver {
    int _listenFd;
    int _peerFd;
    dispatch_queue_t _q;
    dispatch_source_t _timer;
    float *_ring;
    _Atomic uint64_t _w;
    uint64_t _r;
}

+ (ETLinkReceiver *)shared {
    static ETLinkReceiver *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[ETLinkReceiver alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _listenFd = -1;
        _peerFd = -1;
        _q = dispatch_queue_create("ai.nemut.effetune.link.recv", DISPATCH_QUEUE_SERIAL);
        _ring = calloc(RECV_RING_SAMPLES, sizeof(float));
    }
    return self;
}

- (BOOL)listening { return _listenFd >= 0; }
- (BOOL)hasPeer   { return _peerFd >= 0; }

- (BOOL)start {
    if (_listenFd >= 0) return YES;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        os_log_error(ETLinkLog(), "receiver socket 失敗 errno=%d", errno);
        return NO;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(ET_LINK_PORT);
    inet_pton(AF_INET, ET_LINK_HOST, &a.sin_addr);

    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) != 0) {
        os_log_error(ETLinkLog(), "bind 失敗 errno=%d", errno);
        close(fd);
        return NO;
    }
    if (listen(fd, 1) != 0) {
        os_log_error(ETLinkLog(), "listen 失敗 errno=%d", errno);
        close(fd);
        return NO;
    }
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    _listenFd = fd;
    os_log(ETLinkLog(), "receiver 待ち受け開始 port=%d", ET_LINK_PORT);

    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, 5 * NSEC_PER_MSEC, 1 * NSEC_PER_MSEC);
    __weak typeof(self) weak = self;
    dispatch_source_set_event_handler(_timer, ^{ [weak pump]; });
    dispatch_resume(_timer);
    return YES;
}

- (void)stop {
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    dispatch_async(_q, ^{
        if (self->_peerFd >= 0) { close(self->_peerFd); self->_peerFd = -1; }
        if (self->_listenFd >= 0) { close(self->_listenFd); self->_listenFd = -1; }
    });
}

- (void)pump {
    if (_listenFd < 0) return;
    if (_peerFd < 0) {
        int c = accept(_listenFd, NULL, NULL);
        if (c >= 0) {
            int fl = fcntl(c, F_GETFL, 0);
            fcntl(c, F_SETFL, fl | O_NONBLOCK);
            _peerFd = c;
            os_log(ETLinkLog(), "接続を受けた");
        }
        return;
    }
    static float buf[8192];
    for (int pass = 0; pass < 8; pass++) {
        ssize_t n = recv(_peerFd, buf, sizeof(buf), 0);
        if (n == 0) {
            os_log(ETLinkLog(), "相手が切断した");
            close(_peerFd); _peerFd = -1;
            return;
        }
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            os_log_error(ETLinkLog(), "recv 失敗 errno=%d", errno);
            close(_peerFd); _peerFd = -1;
            return;
        }
        uint32_t samples = (uint32_t)(n / sizeof(float));
        uint64_t w = atomic_load_explicit(&_w, memory_order_relaxed);
        for (uint32_t i = 0; i < samples; i++) _ring[(w + i) % RECV_RING_SAMPLES] = buf[i];
        atomic_store_explicit(&_w, w + samples, memory_order_release);
        _receivedFrames += samples / 2;
    }
}

- (uint32_t)readInterleaved:(float *)out frames:(uint32_t)frames {
    uint64_t w = atomic_load_explicit(&_w, memory_order_acquire);
    uint64_t r = _r;
    uint32_t want = frames * 2;
    if (r == 0 || w > r + RECV_RING_SAMPLES) {
        uint64_t behind = 2048ull * 2ull;
        r = (w > behind) ? (w - behind) : 0;
    }
    uint64_t avail = (w > r) ? (w - r) : 0;
    uint32_t got = (uint32_t)MIN(avail, (uint64_t)want);
    for (uint32_t i = 0; i < got; i++) out[i] = _ring[(r + i) % RECV_RING_SAMPLES];
    for (uint32_t i = got; i < want; i++) out[i] = 0.0f;
    _r = r + got;
    return got / 2;
}

@end
