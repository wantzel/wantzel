# "there is an include further down this file" -- only when there is one.
#
# The hint answers the most common cause of `undeclared identifier`: the name exists, but
# the include or import that declares it comes later in the file. It used to look for the
# WORD include anywhere below, so a comment or a string that mentioned it was enough, and
# the reader went looking for an include that was not there. It now looks at the start of
# a line, where an include or an import actually stands.
. "$ROOT/tests/helpers.sh"

# 1. the word in a comment and in a string, no include below: no hint
cat > "$T/word.wz" <<'WZ'
procedure p;
begin
  helper.run;
end;
// include "helper.wz" would go here, but it does not
var s: str;
begin s := "include this"; p; end.
WZ
"$WANTZEL" "$T/word.wz" "$T/out" >"$T/cerr" 2>&1 && { echo "word.wz compiled"; exit 1; }
assert_contains "the name is reported" "$(cat "$T/cerr")" "undeclared identifier: helper.run"
if grep -q "further down" "$T/cerr"; then
  echo "a hint about a later include appeared where there is none:"; sed 's/^/  /' "$T/cerr"; exit 1
fi

# 2. an import below: the hint names an import
cat > "$T/imp.wz" <<'WZ'
procedure p;
begin
  helper.run;
end;
import io;
begin p; end.
WZ
"$WANTZEL" "$T/imp.wz" "$T/out" >"$T/cerr" 2>&1 && { echo "imp.wz compiled"; exit 1; }
assert_contains "an import below is named" "$(cat "$T/cerr")" \
  "there is an import further down this file; a name is only visible after the import that declares it"

# 3. an include below, indented: the hint names an include
mkdir -p "$T/inc"
echo 'procedure helper.run; begin end;' > "$T/inc/helper.wz"
cat > "$T/inc/main.wz" <<'WZ'
procedure p;
begin
  helper.run;
end;
  include "helper.wz";
begin p; end.
WZ
"$WANTZEL" "$T/inc/main.wz" "$T/out" >"$T/cerr" 2>&1 && { echo "main.wz compiled"; exit 1; }
assert_contains "an include below is named" "$(cat "$T/cerr")" \
  "there is an include further down this file; a name is only visible after the include that declares it"
echo "the hint appears for an include or an import below, and not for the word alone"
