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
#import <math.h>
#import <string.h>
#import <os/log.h>
#import <stdatomic.h>

static os_log_t ETLinkLog(void) {
    static os_log_t l;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = os_log_create("ai.nemut.effetune", "link"); });
    return l;
}

// ---- 線の形式 ----
//
// TCP はバイトの列で、4 バイト境界では切れてくれない。recv が返す n が 4 の倍数だと
// 決めつけて n/4 サンプルだけ取ると、余りの 1〜3 バイトが捨てられる。そこから先は
// 隣り合う 2 サンプルにまたがる 4 バイトを float として読むことになり、指数部が
// 任意の値になるので NaN・1e38・非正規化まで飛ぶ。1 回ずれたら復帰しない。
//
// そこで
//   1. 送受とも端数をバイト単位で持ち越す（捨てない・送り直さない）
//   2. チャンクごとにマジックとサンプル数を付け、受け側で毎回検算する
// の両方を持たせた。1 だけだと、ずれたときに誰も気付けない。
//
// 同一機内の 127.0.0.1 しか通らないのでバイト順の変換はしない。送受ともこのファイル。
// 値は 'ETLK1001'。リトルエンディアンで書くので hexdump には "1001KLTE" と並ぶ。
#define ET_LINK_MAGIC       0x45544c4b31303031ull
#define ET_LINK_HDR_BYTES   12                      // マジック 8 + サンプル数 4
#define ET_LINK_MAX_SAMPLES 4096                    // 1 チャンクの上限（2048 フレーム）
#define ET_LINK_CHUNK_BYTES (ET_LINK_HDR_BYTES + ET_LINK_MAX_SAMPLES * sizeof(float))

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
    // 送信中のチャンク。_txOff はサンプルではなくバイト位置。
    uint8_t *_txBuf;
    size_t _txLen;
    size_t _txOff;
    uint32_t _txSamples;
    // 繋がっていないあいだの空回りの回数。connect 試行を間引くのに使う。
    uint32_t _idlePumps;
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
        // malloc 由来なので先頭は 16 バイト境界。ヘッダ 12 の直後の float 配列も 4 で揃う。
        _txBuf = calloc(1, ET_LINK_CHUNK_BYTES);
    }
    return self;
}

- (BOOL)connected { return _fd >= 0; }

- (void)start {
    if (_running) return;
    _running = YES;
    _r = atomic_load(&_w);
    _txLen = _txOff = 0;
    _txSamples = 0;
    _idlePumps = 0;   // 新しい回は 1 回目で撃つ
    // 毎回 0 から数える。累計のままだと、今回何も送っていなくても
    // 「送信=188万」のように見えて、ログで判断を誤る。
    _sentFrames = 0;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
    // **ここが受け手の詰められる下限を決める。**音は滑らかに流れず、
    // この周期ぶんの塊で届く。10ms なら 480 フレームの塊で、受け手は
    // 塊と塊の谷を埋めるだけ溜めていないと読み切ってしまう（実測で
    // 384 フレームが下限だった）。2ms なら 96 フレーム。
    // leeway を 0 にするのは、合流で遅れると谷がその分深くなるから。
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, 2 * NSEC_PER_MSEC, 0);
    __weak typeof(self) weak = self;
    dispatch_source_set_event_handler(_timer, ^{ [weak pump]; });
    dispatch_resume(_timer);
    os_log_error(ETLinkLog(), "ET sender 開始");
}

