# Signing a Wantzel exe, and getting Windows to trust it

*Worked out 11 September 2026 on a Windows 11 machine managed by an organisation.*

On a Windows 11 machine managed by an organisation, a freshly compiled, unsigned `.exe` is
blocked. Two separate layers do this, and they are solved differently:

| message | title | solution |
|---|---|---|
| **ASR** (Defender Exploit Guard) | "Action blocked", with only a **Close** button | a trusted signature, or a folder exclusion from your administrator |
| **SmartScreen** | "Windows protected your PC", with **More info → Run anyway** | a trusted signature weakens it; reputation is solved with **Run anyway** |
| **SmartScreen set to Block** | "Windows protected your PC", **without** More info, only **Don't run** | only a trusted, recognised publisher; there is no manual way around it |

This is not about Wantzel. The ASR rule looks at reputation, not at content, so it blocks
every unknown binary whatever compiler made it — a correctly built hello-world from mingw
or Visual Studio hits exactly the same wall.

**Watch the app name in the dialog.** Only a signed exe can show a known publisher. Run an
unsigned binary and the publisher stays "Unknown" no matter how well your certificate is
installed. Always test with an exe from `bin/` that you signed.

**If the "More info" button is missing** and you only see "Don't run", your organisation
has set SmartScreen to **Block** rather than Warn. There is then no manual way out for
unknown apps, and a trusted signature is the only route: a recognised publisher is no
longer an "unknown app".

An Authenticode signature from a certificate the machine trusts satisfies the "trusted
list" criterion of the ASR rule and lets SmartScreen recognise the publisher.
Self-signed is fine, as long as the certificate is in the right machine stores.

> **There are no helper scripts for this yet.** What follows is the commands themselves —
> `osslsigncode` on Linux, `signtool` on Windows — which is the part that holds regardless of
> any wrapper around it. The reasoning about certificate stores, ASR and SmartScreen is what
> actually costs time to work out, and that is the reason this document exists.

## Step 1 — sign the exe

**From Linux** (WSL), with `osslsigncode`:

```bash
sudo apt install osslsigncode      # once
./signexe.sh bin/hello.exe          # signs in place, self-signed
for f in bin/*.exe; do ./signexe.sh "$f"; done   # everything in bin/
```

The first time, `signexe.sh` creates a self-signed code-signing certificate in
`~/.wantzel-sign`:

- `wantzel.crt` — the certificate, to import on Windows
- `wantzel.key` — the private key (stays on your machine)
- `wantzel.pfx` — the same, in the format Windows imports easily

**On Windows**, with PowerShell as administrator, in one step including trusting the
certificate:

```powershell
.\sign-windows.ps1 -Exe .\bin\hello.exe
```

Two common mistakes here:

- **"running scripts is disabled on this system"** — the PowerShell execution policy
  blocks the `.ps1`. Run it like this instead, which bypasses the policy for that one call
  and changes nothing permanently:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\sign-windows.ps1 -Exe .\bin\hello.exe
  ```

  Or relax the policy once for your account:
  `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

- **Not administrator.** The script writes the certificate to the machine stores
  (`LocalMachine\Root` and `TrustedPublisher`), and that is only possible from an
  **elevated** PowerShell (right-click → "Run as administrator"). Without admin, trusting
  fails silently and ASR blocks the exe anyway.

## Step 2 — trust the certificate

This is the step that goes wrong most often. The certificate has to be in the stores of
the **local computer**, not your user account, and in **two** folders:

- **Trusted Root Certification Authorities** — makes the signature chain valid.
- **Trusted Publishers** — makes the publisher "known".

Putting it in **Personal** does not count. If it is there, move it.

Open the right console with **Windows + R → `certlm.msc`** (that is the local computer;
`certmgr.msc` is your user account and does not work here).

Importing through the console:

