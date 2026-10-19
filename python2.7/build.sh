#!/usr/bin/env bash
# Build Python 2.7.18 deb package for Debian 13 (trixie), fully offline.
#
# Inputs (read-only):
#   /src/2.7        source cache (Python tarball, pip trio wheels, get-pip)
#   /src/patches    patch files applied to the Python source tree
#
# Outputs:
#   /out/py27.deb   the final deb package
#
# Design notes are in openspec/changes/build-python27-debian13/design.md (D1-D10).
set -euo pipefail

SRC_DIR=${SRC_DIR:-/src/2.7}
PATCH_DIR=${PATCH_DIR:-/src/patches}
OUT_DIR=${OUT_DIR:-/out}
BUILD_ROOT=${BUILD_ROOT:-/build}
PREFIX=/usr/local
NPROC=$(nproc)

# PGO training workload: a curated set of interpreter-core and stdlib tests.
#
# Why not the upstream default (the whole regrtest suite): on trixie it hangs
# indefinitely (verified: test_poplib busy-loops at 99% CPU), and the full suite
# is needlessly slow (~20+ min). This curated list exercises the interpreter hot
# paths, runs in well under a minute, and has been verified to complete with no
# hang (design D3). Regrtest ignores individual failures under --pgo.
PROFILE_TESTS="test_grammar test_dict test_list test_tuple test_int test_long \
test_float test_unicode test_math test_re test_struct test_binascii \
test_json test_pickle test_difflib test_heapq test_sort test_iter \
test_generators test_exceptions test_types test_class test_descr \
test_funcattrs test_scope test_compile test_import test_os test_posix \
test_file test_io test_tempfile test_textwrap test_string test_strptime \
test_time test_datetime test_decimal test_fractions test_calendar \
test_random test_zlib test_sqlite test_hashlib test_sha test_md5 test_hmac \
test_base64 test_codecs test_unicode_file test_csv test_cfgparser \
test_argparse test_StringIO test_bufio test_subprocess test_threading"
PROFILE_TASK="-m test.regrtest --pgo ${PROFILE_TESTS}"

PYVER=2.7.18
DEB_VERSION=2.7.18-1deb13local1
STAGING=${OUT_DIR}/staging

