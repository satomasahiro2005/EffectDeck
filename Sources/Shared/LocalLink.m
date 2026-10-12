//  LocalLink.m
//  BSD ソケットで書いてある。Network.framework だと拡張側の制約が読みにくいので、
//  拒否が出たときにどのシステムコールかがそのまま分かる形にした。

#import "LocalLink.h"
#import "ETLinkCodec.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <string.h>
#import <os/log.h>
#import <stdatomic.h>
#import <pthread.h>
#import <time.h>
#import <mach/mach.h>

static os_log_t ETLinkLog(void) {
    static os_log_t l;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = os_log_create("ai.nemut.effetune", "link"); });
    return l;
}

// ---- 線の形式 ----
//
// チャンクのヘッダ（マジック 8 + サンプル数 4）、送り手のリングからの組み立て、
// 受け手の再同期、溜まりの方針は ETLinkCodec.{h,c} にある。
// ここに残したのはソケット・dispatch source・スレッド・ログだけ。
// 形式を変えるときは ETLinkCodec.h の説明と Tests/Native/link を先に読むこと。

// ---- 送り手 ----

// 繋がっていないあいだの再試行の周期。
//
// **繋がっていないあいだに 2ms は要らない。**やることは connect の 1 回だけで、
// 相手が待ち受けを開いていなければ何度撃っても同じ結果しか返らない。
// 200ms は今までの間引き（2ms の 100 回に 1 回）と同じ 5 回/秒なので、
// 繋がるまでの時間は変わらない。変わるのは空振りの起床が 500 回/秒から
// 5 回/秒に減ることだけ。
//
// **繋がってからは周期で回さない。**前は 2ms のタイマー（leeway 0）で回していて、
// 送るものが無くても、相手が止まっていて send が EAGAIN しか返さなくても
// 500 回/秒起きていた。いまは音を積んだ瞬間（pushInterleaved）に 1 回起こし、
// 相手が読んでいないあいだは書き込み可能の通知（WRITE）だけを待つ。
// 粒は WriteMix の 1 回分そのもので、2ms のタイマーより粗くなる所は無い
// （タイマーは 0〜2ms の位相ぶん余計に待っていた）。
//
// 起こし方:
//   音のスレッド → semaphore_signal → 起こし役のスレッド（ETLinkKickThread）
//   → dispatch_source_merge_data（DATA_OR）→ _q の pump。
// 音のスレッドが撃つのは mach の semaphore_signal 1 回だけ。init で作った
// セマフォと、init で立てて semaphore_wait で寝かせてあるスレッドを起こすだけで、
// スレッドの生成も確保も vm_map も無い。ソケットの状態は今までどおり _q だけが持つ
// （起こし役は merge するだけ）。音のスレッドからは「寝ていれば 1 回だけ」
// （_kickPending）なので、1 回の書き出しの間に何度積んでも signal は 1 回。
//
// 捨てた案:
//   - 音のスレッドから直に dispatch_source_merge_data: OR と lock-free な push で
//     済むのは _q が起きているときだけ。pump は次の WriteMix より前に読み切って
//     寝るので、毎回 _q を root queue へ積み直し、_dispatch_root_queue_poke_slow
//     から __workq_kernreturn(REQTHREADS) のシステムコールになる。暇な worker が
//     居なければ（IO が数秒止まって libdispatch が worker を畳んだあとの StartIO）
//     カーネルがその場でスレッドを作り、スタックを mach_vm_map する。vm_map の
//     ロックを他のスレッドが持っていれば音のスレッドがそこで待つ。
//     （前の版はこれを採っていて、「寝ていれば 1 回だけ」は重複を減らすだけで、
//     毎回 1 回の起床は残っていた。）
//   - 音のスレッドからタイマーの suspend/resume: 回数の数え違いが即クラッシュになる。
//   - 音のスレッド側で最小間隔やフレーム数の閾値を置いて束ねる: 束ねたぶんだけ
//     遅れる。遅れは受け手の谷の深さにそのまま乗る。
// 起こし役を挟むぶん、届くのはスレッドの起床 1 回ぶん遅れる（数十 µs）。
// 狙いの溜まり 1024 フレーム（21ms）から見れば誤差。
//
// **戻すときはここ。**実機で HAL の overload や音切れが出たら、繋がっている側を
// 2ms・leeway 0 のタイマーへ戻す（_kickReady を NO にすれば、retimePump が
// その周期を入れ、音のスレッドは signal を撃たない。セマフォかスレッドを
// 作れなかったときも同じ形に落ちる）。2ms の粒が受け手の谷の下限を決めていた経緯
// （ET_LINK_TARGET_FRAMES = 1024 は実機で詰めた値）は変えていない。
#define TX_WAIT_NS          (200ull * NSEC_PER_MSEC)
#define TX_WAIT_LEEWAY_NS   (100ull * NSEC_PER_MSEC)
// 起こし役が使えないときだけ使う、繋がっている側の周期（前の 2ms・leeway 0）。
#define TX_LIVE_NS          (2ull * NSEC_PER_MSEC)

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
    // いまタイマーに入れてある周期が「繋がっている側」か。
    // 同じ値の set_timer を毎回撃たないための札。
    // 繋がっている側ではタイマーを FOREVER に置いて止めてある。
    BOOL _timedLive;

    // 起こし役のスレッドから _q を起こす口。**cancel も release もしない。**
    // stop のあとも起こし役が merge しにくるかもしれないので、
    // gHandlerPtr（EffeTuneDriver.m）と同じく、解放して消える経路そのものを無くす。
    // _kickRT は同じものを ARC の外で読むための別名。
    dispatch_source_t _kick;
    __unsafe_unretained dispatch_source_t _kickRT;
    // 音のスレッドが signal し、起こし役が wait するセマフォ。**destroy しない。**
    // 両方とも init で作り、gLinkSender を出す前に揃える。
    // _kickReady が NO（作れなかった）なら音のスレッドは撃たず、
    // 繋がっている側は 2ms のタイマーで回る（上の「戻すときはここ」）。
    semaphore_t _kickSem;
    BOOL _kickReady;
    // true のあいだは音のスレッドから起こさない。起こしたあと pump が読み位置を
    // 見るまでと、送れずに書き込み可能を待っているあいだ。
    _Atomic bool _kickPending;
    // 繋がっているか（音のスレッドが読む。_fd は _q の持ち物なので別に持つ）。
    _Atomic bool _live;
    // 送れなかったとき、書き込み可能になるのを待つ通知。
    // 繋がった fd ごとに作り、fd を閉じるのはこの cancel handler だけ。
    dispatch_source_t _writable;
    BOOL _writableArmed;
}

