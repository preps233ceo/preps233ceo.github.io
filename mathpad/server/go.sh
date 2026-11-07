#!/usr/bin/env bash
# Downloads the MathPad class-server scripts into Cloud Shell and starts the retry.
#   curl -sL preps233ceo.github.io/mathpad/server/go.sh | bash -s 2 12 [duckdnsname token]
cd "$HOME"
for f in oracle-retry.sh install.sh; do
  curl -fsSLO "https://preps233ceo.github.io/mathpad/server/$f" || { echo "Couldn't download $f"; exit 1; }
done
echo "Downloaded oracle-retry.sh and install.sh"
bash oracle-retry.sh "$@" </dev/null
