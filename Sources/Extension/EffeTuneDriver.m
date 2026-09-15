//  EffeTuneDriver.m
//  Media Device Extension が publish する AudioServerPlugIn。
//  システム音声はここの DoIOOperation(kAudioServerPlugInIOOperationWriteMix) に届く。
//
//  API は Xcode 27 の iPhoneOS SDK の
//    CoreAudio.framework/Headers/AudioServerPlugIn.h
//  をそのまま使っている。推測は入っていない。
//
//  ヘッダの制約（1170-1176 行）:
//    - 提示できるのは単一の出力デバイスのみ
//    - transport type は kAudioDeviceTransportTypeRemoteScreen か RemoteStreaming
//      違うと登録が kAudioHardwareIllegalOperationError で失敗する
//    - デバイスの UID は MediaOutputDevice.id と一致していること
//
//  IO の段階（AudioServerPlugIn.h 343-352 行）:
//    'thrd' Thread / 'cycl' Cycle / 'read' ReadInput / 'cinp' ConvertInput /
//    'pinp' ProcessInput / 'pout' ProcessOutput / 'mixo' MixOutput /
//    'pmix' ProcessMix / 'cmix' ConvertMix / 'rite' WriteMix
//  各クライアントの音は MixOutput でミックスされ、**WriteMix で書き出される**。
//  そこが EffeTune の挿入点になる。

#import "EffeTuneDriver.h"
#import <CoreAudio/AudioServerPlugIn.h>
#import <os/log.h>
#import <pthread.h>
#import <mach/mach_time.h>

// ---- オブジェクト ID。単一デバイスなので固定で足りる ----
// 入力ストリーム（ID 4）は外した。音の受け渡しは TCP (ETLinkSender) に移っていて、
// ReadInput を読む相手がもう居ない。使っていない面を名乗り続ける理由が無いだけで、
// 外したことで症状が消えると分かっているわけではない。
// ヘッダの「提示できるのは単一の出力デバイスのみ」はデバイスの本数の話であって、
// 1 台が入力ストリームを持つことを禁じてはいない。
enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,   // 1
    kObjectID_Device        = 2,
    kObjectID_Stream_Output = 3,
};

// iOS SDK には AudioHardware.h 由来のこの2つが無いので自前で置く。
// 値は macOS の CoreAudio ヘッダと同じ 4CC。
enum {
    kNemutStreamConfiguration    = 'slay',
    kNemutPreferredChannelLayout = 'srnd',
};

static const Float64  kSampleRate     = 48000.0;
static const UInt32   kChannelCount   = 2;
static const UInt32   kRingFrames     = 8192;            // ゼロタイムスタンプの周期

static os_log_t gLog;

// ---- 状態 ----
static AudioServerPlugInDriverInterface   gInterface;
static AudioServerPlugInDriverInterface  *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef         gDriverRef    = &gInterfacePtr;
static AudioServerPlugInHostRef           gHost         = NULL;

static pthread_mutex_t  gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32           gRefCount   = 1;
static CFStringRef      gDeviceUID  = NULL;   // MediaOutputDevice.id と同じ文字列
static Boolean          gRegistered = false;  // 直近の登録が生きているか（publish は毎回やり直す）
// 生存を出し入れして port を手放させる案は外した。
//
// kAudioDevicePropertyDeviceIsAlive を 0 にして PropertiesChanged で知らせると、
// 手放すどころか activate の途中でデバイスを切られて Unable to Connect になる。
// 実機で確かめた。ここは常に 1 を返す。
static Boolean          gIORunning  = false;
static UInt64           gIOCount    = 0;

// ゼロタイムスタンプ用
static Float64  gZeroSampleTime = 0;
static UInt64   gZeroHostTime   = 0;
static UInt64   gAnchorHostTime = 0;
static UInt64   gPeriodCount    = 0;

static EffeTuneSampleHandler gHandler = NULL;

// 出力→入力のリング（gLoop）は削除した。音の受け渡しは TCP (ETLinkSender) に移っている。
static float   gVolume = 1.0f;
static BOOL    gMuted  = NO;

// ---- 小道具 ----