// 音のスレッドの入口（ETLinkSenderPushInterleaved）が引く。
// 送り手はプロセスに 1 つで解放されないので、ARC の外の弱い参照で足りる。
static __unsafe_unretained ETLinkSender *gLinkSender;

+ (ETLinkSender *)shared {
    static ETLinkSender *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[ETLinkSender alloc] init]; gLinkSender = s; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _fd = -1;
        _q = dispatch_queue_create("ai.nemut.effetune.link.send", DISPATCH_QUEUE_SERIAL);
        _ring = calloc(ET_LINK_SEND_RING_SAMPLES, sizeof(float));
        // malloc 由来なので先頭は 16 バイト境界。ヘッダ 12 の直後の float 配列も 4 で揃う。
        _txBuf = calloc(1, ET_LINK_CHUNK_BYTES);
        _kick = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_OR, 0, 0, _q);
        __weak typeof(self) weak = self;
        dispatch_source_set_event_handler(_kick, ^{ [weak pump]; });
        dispatch_resume(_kick);
        _kickRT = _kick;
        _kickReady = [self startKickThread];
        if (!_kickReady) {
            os_log_error(ETLinkLog(), "ET 起こし役を作れない 繋がっている側は 2ms で回す");
        }
    }
    return self;
}

/// 起こし役のスレッド。音のスレッドの signal を待って _q を起こすだけ。
/// 送り手はプロセスに 1 つで解放されないので、arg は ARC の外で受ける。
static void *ETLinkKickThread(void *arg) {
    pthread_setname_np("ai.nemut.effetune.link.kick");
    __unsafe_unretained ETLinkSender *s = (__bridge ETLinkSender *)arg;
    semaphore_t sem = s->_kickSem;
    __unsafe_unretained dispatch_source_t kick = s->_kickRT;
    for (;;) {
        kern_return_t kr = semaphore_wait(sem);
        if (kr == KERN_SUCCESS) {
            dispatch_source_merge_data(kick, 1);
        } else if (kr != KERN_ABORTED) {
            // 起きないはず（セマフォは destroy しない）。黙って回り続けないよう、
            // 2ms ごとに起こす形へ落とす（前のタイマーと同じ粒）。
            static int logged = 0;
            if (logged++ < 5) os_log_error(ETLinkLog(), "ET 起こし役 semaphore_wait 失敗 kr=%d", kr);
            usleep(2000);
            dispatch_source_merge_data(kick, 1);
        }
    }
    return NULL;
}

/// 起こし役のセマフォとスレッドを作る。init からだけ呼ぶ（音のスレッドではない）。
- (BOOL)startKickThread {
    if (semaphore_create(mach_task_self(), &_kickSem, SYNC_POLICY_FIFO, 0) != KERN_SUCCESS) {
        _kickSem = MACH_PORT_NULL;
        return NO;
    }
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    // 音を積んだ瞬間に起きて merge するだけなので、待たされないよう上の段で回す。
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
    pthread_t th;
    int rc = pthread_create(&th, &attr, ETLinkKickThread, (__bridge void *)self);
    pthread_attr_destroy(&attr);
    // 作れなかったときのセマフォは捨てない（誰も signal しないので害が無く、
    // destroy しない決まりを崩さない）。
    return rc == 0;
}

- (BOOL)connected { return _fd >= 0; }

- (void)start {
    if (_running) return;
    _running = YES;
    _r = atomic_load(&_w);
    _txLen = _txOff = 0;
    _txSamples = 0;
    // 毎回 0 から数える。累計のままだと、今回何も送っていなくても
    // 「送信=188万」のように見えて、ログで判断を誤る。
    _sentFrames = 0;
    _pumpCount = 0;
    _sendCalls = 0;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
    // **まだ繋がっていないので遅い側から始める。**
    // DISPATCH_TIME_NOW から始めるので、**最初の 1 回は必ずすぐ撃つ**。
    // 繋がった時点で pump が下の retimePump を呼び、タイマーを止める
    // （以降は音を積んだ瞬間に起こす）。
    _timedLive = NO;
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, TX_WAIT_NS, TX_WAIT_LEEWAY_NS);
    __weak typeof(self) weak = self;
    dispatch_source_set_event_handler(_timer, ^{ [weak pump]; });
    dispatch_resume(_timer);
    os_log_error(ETLinkLog(), "ET sender 開始");
}

