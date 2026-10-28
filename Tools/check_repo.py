#!/usr/bin/env python3
"""リポジトリの中の事実どうしが食い違っていないかを確かめる。stdlib だけ、読むだけ。

  python3 Tools/check_repo.py                    Vendor の要らない検査だけ
  python3 Tools/check_repo.py --version-guard    固定した Vendor/effetune のタグとも突き合わせる
  python3 Tools/check_repo.py --base origin/main 前の版から chain/v* が消えていないか・形が変わっていないか
  python3 Tools/check_repo.py --only chain,urls  名前を挙げた検査だけ

見るもの（名前は --only に渡すもの）:

  chain       chain/v*/effects.json の中身（既定値が範囲と選択肢に入る・名前と鍵が重ならない・
              分類ごとの .md と index.md が揃う・index.md のリンクが生きている）
  versions    UpstreamVersion.swift の版 = README のバッジ = CHAIN.md の chain/v*・dsp-v*・例の版、
              chain/v<版>/ が在る、CHAIN.md の例の鎖が語彙どおり
  vendor      （--version-guard）Vendor/effetune の固定した版（index の gitlink、無ければ HEAD の）の dsp-v* タグ = 上の版
  base        （--base）前の版にあった chain/v*/ が消えていない、dspParams が変わっていない
  store       店に出す文面（What's New・審査メモ・ベータの文面）が 4000 字以内（改行は LF で1字）
  urls        Swift のコードにある URL が site/src/worker.js の返す道に当たる。nemut.ai の別の宛先
              （古いプライバシーポリシーの nemut.ai/effetune-live/privacy.html など）は止める。
              github の EffectDeck/blob/main/<path> は <path> が在る
  names       ETNames.h の ET_ROUTE_NAME と ET_DRIVER_NAME が ET_NAME_STEM を含む。Swift に写しがあれば同じ字
  notice      gen_licenses.py の ITEMS が全部 NOTICE.md に書いてある
  drag        Views の SwiftUI のドラッグ系ジェスチャ（DragGesture( など）が etOwnsDrag() で覆われている。
              覆わない面は `// etOwnsDrag-exempt: 理由` を書く（DragHandle.swift の etOwnsDrag の説明）
  paths       ドキュメントとコメントが挙げているリポジトリの中のパスが在る
              （.gitignore に当たるもの＝手元のログや生成物は在るものとして扱う）。
              消せない引用は Tools/check_repo_allow.txt に理由つきで書く

一つでも引っかかれば 1 で終わる。
"""
import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent

STORE_TEXTS = [
    ("Tools/store_notes.txt", "What's New", 4000),
    ("Tools/review_notes.txt", "審査メモ（Notes）", 4000),
    ("Tools/beta_notes.txt", "What to Test", 4000),
]

# ドキュメントとコメントが挙げるパスの頭。Vendor/ は上流の木なので見ない。
PATH_HEADS = ("Sources", "Scripts", "Tools", "Tests", "docs", "Patches", "Generated", "chain", "site",
              "Licenses")
# 前の字は ASCII だけで見る。\w は日本語にも当たるので、空白を挟まず日本語に続けたパス
# （このリポジトリの書き方）を拾えない。
CITED_PATH = re.compile(r"(?<![A-Za-z0-9_/.-])((?:%s)/[A-Za-z0-9_./-]*[A-Za-z0-9_])" % "|".join(PATH_HEADS))
# 途中を略して書く頭。Generated/<名前> は Sources/EffeTuneLive/Generated/<名前> のこと。
# これだけ末尾の一致で在ると見なす。ほかの頭まで許すと、Tools の下で消えたファイルを
# Tests/Tools の下の同じ名前で在ると取って見逃す。
SHORT_HEADS = ("Generated",)
SCANNED_SUFFIXES = (".md", ".sh", ".py", ".yml", ".yaml", ".swift", ".m", ".mm", ".h", ".c", ".cpp",
                    ".mjs", ".js", ".toml", ".plist", ".txt", ".json", ".entitlements")
# 見ないところ。上流の写し・生成物・試験の材料・この検査自身の試験（わざと死んだパスを書く）。
SKIPPED_PREFIXES = ("Vendor/", "Tests/Fixtures/", "Tests/Tools/", "chain/", "site/package-lock.json",
                    "Tools/check_repo_allow.txt")

SITE_HOSTS_DEFAULT = ("effectdeck.nemut.ai", "fxd.nemut.ai", "fxdb.nemut.ai")
OWNED_DOMAIN = "nemut.ai"
REPO_SLUG = "satomasahiro2005/EffectDeck"
URL = re.compile(r"https?://[A-Za-z0-9.-]+(?::\d+)?(?:/[^\s\"'<>()\\`]*)?")