log() { echo "[py27-build] $*"; }
die() { echo "[py27-build] FATAL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
log "input checks"
for f in Python-${PYVER}.tgz \
         pip-20.3.4-py2.py3-none-any.whl \
         setuptools-44.1.1-py2.py3-none-any.whl \
         wheel-0.37.1-py2.py3-none-any.whl; do
    [ -f "${SRC_DIR}/${f}" ] || die "missing source cache file: ${f}"
done
[ -f "${PATCH_DIR}/setup-py-openssl3-version.patch" ] || die "missing patch file"
mkdir -p "${BUILD_ROOT}" "${OUT_DIR}"

# ---------------------------------------------------------------------------
log "extract Python source and apply patches"
cd "${BUILD_ROOT}"
rm -rf "Python-${PYVER}"
tar xzf "${SRC_DIR}/Python-${PYVER}.tgz"
cd "Python-${PYVER}"
for p in "${PATCH_DIR}"/*.patch; do
    log "applying patch: $p"
    patch -p1 < "$p"
done

# ---------------------------------------------------------------------------
log "point setup.py at the system Berkeley DB"
# _bsddb links against the distribution's libdb5.3 (libdb5.3-dev at build time,
# libdb5.3t64 at run time). Python 2.7's setup.py detect_db only searches
# /usr/lib, /lib, /usr/lib64 and /lib64, while Debian installs the library into
# the multiarch directory. Symlink it into /usr/lib so detection succeeds
# without adding -I/-L flags to the global CPPFLAGS/LDFLAGS, which configure
# would record into config/Makefile and _sysconfigdata.py.
[ -f /usr/include/db.h ] || die "db.h missing: libdb5.3-dev is not installed in the build image"
MULTIARCH=$(gcc -dumpmachine)
for lib in libdb-5.3.so libdb.so libdb.a; do
    if [ -e "/usr/lib/${MULTIARCH}/${lib}" ] && [ ! -e "/usr/lib/${lib}" ]; then
        ln -s "/usr/lib/${MULTIARCH}/${lib}" "/usr/lib/${lib}"
    fi
done
DB_MAJOR=$(grep -m1 -E 'define[[:space:]]+DB_VERSION_MAJOR' /usr/include/db.h | awk '{print $3}')
DB_MINOR=$(grep -m1 -E 'define[[:space:]]+DB_VERSION_MINOR' /usr/include/db.h | awk '{print $3}')
log "db.h: Berkeley DB ${DB_MAJOR:-?}.${DB_MINOR:-?}"

log "check the distribution's NIS headers"
# glibc dropped NIS; Debian ships it as a standalone libnsl. setup.py already
# knows about that split (bpo-32521): _detect_nis looks for headers under
# /usr/include/tirpc and /usr/include/nsl, adds -I only to the nis extension,
# and links libtirpc when present. No symlink or global CPPFLAGS needed, so
# there is nothing to shim here -- only to verify the packages are installed.
[ -f /usr/include/rpcsvc/yp_prot.h ] || die "rpcsvc/yp_prot.h missing: libnsl-dev is not installed"
[ -f /usr/include/tirpc/rpc/rpc.h ] || die "tirpc/rpc/rpc.h missing: libtirpc-dev is not installed"

# ---------------------------------------------------------------------------
log "configure Python (PGO + LTO + shared + ucs4)"
cd "${BUILD_ROOT}/Python-${PYVER}"
./configure \
    --enable-optimizations \
    --with-lto \
    --enable-shared \
    --enable-unicode=ucs4 \
    --prefix=${PREFIX} \
    --with-tcltk-includes="-I/usr/include/tcl8.6" \
    --with-tcltk-libs="-ltk8.6 -ltcl8.6" \
    > configure.log 2>&1 \
    || { tail -10 configure.log >&2; die "python configure failed"; }

# ---------------------------------------------------------------------------
log "PGO + LTO build (profile-opt with overridden PROFILE_TASK)"
make -j"${NPROC}" profile-opt PROFILE_TASK="${PROFILE_TASK}" > make.log 2>&1 \
    || { tail -20 make.log >&2; die "python make profile-opt failed"; }

# Race guard (design D4): -j parallelism can race the sysconfig step, leaving
# _sysconfigdata.py missing, which breaks pip bootstrap. Re-run on demand.
ensure_sysconfig() {
    local py=$1
    if ! find "${py}/build" -name '_sysconfigdata.py' | grep -q . || [ ! -f "${py}/pybuilddir.txt" ]; then
        log "race detected: regenerating _sysconfigdata"
        (cd "${py}" && LD_LIBRARY_PATH=. ./python -E -S -m sysconfig --generate-posix-vars) \
            || die "sysconfig regeneration failed"
    fi
}
ensure_sysconfig "${BUILD_ROOT}/Python-${PYVER}"

# ---------------------------------------------------------------------------
log "install into staging tree"
rm -rf "${STAGING}"
mkdir -p "${STAGING}"
make install DESTDIR="${STAGING}" > install.log 2>&1 || die "make install DESTDIR failed"

# CPython's install target also creates bin/python and bin/python-config
# symlinks pointing at the interpreter. Keep only the versioned ones
# (python2, python2.7, python2-config, python2.7-config).
rm -f "${STAGING}${PREFIX}/bin/python" "${STAGING}${PREFIX}/bin/python-config"

# `setup.py install` leaves egg-info metadata in unusual places
# (lib-dynload/, python2.7/); drop it so the package tree stays clean.
rm -rf "${STAGING}${PREFIX}/lib/python2.7/wsgiref.egg-info"
find "${STAGING}${PREFIX}/lib/python2.7/lib-dynload" -maxdepth 1 -name '*.egg-info' -exec rm -rf {} + 2>/dev/null || true

# ---------------------------------------------------------------------------
log "module report"
# Report from the installed layout: the canonical location of extension
# modules is lib/python2.7/lib-dynload/ (in-tree builds keep them flat in
# build/lib.*/ until install).
DYNLOAD_DIR="${STAGING}${PREFIX}/lib/python2.7/lib-dynload"
DYNLOAD=$(find "${DYNLOAD_DIR}" -maxdepth 1 -name '*.so' -printf '%f\n' | sed 's/\.so$//' | sort)
log "built modules: $(echo ${DYNLOAD} | tr ' ' ',')"
# Diagnostics for module-detection failures: expose why setup.py skipped a
# module (db.h / library search paths, Tcl/Tk vars) before aborting.
dump_module_diagnostics() {
    echo "===== diagnostics ====="
    echo "--- system db for _bsddb:"
    ls -l /usr/include/db.h /usr/lib/libdb*.so /usr/lib/libdb*.a 2>&1 | head -10
    echo "--- build-time CPPFLAGS/LDFLAGS/TCLTK vars:"
    LD_LIBRARY_PATH="${BUILD_ROOT}/Python-${PYVER}" "${BUILD_ROOT}/Python-${PYVER}/python" \
        -c "import sysconfig; print('CPPFLAGS=', sysconfig.get_config_var('CPPFLAGS')); print('LDFLAGS=', sysconfig.get_config_var('LDFLAGS')); print('TCLTK_INCLUDES=', sysconfig.get_config_var('TCLTK_INCLUDES')); print('TCLTK_LIBS=', sysconfig.get_config_var('TCLTK_LIBS'))" 2>&1 | head -6
    echo "--- setup.py bsddb/tkinter detection (debug enabled):"
    ( cd "${BUILD_ROOT}/Python-${PYVER}" && \
      sed -i 's/^        db_setup_debug = False.*/        db_setup_debug = True/' setup.py && \
      LD_LIBRARY_PATH="${BUILD_ROOT}/Python-${PYVER}" ./python setup.py build_ext 2>&1 \
        | grep -iE "db\.h|db lib|bsddb|tkinter|Tcl|tk" | head -25 || true )
    echo "===== end diagnostics ====="
}
for m in _hashlib _ssl _bsddb _tkinter gdbm dbm nis; do
    if ! echo "${DYNLOAD}" | grep -qx "${m}"; then
        dump_module_diagnostics
        die "expected module missing from build: ${m}"
    fi