/// いまの接続の状態に合う周期をタイマーへ入れ直す。**同じなら何もしない。**
/// 繋がっているあいだはタイマーを止める（起こすのは pushInterleaved と WRITE）。
/// 起こし役を作れなかったときだけ、繋がっている側も 2ms で回す。
/// 呼ぶのは _q の上（pump の中）だけ。
- (void)retimePump {
    BOOL live = (_fd >= 0);
    if (live == _timedLive) return;
    dispatch_source_t t = _timer;
    if (!t) return;
    _timedLive = live;
    if (live && !_kickReady) {
        // 起こし役が居ない。音のスレッドは起こさないので、前の 2ms で回す。
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)TX_LIVE_NS),
                                  TX_LIVE_NS, 0);
    } else if (live) {
        dispatch_source_set_timer(t, DISPATCH_TIME_FOREVER, TX_WAIT_NS, 0);
    } else {
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)TX_WAIT_NS),
                                  TX_WAIT_NS, TX_WAIT_LEEWAY_NS);
    }
}

- (void)stop {
    // 音のスレッドがこれ以上起こさないように、まず落とす。
    atomic_store_explicit(&_live, false, memory_order_release);
    _running = NO;
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    dispatch_async(_q, ^{ [self dropConnection]; });
    os_log(ETLinkLog(), "sender 停止 sent=%llu", (unsigned long long)_sentFrames);
}

/// 接続を捨てて、200ms 間隔の再試行へ戻る。呼ぶのは _q の上だけ。
/// fd は _writable の cancel handler が閉じる（ここでは閉じない）。
/// 監視中の fd を先に閉じると未定義で、cancel handler は libdispatch が
/// 登録を外したあとに呼ばれる。_fd は先に -1 にするので connected はすぐ false になる。
- (void)dropConnection {
    atomic_store_explicit(&_live, false, memory_order_release);
    if (_writable) {
        dispatch_source_cancel(_writable);
        // 一度も resume していない（または suspend 中の）source は
        // cancel handler が呼ばれない。ここで起こして呼ばせる。
        if (!_writableArmed) dispatch_resume(_writable);
        _writable = nil;
        _writableArmed = NO;
    }
    _fd = -1;
    _txLen = _txOff = 0;
    _txSamples = 0;
    [self retimePump];
}

- (void)pushInterleaved:(const float *)samples frames:(uint32_t)frames channels:(uint32_t)channels {
    ETLinkSenderPushInterleaved(samples, frames, channels);
}

/// 音のスレッドの入口。objc_msgSend も ARC も libdispatch も通らない
/// （IR を見て 0 個を確かめること）。
/// 積んだあと、送り手が寝ていれば 1 回だけ起こし役へ signal する。
/// **順序が肝。**積む（_w の release）→ _kickPending の交換。pump は先に
/// _kickPending を false にしてから _w を読むので、ここが「すでに起こした」と
/// 見たなら、その pump は後から _w を読んでこの積みも見る。
/// 起こし役が数え残した signal は次の wait をすぐ返すだけで、pump が 1 回空振りする。
void ETLinkSenderPushInterleaved(const float *samples, uint32_t frames, uint32_t channels) {
    __unsafe_unretained ETLinkSender *s = gLinkSender;
    if (!s || !samples || frames == 0) return;
    uint64_t w = atomic_load_explicit(&s->_w, memory_order_relaxed);
    w = ETLinkRingPush(s->_ring, ET_LINK_SEND_RING_SAMPLES, w, samples, frames, channels);
    atomic_store_explicit(&s->_w, w, memory_order_release);
    if (s->_kickReady &&
        atomic_load_explicit(&s->_live, memory_order_relaxed) &&
        !atomic_exchange_explicit(&s->_kickPending, true, memory_order_acq_rel)) {
        semaphore_signal(s->_kickSem);
    }
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
    // 書き込み可能を待つ通知。ここでは作るだけで、送れなくなったとき
    // （armWritable）に初めて resume する。
    // 以降 fd を閉じるのはこの cancel handler だけ（fd は値で捕まえる）。
    _writable = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)fd, 0, _q);
    __weak typeof(self) weak = self;
    dispatch_source_set_event_handler(_writable, ^{ [weak writableFired]; });
    dispatch_source_set_cancel_handler(_writable, ^{ close(fd); });
    _writableArmed = NO;
    _r = atomic_load(&_w);   // 繋がった時点から送る
    // 前の接続で送り残したチャンクの途中から流すと、新しいストリームの先頭が
    // ヘッダにならない。持ち越しはここで捨てる。
    _txLen = _txOff = 0;
    _txSamples = 0;
    os_log_error(ETLinkLog(), "ET connect 成功 port=%d", ET_LINK_PORT);
}

/// 送れなくなったので、書き込み可能になるまで待つ。
/// 相手（本体）が止まっていると send は EAGAIN しか返さない。前はそのあいだも
/// 2ms ごとに起きて同じ EAGAIN を引いていた。
/// _kickPending を立てておくのは、待っているあいだ音のスレッドに起こさせないため
/// （起こされても送れない）。pump の頭で下ろされる。
- (void)armWritable {
    atomic_store_explicit(&_kickPending, true, memory_order_release);
    if (_writable && !_writableArmed) {
        dispatch_resume(_writable);
        _writableArmed = YES;
    }
}

