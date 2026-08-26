#!/usr/bin/env bash
#
# publish-deck.sh — render POSC 8410 slide deck(s) and publish them to the live site.
#
#   ./publish-deck.sh 01_Introduction
#   ./publish-deck.sh 01_Introduction 02_R_Foundations     # several at once
#   ./publish-deck.sh --no-publish 01_Introduction         # stop before going live
#   ./publish-deck.sh --list                               # show available decks
#
# WHY THIS EXISTS
# A Quarto reveal.js deck is not a single file. The .html is a shell that loads
# reveal.js from site_libs/, its generated plots from <deck>_files/, and its
# pictures from images/. Copying only the .html gives you a page that renders as
# unstyled text with broken images — which is exactly how this site broke before.
# This script always moves a deck together with everything it depends on, then
# verifies every asset reference resolves BEFORE anything reaches the live site.
#
# Paths can be overridden with POSC8410_SLIDES / POSC8410_SITE if you move things.

set -euo pipefail

# Force a UTF-8 locale. Without it R falls back to ASCII, and output like
# dplyr::glimpse() silently swaps its "…" truncation marker for "~" — so a
# render from a bare shell produces uglier slides than the same render from
# Positron. Costs nothing; prevents a diff you would otherwise chase.
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

SLIDES_DIR="${POSC8410_SLIDES:-$HOME/Dropbox/Clemson/Teaching/POSC_8410/Fall_2026/Slides}"
SITE_DIR="${POSC8410_SITE:-$HOME/Dropbox/Website/will-horne.github.io}"
SUBDIR="posc-8410"
BRANCH="main"

bold=$(tput bold 2>/dev/null || true); dim=$(tput dim 2>/dev/null || true)
red=$(tput setaf 1 2>/dev/null || true); grn=$(tput setaf 2 2>/dev/null || true)
ylw=$(tput setaf 3 2>/dev/null || true); rst=$(tput sgr0 2>/dev/null || true)

step() { printf "\n%s==>%s %s%s%s\n" "$grn" "$rst" "$bold" "$*" "$rst"; }
warn() { printf "%s warning:%s %s\n" "$ylw" "$rst" "$*"; }
die()  { printf "%serror:%s %s\n" "$red" "$rst" "$*" >&2; exit 1; }

