<p align="center"><img src="assets/logo.svg" width="112" height="112" alt=""></p>

<h1 align="center">Hirte</h1>

<p align="center">
  Your terminals and coding agents, in your pocket.<br>
  An iPhone and iPad client for <a href="https://github.com/herdrdev/herdr">herdr</a>, made for the iPhone Duo.
</p>

<p align="center">
  <a href="https://testflight.apple.com/join/4TTMAnRM">Join the TestFlight beta</a> ·
  <a href="https://hirte.dev">Website</a> ·
  <a href="#building">Build it yourself</a>
</p>

<p align="center">
  <a href="assets/demo.mp4"><img src="assets/demo.gif" width="640" alt="Hirte on the unfolded iPhone Duo: the terminal list next to an agent, answering it with Yes, then a shell"></a>
</p>

Hirte ("shepherd" in German) connects to your machines over SSH and shows every terminal that
herdr-core runs there: what each agent is doing, which ones are waiting for you, and a real terminal
to jump in when they are.

- **Everything at a glance**: terminals grouped by herdr spaces and tabs, agents under the shell that
  started them, progress, and the ones that need you first
- **A real terminal**, powered by [Ghostty](https://ghostty.org)'s libghostty-vt: key bar, hardware
  keyboards, arrow keys from the space bar's trackpad, links, scrollback and pinch to zoom
- **Answer in one tap**: Yes, No, Return or Esc for a blocked agent
- **Keys in the Secure Enclave**, optionally behind Face ID, or Ed25519 keys; import your own
  (Ed25519, ECDSA, RSA, also passphrase-protected), use a FIDO2 security key or log in with a
  password; host keys checked on every connect
- **Themes**: separate light and dark terminal themes, and a choice of fonts

On the iPad and the unfolded iPhone Duo, the terminal list and a terminal sit side by side. It
works on every iPhone and iPad with iOS 26 or later.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/screenshot-dark.png">
    <img src="assets/screenshot-light.png" width="700" alt="Hirte on the unfolded iPhone Duo: the terminal list next to an agent asking to run a database migration, with Yes, No, Return and Esc buttons">
  </picture>
</p>

> Hirte is an independent project. It is not affiliated with or endorsed by the herdr project; it
> speaks herdr-core's public protocol.

## Building

You need a Mac with Xcode 27, [`just`](https://github.com/casey/just),
[`xcbeautify`](https://github.com/cpisciotta/xcbeautify) and [pixi](https://pixi.sh) (for the Zig
compiler that builds libghostty-vt).

```sh
git clone --recurse-submodules https://github.com/glattziehen/hirte
cd hirte
just ghostty   # builds libghostty-vt into HerdrKit/Frameworks
just sim       # runs the app in the simulator
just test      # HerdrKit tests
```

To run it on your own iPhone, sign with your team: set `HIRTE_TEAM` and `HIRTE_BUNDLE_ID_PREFIX`
in `.envrc.local` (see `.envrc`), then `just phone`. `just` lists the other commands.

### Testing locally

`just sim` builds Hirte Dev and launches it in the simulator through Xcode's DeviceHub app.
The default is "iPhone 17 Pro"; use `HIRTE_SIMULATOR="Device name" just sim` to select another
installed simulator. Open Settings → Add Demo Machine to try the interface without an SSH host.
`just test` runs the HerdrKit tests. The debug launch arguments `-hirte.demo YES -hirte.demo.dense YES`
open a denser demo with nested families, long branches and a separate worktree path.

The bottom glass bar contains the Agents/Terminals switch and "+". On a phone, the terminal header
shows its task and context; More contains keyboard, Live Activity and info actions. Watch Only
remains directly accessible.

Local terminal history follows the finger between rows and uses native deceleration after release.
History pruning during live output preserves the visible text while it remains in the buffer.
Mouse-reporting programs receive ordered wheel events and control their own repainting, so their
scrolling still depends on the program and connection. Tapping a live terminal focuses input even
when the program uses mouse reporting; tapping while watching explicitly takes over.

Settings → Agents → Agent Overview lets you choose row fields with a live preview. Title and status
remain visible, and missing context values are omitted. View and Sort in the agent overview provides
Individual/Nested modes and sorting. Settings → Light Theme / Dark Theme opens the theme gallery;
use "+" to paste Ghostty theme text or import a file and review it before saving. Bundled Symbols Nerd
Font Mono supplies fallback Nerd Font symbols in the terminal while keeping the selected text font.

Live Activities are local and optional: enable Settings → Live Activity → "Follow on Lock Screen
(Beta)", then follow a working agent from the terminal menu. Updates arrive while Hirte is open and
connected. In the background or after a connection loss, the last known state remains visible;
reopen Hirte to refresh it. Opening the terminal or relaunching Hirte preserves the same follow
when its terminal and task identity still match. Stop Following, opting out, completion or a new
terminal instance ends it. The menu explains why following is unavailable; notification permission
is not required. This version does not provide reliable background monitoring.

### Optional host context

On a host with the existing herdr-core, `hc`, `git` and Python 3, publish context for a chosen local
terminal through labels:

```sh
python3 scripts/publish-context.py --terminal t7
python3 scripts/publish-context.py --terminal t7 --watch
```

Replace `t7` with its local terminal address from `hc ls`; `--terminal` can be repeated. Without
`--watch`, the script publishes once. With `--watch`, it refreshes until stopped with Ctrl-C.
The five display fields are branch, project, directory, agent and account. An additional creation
timestamp binds them to the terminal instance. Account is a readable profile alias, not a credential.
The publisher needs no GitHub registration. Labels reach Hirte over the existing host connection;
missing values are omitted from the overview.

## License

Apache-2.0, see [LICENSE](LICENSE). Hirte ships Ghostty (libghostty-vt), Citadel, SwiftNIO and
other open-source code, the JetBrains Mono, Comic Mono and Symbols Nerd Font Mono fonts,
agent icon assets attributed to herdr / LobeHub, and themes from iTerm2-Color-Schemes;
their licenses and component notices are in the app under Settings → Open-Source Licenses.
Brand names and marks remain their owners' trademarks; the icon licenses do not grant
trademark rights.