// 4CC を読める文字列にする。どのプロパティを聞かれたかをログに出すため。
static void FourCCStr(uint32_t v, char out[5]) {
    out[0] = (char)((v >> 24) & 0xff);
    out[1] = (char)((v >> 16) & 0xff);
    out[2] = (char)((v >> 8) & 0xff);
    out[3] = (char)(v & 0xff);
    out[4] = 0;
    for (int i = 0; i < 4; i++) if (out[i] < 0x20 || out[i] > 0x7e) out[i] = '.';
}

#define LOGPROP(tag, obj, addr)                                                  do {                                                                             char _s[5], _c[5];                                                           FourCCStr((addr)->mSelector, _s);                                            FourCCStr((addr)->mScope, _c);                                               os_log(gLog, "%{public}s obj=%u sel=%{public}s scope=%{public}s el=%u",                tag, (unsigned)(obj), _s, _c, (unsigned)(addr)->mElement);        } while (0)

static AudioStreamBasicDescription EffeTuneFormat(void) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate       = kSampleRate;
    f.mFormatID         = kAudioFormatLinearPCM;
    f.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket   = 4 * kChannelCount;
    f.mFramesPerPacket  = 1;
    f.mBytesPerFrame    = 4 * kChannelCount;
    f.mChannelsPerFrame = kChannelCount;
    f.mBitsPerChannel   = 32;
    return f;
}

// ---- IUnknown ----

static HRESULT ET_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    CFUUIDRef iunknown = IUnknownUUID;
    CFUUIDRef plugin   = kAudioServerPlugInDriverInterfaceUUID;
    HRESULT rc = E_NOINTERFACE;
    if (CFEqual(req, iunknown) || CFEqual(req, plugin)) {
        pthread_mutex_lock(&gStateMutex);
        gRefCount++;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        rc = S_OK;
    }
    CFRelease(req);
    return rc;
}

static ULONG ET_AddRef(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG n = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return n;
}

static ULONG ET_Release(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG n = gRefCount > 0 ? --gRefCount : 0;
    pthread_mutex_unlock(&gStateMutex);
    return n;
}

// ---- 基本 ----

static OSStatus ET_Initialize(AudioServerPlugInDriverRef inDriver,
                              AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    gAnchorHostTime = 0;
    os_log(gLog, "Initialize");
    return noErr;
}

// 単一デバイスしか出せないので、動的な生成/破棄は受けない。
static OSStatus ET_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc,
                                const AudioServerPlugInClientInfo *c, AudioObjectID *out) {
    (void)d; (void)desc; (void)c; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus ET_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) {
    (void)d; (void)id;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus ET_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev,
                                   const AudioServerPlugInClientInfo *info) {
    (void)d;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    os_log(gLog, "AddDeviceClient pid=%d bundle=%{public}@",
           info ? info->mProcessID : -1,
           info ? (__bridge NSString *)info->mBundleID : @"-");
    return noErr;
}

static OSStatus ET_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev,
                                      const AudioServerPlugInClientInfo *info) {
    (void)d; (void)info;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    os_log(gLog, "RemoveDeviceClient");
    return noErr;
}

static OSStatus ET_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d,
                                                    AudioObjectID dev, UInt64 action,
                                                    void *info) {
    (void)d; (void)dev; (void)action; (void)info;
    return noErr;
}
static OSStatus ET_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d,
                                                  AudioObjectID dev, UInt64 action,
                                                  void *info) {
    (void)d; (void)dev; (void)action; (void)info;
    return noErr;
}

// ---- プロパティ ----

static Boolean ET_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj,
                              pid_t client, const AudioObjectPropertyAddress *addr) {
    (void)d; (void)client;
    if (!addr) return false;
    switch (obj) {
        case kObjectID_PlugIn:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                case kAudioPlugInPropertyTranslateUIDToDevice:
                    return true;
            }
            return false;
        case kObjectID_Device:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyRelatedDevices:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertyStreams:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyNominalSampleRate:
                case kAudioDevicePropertyAvailableNominalSampleRates:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertyPreferredChannelsForStereo:
                case kNemutStreamConfiguration:
                case kNemutPreferredChannelLayout:
                case kAudioObjectPropertyControlList:
                    return true;
            }
            return false;
        case kObjectID_Stream_Output:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    return true;
            }
            return false;
    }
    LOGPROP("HAS-NO", obj, addr);
    return false;
}

