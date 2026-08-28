#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <Release .app directory or executable>" >&2
    exit 2
fi

artifact=$1
if [ ! -e "$artifact" ]; then
    echo "error: Release artifact does not exist: $artifact" >&2
    exit 2
fi

patterns='asr\.apiKey|llm\.apiKey|llm\.bochaKey|com\.local\.SingleGreenDemo\.ai|demo_asr_api_key_field|demo_llm_api_key_field|demo_search_api_key_field|DemoKeychainCredentialProvider|DemoCredentialStore|KeychainDemoCredentialStore|KeychainHelper'
if [ -d "$artifact" ]; then
    contains_demo_identifier() {
        LC_ALL=C grep -aEr -m 1 "$patterns" "$artifact" >/dev/null 2>&1
    }
else
    contains_demo_identifier() {
        LC_ALL=C grep -aE -m 1 "$patterns" "$artifact" >/dev/null 2>&1
    }
fi

if contains_demo_identifier; then
    echo "error: Release artifact contains a demo credential identifier: $artifact" >&2
    exit 1
fi

echo "Release credential isolation check passed."