/// 書き込み可能になった。レベルトリガなので、止めないと鳴り続ける。
- (void)writableFired {
    if (_writableArmed) {
        dispatch_suspend(_writable);
        _writableArmed = NO;
    }
    [self pump];
}

/// 送信中のチャンクの残りを吐き出す。全部出せたら YES。
/// 端数で止まったら _txOff にバイト位置を残して NO を返す。
/// send が返すのはバイト数で、float の途中で止まりうる。ここをサンプル単位で
/// 数えると端数バイトは送信済みなのに読み位置が戻り、同じサンプルの先頭を
/// 送り直す＝受け側が 1〜3 バイトずれる。だからバイトで数える。
- (BOOL)flushPending {
    while (_txOff < _txLen) {
        _sendCalls++;
        ssize_t sent = send(_fd, _txBuf + _txOff, _txLen - _txOff, 0);
        if (sent > 0) { _txOff += (size_t)sent; continue; }
        if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            [self armWritable];
            return NO;
        }
        os_log_error(ETLinkLog(), "send 失敗 errno=%d", errno);
        [self dropConnection];
        return NO;
    }
    // 送り切ったチャンクだけ数える。途中で止まったぶんは次の pump で数える。
    if (_txSamples) { _sentFrames += _txSamples / 2; _txSamples = 0; }
    return YES;
}

- (void)pump {
    _pumpCount++;
    // **_w を読む前に下ろす。**音のスレッドは積んでから交換するので、
    // ここより後の積みは起こし直し、前の積みは下の _w の読みで見える。
    atomic_exchange_explicit(&_kickPending, false, memory_order_acq_rel);
    if (!_running) return;
    if (_fd < 0) {
        // 繋がっていないあいだはタイマー（200ms）だけがここへ来る。
        [self ensureConnected];
        if (_fd < 0) return;
        atomic_store_explicit(&_kickPending, false, memory_order_release);
        atomic_store_explicit(&_live, true, memory_order_release);
        [self retimePump];   // 繋がった。タイマーを止める
    }

    if (![self flushPending]) return;   // 前回の残りが先

    uint64_t w = atomic_load_explicit(&_w, memory_order_acquire);
    uint64_t r = _r;
    if (w <= r) return;

    // 1 チャンクずつ _txBuf に組んで吐く。偶数サンプルで切ること、書き手が
    // 1 周先へ行っていたら古いぶんを捨てることは ETLinkEncodeNext の中。
    // w はこの回のあいだ同じ値を渡し続ける（読み切ったら 0 が返って抜ける）。
    uint32_t n;
    while ((n = ETLinkEncodeNext(_txBuf, &_txLen, _ring, ET_LINK_SEND_RING_SAMPLES, w, &r)) != 0) {
        _txOff = 0;
        _txSamples = n;

        // リングから _txBuf へ写した時点で読み位置を進める。送信が途中で止まっても
        // 残りは _txBuf が持っているので、リングを読み直す必要は無い。
        _r = r;

        if (![self flushPending]) return;   // 続きは次の pump
    }
    _r = r;
}

@end

// ---- 受け手 ----

// 受け手は周期で回さず、ソケットの通知（DISPATCH_SOURCE_TYPE_READ）で動く。
//
// 前は 1 本のタイマーを相手の有無で切り替えていた。相手が居ないあいだは
// 20ms（accept 1 回だけ。backlog はカーネルが受けるので、こちらが遅れても相手の
// connect は即座に成功する）、居るあいだは 1ms・leeway 1ms（e6eee22）。
// それでも相手が居るあいだは recv が空振りでも 1000 回/秒起きていた。
// いまは待ち受けの fd と相手の fd にそれぞれ READ の通知を置き、届いたときだけ動く。
//
// **溜まりは深くならない。**周期で読んでいたときは、届いてから読むまでに
// 最大 1〜2ms 待っていた。届いた瞬間に読めば、その待ちが消えるだけで、
// 読み位置の置き直し（書き位置から狙いのぶん下げる）は変わらない。
// 谷が深くなる向きの変更ではないので、Ran dry が増えるはずがない。
// **もし増えたらここを疑う。**見る所は Diagnostics の Ran dry と Extension link
// （1024 のままか 2048 へ逃げたか）、それに readEvents / recvCalls。
//
// 相手は 1 つだけ。相手が居るあいだは待ち受けの通知を止め（suspend）、
// 次の接続は backlog で待たせる。止めないと、待たされている接続のぶんだけ
// レベルトリガの READ が鳴り続ける。
//
// **待ち受けが死んでも READ は鳴らない。**裏で止まっていたあいだに iOS がソケットを
// defunct にすると、待ち受けの TCP は閉じられ、来た SYN は RST で返される
// （拡張の connect は errno=61 を繰り返す）。XNU の filt_soread は待ち受けの
// ソケットでは so_comp が空かどうかしか見ず、EOF を通知しない。非ブロッキングの
// accept も so_comp が空なら so_error を見る前に EWOULDBLOCK を返す。
// だから死んだかどうかは通知ではなく自分で見に行く（checkListener）。
// defunct は so_error に EBADF を残すので、getsockopt(SO_ERROR) で分かる。
// 見に行くのは、相手が切れたとき（相手と待ち受けは同時に defunct になる）と、
// 相手が居ないあいだの RX_PROBE_NS ごと。止められていたあいだに期限が来ていれば、
// 戻った直後に 1 回撃つ。
#define RX_PROBE_NS         (5ull * NSEC_PER_SEC)
#define RX_PROBE_LEEWAY_NS  (1ull * NSEC_PER_SEC)
// 作ってからこの時間のうちに捨てた待ち受けは、作り直しの間を倍にしていく（30 秒まで）。
#define RX_RELISTEN_QUICK_NS (10ull * NSEC_PER_SEC)

