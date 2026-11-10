#!/usr/bin/env bash
# platform: linux
# Native Linux build of the zbrad pyzmq +ipc wheel (x86_64 or aarch64, whichever host runs it): libzmq and
# libsodium bundled and linked statically, as on Windows (tuned/build-win.ps1), so the wheel needs no libzmq.so.
# One cp312 abi3 wheel, usable on Python 3.12+, tagged linux_<arch> (built on this host's glibc; not a manylinux
# wheel). No containers. Then abi3audit and tools/test_wheel.py in a clean venv (it asserts zmq.has("ipc")).
# Needs: uv, git, cc/c++, make, network for the libzmq/libsodium tarballs.
# usage: tuned/build-lnx.sh [out-dir] [python]
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-${repo}/dist}"
python="${2:-3.12}"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
echo "=== pyzmq-ipc lnx start $(ts) HEAD $(git -C "${repo}" log --oneline -1) $(uname -m)"
if [[ -n "$(git -C "${repo}" status --porcelain --untracked-files=no)" ]]; then
    echo "ERROR: tracked changes in ${repo}; build from a clean commit" >&2
    exit 1
fi
mkdir -p "${out}"
out="$(cd "${out}" && pwd)"

cd "${repo}"
# The bundled libzmq/libsodium licenses go into the wheel (libzmq is MPL-2.0); upstream's before-all step.
uv run --no-project --python "${python}" python buildutils/bundle.py licenses
# Upstream's Linux CFLAGS (pyproject [tool.cibuildwheel.linux.environment]).
CFLAGS="-O3 -Wl,-strip-all" CXXFLAGS="-O3 -Wl,-strip-all" \
uv build --wheel --python "${python}" --out-dir "${out}" . \
    -C cmake.define.ZMQ_PREFIX=bundled \
    -C wheel.py-api=cp312 \
    -C build.verbose=true

version="$(sed -n 's/^version = "\(.*\)"$/\1/p' pyproject.toml)"
wheel="$(ls -t "${out}"/pyzmq-"${version}"-cp312-abi3-linux_"$(uname -m)".whl | head -1)"
echo "wheel: $(basename "${wheel}")"

# A fresh directory per run under the (gitignored) out dir; nothing is deleted.
test_dir="$(mktemp -d "${out}/.test-lnx-$(uname -m)-XXXXXX")"

# abi3audit in its own venv: `uv run --with` over a distro Python can import the distro's
# dist-packages (seen on Ubuntu 24.04: python3-openssl's cryptography panics under 3.14).
uv venv -q --python "${python}" "${test_dir}/audit"
uv pip install -q --python "${test_dir}/audit/bin/python" abi3audit
"${test_dir}/audit/bin/abi3audit" --strict --report "${wheel}"

# No libzmq/libsodium shared library may be needed at run time: they are linked in statically.
python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "${wheel}" "${test_dir}/whl"
if ldd "${test_dir}"/whl/zmq/backend/cython/_zmq*.so | grep -Ei 'zmq|sodium'; then
    echo "ERROR: the extension links a shared libzmq/libsodium" >&2
    exit 1
fi

# tools/test_wheel.py in a clean venv, run from outside the source tree so it imports the installed wheel.
uv venv -q --python "${python}" "${test_dir}/venv"
uv pip install -q --python "${test_dir}/venv/bin/python" "${wheel}" pytest importlib_metadata
cp tools/test_wheel.py "${test_dir}/"
(cd "${test_dir}" && venv/bin/python -m pytest -v -p no:cacheprovider test_wheel.py)
echo "PYZMQ-IPC-LNX-DONE $(ts) ${wheel}"
