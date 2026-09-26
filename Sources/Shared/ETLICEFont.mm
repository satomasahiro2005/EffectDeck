// iOS CoreText boundary for ysfx's LICE renderer. Primitives and compositing
// remain in LICE; only the unavailable SWELL/AppKit font glue is replaced.

#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#include "WDL/lice/lice_text.h"
#include <algorithm>
#include <cstring>

// The offscreen iOS host has no system-window color table. LICE's legacy
// 8x8 fallback text and gfx_getsyscol still reference this SWELL entry point.
int GetSysColor(int) { return RGB(240, 240, 240); }

// **書体名は UTF-8 とは限らない。** 日本語版 REAPER の JSFX は CP932 のまま、欧文は
// CP1252 のまま届く。\xNN や str_setchar でも任意のバイト列が作れ、127 バイトで
// 切られた UTF-8 は字の途中で終わる。読めない名前に CFStringCreateWithCString は
// NULL を返し、それを CFRelease すると trap でアプリごと落ちる（起動のたびに開き直すので毎回）。
// 厳しい順に試す。CP1252 はほぼ何でも読めてしまうので CP932 の後。MacRoman は 256 通り全部に字がある。
static CFStringRef ETCreateFontFamilyName(const char *name)
{
    if (!name || !*name) name = "Helvetica";
    const CFStringEncoding encodings[] = {
        kCFStringEncodingUTF8, kCFStringEncodingDOSJapanese,
        kCFStringEncodingWindowsLatin1, kCFStringEncodingMacRoman,
    };
    for (CFStringEncoding encoding : encodings)
        if (CFStringRef family = CFStringCreateWithCString(nullptr, name, encoding)) return family;
    return CFStringCreateWithCString(nullptr, "Helvetica", kCFStringEncodingUTF8);
}

class ETCoreTextLICEFont final : public LICE_IFont {
public:
    ~ETCoreTextLICEFont() override { if (font_) CFRelease(font_); }
    bool configure(const char *name, int size, bool bold, bool italic, bool underline) {
        if (font_) { CFRelease(font_); font_ = nullptr; }
        CFStringRef family = ETCreateFontFamilyName(name);
        if (!family) return false;
        CTFontSymbolicTraits traits = 0;
        if (bold) traits |= kCTFontBoldTrait;
        if (italic) traits |= kCTFontItalicTrait;
        CTFontRef base = CTFontCreateWithName(family, size > 1 ? size : 1, nullptr);
        CFRelease(family);
        if (!base) return false;
        // **太字や斜体を持たない書体では NULL が返る**（CTFont.h）。そのときは元の書体で描く。
        CTFontRef styled = traits ? CTFontCreateCopyWithSymbolicTraits(base, 0, nullptr, traits, traits)
                                  : nullptr;
        font_ = styled ? styled : (CTFontRef)CFRetain(base);
        CFRelease(base);
        underline_ = underline;
        lineHeight_ = (int)ceil(CTFontGetAscent(font_) + CTFontGetDescent(font_) + CTFontGetLeading(font_));
        return true;
    }
    void SetFromHFont(HFONT, int = 0) override {}
    LICE_pixel SetTextColor(LICE_pixel c) override { auto old=color_; color_=c; return old; }
    LICE_pixel SetBkColor(LICE_pixel c) override { auto old=background_; background_=c; return old; }
    LICE_pixel SetEffectColor(LICE_pixel c) override { auto old=effect_; effect_=c; return old; }
    int SetBkMode(int m) override { int old=backgroundMode_; backgroundMode_=m; return old; }
    void SetCombineMode(int mode, float alpha=1) override { combine_=mode; alpha_=alpha; }
    LICE_pixel GetTextColor() override { return color_; }
    HFONT GetHFont() override { return nullptr; }
    int GetLineHeight() override { return lineHeight_ + lineSpacing_; }
    void SetLineSpacingAdjust(int amount) override { lineSpacing_=amount; }

    int DrawText(LICE_IBitmap *bitmap, const char *utf8, int count, RECT *rect, UINT flags) override {
        if (!font_ || !utf8 || !rect) return 0;
        if (count < 0) count = (int)strlen(utf8);
        CFStringRef string = CFStringCreateWithBytes(nullptr, (const UInt8 *)utf8, count,
                                                     kCFStringEncodingUTF8, false);
        if (!string) return 0;
        CGFloat components[4] = {
            LICE_GETR(color_) / 255.0, LICE_GETG(color_) / 255.0,
            LICE_GETB(color_) / 255.0, (LICE_GETA(color_) / 255.0) * alpha_
        };
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGColorRef color = CGColorCreate(space, components);
        const void *keys[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
        const void *values[] = { font_, color };
        CFDictionaryRef attributes = CFDictionaryCreate(nullptr, keys, values, 2,
                           &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFAttributedStringRef attributed = CFAttributedStringCreate(nullptr, string, attributes);
        CTLineRef line = CTLineCreateWithAttributedString(attributed);
        CGFloat ascent=0, descent=0, leading=0;
        double width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
        int height = (int)ceil(ascent + descent + leading);
        if (flags & DT_CALCRECT) {
            rect->right = rect->left + (int)ceil(width);
            rect->bottom = rect->top + height;
        } else if (bitmap && bitmap->getBits()) {
            size_t row = (size_t)bitmap->getRowSpan() * sizeof(LICE_pixel);
            CGContextRef context = CGBitmapContextCreate(bitmap->getBits(), bitmap->getWidth(),
                bitmap->getHeight(), 8, row, space,
                kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
            if (context) {
                CGContextSetBlendMode(context, kCGBlendModeNormal);
                CGFloat x = rect->left;
                if (flags & DT_CENTER) {
                    const double centered = ((double)(rect->right-rect->left)-width)/2;
                    x += centered > 0 ? centered : 0;
                }
                else if (flags & DT_RIGHT) x = rect->right - width;
                CGFloat baseline = bitmap->getHeight() - rect->top - ascent;
                CGContextSetTextPosition(context, x, baseline);
                CTLineDraw(line, context);
                if (underline_) {
                    CGContextSetStrokeColorWithColor(context, color);
                    CGContextMoveToPoint(context, x, baseline - 1);
                    CGContextAddLineToPoint(context, x + width, baseline - 1);
                    CGContextStrokePath(context);
                }
                CGContextRelease(context);
            }
        }
        CFRelease(line); CFRelease(attributed); CFRelease(attributes);
        CGColorRelease(color); CGColorSpaceRelease(space); CFRelease(string);
        return height;
    }
private:
    CTFontRef font_{};
    LICE_pixel color_{static_cast<LICE_pixel>(LICE_RGBA(255,255,255,255))}, background_{}, effect_{};
    int backgroundMode_{}, combine_{}, lineHeight_{12}, lineSpacing_{};
    float alpha_{1}; bool underline_{};
};

LICE_IFont *ETLICE_CreateFont() { return new ETCoreTextLICEFont; }

int ETLICE_ConfigureFont(LICE_IFont *font, const char *name, int size,
                         bool bold, bool italic, bool underline,
                         char *actualName, size_t actualNameSize)
{
    auto *coreText = dynamic_cast<ETCoreTextLICEFont *>(font);
    if (!coreText) return 0;
    // 0 を返すと gfx_setfont はこの番号を使わず、既定の書体で描く。
    if (!coreText->configure(name, size, bold, italic, underline)) return 0;
    if (actualName && actualNameSize) std::snprintf(actualName, actualNameSize, "%s", name && *name ? name : "Helvetica");
    return coreText->GetLineHeight();
}
