#!/bin/bash
# publish-feed.sh — author, sign, and upload the PaperWalls curated feed.
#
# The local FEED_DIR is the source of truth: catalog.json plus
# content-addressed assets/ and thumbs/. The R2 bucket mirrors it.
#
#   ./publish-feed.sh add [--collection "Name"] <image files…>
#       Import images: sha256-named copy into assets/, 480px thumb into
#       thumbs/, entry appended to catalog.json (displayName from filename).
#       Duplicate content (same sha256) is skipped.
#
#   ./publish-feed.sh collection "Name" <id…|--all>
#       Set the collection on the given wallpapers (or every wallpaper).
#       Use "" as the name to clear it.
#
#   ./publish-feed.sh remove <id…|--all>
#       Remove entries by id (or empty the whole feed); orphaned
#       asset/thumb files are deleted.
#
#   ./publish-feed.sh publish
#       Sign catalog.json (needs PAPERWALLS_SIGNING_KEY in the environment)
#       and upload: assets/thumbs that the bucket doesn't have yet
#       (immutable cache headers), then manifest + signature (max-age=300).
#       Requires wrangler auth: `npx wrangler login` once beforehand.
#
#   ./publish-feed.sh status
#       Show the local manifest vs what the public URL currently serves.
#
# App side: the feed only appears on Macs with appCuratedEnabled=true, and
# only after the manifest verifies against the baked-in public key.

set -o errexit
set -o nounset
set -o pipefail

# --- CONFIG ----------------------------------------------------------
BUCKET="your-feed-bucket"                    # R2 bucket name (wrangler)
PUBLIC_URL="https://feed.example.com"        # public base URL of the bucket
THUMB_MAX_PX=480                             # matches the bundled thumbs
# Local feed source of truth. Override with FEED_DIR=… ./publish-feed.sh …
FEED_DIR="${FEED_DIR:-$(cd "$(dirname "$0")/.." && pwd)/FeedSource}"
# ----------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$FEED_DIR/catalog.json"

die() { echo "publish-feed: $*" >&2; exit 1; }

ensure_feed_dir() {
    mkdir -p "$FEED_DIR/assets" "$FEED_DIR/thumbs"
    if [[ ! -f "$MANIFEST" ]]; then
        printf '{\n  "version": 2,\n  "wallpapers": []\n}\n' > "$MANIFEST"
    fi
}

# manifest_edit <python expression working on `m` (the manifest dict)>
manifest_edit() {
    python3 - "$MANIFEST" "$@" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    m = json.load(f)
exec(sys.argv[2])
with open(path, "w") as f:
    json.dump(m, f, indent=2)
    f.write("\n")
PY
}