1. Right-click **Trusted Root Certification Authorities → Certificates**.
2. **All Tasks → Import**, pick the file. From WSL the path is
   `\\wsl.localhost\Ubuntu\home\<you>\.wantzel-sign\wantzel.crt` (or `wantzel.pfx`).
3. Repeat for **Trusted Publishers → Certificates**.

Import only the "Wantzel Self-Signed" certificate. Leave your organisation's own
certificates alone.

Check you have the right certificate: double-click it, **Details** tab, **Thumbprint**
field, and compare with the SHA-1 that `signexe.sh` shows when it creates the certificate
(or `openssl x509 -in ~/.wantzel-sign/wantzel.crt -noout -fingerprint -sha1`).

## Step 3 — run it

Run `bin\hello.exe`. What you may see:

- **It runs straight away:** the chain works.
- **SmartScreen with publisher "Wantzel Self-Signed" and More info:** the signature is
  recognised; only the reputation layer still complains because the exe is new. Click
  **More info → Run anyway**. After running once that fades. Reputation cannot be removed
  with a certificate, only with "Run anyway" or a public EV certificate.
- **Still "Unknown publisher" or a hard ASR block:** the certificate is not in the Local
  Machine stores, or Windows has not picked up the change yet. Log out and back in or
  restart, and check you used `certlm.msc` and not `certmgr.msc`.

## Known weaknesses of self-signing

- **Timestamp.** `signexe.sh` adds an RFC 3161 timestamp from `timestamp.digicert.com` by
  default (overridable through an environment variable), so the signature stays valid after the certificate
  expires and Windows trusts it sooner. Without a network the script falls back to signing
  without a timestamp.
- **Reputation stays at zero.** SmartScreen may still flag a new exe the first time, even
  with a trusted certificate. Only a public EV certificate removes that immediately; for
  your own development work "Run anyway" is the normal route.