static OSStatus ET_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj,
                                      pid_t client, const AudioObjectPropertyAddress *addr,
                                      Boolean *outSettable) {
    (void)d; (void)client;
    if (!addr || !outSettable) return kAudioHardwareIllegalOperationError;
    *outSettable = false;
    if (obj == kObjectID_Device && addr->mSelector == kAudioDevicePropertyNominalSampleRate) {
        *outSettable = true;
    }
    if (obj == kObjectID_Stream_Output && addr->mSelector == kAudioStreamPropertyIsActive) {
        *outSettable = true;
    }
    return noErr;
}

#define RET_SIZE(n)  do { if (outSize) *outSize = (n); return noErr; } while (0)

static OSStatus ET_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj,
                                       pid_t client, const AudioObjectPropertyAddress *addr,
                                       UInt32 qualSize, const void *qual, UInt32 *outSize) {
    (void)d; (void)client; (void)qualSize; (void)qual;
    if (!addr || !outSize) return kAudioHardwareIllegalOperationError;

    switch (obj) {
        case kObjectID_PlugIn:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:              RET_SIZE(sizeof(AudioClassID));
                case kAudioObjectPropertyOwner:              RET_SIZE(sizeof(AudioObjectID));
                case kAudioObjectPropertyManufacturer:        RET_SIZE(sizeof(CFStringRef));
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:          RET_SIZE(sizeof(AudioObjectID));
                case kAudioPlugInPropertyTranslateUIDToDevice: RET_SIZE(sizeof(AudioObjectID));
            }
            break;
        case kObjectID_Device:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:              RET_SIZE(sizeof(AudioClassID));
                case kAudioObjectPropertyOwner:              RET_SIZE(sizeof(AudioObjectID));
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:            RET_SIZE(sizeof(CFStringRef));
                // 入力スコープにはストリームが無い。
                // GetPropertyData が 0 個返すので、大きさも 0 でないと食い違う。
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyStreams:
                    RET_SIZE(addr->mScope == kAudioObjectPropertyScopeInput
                             ? 0u : (UInt32)sizeof(AudioObjectID));
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyZeroTimeStampPeriod: RET_SIZE(sizeof(UInt32));
                case kAudioDevicePropertyRelatedDevices:      RET_SIZE(sizeof(AudioObjectID));
                case kAudioDevicePropertyNominalSampleRate:   RET_SIZE(sizeof(Float64));
                case kAudioDevicePropertyAvailableNominalSampleRates:
                                                              RET_SIZE(sizeof(AudioValueRange));
                case kAudioDevicePropertyPreferredChannelsForStereo:
                                                              RET_SIZE(2 * sizeof(UInt32));
                case kNemutStreamConfiguration:
                    // 入力スコープはバッファ 0 本なのでヘッダの分だけ。
                    RET_SIZE(addr->mScope == kAudioObjectPropertyScopeInput
                             ? (UInt32)offsetof(AudioBufferList, mBuffers)
                             : (UInt32)(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer)));
                case kNemutPreferredChannelLayout:
                    RET_SIZE(offsetof(AudioChannelLayout, mChannelDescriptions));
                case kAudioObjectPropertyControlList:
                    // 音量などのコントロールは持たない。空で返す。
                    RET_SIZE(0);
            }
            break;
        case kObjectID_Stream_Output:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:              RET_SIZE(sizeof(AudioClassID));
                case kAudioObjectPropertyOwner:              RET_SIZE(sizeof(AudioObjectID));
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:            RET_SIZE(sizeof(UInt32));
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                                            RET_SIZE(sizeof(AudioStreamBasicDescription));
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                                            RET_SIZE(sizeof(AudioStreamRangedDescription));
            }
            break;
    }
    LOGPROP("SIZE-UNKNOWN", obj, addr);
    return kAudioHardwareUnknownPropertyError;
}

#undef RET_SIZE

#define PUT(type, value) \
    do { if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; \
         *((type *)outData) = (value); *outDataSize = sizeof(type); return noErr; } while (0)