done
# Documented intentional exclusions (design D5): imageop (32-bit only upstream).
log "intentionally excluded modules: imageop (see design D5)"
for m in imageop; do
    if echo "${DYNLOAD}" | grep -qx "${m}"; then die "unexpected module built: ${m}"; fi
done

# _bsddb must link the distribution's libdb, not a vendored static copy.
if ! objdump -p "${DYNLOAD_DIR}/_bsddb.so" | grep -q 'NEEDED.*libdb-5\.3\.so'; then
    dump_module_diagnostics
    die "_bsddb is not linked against the system libdb-5.3.so"
fi
log "_bsddb links system libdb-5.3.so"
if ! objdump -p "${DYNLOAD_DIR}/nis.so" | grep -q 'NEEDED.*libnsl\.so\.2'; then
    die "nis is not linked against the system libnsl.so.2"
fi
log "nis links system libnsl.so.2"

# ---------------------------------------------------------------------------
log "bootstrap pip trio offline from cached wheels"
# pip 20.3.4 skips itself when the running interpreter already has that
# version importable (we run it from the unpacked wheel), so --ignore-installed
# is required to get pip itself, its dist-info and the pip/pip2/pip2.7 scripts
# into the staging tree.
PIP_TMP=${BUILD_ROOT}/pip-bootstrap
rm -rf "${PIP_TMP}"; mkdir -p "${PIP_TMP}"
python3 -c "import zipfile; zipfile.ZipFile('${SRC_DIR}/pip-20.3.4-py2.py3-none-any.whl').extractall('${PIP_TMP}')"

# scandir is reached through pathlib2 (<3.4 marker) -> virtualenv. PyPI only
# ships Windows wheels for cp27, so the cached sdist is compiled during the
# offline install. pip's legacy sdist build needs setuptools and wheel in the
# build interpreter itself, not just staged for /usr/local.
PYTHONPATH="${PIP_TMP}" LD_LIBRARY_PATH="${BUILD_ROOT}/Python-${PYVER}" \
    "${BUILD_ROOT}/Python-${PYVER}/python" -m pip install \
        --no-index --find-links="${SRC_DIR}" \
        setuptools==44.1.1 wheel==0.37.1 \
        > build-tools.log 2>&1 \
    || { tail -5 build-tools.log >&2; die "cannot install build tools into the build interpreter"; }

PYTHONPATH="${PIP_TMP}" LD_LIBRARY_PATH="${BUILD_ROOT}/Python-${PYVER}" \
    "${BUILD_ROOT}/Python-${PYVER}/python" -m pip install \
        --ignore-installed \
        --no-index --find-links="${SRC_DIR}" \
        --root="${STAGING}" \
        pip==20.3.4 setuptools==44.1.1 wheel==0.37.1 virtualenv==20.15.1 \
        > pip-install.log 2>&1 \
    || { tail -5 pip-install.log >&2; die "offline pip install failed"; }

# Command names stay versioned even though the package installs under
# /usr/local: /usr/local/bin precedes /usr/bin in PATH, so an unversioned `pip`
# here would silently shadow the distribution's /usr/bin/pip from python3-pip.
# The pip bootstrap above writes bin/pip again, so this cleanup runs after it.
# Scripts shipped by make install are renamed to Debian-style versioned names.
for f in pip easy_install wheel; do
    rm -f "${STAGING}${PREFIX}/bin/${f}"
