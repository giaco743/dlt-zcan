# A DLT v1 filter tool written in Zig

`dlt-zcan` is a tool to filter huge DLT logs and output the filtered content to a new file.

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
* LogLEvel (1 = fatal, 2 = error, 3 = warn, 4 = info, 5 = debug, 6 = verbose)
* Contained substrings
To filter an existing log file specify it as the firt positional argument, the second positional argument is the ouput file, which gets overwritten, if it already exists.

```
./dlt-zcan input.dlt output.dlt --ecuid ECU --appid MYAP --ctid TEST --level 4 --substring "Hello World!"
```