class Repo:
    """検査が読む木。git の作業ツリーなら git に聞き、そうでなければフォルダを歩く。"""

    def __init__(self, root):
        self.root = pathlib.Path(root).resolve()
        self.is_git = self._git_ok()
        self._files = None

    def git(self, *args, cwd=None):
        try:
            return subprocess.run(["git", *args], cwd=str(cwd or self.root),
                                  capture_output=True, text=True, encoding="utf-8", errors="replace")
        except OSError:
            return None

    def _git_ok(self):
        r = self.git("rev-parse", "--show-toplevel")
        if not r or r.returncode != 0:
            return False
        return (os.path.normcase(os.path.realpath(r.stdout.strip()))
                == os.path.normcase(os.path.realpath(str(self.root))))

    @property
    def files(self):
        """追跡しているファイルと、まだ add していないが無視もしていないファイル（/ 区切り）。"""
        if self._files is None:
            names = []
            if self.is_git:
                r = self.git("ls-files", "-z", "--cached", "--others", "--exclude-standard")
                if r and r.returncode == 0:
                    names = [n for n in r.stdout.split("\0") if n]
            else:
                for dirpath, dirnames, filenames in os.walk(self.root):
                    dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules", "build", "Vendor")]
                    for f in filenames:
                        rel = pathlib.Path(dirpath, f).relative_to(self.root).as_posix()
                        names.append(rel)
            self._files = sorted(n for n in names if (self.root / n).is_file())
        return self._files

    def read(self, rel):
        return (self.root / rel).read_text(encoding="utf-8")

    def exists(self, rel):
        return (self.root / rel).exists()

    def ignored(self, paths):
        """.gitignore に当たるものの集合。git でなければ空。"""
        if not self.is_git or not paths:
            return set()
        try:
            r = subprocess.run(["git", "check-ignore", "--no-index", "--stdin", "-z"], cwd=str(self.root),
                               input="\0".join(paths) + "\0", capture_output=True, text=True,
                               encoding="utf-8", errors="replace")
        except OSError:
            return set()
        return {p for p in r.stdout.split("\0") if p}


# ---------------------------------------------------------------- 版

def upstream_version(repo):
    m = re.search(r'ETUpstreamVersion\s*=\s*"([^"]+)"',
                  repo.read("Sources/EffeTuneLive/Generated/UpstreamVersion.swift"))
    return m.group(1) if m else None


def check_versions(repo, args):
    bad = []
    up = upstream_version(repo)
    if not up:
        return ["UpstreamVersion.swift から ETUpstreamVersion を読めない"]
    readme = repo.read("README.md") if repo.exists("README.md") else ""
    m = re.search(r"badge/EffeTune%20DSP-(.+?)-[0-9A-Fa-f]{6}\)", readme)
    badge = m.group(1).replace("--", "-") if m else None
    if badge != up:
        bad.append("README のバッジ %s が UpstreamVersion %s と違う（python3 Tools/gen_version.py）" % (badge, up))
    if not repo.exists("chain/v%s/effects.json" % up):
        bad.append("chain/v%s/ が無い（python3 Tools/gen_catalog.py）" % up)
    if repo.exists("CHAIN.md"):
        text = repo.read("CHAIN.md")
        for v in sorted(set(re.findall(r"chain/v(\d+\.\d+\.\d+)", text))):
            if v != up:
                bad.append("CHAIN.md が chain/v%s を指している（UpstreamVersion は %s）" % (v, up))
        for v in sorted(set(re.findall(r"dsp-v(\d+\.\d+\.\d+)", text))):
            if v != up:
                bad.append("CHAIN.md が dsp-v%s を指している（UpstreamVersion は %s）" % (v, up))
        for v in sorted(set(re.findall(r"\(EffeTune DSP (\d+\.\d+\.\d+)\)", text))):
            if v != up:
                bad.append("CHAIN.md の例が EffeTune DSP %s と書いている（UpstreamVersion は %s）" % (v, up))
        for rel in sorted(set(re.findall(r"\]\((chain/[^)#\s]+)\)", text))):
            if not repo.exists(rel):
                bad.append("CHAIN.md のリンク先 %s が無い" % rel)
        bad += check_chain_example(repo, text, up)
    return bad