@implementation ETLinkReceiver {
    int _listenFd;
    int _peerFd;
    dispatch_queue_t _q;
    // 待ち受けの fd と相手の fd の READ 通知。どちらも _q の上でだけ触る
    // （start が resume する前を除く）。fd を閉じるのは各 source の cancel handler
    // だけで、-1 にするのは dropPeer / stop / abandonListener。
    dispatch_source_t _acceptSrc;
    BOOL _acceptPaused;
    // accept が EAGAIN で空振りした回数（受けたら 0 に戻す）と、待ち受けを
    // 捨てたあと作り直すか。どちらも _q の上でだけ触る。わけは acceptPeer。
    uint32_t _acceptMisses;
    BOOL _relisten;
    // 相手が居ないあいだ、待ち受けが生きているかを見に行くタイマー（checkListener）。
    // 相手が居るあいだは FOREVER に置く。待ち受けと一緒に作り、一緒に捨てる。
    dispatch_source_t _probeSrc;
    // 待ち受けを作った時刻（CLOCK_MONOTONIC_RAW の ns）。主スレッドの start が書き、
    // _q の listenerClosed が読む（その待ち受けの resume より前に書くので順序は付いている）。
    uint64_t _listenBuiltNs;
    // 作り直しの前に置く秒数。すぐ捨てられる待ち受けが続くと倍にしていく。_q の持ち物。
    uint32_t _relistenDelay;
    dispatch_source_t _peerSrc;
    float *_ring;
    _Atomic uint64_t _w;
    uint64_t _r;
    // 受信したバイトをそのまま溜める。float に切り出すのは境界が揃ってから。
    uint8_t *_rxBuf;
    size_t _rxLen;
    uint64_t _badSamples;
    // 今の相手を受けた時点の _receivedFrames。枯れの判定はこの相手から
    // 受け取った分で見る（累計で見ると 2 本目以降の立ち上がりを枯れと数える）。
    uint64_t _receivedAtAccept;
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
        _ring = calloc(ET_LINK_RECV_RING_SAMPLES, sizeof(float));
        _rxBuf = calloc(1, ET_LINK_RX_BUF_BYTES);
    }
    return self;
}

- (BOOL)listening { return _listenFd >= 0; }
- (BOOL)hasPeer   { return _peerFd >= 0; }

/// 溜まりの方針が持つ状態（狙い 1024 / 2048、枯れ・切り詰めの数、溜め直し）。
/// 数と閾値の意味は ETLinkCodec.h。受け手は 1 つしか無いのでプロセスに 1 組。
/// 書くのは音のスレッド（readInterleaved）と繋ぎ直し（resetLinkState）だけ。
static ETLinkJitter gJitter = ET_LINK_JITTER_INIT;

+ (uint32_t)targetFrames { return atomic_load_explicit(&gJitter.target, memory_order_relaxed); }
+ (uint32_t)starveCount  { return atomic_load_explicit(&gJitter.starveCount, memory_order_relaxed); }
+ (uint64_t)starveFrames { return atomic_load_explicit(&gJitter.starveFrames, memory_order_relaxed); }
+ (uint32_t)trimCount    { return atomic_load_explicit(&gJitter.trimCount, memory_order_relaxed); }
+ (uint64_t)trimFrames   { return atomic_load_explicit(&gJitter.trimFrames, memory_order_relaxed); }

/// 繋ぎ直したときに、浅い側から始め直す。
+ (void)resetLinkState {
    ETLinkJitterReset(&gJitter);
}

- (uint32_t)bufferedFrames {
    uint64_t w = atomic_load_explicit(&_w, memory_order_acquire);
    uint64_t r = _r;
    if (w <= r) return 0;
    uint64_t samples = w - r;
    if (samples > ET_LINK_RECV_RING_SAMPLES) samples = ET_LINK_RECV_RING_SAMPLES;
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
    _listenBuiltNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    _rxLen = 0;
    os_log_error(ETLinkLog(), "ET receiver 待ち受け開始 port=%d", ET_LINK_PORT);

    _readEvents = 0;
    _recvCalls = 0;

    // 待ち受けの fd の READ は「accept できる接続がある」の意味。
    // cancel handler は fd を値で捕まえる（ivar を読むと、閉じる fd が
    // 後から入れ替わった値になりうる）。
    // 作り直しを cancel handler から始めるのは、古い fd を閉じた後でないと
    // 同じ口に bind できない（SO_REUSEADDR でも listen 中の口は EADDRINUSE）から。
    int lfd = fd;
    _acceptSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)lfd, 0, _q);
    __weak typeof(self) weak = self;
    dispatch_source_set_event_handler(_acceptSrc, ^{ [weak acceptPeer]; });
    dispatch_source_set_cancel_handler(_acceptSrc, ^{ close(lfd); [weak listenerClosed]; });
    _acceptPaused = NO;
    _acceptMisses = 0;
    dispatch_resume(_acceptSrc);

    // 待ち受けが死んでいないかを見に行く（わけは上の「待ち受けが死んでも」）。
    // suspend はしない（止めるときは FOREVER に置く）ので、cancel だけで捨てられる。
    _probeSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
    dispatch_source_set_timer(_probeSrc, dispatch_time(DISPATCH_TIME_NOW, (int64_t)RX_PROBE_NS),
                              RX_PROBE_NS, RX_PROBE_LEEWAY_NS);
    dispatch_source_set_event_handler(_probeSrc, ^{ [weak checkListener]; });
    dispatch_resume(_probeSrc);
    return YES;
}