cmd_add() {
    local collection=""
    if [[ "${1:-}" == "--collection" ]]; then
        collection="${2:?--collection needs a value}"; shift 2
    fi
    [[ $# -ge 1 ]] || die "add needs at least one image file"
    ensure_feed_dir

    local file added=0
    for file in "$@"; do
        [[ -f "$file" ]] || die "not a file: $file"
        local ext; ext="$(tr '[:upper:]' '[:lower:]' <<< "${file##*.}")"
        case "$ext" in
            jpg|jpeg|png|heic|tiff) ;;
            *) echo "skip (unsupported .$ext): $file"; continue ;;
        esac

        local sha size base name id
        sha="$(shasum -a 256 "$file" | awk '{print $1}')"
        size="$(stat -f%z "$file")"
        base="$(basename "$file")"; base="${base%.*}"
        # "aurora-veil_2" → display "Aurora Veil 2", id "aurora-veil-2"
        name="$(sed -E 's/[-_]+/ /g' <<< "$base" | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) substr($i,2)}}1')"
        id="$(tr '[:upper:] _' '[:lower:]--' <<< "$base" | sed -E 's/[^a-z0-9-]//g; s/-+/-/g')"

        if grep -q "\"sha256\": \"$sha\"" "$MANIFEST"; then
            echo "skip (already in feed): $base"
            continue
        fi

        cp "$file" "$FEED_DIR/assets/$sha.$ext"
        sips --resampleHeightWidthMax "$THUMB_MAX_PX" -s format jpeg \
             "$file" --out "$FEED_DIR/thumbs/$sha.jpg" >/dev/null \
            || die "thumbnail generation failed for $file"

        export ENTRY_JSON="$(python3 -c '
import json, sys
print(json.dumps({
    "id": sys.argv[1], "displayName": sys.argv[2],
    "collection": sys.argv[3] or None,
    "image": "assets/" + sys.argv[4], "thumbnail": "thumbs/" + sys.argv[5],
    "sha256": sys.argv[6], "size": int(sys.argv[7]), "minAppVersion": None,
}))' "$id" "$name" "$collection" "$sha.$ext" "$sha.jpg" "$sha" "$size")"
        manifest_edit "
import json, os
entry = json.loads(os.environ['ENTRY_JSON'])
if any(w['id'] == entry['id'] for w in m['wallpapers']):
    entry['id'] += '-' + entry['sha256'][:6]
m['wallpapers'].append(entry)
" || die "manifest update failed for $file"
        echo "added: $name  (id: $id, $sha)"
        added=$((added + 1))
    done
    echo "==> $added added; feed now $(python3 -c "import json;print(len(json.load(open('$MANIFEST'))['wallpapers']))") wallpaper(s). Next: ./publish-feed.sh publish"
}

cmd_collection() {
    [[ $# -ge 2 ]] || die 'usage: collection "Name" <id…|--all>  ("" clears)'
    ensure_feed_dir
    local name="$1"; shift
    COLLECTION_NAME="$name" TARGET_IDS="$*" manifest_edit "
import os
ids = set(os.environ['TARGET_IDS'].split())
name = os.environ['COLLECTION_NAME'] or None
changed = 0
for w in m['wallpapers']:
    if '--all' in ids or w['id'] in ids:
        w['collection'] = name
        changed += 1
print(f\"collection {'cleared' if name is None else repr(name)} on {changed} wallpaper(s)\")
"
    echo "==> done. Next: ./publish-feed.sh publish"
}

cmd_remove() {
    [[ $# -ge 1 ]] || die "remove needs wallpaper id(s) or --all"
    ensure_feed_dir
    REMOVE_IDS="$*" manifest_edit "
import os
ids = set(os.environ['REMOVE_IDS'].split())
before = len(m['wallpapers'])
if '--all' in ids:
    m['wallpapers'] = []
else:
    m['wallpapers'] = [w for w in m['wallpapers'] if w['id'] not in ids]
print(f\"removed {before - len(m['wallpapers'])} entrie(s)\")
"
    # Drop asset/thumb files nothing references anymore.
    python3 - "$MANIFEST" "$FEED_DIR" <<'PY'
import json, os, sys
manifest, feed = sys.argv[1], sys.argv[2]
keep = set()
for w in json.load(open(manifest))["wallpapers"]:
    keep.add(os.path.basename(w["image"]))
    if w.get("thumbnail"):
        keep.add(os.path.basename(w["thumbnail"]))
for sub in ("assets", "thumbs"):
    d = os.path.join(feed, sub)
    for f in os.listdir(d):
        if f not in keep and not f.startswith("."):
            os.remove(os.path.join(d, f))
            print("deleted", sub + "/" + f)
PY
    echo "==> done. Next: ./publish-feed.sh publish (sync removals to the bucket)"
}

remote_has() {  # remote_has <key> → 0 if the public URL already serves it
    curl -sfI "$PUBLIC_URL/$1" >/dev/null 2>&1
}

cmd_publish() {
    ensure_feed_dir
    [[ -n "${PAPERWALLS_SIGNING_KEY:-}" ]] \
        || die "set PAPERWALLS_SIGNING_KEY (base64 Ed25519 private key) first"

    echo "==> signing manifest"
    swift "$SCRIPT_DIR/sign-manifest.swift" "$MANIFEST"

    echo "==> uploading new assets/thumbs (immutable, skipped if already in the bucket)"
    local sub file key
    for sub in assets thumbs; do
        for file in "$FEED_DIR/$sub"/*; do
            [[ -f "$file" ]] || continue
            key="$sub/$(basename "$file")"
            if remote_has "$key"; then
                echo "   have: $key"
            else
                npx wrangler r2 object put "$BUCKET/$key" --file "$file" \
                    --cache-control "public, max-age=31536000, immutable" --remote
            fi
        done
    done

    echo "==> uploading manifest + signature"
    npx wrangler r2 object put "$BUCKET/catalog.json" --file "$MANIFEST" \
        --content-type "application/json" --cache-control "max-age=300" --remote
    npx wrangler r2 object put "$BUCKET/catalog.json.sig" --file "$MANIFEST.sig" \
        --cache-control "max-age=300" --remote

    echo "✅ published — apps with appCuratedEnabled pick it up on their next sync (≤6 h, or relaunch)"
}

cmd_status() {
    ensure_feed_dir
    echo "local:  $(python3 -c "import json;print(len(json.load(open('$MANIFEST'))['wallpapers']))") wallpaper(s) in $MANIFEST"
    echo "remote: $(curl -sf "$PUBLIC_URL/catalog.json" | python3 -c "import json,sys
try: print(f\"{len(json.load(sys.stdin)['wallpapers'])} wallpaper(s) served\")
except Exception: print('empty or unparseable manifest')" )"
    if curl -sfI "$PUBLIC_URL/catalog.json.sig" >/dev/null; then
        echo "remote signature: present"
    else
        echo "remote signature: MISSING — the app will refuse the feed until publish runs"
    fi
}

case "${1:-}" in
    add)        shift; cmd_add "$@" ;;
    collection) shift; cmd_collection "$@" ;;
    remove)     shift; cmd_remove "$@" ;;
    publish)    cmd_publish ;;
    status)     cmd_status ;;
    *)          sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