def check_chain_example(repo, chain_md, up):
    """CHAIN.md の最初の json の塊（例の鎖）が語彙どおりか。"""
    path = repo.root / "chain" / ("v" + up) / "effects.json"
    blocks = re.findall(r"```json\n(.*?)\n```", chain_md.replace("\r\n", "\n"), re.S)
    if not blocks or not path.exists():
        return []
    vocab = {e["nm"]: e for e in json.loads(path.read_text(encoding="utf-8"))["effects"]}
    bad = []
    try:
        chain = json.loads(blocks[0])
    except ValueError as e:
        return ["CHAIN.md の例の鎖が JSON として読めない: %s" % e]
    for stage in chain if isinstance(chain, list) else []:
        nm = stage.get("nm")
        if nm == "Section":
            continue
        e = vocab.get(nm)
        if e is None or "unsupported" in e:
            bad.append("CHAIN.md の例: 使えない nm %r" % nm)
            continue
        keys = {p["key"]: p for p in e["params"] if p["shape"] in ("scalar", "flat")}
        for p in e["params"]:
            if p["shape"] == "indexed":
                for i in range(p["count"]):
                    keys["%s%d" % (p["key"], i)] = dict(p, shape="scalar")
            elif p["shape"] == "object-array":
                keys[p["array"]] = dict(p, shape="object-array")
        for k, v in stage.items():
            if k in ("nm", "en", "cm", "ch"):
                continue
            p = keys.get(k)
            if p is None:
                bad.append("CHAIN.md の例: %s に鍵 %s は無い" % (nm, k))
            elif p["shape"] != "scalar":
                continue
            elif p["kind"] == "number" and not (isinstance(v, (int, float)) and p["min"] <= v <= p["max"]):
                bad.append("CHAIN.md の例: %s.%s=%r は範囲の外" % (nm, k, v))
            elif p["kind"] == "enum" and v not in p["options"]:
                bad.append("CHAIN.md の例: %s.%s=%r は選択肢に無い" % (nm, k, v))
    return bad


def check_vendor(repo, args):
    """固定した版（index の gitlink、無ければ HEAD の）の dsp-v* タグ = UpstreamVersion。

    index を先に読むのは gen_catalog.check_vendor_pin と同じ理由。上流へ追従するときは Vendor を
    進めて git add Vendor/effetune してから setup.sh を回す（UpstreamVersion が新しい版になる）。
    コミットする前に HEAD の gitlink と比べると、古い版と食い違って落ちる。
    """
    up = upstream_version(repo)
    pin = None
    r = repo.git("ls-files", "--stage", "--", "Vendor/effetune")
    m = re.search(r"^160000 ([0-9a-f]{40}) 0\t", r.stdout if r and r.returncode == 0 else "", re.M)
    if m:
        pin = m.group(1)
    else:
        r = repo.git("ls-tree", "HEAD", "Vendor/effetune")
        m = re.search(r"\b160000 commit ([0-9a-f]{40})\b", r.stdout if r and r.returncode == 0 else "")
        if m:
            pin = m.group(1)
    if not pin:
        return ["index にも HEAD にも Vendor/effetune の gitlink が無い"]
    vendor = repo.root / "Vendor" / "effetune"
    shallow = repo.git("rev-parse", "--is-shallow-repository", cwd=vendor)
    if not shallow or shallow.returncode != 0:
        return ["Vendor/effetune が git の作業ツリーでない（git submodule update --init --filter=blob:none Vendor/effetune）"]
    if shallow.stdout.strip() == "true":
        return ["Vendor/effetune が浅い clone で、dsp-v* のタグを信用できない"
                "（git submodule update --init --filter=blob:none Vendor/effetune）"]
    d = repo.git("describe", "--tags", "--match", "dsp-v*", pin, cwd=vendor)
    if not d or d.returncode != 0:
        return ["固定した版 %s から dsp-v* のタグを辿れない（%s）"
                % (pin[:8], (d.stderr.strip() if d else "git が無い"))]
    tag = d.stdout.strip().removeprefix("dsp-v").split("-")[0]
    bad = []
    if tag != up:
        bad.append("固定した Vendor/effetune（%s）は dsp-v%s、UpstreamVersion は %s" % (pin[:8], tag, up))
    if not repo.exists("chain/v%s/effects.json" % tag):
        bad.append("固定した版の chain/v%s/ が無い" % tag)
    if d.stdout.strip() != "dsp-v" + tag:
        print("note: 固定した版はタグの間（%s）。版はその前のタグ %s として扱う" % (d.stdout.strip(), tag))
    return bad


