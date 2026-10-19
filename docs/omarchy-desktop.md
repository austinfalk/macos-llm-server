# The Mac's desktop and SSH, from an Omarchy machine

How to reach the server Mac itself from an [Omarchy](https://omarchy.org)
machine: its desktop over Screen Sharing with Remmina, smoother video and sound
with Sunshine and Moonlight, and a shell over SSH. The clients do not need any
of it ([omarchy-client.md](omarchy-client.md)). But the model server runs in
your login session on the Mac, so after the Mac restarts, the desktop is how
you log in and start it again. Follow it the way you follow the client guide:
one step at a time, with its check. Anything that needs `sudo` or a GUI is the
user's. Working on Omarchy 4.0.5 in October 2026 with Remmina 1.4.43,
moonlight-qt 6.2.0, Tailscale 1.104.1 and 1Password 8.12.40.

**Before you start.** The Omarchy machine is on the tailnet (the client guide,
step 1). On the server, the owner has:

- pasted the current `config/tailscale-policy.hujson` into the admin console
  (the [README](../README.md), step 2). It allows Screen Sharing, `tcp:5900`,
  and Sunshine's ports.
- run `sudo sh scripts/4-harden.sh` (README, step 6), which limits Screen
  Sharing and Sunshine to the tailnet. `sudo sh scripts/verify.sh` then
  reports "firewall loaded: Screen Sharing (5900), Kerberos (88) and Sunshine
  from the tailnet only".

## 1. Screen Sharing with Remmina

On the Mac (the user, in the GUI): System Settings → General → Sharing →
**Screen Sharing** on; **Allow access for: Only these users** → your account;
**"VNC viewers may control screen with password" off**. The server's firewall
already limits it to the tailnet.

On Omarchy: `sudo pacman -S remmina libvncserver`. Remmina's VNC plugin needs
`libvncserver`, and TigerVNC cannot sign in to a Mac. With "VNC viewers may
control screen with password" off, the Mac offers only Apple's sign-in methods
(security types 30, 33, 35, 36), and Remmina's VNC plugin speaks type 30.

The connection, as a file, `~/.local/share/remmina/<machine>-mac.remmina`
(`chmod 600`; the folder `700`):

```ini
[remmina]
name=<machine> (Mac Screen Sharing)
protocol=VNC
server=<machine>:5900
username=<your Mac username>
password=
colordepth=16
quality=1
disablepasswordstoring=1
scale=1
```

Remmina asks for the Mac password on each connection and does not store it.
16-bit colour and "Medium" quality cut the data a lot, and text stays readable.

- **Lag.** Remmina cannot use the video encoding Apple's own client gets, so it
  sends compressed pixels, and a Retina screen is a lot of them. macOS draws
  each point as 2×2 pixels, and Screen Sharing sends the pixels. On the Mac,
  System Settings → Displays:
  - **Larger Text** (the end of the scale) is the easy step. On a 16" MacBook
    Pro it looks like 1168×755 and sends 2336×1510, 3.5 million pixels instead
    of 7.7 million at the default. Noticeably faster in use.
  - **A non-Retina mode** cuts that by four again: Advanced → **Show
    resolutions as list** → **Show all resolutions**, then pick one without
    "(HiDPI)". Text in Remmina gets softer, since it stretches the smaller
    image to the window.

  To see what the Mac is sending, over SSH (step 3):
  `system_profiler -json SPDisplaysDataType | grep -E '_spdisplays_(pixels|resolution)'`.
  `pixels` is what Remmina receives. Wired Ethernet helps too. For smooth
  video, see step 2.
- **Super key.** Turn on Remmina's **Grab all keyboard events** (toolbar), or
  Hyprland keeps Super shortcuts for itself.
- **No audio.** Normal: VNC carries none, and the Mac sends sound only to
  Apple's own client.
- The first connection to a Mac with no display attached can time out while it
  starts a virtual screen. Connect again.

**Check:** you see the Mac's screen (the login window, if nobody is logged in).
On the server, `verify.sh` shows Screen Sharing dropped from the local network
and allowed from the tailnet.

## 2. Sunshine and Moonlight (optional)

Smooth video and sound instead of Screen Sharing: **Sunshine** on the Mac
encodes the screen as H.264 or HEVC video with the Mac's hardware encoder, and
**Moonlight** on Omarchy plays it. Set up and verified on 2026-10-03 with
Sunshine v2026.914.233613 and moonlight-qt from `extra`: HEVC with hardware
decoding at both ends, over a direct tailnet connection, and much smoother than
Remmina.

**Decide first.** This adds a third-party service to a server otherwise kept to
built-in components, and it needs Screen Recording and Accessibility, which
give it full view and control of the Mac. Sunshine's macOS support is marked
experimental in its stable docs, and has open bugs that matter here:

- H.264 on macOS halves the frame rate in current releases (LizardByte/Sunshine
  #5697). Use **HEVC**.
- When the display sleeps, Sunshine has nothing to capture and Moonlight
  cannot connect (#5509). Item 5 below keeps the display awake on the charger.
- It needs a logged-in GUI session. With FileVault on, nothing streams after a
  restart until someone logs in (Screen Sharing works at the login window).
- With no monitor attached it needs a display to capture: an HDMI dummy plug
  or a BetterDisplay virtual screen (community reports; not in Sunshine's docs).

For admin work, step 1 is enough. **Keep step 1 set up either way.** It is the
way back in when Sunshine cannot help (see "When Sunshine fails" below).

### On the Mac (the user)

1. **Install** the signed `Sunshine-macOS-arm64.dmg` from
   [LizardByte/Sunshine releases](https://github.com/LizardByte/Sunshine/releases)
   (stable, not a pre-release), into /Applications. Prefer it to LizardByte's
   Homebrew tap, which has only a command-line formula with an ad-hoc
   signature. macOS ties Screen Recording and Accessibility for such a binary
   to that exact build, so they would likely need granting again after every
   `brew upgrade`. The app is signed with LizardByte's Developer ID and
   notarized, and keeps them.
2. **Permissions**, when asked on first launch: Screen Recording, Accessibility
   (keyboard and mouse), and Microphone or System Audio Recording for sound.
   Leave `audio_sink` empty. On macOS 14 and later, Sunshine captures system
   audio itself (PR #4209), and the docs' advice to install BlackHole is out of
   date. After Screen Recording, macOS offers **Quit & Reopen**. On the first
   run Sunshine hung there instead: still running, its web UI not answering.
   If so, quit it and open it again (`pkill -x Sunshine; open -a Sunshine`).
   Its log, `~/.config/sunshine/sunshine.log`, should then list
   `Found HEVC encoder: hevc_videotoolbox`.
3. **Settings**, in `~/.config/sunshine/sunshine.conf`:

   ```ini
   origin_web_ui_allowed = pc
   upnp = disabled
   ```

   `pc` means the web UI answers only on the Mac itself: https://localhost:47990
   in Safari on the Mac (through Remmina, or in person; the certificate is
   self-signed, so accept the warning), or from Omarchy through SSH (step 3):
   `ssh -L 47990:127.0.0.1:47990 <machine>`, then https://localhost:47990.
   Leave `bind_address` empty. Binding to the tailnet address would also move
   the web UI off localhost and lock you out of it. Sunshine treats tailnet
   addresses as LAN, so Sunshine does not encrypt the stream. It travels
   inside WireGuard.
4. **First run:** in the web UI, create the Sunshine username and password
   (store them in 1Password), and start Sunshine at login. It must be a login
   item, which runs in your GUI session, not a daemon.
5. **Keep the display awake on the charger:** `sudo pmset -c displaysleep 0`
   (undo: `sudo pmset -c displaysleep <minutes>`). Without it, with the lid
   shut, the display goes off the moment a Remmina session ends (Screen Sharing
   holds it on only while connected), and otherwise after a few idle minutes.
   Sunshine then logs "No display devices are active", so Moonlight cannot
   connect. With it, Moonlight shows the **lock screen** and you can type your
   password there. On battery the display still sleeps. With the lid shut the
   panel stays dark anyway; with it open, the screen stays on.
   (Amphetamine, or `caffeinate -d`, does the same while it runs.)

   **The Mac no longer locks when the display would have slept**, so let the
   screen saver lock it: System Settings → Lock Screen → **Start Screen Saver
   when inactive** (10 minutes here; the default is 20) with **Require password
   after screen saver begins or display is turned off** at **Immediately**.
   Input through Moonlight counts as activity. Amphetamine holds off the
   screen saver too, so the Mac does not lock while it runs (presumably
   `caffeinate -d` as well; not checked).
   Checked 2026-10-03: at 1 minute it locked, and Moonlight showed the lock
   screen and took the password.
6. **Firewall.** Sunshine listens on every network, like Screen Sharing. The
   server's pf anchor (`config/pf-screensharing.conf`) already drops its
   default ports (TCP 47984, 47989, 47990, 48010 and UDP 47998-48000) unless
   the connection comes from the tailnet. With Sunshine running,
   `sudo sh scripts/verify.sh` reports the web UI allowed from the Mac itself,
   and Sunshine dropped from the local network and allowed from the tailnet.
   Keep Sunshine's base `port` at its default, 47989, or the rules miss it.
7. **Tailnet policy:** `config/tailscale-policy.hujson` has the ports in the
   grant's `ip` list:

   ```
   "tcp:47984", "tcp:47989", "tcp:48010", "udp:47998-48000",
   ```

   Check them with the admin console's policy tests. 47990 (the web UI)
   stays out, because it is reached through SSH.

### On Omarchy

1. `sudo pacman -S moonlight-qt` (in `extra`). Intel graphics decode HEVC in
   hardware through VAAPI (`intel-media-driver`).
2. **Add the host** with **+** (top right): `<machine>` (MagicDNS) or its
   100.x address. Moonlight's own search will not find it, because that uses
   mDNS, which stays on the local network, where Sunshine is firewalled.
   Moonlight shows a PIN. Enter it in Sunshine's web UI → PIN. If adding times
   out, check the tailnet policy ("On the Mac", item 7):
   `nc -z -w 3 <machine> 47989`.
3. **Settings** (the gear in the main window; there is no settings screen
   during a stream, so end it with Ctrl+Alt+Shift+Q, change them, and start
   again): video codec **HEVC**, or **Automatic** as long as the statistics
   still show HEVC; **Capture system keyboard shortcuts**: in fullscreen (so
   Super goes to the Mac).
4. **Keys:** Ctrl+Alt+Shift+Q ends the stream, +Z releases the keyboard and
   mouse, +X toggles fullscreen, +S shows statistics. Moonlight does not send
   the Command key. **Right Option** is Command on the Mac.

No MTU change is needed. Moonlight caps packets for addresses like the
tailnet's at a size that fits Tailscale's.

**If the mouse lags**, the statistics (Ctrl+Alt+Shift+S) say where. High or
jumpy network latency means Wi-Fi: a cable on the Mac, or on both, helps most.
High rendering time or frame queue delay: turn off **V-Sync** and **Frame
pacing** in Moonlight's settings, which add a frame or more each. A 120 FPS
stream, if the Omarchy screen can show it, also moves the cursor twice as
often as 60. `tailscale status` on either machine should say `direct`, not
`relay`.

**Check:** the stream shows the Mac's screen with sound, Ctrl+Alt+Shift+S
reports HEVC with hardware decoding, and from another machine on the local
network (not the tailnet) the ports stay closed:
`nc -z -w 3 <Mac's LAN address> 47989` must fail.

### When Sunshine fails: back to Remmina

Screen Sharing (step 1) is built into macOS and shares nothing with Sunshine,
not its app, its ports or its permissions. So the Remmina connection keeps
working whatever happens to Sunshine. Use it when:

- **The Mac has restarted.** Sunshine runs only in a logged-in session, and
  Screen Sharing works at the login window. Log in through Remmina, and
  Sunshine and the model server start with your session. Once you are logged
  in, a locked screen is no reason to switch back. With the display awake
  ("On the Mac", item 5), Moonlight shows it and takes your password.
- **The stream is black or frozen**, or Moonlight cannot connect (the display
  slept, #5509). Check "On the Mac", item 5, connect with Remmina, or restart
  Sunshine over SSH (step 3): `pkill -x Sunshine; sleep 2; open -a Sunshine`.
  It runs in the menu bar, with no Dock icon.
- **Moonlight cannot find or pair with the host.** Sunshine's web UI is still
  reachable through the SSH tunnel above.

Connect with one or the other, not both at once (untested together).

## 3. SSH to the server (optional)

The clients need no shell on the server, since the key comes from 1Password.
But SSH is the way to administer the server from here (logs, `launchctl`,
`verify.sh`) without the desktop. The server accepts SSH keys only, and only
from the tailnet. The key is the one in its `~/.ssh/authorized_keys`, kept in
1Password and served by 1Password's SSH agent, so its private half never
leaves 1Password.

1. **1Password's SSH agent on:** 1Password → Settings → Developer → *Use the
   SSH agent*. It offers keys from the Personal or Private vault by default.
   For a key in another vault, add the vault to
   `~/.config/1Password/ssh/agent.toml`.
2. **`ssh` uses it, and only this key.** `SSH_AUTH_SOCK=~/.1password/agent.sock
   ssh-add -l` should list the key. With several keys in the agent it offers
   them in turn, and the server can give up ("Too many authentication
   failures") before reaching the right one, so name it. Save its public half
   straight from the agent, with no export from 1Password:

   ```sh
   SSH_AUTH_SOCK=~/.1password/agent.sock ssh-add -L | grep ' <key title>$' > ~/.ssh/<machine>.pub
   ```

   and add to `~/.ssh/config`, above any `Host *` block (with your Mac
   username):

   ```
   Host <machine>
       HostName <machine>
       User <you>
       IdentityFile ~/.ssh/<machine>.pub
       IdentitiesOnly yes
       IdentityAgent ~/.1password/agent.sock
   ```
3. **Check the host key before trusting it.** From Omarchy, without
   connecting: `ssh-keyscan -t ed25519 <machine> | ssh-keygen -lf -`. On the
   Mac (over Screen Sharing, step 1):
   `ssh-keyscan -t ed25519 localhost | ssh-keygen -lf -`, which avoids typing
   the host key's path. The `SHA256:` fingerprints must match in full. If they
   do not, stop.
4. **Connect:** `ssh <machine>` (MagicDNS; else the full
   `<machine>.<tailnet>.ts.net`), accept the fingerprint you just checked, and
   approve the key in 1Password.

**Check:** `ssh <machine> 'sw_vers -productVersion; /opt/homebrew/bin/splash-m1 --version; curl -s -o /dev/null -w "%{http_code}\n" 127.0.0.1:8000/ready'`
prints the macOS version, Splash's version, and 200 when the model server is
ready. A command run this way gets no login shell, so Homebrew's tools are not
on its `PATH`. Interactively (`ssh <machine>`) `splash-m1` works; in a one-off
command, use its full path. The server lives in your GUI login, so it runs only
while you are logged in on the Mac. After a restart, log in through Remmina
(step 1) first.

## Later

- **iPhone and iPad:** the Tailscale app with the same login; any chat app
  that takes a custom OpenAI-compatible base URL and API key (not yet chosen
  or tested here); **Screens** for the Mac's desktop, signing in with the Mac
  account. Avoid Chatbox on iOS: its key authentication to custom endpoints
  fails there (chatboxai/chatbox #3516).
- **blip** ([nixfred/blip](https://github.com/nixfred/blip)), iMessage on
  Omarchy. It has no AI features. It needs a Mac signed in to your Apple ID,
  logged in and awake, as its gateway. If that is the server, it needs Full
  Disk Access for macOS's SSH helper (`sshd-keygen-wrapper`), which its own
  README warns applies to **every** SSH key on the account, not just blip's.
  Decide that trade-off before installing it.
