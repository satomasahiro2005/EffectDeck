// et_lice_font_linux.cpp（Tests/Fuzz/Native）
// 的 jsfxexec の Linux 用の書体。Sources/Shared/ETLICEFont.mm（CoreText）の代わりに同じ 3 つを置く。
//   GetSysColor           SWELL の色表（LICE の 8x8 の字と gfx_getsyscol が読む）
//   ETLICE_CreateFont     ysfx の LICE_CreateFont（Patches/ysfx-effectdeck-ios.diff が外へ出した口）
//   ETLICE_ConfigureFont  gfx_setfont と既定の書体（Helvetica 12）
//
// **CoreText は Linux に無いので、字の描画そのものはここでは叩けない。**
// ETLICEFont.mm と同じ約束（名前は任意のバイト列・count < 0 は strlen・DT_CALCRECT は
// 寸法だけ・失敗は 0）で寸法を返し、画素には書かない。叩けるのは gfx_drawstr /
// gfx_measurestr / gfx_setfont / gfx_printf の周り（ysfx と LICE の側）まで。
// 行の高さは CoreText の ascent + descent + leading（Helvetica で大きさの約 1.2 倍）に寄せる。
// 大きさは gfx_setfont が int にした値がそのまま来るので、2^20 で止めて int の溢れを
// こちらで作らない（CoreText 側の上限は知らない。ここは代わりの書体の都合）。

// 標準の頭を先に読む（SWELL の swell-types.h が min / max をマクロで置く）。
#include <cmath>
#include <cstdio>
#include <cstring>

#include "WDL/lice/lice.h"
#include "WDL/lice/lice_text.h"

int GetSysColor(int) { return RGB(240, 240, 240); }

namespace {
constexpr double kMaxLineHeight = 1 << 20;
/// 大きさ（点）から画素へ。1 以上 kMaxLineHeight 以下。
int metric(double v) { v = std::ceil(v); return v < 1 ? 1 : v > kMaxLineHeight ? (int)kMaxLineHeight : (int)v; }

class ETLinuxLICEFont final : public LICE_IFont {
public:
    bool configure(const char *name, int size, bool, bool, bool underline)
    {
        (void)name;   // 名前は選ぶのに使うだけ（ETLICEFont.mm は読めない名前で Helvetica に倒す）
        const double points = size > 1 ? size : 1;
        lineHeight_ = metric(points * 1.2);
        advance_ = metric(points * 0.6);
        underline_ = underline;
        return true;
    }
    void SetFromHFont(HFONT, int = 0) override {}
    LICE_pixel SetTextColor(LICE_pixel c) override { auto old = color_; color_ = c; return old; }
    LICE_pixel SetBkColor(LICE_pixel c) override { auto old = background_; background_ = c; return old; }
    LICE_pixel SetEffectColor(LICE_pixel c) override { auto old = effect_; effect_ = c; return old; }
    int SetBkMode(int m) override { int old = backgroundMode_; backgroundMode_ = m; return old; }
    void SetCombineMode(int mode, float alpha = 1) override { combine_ = mode; alpha_ = alpha; }
    LICE_pixel GetTextColor() override { return color_; }
    HFONT GetHFont() override { return nullptr; }
    int GetLineHeight() override { return lineHeight_ + lineSpacing_; }
    void SetLineSpacingAdjust(int amount) override { lineSpacing_ = amount; }

    int DrawText(LICE_IBitmap *bitmap, const char *utf8, int count, RECT *rect, UINT flags) override
    {
        if (!utf8 || !rect) return 0;
        if (count < 0) count = (int)std::strlen(utf8);
        // ETLICEFont.mm は count バイトを CFStringCreateWithBytes で読む。同じだけ読む
        // （ASan が count の外を読んでいないかを見る）。
        size_t glyphs = 0;
        for (int i = 0; i < count; ++i) glyphs += ((unsigned char)utf8[i] & 0xC0) != 0x80;
        const double width = (double)glyphs * advance_ < kMaxLineHeight ? (double)glyphs * advance_ : kMaxLineHeight;
        if (flags & DT_CALCRECT) {
            rect->right = rect->left + (int)width;
            rect->bottom = rect->top + lineHeight_;
        } else if (bitmap) {
            (void)bitmap->getBits();   // 描画は CoreText の仕事。ここでは書かない
        }
        return lineHeight_;
    }

private:
    LICE_pixel color_{static_cast<LICE_pixel>(LICE_RGBA(255, 255, 255, 255))}, background_{}, effect_{};
    int backgroundMode_{}, combine_{}, lineHeight_{12}, lineSpacing_{}, advance_{7};
    float alpha_{1};
    bool underline_{};
};
}

LICE_IFont *ETLICE_CreateFont() { return new ETLinuxLICEFont; }

int ETLICE_ConfigureFont(LICE_IFont *font, const char *name, int size,
                         bool bold, bool italic, bool underline,
                         char *actualName, size_t actualNameSize)
{
    auto *own = dynamic_cast<ETLinuxLICEFont *>(font);
    if (!own) return 0;
    if (!own->configure(name, size, bold, italic, underline)) return 0;
    if (actualName && actualNameSize)
        std::snprintf(actualName, actualNameSize, "%s", name && *name ? name : "Helvetica");
    return own->GetLineHeight();
}