/// 待ち受けと相手を畳む。非同期なのは前のまま。
/// 使っていない（AudioIO は keepListening: true でしか呼ばない）。
/// stop の直後に start すると、まだ _listenFd が残っていて start が何もしない
/// 競合が前からある。使い始めるときに直すこと。
- (void)stop {
    dispatch_async(_q, ^{
        // 止まっている待ち受けは cancel handler が呼ばれないので、
        // dropPeer が先に resume してから cancel する。
        [self dropPeer];
        self->_relisten = NO;
        if (self->_probeSrc) { dispatch_source_cancel(self->_probeSrc); self->_probeSrc = nil; }
        if (self->_acceptSrc) { dispatch_source_cancel(self->_acceptSrc); self->_acceptSrc = nil; }
        self->_listenFd = -1;
        self->_rxLen = 0;
    });
}

/// チャンク本体をリングへ写す。
/// 非有限値は ETLinkRingWrite が 0 に置き換えて数を返す（NaN を 1 つ通すと
/// IIR の状態が戻らなくなるので落とす。黙って埋めると原因が見えないので数える）。
- (void)writeSamples:(const uint8_t *)bytes count:(uint32_t)count {
    uint64_t w = atomic_load_explicit(&_w, memory_order_relaxed);
    uint64_t badBefore = _badSamples;
    _badSamples += ETLinkRingWrite(_ring, ET_LINK_RECV_RING_SAMPLES, w, bytes, count);
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

/// ETLinkConsume が取り出したチャンクを受ける。ctx は ETLinkReceiver。
static void ETLinkReceiverTakeChunk(void *ctx, const uint8_t *payload, uint32_t count) {
    [(__bridge ETLinkReceiver *)ctx writeSamples:payload count:count];
}

/// 溜めたバイト列から取り出せるチャンクを全部取り出し、残りを先頭へ寄せる。
/// ヘッダが揃わない端数・本体が届いていないチャンクはそのまま次の recv へ持ち越す。
/// ヘッダの検算と 1 バイトずつの再同期は ETLinkConsume の中。
- (void)consume {
    size_t skipped = ETLinkConsume(_rxBuf, &_rxLen, ETLinkReceiverTakeChunk, (__bridge void *)self);
    if (skipped > 0) {
        static int logged = 0;
        if (logged++ < 20) {
            os_log_error(ETLinkLog(), "ET 同期ずれ %zu バイト読み飛ばし bad=%llu",
                         skipped, (unsigned long long)_badSamples);
        }
    }
}

/// 待ち受けに接続が来た。_q の上で呼ばれる。
/// 相手は 1 つだけ。受けたら待ち受けの通知を止め、次の接続は backlog に待たせる
/// （止めないと、待たされている接続のぶんだけレベルトリガの READ が鳴り続ける）。
/// 再開は dropPeer。
- (void)acceptPeer {
    if (_listenFd < 0 || _peerFd >= 0) return;
    int c = accept(_listenFd, NULL, NULL);
    // **失敗を黙って捨てると空回りしうる。**周期で回していたときは、失敗しても
    // 次の accept は 20ms 後だった。レベルトリガの READ では、fd が読める
    // ままなら handler がすぐまた呼ばれ、_q が CPU を 1 本使い切る。
    //
    // fd や記憶域が尽きた（EMFILE / ENFILE / ENOBUFS / ENOMEM）ときは作り直さない。
    // 作り直しても足りないものは増えない（閉じた 1 本を socket がすぐ使う）。
    // XNU の accept は so_comp から外してから fd を取り、取れなければその接続を
    // 閉じて捨てる（rdar://8554930）ので、READ は鳴り続けないはずだが、
    // 念のため待ち受けの通知を 1 秒止める（pauseAcceptBriefly）。
    //
    // それ以外（ECONNABORTED や EINVAL など）は待ち受けを捨てて作り直す。
    // 作り直しの間は listenerClosed が延ばす。
    // **defunct の待ち受けはここへ来ない。**READ が鳴らず、accept も EWOULDBLOCK を
    // 返すだけだから（上の「待ち受けが死んでも」）。そちらは checkListener が拾う。
    //
    // EAGAIN だけは様子を見る。読めると言われて何も無いのは 1 回なら空振りで
    // 済むが、同じ理由で鳴り続けることもありうるので、受けられないまま
    // 空振りが 64 回たまったら同じく作り直す（受けたら数え直す）。
    if (c < 0) {
        int e = errno;
        if ((e == EAGAIN || e == EWOULDBLOCK || e == EINTR) && ++_acceptMisses < 64) return;
        if (e == EMFILE || e == ENFILE || e == ENOBUFS || e == ENOMEM) {
            static int logged = 0;
            if (logged++ < 20) os_log_error(ETLinkLog(), "ET accept 失敗 errno=%d 1 秒止める", e);
            [self pauseAcceptBriefly];
            return;
        }
        [self abandonListener:e];
        return;
    }
    _acceptMisses = 0;
    // 相手が居るあいだは待ち受けを見に行かない（見るのは切れたとき）。
    if (_probeSrc) dispatch_source_set_timer(_probeSrc, DISPATCH_TIME_FOREVER, RX_PROBE_NS, 0);
    int fl = fcntl(c, F_GETFL, 0);
    fcntl(c, F_SETFL, fl | O_NONBLOCK);
    _peerFd = c;
    _rxLen = 0;     // 前の相手の書きかけを新しいストリームに混ぜない
    _receivedAtAccept = _receivedFrames;
    // **浅い側から始め直す。**前の相手で枯れて深くしたぶんを
    // 引き継ぐと、一度の混み合いで遅れが増えたまま固定される。
    [ETLinkReceiver resetLinkState];
    os_log_error(ETLinkLog(), "ET 接続を受けた");

    // 相手の fd の READ は「読めるものがある」または「切れた」の意味。
    // 受けた時点で届いていたぶんも、resume すれば鳴る（レベルトリガ）。
    _peerSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)c, 0, _q);
    __weak typeof(self) weak = self;
    dispatch_source_set_event_handler(_peerSrc, ^{ [weak readPeer]; });
    dispatch_source_set_cancel_handler(_peerSrc, ^{ close(c); });
    dispatch_resume(_peerSrc);

    dispatch_suspend(_acceptSrc);
    _acceptPaused = YES;
}

