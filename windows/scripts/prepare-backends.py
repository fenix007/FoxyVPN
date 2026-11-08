#!/usr/bin/env python3
"""Build pinned Windows backends; usable from Windows, macOS and Linux."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "windows" / ".build"
SOURCES = BUILD / "sources"
FIREFOX_COMMIT = "55ad91a2ccea1c93e69c82a08a7681e279884db5"
SING_COMMIT = "c005f35300ce76427dc285481ec5695f5b179cd2"


def run(*args, cwd=None, env=None):
    subprocess.run(args, cwd=cwd, env=env, check=True)


def checkout(name, repository, revision):
    path = SOURCES / name
    if not (path / ".git").is_dir():
        if path.exists():
            raise RuntimeError(f"Source directory already exists: {path}")
        path.mkdir(parents=True)
        run("git", "init", "--quiet", str(path))
        run("git", "remote", "add", "origin", repository, cwd=path)
        run("git", "fetch", "--quiet", "--depth", "1", "origin", revision, cwd=path)
        run("git", "checkout", "--quiet", "--detach", "FETCH_HEAD", cwd=path)
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=path, text=True).strip()
    if actual != revision:
        raise RuntimeError(f"Unexpected source revision at {path}: {actual}")
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=["amd64", "arm64"], default="amd64")
    parser.add_argument("--go", default=os.environ.get("FOXYVPN_GO_BIN", "go"))
    parser.add_argument("--skip-tests", action="store_true", help="Use only after running the backend tests separately")
    args = parser.parse_args()
    go = shutil.which(args.go)
    if not go:
        raise RuntimeError("Go 1.26+ is required; install Go or set FOXYVPN_GO_BIN")
    firefox = checkout("firefox-vpn-client", "https://github.com/UjuiUjuMandan/firefox-vpn-client.git", FIREFOX_COMMIT)
    sing = checkout("sing-box", "https://github.com/SagerNet/sing-box.git", SING_COMMIT)
    patch = ROOT / "macos" / "Backend" / "firefox-vpn-client-macos.patch"
    check = subprocess.run(["git", "apply", "--check", str(patch)], cwd=firefox, capture_output=True)
    if check.returncode == 0:
        run("git", "apply", str(patch), cwd=firefox)
    else:
        run("git", "apply", "--reverse", "--check", str(patch), cwd=firefox)
    expected = {"cmd/proxy-demo/main.go", "cmd/proxy-demo/main_test.go", "firefox_identity_test.go", "fxa.go", "tokens.go", "tokens_test.go"}
    changed = set(subprocess.check_output(["git", "diff", "--name-only"], cwd=firefox, text=True).splitlines())
    if changed != expected:
        raise RuntimeError(f"Unexpected backend changes: {changed}")
    if subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard"], cwd=firefox).strip():
        raise RuntimeError("Unexpected untracked files in Firefox backend source")
    run("git", "diff", "--exit-code", cwd=sing)
    if subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard"], cwd=sing).strip():
        raise RuntimeError("Unexpected untracked files in sing-box source")
    env = os.environ.copy()
    env.pop("GOOS", None)
    env.pop("GOARCH", None)
    env["CGO_ENABLED"] = "0"
    env.setdefault("GOCACHE", str(BUILD / "go-cache"))
    env.setdefault("GOMODCACHE", str(BUILD / "go-mod-cache"))
    if not args.skip_tests:
        run(go, "test", "./...", cwd=firefox, env=env)
    env.update(GOOS="windows", GOARCH=args.arch)
    output = BUILD / "backends" / args.arch
    output.mkdir(parents=True, exist_ok=True)
    run(go, "build", "-trimpath", "-buildvcs=false", "-o", str(output / "foxyvpn-proxy.exe"), "./cmd/proxy-demo", cwd=firefox, env=env)
    run(go, "build", "-trimpath", "-buildvcs=false", "-o", str(output / "sing-box.exe"), "./cmd/sing-box", cwd=sing, env=env)
    print(f"Windows {args.arch} backends: {output}")


if __name__ == "__main__":
    main()
