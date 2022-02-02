# coremem

## An utility to report the core memory usage

It is a [`ps_mem`](https://github.com/pixelb/ps_mem) alternative, this project is inspired by it.

There are some aditional/changed options:

```
* -u/--user-id [uid]          Only query processes of given uid, if none are provided, defaults to the current user
* -l/--limit <Number>         Only show up to Number of lines
* -r/--reverse                Reverse the order, showing processes in an descending
-t, --total [machine|human]   Only show the total RAM usage, by default
                              displays the kilobytes (machine readable)
```


## Build and run

* Needs [`zig-0.9.0`](https://ziglang.org/download/).

To build a release-safe binary, run:

    zig build -Drelease-safe

If you want more perfomance (although not that relevant in this case), you can use -Drelease-fast, or -Drelease-small for size optimizations.
Now, you can copy the `zig-out/bin/coremem` binary to some directory in your PATH and use it.


## Usage

```
Usage: coremem [OPTION]...
Show program core memory usage
-h, --help                       Show this help and exits
-S, --swap                       Show swap information
-s, --show-args                  Show all command line arguments
-r, --reverse                    Reverses the order that processes are shown
-t, --total [machine|human]      Only show the total RAM usage, by default
                                 displays the kilobytes (machine readable)
-d, --discriminate-by-pid        Show by process rather than by program
-w, --watch <N>                  Measure and show memory usage every N seconds
-l, --limit <N>                  Show only the last N processes
-u, --user-id [uid]              Only consider the processes owned by uid, if
                                 none specified, defaults to current user
-p, --pid <pid>[,pid2,...pidN]   Shows the memory usage of the PIDs specified
```

### Examples:

See the top 5 processes/programs that uses the most memory:

    coremem -l 5

See the memory usage of processes of your current user separated by its PID:

    coremem -du

Watch (with 10s of delay) the memory usage of the PIDs 2364, 9870 and 3460, also showing theirs args and swap usage:

    coremem -sS --watch 10 -p=2364,9870,3460


## TODOs

* Properly calculate the memory usage
* `-f/--format=[auto, Kib, Mib, Gib, Tib]`   with auto being the default, meaning that it will use any of the other formats as needed
* Support others SOs (right now only linux is supported
