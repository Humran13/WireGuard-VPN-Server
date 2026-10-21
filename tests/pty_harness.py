#!/usr/bin/env python3
"""
pty_harness.py - drive a script the way `curl ... | bash` really runs, and
capture exactly what a human would see on their real terminal.

  - the script's own stdin (fd 0) is a plain, non-seekable PIPE (so if it
    naively uses `read` for prompts, it will consume its own trailing
    source lines instead of waiting for the user)
  - the process has a real controlling terminal (a pty) - fd 1 and fd 2
    are left attached to that pty slave (exactly like a real interactive
    `curl | bash` session, where only stdin is redirected by the pipe and
    stdout/stderr still go straight to the terminal), so anything the
    script writes - including a bash `read -p` prompt - is captured in
    the SAME byte stream a human would actually see, in the order it was
    written, interleaved with the answers we type back.

Usage:
  pty_harness.py --script FILE --answers-file FILE [--no-tty] [--timeout N]

Answers file: one line per answer to type into the controlling terminal,
sent with a short delay between each so the child has time to reach its
next prompt. Each line is sent followed by a newline.

With --no-tty, no controlling terminal is attached at all (stdin is still
a pipe, but /dev/tty is unreachable) - used to verify the script fails
fast instead of hanging when no terminal is available.

Prints the raw terminal byte stream (what a human would have seen,
including local echo of typed answers) to this process's stdout, then
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
    ap.add_argument(
        "--direct-stdin",
        action="store_true",
        help=(
            "Run the script directly (`bash script`) with stdin left attached "
            "to the pty, like a normal non-piped execution, instead of "
            "feeding it over a separate pipe like `curl | bash`."
        ),
    )
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--answer-delay", type=float, default=0.3)
    args = ap.parse_args()

    answers = []
    if args.answers_file:
        with open(args.answers_file, "r") as f:
            answers = [line.rstrip("\n") for line in f]

    pipe_r = pipe_w = None
    if not args.direct_stdin:
        # Anonymous pipe that will become the child's stdin (fd 0): a real
        # pipe, non-seekable, exactly like curl's stdout piped into bash.
        pipe_r, pipe_w = os.pipe()
        with open(args.script, "rb") as f:
            script_bytes = f.read()

    if args.no_tty:
        pid = os.fork()
        master_fd = None
    else:
        pid, master_fd = pty.fork()

    if pid == 0:
        # Child.
        if args.no_tty:
            # Detach from any controlling terminal entirely. fd 1/2 stay
            # whatever they were (inherited from the parent) - irrelevant
            # for this mode since the point is /dev/tty must be
            # unreachable, not what gets printed where.
            os.setsid()
        # else: pty.fork() already did setsid() + TIOCSCTTY on the slave
        # AND already attached fd 0/1/2 to that slave for us. We deliberately
        # leave fd 1 and fd 2 alone here - so anything written to
        # stdout/stderr (including a `read -p` prompt) lands on the pty,
        # exactly like a real terminal session.

        if args.direct_stdin:
            # fd 0 stays attached to the pty slave (or whatever it already
            # is in --no-tty mode): a normal, non-piped execution.
            os.execvp("bash", ["bash", args.script])
        else:
            os.dup2(pipe_r, 0)
            os.close(pipe_r)
            os.close(pipe_w)
            os.execvp("bash", ["bash", "-s"])
        os._exit(127)

    # Parent.
    if not args.direct_stdin:
        os.close(pipe_r)
        # Feed the script source into the child's stdin pipe, matching
        # `curl -fsSL ... | bash`: the whole script arrives over the pipe.
        os.write(pipe_w, script_bytes)
        os.close(pipe_w)

    deadline = time.time() + args.timeout
    answer_idx = 0
    next_answer_at = time.time() + args.answer_delay
    output = b""

    read_fds = [master_fd] if master_fd is not None else []

    while True:
        if time.time() > deadline:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
            sys.stderr.write("TIMEOUT waiting for child process\n")
            sys.stdout.buffer.write(output)
            sys.exit(124)

        timeout = 0.5
        if master_fd is not None and answer_idx < len(answers):
            timeout = max(0.0, next_answer_at - time.time())

        if read_fds:
            try:
                r, _, _ = select.select(read_fds, [], [], timeout)
            except OSError:
                r = []
            if master_fd in r:
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError:
                    chunk = b""
                    read_fds = []
                if chunk:
                    output += chunk
        else:
            time.sleep(min(timeout, 0.2))

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
            if read_fds:
                while True:
                    try:
                        r, _, _ = select.select(read_fds, [], [], 0.2)
                    except OSError:
                        break
                    if master_fd not in r:
                        break
                    try:
                        chunk = os.read(master_fd, 4096)
                    except OSError:
                        chunk = b""
                    if not chunk:
                        break
                    output += chunk
            sys.stdout.buffer.write(output)
            if os.WIFEXITED(status):
                sys.exit(os.WEXITSTATUS(status))
            sys.exit(1)


if __name__ == "__main__":
    main()
