# Getting your database key

WeChat encrypts the chat databases it keeps on your Mac. To read them,
GreenBubbles needs your account's key. This page shows how to copy that key
out of your own running WeChat app. You only do this once.

The [README](../README.md#getting-your-database-key) has the short version.

![Account key capture and per-database key derivation](../assets/key-flow.svg)

## Preserve the primary WeChat installation

Do not re-sign `/Applications/WeChat.app` as a setup step in this fork.
A live attempt with WeChat 4.1.15 failed to launch after deep ad-hoc signing;
the official vendor-signed application had to be restored. Do not disable
SIP, library validation, or other system protections to make capture work.

The current reader accepts an already acquired, database-verified key without
changing the application. The capture implementation still needs debugger
access and a fresh login. A protected official client is therefore a blocker,
not an instruction to modify its signature. A root-only task-port probe can
check access without reading memory, stopping the app, or setting breakpoints;
a successful probe alone does not prove acquisition works. On the restored
official WeChat 4.1.15 build 270134, both ordinary-user and root probes
returned `KERN_FAILURE` (5). The root report confirmed `memoryRead: false`
and `targetPaused: false`; the official signature still passed deep strict
verification and the same client process remained running. Repeating the
probe with administrator privileges is not a remedy for this observed blocker.

No isolated-copy acquisition procedure is accepted yet. A copied executable
can still share an account container with the main application; copying it
alone does not isolate user data. Validate application and data isolation,
process selection, secret handling, and restoration before asking an owner
to log in to an alternate client.

## With an existing key

Run `greenbubbles-acquire verify --passphrase-stdin --json` with the owner-only
key file redirected to stdin. Require `allVerified: true` before bounded
message-read acceptance. Never print or paste the key. Verification does not
change WeChat or prove history/media completeness.

## Capture in an independently validated environment

`greenbubbles-acquire preflight` reports whether the current process can use
the existing capture path. When blocked, stop; no signing operation is part
of the CLI. When acquisition has independently been made safe, the owner
starts `capture`, waits for the attach event, then handles logout/login.
Candidates are verified before being written to a private file. A successful
capture must still be followed by full `verify` and a bounded reader check.

## Command options

```sh
greenbubbles-acquire preflight [--json] [--db-root <path>]
greenbubbles-acquire capture [--output <path>] [--timeout-seconds 300] \
  [--db-root <path>] [--overwrite]
greenbubbles-acquire verify --passphrase-stdin [--db-root <path>]
```

- **`preflight`** checks that WeChat is installed and running, whether it has
  been re-signed, whether `lldb` is available, whether you are root, and how
  many databases it found. It exits with an error if anything blocks the
  capture. `--json` prints the report as JSON.
- **`capture`** runs the same checks, then waits for you to log out and back
  in. `--timeout-seconds` changes the 300-second wait. `--output` saves the key
  somewhere other than `~/.greenbubbles-acquire/passphrase.txt`. It never
  replaces an existing key file unless you add `--overwrite`.
- **`verify`** checks a saved key against your databases without touching
  WeChat. Pipe the key file into it. Use it after WeChat creates new database
  files; the same key opens them, so you don't need to capture again.
- **`--db-root`** points at a specific WeChat data folder. Normally the tool
  picks the account whose data was written most recently.

The WeChat version is shown for information only. The tool does not refuse a
version it hasn't seen, but it has only been tested on WeChat 4.1.12 and 4.1.13.

## Candidate validation

The capture breakpoint filters for SQLCipher 4 PBKDF2 parameters (32-byte
password, 16-byte salt, SHA512, 256000 rounds). A parameter match is only a
candidate: the capture loop verifies it against the inventoried database
page-1 HMACs before detaching. A rejected candidate resumes the process and
continues within the original timeout, including across process restarts.
No unverified candidate is saved. Final verification still reports how many
inventoried salts were covered; use `verify` to require complete coverage.

This addresses the premature-candidate failure described in upstream issue
#20. Automated process-loop and cryptographic tests do not establish live
compatibility with every WeChat 4.1.15 build. A real capture, full inventory
verification, and bounded message read remain the acceptance steps.

## If something goes wrong

The capture never saves a key it could not verify. If anything fails, you are
left with no key file rather than a wrong one.

- **"Hardened Runtime is still active":** debugger access is blocked. Preserve
  the official application; do not re-sign it as a workaround.
- **Timed out:** you didn't log out and back in within the time limit. Run
  `capture` again. An idle, logged-in WeChat never reveals the key.
- **Verification failed:** the captured value didn't open your databases, so
  nothing was saved. Check that you logged back into the same account.
- **WeChat updated:** verify any existing key before attempting acquisition.
  Keep the updated official application intact.

## Where the key is saved

The key is saved as 64 hexadecimal characters in
`~/.greenbubbles-acquire/passphrase.txt`. The file can be read only by your
account (mode `0600`, in a `0700` folder). It is not encrypted; those file
permissions are what protect it. The key never appears on the command line, in
a report, or in a log.

To use a key saved somewhere else, or to read a second account or a backup,
create a [query profile](QUERY_PROFILES.md). You can also pipe a key directly
into a command:

```sh
cat <passphrase-file> | greenbubbles conversations list \
  <db_storage-directory> --passphrase-stdin --limit 20
```

If you think the key has leaked, see
[OPERATIONAL_RESPONSE_PLAN.md](OPERATIONAL_RESPONSE_PLAN.md). Because the key
can't be changed, the response is about finding and removing copies.

## How it works

You don't need this section to use GreenBubbles.

WeChat uses SQLCipher to encrypt each database file. Your account has one
32-byte key. For each file, WeChat combines that key with a random value stored
at the start of the file (the salt) to make the file's own encryption key. So
there is one account key, not one key per file or table. See the
[SQLCipher design](https://www.zetetic.net/sqlcipher/design/).

WeChat makes those per-file keys only while it opens its databases, which
happens when you log in. It does this by calling a macOS system function,
`CCKeyDerivationPBKDF`. That is the one moment the account key can be seen, and
it is why you have to log out and back in.

`greenbubbles-acquire capture` does this:

1. Attaches Apple's `lldb` debugger to WeChat and pauses on
   `CCKeyDerivationPBKDF` only when the password passed to it is exactly 32
   bytes long.
2. When you log back in, it reads those 32 bytes once (from register `x1` on
   Apple silicon, `rsi` on Intel), then detaches. It reads nothing else and
   changes nothing in WeChat. Because it pauses on a macOS function rather than
   on WeChat's own code, it does not depend on a particular WeChat version.
3. On WeChat 4.1.13, logging out ends the WeChat process and logging in starts
   a new one. The tool notices and follows the new process.
4. For each database file, it computes the file's key on your Mac
   (PBKDF2-HMAC-SHA512, 256,000 rounds, with that file's 16-byte salt).
5. It proves each computed key is correct by checking SQLCipher 4's
   authentication code on the file's first page. A key that fails this check is
   never saved.

Only the account key is saved. The per-file keys exist in memory only during
the check and are then erased.

GreenBubbles features that don't read live WeChat data, such as opening an
existing backup, never use this capture.

## What has been tested

- **2026-08-27, WeChat 4.1.12:** a test with made-up data reproduced the read
  and key computation exactly. Then a real capture on the author's own Mac and
  account verified all 25 databases. A database WeChat created later was
  verified with `verify` using the same key, without a second capture.
- **2026-08-28, WeChat 4.1.13:** after WeChat auto-updated and was re-signed, a
  capture verified all 26 databases in 45 seconds. Logging out ended the WeChat
  process and logging in started a new one; the capture followed it.

That is two successful runs on one Mac and one account. It is not a promise
that it will work on your Mac, your WeChat version, or your account.

## Credits

The capture method is ported from the MIT-licensed
[`TANGandXUE/wcdb-key-tool`](https://github.com/TANGandXUE/wcdb-key-tool),
which credits kkocdko, wxchat-export, and ylytdeng/wechat-decrypt. See
[NOTICE.md](../NOTICE.md). GreenBubbles does not download or run that tool; it
reimplements the method.

How other projects get the same key, and why this method was chosen, is in
[`archive/ACQUISITION_FEASIBILITY.md`](archive/ACQUISITION_FEASIBILITY.md).