/// fd が尽きたときに、待ち受けの通知を 1 秒止める。_q の上で呼ぶ。
/// 止めるのに使うのは相手が居るときと同じ _acceptPaused なので、その間に
/// stop が来ても dropPeer が resume してから cancel する（止めたままの source は
/// cancel handler が呼ばれず、解放するとクラッシュする）。abandonListener も同じ。
- (void)pauseAcceptBriefly {
    if (_acceptPaused || !_acceptSrc) return;
    dispatch_suspend(_acceptSrc);
    _acceptPaused = YES;
    dispatch_source_t src = _acceptSrc;
    __weak typeof(self) weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC), _q, ^{
        ETLinkReceiver *s = weak;
        if (!s) return;
        // 止めた本人のまま、まだ止まっているときだけ戻す（作り直し・stop の後は触らない）。
        if (s->_acceptSrc == src && s->_acceptPaused && s->_peerFd < 0) {
            dispatch_resume(src);
            s->_acceptPaused = NO;
        }
    });
}

/// 待ち受けが生きているかを見に行く。_q の上で呼ぶ。相手が居るあいだは見ない
/// （待ち受けは止めてあり、相手と待ち受けは同時に defunct になるので、相手が
/// 切れたとき dropPeer から見れば足りる）。
/// defunct は so_error に EBADF を残す。SO_ERROR は読むと 0 に戻るが、
/// 0 でなければどのみち捨てるので構わない。getsockopt 自体が失敗しても捨てる。
/// accept を撃って確かめる形は使えない（EWOULDBLOCK が先に返る）。
- (void)checkListener {
    if (_listenFd < 0 || _peerFd >= 0) return;
    int e = 0;
    socklen_t l = sizeof(e);
    if (getsockopt(_listenFd, SOL_SOCKET, SO_ERROR, &e, &l) != 0) e = errno ? errno : EBADF;
    if (e != 0) [self abandonListener:e];
}

/// 使えなくなった待ち受けを捨てる。_q の上で呼ぶ。
/// 相手が居ないときにしか来ない（acceptPeer は相手が居れば accept しない。
/// checkListener も相手が居れば見ない）。止めてあるのは pauseAcceptBriefly の
/// 1 秒だけで、そのときは resume してから cancel する。作り直しは cancel handler が
/// fd を閉じた後の listenerClosed から。
- (void)abandonListener:(int)err {
    static int logged = 0;
    if (logged++ < 20) {
        os_log_error(ETLinkLog(), "ET 待ち受けが使えない errno=%d 作り直す", err);
    }
    _relisten = YES;
    if (_probeSrc) { dispatch_source_cancel(_probeSrc); _probeSrc = nil; }
    if (_acceptSrc) {
        if (_acceptPaused) { dispatch_resume(_acceptSrc); _acceptPaused = NO; }
        dispatch_source_cancel(_acceptSrc);
        _acceptSrc = nil;
    }
    _listenFd = -1;
    _acceptMisses = 0;
}

/// 待ち受けの fd を閉じた。_q の上で（cancel handler から）呼ばれる。
/// stop で畳んだときは何もしない。
///
/// **間は作り直しをまたいで延ばす。**relistenAfter の倍々は start が失敗したときしか
/// 効かず、作るたびに成功してすぐ捨てられる形（同じ理由で毎回 abandon される）では
/// 主スレッドと _q を往復し続ける。作ってから RX_RELISTEN_QUICK_NS のうちに
/// 捨てたなら前の間を倍に（1, 2, 4 … 30 秒）、長く持ったなら待たずに作り直す。
- (void)listenerClosed {
    if (!_relisten) return;
    _relisten = NO;
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    if (now - _listenBuiltNs < RX_RELISTEN_QUICK_NS) {
        _relistenDelay = _relistenDelay == 0 ? 1 : (_relistenDelay * 2 > 30 ? 30 : _relistenDelay * 2);
    } else {
        _relistenDelay = 0;
    }
    uint32_t delay = _relistenDelay;
    uint32_t retry = delay == 0 ? 1 : (delay * 2 > 30 ? 30 : delay * 2);
    // start は AudioIO と同じ主スレッドで呼ぶ（_listenFd を見て二重に作らないため）。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ [self relistenAfter:retry]; });
}

