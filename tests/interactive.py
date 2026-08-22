#!/usr/bin/env python3
"""PTY regressions for the Bash/Readline autosuggestion wrapper."""

from __future__ import annotations

import os
import pty
import re
import select
import shlex
import sys
import time


UP = b"\x1b[A"
DOWN = b"\x1b[B"
RIGHT = b"\x1b[C"
ALT_F = b"\x1bf"
ALT_RIGHT = b"\x1b[1;3C"
CTRL_F = b"\x06"
CTRL_G = b"\x07"
CTRL_RIGHT = b"\x1b[1;5C"
END = b"\x1b[F"
TAB = b"\x09"
CTRL_W = b"\x17"
CTRL_Y = b"\x19"
ALT_Y = b"\x1by"
ALT_DOT = b"\x1b."
PROBE = b"\x1d"


class InteractiveBash:
    def __init__(
        self,
        shared_object: str,
        history: list[str] | None = None,
        extra_setup: str = "",
    ) -> None:
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            env = {
                "HOME": os.path.expanduser("~"),
                "LANG": "C.UTF-8",
                "PATH": os.environ["PATH"],
                "TERM": "xterm-256color",
            }
            os.execvpe("bash", ["bash", "--noprofile", "--norc", "-i"], env)

        self._drain()
        history_setup = "; ".join(
            f"history -s {shlex.quote(line)}" for line in (history or [])
        )
        setup = [
            "PS1='P> '",
            "set +o history",
            "history -c",
            history_setup,
            "bind 'set bell-style none'",
            "bind '\"\\e[A\": history-search-backward'",
            "bind '\"\\e[B\": history-search-forward'",
            "bind '\"\\C-p\": history-search-backward'",
            "bind '\"\\C-n\": history-search-forward'",
            "bind 'TAB: menu-complete'",
            "bind '\"\\e[Z\": menu-complete-backward'",
            "bind '\"\\e[1;3C\": forward-word'",
            "bind '\"\\e[1;5C\": shell-forward-word'",
            "__as_probe() { printf '\\n__STATE__%s|%s\\n' "
            '"$READLINE_LINE" "$READLINE_POINT"; }',
            "bind -x '\"\\C-]\":__as_probe'",
            extra_setup,
            f"enable -f {shlex.quote(shared_object)} omarchy_autosuggest",
            "omarchy_autosuggest enable",
        ]
        command = "; ".join(part for part in setup if part)
        os.write(self.fd, command.encode() + b"\n")
        prompt = b"\x1b[?2004hP> "
        output = self._read_until(prompt)
        if prompt not in output:
            raise AssertionError(f"shell setup did not reach prompt: {output!r}")

    def _drain(self, timeout: float = 0.15) -> bytes:
        output = bytearray()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            ready, _, _ = select.select(
                [self.fd], [], [], max(0.0, deadline - time.monotonic())
            )
            if not ready:
                break
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            output.extend(chunk)
            deadline = time.monotonic() + 0.03
        return bytes(output)

    def _read_until(self, marker: bytes, timeout: float = 2.0) -> bytes:
        output = bytearray()
        deadline = time.monotonic() + timeout
        while marker not in output and time.monotonic() < deadline:
            output.extend(self._drain(0.15))
        return bytes(output)

    def state(self, typed: bytes = b"", keys: bytes = b"") -> tuple[str, int]:
        os.write(self.fd, typed)
        if typed:
            self._drain()
        for key in keys:
            os.write(self.fd, bytes([key]))
            time.sleep(0.015)
        self._drain()
        os.write(self.fd, PROBE)
        output = self._read_until(b"__STATE__") + self._drain(0.15)
        matches = list(re.finditer(rb"__STATE__(.*?)\|([0-9]+)\r?\n", output))
        if not matches:
            raise AssertionError(f"state probe missing from output: {output!r}")
        match = matches[-1]
        return match.group(1).decode("utf-8"), int(match.group(2))

    def close(self) -> None:
        try:
            os.write(self.fd, b"\x03")
            self._drain()
            os.write(self.fd, b"exit\n")
            self._drain()
        finally:
            try:
                os.waitpid(self.pid, 0)
            except ChildProcessError:
                pass


