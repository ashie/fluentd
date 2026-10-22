# io-event Coolio compatibility

## Motivation and scope

Fluentd uses cool.io for its event loop, and cool.io depends on libev. The
Fluentd team can maintain cool.io, so replacing it is not an immediate
requirement. However, libev's upstream maintenance has been limited, and
changes around Ruby's asynchronous IO can break the stack. It is useful to
know whether Fluentd has a viable alternative if maintaining it becomes
difficult.

Fluentd already depends on `async-http`, which brings in Async and io-event.
Using io-event beneath the Coolio API would therefore align this backend with
an IO library already present in Fluentd's dependency graph. The PoC declares
io-event directly rather than relying on that transitive dependency. Sharing a
dependency does not mean the Coolio and Async event loops share a scheduler or
automatically cooperate; that would need separate integration tests.

This proof of concept uses io-event's low-level primitives and asks a more
specific question than whether Fluentd's own tests pass: can Fluentd and its
plugin ecosystem continue to use the Coolio API, including `require 'cool.io'`,
while the event loop implementation changes? It is an opt-in evaluation, not a
decision to replace cool.io. The default backend remains the real cool.io gem.

This document describes the compatibility layer selected by
`FLUENTD_EVENT_LOOP_BACKEND=io_event_compat` and the limits of that evaluation.

## Loading

`lib/cool.io.rb` is a load-path shim for `require 'cool.io'`.

- With `FLUENTD_EVENT_LOOP_BACKEND=io_event_compat`, it loads
  `event_loop_compat` and `event_loop_compat/coolio`.
- Without that environment variable, it loads the real `cool.io` gem by
  absolute path.
- If `Coolio::Loop` is already defined, the shim only accepts the
  compatibility namespace. With the compat backend and the real gem
  loaded first, it raises `LoadError` instead of leaving a mixed
  namespace behind.
- `require 'coolio'` is intercepted indirectly when the `cool.io` gem is
  available to RubyGems: the gem's `coolio.rb` alias calls
  `require 'cool.io'`, which resolves to this shim. If the real cool.io
  extension was loaded before that, the shim raises `LoadError` under the
  compat backend instead of mixing namespaces.

`lib/event_loop_compat/coolio.rb` defines the `Coolio` namespace on top of
`EventLoopCompat`. It refuses to load if the real cool.io extension is already
loaded. Fluentd's `fluent/load.rb` and event loop helper both require
`cool.io`, so the shim selects the namespace early enough for plugins that
reference `Coolio` without an explicit require. The `event_loop_compat` entry
point alone does not define `Coolio`; comparison tests load the implementations
in separate child processes.

Loading both implementations in one process is not supported in any order:

| Loaded first | Then | Result |
| --- | --- | --- |
| real cool.io | `require 'cool.io'` with the compat backend | `LoadError` from the shim |
| real cool.io | `require 'coolio'` with the compat backend | `LoadError` from the shim |
| real cool.io | `require 'event_loop_compat/coolio'` | `LoadError` from the namespace |
| compatibility namespace | real cool.io | `TypeError: superclass mismatch for class Coolio::Loop` |

The gemspec still declares cool.io as a runtime dependency, and the gem must
remain available for the default backend and for its `coolio.rb` require alias.
Having it installed or activated by Bundler does not itself load the real
extension. With the compat backend, do not explicitly require the gem's
`cool.io.rb` by absolute path or otherwise bypass the shim.

The bundled plugins, counter subsystem, server and timer helpers, and legacy
socket API use the `Coolio` interface on both backends. Their production source
is unchanged from master; only the event loop helper retains a backend-specific
error handler. The io-event implementation and load-path shim are new files.

## Possible integration into cool.io (not implemented)

The compatibility layer could live in the cool.io gem instead of Fluentd. The
gem's `require 'cool.io'` entry point could select the existing libev backend
by default or an io-event backend through an opt-in setting (for example,
`COOLIO_BACKEND=io_event`). `require 'coolio'` and external plugins would then
use the same gem and public `Coolio` namespace, without Fluentd shadowing its
load path. The current PoC demonstrates that Fluentd's bundled plugins and
most core code can use that namespace without backend-specific base classes;
it does **not** demonstrate an integrated cool.io gem.

