#!/usr/bin/env python3

import argparse
import socket
import time


DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 3490
DEFAULT_CHUNK_SIZE = 128
DEFAULT_INTERVAL = 0.001


def send_file(conn, path, chunk_size, interval):
    """Send one complete file over an existing TCP connection."""

    with open(path, "rb") as f:
        while True:
            chunk = f.read(chunk_size)

            if not chunk:
                break

            conn.sendall(chunk)

            if interval > 0:
                time.sleep(interval)


def run(args):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)

    # Allow restarting the Python daemon quickly after Ctrl+C.
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

    server.bind((args.host, args.port))
    server.listen(1)

    print(f"DLT fake daemon listening on {args.host}:{args.port}")
    print(f"File:       {args.file}")
    print(f"Chunk size: {args.chunk_size}")
    print(f"Interval:   {args.interval}s")
    print(f"Loop:       {args.loop}")

    try:
        while True:
            print("Waiting for connection...")

            conn, addr = server.accept()

            print(f"Client connected: {addr}")

            # The connection stays open for the entire lifetime of this
            # transmission loop.
            try:
                while True:
                    print("Sending file...")

                    send_file(
                        conn,
                        args.file,
                        args.chunk_size,
                        args.interval,
                    )

                    print("Finished sending file.")

                    if not args.loop:
                        break

                    print("Looping file on the same TCP connection...")

            except (BrokenPipeError, ConnectionResetError):
                print("Client disconnected.")

            finally:
                conn.close()
                print("Connection closed.")

            # If --loop is enabled, wait for another client after a
            # disconnected client. Otherwise the daemon exits.
            if not args.loop:
                break

    except KeyboardInterrupt:
        print("\nStopping daemon...")

    finally:
        server.close()


def main():
    parser = argparse.ArgumentParser(
        description="Fake DLT TCP daemon for testing"
    )

    parser.add_argument(
        "--host",
        default=DEFAULT_HOST,
        help=f"Listen address (default: {DEFAULT_HOST})",
    )

    parser.add_argument(
        "--port",
        type=int,
        default=DEFAULT_PORT,
        help=f"Listen port (default: {DEFAULT_PORT})",
    )

    parser.add_argument(
        "--file",
        required=True,
        help="DLT file to transmit",
    )

    parser.add_argument(
        "--chunk-size",
        type=int,
        default=DEFAULT_CHUNK_SIZE,
        help=f"TCP chunk size (default: {DEFAULT_CHUNK_SIZE})",
    )

    parser.add_argument(
        "--interval",
        type=float,
        default=DEFAULT_INTERVAL,
        help=f"Delay between chunks in seconds (default: {DEFAULT_INTERVAL})",
    )

    parser.add_argument(
        "--loop",
        action="store_true",
        help="Repeat the file forever on the same TCP connection",
    )

    args = parser.parse_args()

    if args.chunk_size <= 0:
        parser.error("--chunk-size must be greater than 0")

    if args.interval < 0:
        parser.error("--interval must be >= 0")

    run(args)


if __name__ == "__main__":
    main()
