#!/usr/bin/env bash
set -euo pipefail

release="${1:-}"
if [[ -z "$release" || ! -d "$release" ]]; then
  echo "usage: $0 /opt/micupoker/releases/RELEASE_ID" >&2
  exit 2
fi

release=$(readlink -f "$release")
case "$release" in
  /opt/micupoker/releases/[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
  *) echo "refusing unexpected release path: $release" >&2; exit 1 ;;
esac

manifest="$release/.release-manifest.sha256"
[[ -r "$manifest" ]] || { echo "release manifest is missing" >&2; exit 1; }
[[ -x "$release/bin/micu_poker" ]] || { echo "release launcher is not executable" >&2; exit 1; }

if find "$release" \( ! -user root -o ! -group root \) -print -quit | grep -q .; then
  echo "release contains a non-root-owned path" >&2
  exit 1
fi

if find "$release" -perm /022 -print -quit | grep -q .; then
  echo "release contains a group/world-writable path" >&2
  exit 1
fi

while IFS= read -r -d '' link; do
  target=$(readlink -f "$link")
  case "$target" in
    "$release"/*) ;;
    *) echo "release symlink escapes its root: $link" >&2; exit 1 ;;
  esac
done < <(find "$release" -type l -print0)

(
  cd "$release"
  sha256sum --check --strict --quiet .release-manifest.sha256
)

expected=$(find "$release" -type f ! -name .release-manifest.sha256 | wc -l)
recorded=$(wc -l <"$manifest")
[[ "$expected" -eq "$recorded" ]] || {
  echo "release manifest count mismatch: expected=$expected recorded=$recorded" >&2
  exit 1
}

echo "release_integrity=passed files=$recorded path=$release"
