//  LocalLink.h
//  拡張 → プレイヤーアプリ へ PCM を運ぶローカル接続。
//
//  なぜこの形か（いずれも実機のサンドボックスログで確定）:
//    - App Group のファイル: deny file-write-data
//    - POSIX 共有メモリ:     deny ipc-posix-shm-read-data / ipc-posix-shm-write-create
//    - 待ち受け:             deny network-bind local:*:0
//  つまり拡張は「作る・待つ」が全部禁じられている。
//  一方、外へ繋ぐのは Media Device Extension の本来の用途（ネットワーク機器へ音を送る）
//  なので許されているはず。そこで待ち受けはプレイヤー側が持ち、拡張は繋ぎに行く。
//
//  形式: float32 インターリーブ 2ch 48kHz を、チャンクごとに 12 バイトのヘッダ
//  （マジック 8 + サンプル数 4）を付けて TCP で流す。中身はリトルエンディアンのまま。
//  ヘッダ無しの生 float を流していたが、TCP は 4 バイト境界では切れないので、
//  recv/send が返した端数バイトを捨てるか送り直すと以後の float が 2 サンプルに
//  またがって組み直され、NaN や 1e38 になる。しかも誰も気付けない。
//  端数はバイト単位で持ち越し、ヘッダで毎チャンク検算する。送受ともこのヘッダの実装。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#define ET_LINK_PORT 47101
#define ET_LINK_HOST "127.0.0.1"

/// 送り手（拡張側）。接続は自動で張り直す。
@interface ETLinkSender : NSObject
@property (class, readonly) ETLinkSender *shared;
@property (nonatomic, readonly) BOOL connected;
@property (nonatomic, readonly) uint64_t sentFrames;
- (void)start;
- (void)stop;
/// リアルタイムスレッドから呼ぶ。内部のリングに積むだけで、送信は別スレッド。
- (void)pushInterleaved:(const float *)samples frames:(uint32_t)frames channels:(uint32_t)channels;
@end

/// 受け手（プレイヤー側）。
@interface ETLinkReceiver : NSObject
@property (class, readonly) ETLinkReceiver *shared;
@property (nonatomic, readonly) BOOL listening;
@property (nonatomic, readonly) BOOL hasPeer;
@property (nonatomic, readonly) uint64_t receivedFrames;
/// まだ読み出していないフレーム数。そのまま遅延になる。
@property (nonatomic, readonly) uint32_t bufferedFrames;

/// 再同期のときに置く、書き位置からの遅れ（フレーム）。
/// 設計上の定数なので、遅れの表示にはこちらを使う。
/// bufferedFrames はその瞬間の溜まりで、払うたびに動く。
@property (class, nonatomic, readonly) uint32_t targetFrames;
- (BOOL)start;
- (void)stop;
/// 受信済みのサンプルを取り出す。足りない分は無音で埋める。
- (uint32_t)readInterleaved:(float *)out frames:(uint32_t)frames;
@end

NS_ASSUME_NONNULL_END