- (void)stop {
    _running = NO;
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    dispatch_async(_q, ^{
        if (self->_fd >= 0) { close(self->_fd); self->_fd = -1; }
        self->_txLen = self->_txOff = 0;
        self->_txSamples = 0;
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
        if (logged++ < 5) os_log_error(ETLinkLog(), "ET connect 失敗 errno=%d", errno);
        close(fd);
        return;
    }
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    _fd = fd;
    _r = atomic_load(&_w);   // 繋がった時点から送る
    // 前の接続で送り残したチャンクの途中から流すと、新しいストリームの先頭が
    // ヘッダにならない。持ち越しはここで捨てる。
    _txLen = _txOff = 0;
    _txSamples = 0;
    os_log_error(ETLinkLog(), "ET connect 成功 port=%d", ET_LINK_PORT);
}

/// 送信中のチャンクの残りを吐き出す。全部出せたら YES。
/// 端数で止まったら _txOff にバイト位置を残して NO を返す。
/// send が返すのはバイト数で、float の途中で止まりうる。ここをサンプル単位で
/// 数えると端数バイトは送信済みなのに読み位置が戻り、同じサンプルの先頭を
/// 送り直す＝受け側が 1〜3 バイトずれる。だからバイトで数える。
- (BOOL)flushPending {
    while (_txOff < _txLen) {
        ssize_t sent = send(_fd, _txBuf + _txOff, _txLen - _txOff, 0);
        if (sent > 0) { _txOff += (size_t)sent; continue; }
        if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return NO;
        os_log_error(ETLinkLog(), "send 失敗 errno=%d", errno);
        close(_fd); _fd = -1;
        _txLen = _txOff = 0;
        _txSamples = 0;
        return NO;
    }
    // 送り切ったチャンクだけ数える。途中で止まったぶんは次の pump で数える。
    if (_txSamples) { _sentFrames += _txSamples / 2; _txSamples = 0; }
    return YES;
}

- (void)pump {
    if (!_running) return;
    // **繋がっていないあいだの connect 試行を間引く。**
    // 周期は 2ms なので、本体が 47101 を開くまで socket → connect → close の
    // 三連が 500 回/秒走っていた。100 回に 1 回（5 回/秒）まで落とす。
    //
    // 剰余が 0 の回に撃つので、**最初の 1 回は必ず撃つ**。
    // ここを `++_idlePumps % 100` と書くと初回が飛んで、繋がるまで 200ms 待つ。
    // 繋がったあとはこの行を通らないので、送出の周期は変えていない。
    if (_fd < 0 && (_idlePumps++ % 100) != 0) return;
    [self ensureConnected];
    if (_fd < 0) return;

    if (![self flushPending]) return;   // 前回の残りが先

    uint64_t w = atomic_load_explicit(&_w, memory_order_acquire);
    uint64_t r = _r;
    if (w <= r) return;
    uint64_t avail = w - r;
    if (avail > SEND_RING_SAMPLES) { r = w - SEND_RING_SAMPLES; avail = SEND_RING_SAMPLES; }

    while (avail >= 2) {
        uint32_t n = (uint32_t)MIN(avail, (uint64_t)ET_LINK_MAX_SAMPLES);
        n &= ~1u;   // 必ず偶数サンプルで切る。奇数だと以後 L と R が入れ替わる
        if (n == 0) break;

        uint64_t magic = ET_LINK_MAGIC;
        uint32_t count = n;
        memcpy(_txBuf, &magic, sizeof(magic));
        memcpy(_txBuf + 8, &count, sizeof(count));
        float *payload = (float *)(void *)(_txBuf + ET_LINK_HDR_BYTES);
        for (uint32_t i = 0; i < n; i++) payload[i] = _ring[(r + i) % SEND_RING_SAMPLES];

        _txLen = ET_LINK_HDR_BYTES + (size_t)n * sizeof(float);
        _txOff = 0;
        _txSamples = n;

        // リングから _txBuf へ写した時点で読み位置を進める。送信が途中で止まっても
        // 残りは _txBuf が持っているので、リングを読み直す必要は無い。
        r += n;
        avail -= n;
        _r = r;

        if (![self flushPending]) return;   // 続きは次の pump
    }
    _r = r;
}

@end

// ---- 受け手 ----

#define RECV_RING_SAMPLES (48000 * 2 * 2)
#define RX_BUF_BYTES      65536     // 1 チャンク（最大 16396 バイト）より十分大きく取る

@implementation ETLinkReceiver {
    int _listenFd;
    int _peerFd;
    dispatch_queue_t _q;
    dispatch_source_t _timer;
    float *_ring;
    _Atomic uint64_t _w;
    uint64_t _r;
    // 受信したバイトをそのまま溜める。float に切り出すのは境界が揃ってから。
    uint8_t *_rxBuf;
    size_t _rxLen;
    uint64_t _badSamples;
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
        _rxBuf = calloc(1, RX_BUF_BYTES);
    }
    return self;
}

