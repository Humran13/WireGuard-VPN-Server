#!/usr/bin/env python3
"""
pty_harness.py - drive a script the way `curl ... | bash` really runs:

  - the script's own stdin is a plain, non-seekable PIPE (so if it naively
    uses `read` for prompts, it will consume its own trailing source lines
    instead of waiting for the user)
  - the process nonetheless has a real controlling terminal (a pty),
    reachable via /dev/tty, exactly like a human's interactive shell
    session piping `curl | bash` into itself

Usage:
  pty_harness.py --script FILE --answers-file FILE [--no-tty] [--timeout N]

Answers file: one line per answer to type into the controlling terminal,
sent with a short delay between each so the child has time to reach its
next prompt. Each line is sent followed by a newline.

With --no-tty, no controlling terminal is attached at all (stdin is still
a pipe, but /dev/tty is unreachable) - used to verify the script fails
fast instead of hanging when no terminal is available.

Prints the child's combined stdout+stderr to this process's stdout, then
exits with the child's exit status.
"""
import argparse
import os
import pty
import select
import signal
import sys
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--script", required=True)
    ap.add_argument("--answers-file", default=None)
    ap.add_argument("--no-tty", action="store_true")
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--answer-delay", type=float, default=0.3)
    args = ap.parse_args()

    answers = []
    if args.answers_file:
        with open(args.answers_file, "r") as f:
            answers = [line.rstrip("\n") for line in f]

    with open(args.script, "rb") as f:
        script_bytes = f.read()

    # Anonymous pipe that will become the child's stdin (fd 0): a real
    # pipe, non-seekable, exactly like curl's stdout piped into bash.
    pipe_r, pipe_w = os.pipe()

    out_r, out_w = os.pipe()  # child's stdout+stderr -> captured here

    if args.no_tty:
        pid = os.fork()
        master_fd = None
    else:
        pid, master_fd = pty.fork()

    if pid == 0:
        # Child
        if args.no_tty:
            # Detach from any controlling terminal entirely.
            os.setsid()
        # else: pty.fork() already did setsid() + TIOCSCTTY on the slave.

        os.dup2(pipe_r, 0)
        os.dup2(out_w, 1)
        os.dup2(out_w, 2)
        for fd in (pipe_r, pipe_w, out_r, out_w):
            try:
                os.close(fd)
            except OSError:
                pass
        os.execvp("bash", ["bash", "-s"])
        os._exit(127)

    # Parent
    os.close(pipe_r)
    os.close(out_w)

    # Feed the script source into the child's stdin pipe, matching
    # `curl -fsSL ... | bash`: the whole script arrives over the pipe.
    os.write(pipe_w, script_bytes)
    os.close(pipe_w)

    deadline = time.time() + args.timeout
    answer_idx = 0
    next_answer_at = time.time() + args.answer_delay
    output = b""

    while True:
        if time.time() > deadline:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
            sys.stderr.write("TIMEOUT waiting for child process\n")
            sys.stdout.buffer.write(output)
            sys.exit(124)

        rlist = [out_r]
        timeout = max(0.0, next_answer_at - time.time()) if (
            master_fd is not None and answer_idx < len(answers)
        ) else 0.5

        r, _, _ = select.select(rlist, [], [], timeout)
        if out_r in r:
            try:
                chunk = os.read(out_r, 4096)
            except OSError:
                chunk = b""
            if chunk:
                output += chunk
            else:
                # EOF: child closed its output, it's finishing up.
                pass

        if (
            master_fd is not None
            and answer_idx < len(answers)
            and time.time() >= next_answer_at
        ):
            ans = (answers[answer_idx] + "\n").encode()
            try:
                os.write(master_fd, ans)
            except OSError:
                pass
            answer_idx += 1
            next_answer_at = time.time() + args.answer_delay

        wpid, status = os.waitpid(pid, os.WNOHANG)
        if wpid == pid:
            # Drain any remaining output.
            while True:
                try:
                    r, _, _ = select.select([out_r], [], [], 0.2)
                except OSError:
                    break
                if out_r not in r:
                    break
                chunk = os.read(out_r, 4096)
                if not chunk:
                    break
                output += chunk
            sys.stdout.buffer.write(output)
            if os.WIFEXITED(status):
                sys.exit(os.WEXITSTATUS(status))
            sys.exit(1)


if __name__ == "__main__":
    main()
