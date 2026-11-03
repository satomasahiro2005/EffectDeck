"""Tests/Tools の共通の道具。stdlib だけ。

    python -m unittest discover -s Tests/Tools

生成器（Tools/*.py）はスクリプトとして書いてあるので、パスから読み込んで
モジュールの定数（入口と出口のパス）を一時フォルダへ向け直して試す。
git を使う試験は、利用者の設定（署名・フック・既定のブランチ名）に左右されないよう
空の設定で走らせる（hermetic_git_env）。
"""
import contextlib
import importlib.util
import io
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
TOOLS = ROOT / "Tools"

_loaded = 0


def load_tool(name):
    """Tools/<name>.py を毎回新しいモジュールとして読む（定数を書き換えても他の試験へ漏れない）。"""
    global _loaded
    _loaded += 1
    path = TOOLS / (name + ".py")
    spec = importlib.util.spec_from_file_location("tool_%s_%d" % (name, _loaded), path)
    mod = importlib.util.module_from_spec(spec)
    # Tools/__pycache__ を作らない（試験のたびに生成器のフォルダへ .pyc が増える）。
    keep, sys.dont_write_bytecode = sys.dont_write_bytecode, True
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.dont_write_bytecode = keep
    return mod


class TempDir:
    """with で使う一時フォルダ。pathlib.Path を返す。"""

    def __enter__(self):
        self.path = pathlib.Path(tempfile.mkdtemp(prefix="ettools-"))
        return self.path

    def __exit__(self, *exc):
        shutil.rmtree(self.path, ignore_errors=True)
        return False


def write(path, text):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")
    return path


def hermetic_git_env(home):
    """利用者の git 設定を読まない環境。コミットの名前だけ入れる。"""
    empty = pathlib.Path(home) / "gitconfig-empty"
    if not empty.exists():
        empty.write_text("", encoding="utf-8")
    env = dict(os.environ)
    env.update({
        "GIT_CONFIG_GLOBAL": str(empty),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
        "GIT_TERMINAL_PROMPT": "0",
    })
    env.pop("GIT_DIR", None)
    env.pop("GIT_WORK_TREE", None)
    env.pop("GIT_INDEX_FILE", None)
    return env


def git(cwd, *args, env=None, check=True):
    r = subprocess.run(["git", *args], cwd=str(cwd), env=env, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise AssertionError("git %s failed: %s" % (" ".join(args), r.stderr))
    return r.stdout.strip()


def have_git():
    return shutil.which("git") is not None


def have_node():
    return shutil.which("node") is not None


def vendor_at_pin(name, *paths):
    """Vendor/<name> がこのリポジトリの固定した版（index か HEAD の gitlink）で、paths に手が無いか。

    作業ツリーの Vendor には別の版の checkout や setup.sh のパッチが混ざることがある
    （この木の Vendor/effetune は固定が 0.11.0 なのに 0.10.0 のままだった）。そのまま比べると、
    追跡している生成物のせいにして落ちる。固定した版でなければ比べずに飛ばす。
    """
    if not have_git():
        return False
    vendor = ROOT / "Vendor" / name

    def out(cwd, *args):
        try:
            r = subprocess.run(["git", *args], cwd=str(cwd), capture_output=True, text=True,
                               encoding="utf-8", errors="replace")
        except OSError:
            return None
        return r.stdout.strip() if r.returncode == 0 else None

    if not vendor.is_dir():
        return False
    # 取っていない submodule（空のフォルダ）では git が外のリポジトリを答えるので、木の根を確かめる。
    top = out(vendor, "rev-parse", "--show-toplevel")
    try:
        if not top or not os.path.samefile(top, str(vendor)):
            return False
    except OSError:
        return False
    head = out(vendor, "rev-parse", "HEAD")
    pins = set()
    for args in (("ls-files", "--stage", "--", "Vendor/" + name), ("ls-tree", "HEAD", "Vendor/" + name)):
        m = re.search(r"\b([0-9a-f]{40})\b", out(ROOT, *args) or "")
        if m:
            pins.add(m.group(1))
    if not head or head not in pins:
        return False
    if paths:
        # Windows の checkout（CRLF）を WSL の git で見ると、改行だけの違いを手が入ったと取ることがある
        # （index の stat が古いとき）。改行は揃えて比べる。
        dirty = out(vendor, "-c", "core.autocrlf=input", "status", "--porcelain", "--", *paths)
        if dirty is None or dirty:
            return False
    return True


@contextlib.contextmanager
def env_patch(**values):
    """os.environ を一時的に書き換える。None は消す。"""
    old = {k: os.environ.get(k) for k in values}
    try:
        for k, v in values.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        yield
    finally:
        for k, v in old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


@contextlib.contextmanager
def quiet():
    """生成器の print を捨てる。捕まえた中身は戻り値の2つの StringIO で読める。"""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        yield out, err


def run_main(func, *args):
    """main() を呼び、戻り値か SystemExit の code を返す（0 は None と同じ扱い）。"""
    try:
        code = func(*args)
    except SystemExit as e:
        code = e.code
    if code is None:
        return 0
    if isinstance(code, str):
        sys.stderr.write(code + "\n")   # sys.exit("...") と同じく字は stderr へ
        return 1
    return code


def swift_raw_text(hashes, body):
    """#…#\"\"\"…\"\"\"#…# の 1 行の中身を Swift の読み方で読む（生成器が埋めた JSON を読み戻す）。

    生文字列でも \\ に同じ数の # が続けばエスケープ（\\#n は改行、\\#( は埋め込み）で、
    \"\"\" に同じ数の # が続けばそこで閉じる。どちらかが中身にあれば、Swift は書いた字の
    とおりには読まない（コンパイルが通っても JSON が壊れる）ので、読み戻しを止める。
    """
    for bad in ("\\" + hashes, '"""' + hashes):
        if bad in body:
            raise AssertionError("%s\"\"\" の中に %s がある。Swift はそのまま読まない: %s"
                                 % (hashes, bad, body[:80]))
    return body


__all__ = ["ROOT", "TOOLS", "load_tool", "TempDir", "write", "hermetic_git_env", "git",
           "have_git", "have_node", "vendor_at_pin", "env_patch", "quiet", "run_main", "swift_raw_text", "unittest",
           "sys"]