- (BOOL)listening { return _listenFd >= 0; }
- (BOOL)hasPeer   { return _peerFd >= 0; }

/// 貼り直すときに書き位置から下げる量。**経路の遅れの大半がここ。**
/// 1024 は 48 kHz で 21.3 ms。実機で刻んで測った結果、384 は取りこぼし、
/// 512 で枯れ、576 でもたまに枯れる。谷の深さは一定ではないので、
/// 一度 never になった値が安全とは限らない。たまに出る値の倍を取った。
#define TARGET_FRAMES 1024u
/// 枯れたときに逃げる先。**設定には出さない。**選ばせるものではなく、
/// 1024 で保たない機械や場面のための逃げ道。繋ぎ直すと戻る。
#define TARGET_FALLBACK 2048u
/// 溜め直しを諦めるまでの回数。**無限に待たない。**条件を満たせない
/// 状態に落ちたときに、永久に無音を出し続ける口を残さないため。
#define REFILL_GIVE_UP 200
/// 深い側へ移るまでに要る枯れの回数と、「続いた」と見なす間隔。
/// **散発的な 1 回では移らない。**9 秒に 1 度の 5 ms の欠けは聴こえず、
/// そこで遅れを倍にするのは損。短い間に繰り返すなら 1024 では保たない。
#define STARVE_TO_FALL_BACK 3
#define STARVE_NEAR_FRAMES (48000u * 5u)
/// 繋がってからこれだけ受け取るまでは枯れとして数えない。
/// **立ち上がりは必ず通る。**溜まりは 0 から始まるので、最初の数回は
/// 読みに行くほうが早い（実機のログで 107 ms と 533 ms の 2 回）。
#define SETTLE_FRAMES 48000u

/// 前に枯れたときの受信フレーム数と、近いうちに続いた回数。
/// オーディオスレッドだけが書くが、繋ぎ直しで 0 に戻すので atomic。
static _Atomic uint64_t gLastStarveAt = 0;
static _Atomic uint32_t gStarveRun = 0;

static _Atomic uint32_t gTarget = TARGET_FRAMES;
/// 尽きて無音を書いた回数と、そのフレーム数。**耳では数えられない。**
static _Atomic uint32_t gStarveCount = 0;
static _Atomic uint64_t gStarveFrames = 0;
/// 溜まりすぎて捨てた回数と、そのフレーム数。クロックのずれの速さが読める。
static _Atomic uint32_t gTrimCount = 0;
static _Atomic uint64_t gTrimFrames = 0;
/// 溜め直している最中か。枯れた瞬間は読み位置が書き位置に追いついていて、
/// そのまま読み続けると届くそばから読み切る。1 度まとめて待つ。
static _Atomic bool gRefilling = false;
/// 溜め直しで待った回数。REFILL_GIVE_UP で諦める。
static _Atomic uint32_t gRefillWaits = 0;

+ (uint32_t)targetFrames { return atomic_load_explicit(&gTarget, memory_order_relaxed); }
+ (uint32_t)starveCount  { return atomic_load_explicit(&gStarveCount, memory_order_relaxed); }
+ (uint64_t)starveFrames { return atomic_load_explicit(&gStarveFrames, memory_order_relaxed); }
+ (uint32_t)trimCount    { return atomic_load_explicit(&gTrimCount, memory_order_relaxed); }
+ (uint64_t)trimFrames   { return atomic_load_explicit(&gTrimFrames, memory_order_relaxed); }