done
# virtualenv 20.15.1 is the last release supporting Python 2.7. It keeps its
# functionality under versioned names rather than being dropped: Debian ships
# /usr/bin/virtualenv in python3-virtualenv, and /usr/local/bin wins in PATH.
mv "${STAGING}${PREFIX}/bin/virtualenv" "${STAGING}${PREFIX}/bin/virtualenv2"
ln -s virtualenv2 "${STAGING}${PREFIX}/bin/virtualenv-2.7"
if [ -f "${STAGING}${PREFIX}/bin/2to3" ]; then mv "${STAGING}${PREFIX}/bin/2to3" "${STAGING}${PREFIX}/bin/2to3-2.7"; fi
if [ -f "${STAGING}${PREFIX}/bin/idle" ]; then mv "${STAGING}${PREFIX}/bin/idle" "${STAGING}${PREFIX}/bin/idle2.7"; fi
if [ -f "${STAGING}${PREFIX}/bin/pydoc" ]; then mv "${STAGING}${PREFIX}/bin/pydoc" "${STAGING}${PREFIX}/bin/pydoc2.7"; fi

# ---------------------------------------------------------------------------
log "verify the installed interpreter (run from staging tree)"
PYTHONHOME="${STAGING}${PREFIX}" \
LD_LIBRARY_PATH="${STAGING}${PREFIX}/lib" \
    "${BUILD_ROOT}/Python-${PYVER}/python" - <<'EOF' || die "staged interpreter verification failed"
import ssl, sqlite3, ctypes, hashlib, _hashlib, hmac, readline, multiprocessing
import bsddb, gdbm, Tkinter
print("staged python2.7 modules OK |", ssl.OPENSSL_VERSION)
EOF

# Build-time-only library paths must not leak into sysconfig: LDSHARED/LDFLAGS
# are reused when a user compiles a third-party extension, so a dangling -L
# (e.g. the vendor db prefix) would be passed to their linker.
log "check sysconfig for dangling -L paths"
PYTHONHOME="${STAGING}${PREFIX}" \
LD_LIBRARY_PATH="${STAGING}${PREFIX}/lib" \
    "${STAGING}${PREFIX}/bin/python2.7" - <<'EOF' || die "sysconfig leaks a library path that does not exist"
import os, re, sysconfig
bad = []
for key, val in sysconfig.get_config_vars().items():
    if not isinstance(val, str):
        continue
    for match in re.finditer(r'-L(\S+)', val):
        path = match.group(1)
        if not os.path.isdir(path):
            bad.append("%s: -L%s" % (key, path))
if bad:
    print("\n".join(bad))
    raise SystemExit(1)
print("sysconfig -L paths OK")
EOF

# The package must not claim unversioned command names; make sure everything is
# reachable only under versioned names (Debian policy, keeps python3 intact).
for f in python python-config pip easy_install wheel 2to3 idle pydoc virtualenv; do
    if [ -e "${STAGING}${PREFIX}/bin/${f}" ]; then
        die "unexpected unversioned path: ${PREFIX}/bin/${f}"
    fi
done
for f in python2.7 pip2 pip2.7 easy_install-2.7 2to3-2.7 idle2.7 pydoc2.7 virtualenv2 virtualenv-2.7; do
    if [ ! -x "${STAGING}${PREFIX}/bin/${f}" ]; then
        die "missing ${PREFIX}/bin/${f}"
    fi
done

# pip must be usable out of the staged tree (design: pip preinstalled).
PIP_VERSION=$(PYTHONHOME="${STAGING}${PREFIX}" LD_LIBRARY_PATH="${STAGING}${PREFIX}/lib" \
    "${STAGING}${PREFIX}/bin/python2.7" -m pip --version 2>&1) \
    || die "pip is not usable from the staged tree"
case "${PIP_VERSION}" in
    pip\ 20.3.4*) log "pip OK: ${PIP_VERSION}" ;;
    *) die "unexpected pip version: ${PIP_VERSION}" ;;
esac

# virtualenv has to run from the staged tree and carry its embedded seed wheels,
# otherwise `virtualenv2 myenv` needs network access. The entry script cannot be
# executed here (its shebang points at /usr/local/bin/python2.7, which only
# exists after installation), so drive the module with the staged interpreter
# and check the shebang separately.
VIRTUALENV_VERSION=$(PYTHONHOME="${STAGING}${PREFIX}" LD_LIBRARY_PATH="${STAGING}${PREFIX}/lib" \
    "${STAGING}${PREFIX}/bin/python2.7" -m virtualenv --version 2>&1) \
    || die "virtualenv is not usable from the staged tree: ${VIRTUALENV_VERSION}"
