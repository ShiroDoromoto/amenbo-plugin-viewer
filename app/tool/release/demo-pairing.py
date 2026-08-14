# /// script
# requires-python = ">=3.11"
# dependencies = ["opencv-python-headless", "numpy", "requests", "pynacl"]
# ///
"""The pairing code App Review is handed, checked the way the phone would read it.

App Review asked to be shown the app working, and this app shows nothing without a computer
running Amenbo. What it is handed instead is a code into a backlog stood up for it — invented
rows, its own Worker, its own key, and nothing of anyone's real work.

    uv run app/tool/release/demo-pairing.py

**Run this before every submission.** The code carries the contract version, and a phone refuses
one from either side of its own. A code left standing through a contract change is worse than no
code at all: the reviewer scans it and is told the thing they were given is out of date.

The code itself lives with the App Store key, outside the repository — reading it is the whole of
what this needs, and it writes nothing back.
"""

import base64
import json
import pathlib
import sys

import cv2
import requests
from nacl.bindings import crypto_aead_xchacha20poly1305_ietf_decrypt

# What the phone reads today. A code saying anything else is one to issue again, not to hand over.
CONTRACT = 1

CODE = pathlib.Path.home() / ".config/amenbo-release/demo-secrets/pairing-appreview.png"


def unpadded(value):
    """base64url as everything on this route is written — the padding is optional on the way in."""
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def read_the_code():
    if not CODE.exists():
        sys.exit(f"no {CODE} — the demo pairing has not been issued on this machine")
    text, *_ = cv2.QRCodeDetector().detectAndDecode(cv2.imread(str(CODE)))
    if not text:
        sys.exit(f"{CODE} holds no code that reads")
    return json.loads(text)


def main():
    code = read_the_code()
    print(f"code    v={code['v']}  label={code.get('l')}  {code['url']}")
    if code["v"] != CONTRACT:
        sys.exit(f"the code speaks contract {code['v']}, the phone reads {CONTRACT} — issue a new one")

    answer = requests.get(
        f"{code['url'].rstrip('/')}/records",
        headers={"Authorization": f"Bearer {code['t']}"},
        timeout=60,
    )
    if answer.status_code != 200:
        sys.exit(f"GET /records → {answer.status_code}\n{answer.text[:400]}")
    rows = answer.json()["records"]

    # Opening them is the point: a token that fetches and a key that does not open is a code the
    # reviewer would scan into an empty app, which is the failure this is here to catch.
    key = unpadded(code["k"])
    opened = 0
    for row in rows:
        try:
            crypto_aead_xchacha20poly1305_ietf_decrypt(
                unpadded(row["c"]), row["k"].encode(), unpadded(row["n"]), key
            )
        except Exception:
            continue
        opened += 1

    print(f"records {opened}/{len(rows)} opened with the key it carries")
    if not rows or opened != len(rows):
        sys.exit("the code is stale — push the demo backlog again and issue a new code")
    print("ok — hand this code to App Review")


if __name__ == "__main__":
    main()