def check_base(repo, args):
    """前の版にあった chain/v*/ が消えていない・dspParams が変わっていない。"""
    base = args.base
    r = repo.git("ls-tree", "-d", "--name-only", base, "chain/")
    if not r or r.returncode != 0:
        return ["--base %s を読めない（%s）" % (base, r.stderr.strip() if r else "git が無い")]
    bad = []
    for folder in r.stdout.split():
        name = folder.rstrip("/").split("/")[-1]
        if not name.startswith("v"):
            continue
        now = repo.root / "chain" / name / "effects.json"
        if not now.exists():
            bad.append("chain/%s/ が消えている。古いビルドの依頼文は古い版を名指しするので消さない" % name)
            continue
        old = repo.git("show", "%s:chain/%s/effects.json" % (base, name))
        if not old or old.returncode != 0:
            continue
        try:
            before = json.loads(old.stdout).get("dspParams")
            after = json.loads(now.read_text(encoding="utf-8")).get("dspParams")
        except ValueError:
            bad.append("chain/%s/effects.json が JSON として読めない" % name)
            continue
        if before != after:
            bad.append("chain/%s/ の dspParams が %s から %s に変わった。同じ版のフォルダを別のパラメータで上書きしない"
                       % (name, before, after))
    return bad


# ---------------------------------------------------------------- 語彙（chain/）