/// 繋ぎ直したときに、浅い側から始め直す。
+ (void)resetLinkState {
    atomic_store_explicit(&gTarget, TARGET_FRAMES, memory_order_relaxed);
    atomic_store_explicit(&gStarveCount, 0, memory_order_relaxed);
    atomic_store_explicit(&gStarveFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&gTrimCount, 0, memory_order_relaxed);
    atomic_store_explicit(&gTrimFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&gRefilling, false, memory_order_relaxed);
    atomic_store_explicit(&gRefillWaits, 0, memory_order_relaxed);
    atomic_store_explicit(&gLastStarveAt, 0, memory_order_relaxed);
    atomic_store_explicit(&gStarveRun, 0, memory_order_relaxed);
}

- (uint32_t)bufferedFrames {
    uint64_t w = atomic_load_explicit(&_w, memory_order_acquire);
    uint64_t r = _r;
    if (w <= r) return 0;
    uint64_t samples = w - r;
    if (samples > RECV_RING_SAMPLES) samples = RECV_RING_SAMPLES;
    return (uint32_t)(samples / 2);
}

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
    _rxLen = 0;
    os_log_error(ETLinkLog(), "ET receiver 待ち受け開始 port=%d", ET_LINK_PORT);

    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
    // 受け取る側の周期も溜まりに足し算される。送り手と同じく詰める。
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, 1 * NSEC_PER_MSEC, 0);
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
        self->_rxLen = 0;
    });
}

/// チャンク本体をリングへ写す。
- (void)writeSamples:(const uint8_t *)bytes count:(uint32_t)count {
    uint64_t w = atomic_load_explicit(&_w, memory_order_relaxed);
    uint64_t badBefore = _badSamples;
    for (uint32_t i = 0; i < count; i++) {
        float v;
        // _rxBuf の途中から読むので 4 バイト境界に乗っている保証が無い。memcpy で取る。
        memcpy(&v, bytes + (size_t)i * sizeof(float), sizeof(v));
        // NaN や inf を 1 つ通すと IIR の状態が戻らなくなり、以後ずっと無音か轟音になる。
        // ここで落として数を記録する（黙って埋めると原因が見えない）。
        if (!isfinite(v)) { v = 0.0f; _badSamples++; }
        _ring[(w + i) % RECV_RING_SAMPLES] = v;
    }
    atomic_store_explicit(&_w, w + count, memory_order_release);
    _receivedFrames += count / 2;

    // ここで出さないと、同期ずれを伴わない非有限値（送り手側で既に壊れている音）が
    // 黙って 0 に置き換わる。consume 側の bad= は同期ずれが起きたときしか通らない。
    if (_badSamples > badBefore) {
        static int logged = 0;
        if (logged++ < 20) {
            os_log_error(ETLinkLog(), "ET 非有限値 %llu 個を 0 にした 累計=%llu",
                         (unsigned long long)(_badSamples - badBefore),
                         (unsigned long long)_badSamples);
        }
    }
}

