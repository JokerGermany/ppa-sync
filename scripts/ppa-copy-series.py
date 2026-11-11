#!/usr/bin/env python3
"""Copy published packages (source + prebuilt binaries, no rebuild) from one Ubuntu
series of a PPA to the other supported series.

Target series are read from Launchpad at runtime: every Ubuntu series NEWER than the
source series whose status is "Supported" or "Current Stable Release". Override with --to.

Untested against Launchpad. Dry run unless --apply is given.
Same credentials file as ppa-cleanup.py.
"""
import argparse
import sys
import time

from launchpadlib.launchpad import Launchpad

ap = argparse.ArgumentParser()
ap.add_argument("--ppa", default="jokergermany/ppa")
ap.add_argument("--from-series", default="noble")
ap.add_argument("--to", nargs="*", help="target series (default: all supported)")
ap.add_argument("--credentials", default="lp-creds")
ap.add_argument("--apply", action="store_true")
a = ap.parse_args()

owner, name = a.ppa.split("/")
lp = Launchpad.login_with("ppa-sync", "production", version="devel", credentials_file=a.credentials)
ubuntu = lp.distributions["ubuntu"]
ppa = lp.people[owner].getPPAByName(name=name)

def retry(fn, what, tries=4, wait=30):
    """Call fn(); retry on transient Launchpad errors (503, timeouts)."""
    for i in range(1, tries + 1):
        try:
            return fn()
        except Exception as e:
            if i == tries:
                raise
            print(f"  {what}: {type(e).__name__} ({str(e).splitlines()[0][:80]}), retry {i}/{tries - 1} in {wait}s",
                  file=sys.stderr)
            time.sleep(wait)


def series_ver(s):  # "24.04" -> (24, 4)
    return tuple(int(x) for x in s.version.split("."))

src_series = ubuntu.getSeries(name_or_version=a.from_series)
if a.to:
    targets = [ubuntu.getSeries(name_or_version=s) for s in a.to]
else:
    # only series NEWER than the source series (e.g. noble and newer, no jammy)
    targets = [s for s in ubuntu.series
               if s.status in ("Supported", "Current Stable Release") and series_ver(s) > series_ver(src_series)]
print("source series:", a.from_series, "| targets:", ", ".join(s.name for s in targets) or "none")

sources = ppa.getPublishedSources(distro_series=src_series, status="Published")

errors = 0
for src in sources:
    pkg, ver = src.source_package_name, src.source_package_version
    for t in targets:
        try:
            # Any publication of this exact version in the target series (also superseded/deleted)
            # means a copy was already done; Launchpad never accepts the same version twice.
            existing = retry(lambda: list(ppa.getPublishedSources(
                source_name=pkg, exact_match=True, version=ver, distro_series=t)), f"check {pkg} -> {t.name}")
            if existing:
                continue
            print(("COPY " if a.apply else "would copy ") + f"{pkg} {ver} -> {t.name}")
            if a.apply:
                retry(lambda: ppa.copyPackage(source_name=pkg, version=ver, from_archive=ppa,
                                              to_series=t.name, to_pocket="Release", include_binaries=True),
                      f"copy {pkg} -> {t.name}", tries=2)
        except Exception as e:  # e.g. copy job already queued, or Launchpad unavailable
            print(f"  WARNING: {pkg} {ver} -> {t.name}: {str(e).splitlines()[0][:200]}", file=sys.stderr)
            errors += 1

print("done" + (f", {errors} warning(s); will be retried on the next run" if errors else ""))