def check_chain(repo, args):
    bad = []
    chain = repo.root / "chain"
    if not chain.is_dir():
        return ["chain/ が無い"]
    for d in sorted(p for p in chain.iterdir() if p.is_dir()):
        folder = d.name
        try:
            data = json.loads((d / "effects.json").read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            bad.append("%s/effects.json を読めない: %s" % (folder, e))
            continue
        if "v" + str(data.get("dsp", "")) != folder:
            bad.append("%s: dsp が %r" % (folder, data.get("dsp")))
        if not re.fullmatch(r"[0-9a-f]{16}", str(data.get("dspParams", ""))):
            bad.append("%s: dspParams が %r" % (folder, data.get("dspParams")))
        cats, names = [], set()
        for e in data.get("effects", []):
            nm = e.get("nm")
            if nm in names:
                bad.append("%s: nm %s が2つある" % (folder, nm))
            names.add(nm)
            if e.get("category") not in cats:
                cats.append(e.get("category"))
            bad += check_params(folder, e)
        md = {p.name for p in d.glob("*.md")}
        expect = {c + ".md" for c in cats} | {"index.md"}
        for name in sorted(expect - md):
            bad.append("%s: %s が無い" % (folder, name))
        for name in sorted(md - expect):
            bad.append("%s: どの分類でもない %s がある" % (folder, name))
        if "index.md" in md:
            index = (d / "index.md").read_text(encoding="utf-8")
            for n in sorted(names):
                if "- `%s`" % n not in index:
                    bad.append("%s: index.md に %s が無い" % (folder, n))
            for link in re.findall(r"\]\(([^)#]+\.md)\)", index):
                if not (d / link).resolve().exists():
                    bad.append("%s: index.md のリンク先 %s が無い" % (folder, link))
        for c in cats:
            p = d / (c + ".md")
            if p.exists():
                text = p.read_text(encoding="utf-8")
                for e in data.get("effects", []):
                    if e.get("category") == c and "\n## %s\n" % e["nm"] not in text:
                        bad.append("%s: %s.md に ## %s が無い" % (folder, c, e["nm"]))
    return bad


def check_params(folder, e):
    bad = []
    keys = set()
    where = "%s %s" % (folder, e.get("nm"))
    for p in e.get("params", []):
        k = (p.get("array"), p.get("key"))
        if k in keys:
            bad.append("%s: 鍵 %s が2つある" % (where, p.get("key")))
        keys.add(k)
        default = p.get("default")
        values = default if isinstance(default, list) else [default]
        if p.get("shape") != "scalar":
            if not isinstance(default, list) or len(default) != p.get("count"):
                bad.append("%s.%s: 既定値の数が count %s と合わない" % (where, p.get("key"), p.get("count")))
        for v in values:
            kind = p.get("kind")
            if kind == "number":
                if not isinstance(v, (int, float)) or isinstance(v, bool) or not (p["min"] <= v <= p["max"]):
                    bad.append("%s.%s: 既定値 %r が [%s, %s] の外" % (where, p.get("key"), v, p.get("min"), p.get("max")))
                elif "allowed" in p and v not in p["allowed"]:
                    bad.append("%s.%s: 既定値 %r が allowed %s に無い" % (where, p.get("key"), v, p["allowed"]))
            elif kind == "enum":
                if v not in p.get("options", []):
                    bad.append("%s.%s: 既定値 %r が選択肢に無い" % (where, p.get("key"), v))
            elif kind == "toggle":
                if not isinstance(v, bool):
                    bad.append("%s.%s: 入切の既定値 %r" % (where, p.get("key"), v))
            else:
                bad.append("%s.%s: kind %r" % (where, p.get("key"), kind))
    return bad


# ---------------------------------------------------------------- 店の文面

def check_store(repo, args):
    bad = []
    for rel, what, limit in STORE_TEXTS:
        if not repo.exists(rel):
            continue
        # Windows の作業ツリーは CRLF になっていることがある。店は改行を1字と数える。
        text = repo.read(rel).replace("\r\n", "\n")
        if len(text) > limit:
            bad.append("%s（%s）が %d 字で、上限 %d 字を超える" % (rel, what, len(text), limit))
    return bad


# ---------------------------------------------------------------- URL

def site_routes(repo):
    """worker.js が返す道と、site の宛先の名前。"""
    worker = "site/src/worker.js"
    if not repo.exists(worker):
        return None, SITE_HOSTS_DEFAULT
    text = repo.read(worker)
    routes = set(re.findall(r'case\s+"(/[^"]*)"\s*:', text))
    m = re.search(r"AASA_PATHS\s*=\s*new Set\(\[([^\]]*)\]", text)
    if m:
        routes |= set(re.findall(r'"(/[^"]*)"', m.group(1)))
    hosts = SITE_HOSTS_DEFAULT
    if repo.exists("site/src/links.js"):
        links = repo.read("site/src/links.js")
        found = tuple(re.findall(r'export const (?:DECK|LINK|DISCORD)_HOST\s*=\s*"([^"]+)"', links))
        if found:
            hosts = found
    return routes, hosts


def allowlist(repo):
    """Tools/check_repo_allow.txt。`パス  # 理由` と `url:接頭辞  # 理由`。理由の無い行は受けない。"""
    paths, urls, bad = {}, {}, []
    rel = "Tools/check_repo_allow.txt"
    if not repo.exists(rel):
        return paths, urls, bad
    for n, line in enumerate(repo.read(rel).splitlines(), 1):
        body, _, why = line.partition("#")
        body = body.strip()
        if not body:
            continue
        if not why.strip():
            bad.append("%s:%d: 理由が無い（`%s  # 理由`）" % (rel, n, body))
            continue
        if body.startswith("url:"):
            urls[body[4:]] = why.strip()
        else:
            paths[body] = why.strip()
    return paths, urls, bad


def check_urls(repo, args):
    routes, hosts = site_routes(repo)
    _, allowed_urls, _ = allowlist(repo)
    files = set(repo.files)
    bad = []
    for rel in repo.files:
        if not rel.startswith("Sources/") or not rel.endswith((".swift", ".m", ".plist")):
            continue
        for n, line in enumerate(repo.read(rel).splitlines(), 1):
            for url in URL.findall(line):
                url = url.rstrip(".,;:")
                if any(url.startswith(a) for a in allowed_urls):
                    continue
                u = urllib.parse.urlsplit(url)
                host = u.hostname or ""
                where = "%s:%d %s" % (rel, n, url)
                if host in hosts:
                    path = u.path or "/"
                    if routes is not None and path not in routes:
                        bad.append("%s: site/src/worker.js はこの道（%s）を返さない" % (where, path))
                elif host == OWNED_DOMAIN or host.endswith("." + OWNED_DOMAIN):
                    bad.append("%s: %s はこのリポジトリの site が返す宛先ではない（%s）"
                               % (where, host, " / ".join(hosts)))
                elif host == "github.com" or host == "raw.githubusercontent.com":
                    m = re.match(r"^/%s/(?:(?:blob|tree|raw)/)?main/(.+)$" % re.escape(REPO_SLUG), u.path)
                    if m:
                        target = urllib.parse.unquote(m.group(1)).rstrip("/")
                        if target not in files and not any(f.startswith(target + "/") for f in files):
                            bad.append("%s: リポジトリに %s が無い" % (where, target))
    return bad


# ---------------------------------------------------------------- 名前

def check_names(repo, args):
    rel = "Sources/Shared/ETNames.h"
    if not repo.exists(rel):
        return ["%s が無い" % rel]
    text = repo.read(rel)
    macros = dict(re.findall(r'^\s*#define\s+(ET_\w+)\s+"([^"]*)"', text, re.M))
    stem = macros.get("ET_NAME_STEM")
    if not stem:
        return ["%s に ET_NAME_STEM が無い" % rel]
    bad = []
    for name in ("ET_ROUTE_NAME", "ET_DRIVER_NAME"):
        v = macros.get(name)
        if v is None:
            bad.append("%s に %s が無い" % (rel, name))
        elif stem.lower() not in v.lower():
            bad.append("%s %r が ET_NAME_STEM %r を含まない（折り返しの判定が自分を見失う）" % (name, v, stem))
    # Swift 側の写し（純粋なファイルに置いた nameStem など）。あれば同じ字であること。
    copy = re.compile(r'\b(?:let|var)\s+(\w*[Nn]ame[Ss]tem\w*)\s*(?::\s*String)?\s*=\s*"([^"]*)"')
    for f in repo.files:
        if f.startswith("Sources/") and f.endswith(".swift"):
            for m in copy.finditer(repo.read(f)):
                if m.group(2) != stem:
                    bad.append("%s: %s = %r が ET_NAME_STEM %r と違う" % (f, m.group(1), m.group(2), stem))
    return bad


# ---------------------------------------------------------------- NOTICE

def load_license_items(repo):
    path = repo.root / "Tools" / "gen_licenses.py"
    if not path.exists():
        return None
    import importlib.util
    spec = importlib.util.spec_from_file_location("check_repo_gen_licenses", path)
    mod = importlib.util.module_from_spec(spec)
    # 読むだけの検査なので、生成器の横に .pyc を残さない。
    keep, sys.dont_write_bytecode = sys.dont_write_bytecode, True
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.dont_write_bytecode = keep
    return list(mod.ITEMS)


def squash(s):
    return re.sub(r"[^0-9a-z]", "", s.lower())


def check_notice(repo, args):
    items = load_license_items(repo)
    if items is None:
        return []
    if not repo.exists("NOTICE.md"):
        return ["NOTICE.md が無い"]
    notice = squash(repo.read("NOTICE.md"))
    bad = []
    for name, lic, author, rel in items:
        if rel == "LICENSE":
            continue    # このアプリ自身
        if squash(name) not in notice:
            bad.append("NOTICE.md に %s（%s、gen_licenses.py の ITEMS）が無い" % (name, lic))
    return bad


# ---------------------------------------------------------------- パス

def check_paths(repo, args):
    files = repo.files
    fileset = set(files)
    dirs = set()
    for f in files:
        parts = f.split("/")
        for i in range(1, len(parts)):
            dirs.add("/".join(parts[:i]))
    allowed, _, bad = allowlist(repo)

    def resolves(cited, citing):
        if cited in fileset or cited in dirs or cited + ".swift" in fileset:
            return True
        rel = os.path.normpath(os.path.join(os.path.dirname(citing), cited)).replace(os.sep, "/")
        if rel in fileset or rel in dirs:
            return True
        if cited.split("/", 1)[0] not in SHORT_HEADS:
            return False
        tail = "/" + cited
        return any(f.endswith(tail) for f in files) or any(d.endswith(tail) for d in dirs)

    unresolved = {}
    for rel in files:
        if rel.startswith(SKIPPED_PREFIXES) or not rel.endswith(SCANNED_SUFFIXES):
            continue
        try:
            text = repo.read(rel)
        except (UnicodeDecodeError, OSError):
            continue
        for n, line in enumerate(text.splitlines(), 1):
            for m in CITED_PATH.finditer(line):
                cited = m.group(1).rstrip(".")
                after = line[m.end():m.end() + 2]
                # 型や版を差し込む書き方（chain/v<版>、chain/v\(版)、chain/v%s、JSFX*Tests、shot-${name}）は
                # 名指しではない。
                if "..." in cited or after[:1] in ("*", "<", "{", "$", "…", "\\", "%", "(") \
                        or after in ("-*", "-$", "-<", "-{"):
                    continue
                if cited in allowed or resolves(cited, rel):
                    continue
                unresolved.setdefault(cited, []).append("%s:%d" % (rel, n))
    # 「フォルダだけ」の無視（Generated/note-models/）は、フォルダがまだ無い木では / を付けないと当たらない。
    probe = sorted(unresolved) + [c + "/" for c in sorted(unresolved)]
    ignored = {p.rstrip("/") for p in repo.ignored(probe)}
    for cited in sorted(unresolved):
        if cited in ignored:
            continue
        where = unresolved[cited]
        bad.append("%s が無い（%s%s）" % (cited, ", ".join(where[:3]),
                                        " ほか %d か所" % (len(where) - 3) if len(where) > 3 else ""))
    if getattr(args, "verbose", False):
        for cited in sorted(allowed):
            if resolves(cited, ""):
                print("note: 許可の表の %s はもう在る（Tools/check_repo_allow.txt から外せる）" % cited)
    return bad


# ---------------------------------------------------------------- ドラッグの印

# 指の動きを受ける SwiftUI のジェスチャ。onTapGesture・LongPressGesture 単独は動かさないので見ない
# （長押し→ドラッグの組は DragGesture( が当たる）。onDrag（並べ替えの取っ手）もこの規則の外。
DRAG_GESTURE = re.compile(r"\b(?:DragGesture|MagnificationGesture|MagnifyGesture|RotateGesture|RotationGesture)\s*\(")
DRAG_EXEMPT = re.compile(r"etOwnsDrag-exempt:[ \t]*(\S[^\n]*)")
DRAG_VIEWS_PREFIX = "Sources/EffeTuneLive/Views/"
# `{` の頭がこれなら宣言（View や関数の本体）。印を探して祖先を遡るのはここまで。
DRAG_DECL_HEAD = re.compile(r"\b(?:func|var|let|struct|class|enum|extension|init|subscript|protocol)\b|->[^{}]*$")


def swift_code_only(text):
    """コメントと文字列の中身を空白に置き換えた同じ長さの文。括弧の数えを狂わせないため。"""
    out = list(text)
    n = len(text)

    def blank(a, b):
        for k in range(a, min(b, n)):
            if out[k] != "\n":
                out[k] = " "

    i = 0
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif text.startswith('"""', i):
            j = text.find('"""', i + 3)
            end = n if j < 0 else j
            blank(i + 3, end)
            i = end + 3
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] not in '"\n':
                if text.startswith("\\(", j):
                    depth, j = 1, j + 2    # 文字列の中の式。中の括弧も閉じまで飛ばす
                    while j < n and depth:
                        depth += {"(": 1, ")": -1}.get(text[j], 0)
                        j += 1
                else:
                    j += 2 if text[j] == "\\" else 1
            blank(i + 1, j)
            i = j + 1
        else:
            i += 1
    return "".join(out)


