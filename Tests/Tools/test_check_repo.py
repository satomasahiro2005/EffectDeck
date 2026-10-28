"""Tools/check_repo.py の試験。小さな木を一時フォルダに作って、検査ごとに1か所ずつ壊す。"""
import json

from tools_support import (TempDir, env_patch, git, have_git, hermetic_git_env, load_tool, quiet,
                           unittest, write)

EFFECTS = {
    "dsp": "0.11.0", "dspParams": "0123456789abcdef", "generator": "Tools/gen_catalog.py",
    "effects": [
        {"nm": "Volume", "type": "VolumePlugin", "category": "basics", "about": "Level",
         "params": [{"key": "vl", "label": "Volume", "shape": "scalar", "kind": "number",
                     "min": -60, "max": 24, "step": 0.1, "unit": "dB", "default": 0}]},
        {"nm": "5Band PEQ", "type": "FiveBandPEQPlugin", "category": "eq", "about": "PEQ",
         "params": [
             {"key": "f", "label": "Freq", "shape": "indexed", "count": 2, "kind": "number",
              "min": 20, "max": 20000, "step": 1, "unit": "Hz", "default": [100, 1000]},
             {"key": "t", "label": "Type", "shape": "scalar", "kind": "enum",
              "options": ["pk", "ls"], "default": "pk"},
             {"key": "on", "label": "On", "shape": "scalar", "kind": "toggle", "default": True},
             {"key": "os", "label": "Oversampling", "shape": "scalar", "kind": "number",
              "min": 1, "max": 8, "step": 1, "unit": "", "default": 1, "allowed": [1, 2, 4, 8]}]},
        {"nm": "Matrix", "type": "MatrixPlugin", "category": "basics", "about": "Routing",
         "unsupported": "its routing is set in the app", "params": []},
    ]}

CHAIN_MD = """\
# Chains
`EffectDeck v2026.09.22 (EffeTune DSP 0.11.0)`. See [`chain/v0.11.0/`](chain/v0.11.0/index.md).
Tag `dsp-v0.11.0`.

```json
[{"nm":"Volume","vl":-3},{"nm":"Section","cm":"EQ"},{"nm":"5Band PEQ","f0":200,"t":"ls","en":true}]
```
"""

WORKER = """\
const AASA_PATHS = new Set(["/.well-known/apple-app-site-association", "/apple-app-site-association"]);
async function deck(url) {
  switch (url.pathname) {
    case "/":
      return home();
    case "/j":
    case "/j/":
      return jsfx();
    case "/privacy":
      return privacy();
  }
}
"""

LINKS = 'export const DECK_HOST = "effectdeck.nemut.ai";\nexport const LINK_HOST = "fxd.nemut.ai";\n'

SETTINGS = """\
let privacy = URL(string: "https://effectdeck.nemut.ai/privacy")!
let share = "https://effectdeck.nemut.ai/?p=" + code
let jsfx = "https://effectdeck.nemut.ai/j#" + payload
let doc = URL(string: "https://github.com/satomasahiro2005/EffectDeck/blob/main/CHAIN.md")!
let other = URL(string: "https://example.com/anything")!
"""

NAMES_H = """\
#define ET_NAME_STEM "EffectDeck"
#define ET_ROUTE_NAME "EffectDeck"
#define ET_DRIVER_NAME "EffectDeck Driver"
#define ET_MANUFACTURER "nemut.ai"
"""

GEN_LICENSES = """\
ITEMS = [
    ("EffectDeck", "MIT", "nemut.ai", "LICENSE"),
    ("EffeTune", "MIT", "Yoshiyuki Kobayashi", "Vendor/effetune/LICENSE"),
    ("WDL / LICE", "zlib-style", "Cockos", "Vendor/ysfx/thirdparty/WDL/LICENSE.txt"),
]
"""