/// 待ち受けを作り直す。主スレッドで呼ぶ。
/// AudioIO が先に作り直していれば start は何もしない。作れなければ間を倍に
/// 延ばして（30 秒まで）また試す。AudioIO.start() も !listening を見て作るが、
/// 音が回り続けているあいだは呼ばれないので、それを待たない。
- (void)relistenAfter:(uint32_t)retrySeconds {
    if ([self start]) return;
    uint32_t next = retrySeconds * 2 > 30 ? 30 : retrySeconds * 2;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)retrySeconds * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ [self relistenAfter:next]; });
}

/// 相手の fd が読める（または切れた）。_q の上で呼ばれる。
/// 前の pump の相手側の半分。
- (void)readPeer {
    _readEvents++;
    // 1 回の通知で読むのは 8 回まで。残りがあればレベルトリガでまた来る。
    for (int pass = 0; pass < 8; pass++) {
        if (_peerFd < 0) return;
        // consume の後は必ず 1 チャンク未満しか残らないので届かないはず。
        // 前は黙って return していたが、レベルトリガでは同じ通知が鳴り続けて
        // 空回りになる（もともと二度と進まない詰まりだった）。切って繋ぎ直させる。
        if (_rxLen >= ET_LINK_RX_BUF_BYTES) {
            os_log_error(ETLinkLog(), "ET 受信バッファが溢れた 切断する");
            [self dropPeer];
            return;
        }
        ssize_t n = recv(_peerFd, _rxBuf + _rxLen, ET_LINK_RX_BUF_BYTES - _rxLen, 0);
        _recvCalls++;
        if (n == 0) {
            os_log(ETLinkLog(), "相手が切断した");
            [self dropPeer];
            return;
        }
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return;
            os_log_error(ETLinkLog(), "recv 失敗 errno=%d", errno);
            [self dropPeer];
            return;
        }
        // n は 4 の倍数とは限らない。端数は _rxBuf に残したまま次の recv と繋ぐ。
        _rxLen += (size_t)n;
        [self consume];
    }
}

/// 相手を手放して、次の接続を受けられる状態へ戻す。_q の上で呼ぶ。
/// **ここでは fd を close しない。**fd は _peerSrc の cancel handler が閉じる。
/// 監視中の fd を先に閉じるのは未定義で、cancel handler は libdispatch が
/// 登録を外したあとに 1 度だけ呼ばれる。hasPeer は先に false になる
/// （音のスレッドは _peerFd の int を読むだけ）。
- (void)dropPeer {
    if (_peerSrc) { dispatch_source_cancel(_peerSrc); _peerSrc = nil; }
    _peerFd = -1;
    _rxLen = 0;
    // suspend 中の source は cancel handler が呼ばれない。待ち受けの再開は
    // 次の接続を受けるためだけでなく、stop で畳むための resume でもある。
    if (_acceptPaused && _acceptSrc) {
        dispatch_resume(_acceptSrc);
        _acceptPaused = NO;
    }
    // 相手が切れたのは、iOS が相手と待ち受けを一緒に defunct にしたせいかもしれない。
    // その場で見て、生きていれば相手が居ないあいだの見回りへ戻す。
    [self checkListener];
    if (_probeSrc) {
        dispatch_source_set_timer(_probeSrc, dispatch_time(DISPATCH_TIME_NOW, (int64_t)RX_PROBE_NS),
                                  RX_PROBE_NS, RX_PROBE_LEEWAY_NS);
    }
}

- (uint32_t)readInterleaved:(float *)out frames:(uint32_t)frames {
    uint64_t w = atomic_load_explicit(&_w, memory_order_acquire);
    uint64_t r = _r;
    // 貼り直し・溜まりすぎの切り詰め・溜め直し・枯れの数え方・2048 への逃げは
    // ETLinkJitterRead の中（説明もそちら）。ここは状態を渡してログを書くだけ。
    //
    // **鳴る前の空回りは枯れではない。**相手が居るかと受信済みのフレーム数を渡すのは
    // そのため（相手が繋がる前も音のコールバックは回っていて、毎枠足りない）。
    // **渡すのは今の相手から受けた分。**累計を渡すと、起動から 1 秒鳴った後は
    // 繋ぎ直すたびに立ち上がりの溜め込みを枯れと数え、3 回で 2048 へ逃げていた。
    ETLinkStarve starve;
    // 2 つは _q で書かれ、ここは音のスレッド。順序の保証が無いので、
    // 受けた直後に古い累計が見えても桁あふれで「鳴っている」にしない。
    uint64_t total = _receivedFrames, base = _receivedAtAccept;
    uint64_t received = total > base ? total - base : 0;
    uint32_t got = ETLinkJitterRead(&gJitter, _ring, ET_LINK_RECV_RING_SAMPLES, w, &r,
                                    out, frames, _peerFd >= 0, received, &starve);
    if (starve.counted) {
        // **最初の何回かだけ書き出す。**毎枠出すと洪水になって、
        // 肝心の間隔が読めなくなる。頻度は Diagnostics の数で見る。
        static int logged = 0;
        if (logged++ < 40) {
            os_log_error(ETLinkLog(),
                         "ET 枯れ 埋め=%u/%u 溜まり=%llu 狙い=%u 受信=%llu 連=%u",
                         starve.filledFrames, starve.wantFrames,
                         (unsigned long long)starve.bufferedFrames,
                         starve.target,
                         (unsigned long long)received,
                         starve.runBefore + 1);
        }
    }
    _r = r;
    return got;
}

@end