Known issues with moving the layer into cool.io:

- Backend selection must happen before the native `cool.io_ext` is required or
  backend-specific `Coolio` classes are defined. Select one backend per
  process; switching after loading, or mixing watcher and loop
  implementations, is not supported.
  A setting read only after Fluentd loads plugins would be too late.
- cool.io currently builds a native extension containing libev. Merely
  selecting io-event at runtime would avoid using that extension but would not
  remove its install-time build requirement. Avoiding libev entirely would
  require a separate packaging step, such as making the native backend
  optional or splitting it out, plus a clear dependency policy for io-event.
- Some of cool.io's Ruby-level IO, socket and server classes sit on top of its
  native watcher, loop and buffer classes. The PoC reproduces parts of this
  stack in the compatibility namespace. Moving it into the gem should examine
  which Ruby code can be shared and which backend-specific behavior must stay
  separate; copying the whole PoC would leave two implementations to maintain.
- Ownership by cool.io would not remove the observable differences listed
  below (for example one-shot timers, stat attributes and synchronous DNS).
  Their compatibility policy, load-order tests, and cross-platform behavior
  would have to be maintained in cool.io. The current PoC has not been tested
  on a Windows host, and its full suite has not completed after the latest
  integration changes.

A practical first step would keep the existing libev build and default backend
while moving selection and the compatibility tests into cool.io. Whether to
remove the native build dependency is a separate decision; runtime switching
alone does not solve that part of the original motivation.

## Implemented public API

| API | Status | Notes |
| --- | --- | --- |
| `Coolio::VERSION` | Implemented | Reports `1.9.0`. |
| `Cool.io` | Implemented | Returns the `Coolio` module. |
| `Coolio::Loop` | Implemented | Inherits `EventLoopCompat::Loop`. |
| `Coolio::Loop.default` | Implemented | Uses `Thread#_coolio_loop`. |
| `Coolio::Loop#run` | Implemented | Raises when no watchers are attached, returns `false`. |
| `Coolio::Loop#run_once` | Implemented | Returns an approximate event count. |
| `Coolio::Loop#run_nonblock` | Implemented | Calls `run_once(0)`. |
| `Coolio::Loop#stop` | Implemented | Raises when the loop is not running. |
| `Coolio::Loop#has_active_watchers?` | Implemented | Uses active watcher count. |
| `Coolio::Watcher` | Implemented | Base class of the watcher classes; base initialization error is preserved. |
| `Coolio::Watcher#attach` | Implemented | Preserves loop type and attach errors, accepts the loop of the event loop helper. |
| `Coolio::Watcher#detach` | Implemented | Preserves not-attached error. |
| `Coolio::Watcher#enable` | Implemented | Preserves not-attached and already-enabled errors. |
| `Coolio::Watcher#disable` | Implemented | Preserves already-disabled error. |
| `Coolio::IOWatcher` | Implemented | Accepts cool.io string flags. |
| `Coolio::TimerWatcher` | Implemented | Includes `reset`. |
| `Coolio::StatWatcher` | Implemented | Subclass with `on_change`, like real cool.io. |
| `Struct::StatInfo` | Implemented | Same member order as the C extension; neither backend defines `Coolio::StatWatcher::StatInfo`. |
| `Coolio::AsyncWatcher` | Implemented | Uses an `IO.pipe` like real cool.io. |
| `Coolio::Buffer` | Approximate | Pure Ruby approximation. |
| `Coolio::IO` | Implemented | Uses an internal `Coolio::IO::Watcher`, like real cool.io. |
| `Coolio::Socket` | Implemented | Uses a `Connector` watcher. |
| `Coolio::TCPSocket` | Implemented | Hostname resolution is synchronous. |
| `Coolio::UNIXSocket` | Implemented | Connects synchronously like real cool.io. |
| `Coolio::Listener` | Implemented | Uses `accept_nonblock`. |
| `Coolio::TCPListener` | Implemented | Sets `do_not_reverse_lookup` like real cool.io. |
| `Coolio::UNIXListener` | Implemented | Wraps `UNIXServer`. |
| `Coolio::Server` | Implemented | Validates connection class and arity. |
| `Coolio::TCPServer` | Implemented | Supports port `0` and existing `TCPServer`. |
| `Coolio::UNIXServer` | Implemented | Supports existing `UNIXServer`. |
| `Coolio::DNSResolver` | Implemented | Ported from real cool.io Ruby code. |