static OSStatus ET_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj,
                                   pid_t client, const AudioObjectPropertyAddress *addr,
                                   UInt32 qualSize, const void *qual,
                                   UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)d; (void)client;
    if (!addr || !outDataSize || !outData) return kAudioHardwareIllegalOperationError;

    switch (obj) {
        case kObjectID_PlugIn:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
                case kAudioObjectPropertyClass:     PUT(AudioClassID, kAudioPlugInClassID);
                case kAudioObjectPropertyOwner:     PUT(AudioObjectID, kAudioObjectUnknown);
                case kAudioObjectPropertyManufacturer:
                    PUT(CFStringRef, (CFStringRef)CFRetain(CFSTR("nemut.ai")));
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                    if (inDataSize < sizeof(AudioObjectID)) { *outDataSize = 0; return noErr; }
                    ((AudioObjectID *)outData)[0] = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return noErr;
                case kAudioPlugInPropertyTranslateUIDToDevice: {
                    if (qualSize != sizeof(CFStringRef) || !qual)
                        return kAudioHardwareBadPropertySizeError;
                    CFStringRef want = *((CFStringRef *)qual);
                    AudioObjectID r = kAudioObjectUnknown;
                    if (gDeviceUID && want && CFEqual(want, gDeviceUID)) r = kObjectID_Device;
                    PUT(AudioObjectID, r);
                }
            }
            break;

        case kObjectID_Device:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
                case kAudioObjectPropertyClass:     PUT(AudioClassID, kAudioDeviceClassID);
                case kAudioObjectPropertyOwner:     PUT(AudioObjectID, kObjectID_PlugIn);
                case kAudioObjectPropertyName:
                    PUT(CFStringRef, (CFStringRef)CFRetain(CFSTR("EffeTune")));
                case kAudioObjectPropertyManufacturer:
                    PUT(CFStringRef, (CFStringRef)CFRetain(CFSTR("nemut.ai")));
                case kAudioDevicePropertyDeviceUID:
                    PUT(CFStringRef, gDeviceUID ? (CFStringRef)CFRetain(gDeviceUID)
                                                : (CFStringRef)CFRetain(CFSTR("")));
                case kAudioDevicePropertyModelUID:
                    PUT(CFStringRef, (CFStringRef)CFRetain(CFSTR("ai.nemut.effetune.model")));
                // ヘッダの要求: RemoteStreaming か RemoteScreen でないと登録が失敗する。
                case kAudioDevicePropertyTransportType:
                    PUT(UInt32, kAudioDeviceTransportTypeRemoteStreaming);
                case kAudioDevicePropertyRelatedDevices:
                    if (inDataSize < sizeof(AudioObjectID)) { *outDataSize = 0; return noErr; }
                    ((AudioObjectID *)outData)[0] = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return noErr;
                case kAudioDevicePropertyClockDomain:       PUT(UInt32, 0);
                case kAudioDevicePropertyDeviceIsAlive:     PUT(UInt32, 1);
                case kAudioDevicePropertyDeviceIsRunning:   PUT(UInt32, gIORunning ? 1 : 0);
                // どちらも 0。このデバイスは MediaDevice のルートピッカーで
                // 明示的に選ばれたときだけ使えればよく、既定の出力の候補に入る必要は無い。
                //
                // 未確認: 「既定の候補だったからプレイヤー自身の出力もここへ来て
                // 帰還ループになり、レベルが +33dB まで伸びた」という筋は測っていない。
                // レベルが伸びたのは実機で見た事実だが、原因はこれと決まっていない。
                // プレイヤーの出力が本当にここへ来ていたなら AddDeviceClient の
                // bundle に ai.nemut.effetune.player が出る。まずそれを読むこと。
                // 0 にした副作用（ルートピッカーから選べなくなる）も未確認。
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:       PUT(UInt32, 1);
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: PUT(UInt32, 1);
                case kAudioDevicePropertyLatency:           PUT(UInt32, 0);
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyStreams: {
                    // 出力ストリーム 1 本だけ。入力スコープには何も返さない。
                    AudioObjectID ids[1];
                    UInt32 n = 0;
                    if (addr->mScope != kAudioObjectPropertyScopeInput) {
                        ids[n++] = kObjectID_Stream_Output;
                    }
                    UInt32 fit = inDataSize / (UInt32)sizeof(AudioObjectID);
                    if (fit > n) fit = n;
                    for (UInt32 i = 0; i < fit; i++) ((AudioObjectID *)outData)[i] = ids[i];
                    *outDataSize = fit * (UInt32)sizeof(AudioObjectID);
                    return noErr;
                }
                case kAudioDevicePropertySafetyOffset:      PUT(UInt32, 512);
                case kAudioDevicePropertyNominalSampleRate: PUT(Float64, kSampleRate);
                case kAudioDevicePropertyAvailableNominalSampleRates: {
                    if (inDataSize < sizeof(AudioValueRange)) { *outDataSize = 0; return noErr; }
                    AudioValueRange *r = (AudioValueRange *)outData;
                    r[0].mMinimum = kSampleRate;
                    r[0].mMaximum = kSampleRate;
                    *outDataSize = sizeof(AudioValueRange);
                    return noErr;
                }
                case kAudioDevicePropertyIsHidden:          PUT(UInt32, 0);
                case kAudioDevicePropertyZeroTimeStampPeriod: PUT(UInt32, kRingFrames);
                case kAudioDevicePropertyPreferredChannelsForStereo: {
                    if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    ((UInt32 *)outData)[0] = 1;
                    ((UInt32 *)outData)[1] = 2;
                    *outDataSize = 2 * sizeof(UInt32);
                    return noErr;
                }
                case kNemutStreamConfiguration: {
                    AudioBufferList *bl = (AudioBufferList *)outData;
                    // 出力は 1 バッファ 2ch。入力スコープはバッファ 0 本
                    // （入力ストリームを外したので、ここも空でないと食い違う）。
                    if (addr->mScope == kAudioObjectPropertyScopeInput) {
                        size_t need = offsetof(AudioBufferList, mBuffers);
                        if (inDataSize < need) return kAudioHardwareBadPropertySizeError;
                        bl->mNumberBuffers = 0;
                        *outDataSize = (UInt32)need;
                        return noErr;
                    }
                    size_t need = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer);
                    if (inDataSize < need) return kAudioHardwareBadPropertySizeError;
                    bl->mNumberBuffers = 1;
                    bl->mBuffers[0].mNumberChannels = kChannelCount;
                    bl->mBuffers[0].mDataByteSize = 0;
                    bl->mBuffers[0].mData = NULL;
                    *outDataSize = (UInt32)need;
                    return noErr;
                }
                case kAudioObjectPropertyControlList:
                    *outDataSize = 0;
                    return noErr;
                case kNemutPreferredChannelLayout: {
                    size_t need = offsetof(AudioChannelLayout, mChannelDescriptions);
                    if (inDataSize < need) return kAudioHardwareBadPropertySizeError;
                    AudioChannelLayout *cl = (AudioChannelLayout *)outData;
                    cl->mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
                    cl->mChannelBitmap = 0;
                    cl->mNumberChannelDescriptions = 0;
                    *outDataSize = (UInt32)need;
                    return noErr;
                }
            }
            break;

        case kObjectID_Stream_Output:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
                case kAudioObjectPropertyClass:     PUT(AudioClassID, kAudioStreamClassID);
                case kAudioObjectPropertyOwner:     PUT(AudioObjectID, kObjectID_Device);
                case kAudioStreamPropertyIsActive:  PUT(UInt32, 1);
                // 1 = input, 0 = output。出力しか持たないので 0 固定。
                case kAudioStreamPropertyDirection:
                    PUT(UInt32, 0);
                case kAudioStreamPropertyTerminalType:
                    PUT(UInt32, kAudioStreamTerminalTypeSpeaker);
                case kAudioStreamPropertyStartingChannel: PUT(UInt32, 1);
                case kAudioStreamPropertyLatency:         PUT(UInt32, 0);
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    PUT(AudioStreamBasicDescription, EffeTuneFormat());
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats: {
                    if (inDataSize < sizeof(AudioStreamRangedDescription)) { *outDataSize = 0; return noErr; }
                    AudioStreamRangedDescription *r = (AudioStreamRangedDescription *)outData;
                    r[0].mFormat = EffeTuneFormat();
                    r[0].mSampleRateRange.mMinimum = kSampleRate;
                    r[0].mSampleRateRange.mMaximum = kSampleRate;
                    *outDataSize = sizeof(AudioStreamRangedDescription);
                    return noErr;
                }
            }
            break;
    }
    LOGPROP("DATA-UNKNOWN", obj, addr);
    return kAudioHardwareUnknownPropertyError;
}

