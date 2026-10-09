"""Shared pieces of the fault-injection self-tests (sim/*_diff/selftest.py).

A self-test runs the golden against itself once per injected fault (a tb_diff generic) and checks that
exactly the expected counters move. Each harness supplies its RESULT parser and its list of tests.
"""
import os
import subprocess
import sys

NVC = ["nvc", "--std=2008"]


def link_null(rundir, names):
    """Symlink each literal file name the RTL opens to /dev/null so its debug output is discarded."""
    for n in names:
        link = os.path.join(rundir, n)
        if not os.path.lexists(link):
            os.symlink("/dev/null", link)


def run_tb(lib, rundir, name, gens, vecfile, debug_names=(), libdirs=(), nvc_args=(), tb="tb_diff"):
    """Elaborate and run tb in RUNDIR/NAME with generics GENS; returns (stdout, returncode). run.log is written."""
    d = os.path.join(rundir, name)
    os.makedirs(d, exist_ok=True)
    link_null(d, debug_names)
    cmd = NVC + list(nvc_args) + ["--work=work:" + lib]
    for l in libdirs:
        cmd += ["-L", l]
    cmd += ["-e", "--no-save", "-g", "G_VECFILE=" + vecfile]
    for k, v in gens.items():
        cmd += ["-g", "%s=%s" % (k, v)]
    cmd += [tb, "-r"]
    p = subprocess.run(cmd, cwd=d, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    open(os.path.join(d, "run.log"), "w").write(p.stdout)
    return p.stdout, p.returncode


def gen_vectors(script, out, *args):
    """Run a harness's gen_vectors.py --suite smoke --seed 1; returns its stderr."""
    p = subprocess.run([sys.executable, script, "--suite", "smoke", "--seed", "1"] + list(args) + ["--out", out],
                       stderr=subprocess.PIPE, text=True, check=True)
    return p.stderr


def run_tests(tests, runner, base=None, label="selftest"):
    """tests: (name, generics, check(result) -> bool, description). runner(name, gens) -> result dict or None.
    Prints one line per test and the SELFTEST verdict; exits 0 on success."""
    ok = True
    for name, gens, chk, desc in tests:
        r = base if (name == "base" and base is not None) else runner(name, gens)
        good = bool(r) and chk(r)
        ok &= good
        print("%s %-18s %s  %s  %s" % (label, name, "ok  " if good else "FAIL", desc, r if (r and not good) else ""))
    print("SELFTEST " + ("PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)