/// 溜めたバイト列から取り出せるチャンクを全部取り出し、残りを先頭へ寄せる。
/// ヘッダが揃わない端数・本体が届いていないチャンクはそのまま次の recv へ持ち越す。
- (void)consume {
    size_t off = 0;
    size_t skipped = 0;
    while (_rxLen - off >= ET_LINK_HDR_BYTES) {
        uint64_t magic = 0;
        uint32_t count = 0;
        memcpy(&magic, _rxBuf + off, sizeof(magic));
        memcpy(&count, _rxBuf + off + 8, sizeof(count));
        // 送り側が必ず偶数サンプルで切るので、奇数はずれている証拠として弾く。
        if (magic != ET_LINK_MAGIC || count == 0 || (count & 1u) || count > ET_LINK_MAX_SAMPLES) {
            off += 1;       // 1 バイトずつずらして次のマジックを探す
            skipped++;
            continue;
        }
        size_t need = ET_LINK_HDR_BYTES + (size_t)count * sizeof(float);
        if (_rxLen - off < need) break;     // 本体がまだ揃っていない
        [self writeSamples:_rxBuf + off + ET_LINK_HDR_BYTES count:count];
        off += need;
    }
    if (off > 0) {
        memmove(_rxBuf, _rxBuf + off, _rxLen - off);
        _rxLen -= off;
    }
    if (skipped > 0) {
        static int logged = 0;
        if (logged++ < 20) {
            os_log_error(ETLinkLog(), "ET 同期ずれ %zu バイト読み飛ばし bad=%llu",
                         skipped, (unsigned long long)_badSamples);
        }
    }
}

- (void)pump {
    if (_listenFd < 0) return;
    if (_peerFd < 0) {
        int c = accept(_listenFd, NULL, NULL);
        if (c >= 0) {
            int fl = fcntl(c, F_GETFL, 0);
            fcntl(c, F_SETFL, fl | O_NONBLOCK);
            _peerFd = c;
            _rxLen = 0;     // 前の相手の書きかけを新しいストリームに混ぜない
            // **浅い側から始め直す。**前の相手で枯れて深くしたぶんを
            // 引き継ぐと、一度の混み合いで遅れが増えたまま固定される。
            [ETLinkReceiver resetLinkState];
            os_log_error(ETLinkLog(), "ET 接続を受けた");
        }
        return;
    }
    for (int pass = 0; pass < 8; pass++) {
        // consume の後は必ず 1 チャンク未満しか残らないので空きはあるが、
        // 長さ 0 の recv は戻り値 0（＝切断）と区別できないので念のため止める。
        if (_rxLen >= RX_BUF_BYTES) return;
        ssize_t n = recv(_peerFd, _rxBuf + _rxLen, RX_BUF_BYTES - _rxLen, 0);
        if (n == 0) {
            os_log(ETLinkLog(), "相手が切断した");
            close(_peerFd); _peerFd = -1;
            _rxLen = 0;
            return;
        }
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            os_log_error(ETLinkLog(), "recv 失敗 errno=%d", errno);
            close(_peerFd); _peerFd = -1;
            _rxLen = 0;
            return;
        }
        // n は 4 の倍数とは限らない。端数は _rxBuf に残したまま次の recv と繋ぐ。
        _rxLen += (size_t)n;
        [self consume];
    }
}