#undef PUT

static OSStatus ET_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj,
                                   pid_t client, const AudioObjectPropertyAddress *addr,
                                   UInt32 qualSize, const void *qual,
                                   UInt32 inDataSize, const void *inData) {
    (void)d; (void)client; (void)qualSize; (void)qual;
    if (!addr) return kAudioHardwareIllegalOperationError;

    // IsPropertySettable が「書ける」と答えた 2 つは、ここで受けないと辻褄が合わない。
    // 書けると答えたのにエラーを返すと、ホストはストリームの活性化と
    // レート合わせを失敗として扱い、そのまま IO が始まらない。
    if (obj == kObjectID_Stream_Output && addr->mSelector == kAudioStreamPropertyIsActive) {
        // 受けるだけ。ストリームは 1 本しかないので常に有効のまま返す。
        return noErr;
    }
    if (obj == kObjectID_Device && addr->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (!inData || inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        Float64 want = *((const Float64 *)inData);
        // AvailableNominalSampleRates は 48k の 1 点だけ。それ以外は受けない。
        if (want > kSampleRate - 1.0 && want < kSampleRate + 1.0) return noErr;
        return kAudioHardwareIllegalOperationError;
    }

    // ほかは単一フォーマット固定なので受けない。
    return kAudioHardwareUnknownPropertyError;
}

// ---- IO ----

static OSStatus ET_StartIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)d; (void)client;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    gIORunning = true;
    gIOCount = 0;
    gAnchorHostTime = 0;
    gZeroSampleTime = 0;
    gZeroHostTime = 0;
    gPeriodCount = 0;
    pthread_mutex_unlock(&gStateMutex);
    os_log(gLog, "ET StartIO");
    return noErr;
}

