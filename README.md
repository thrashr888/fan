# fan

Answer a practical Mac question: **why are my fans running, and what can I quit to test it?**

`fan` reads actual fan RPM from the Mac's System Management Controller (SMC),
then groups recent CPU activity by app. It suggests copyable, graceful quit
commands for ordinary apps and a way to watch whether RPM falls afterward.
It never quits an app or changes fan speed for you.
It also checks the non-software explanation first: blankets, bedding, and
other soft surfaces can obstruct cooling. It cannot sense blocked airflow,
so moving the Mac to a hard, flat surface and watching RPM is a useful test.

## Install

```sh
brew install thrashr888/tap/fan
```

Or build the read-only sensor helper on macOS with Xcode Command Line Tools:

```sh
cc -std=c11 -O2 fan-rpm.c -framework IOKit -framework CoreFoundation -o fan-rpm
./fan
```

Keep `fan` and `fan-rpm` in the same directory. The Homebrew formula does this.

## Use

```sh
fan           # measured fan speed, recent CPU activity, suggested next step
fan -w        # watch until every fan reports 0 RPM twice; Ctrl-C stops it
fan -d        # show a deeper thermal/GPU diagnostic command
fan -h        # all options
```

The suggested quit commands are on their own lines for easy copying. Save your
work before quitting an app. If a background process is an ordinary user
executable, `fan` shows an inspection command followed by a `kill -TERM`
command. It never suggests killing WindowServer or a system service.
It gives tailored guidance for WindowServer, CrowdStrike Falcon, coreaudiod,
ControlCenter, Spotlight, and kernel_task rather than treating them as apps
you should force-quit. CrowdStrike is managed security software; ask your IT
team if its CPU usage remains high.

Fan RPM says whether a fan is physically spinning. CPU activity is evidence
about possible heat sources, not proof that a particular app started the fan.
macOS `ps` reports a decaying CPU average over up to a minute, so a brief spike
or a just-closed app can remain visible. The practical test is to close one app
at a time and watch whether RPM drops. Fans may take minutes to slow after load
ends. GPU work, charging, ambient temperature, blocked airflow, and earlier
load can also matter.

If the SMC reading is unavailable, `fan` says so and `-w` falls back to a CPU
threshold. The SMC key interface is undocumented and may change on future Macs.

## How it works

The small `fan-rpm` helper reads `FNum` (fan count) and `F0Ac`, `F1Ac`, etc.
(actual RPM) through IOKit. It performs no SMC writes and normally needs no
administrator password. `fan` samples the process list, groups helpers by app,
and prints actions only for ordinary apps or user executables.

## License

MIT. See [LICENSE](LICENSE).
