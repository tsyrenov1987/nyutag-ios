#!/bin/sh
# Стенд для живых тестов на Маке: ядро nyutag.chat достаётся по SSH-пробросу (FarvaterCore есть только для iOS).
#
#   ssh -N -L 18008:127.0.0.1:8008 -L 18090:127.0.0.1:8090 nyutag-core &
#   . tools/test-env.sh && swift test
#
# Учётка берётся из tools/test-env.local.sh (в .gitignore):
#   export NYUTAG_TEST_USER=test17
#   export NYUTAG_TEST_PASSWORD=...
export NYUTAG_TEST_HS="${NYUTAG_TEST_HS:-http://127.0.0.1:18008}"
export NYUTAG_TEST_API="${NYUTAG_TEST_API:-http://127.0.0.1:18090}"
if [ -f "$(dirname "$0")/test-env.local.sh" ]; then
    . "$(dirname "$0")/test-env.local.sh"
fi
