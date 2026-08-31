# A DLT v1 filter tool written in Zig

`dlt-zcan` is a tool to filter large DLT logs and output the filtered content to a new file.
`dlt-zcan` has to be compiled with zig 0.16.

> **Note:** `dlt-zcan` is currently a work in progress. It has been tested against example DLT files and large DLT logs, but full compliance with the DLT v1 specification and comprehensive test coverage are not yet guaranteed.

## Build `dlt-zcan`

To build `dlt-zcan` from source just download the repo and compile the source code to an executable:

```
zig build-exe dlt-zcan.zig -O ReleaseFast
```

## Filter huge DLT logs

DLT logs can be filtered according to:
* ECU ID
* APP ID
* CONTEXT ID
* \>\= Log Level  (1 = fatal, 2 = error, 3 = warn, 4 = info, 5 = debug, 6 = verbose)
* Contained substrings
To filter an existing log file specify it as the first positional argument, the second positional argument is the output file, which gets overwritten, if it already exists. If the second argument is not given, the content is printed to the terminal raw, if `-pretty` is not used.

```
./dlt-zcan input.dlt output.dlt --ecuid ECU --apid MYAP --ctid TEST --level 4 --substring "Hello World!" --pretty
```

With `--pretty` enabled the ouput looks like:

```
...
ECU=ECU APID=LOG CTID=TES4 Level=INFO | [0, "Hello world"]
ECU=ECU APID=LOG CTID=TES4 Level=INFO | [1, "Hello world"]
ECU=ECU APID=LOG CTID=TES4 Level=INFO | [2, "Hello world"]
ECU=ECU APID=LOG CTID=TES4 Level=INFO | [3, "Hello world"]
ECU=ECU APID=LOG CTID=TES4 Level=INFO | [4, "Hello world"]
ECU=ECU APID=LOG CTID=TES4 Level=INFO | [5, "Hello world"]
ECU=ECU APID=LOG CTID=TES4 Level=INFO | [6, "Hello world"]
ECU=ECU APID=LOG CTID=TES4 Level=INFO | [7, "Hello world"]
ECU=ECU APID=LOG CTID=TES4 Level=INFO | [8, "Hello world"]
...
```

## Benchmark

For benchmarking a 4.2G big .dlt file was created by repeatedly concatenating an example dlt-file from the official DLT Viewer github [repository](https://github.com/COVESA/dlt-daemon/blob/master/tests/testfile.dlt).

## Performance

Benchmarked with `hyperfine` (3 warmup runs, 10 measurements).

| Benchmark | Mean ± σ |
|---|---:|
| `cat testfiles/huge.dlt > /dev/null` | 4.421 ± 0.026 s |
| `./dlt-zcan testfiles/huge.dlt /dev/null` | 7.114 ± 0.059 s |
| `./dlt-zcan testfiles/huge.dlt /dev/null --ecuid ECU` | 7.110 ± 0.033 s |
| `./dlt-zcan testfiles/huge.dlt /dev/null --substring "Hello world"` | 8.451 ± 0.027 s |
| `./dlt-zcan testfiles/huge.dlt /dev/null --pretty` | 14.955 ± 0.036 s |

### Benchmark system

* **CPU:** Intel Core i5-7200U @ 2.50 GHz (2C/4T)
* **RAM:** 7.6 GiB
* **Storage:** SK hynix PC300 NVMe 256 GB
* **OS:** Ubuntu 24.04.3 LTS
* **Kernel:** 6.8.0-137-generic
* **Zig:** 0.16.0