- **Your machine only.** A self-signed certificate is trusted only on the machine where
  you imported it. To distribute to others you need a public CA certificate, or you get
  the exe cleared by Microsoft through the Security Intelligence portal ("Incorrectly
  detected").

## If signing does not work on your managed machine

Some organisations enforce the ASR rule or SmartScreen so tightly through MDM that a
locally trusted self-signed certificate does not count. Signing then does not help as a
matter of principle: on an MDM-managed device you usually cannot write those stores, and
the ASR policy ignores locally added certificates.

Two real ways out. Ask your administrator to roll out your certificate by policy, or to
add a folder exclusion for your development directory — that is the intended route and
does not weaken the rule elsewhere. Or use a fresh Windows without that policy, which is
what the next section is about.

For a release you give to others you can also submit the exe to Microsoft as a false
positive through the Security Intelligence portal
(`https://www.microsoft.com/en-us/wdsi/filesubmission`).

## Windows Sandbox: a clean Windows, no ASR

Windows Sandbox is a lightweight, disposable Windows that Windows itself ships. It starts
fresh, runs separately from your normal Windows, and does **not** contain the ASR policy
that blocks an unsigned `.exe`. Close the window and everything is gone.

This is the simplest way to see that a fresh Wantzel build runs on a real Windows, without
running into managed security and without signing anything. The block on a managed laptop
comes from an MDM policy in *that* Windows, not in the fresh Windows the sandbox sets up
each time.

### Once: enable Windows Sandbox

Requires Windows 10/11 **Pro** or **Enterprise** (not Home) and virtualisation enabled in
the BIOS. In an **elevated** PowerShell:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName "Containers-DisposableClientVM" -All
```

Restart afterwards. "Windows Sandbox" is now in the Start menu.

### Put the exes somewhere the sandbox can reach

Windows Sandbox cannot reliably mount a `\\wsl.localhost` path, so copy the builds to an
ordinary Windows folder first. In a **Windows** PowerShell (not WSL):

```powershell
New-Item -ItemType Directory -Force C:\wantzel-share | Out-Null
Copy-Item \\wsl.localhost\Ubuntu\home\<you>\wantzel\bin\*.exe C:\wantzel-share\
```

The included `win-sandbox.wsb` mounts a host folder into the sandbox; set `HostFolder` in
that file to the folder you used.

### Start it

Double-click `win-sandbox.wsb` (copy it to Windows first if needed), or from PowerShell:

```powershell
C:\wantzel-share\win-sandbox.wsb
```

The sandbox opens and mounts the folder on the desktop as `wantzel`.

### Do NOT run the exe straight from the mounted folder

Starting a `.exe` directly from the mounted folder gives **"Access denied"**. Two things
cause this:

- **Executing from the shared folder** goes through the VirtIO share, and Windows often
  does not allow execute there.
- **Permissions.** Files written from WSL through `/mnt/c` to the host folder get an ACL
  the sandbox user `WDAGUtilityAccount` cannot reach. Symptom: some exes copy fine, others
  say you are not authorised.

### The way that works: zip on the host, unpack in the sandbox

This avoids both problems at once. Unpack inside the sandbox and the sandbox user owns the
files (full rights), and `C:\wantzel` is a local disk, so you are not running from the
share.

**Host side** (from WSL or Windows), zip the exes:

```sh
cd ~/wantzel
for e in hello cat primes httpd mcpfiles; do ./bin/wantzel examples/$e.wz /tmp/$e.exe; done
( cd /tmp && zip -j wantzel-exes.zip hello.exe cat.exe primes.exe httpd.exe mcpfiles.exe )
cp /tmp/wantzel-exes.zip /mnt/c/wantzel-share/
```

**In the sandbox**, unpack to a local folder and run:

```powershell
Expand-Archive C:\Users\WDAGUtilityAccount\Desktop\wantzel\wantzel-exes.zip C:\wantzel -Force
cd C:\wantzel
.\hello.exe
```

Networking is on, so `httpd.exe` and `mcpfiles.exe` work too.

If you do share loose files instead, level the permissions with `icacls` so each file
inherits the folder's normal rights, then copy to a local folder inside the sandbox before
running:

```powershell
icacls "C:\wantzel-share\*" /reset
```

## Distribution and selling: which certificate for what

Building is free: the compiler makes a working Windows exe at no cost and with no
registration. What costs money and registration is not the building but the *trust* — an
exe that runs on someone else's machine without a warning. Pick the route that fits your
goal:

| goal | certificate | cost | works |
|---|---|---|---|
| your own machines, testing | self-signed (`signexe.sh`) | free | only after importing the cert; **not** on a managed device |
| managed work device | rolled out by IT, or a folder exclusion | — | only if your administrator allows it |
| selling, wide audience | **OV** from a public CA | ~200–400/year | everywhere, once reputation builds |
| selling without the SmartScreen hurdle | **EV** from a public CA | ~350–700/year | everywhere, clean immediately |

### Signing with a purchased certificate

Since June 2023 the private key of a public code-signing certificate has to live on
**hardware** (USB token or cloud HSM) — you no longer get a `.pfx`. So you sign on Windows
with the token plugged in, not from WSL with `osslsigncode`.

1. Buy an OV or EV certificate from a CA (DigiCert, Sectigo, or Certum for a cheaper
   option). For a company you will need a business registration.
2. Go through the business verification (days to weeks). You get a token or cloud-HSM
   access.
3. Sign with `signtool` (Windows SDK). The included `sign-release.ps1` does this with the
   right distribution parameters:

   ```powershell
   .\sign-release.ps1 -Exe .\bin\hello.exe
   ```

   Underneath: `signtool sign /fd sha256 /tr <timestamp> /td sha256 /a <exe>`. The `/a`
   picks the certificate on the token automatically; with `-Thumbprint` you point at a
   specific one.

4. EV removes the SmartScreen warning immediately. OV builds reputation over time and
   downloads; until then customers still see "More info → Run anyway" the first time.

**Installers** (Inno Setup, WiX/MSI) are signed with exactly the same `signtool` command:
sign both the installer and the exes inside it.