def build(root):
    write(root / "Sources/EffeTuneLive/Generated/UpstreamVersion.swift", 'let ETUpstreamVersion = "0.11.0"\n')
    write(root / "project.yml", 'settings:\n  base:\n    MARKETING_VERSION: "2026.09.22"\n')
    write(root / "README.md", "![EffeTune DSP](https://img.shields.io/badge/EffeTune%20DSP-0.11.0-3B82F6)\n"
                              "See `Tools/gen_catalog.py` and `Generated/UpstreamVersion.swift`.\n")
    write(root / "CHAIN.md", CHAIN_MD)
    rows = ",\n".join(json.dumps(e, ensure_ascii=False, separators=(",", ":")) for e in EFFECTS["effects"])
    write(root / "chain/v0.11.0/effects.json",
          '{"dsp":"0.11.0","dspParams":"0123456789abcdef","generator":"Tools/gen_catalog.py","effects":[\n%s\n]}\n' % rows)
    write(root / "chain/v0.11.0/index.md",
          "# Index\n\n## basics ([basics.md](basics.md))\n\n- `Volume` — Level\n- `Matrix` — Routing\n\n"
          "## eq ([eq.md](eq.md))\n\n- `5Band PEQ` — PEQ\n")
    write(root / "chain/v0.11.0/basics.md", "# basics\n\n## Volume\n\nx\n\n## Matrix\n\ny\n")
    write(root / "chain/v0.11.0/eq.md", "# eq\n\n## 5Band PEQ\n\nz\n")
    write(root / "Tools/store_notes.txt", "Fixes.\n")
    write(root / "Tools/review_notes.txt", "Notes.\n")
    write(root / "Tools/gen_catalog.py", "# generator\n")
    write(root / "Tools/gen_licenses.py", GEN_LICENSES)
    write(root / "site/src/worker.js", WORKER)
    write(root / "site/src/links.js", LINKS)
    write(root / "Sources/EffeTuneLive/Views/SettingsView.swift", SETTINGS)
    write(root / "Sources/Shared/ETNames.h", NAMES_H)
    write(root / "NOTICE.md", "# What is bundled\n\n## EffeTune\n\n## WDL/LICE (zlib)\n")
    write(root / "docs/a.md", "Read `Sources/Shared/ETNames.h` and [b](b.md) and `docs/b.md`.\n")
    write(root / "docs/b.md", "Relative: `site/src/worker.js`.\n")
    write(root / "LICENSE", "MIT\n")


