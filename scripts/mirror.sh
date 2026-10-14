#!/usr/bin/env bash
# Push this package's own history to its public mirror, github.com/Yumankind/overblast-feedback-ios.
#
# The package is developed inside the monorepo, beside the worker whose `POST /v1/feedback` it calls
# and the feedback-reports contract both halves are held to, so a change to either is one
# commit and one review. The mirror is the public face of the same code, and it has to be a
# repository of its own because Swift Package Manager resolves a dependency BY URL AND TAG: an app
# declares `.package(url: "https://github.com/Yumankind/overblast-feedback-ios", from: "0.1.0")`, and
# what it gets is a checkout of that repository's root with `Package.swift` at the top.
#
# `git subtree split` rewrites this package's commits with the package directory as the root,
# deterministically (the same history produces the same commit ids), so every push is a
# fast-forward of the last one. `MIRROR_REMOTE` and `MIRROR_BRANCH` override the destination.
#
#   scripts/mirror.sh              push main
#   scripts/mirror.sh v0.1.0       push main, then tag that exact commit and push the tag
#
# THE TAG IS WHAT AN APP RESOLVES, so it is pushed last and only after the branch is up: a tag that
# points at a commit the mirror does not have yet is a dependency nobody can fetch.
set -euo pipefail
cd "$(dirname "$0")/../../.."
PREFIX=packages/overblast-feedback-ios
REMOTE="${MIRROR_REMOTE:-https://github.com/Yumankind/overblast-feedback-ios.git}"
BRANCH="${MIRROR_BRANCH:-main}"
TAG="${1:-}"

if [ -n "$(git status --porcelain -- "$PREFIX")" ]; then
  echo "mirror: $PREFIX has uncommitted changes; commit them first" >&2
  exit 1
fi

SPLIT="$(git subtree split --prefix="$PREFIX" HEAD 2>/dev/null)"
echo "mirror: $SPLIT -> $REMOTE $BRANCH"
git push "$REMOTE" "$SPLIT:refs/heads/$BRANCH"

if [ -n "$TAG" ]; then
  echo "mirror: tagging $SPLIT as $TAG"
  git push "$REMOTE" "$SPLIT:refs/tags/$TAG"
  echo "mirror: apps can now resolve .package(url: \"${REMOTE%.git}\", from: \"${TAG#v}\")"
fi
