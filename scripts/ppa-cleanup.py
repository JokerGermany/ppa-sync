#!/usr/bin/env python3
"""Delete superseded source publications from a PPA, keeping the newest N per package and series.

Untested against Launchpad. Runs as dry run unless --apply is given.
Credentials: create once locally with
    python3 -c 'from launchpadlib.launchpad import Launchpad; \
      Launchpad.login_with("ppa-sync", "production", version="devel", credentials_file="lp-creds")'
"""
import argparse
from launchpadlib.launchpad import Launchpad

ap = argparse.ArgumentParser()
ap.add_argument("--ppa", default="jokergermany/ppa")
ap.add_argument("--keep", type=int, default=1)
ap.add_argument("--credentials", default="lp-creds")
ap.add_argument("--apply", action="store_true")
a = ap.parse_args()

owner, name = a.ppa.split("/")
lp = Launchpad.login_with("ppa-sync", "production", version="devel", credentials_file=a.credentials)
ppa = lp.people[owner].getPPAByName(name=name)

groups = {}
for st in ("Published", "Superseded"):
    for p in ppa.getPublishedSources(status=st):
        groups.setdefault((p.source_package_name, p.distro_series_link), []).append(p)

for (pkg, series), pubs in sorted(groups.items()):
    pubs.sort(key=lambda p: p.date_created, reverse=True)
    for old in pubs[a.keep:]:
        print(("DELETE " if a.apply else "would delete ") + f"{pkg} {old.source_package_version} ({old.status})")
        if a.apply:
            old.requestDeletion(removal_comment="superseded by newer upstream release")
