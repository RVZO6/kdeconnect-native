# Performance measurements

## Changes kept

- Create notification groups only near the viewport with `LazyVStack`.
- Keep card identity and reply state during stack animation, but do not
  create hidden text fields or glass buttons behind a collapsed stack.
- Measure only the front card when a stack is collapsed. Observe its
  height once per group, not once per notification.
- Read swipe width from the native view during the gesture. Do not keep
  a width observer on every scrolling card.
- Share one scroll-event monitor. Select a swipe target once per gesture.
  Pass vertical scroll events through and consume horizontal swipe events.
- Do not rebuild an unchanged notification list for battery/header changes.
- Read up to eight notification property sets at once. Keep input order
  and skip failed reads, as before.

## Results: 26 October 2026

Apple M4 Pro, macOS 27.0.1, Swift 6.4, release builds. The UI workload uses
300 notifications in 20 apps, a 900 × 640 point window content area, and
241 scroll events per scenario. Values below are medians from three runs.
The baseline uses `2333259` with the same demo and measurement harness.

| Workload | Before | After | Change |
| --- | ---: | ---: | ---: |
| Collapsed stacks: process CPU time | 6,461 ms | 1,704 ms | 74% less |
| Expanded stacks: process CPU time | 6,420 ms | 1,316 ms | 80% less |
| Collapsed stacks: 95th-percentile input interval | 32.52 ms | 15.88 ms | 51% less |
| Expanded stacks: 95th-percentile input interval | 33.67 ms | 13.86 ms | 59% less |
| Installed scroll-event monitors | 320 | 1 | Fixed count |

Each run scrolls approximately 3,360 points. The maximum input interval
still varies; this change does not remove every delay.

These historical runs used the earlier two-phase harness. The current
benchmark selects the notification scroll view, accounts for safe-area
insets, reverses at the scroll edges, and also posts hover events. Do not
compare new timings directly with the historical table.

A single expanded group with 300 cards remains expensive. Two exploratory
runs per version varied from about 6.3 to 11.0 seconds of CPU time. No
improvement is claimed for that case. The layout still creates all cards
inside one expanded group to preserve their identity and spring movement.
Rendering only the visible cards inside a large group is a remaining target.

Independent-read measurements use seven samples of 64 reads per limit:

| Workload | One read at a time | Up to eight reads | Speed ratio |
| --- | ---: | ---: | ---: |
| `NameHasOwner` on an isolated local D-Bus | 2.12 ms | 0.62 ms | 3.4× |
| Configured 2 ms delay per read, synthetic | 186.94 ms | 24.04 ms | 7.8× |

The local-bus test starts a separate bundled `dbus-daemon`. It does not
contact `kdeconnectd`, change its address file, or use personal device data.
These read results are not end-to-end phone refresh measurements.

### Device refresh: three optional plugins

The battery, connectivity and notification reads run independently when at
least two are enabled. With zero or one enabled plugin, no child tasks are
created. The table shows the median of three runs; each run has seven timed
samples after a warm-up. The baseline is the sequential implementation in
`129a294`.

| Workload | Sequential | Parallel | Interpretation |
| --- | ---: | ---: | --- |
| Zero reads, in memory | 20.9 ns | 21.0 ns | No meaningful change |
| One read, in memory | 352.6 ns | 366.3 ns | 13.7 ns more |
| Three reads, in memory | 1.10 µs | 3.94 µs | 2.84 µs more task overhead |
| Three reads, 2 ms artificial delay each | 8.87 ms | 2.97 ms | 66.5% less elapsed time |
| Three local private-bus calls | 85.1 µs | 54.9 µs | 35.4% less elapsed time |

The private-bus case uses `NameHasOwner` as a transport proxy. It does not
measure `kdeconnectd`, phone communication, or end-to-end UI refresh.
The raw samples are in
[Results/2026-10-26-device-details.json](Results/2026-10-26-device-details.json).

Raw samples and environment details are in [Results/2026-10-26.json](Results/2026-10-26.json).

## Repeat the measurements

```sh
swift build -c release --product KDEConnectNative
bin="$(swift build -c release --show-bin-path)/KDEConnectNative"
for run in 1 2 3; do
  "$bin" --demo --demo-notifications 25 --demo-apps 5 --demo-reply-every 3 \
    --ui-benchmark "/tmp/kdeconnect-ui-$run.json"
done

KDECONNECT_PERF=1 swift test -c release --filter ConcurrentReadTests
KDECONNECT_PERF=1 swift test -c release --filter DeviceDetailsTests
swift test
swift test -c release
```

Keep other work light while the UI test runs. It opens a real window, then
closes it. It delivers vertical events directly to the selected
`NSScrollView`, so pointer position and focus do not select another target.
Monitor routing is tested separately by `HorizontalSwipeTests`.
The example has 25 notifications from five apps; every third notification
supports replies. `--demo-reply-every 0` makes none replyable. Omitting
that option keeps the original generated fixture, where all are replyable.
The JSON records the effective viewport, scroll range, view-body updates,
and posted hover events. A posted hover event is not proof that AppKit
delivered it; check the body-update counts before interpreting that case.

The input interval includes an 8 ms configured sleep and scheduling delay.
It measures main-thread responsiveness, **not presented frame rate**. CPU
time includes all app threads, but not WindowServer or GPU time. Lazy
layout can change the estimated document height as groups come into view.
Compare scrolling distance as well as time. Do not run captures or a CPU
sampler inside the timed workload.

Default tests check read order, partial failures, concurrency limits,
empty input, shared-monitor removal, swipe direction, momentum, clipped
hit regions, and notification input equality. Timing experiments are
opt-in; there are no timing thresholds in the normal test suite.

For visual checks, use the existing `--demo --stack-test <directory>` and
`--demo --swipe-test <directory>` commands. A single large group can be
tested with `--demo-notifications 300 --demo-apps 1`.