_PAIRS = {")": "(", "]": "[", "}": "{"}


def _enclosing_open(code, pos):
    """pos を囲む、閉じていない開き括弧の位置。無ければ -1。"""
    depth = {"(": 0, "[": 0, "{": 0}
    for k in range(pos - 1, -1, -1):
        c = code[k]
        if c in _PAIRS:
            depth[_PAIRS[c]] += 1
        elif c in depth:
            if depth[c]:
                depth[c] -= 1
            else:
                return k
    return -1


def _match_close(code, op):
    """開き括弧 op に対応する閉じ括弧の位置。無ければ -1。"""
    stack = []
    for k in range(op, len(code)):
        c = code[k]
        if c in "([{":
            stack.append(c)
        elif c in _PAIRS:
            if not stack:
                return -1
            stack.pop()
            if not stack:
                return k
    return -1


_MODIFIER = re.compile(r"\s*\.\s*(\w+)")
_CLOSURE = re.compile(r"[ \t]*\{")
_LABELED_CLOSURE = re.compile(r"\s*\w+\s*:\s*\{")


def _chain_has_mark(code, close):
    """閉じ括弧 close の直後に続く .modifier の連なりに .etOwnsDrag() が在るか。"""
    pos = close + 1
    while True:
        m = _MODIFIER.match(code, pos)
        if not m:
            return False
        name, pos = m.group(1), m.end()
        if code[pos:pos + 1] == "(":
            if name == "etOwnsDrag":
                return True
            end = _match_close(code, pos)
            if end < 0:
                return False
            pos = end + 1
        m = _CLOSURE.match(code, pos)
        while m:    # 後ろ付きの閉じ（onGeometryChange(...) { } action: { } も）
            end = _match_close(code, m.end() - 1)
            if end < 0:
                return False
            pos = end + 1
            m = _LABELED_CLOSURE.match(code, pos)