class CheckRepoTests(unittest.TestCase):
    def setUp(self):
        self.cr = load_tool("check_repo")

    def run_check(self, root, *extra):
        with quiet() as (out, err):
            code = self.cr.main(["--root", str(root), *extra])
        return code, out.getvalue()

    def assertProblem(self, root, needle, *extra):
        code, out = self.run_check(root, *extra)
        self.assertEqual(code, 1, out)
        self.assertIn(needle, out)

    def test_clean_tree_passes(self):
        with TempDir() as tmp:
            build(tmp)
            code, out = self.run_check(tmp)
        self.assertEqual(code, 0, out)

    # ---- chain

    def mutate_effects(self, root, fn):
        path = root / "chain/v0.11.0/effects.json"
        data = json.loads(path.read_text("utf-8"))
        fn(data)
        path.write_text(json.dumps(data), encoding="utf-8")

    def test_chain_default_outside_range(self):
        with TempDir() as tmp:
            build(tmp)
            self.mutate_effects(tmp, lambda d: d["effects"][0]["params"][0].update(default=30))
            self.assertProblem(tmp, "Volume.vl: 既定値 30", "--only", "chain")

    def test_chain_default_not_allowed_or_option(self):
        with TempDir() as tmp:
            build(tmp)

            def fn(d):
                d["effects"][1]["params"][3]["default"] = 3
                d["effects"][1]["params"][1]["default"] = "hp"
            self.mutate_effects(tmp, fn)
            code, out = self.run_check(tmp, "--only", "chain")
        self.assertEqual(code, 1)
        self.assertIn("allowed", out)
        self.assertIn("選択肢に無い", out)

    def test_chain_array_default_count(self):
        with TempDir() as tmp:
            build(tmp)
            self.mutate_effects(tmp, lambda d: d["effects"][1]["params"][0].update(default=[100]))
            self.assertProblem(tmp, "count 2", "--only", "chain")

    def test_chain_duplicate_nm_and_missing_md(self):
        with TempDir() as tmp:
            build(tmp)

            def fn(d):
                d["effects"].append(dict(d["effects"][0], category="lofi"))
            self.mutate_effects(tmp, fn)
            code, out = self.run_check(tmp, "--only", "chain")
        self.assertIn("nm Volume が2つある", out)
        self.assertIn("lofi.md が無い", out)

    def test_chain_index_lacks_effect(self):
        with TempDir() as tmp:
            build(tmp)
            write(tmp / "chain/v0.11.0/index.md", "## basics ([basics.md](basics.md))\n- `Volume`\n")
            code, out = self.run_check(tmp, "--only", "chain")
        self.assertIn("index.md に 5Band PEQ が無い", out)
        self.assertIn("index.md に Matrix が無い", out)

    def test_chain_folder_and_dsp_disagree(self):
        with TempDir() as tmp:
            build(tmp)
            self.mutate_effects(tmp, lambda d: d.update(dsp="0.10.0"))
            self.assertProblem(tmp, "v0.11.0: dsp が '0.10.0'", "--only", "chain")

    # ---- versions

    def test_badge_mismatch(self):
        with TempDir() as tmp:
            build(tmp)
            write(tmp / "README.md", "![x](https://img.shields.io/badge/EffeTune%20DSP-0.10.0-3B82F6)\n")
            self.assertProblem(tmp, "README のバッジ 0.10.0", "--only", "versions")

    def test_chain_md_names_old_version(self):
        with TempDir() as tmp:
            build(tmp)
            write(tmp / "CHAIN.md", CHAIN_MD.replace("dsp-v0.11.0", "dsp-v0.10.0"))
            self.assertProblem(tmp, "dsp-v0.10.0", "--only", "versions")

    def test_chain_md_example_uses_unknown_key(self):
        with TempDir() as tmp:
            build(tmp)
            write(tmp / "CHAIN.md", CHAIN_MD.replace('"f0":200', '"f7":200').replace('"vl":-3', '"vl":-90'))
            code, out = self.run_check(tmp, "--only", "versions")
        self.assertIn("5Band PEQ に鍵 f7 は無い", out)
        self.assertIn("Volume.vl=-90 は範囲の外", out)

    def test_upstream_folder_missing(self):
        with TempDir() as tmp:
            build(tmp)
            write(tmp / "Sources/EffeTuneLive/Generated/UpstreamVersion.swift", 'let ETUpstreamVersion = "0.12.0"\n')
            self.assertProblem(tmp, "chain/v0.12.0/ が無い", "--only", "versions")

    # ---- store

    def test_store_text_over_limit_counts_lf(self):
        with TempDir() as tmp:
            build(tmp)
            # 3990 字 + 改行 10 個。CRLF で書いてもバイトでは数えない（4000 字ちょうどは通る）。
            text = ("x" * 398 + "\n") * 10 + "y" * 10
            self.assertEqual(len(text), 4000)
            (tmp / "Tools/review_notes.txt").write_bytes(text.replace("\n", "\r\n").encode())
            code, out = self.run_check(tmp, "--only", "store")
            self.assertEqual(code, 0, out)
            (tmp / "Tools/review_notes.txt").write_bytes((text + "z").encode())
            self.assertProblem(tmp, "4001 字", "--only", "store")

    # ---- urls

    def test_url_old_privacy_link_flagged(self):
        # 以前アプリは nemut.ai/effetune-live/privacy.html（古いポリシーへ飛ぶ）を開いていた。
        with TempDir() as tmp:
            build(tmp)
            write(tmp / "Sources/EffeTuneLive/Views/SettingsView.swift",
                  SETTINGS + 'let old = "https://nemut.ai/effetune-live/privacy.html"\n')
            self.assertProblem(tmp, "nemut.ai はこのリポジトリの site が返す宛先ではない", "--only", "urls")

    def test_url_unknown_route_flagged(self):
        with TempDir() as tmp:
            build(tmp)
            write(tmp / "Sources/EffeTuneLive/Views/SettingsView.swift",
                  SETTINGS + 'let bad = "https://effectdeck.nemut.ai/privacy.html"\n')
            self.assertProblem(tmp, "この道（/privacy.html）", "--only", "urls")

    def test_url_github_blob_must_exist(self):
        with TempDir() as tmp:
            build(tmp)
            write(tmp / "Sources/EffeTuneLive/Views/SettingsView.swift",
                  SETTINGS + 'let doc2 = "https://github.com/satomasahiro2005/EffectDeck/blob/main/JSFX.md"\n')
            self.assertProblem(tmp, "リポジトリに JSFX.md が無い", "--only", "urls")
            write(tmp / "JSFX.md", "# JSFX\n")
            self.assertEqual(self.run_check(tmp, "--only", "urls")[0], 0)

    def test_url_allowlisted_prefix(self):
        with TempDir() as tmp:
            build(tmp)
            write(tmp / "Sources/EffeTuneLive/Views/SettingsView.swift",
                  SETTINGS + 'let alt = "https://nemut.ai/altstore/source.json"\n')
            write(tmp / "Tools/check_repo_allow.txt", "url:https://nemut.ai/altstore/  # 別のサイト\n")
            self.assertEqual(self.run_check(tmp, "--only", "urls")[0], 0)

    # ---- names

    def test_names_must_contain_stem(self):
        with TempDir() as tmp:
            build(tmp)
            write(tmp / "Sources/Shared/ETNames.h", NAMES_H.replace('ET_ROUTE_NAME "EffectDeck"',
                                                                     'ET_ROUTE_NAME "EffeTune"'))
            self.assertProblem(tmp, "ET_ROUTE_NAME 'EffeTune'", "--only", "names")

    def test_names_swift_copy_must_match(self):
        with TempDir() as tmp:
            build(tmp)
            write(tmp / "Sources/EffeTuneLive/Audio/FeedbackLoop.swift",
                  'enum FeedbackLoop {\n    static let nameStem = "EffeTune"\n}\n')
            self.assertProblem(tmp, "nameStem = 'EffeTune'", "--only", "names")
            write(tmp / "Sources/EffeTuneLive/Audio/FeedbackLoop.swift",
                  'enum FeedbackLoop {\n    static let nameStem: String = "EffectDeck"\n}\n')
            self.assertEqual(self.run_check(tmp, "--only", "names")[0], 0)

    # ---- notice

    def test_notice_lists_every_license(self):
        with TempDir() as tmp:
            build(tmp)
            write(tmp / "NOTICE.md", "# What is bundled\n\n## EffeTune\n")
            self.assertProblem(tmp, "NOTICE.md に WDL / LICE", "--only", "notice")

    # ---- drag（etOwnsDrag の印）

    VIEW = "Sources/EffeTuneLive/Views/Effects/X.swift"

    def drag_result(self, swift, rel=VIEW):
        with TempDir() as tmp:
            build(tmp)
            write(tmp / rel, swift)
            return self.run_check(tmp, "--only", "drag")

    def test_drag_unmarked_gesture_flagged_with_line(self):
        code, out = self.drag_result(
            "struct V: View {\n"
            "    var body: some View {\n"
            "        Color.clear\n"
            "            .gesture(DragGesture(minimumDistance: 6)\n"
            "                .onChanged { _ in })\n"
            "    }\n"
            "}\n")
        self.assertEqual(code, 1, out)
        self.assertIn("Sources/EffeTuneLive/Views/Effects/X.swift:4 の DragGesture(", out)
        self.assertIn("etOwnsDrag-exempt", out)

    def test_drag_mark_after_gesture_passes(self):
        code, out = self.drag_result(
            "struct V: View {\n"
            "    var body: some View {\n"
            "        Color.clear\n"
            "            .gesture(DragGesture(minimumDistance: 6)\n"
            "                .onChanged { _ in })\n"
            "            .onChange(of: a) { _, _ in }\n"
            "            .etOwnsDrag()\n"
            "    }\n"
            "}\n")
        self.assertEqual(code, 0, out)

    def test_drag_mark_on_ancestor_passes(self):
        # JSFX の面のように、ジェスチャは GeometryReader の中、印は GeometryReader の後ろ。
        code, out = self.drag_result(
            "struct V: View {\n"
            "    var body: some View {\n"
            "        GeometryReader { g in\n"
            "            Color.black\n"
            "                .gesture(DragGesture(minimumDistance: 0))\n"
            "                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in }\n"
            "        }\n"
            "        .modifier(Layout(a: x ? 1 : nil))\n"
            "        .clipped()\n"
            "        .etOwnsDrag()\n"
            "        .onDisappear { }\n"
            "    }\n"
            "}\n")
        self.assertEqual(code, 0, out)

    def test_drag_mark_on_sibling_does_not_cover(self):
        # 同じファイルに印が在るだけでは足りない。1 か所ごとに見る。
        code, out = self.drag_result(
            "struct V: View {\n"
            "    var body: some View {\n"
            "        ZStack {\n"
            "            Color.clear\n"
            "                .gesture(DragGesture(minimumDistance: 0))\n"
            "                .etOwnsDrag()\n"
            "            Color.red\n"
            "                .gesture(DragGesture(minimumDistance: 1))\n"
            "        }\n"
            "    }\n"
            "}\n")
        self.assertEqual(code, 1, out)
        self.assertIn("X.swift:8 の DragGesture(", out)
        self.assertNotIn("X.swift:5", out)

    def test_drag_exempt_comment_above_modifier_passes(self):
        code, out = self.drag_result(
            "struct V: View {\n"
            "    var body: some View {\n"
            "        // 読むだけ。\n"
            "        Color.clear\n"
            "            // etOwnsDrag-exempt: 読むだけで何も動かさない\n"
            "            // （理由の続き）\n"
            "            .simultaneousGesture(\n"
            "                DragGesture(minimumDistance: 0)\n"
            "                    .onChanged { _ in })\n"
            "    }\n"
            "}\n")
        self.assertEqual(code, 0, out)

    def test_drag_exempt_trailing_comment_passes(self):
        code, out = self.drag_result(
            "struct V: View {\n"
            "    var body: some View {\n"
            "        Color.clear.gesture(DragGesture()) // etOwnsDrag-exempt: 診断用\n"
            "    }\n"
            "}\n")
        self.assertEqual(code, 0, out)

    def test_drag_exempt_needs_reason(self):
        code, out = self.drag_result(
            "struct V: View {\n"
            "    var body: some View {\n"
            "        // etOwnsDrag-exempt:\n"
            "        Color.clear.gesture(DragGesture())\n"
            "    }\n"
            "}\n")
        self.assertEqual(code, 1, out)
        self.assertIn("X.swift:4 の DragGesture(", out)

    def test_drag_exempt_far_above_does_not_count(self):
        # 離れた別の文の免除は、このジェスチャのものではない。
        code, out = self.drag_result(
            "struct V: View {\n"
            "    var body: some View {\n"
            "        // etOwnsDrag-exempt: 上のぶん\n"
            "        Color.clear.gesture(DragGesture())\n"
            "            .etOwnsDrag()\n"
            "        Color.red\n"
            "            .frame(width: 1)\n"
            "            .gesture(DragGesture())\n"
            "    }\n"
            "}\n")
        self.assertEqual(code, 1, out)
        self.assertIn("X.swift:8 の DragGesture(", out)

    def test_drag_gesture_returning_func_follows_use_site(self):
        marked = (
            "struct V: View {\n"
            "    var body: some View {\n"
            "        Color.clear\n"
            "            .gesture(drag(in: plot))\n"
            "            .etOwnsDrag()\n"
            "    }\n"
            "    private func drag(in plot: P) -> some Gesture {\n"
            "        DragGesture(minimumDistance: 0)\n"
            "            .onChanged { _ in }\n"
            "    }\n"
            "}\n")
        self.assertEqual(self.drag_result(marked)[0], 0)
        code, out = self.drag_result(marked.replace("            .etOwnsDrag()\n", ""))
        self.assertEqual(code, 1, out)
        self.assertIn("X.swift:7 の DragGesture(", out)
        self.assertIn("使う側", out)

    def test_drag_gesture_returning_func_unused_flagged(self):
        code, out = self.drag_result(
            "struct V: View {\n"
            "    private func drag() -> some Gesture {\n"
            "        DragGesture()\n"
            "    }\n"
            "}\n")
        self.assertEqual(code, 1, out)

    def test_drag_gesture_returning_func_exempt_above_decl(self):
        code, out = self.drag_result(
            "struct V: View {\n"
            "    // etOwnsDrag-exempt: 鎖の外の画面\n"
            "    private func drag() -> some Gesture {\n"
            "        LongPressGesture().sequenced(before: DragGesture())\n"
            "    }\n"
            "}\n")
        self.assertEqual(code, 0, out)

    def test_drag_ignores_comments_strings_taps_and_other_folders(self):
        code, out = self.drag_result(
            "struct V: View {\n"
            "    // DragGesture( を使わない\n"
            "    var body: some View {\n"
            "        Text(\"DragGesture(\\(x)\")\n"
            "            .onTapGesture { }\n"
            "            .onDrag { NSItemProvider() }\n"
            "    }\n"
            "}\n")
        self.assertEqual(code, 0, out)
        code, out = self.drag_result("let g = DragGesture()\n", rel="Sources/EffeTuneLive/Audio/Y.swift")
        self.assertEqual(code, 0, out)

    def test_drag_magnification_gesture_flagged(self):
        code, out = self.drag_result(
            "struct V: View {\n"
            "    var body: some View {\n"
            "        Color.clear.gesture(MagnificationGesture())\n"
            "    }\n"
            "}\n")
        self.assertEqual(code, 1, out)
        self.assertIn("MagnificationGesture(", out)

    # ---- paths

    def test_dead_path_flagged(self):
        with TempDir() as tmp:
            build(tmp)
            write(tmp / "docs/c.md", "See `Scripts/gone.sh` and `docs/au-post-insert.md`.\n")
            code, out = self.run_check(tmp, "--only", "paths")
        self.assertEqual(code, 1)
        self.assertIn("Scripts/gone.sh が無い（docs/c.md:1）", out)
        self.assertIn("docs/au-post-insert.md が無い", out)

    def test_dead_path_suffix_relative_and_template(self):
        with TempDir() as tmp:
            build(tmp)
            write(tmp / "Sources/EffeTuneLive/DSP/X.swift",
                  "// Generated/UpstreamVersion.swift と chain/v<版>/ と chain/v\\(v) と Tests/Unit/JSFX*Tests.swift\n"
                  "// docs/shot-${name}.png と Sources/.../EffectSpec.swift\n")
            self.assertEqual(self.run_check(tmp, "--only", "paths")[0], 0)

    def test_dead_path_suffix_only_for_generated(self):
        # 末尾一致で在ると見なすのは Generated/…（Sources/EffeTuneLive/Generated の略し書き）だけ。
        # Tools/x を Tests/Tools/x で在ると取ると、消えたファイルを見逃し、試験が作った
        # Tests/Tools/__pycache__ の有る無しで結果が変わる（clone したての木で落ちた）。
        with TempDir() as tmp:
            build(tmp)
            write(tmp / "Tests/Tools/helper.py", "# test helper\n")
            write(tmp / "Tests/Tools/__pycache__/helper.cpython-312.pyc", "")
            write(tmp / "docs/c.md", "See `Tools/helper.py` and `Tools/__pycache__`.\n")
            code, out = self.run_check(tmp, "--only", "paths")
        self.assertEqual(code, 1, out)
        self.assertIn("Tools/helper.py が無い（docs/c.md:1）", out)
        self.assertIn("Tools/__pycache__ が無い（docs/c.md:1）", out)

    def test_dead_path_glued_to_japanese(self):
        # 日本語に続けて書いたパス（字の間に空白を入れない書き方）も拾う。
        with TempDir() as tmp:
            build(tmp)
            write(tmp / "docs/c.md", "手順はScripts/gone.shにある。README はTools/gen_catalog.pyを指す。\n")
            code, out = self.run_check(tmp, "--only", "paths")
        self.assertEqual(code, 1, out)
        self.assertIn("Scripts/gone.sh が無い（docs/c.md:1）", out)
        self.assertNotIn("gen_catalog.py が無い", out)

    def test_dead_path_allowlist_needs_reason(self):
        with TempDir() as tmp:
            build(tmp)
            write(tmp / "docs/c.md", "Upstream `docs/plugins/control.md`.\n")
            write(tmp / "Tools/check_repo_allow.txt", "docs/plugins/control.md\n")
            code, out = self.run_check(tmp, "--only", "paths")
            self.assertIn("理由が無い", out)
            write(tmp / "Tools/check_repo_allow.txt", "docs/plugins/control.md  # 上流の docs\n")
            self.assertEqual(self.run_check(tmp, "--only", "paths")[0], 0)

    @unittest.skipUnless(have_git(), "git が無い")
    def test_dead_path_gitignored_is_local(self):
        # .gitignore に当たるもの（手元のログ・生成物）は在るものとして扱う。追跡していないだけで消えてはいない。
        with TempDir() as tmp:
            build(tmp)
            env = hermetic_git_env(tmp)
            write(tmp / ".gitignore", "docs/connect-log.md\nGenerated/note-models/\n")
            write(tmp / "docs/c.md", "Log: `docs/connect-log.md`, models: `Generated/note-models`.\n")
            git(tmp, "init", "-q", "-b", "main", env=env)
            git(tmp, "add", ".", env=env)
            with env_patch(GIT_CONFIG_GLOBAL=env["GIT_CONFIG_GLOBAL"], GIT_CONFIG_NOSYSTEM="1"):
                code, out = self.run_check(tmp, "--only", "paths")
        self.assertEqual(code, 0, out)

    def test_unknown_check_name_is_usage_error(self):
        with TempDir() as tmp, quiet():
            with self.assertRaises(SystemExit) as cm:
                self.cr.main(["--root", str(tmp), "--only", "nope"])
        self.assertEqual(cm.exception.code, 2)

    def test_only_vendor_runs_the_vendor_check(self):
        # --only vendor だけで --version-guard を忘れても、何も見ずに ok と言わない。
        with TempDir() as tmp:
            build(tmp)
            self.assertProblem(tmp, "gitlink が無い", "--only", "vendor")

    def test_only_base_without_base_is_usage_error(self):
        with TempDir() as tmp, quiet():
            with self.assertRaises(SystemExit) as cm:
                self.cr.main(["--root", str(tmp), "--only", "base"])
        self.assertEqual(cm.exception.code, 2)