static OSStatus ET_StopIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)d; (void)client;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    gIORunning = false;
    pthread_mutex_unlock(&gStateMutex);
    os_log(gLog, "StopIO frames=%llu", (unsigned long long)gIOCount);
    return noErr;
}

// ゼロタイムスタンプ。仮想デバイスなのでホストクロックから作る。
//
// 直した点: 以前は周期ごとに seed を増やしていたが、これは
//   HALS_IORawClock::Update: Re-anchoring IO timeline. Zero timestamp seed changed
// をホストに毎回起こさせ、後続のセッション活性化が
//   AudioSessionServerImp_iOS.mm:899 "early exit due to failure" ('!pla') で落ちていた。
// seed は「タイムラインが不連続に変わったとき」だけ変える値なので固定にする。
static OSStatus ET_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID dev,
                                    UInt32 client, Float64 *outSampleTime,
                                    UInt64 *outHostTime, UInt64 *outSeed) {
    (void)d; (void)client;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;

    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);

    // 1 フレームあたりのホストティック数
    const Float64 nsPerFrame = 1.0e9 / kSampleRate;
    const Float64 hostTicksPerFrame = nsPerFrame * (Float64)tb.denom / (Float64)tb.numer;
    const Float64 hostTicksPerRing = hostTicksPerFrame * (Float64)kRingFrames;

    UInt64 now = mach_absolute_time();

    // ここはリアルタイムスレッド。ロックも確保もしない。
    // 呼び出しは HAL の IO スレッド 1 本からなので素の変数で足りる。
    if (gAnchorHostTime == 0) {
        gAnchorHostTime = now;
        gPeriodCount = 0;
    }
    // 次の周期の開始時刻を超えていたら 1 周期進める。
    Float64 offset = ((Float64)(gPeriodCount + 1)) * hostTicksPerRing;
    UInt64 nextHostTime = gAnchorHostTime + (UInt64)offset;
    if (nextHostTime <= now) {
        gPeriodCount++;
    }
    Float64 st = (Float64)(gPeriodCount * (UInt64)kRingFrames);
    UInt64 ht = gAnchorHostTime + (UInt64)(((Float64)gPeriodCount) * hostTicksPerRing);
    gZeroSampleTime = st;
    gZeroHostTime = ht;

    if (outSampleTime) *outSampleTime = st;
    if (outHostTime)   *outHostTime   = ht;
    if (outSeed)       *outSeed       = 1;   // 固定。変えるとホストが再同期する。
    return noErr;
}