case "${VIRTUALENV_VERSION}" in
    *20.15.1*) log "virtualenv OK: ${VIRTUALENV_VERSION}" ;;
    *) die "unexpected virtualenv version: ${VIRTUALENV_VERSION}" ;;
esac
[ "$(head -1 "${STAGING}${PREFIX}/bin/virtualenv2")" = "#!${PREFIX}/bin/python2.7" ] \
    || die "virtualenv2 does not point at the packaged interpreter"
ls "${STAGING}${PREFIX}/lib/python2.7/site-packages/virtualenv/seed/wheels/embed/" | grep -q '^pip-20\.3\.4' \
    || die "virtualenv is missing its embedded seed wheels"

PYTHONHOME="${STAGING}${PREFIX}" \
LD_LIBRARY_PATH="${STAGING}${PREFIX}/lib" \
    "${BUILD_ROOT}/Python-${PYVER}/python" -m test test_hashlib test_md5 test_sha test_hmac test_bsddb test_gdbm \
    2>&1 | tail -1 | grep -q "SUCCESS" \
    || die "staged interpreter test suite failed"

# ---------------------------------------------------------------------------
log "generate control (Depends from NEEDED sonames)"
rm -rf "${STAGING}/DEBIAN"
mkdir -p "${STAGING}/DEBIAN"
ARCH=$(dpkg --print-architecture)
# Map direct DT_NEEDED sonames of staged ELFs to trixie package names via
# dpkg -S. This is what pulls libdb5.3t64 in for _bsddb.
TRIPLET=$(gcc -dumpmachine)
mapfile -t SONAMES < <(find "${STAGING}${PREFIX}" -type f \( -name "*.so*" -o -name "python2.7" \) \
    -exec objdump -p {} \; 2>/dev/null \
    | awk '/NEEDED/{print $2}' | sort -u | grep -v '^libpython2.7.so.1.0$' || true)
declare -A SEEN_PKG
declare -A SEEN_SO
DEPS=""
for so in "${SONAMES[@]}"; do
    [ -n "${so}" ] || continue
    [ -n "${SEEN_SO[${so}]:-}" ] && continue
    SEEN_SO[${so}]=1
    lib="/usr/lib/${TRIPLET}/${so}"
    [ -e "${lib}" ] || lib=$(ldconfig -p | grep -F "${so} " | awk '{print "/usr"$NF}' | head -1)
    # dpkg -S prints "pkg:arch: /path"; keep the bare package name.
    pkg=$(dpkg -S "${lib}" 2>/dev/null | head -1 | sed 's/: .*//;s/:[a-z0-9][a-z0-9-]*$//')
    [ -n "${pkg}" ] || die "cannot map soname to package: ${so}"
    [ -n "${SEEN_PKG[${pkg}]:-}" ] && continue
    SEEN_PKG[${pkg}]=1
    DEPS="${DEPS:+${DEPS}, }${pkg}"
done
log "Depends: ${DEPS}"

# ca-certificates as Recommends, matching Debian's python3.13 package (verified:
# "Recommends: ca-certificates"). Without it ssl.create_default_context()
# raises CERTIFICATE_VERIFY_FAILED, because /usr/lib/ssl/cert.pem dangles.
# Kept a Recommends rather than Depends: apt installs it by default
# (APT::Install-Recommends is on in trixie and in debian:*-slim), while
# --no-install-recommends users stay minimal and add it explicitly. pip does
# not need it either, its vendored certifi covers HTTPS downloads.
cat > "${STAGING}/DEBIAN/control" <<EOF
Package: python2.7
Version: ${DEB_VERSION}
Architecture: ${ARCH}
Priority: optional
Section: python
Maintainer: Luo Yuhao <luoyuhao@local>
Depends: ${DEPS}
Recommends: ca-certificates
Provides: python2, python2.7
Description: Python 2.7.18 built from source on Debian 13 (trixie)
 Built with PGO + LTO against the system OpenSSL 3.x and Berkeley DB 5.3;
 pip 20.3.4, setuptools 44.1.1 and wheel 0.37.1 preinstalled. Installed
 under /usr/local so it stays clear of distribution-managed paths.
 Local build, not an official Debian package.
EOF

# ---------------------------------------------------------------------------
log "build deb (dpkg-deb, xz)"
# Version strings never contain '~' (design D6): trixie's apt rejects local
# file paths containing it.
dpkg-deb --build -Zxz "${STAGING}" "${OUT_DIR}/py27.deb" > dpkg-deb.log 2>&1 \
    || { tail -5 dpkg-deb.log >&2; die "dpkg-deb failed"; }
log "done: ${OUT_DIR}/py27.deb ($(du -h "${OUT_DIR}/py27.deb" | cut -f1))"