@unittest.skipUnless(have_git(), "git が無い")
class GitCheckTests(unittest.TestCase):
    """--version-guard と --base。一時リポジトリで確かめる。"""

    def setUp(self):
        self.cr = load_tool("check_repo")

    def make(self, tmp, tag="dsp-v0.11.0", shallow=False):
        env = hermetic_git_env(tmp)
        upstream = tmp / "upstream"
        upstream.mkdir()
        git(upstream, "init", "-q", "-b", "main", env=env)
        write(upstream / "a", "1\n")
        git(upstream, "add", ".", env=env)
        git(upstream, "commit", "-q", "-m", "one", env=env)
        write(upstream / "a", "2\n")
        git(upstream, "commit", "-q", "-am", "two", env=env)
        git(upstream, "tag", tag, env=env)
        pin = git(upstream, "rev-parse", "HEAD", env=env)
        sup = tmp / "super"
        build(sup)
        (sup / "Vendor").mkdir()
        args = ["clone", "-q"] + (["--depth", "1"] if shallow else []) + [upstream.as_uri(), "effetune"]
        git(sup / "Vendor", *args, env=env)
        git(sup, "init", "-q", "-b", "main", env=env)
        git(sup, "add", "--", ".", ":!Vendor", env=env)
        git(sup, "update-index", "--add", "--cacheinfo", "160000,%s,Vendor/effetune" % pin, env=env)
        git(sup, "commit", "-q", "-m", "base", env=env)
        return env, sup

    def run_check(self, env, root, *extra):
        with env_patch(GIT_CONFIG_GLOBAL=env["GIT_CONFIG_GLOBAL"], GIT_CONFIG_NOSYSTEM="1"), \
                quiet() as (out, err):
            code = self.cr.main(["--root", str(root), *extra])
        return code, out.getvalue()

    def test_version_guard_matches(self):
        with TempDir() as tmp:
            env, sup = self.make(tmp)
            code, out = self.run_check(env, sup, "--version-guard", "--only", "vendor")
        self.assertEqual(code, 0, out)

    def test_vendor_pin_rejects_old_tag(self):
        with TempDir() as tmp:
            env, sup = self.make(tmp, tag="dsp-v0.10.0")
            code, out = self.run_check(env, sup, "--version-guard", "--only", "vendor")
        self.assertEqual(code, 1)
        self.assertIn("dsp-v0.10.0、UpstreamVersion は 0.11.0", out)

    def test_version_guard_rejects_shallow(self):
        with TempDir() as tmp:
            env, sup = self.make(tmp, shallow=True)
            code, out = self.run_check(env, sup, "--version-guard", "--only", "vendor")
        self.assertEqual(code, 1)
        self.assertIn("浅い clone", out)

    def test_version_guard_reads_staged_gitlink(self):
        # 上流へ追従している途中（Vendor を進めて git add Vendor/effetune し、setup.sh が
        # UpstreamVersion を書き換えた。まだコミットしていない）。gen_catalog.check_vendor_pin と
        # 同じく index の gitlink を固定として読む。HEAD の gitlink を読むと 0.11.0 と食い違って落ちる。
        with TempDir() as tmp:
            env, sup = self.make(tmp)
            upstream = tmp / "upstream"
            write(upstream / "a", "3\n")
            git(upstream, "commit", "-q", "-am", "three", env=env)
            git(upstream, "tag", "dsp-v0.12.0", env=env)
            new = git(upstream, "rev-parse", "HEAD", env=env)
            git(sup / "Vendor/effetune", "fetch", "-q", "--tags", "origin", env=env)
            git(sup, "update-index", "--cacheinfo", "160000,%s,Vendor/effetune" % new, env=env)
            write(sup / "Sources/EffeTuneLive/Generated/UpstreamVersion.swift",
                  'let ETUpstreamVersion = "0.12.0"\n')
            write(sup / "chain/v0.12.0/effects.json", json.dumps({"dsp": "0.12.0"}))
            code, out = self.run_check(env, sup, "--version-guard", "--only", "vendor")
        self.assertEqual(code, 0, out)

    def test_chain_folder_tampered_against_base(self):
        with TempDir() as tmp:
            env, sup = self.make(tmp)
            path = sup / "chain/v0.11.0/effects.json"
            path.write_text(path.read_text("utf-8").replace("0123456789abcdef", "fedcba9876543210"),
                            encoding="utf-8")
            code, out = self.run_check(env, sup, "--base", "HEAD", "--only", "base")
            self.assertEqual(code, 1)
            self.assertIn("dspParams が 0123456789abcdef から fedcba9876543210", out)

    def test_chain_folder_deleted_against_base(self):
        with TempDir() as tmp:
            env, sup = self.make(tmp)
            write(sup / "chain/v0.12.0/effects.json", json.dumps({"dsp": "0.12.0"}))
            for f in (sup / "chain/v0.11.0").iterdir():
                f.unlink()
            (sup / "chain/v0.11.0").rmdir()
            code, out = self.run_check(env, sup, "--base", "HEAD", "--only", "base")
        self.assertEqual(code, 1)
        self.assertIn("chain/v0.11.0/ が消えている", out)


if __name__ == "__main__":
    unittest.main()
