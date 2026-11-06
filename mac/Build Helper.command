#!/bin/bash
# Earmark build helper (v3). While this window is open, Claude can compile the iPhone and Mac apps
# on this Mac and install the iPhone app (cable or same Wi-Fi), keeping the app's data.
# Keeps the Mac awake while it runs. It only builds the project in ./mobile, when a request file
# appears there. Close the window to stop.
cd "$(dirname "$0")/mobile" || exit 1
echo "Earmark build helper v3 is running. Leave this window open; close it to stop."
caffeinate -dimsu -w $$ &
rm -f .build_request
while true; do
  if [ -f .build_request ]; then
    what="$(cat .build_request 2>/dev/null)"
    rm -f .build_request
    echo "[$(date +%H:%M:%S)] ${what:-build} …"
    bash ../build_ios.sh "$what" > .build_log.txt 2>&1
    tail -2 .build_log.txt | head -1
  fi
  sleep 3
done