def _drag_covered(code, pos):
    """pos の位置の式が .etOwnsDrag() に覆われているか。

    返すのは (覆われている, 遡りが止まった宣言の `{` の位置または -1)。
    式の後ろに続く .modifier と、それを囲む括弧・閉じの後ろに続く .modifier を、
    宣言（var body・func）の本体に着くまで見る。"""
    cur = pos
    while True:
        op = _enclosing_open(code, cur)
        if op < 0:
            return False, -1
        if code[op] == "{":
            head = code[code.rfind("\n", 0, op) + 1:op]
            if DRAG_DECL_HEAD.search(head):
                return False, op
        end = _match_close(code, op)
        if end >= 0 and _chain_has_mark(code, end):
            return True, -1
        cur = op


def _line_of(text, pos):
    return text.count("\n", 0, pos) + 1


def _drag_exempt(lines, numbers):
    """numbers（1 始まり）の行の末尾か、その真上の // のかたまりに理由つきの免除が在るか。
    理由の無い `etOwnsDrag-exempt:` は免除にしない。"""
    for ln in numbers:
        if not 1 <= ln <= len(lines):
            continue
        m = DRAG_EXEMPT.search(lines[ln - 1])
        if m and "//" in lines[ln - 1][:m.start()]:
            return True
        i = ln - 2
        while i >= 0 and lines[i].lstrip().startswith("//"):
            if DRAG_EXEMPT.search(lines[i]):
                return True
            i -= 1
    return False


