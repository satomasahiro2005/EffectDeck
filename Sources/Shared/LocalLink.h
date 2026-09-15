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
//  形式: ヘッダ無しの生 float32 インターリーブ 2ch 48kHz を TCP で流すだけ。

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
- (BOOL)start;
- (void)stop;
/// 受信済みのサンプルを取り出す。足りない分は無音で埋める。
- (uint32_t)readInterleaved:(float *)out frames:(uint32_t)frames;
@end

NS_ASSUME_NONNULL_END