## Tested behavior

`test/event_loop_compat/coolio_namespace_probe.rb` checks:

- `Coolio::VERSION`
- `Cool.io`
- `Coolio::Loop` option validation
- `Coolio::Watcher` base initialization error
- `Coolio::Loop#attach` loop type error
- `Coolio::IOWatcher` invalid flag error
- `Coolio::TimerWatcher` reset and detach errors
- `Coolio::Loop#stop`, `run`, and `run_once` errors
- one-shot timer behavior
- `Coolio::AsyncWatcher`
- `Coolio::IOWatcher` readable events
- `Coolio::Buffer` basic behavior
- `Coolio::TCPServer` echo behavior
- class hierarchy checks for socket and server classes

`test/event_loop_compat/test_coolio_namespace.rb` runs that probe in a child
process so the compat `Coolio` namespace does not pollute the test process.

`test/event_loop_compat/coolio_compare_probe.rb` reports the class hierarchy,
`is_a?`/`kind_of?`/`===`, constructor and callback errors, loop return values,
timer, IO, socket and stat watcher behavior of one implementation. That
includes the stat watcher baseline: a change made between attaching and running
the loop, detaching and attaching again, keeping the watcher attached across two
runs of the loop, a path that does not exist yet, and removing the watched file.
`test/event_loop_compat/test_coolio_compatibility.rb` runs it against the real
cool.io gem and against this repository in child processes and compares the
two reports, so the contracts above are checked against the real gem rather
than against a copy of them written by hand.

`test/event_loop_compat/test_load_order.rb` checks the loading combinations in
the table above.

`test/plugin_helper/test_event_loop_coolio_watchers.rb` attaches timer, IO and
stat watchers to the `Coolio::Loop` created by the event loop helper, which is
what external plugins do. `test/compat/test_socket_util.rb` exercises the
legacy socket API through the same public namespace.

These probes cover representative API contracts, not every behavior of the C
extension or every external plugin. After the latest core-diff reduction, the
focused compatibility and integration tests passed on both backends. A compat
full-suite run was stopped by a 10-minute limit after 3,201 tests with no
failures or errors at that point; this is not a completed full-suite result.
Windows has not been tested on a Windows host.

## Differences from cool.io

These are the differences the comparison test pins down. Other observations
in that probe match the real gem; behavior outside the probe is not guaranteed.
For each difference, why it is kept, what it means for a plugin, and what a
plugin can do instead are written down.

### Re-attaching an attached watcher

`Coolio::Watcher#attach` re-attaches an attached watcher. cool.io raises
`ArgumentError: wrong number of arguments (given 0, expected 1)`.

- Why it is kept: that error is an accident of how the C extension calls the
  loop's `attach` a second time, not a documented contract, and there is no
  second `attach` implementation to reproduce it with.
- Effect on plugins: attaching twice works here and raises with cool.io. The
  tested plugin scenarios do not rely on that exception.
- Instead: ask `attached?` before attaching, as plugins already have to do to
  avoid the exception.

### The libev constants of `Coolio::Loop`

`EVBACKEND_*` and `EVFLAG_*` are not defined, and the `:backend`,
`:fork_check` and `:skip_environment` options are accepted but ignored.

- Why it is kept: there is no libev backend to select; io-event uses one
  selector per loop and chooses the mechanism itself.
- Effect on plugins: code reading `Coolio::Loop::EVBACKEND_KQUEUE` gets a
  `NameError`. The tested plugin scenarios do not read these constants.
- Instead: do not select a backend.

### `Coolio::TCPSocket::TCPConnectResolver` and asynchronous DNS

The constant is not defined and `Coolio::TCPSocket.connect` resolves the address
synchronously.

- Why it is kept: asynchronous resolution needs a resolver watcher wired to the
  loop; the compatibility layer has no consumer for it, and adding one would be
  new API rather than compatibility.
