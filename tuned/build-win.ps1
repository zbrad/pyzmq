# platform: windows
# Native Windows build of the zbrad pyzmq +ipc wheel: libzmq (bundled, static) with its IPC (AF_UNIX) transport and
# epoll (wepoll) poller, which upstream's PyPI Windows wheels turn off (pyzmq#1981). One cp312 abi3 wheel, usable on
# Python 3.12+. No containers, no cibuildwheel; steps follow upstream's own [tool.cibuildwheel] recipe in
# pyproject.toml: fetch the bundled libraries' licenses, build with the static MSVC runtime, abi3audit, then
# tools/test_wheel.py in a clean venv (it asserts zmq.has("ipc")).
# Needs: uv, git, Visual Studio Build Tools (CMake's VS generator finds them), network for the libzmq/libsodium
# tarballs. usage: pwsh -File tuned\build-win.ps1 [-OutDir dist] [-Python 3.14]
param(
    [string]$OutDir = (Join-Path $PSScriptRoot '..\dist'),
    [string]$Python = '3.14'
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ts = { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
Write-Host "=== pyzmq-ipc win start $(& $ts) HEAD $(git -C $repo log --oneline -1)"
if (git -C $repo status --porcelain --untracked-files=no) { throw "tracked changes in $repo; build from a clean commit" }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

# The bundled libzmq/libsodium licenses go into the wheel (libzmq is MPL-2.0); upstream's before-all step.
Push-Location $repo
try {
    uv run --no-project --python $Python python buildutils/bundle.py licenses
    if ($LASTEXITCODE) { throw 'license fetch failed' }
    uv build --wheel --python $Python --out-dir $OutDir . `
        -C 'cmake.define.ZMQ_PREFIX=bundled' `
        -C 'cmake.define.CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded' `
        -C 'cmake.define.CMAKE_SHARED_LINKER_FLAGS=ucrt.lib;vcruntime.lib;/nodefaultlib:libucrt.lib;/nodefaultlib:libvcruntime.lib' `
        -C 'wheel.py-api=cp312' `
        -C 'build.verbose=true'
    if ($LASTEXITCODE) { throw 'build failed' }
} finally { Pop-Location }

$version = (Select-String -Path (Join-Path $repo 'pyproject.toml') -Pattern '^version = "(.+)"').Matches[0].Groups[1].Value
$wheel = Get-ChildItem $OutDir -Filter "pyzmq-$version-cp312-abi3-win*.whl" | Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $wheel) { throw "no pyzmq-$version-cp312-abi3-win*.whl in $OutDir" }
Write-Host "wheel: $($wheel.Name)"

# A fresh directory per run under the (gitignored) out dir; nothing is deleted.
$testDir = Join-Path $OutDir ".test-win-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmss'))"
$venv = Join-Path $testDir 'venv'
New-Item -ItemType Directory $testDir | Out-Null

# abi3audit in its own venv, as in tuned/build-lnx.sh (`uv run --with` can see a base interpreter's packages).
$audit = Join-Path $testDir 'audit'
uv venv --python $Python $audit
uv pip install --python "$audit\Scripts\python.exe" abi3audit
if ($LASTEXITCODE) { throw 'abi3audit install failed' }
& "$audit\Scripts\abi3audit.exe" --strict --report $wheel.FullName
if ($LASTEXITCODE) { throw 'abi3audit failed' }

# tools/test_wheel.py in a clean venv, run from outside the source tree so it imports the installed wheel.
uv venv --python $Python $venv
uv pip install --python "$venv\Scripts\python.exe" $wheel.FullName pytest importlib_metadata
if ($LASTEXITCODE) { throw 'test venv install failed' }
Copy-Item -LiteralPath (Join-Path $repo 'tools\test_wheel.py') -Destination $testDir -Force
Push-Location $testDir
try {
    & "$venv\Scripts\python.exe" -m pytest -v -p no:cacheprovider test_wheel.py
    if ($LASTEXITCODE) { throw 'tools/test_wheel.py failed' }
} finally { Pop-Location }
Write-Host "PYZMQ-IPC-WIN-DONE $(& $ts) $($wheel.FullName)"
