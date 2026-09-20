//  EffeTuneDriver.h
//  Media Device Extension が publish する AudioServerPlugIn。
//  ここへシステム音声のサンプルが流れてくる。
//
//  iOS 27 でも API は macOS と同じ C の AudioServerPlugInDriverInterface で、
//  AudioServerDriver.framework が全メソッドの既定実装を持っている（iOS 27 バイナリで確認）:
//      ASD_CreateDriverInterface / ASD_DestroyDriverInterface
//      ASD_Initialize / ASD_CreateDevice / ASD_DestroyDevice
//      ASD_HasProperty / ASD_GetPropertyData / ASD_SetPropertyData
//      ASD_StartIO / ASD_StopIO / ASD_AddDeviceClient
//      ASD_WillDoIOOperation / ASD_BeginIOOperation / ASD_DoIOOperation / ASD_EndIOOperation
//      ASD_GetZeroTimeStamp
//      ASD_AddStreamRealTimeOperations / ASD_RemoveStreamRealTimeOperations
//      ASD_AddAudioDeviceRealTimeOperations / ASD_RemoveAudioDeviceRealTimeOperations
//      ASD_SetRealtimeOperationTableSize
//
//  登録は CoreAudio の以下で行う。**引数は最初こちらで逆アセンブルして確定したが、
//  いまは iOS 27 の公開 API として Apple が文書に載せている**（Core Audio）。
//      void AudioServerPlugInRegisterMediaDeviceExtension(
//              AudioServerPlugInDriverInterface **iface,
//              void (^invalidationHandler)(void));
//      // 実体は AudioServerPlugInRegisterDriver(Driver_Type=2, iface, block) への tail call
//      // Driver_Type: 1 = Remote, 2 = MediaDeviceExtension
//
//  出力デバイスは 1 個、transport は RemoteStreaming、UID は MediaOutputDevice.id と
//  同じ、という制約もこちらで測ったものが、そのまま Apple の文書に書かれている。
//
//  **公開仕様から外している所が 2 つある。どちらも承知の上。**
//   1. 本体の entitlement を空配列にしている（EffeTuneLive.entitlements の頭に理由）。
//      配信の検査はキーの存在を求め、実行時は中身が空でないときだけ '!pla' で
//      AVAudioSession を拒む。2 本に分けずに 1 本で成立させるための形。
//      Apple は「container app の唯一の目的は拡張の配送」と書いているので、
//      **そこからは意図的に外れている。**
//   2. publish を activateDevice の中で先に撃っている。Apple の掲載例は
//      startRealtimeSampleDelivery の中。ただし Apple 自身が
//      「activate 後すみやかに機器が現れないと deactivate されて Unable to Connect
//      になる」と書いており、こちらの順はその要求に合わせたもの。
//  どちらも iOS の版が上がったときに真っ先に見る所。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// システム音声が届いたときに呼ばれる。リアルタイムスレッドなので確保も待ちもしないこと。
/// ストリームのフォーマットはインターリーブの float32 なので、
/// data[0] に L,R,L,R... が frames*channels 個並んでいる（面は 1 つだけ）。
/// - frames: フレーム数（チャンネルあたり）
/// - channels: チャンネル数
typedef void (^EffeTuneSampleHandler)(const float *_Nonnull *_Nonnull data,
                                      uint32_t channels,
                                      uint32_t frames,
                                      double hostTime);

@interface EffeTuneDriver : NSObject

@property (class, readonly) EffeTuneDriver *shared;

@property (nonatomic) float volume;
@property (nonatomic) BOOL muted;

/// AudioServerPlugIn を作って CoreAudio に登録する。
/// activateDevice 直後に呼ぶこと。遅れるとシステムに切られる。
/// deviceUID は MediaOutputDevice.id と一致させること（ヘッダの要求）。
- (OSStatus)publishWithDeviceUID:(NSString *)deviceUID;
- (void)unpublish;

/// サンプルの受け取りを開始／停止する。
- (void)startCaptureWithHandler:(EffeTuneSampleHandler)handler;
- (void)stopCapture;

/// 直近に届いたサンプルの情報（デバッグ用）。
@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) uint32_t channelCount;
@property (nonatomic, readonly) uint64_t framesDelivered;

@end

NS_ASSUME_NONNULL_END
