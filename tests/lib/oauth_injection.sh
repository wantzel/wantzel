# lib/oauth.wz: nothing a client sends ends up in a response header or a page as markup.
#
# The authorization endpoint writes the client's redirect_uri and state into the Location
# header of its 302, and the client's redirect_uri and name into the sign-in page. A
# carriage return and line feed in either (sent percent-encoded, decoded by the server)
# would add headers of the attacker's choosing to the reply; a quote or an angle bracket
# would add markup to the page. So:
#   - /register refuses a redirect_uri with a control character, a space, a quote or an
#     angle bracket, and one that is not http:// or https://;
#   - /authorize (GET and POST) refuses such a redirect_uri or state;
#   - the client name is escaped on the page;
#   - and the ordinary flow still ends in a 302 with the code and the state.
#
# TOETSGROEP: lib
# DEKT: lib/oauth.wz
. "$ROOT/tests/helpers.sh"
. "$ROOT/tests/lib/portlib.sh"

command -v curl >/dev/null 2>&1 || { echo "curl is missing"; exit 1; }

set -- $(free_ports 1)
port=$1
base="http://127.0.0.1:$port"

compile "$ROOT/examples/mcpoauth.wz" "$T/srv"
mkdir -p "$T/data"
"$T/srv" "$port" "$T/data" "$base" alice s3cret >"$T/server.log" 2>&1 &
pid=$!
cleanup() { kill "$pid" 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT

ready=0
for _ in $(seq 50); do
  if curl -s -m 2 -o /dev/null "$base/"; then ready=1; break; fi
  sleep 0.1
done
[ $ready -eq 1 ] || { echo "mcpoauth did not come up"; cat "$T/server.log"; exit 1; }

# register(json) -> prints the status on line 1 and the body after it
register() {
  curl -s -m 5 -o "$T/reg.body" -w '%{http_code}' -H 'Content-Type: application/json' \
       -d "$1" "$base/register"
}
clientid() { sed -n 's/.*"client_id":"\([0-9a-f]*\)".*/\1/p' "$T/reg.body"; }

chal="E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

# ---- registration refuses what could break out of a header or an attribute -------------
st=$(register '{"redirect_uris":["https://ok.example/cb\r\nSet-Cookie: pwned=1"]}')
assert_eq "a redirect_uri with CR LF is refused at registration" "$st" "400"
st=$(register '{"redirect_uris":["https://ok.example/cb\"><script>x</script>"]}')
assert_eq "a redirect_uri with a quote and angle brackets is refused" "$st" "400"
st=$(register '{"redirect_uris":["https://ok.example/c b"]}')
assert_eq "a redirect_uri with a space is refused" "$st" "400"
st=$(register '{"redirect_uris":["httpx://ok.example/cb"]}')
assert_eq "a redirect_uri that is not http(s):// is refused" "$st" "400"

# ---- a good client, with a name that is markup -----------------------------------------
st=$(register '{"redirect_uris":["https://ok.example/cb?x=1"],"client_name":"<script>alert(1)</script>"}')
assert_eq "an ordinary client registers" "$st" "201"
cid=$(clientid)
[ ${#cid} -eq 32 ] || { echo "no client_id in: $(cat "$T/reg.body")"; exit 1; }
ruri="https%3A%2F%2Fok.example%2Fcb%3Fx%3D1"

page=$(curl -s -m 5 "$base/authorize?client_id=$cid&redirect_uri=$ruri&state=abc&code_challenge=$chal&code_challenge_method=S256&response_type=code")
assert_contains "the sign-in page is shown" "$page" "<form"
case "$page" in
  *"<script>alert(1)</script>"*) echo "the client name reached the page as markup"; exit 1 ;;
esac
assert_contains "the client name is escaped on the page" "$page" "&lt;script&gt;alert(1)&lt;/script&gt;"

# ---- a state with CR LF: refused on GET and on POST, and no header is added -------------
evil="abc%0d%0aSet-Cookie:%20pwned=1"
st=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$base/authorize?client_id=$cid&redirect_uri=$ruri&state=$evil&code_challenge=$chal&code_challenge_method=S256&response_type=code")
assert_eq "GET /authorize refuses a state with CR LF" "$st" "400"

curl -s -m 5 -D "$T/post.head" -o /dev/null \
     --data "client_id=$cid&redirect_uri=$ruri&state=$evil&code_challenge=$chal&user=alice&secret=s3cret" \
     "$base/authorize"
head1=$(head -1 "$T/post.head" | tr -d '\r')
assert_contains "POST /authorize refuses a state with CR LF" "$head1" " 400"
if grep -qi '^set-cookie: *pwned' "$T/post.head"; then echo "a header was injected through state:"; cat "$T/post.head"; exit 1; fi

evil2="abc%22%3E%3Cscript%3Ex%3C%2Fscript%3E"
st=$(curl -s -m 5 -o /dev/null -w '%{http_code}' --data "client_id=$cid&redirect_uri=$ruri&state=$evil2&code_challenge=$chal&user=alice&secret=s3cret" "$base/authorize")
assert_eq "POST /authorize refuses a state with a quote and angle brackets" "$st" "400"

# ---- the ordinary flow still works -------------------------------------------------------
curl -s -m 5 -D "$T/ok.head" -o /dev/null \
     --data "client_id=$cid&redirect_uri=$ruri&state=xyz-123_ok.~&code_challenge=$chal&user=alice&secret=s3cret" \
     "$base/authorize"
head1=$(head -1 "$T/ok.head" | tr -d '\r')
assert_contains "a correct sign-in redirects" "$head1" " 302"
loc=$(grep -i '^location:' "$T/ok.head" | tr -d '\r')
assert_contains "back to the registered uri, with its own query kept" "$loc" "https://ok.example/cb?x=1&code="
assert_contains "and the state unchanged" "$loc" "&state=xyz-123_ok.~"

echo "nothing a client sends reaches a header or the page as markup; the ordinary flow still redirects"
