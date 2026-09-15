# The VS Code extension must be complete enough to publish.
#
# Publishing needs a Marketplace account and a token, which is not something a test can
# do -- but everything that goes WRONG at publish time can be checked here, and finding it
# then means finding it at the worst moment.
#
# What vsce refuses, and what this therefore checks: a missing field, a declared license
# with no LICENSE file beside the manifest, a file the manifest points at that is not
# there, and a version that does not parse.
. "$ROOT/tests/helpers.sh"
cd "$ROOT/editors/vscode"

pkg=package.json
[ -f "$pkg" ] || { echo "editors/vscode/package.json is missing"; exit 1; }

# No python in this repository, so the manifest is read with grep. That is enough for the
# question asked here -- does a field exist and does the file it names exist -- and it
# keeps the test free of a JSON parser it would otherwise have to carry.
need_field() {
  grep -q "\"$1\"" "$pkg" || { echo "package.json has no \"$1\"; the Marketplace requires it"; exit 1; }
}
for f in name displayName description version publisher license repository engines categories; do
  need_field "$f"
done

# A declared license needs the file beside the manifest: vsce does not look upwards.
grep -q '"license"' "$pkg" && { [ -f LICENSE ] || {
  echo "package.json declares a license but editors/vscode/LICENSE is missing"
  echo "  vsce looks beside the manifest, not in the repository root"
  exit 1; }; }

# Every path the manifest points at must exist. These are the ones that break silently:
# a missing grammar means no highlighting and no error, a missing snippet file means the
# snippets simply never appear.
for rel in $(grep -oE '"\./[^"]+"' "$pkg" | tr -d '"'); do
  [ -e "$rel" ] || { echo "package.json points at $rel, which does not exist"; exit 1; }
done

# the version must be three numbers: the Marketplace rejects anything else
ver=$(grep -oE '"version"[^,]*' "$pkg" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
[ -n "$ver" ] || { echo "the version in package.json is not a plain x.y.z"; exit 1; }

# and a README, because the Marketplace page IS the README
[ -s README.md ] || { echo "editors/vscode/README.md is missing or empty; it becomes the Marketplace page"; exit 1; }

echo "the extension is packaging-complete (version $ver, license, README, every referenced file present)"