- (uint32_t)readInterleaved:(float *)out frames:(uint32_t)frames {
    uint64_t w = atomic_load_explicit(&_w, memory_order_acquire);
    uint64_t r = _r;
    uint32_t want = frames * 2;
    uint64_t behind = (uint64_t)atomic_load_explicit(&gTarget,
                                                     memory_order_relaxed) * 2ull;

    // **貼り直しを先に済ませる。**溜め直しの判定より前に置くこと。
    // 逆にすると、読み位置が 0 のまま（初回や繋ぎ直しの直後）は
    // 貼り直しに届かず、条件を満たせないまま無音を出し続ける。
    //
    // 溜まりすぎたら捨てるのもここ。送り手と読み手のクロックはぴたりとは
    // 合わず、読んだぶんだけ進めるだけでは溜まりが漂う。上限が無かった
    // ときは、狙い 128 に対して実測 3000 まで伸びていた。
    if (r == 0 || w > r + RECV_RING_SAMPLES || (w > r && w - r > behind * 2)) {
        uint64_t was = r;
        r = (w > behind) ? (w - behind) : 0;
        if (was != 0 && r > was) {
            atomic_fetch_add_explicit(&gTrimCount, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&gTrimFrames, (r - was) / 2, memory_order_relaxed);
        }
    }

    // **溜め直しの途中は読まない。**枯れた直後は読み位置が書き位置に
    // 追いついていて、そのまま読み続けると届くそばから読み切る。
    // 細かく途切れ続けるより、1 度まとめて待って立て直す。
    // **待ち続けない。**溜まらないまま REFILL_GIVE_UP 回まで来たら諦めて読む。
    if (atomic_load_explicit(&gRefilling, memory_order_acquire)) {
        uint32_t waits = atomic_fetch_add_explicit(&gRefillWaits, 1, memory_order_relaxed);
        if ((w > r && w - r >= behind) || waits >= REFILL_GIVE_UP) {
            atomic_store_explicit(&gRefilling, false, memory_order_release);
            atomic_store_explicit(&gRefillWaits, 0, memory_order_relaxed);
        } else {
            for (uint32_t i = 0; i < want; i++) out[i] = 0.0f;
            _r = r;
            return 0;
        }
    }

    uint64_t avail = (w > r) ? (w - r) : 0;
    uint32_t got = (uint32_t)MIN(avail, (uint64_t)want);
    for (uint32_t i = 0; i < got; i++) out[i] = _ring[(r + i) % RECV_RING_SAMPLES];
    for (uint32_t i = got; i < want; i++) out[i] = 0.0f;
    // **埋めたことを残す。**ここは無音を書いて黙って進むので、
    // 記録しないと詰めすぎたのか足りているのか分からない。
    //
    // **鳴る前の空回りは枯れではない。**相手が繋がる前も音のコールバックは
    // 回っていて、当然データが無いので毎枠ここへ来る。数えると Ran dry が
    // 本物と見分けられなくなり、狙いまで 2048 へ逃げて遅れが無駄に増える
    // （実機のログで、枯れ 4 件が全部「受信=0」だった）。
    BOOL live = (_peerFd >= 0) && (_receivedFrames > SETTLE_FRAMES);
    if (got < want && live) {
        atomic_fetch_add_explicit(&gStarveCount, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&gStarveFrames,
                                  (uint64_t)(want - got) / 2, memory_order_relaxed);
        // **最初の何回かだけ書き出す。**毎枠出すと洪水になって、
        // 肝心の間隔が読めなくなる。頻度は Diagnostics の数で見る。
        static int logged = 0;
        if (logged++ < 40) {
            os_log_error(ETLinkLog(),
                         "ET 枯れ 埋め=%u/%u 溜まり=%llu 狙い=%u 受信=%llu 連=%u",
                         (want - got) / 2, want / 2,
                         (unsigned long long)((w > r) ? (w - r) / 2 : 0),
                         atomic_load_explicit(&gTarget, memory_order_relaxed),
                         (unsigned long long)_receivedFrames,
                         atomic_load_explicit(&gStarveRun, memory_order_relaxed) + 1);
        }
        // **続いたときだけ深い側へ移る。**離れて 1 回なら聴こえないので、
        // そこで遅れを倍にする意味がない。前の枯れからの間隔で見る。
        uint64_t last = atomic_load_explicit(&gLastStarveAt, memory_order_relaxed);
        uint32_t run = (last != 0 && _receivedFrames - last < STARVE_NEAR_FRAMES)
                     ? atomic_load_explicit(&gStarveRun, memory_order_relaxed) + 1 : 1;
        atomic_store_explicit(&gStarveRun, run, memory_order_relaxed);
        atomic_store_explicit(&gLastStarveAt, _receivedFrames, memory_order_relaxed);
        if (run >= STARVE_TO_FALL_BACK) {
            atomic_store_explicit(&gTarget, TARGET_FALLBACK, memory_order_relaxed);
        }
        atomic_store_explicit(&gRefillWaits, 0, memory_order_relaxed);
        atomic_store_explicit(&gRefilling, true, memory_order_release);
    }
    _r = r + got;
    return got / 2;
}

@end