static OSStatus ET_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev,
                                     UInt32 client, UInt32 op,
                                     Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)d; (void)client;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    Boolean will = false, inPlace = true;
    // ミックスはホスト側がやる。こちらは書き出し段だけ引き受ける。
    // MixOutput まで true にすると、やらない仕事を引き受けたことになり
    // ホストの IO サイクルと噛み合わなくなる。
    // ReadInput も false。入力ストリームを外したので読み出す相手がいない。
    switch (op) {
        case kAudioServerPlugInIOOperationWriteMix:   // 出力の書き出し。ここに音が届く
            will = true;
            break;
        default:
            will = false;
            break;
    }
    if (outWillDo) *outWillDo = will;
    if (outWillDoInPlace) *outWillDoInPlace = inPlace;
    return noErr;
}

static OSStatus ET_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev,
                                    UInt32 client, UInt32 op, UInt32 frames,
                                    const AudioServerPlugInIOCycleInfo *cycle) {
    (void)d; (void)dev; (void)client; (void)op; (void)frames; (void)cycle;
    return noErr;
}

// ここが本体。WriteMix でミックス済みのシステム音声が来る。
static OSStatus ET_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev,
                                 AudioObjectID stream, UInt32 client, UInt32 op,
                                 UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle,
                                 void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)d; (void)stream; (void)client; (void)ioSecondaryBuffer;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (!ioMainBuffer || frames == 0) return noErr;

    // 引き受けるのは WriteMix だけ。ReadInput 用の出力→入力のリングは削除した
    // （入力ストリームを外したので読む相手がいない。受け渡しは TCP に移っている）。
    if (op != kAudioServerPlugInIOOperationWriteMix) return noErr;

    gIOCount += frames;

    EffeTuneSampleHandler h = gHandler;
    if (h) {
        // ストリームのフォーマットはインターリーブの float32 x2。
        // Passthrough 側が非インターリーブを期待しているので、
        // ここではインターリーブのまま1面として渡し、受け側で分ける。
        const float *interleaved = (const float *)ioMainBuffer;
        const float *planes[1] = { interleaved };
        h(planes, kChannelCount, frames,
          cycle ? cycle->mOutputTime.mHostTime : 0);
    }

    // ミュート中だけ書き出し後のバッファを潰す。
    //
    // ただしこれは聞こえ方を変えない。すぐ上の h() で同じサンプルを既に TCP へ渡していて、
    // 鳴らすのは本体側だから、ここを 0 にしても届く音は変わらない。
    // gVolume も同じで、読んでいるのは volume のゲッターだけ。
    // ルートピッカーの音量とミュートは、いまのところ効かない。
    if (gMuted) {
        memset(ioMainBuffer, 0, (size_t)frames * kChannelCount * sizeof(float));
    }
    return noErr;
}

static OSStatus ET_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev,
                                  UInt32 client, UInt32 op, UInt32 frames,
                                  const AudioServerPlugInIOCycleInfo *cycle) {
    (void)d; (void)dev; (void)client; (void)op; (void)frames; (void)cycle;
    return noErr;
}

// ---- ObjC の顔 ----

@implementation EffeTuneDriver

+ (EffeTuneDriver *)shared {
    static EffeTuneDriver *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLog = os_log_create("ai.nemut.effetune", "driver");
        s = [[EffeTuneDriver alloc] init];
    });
    return s;
}

