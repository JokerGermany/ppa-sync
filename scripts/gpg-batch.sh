#!/bin/sh
# Non-interactive gpg for debsign (passphrase from $GPG_PASSFILE, if set).
exec gpg --batch --pinentry-mode loopback ${GPG_PASSFILE:+--passphrase-file "$GPG_PASSFILE"} "$@"
