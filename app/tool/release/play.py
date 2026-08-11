# /// script
# requires-python = ">=3.11"
# dependencies = ["google-auth", "requests"]
# ///
"""The Google Play half of a release, as commands rather than a browser.

Everything Play does happens inside an **edit**, which is a transaction: open one, change what is
inside it, commit. Nothing reaches the store until the commit, and an edit left open simply
expires — so a run that dies halfway leaves the store exactly as it was.

    uv run app/tool/release/play.py state
    uv run app/tool/release/play.py upload build/app/outputs/bundle/release/app-release.aab --track alpha
    uv run app/tool/release/play.py notes --track alpha --text-file /path/to/what-changed.txt

Reads the service account key from `~/.config/amenbo-release/play-service-account.json`. That
account is a user of the Play account, invited under "users and permissions" like a person — the
permissions it was given are the whole of what these commands can do.
"""

import argparse
import pathlib
import re
import sys

import google.auth.transport.requests
import requests
from google.oauth2 import service_account

PACKAGE = "work.amenbo.viewer"
API = "https://androidpublisher.googleapis.com/androidpublisher/v3"
UPLOAD = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3"
KEY = pathlib.Path.home() / ".config/amenbo-release/play-service-account.json"
STORE = pathlib.Path(__file__).resolve().parents[2] / "store"

# Play's locale names and the listing sheets' own are not spelled the same everywhere.
SHEET = {"en-US": "en", "zh-CN": "zh-Hans", "zh-TW": "zh-Hant"}


def session():
    if not KEY.exists():
        sys.exit(f"no {KEY} — see the release skill for how that account is made")
    creds = service_account.Credentials.from_service_account_file(
        str(KEY), scopes=["https://www.googleapis.com/auth/androidpublisher"]
    )
    creds.refresh(google.auth.transport.requests.Request())
    talk = requests.Session()
    talk.headers["Authorization"] = f"Bearer {creds.token}"
    return talk


def check(answer, what):
    if answer.status_code >= 300:
        sys.exit(f"{what} → {answer.status_code}\n{answer.text[:800]}")
    return answer.json() if answer.text else {}


def languages(talk, edit):
    """The languages Play has a listing in. Writing a note for any other one is refused."""
    listings = check(
        talk.get(f"{API}/applications/{PACKAGE}/edits/{edit}/listings", timeout=60), "listings"
    )
    return [one["language"] for one in listings.get("listings", [])]


def listing_notes(language):
    """What the listing sheet says about this release, in the language Play asked for."""
    sheet = STORE / f"{SHEET.get(language, language)}.md"
    section = re.search(r"^## release_notes\n(.*?)(?=^## |\Z)", sheet.read_text(), re.S | re.M)
    if not section:
        sys.exit(f"{sheet} has no release_notes")
    return section.group(1).strip()


def state(_args):
    talk = session()
    edit = check(talk.post(f"{API}/applications/{PACKAGE}/edits", timeout=60), "edits.insert")["id"]
    tracks = check(
        talk.get(f"{API}/applications/{PACKAGE}/edits/{edit}/tracks", timeout=60), "tracks.list"
    )
    for track in tracks.get("tracks", []):
        print(f"track {track['track']}")
        for release in track.get("releases", []):
            print(f"  {release.get('name')}  {release.get('status')}  {release.get('versionCodes')}")
    bundles = check(
        talk.get(f"{API}/applications/{PACKAGE}/edits/{edit}/bundles", timeout=60), "bundles.list"
    )
    print("bundles", [b["versionCode"] for b in bundles.get("bundles", [])])
    print("listings", languages(talk, edit))
    # A read costs nothing, but an edit left holding the app does. Throw it away.
    talk.delete(f"{API}/applications/{PACKAGE}/edits/{edit}", timeout=60)


def upload(args):
    """Sends the bundle and makes it the track's release, in one edit."""
    talk = session()
    edit = check(talk.post(f"{API}/applications/{PACKAGE}/edits", timeout=60), "edits.insert")["id"]

    bundle = check(
        talk.post(
            f"{UPLOAD}/applications/{PACKAGE}/edits/{edit}/bundles?uploadType=media",
            data=args.aab.read_bytes(),
            headers={"Content-Type": "application/octet-stream"},
            timeout=1800,
        ),
        "bundles.upload",
    )
    code = bundle["versionCode"]
    print(f"uploaded versionCode {code}")

    text = args.text_file.read_text().strip() if args.text_file else None
    track = check(
        talk.put(
            f"{API}/applications/{PACKAGE}/edits/{edit}/tracks/{args.track}",
            json={
                "track": args.track,
                "releases": [
                    {
                        "name": args.name or str(code),
                        "versionCodes": [str(code)],
                        "status": "completed",
                        "releaseNotes": [
                            {"language": one, "text": text or listing_notes(one)}
                            for one in languages(talk, edit)
                        ],
                    }
                ],
            },
            timeout=120,
        ),
        "tracks.update",
    )
    print(f"track {track['track']} → {[r['name'] for r in track['releases']]}")

    check(talk.post(f"{API}/applications/{PACKAGE}/edits/{edit}:commit", timeout=300), "commit")
    print("committed")


def notes(args):
    """Rewrites what a track says about the build it is already serving. No bundle moves.

    The same text goes to every language Play has a listing in — which is honest while there is
    one, and the thing to change first if a second listing ever appears.
    """
    talk = session()
    edit = check(talk.post(f"{API}/applications/{PACKAGE}/edits", timeout=60), "edits.insert")["id"]

    current = check(
        talk.get(f"{API}/applications/{PACKAGE}/edits/{edit}/tracks/{args.track}", timeout=60),
        "tracks.get",
    )
    if not current.get("releases"):
        sys.exit(f"track {args.track} is serving nothing")
    release = current["releases"][0]
    release["releaseNotes"] = [
        {"language": one, "text": args.text_file.read_text().strip()}
        for one in languages(talk, edit)
    ]
    check(
        talk.put(
            f"{API}/applications/{PACKAGE}/edits/{edit}/tracks/{args.track}",
            json={"track": args.track, "releases": [release]},
            timeout=60,
        ),
        "tracks.update",
    )
    check(talk.post(f"{API}/applications/{PACKAGE}/edits/{edit}:commit", timeout=300), "commit")
    print(f"track {args.track} → {release['name']} note replaced")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    steps = parser.add_subparsers(required=True)

    steps.add_parser("state", help="what the tracks are serving").set_defaults(run=state)

    one = steps.add_parser("upload", help="send a bundle and put it on a track")
    one.add_argument("aab", type=pathlib.Path)
    one.add_argument("--track", required=True, help="internal / alpha / beta / production")
    one.add_argument("--name", help="what the release is called in the console")
    one.add_argument(
        "--text-file",
        type=pathlib.Path,
        help="what changed, for testers. Without it the listing sheets are used",
    )
    one.set_defaults(run=upload)

    one = steps.add_parser("notes", help="rewrite a serving release's note")
    one.add_argument("--track", required=True)
    one.add_argument("--text-file", type=pathlib.Path, required=True)
    one.set_defaults(run=notes)

    args = parser.parse_args()
    args.run(args)
