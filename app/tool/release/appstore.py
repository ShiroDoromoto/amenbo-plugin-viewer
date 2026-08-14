# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""The App Store half of a release, as commands rather than a browser.

Nothing here is a secret and nothing here is an account: the key, its two identifiers and the
paths to them live on the machine that runs this, outside the repository. What is written down is
the order the steps go in, because that order is where the cost is — withdrawing a submission
loses the place in the review queue, and no amount of care afterwards buys it back.

    uv run app/tool/release/appstore.py state
    uv run app/tool/release/appstore.py upload build/ios/ipa/*.ipa
    uv run app/tool/release/appstore.py notes 1.0
    uv run app/tool/release/appstore.py notes 1.0 app/tool/release/review-notes.txt
    uv run app/tool/release/appstore.py attach 1.0
    uv run app/tool/release/appstore.py attach 1.0 ~/.config/amenbo-release/demo-secrets/pairing-appreview.png
    uv run app/tool/release/appstore.py withdraw
    uv run app/tool/release/appstore.py bind 1.0.0 2
    uv run app/tool/release/appstore.py submit 1.0.0

Reads `ASC_KEY_ID` and `ASC_ISSUER_ID` from `~/.config/amenbo-release/asc.env`, and the key itself
from `~/.appstoreconnect/private_keys/AuthKey_<id>.p8` — the directory `altool` looks in, so the
upload needs nothing said twice.
"""

import argparse
import hashlib
import pathlib
import subprocess
import sys
import time

import jwt
import requests

BUNDLE = "work.amenbo.viewer"
API = "https://api.appstoreconnect.apple.com"
HOME = pathlib.Path.home()
ENV = HOME / ".config/amenbo-release/asc.env"
KEYS = HOME / ".appstoreconnect/private_keys"

# The states a submission can be in while it is still the app's turn to act. Anything outside this
# has either finished or been cancelled, and withdrawing it would be a no-op at best.
PENDING = {"READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES"}

# What the notes field holds. Checked here because the API refuses the whole PATCH over it, and a
# rejection at that point costs a round trip to find out which of the two fields was too long.
NOTES_LIMIT = 4000


def ids():
    """The key's two identifiers, read off the machine rather than passed around."""
    if not ENV.exists():
        sys.exit(f"no {ENV} — see the release skill for what belongs in it")
    values = dict(
        line.split("=", 1)
        for line in ENV.read_text().splitlines()
        if line.strip() and not line.startswith("#") and "=" in line
    )
    return values["ASC_KEY_ID"].strip(), values["ASC_ISSUER_ID"].strip()


def token():
    """A twenty-minute bearer, signed with the key sitting where altool keeps it."""
    key_id, issuer = ids()
    private = (KEYS / f"AuthKey_{key_id}.p8").read_text()
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        private,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def call(method, path, body=None, **params):
    answer = requests.request(
        method,
        f"{API}{path}",
        headers={
            "Authorization": f"Bearer {token()}",
            "Content-Type": "application/json",
        },
        json=body,
        params=params or None,
        timeout=120,
    )
    if answer.status_code >= 300:
        sys.exit(f"{method} {path} → {answer.status_code}\n{answer.text[:800]}")
    return answer.json() if answer.text else {}


def app():
    """This app, found by the identifier it ships under rather than by a number written here."""
    found = call("GET", "/v1/apps", **{"filter[bundleId]": BUNDLE})["data"]
    if not found:
        sys.exit(f"no app on this account with the identifier {BUNDLE}")
    return found[0]["id"]


def versions():
    return call("GET", f"/v1/apps/{app()}/appStoreVersions", limit=10)["data"]


def version_named(name):
    for version in versions():
        if version["attributes"]["versionString"] == name:
            return version["id"]
    sys.exit(f"no version {name} on this app")


def build_numbered(number):
    """A build by the number the store counts with — the one that can never be used twice."""
    for build in call("GET", "/v1/builds", **{"filter[app]": app(), "limit": 50})["data"]:
        if build["attributes"]["version"] == str(number):
            return build["id"]
    sys.exit(f"no build {number} — it may still be processing")


def submissions():
    return [
        (s["id"], s["attributes"]["state"])
        for s in call("GET", f"/v1/apps/{app()}/reviewSubmissions", limit=10)["data"]
    ]


def state(_args):
    print(f"app {app()}  {BUNDLE}")
    for build in call(
        "GET", "/v1/builds", **{"filter[app]": app(), "limit": 5, "sort": "-uploadedDate"}
    )["data"]:
        a = build["attributes"]
        print(f"  build {a['version']}  {a['processingState']}  uploaded {a['uploadedDate']}")
    for version in versions():
        a = version["attributes"]
        held = call("GET", f"/v1/appStoreVersions/{version['id']}/build")["data"]
        under = held["attributes"]["version"] if held else None
        print(f"  version {a['versionString']}  {a['appStoreState']}  release={a['releaseType']}  build={under}")
    for sid, s in submissions():
        print(f"  submission {sid}  {s}")


def review_detail(version):
    """The panel App Review reads before it opens the app — contact, demo account, notes."""
    return call("GET", f"/v1/appStoreVersions/{version_named(version)}/appStoreReviewDetail")["data"]


def notes(args):
    """Reads the review notes, or replaces them with a file.

    This is the one answer to a Guideline 2.1 that asks for information rather than a fix: what
    the app is, what it needs to show anything, and what was tested on. Kept in a file because it
    is written once and handed over again at every submission.
    """
    detail = review_detail(args.version)
    if args.file is None:
        print(detail["attributes"]["notes"] or "(empty)")
        return
    text = args.file.read_text()
    if len(text) > NOTES_LIMIT:
        sys.exit(f"{len(text)} characters — App Store Connect takes {NOTES_LIMIT}")
    call(
        "PATCH",
        f"/v1/appStoreReviewDetails/{detail['id']}",
        {
            "data": {
                "type": "appStoreReviewDetails",
                "id": detail["id"],
                "attributes": {"notes": text},
            }
        },
    )
    print(f"version {args.version} now carries {len(text)} characters of notes")


def attach(args):
    """Lists what is attached to the review panel, adds a file to it, or takes one away.

    The pairing code we hand App Review is a picture, and a picture is the one thing the notes
    field cannot carry. It goes up the same way an archive does — reserve, put, commit — so the
    whole submission still leaves from here rather than from a browser.
    """
    detail = review_detail(args.version)
    here = f"/v1/appStoreReviewDetails/{detail['id']}/appStoreReviewAttachments"
    if args.file is None:
        for one in call("GET", here)["data"]:
            a = one["attributes"]
            print(f"  {one['id']}  {a['fileName']}  {a['fileSize']} bytes  {a['assetDeliveryState']['state']}")
        return
    if args.rm:
        call("DELETE", f"/v1/appStoreReviewAttachments/{args.file}")
        print(f"removed {args.file}")
        return

    body = pathlib.Path(args.file).read_bytes()
    reserved = call(
        "POST",
        "/v1/appStoreReviewAttachments",
        {
            "data": {
                "type": "appStoreReviewAttachments",
                "attributes": {"fileName": pathlib.Path(args.file).name, "fileSize": len(body)},
                "relationships": {
                    "appStoreReviewDetail": {
                        "data": {"type": "appStoreReviewDetails", "id": detail["id"]}
                    }
                },
            }
        },
    )["data"]
    for step in reserved["attributes"]["uploadOperations"]:
        piece = body[step["offset"] : step["offset"] + step["length"]]
        sent = requests.request(
            step["method"],
            step["url"],
            headers={h["name"]: h["value"] for h in step["requestHeaders"]},
            data=piece,
            timeout=300,
        )
        if sent.status_code >= 300:
            sys.exit(f"upload → {sent.status_code}\n{sent.text[:400]}")
    call(
        "PATCH",
        f"/v1/appStoreReviewAttachments/{reserved['id']}",
        {
            "data": {
                "type": "appStoreReviewAttachments",
                "id": reserved["id"],
                "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(body).hexdigest()},
            }
        },
    )
    print(f"attached {pathlib.Path(args.file).name} as {reserved['id']}")


def upload(args):
    """Hands the archive to Apple, after asking Apple whether it would take it.

    The validate is not politeness: a rejection here costs nothing, and the same rejection after
    the upload costs a build number, which never comes back.
    """
    key_id, issuer = ids()
    for step in ("--validate-app", "--upload-app"):
        done = subprocess.run(
            [
                "xcrun", "altool", step,
                "--type", "ios",
                "-f", str(args.ipa),
                "--apiKey", key_id,
                "--apiIssuer", issuer,
            ],
            capture_output=True,
            text=True,
        )
        print(done.stdout.strip() or done.stderr.strip())
        if done.returncode != 0:
            sys.exit(done.returncode)


def withdraw(_args):
    """Takes the app out of the queue. This is the expensive one — see the note at the top."""
    for sid, s in submissions():
        if s in PENDING:
            call(
                "PATCH",
                f"/v1/reviewSubmissions/{sid}",
                {"data": {"type": "reviewSubmissions", "id": sid, "attributes": {"canceled": True}}},
            )
            print(f"withdrew {sid} (was {s})")
            return
    print("nothing was queued")


def bind(args):
    """Puts a different build under a version. The version has to be out of review first."""
    call(
        "PATCH",
        f"/v1/appStoreVersions/{version_named(args.version)}/relationships/build",
        {"data": {"type": "builds", "id": build_numbered(args.build)}},
    )
    print(f"version {args.version} now carries build {args.build}")


def submit(args):
    """Puts the version back in the queue: a submission, the version inside it, then send."""
    version = version_named(args.version)
    sub = call(
        "POST",
        "/v1/reviewSubmissions",
        {
            "data": {
                "type": "reviewSubmissions",
                "attributes": {"platform": "IOS"},
                "relationships": {"app": {"data": {"type": "apps", "id": app()}}},
            }
        },
    )["data"]
    call(
        "POST",
        "/v1/reviewSubmissionItems",
        {
            "data": {
                "type": "reviewSubmissionItems",
                "relationships": {
                    "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub["id"]}},
                    "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version}},
                },
            }
        },
    )
    call(
        "PATCH",
        f"/v1/reviewSubmissions/{sub['id']}",
        {"data": {"type": "reviewSubmissions", "id": sub["id"], "attributes": {"submitted": True}}},
    )
    print(f"submitted {sub['id']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    steps = parser.add_subparsers(required=True)

    steps.add_parser("state", help="what the store is holding").set_defaults(run=state)

    one = steps.add_parser("notes", help="read the review notes, or replace them with a file")
    one.add_argument("version")
    one.add_argument("file", nargs="?", type=pathlib.Path)
    one.set_defaults(run=notes)

    one = steps.add_parser("attach", help="list, add or remove a review attachment")
    one.add_argument("version")
    one.add_argument("file", nargs="?", help="a file to attach, or an attachment id with --rm")
    one.add_argument("--rm", action="store_true", help="remove the attachment named instead")
    one.set_defaults(run=attach)

    one = steps.add_parser("upload", help="validate an ipa, then send it")
    one.add_argument("ipa", type=pathlib.Path)
    one.set_defaults(run=upload)

    steps.add_parser("withdraw", help="take the queued submission back").set_defaults(run=withdraw)

    one = steps.add_parser("bind", help="put a build under a version")
    one.add_argument("version")
    one.add_argument("build")
    one.set_defaults(run=bind)

    one = steps.add_parser("submit", help="send a version for review")
    one.add_argument("version")
    one.set_defaults(run=submit)

    args = parser.parse_args()
    args.run(args)