- Effect on plugins: the first `connect` to a hostname blocks the thread that
  calls it. Subclasses of `Coolio::TCPSocket` work; code that references
  `TCPConnectResolver` by name fails with `NameError`. `TCPConnectSocket` is
  present in the compatibility layer.
- Instead: resolve the address before connecting, or use `IPAddr` literals.

### The attributes of a removed or missing path

Both report exactly one change when the watched file is removed, but the
attributes differ: cool.io reports the attributes the file had before the
removal (its inotify fast path does not re-stat the path), the compatibility
layer reports the attributes of a missing path, which are all zero. For a path
that does not exist when the watcher is attached, the `prev` struct that cool.io
passes contains uninitialized memory.

- Why it is kept: the zeroed attributes are the documented libev polling
  semantics and are the same on every platform; Windows has no inotify, so the
  cool.io values there are already different from Linux. Reproducing the
  cool.io values would mean reproducing uninitialized memory.
- Effect on plugins: a plugin that classifies the event from `prev` and `cur`
  (for example "was the file deleted?") reads different fields. `in_tail` uses
  the callback only as a trigger and does not look at the attributes.
- Instead: treat `cur.mode.zero?` as "the path does not exist", or call
  `File.exist?` in the callback.

### One-shot timers

A one-shot `Coolio::TimerWatcher` is disabled after it fires, so
`Loop#has_active_watchers?` becomes false and `Loop#run` returns. cool.io leaves
the watcher enabled, keeps counting it, and `Loop#run` blocks forever unless a
callback calls `stop`.

- Why it is kept: libev deactivates a one-shot timer when it fires; cool.io
  only fails to lower its Ruby-level counter, so the blocking `run` is a
  bookkeeping bug and not a contract. Reproducing it would make the
  compatibility loop wait forever for an event that can never happen.
- Effect on plugins: a plugin whose last remaining watcher is a fired one-shot
  timer returns from `run` here and hangs with cool.io in the probed scenario.
  A plugin that re-arms a one-shot timer with `enable` gets a
  working timer here and `RuntimeError: already enabled` with cool.io.
- Instead: keep the loop alive with a repeating watcher, which is what the event
  loop helper does with its default watcher, and re-arm with `reset`.

### `attached?` returns `true`

cool.io returns the truthy Integer `0`.

- Why it is kept: `0` is the raw `ev_is_active` value of the C extension leaking
  into Ruby, where every object except `nil` and `false` is true.
- Effect on plugins: `if w.attached?` behaves the same. Comparing the result
  with `==` against `true` or `false` differs.
- Instead: use the truthiness of the result.

## Known gaps

- `run_once` event counts are approximate. IO events are counted from the
  selector ready count; timer callbacks increment a counter. This is not
  guaranteed to match libev event counts exactly.
- `Coolio::Buffer` is a pure-Ruby approximation. Its basic probed behavior is
  compared with the real C extension, but it has not been exhaustively validated.
- `Coolio::DNSResolver` is implemented but not directly tested.
- `Coolio::TCPSocket.connect` resolves hostnames synchronously with
  `Addrinfo.getaddrinfo`; real cool.io uses asynchronous DNS resolution.
- `Coolio::Loop` accepts `:skip_environment`, `:fork_check`, and `:backend`
  options for API compatibility, but they do not configure libev behavior.
- `require 'coolio'` is only intercepted through the real gem's `coolio.rb`
  alias. If RubyGems cannot find the `cool.io` gem, `require 'coolio'` does not
  load the compatibility namespace.
- The concrete Coolio watcher classes inherit `Coolio::Watcher` and get their
  implementation from the `EventLoopCompat` watcher classes by mixing in
  `EventLoopCompat::IOWatcherBehavior`, `EventLoopCompat::TimerWatcherBehavior`
  and `EventLoopCompat::StatWatcherBehavior`. The behavior modules are not
  `Coolio` constants, so `Coolio::Watcher.ancestors` matches the real gem.
  `Coolio::IO` is not a watcher in cool.io, so it stays based on
  `EventLoopCompat::BufferedIO`.