def check(
    name: str,
    shared_object: str,
    expected: str,
    *,
    history: list[str] | None = None,
    setup: str = "",
    typed: bytes = b"",
    keys: bytes = b"",
) -> None:
    shell = InteractiveBash(shared_object, history, setup)
    try:
        line, point = shell.state(typed, keys)
        if line != expected or point < 0 or point > len(line.encode()):
            raise AssertionError(
                f"{name}: expected {expected!r}, got {line!r} at point {point}"
            )
        print(f"ok - {name}")
    finally:
        shell.close()


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} PATH_TO_SHARED_OBJECT", file=sys.stderr)
        return 2
    shared_object = os.path.abspath(sys.argv[1])
    if not os.path.isfile(shared_object):
        print(f"missing shared object: {shared_object}", file=sys.stderr)
        return 2

    history = ["echo oldest", "echo middle", "echo newest"]
    check("empty Up repeats", shared_object, "echo oldest", history=history, keys=UP * 3)
    check(
        "Down restores original line",
        shared_object,
        "",
        history=history,
        keys=UP * 2 + DOWN * 2,
    )
    check(
        "prefix history repeats",
        shared_object,
        "git add .",
        history=["git add .", "echo unrelated", "git status"],
        typed=b"git ",
        keys=UP * 2,
    )
    check(
        "Tab menu completion repeats",
        shared_object,
        "x alto ",
        setup="complete -W 'alpha alpine alto' x",
        typed=b"x al",
        keys=TAB * 3,
    )
    check(
        "yank-pop sees the real previous command",
        shared_object,
        "one three two",
        typed=b"one two",
        keys=CTRL_W + b"three four" + CTRL_W + CTRL_Y + ALT_Y,
    )
    check(
        "repeated yank-last-arg walks history",
        shared_object,
        "alpha",
        history=["echo alpha", "printf beta"],
        keys=ALT_DOT * 2,
    )
    check(
        "Right accepts the complete suggestion",
        shared_object,
        "git checkout main",
        history=["git checkout main"],
        typed=b"git c",
        keys=RIGHT,
    )
    check(
        "Ctrl-F accepts the complete suggestion",
        shared_object,
        "git checkout main",
        history=["git checkout main"],
        typed=b"git c",
        keys=CTRL_F,
    )
    check(
        "Alt-F accepts one word",
        shared_object,
        "git checkout",
        history=["git checkout main"],
        typed=b"git ",
        keys=ALT_F,
    )
    check(
        "Alt-Right accepts one word",
        shared_object,
        "git checkout",
        history=["git checkout main"],
        typed=b"git ",
        keys=ALT_RIGHT,
    )
    check(
        "Ctrl-Right accepts one shell word",
        shared_object,
        "git checkout",
        history=["git checkout main"],
        typed=b"git ",
        keys=CTRL_RIGHT,
    )
    check(
        "End accepts the complete suggestion",
        shared_object,
        "git checkout main",
        history=["git checkout main"],
        typed=b"git c",
        keys=END,
    )
    check(
        "Ctrl-G dismisses the current suggestion",
        shared_object,
        "e",
        history=["echo hello"],
        typed=b"e",
        keys=CTRL_G + RIGHT,
    )
    check(
        "editing re-enables a dismissed suggestion",
        shared_object,
        "echo hello",
        history=["echo hello"],
        typed=b"e",
        keys=CTRL_G + b"c" + RIGHT,
    )
    check(
        "history recall does not grow a new ghost",
        shared_object,
        "echo short",
        history=["echo short suffix", "echo short"],
        keys=UP + RIGHT,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