PUBLISH=1
DECKS=()
for arg in "$@"; do
  case "$arg" in
    --no-publish) PUBLISH=0 ;;
    --list)
      [ -d "$SLIDES_DIR" ] || die "slides dir not found: $SLIDES_DIR"
      basename -s .qmd "$SLIDES_DIR"/*.qmd | sed 's/^/  /'
      exit 0 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $arg" ;;
    *)  DECKS+=("${arg%.qmd}") ;;   # tolerate a trailing .qmd
  esac
done

[ ${#DECKS[@]} -gt 0 ] || die "no deck named. Try: $(basename "$0") --list"
[ -d "$SLIDES_DIR" ]   || die "slides dir not found: $SLIDES_DIR"
[ -d "$SITE_DIR" ]     || die "site dir not found: $SITE_DIR"
command -v quarto >/dev/null || die "quarto not on PATH"

DEST="$SITE_DIR/$SUBDIR"
mkdir -p "$DEST/images"

# ---------------------------------------------------------------- render
for deck in "${DECKS[@]}"; do
  [ -f "$SLIDES_DIR/$deck.qmd" ] || die "no such deck: $deck.qmd (try --list)"
done

step "Rendering ${#DECKS[@]} deck(s)"
for deck in "${DECKS[@]}"; do
  printf "  %s\n" "$deck"
  ( cd "$SLIDES_DIR" && quarto render "$deck.qmd" --quiet )
done

# ---------------------------------------------------------------- copy
step "Copying decks and their assets into $SUBDIR/"
BUILT="$SLIDES_DIR/_site"

# site_libs is shared by every deck; ship it once, refresh if Quarto updated it.
if [ ! -d "$DEST/site_libs" ] || [ "$BUILT/site_libs" -nt "$DEST/site_libs" ]; then
  printf "  site_libs/ (shared reveal.js runtime)\n"
  rm -rf "$DEST/site_libs"
  cp -R "$BUILT/site_libs" "$DEST/"
fi

for deck in "${DECKS[@]}"; do
  [ -f "$BUILT/$deck.html" ] || die "render produced no $deck.html — check the log above"
  printf "  %s.html\n" "$deck"
  cp "$BUILT/$deck.html" "$DEST/"
  if [ -d "$BUILT/${deck}_files" ]; then
    printf "  %s_files/\n" "$deck"
    rm -rf "$DEST/${deck}_files"
    cp -R "$BUILT/${deck}_files" "$DEST/"
  fi
done

# Copy across only the images these decks actually reference. Filenames contain
# spaces and percent-encoding, so this is done in python rather than shell globs.
step "Copying referenced images"
python3 - "$BUILT" "$DEST" "${DECKS[@]}" <<'PY'
import os, re, shutil, sys, urllib.parse
built, dest, decks = sys.argv[1], sys.argv[2], sys.argv[3:]
pat = re.compile(r'(?:src|href)="(images/[^"]+)"')
wanted = set()
for d in decks:
    p = os.path.join(built, f"{d}.html")
    if os.path.exists(p):
        with open(p, encoding="utf-8", errors="ignore") as fh:
            wanted |= {urllib.parse.unquote(m) for m in pat.findall(fh.read())}
copied = 0
for rel in sorted(wanted):
    src, dst = os.path.join(built, rel), os.path.join(dest, rel)
    if not os.path.exists(src):
        print(f"  MISSING SOURCE: {rel}"); continue
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if not os.path.exists(dst) or os.path.getmtime(src) > os.path.getmtime(dst):
        shutil.copy2(src, dst); copied += 1
        print(f"  {rel}")
print(f"  ({len(wanted)} referenced, {copied} copied or refreshed)")
PY

# ---------------------------------------------------------------- verify
step "Building the site and verifying every asset resolves"
( cd "$SITE_DIR" && quarto render --quiet )

python3 - "$SITE_DIR/_site/$SUBDIR" "${DECKS[@]}" <<'PY' || exit 1
import os, re, sys, urllib.parse
root, decks = sys.argv[1], sys.argv[2:]
pat = re.compile(r'(?:src|href)="([^"]+)"')
bad = 0
for d in decks:
    p = os.path.join(root, f"{d}.html")
    if not os.path.exists(p):
        print(f"  {d}.html did not reach the built site"); bad += 1; continue
    with open(p, encoding="utf-8", errors="ignore") as fh:
        refs = pat.findall(fh.read())
    miss = []
    for r in refs:
        if r.startswith(("http://", "https://", "#", "mailto:", "data:", "//")):
            continue
        rel = urllib.parse.unquote(r.split("?")[0].split("#")[0])
        if rel and not os.path.exists(os.path.join(root, rel)):
            miss.append(rel)
    print(f"  {d}.html — {len(refs)} refs, {len(miss)} missing")
    for m in miss[:8]:
        print(f"      MISSING: {m}")
    bad += len(miss)
if bad:
    print("\n  Refusing to publish: the deck would render broken on the live site.")
    sys.exit(1)
print("\n  All assets resolve.")
PY

# ---------------------------------------------------------------- warn on index
for deck in "${DECKS[@]}"; do
  grep -q "$deck.html" "$DEST/index.qmd" 2>/dev/null || \
    warn "$deck.html is not linked from $SUBDIR/index.qmd — add a row so students can find it"
done

if [ "$PUBLISH" -eq 0 ]; then
  step "Stopping before publish (--no-publish)"
  printf "  Everything is staged in %s\n" "$DEST"
  exit 0
fi

# ---------------------------------------------------------------- ship
step "Committing and pushing $BRANCH"
cd "$SITE_DIR"
if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -q -m "Publish POSC 8410 deck(s): ${DECKS[*]}"
  printf "  %s\n" "$(git log --oneline -1)"
else
  printf "  nothing to commit\n"
fi

# Pull first: the repo has been edited from more than one machine before, and a
# rejected push after a successful publish leaves main and gh-pages out of sync.
git pull --rebase --quiet origin "$BRANCH" || die "pull --rebase hit a conflict — resolve it, then re-run"
git push --quiet origin "$BRANCH"
printf "  pushed to origin/%s\n" "$BRANCH"

step "Publishing to gh-pages"
quarto publish gh-pages --no-prompt --no-browser

step "Done"
for deck in "${DECKS[@]}"; do
  printf "  https://will-horne.github.io/%s/%s.html\n" "$SUBDIR" "$deck"
done
printf "%s  GitHub Pages takes a minute or two; hard-refresh if you see the old version.%s\n" "$dim" "$rst"