def drag_problems(text):
    """1 つの Swift ファイルの、印も免除も無いドラッグ系ジェスチャの (行, 名前, func 経由か)。"""
    code = swift_code_only(text)
    lines = text.split("\n")
    bad = []
    for m in DRAG_GESTURE.finditer(code):
        name = m.group(0).rstrip("( \t\n")
        ln = _line_of(text, m.start())
        covered, decl = _drag_covered(code, m.start())
        heads = [ln]
        first = _enclosing_open(code, m.start())
        if first >= 0 and code[first] == "(":
            heads.append(_line_of(text, first))    # .gesture( を開いた行
        via_func = False
        if not covered and decl >= 0:
            # `some Gesture` を返す func / var の中。印は使う側（.gesture(drag(...))）に付く。
            decl_m = None
            for decl_m in re.finditer(r"\b(func|var)\s+(\w+)", code[:decl]):
                pass
            if decl_m and re.search(r"\bGesture\b", code[decl_m.start():decl]):
                via_func = True
                heads.append(_line_of(text, decl_m.start()))
                kind, ident = decl_m.group(1), decl_m.group(2)
                use = re.compile(r"\b%s\s*\(" % ident if kind == "func" else r"\b%s\b" % ident)
                uses = [u for u in use.finditer(code)
                        if not (decl_m.start() <= u.start() < decl)]
                covered = bool(uses) and all(_drag_covered(code, u.start())[0] for u in uses)
        if covered or _drag_exempt(lines, heads):
            continue
        bad.append((ln, name, via_func))
    return bad


def check_drag(repo, args):
    """カードの中の面が指の動きを SwiftUI のジェスチャで受けるなら、その面は etOwnsDrag() の印を敷く。

    鎖の長押し（並べ替え）と横の払い（削除）は UIScrollView の認識器で、UIKit の部品は当たりで
    見つかるが、SwiftUI のジェスチャは見えない。印が無いと指が行の掴みや払いにも渡る。
    ファイルごとでなく 1 か所ごとに見る。"""
    bad = []
    for rel in repo.files:
        if not rel.startswith(DRAG_VIEWS_PREFIX) or not rel.endswith(".swift"):
            continue
        try:
            text = repo.read(rel).replace("\r\n", "\n")
        except (UnicodeDecodeError, OSError):
            continue
        for ln, name, via_func in drag_problems(text):
            bad.append("%s:%d の %s( に .etOwnsDrag() が続いていない%s。印を付けるか、"
                       "その行かすぐ上の // に `// etOwnsDrag-exempt: 理由` を書く"
                       % (rel, ln, name, "（使う側の .gesture(...) を見た）" if via_func else ""))
    return bad


CHECKS = [
    ("chain", check_chain),
    ("versions", check_versions),
    ("store", check_store),
    ("urls", check_urls),
    ("names", check_names),
    ("notice", check_notice),
    ("drag", check_drag),
    ("paths", check_paths),
]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=str(ROOT), help="確かめる木（既定はこのリポジトリ）")
    ap.add_argument("--version-guard", action="store_true",
                    help="固定した Vendor/effetune の dsp-v* タグとも突き合わせる（タグの取れる submodule が要る）")
    ap.add_argument("--base", help="この版と比べて chain/v*/ が消えていないか・dspParams が同じかを見る")
    ap.add_argument("--only", help="走らせる検査の名前（, 区切り）")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)

    wanted = [w.strip() for w in (args.only or "").split(",") if w.strip()]
    known = {n for n, _ in CHECKS} | {"vendor", "base"}
    unknown = [w for w in wanted if w not in known]
    if unknown:
        ap.error("知らない検査: %s（%s）" % (", ".join(unknown), ", ".join(sorted(known))))
    # --only vendor は --version-guard と同じ。--only base は比べる版が要る（黙って何もしないで ok と言わない）。
    if "vendor" in wanted:
        args.version_guard = True
    if "base" in wanted and not args.base:
        ap.error("--only base には --base <版> が要る")

    repo = Repo(args.root)
    checks = list(CHECKS)
    if args.version_guard:
        checks.append(("vendor", check_vendor))
    if args.base:
        checks.append(("base", check_base))
    if wanted:
        checks = [(n, f) for n, f in checks if n in wanted]

    problems = 0
    for name, func in checks:
        found = func(repo, args)
        for p in found:
            print("!! [%s] %s" % (name, p))
        problems += len(found)
    if problems:
        print("check_repo: %d 件" % problems)
        return 1
    print("check_repo: ok（%s）" % ", ".join(n for n, _ in checks))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