- (float)volume { return gVolume; }
- (void)setVolume:(float)v { gVolume = v; }
- (BOOL)muted { return gMuted; }
- (void)setMuted:(BOOL)m { gMuted = m; }
- (double)sampleRate { return kSampleRate; }
- (uint32_t)channelCount { return kChannelCount; }
- (uint64_t)framesDelivered { return gIOCount; }

/// vtable を埋めるのはプロセスに 1 回だけ。
///
/// 以前は publish のたびに memset して張り直していた。
/// audio server が握っている最中に関数ポインタが一瞬 NULL になり、
/// その隙に呼ばれるとデバイスが死んだ。
/// 埋めるのを一度きりにすれば、登録だけを何度やり直しても危うくない。
static void ETFillInterfaceOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gInterface._reserved                        = NULL;
        gInterface.QueryInterface                   = ET_QueryInterface;
        gInterface.AddRef                           = ET_AddRef;
        gInterface.Release                          = ET_Release;
        gInterface.Initialize                       = ET_Initialize;
        gInterface.CreateDevice                     = ET_CreateDevice;
        gInterface.DestroyDevice                    = ET_DestroyDevice;
        gInterface.AddDeviceClient                  = ET_AddDeviceClient;
        gInterface.RemoveDeviceClient               = ET_RemoveDeviceClient;
        gInterface.PerformDeviceConfigurationChange = ET_PerformDeviceConfigurationChange;
        gInterface.AbortDeviceConfigurationChange   = ET_AbortDeviceConfigurationChange;
        gInterface.HasProperty                      = ET_HasProperty;
        gInterface.IsPropertySettable               = ET_IsPropertySettable;
        gInterface.GetPropertyDataSize              = ET_GetPropertyDataSize;
        gInterface.GetPropertyData                  = ET_GetPropertyData;
        gInterface.SetPropertyData                  = ET_SetPropertyData;
        gInterface.StartIO                          = ET_StartIO;
        gInterface.StopIO                           = ET_StopIO;
        gInterface.GetZeroTimeStamp                 = ET_GetZeroTimeStamp;
        gInterface.WillDoIOOperation                = ET_WillDoIOOperation;
        gInterface.BeginIOOperation                 = ET_BeginIOOperation;
        gInterface.DoIOOperation                    = ET_DoIOOperation;
        gInterface.EndIOOperation                   = ET_EndIOOperation;
    });
}

- (OSStatus)publishWithDeviceUID:(NSString *)uid {
    if (gDeviceUID) { CFRelease(gDeviceUID); gDeviceUID = NULL; }
    gDeviceUID = (CFStringRef)CFBridgingRetain([uid copy]);

    ETFillInterfaceOnce();

    // **毎回登録し直す。**
    // 以前は gRegistered で短絡していたが、それだと
    // audio server がポートを止めた（quies:1 rout:0）あとに負ける。
    // 実機のログで確かめたところ、activate が 5 回来て全部
    // 「登録済みなので再利用」になり、StartIO は 1 回も呼ばれなかった。
    // 端末を再起動すると直るのは、プロセスが入れ替わって
    // 1 回目の登録に戻るから。
    OSStatus st = AudioServerPlugInRegisterMediaDeviceExtension(gDriverRef, ^{
        gRegistered = false;
        os_log_error(gLog, "ET audio server との接続が切れた");
    });
    if (st == noErr) gRegistered = true;
    os_log_error(gLog, "ET publish uid=%{public}@ status=%d registered=%d",
                 uid, (int)st, (int)gRegistered);
    return st;
}

/// 音の受け取りだけ止める。CoreAudio への登録は残す。
/// 登録を捨てても貼り直す手段が無い（RegisterMediaDeviceExtension に対になる
/// Unregister が無い）ので、捨てた時点でこのプロセスでは二度と出せなくなる。
- (void)unpublish {
    gHandler = nil;

    os_log(gLog, "unpublish frames=%llu registered=%d",
           (unsigned long long)gIOCount, (int)gRegistered);
}

- (void)startCaptureWithHandler:(EffeTuneSampleHandler)handler {
    gHandler = [handler copy];
    gIOCount = 0;
    os_log(gLog, "startCapture");
}

- (void)stopCapture {
    gHandler = nil;
    os_log(gLog, "stopCapture frames=%llu", (unsigned long long)gIOCount);
}

@end
