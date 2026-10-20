#!/usr/bin/env python3
"""Record real Neovim/Kitty windows on an isolated X11 display. No API calls."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout.strip()


class Recorder:
    def __init__(self, args, work):
        self.args, self.work = args, work
        self.env = dict(os.environ, DISPLAY=args.display)
        self.frames = []
        self.last_hash = None
        self.last_time = None

    def lua(self, code):
        expr = "luaeval(" + json.dumps("(function() " + code + " end)()", ensure_ascii=False) + ")"
        return run("nvim", "--server", self.args.server, "--remote-expr", expr)

    def keys(self, keys):
        run("nvim", "--server", self.args.server, "--remote-send", keys)

    def caption(self, keys, text):
        self.lua("InklingDemo.caption(" + json.dumps(keys, ensure_ascii=False) + ","
                 + json.dumps(text, ensure_ascii=False) + ")")

    def capture(self):
        path = self.work / "capture.png"
        run(self.args.magick, "import", "-window", "root", "-depth", "8", "-strip", str(path), env=self.env)
        now = time.monotonic()
        if self.frames:
            self.frames[-1][1] += now - self.last_time
        digest = hashlib.sha256(path.read_bytes()).digest()
        if digest != self.last_hash:
            frame = self.work / f"frame-{len(self.frames):04}.png"
            shutil.copyfile(path, frame)
            self.frames.append([frame, 0])
            self.last_hash = digest
        self.last_time = now

    def hold(self, seconds):
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            started = time.monotonic()
            self.capture()
            time.sleep(max(0, min(0.18 - (time.monotonic() - started), until - time.monotonic())))

    def type(self, text):
        for i in range(0, len(text), 3):
            self.keys(text[i:i + 3])
            self.hold(0.09)

    def ready(self, title=None):
        until = time.monotonic() + 25
        while time.monotonic() < until:
            self.hold(0.2)
            state = json.loads(self.lua(
                'local s = require("inkling.view")._state(); return vim.json.encode({'
                'title = s and s.entry and s.entry.graph.title, image = s and s.image and s.image.png ~= nil,'
                'status = s and s.status, busy = s and s.busy})'))
            if state.get("image") and not state.get("busy") and (not title or state.get("title") == title):
                self.hold(0.4)
                return
        raise RuntimeError(f"Diagram did not render: {state}")

    def reset(self):
        self.keys("<Esc>")
        self.lua('require("inkling.view").close(); vim.cmd("only"); vim.cmd("edit client.py"); '
                 'vim.api.nvim_win_set_cursor(0, {11, 0}); vim.cmd("redraw!")')
        self.frames, self.last_hash, self.last_time = [], None, None

    def finish(self, name):
        self.hold(2)
        command = [self.args.gifsicle, "--loopcount=0", "--colors=256", "--optimize=3"]
        for path, duration in self.frames:
            # Quantize one frame at a time; keep encoding memory bounded.
            frame = path.with_suffix(".gif")
            run(self.args.magick, "-limit", "thread", "1", str(path), str(frame))
            command.extend(["--delay=" + str(max(1, round(duration * 100))), str(frame)])
        output = self.args.output / (name + ".gif")
        command.extend(["--output", str(output)])
        subprocess.run(command, check=True)
        print(f"{output.name}: {len(self.frames)} frames, "
              f"{sum(f[1] for f in self.frames):.1f}s, {output.stat().st_size / 1024:.0f} KiB", flush=True)

    def follow(self):
        self.reset()
        self.caption(":Inkling view flow", "See the function beside its code")
        self.hold(0.8)
        self.type(":Inkling view flow")
        self.hold(0.5)
        self.keys("<CR>")
        self.ready("Fetch with a cache")
        self.hold(2)
        self.caption("20G", "Move to another function — the diagram follows")
        self.keys("20G")
        self.ready("Invalidate a cached value")
        self.hold(2)
        self.caption("11G", "Return to fetch — reuse its cached diagram")
        self.keys("11G")
        self.ready("Fetch with a cache")
        self.hold(1)
        self.caption("Ctrl-w l  +", "Enter the diagram to pin it; zoom in")
        self.keys("<C-w>l+")
        self.hold(1)
        self.keys("+")
        self.hold(1)
        self.caption("j / k / h / l", "Pan around the rendered diagram")
        self.keys("jj")
        self.hold(1)
        self.keys("kk")
        self.hold(0.5)
        self.caption("0", "Fit the entire diagram again")
        self.keys("0")
        self.finish("follow-focus")

    def investigate(self):
        self.reset()
        self.keys(":Inkling view flow<CR>")
        self.ready("Fetch with a cache")
        self.frames, self.last_hash, self.last_time = [], None, None
        self.caption("Ctrl-w l  u", "Step out from a function to its class")
        self.hold(1)
        self.keys("<C-w>lu")
        self.ready("ApiClient and its collaborators")
        self.hold(2)
        self.caption("/ HttpTransport", "Find a component and preview its source")
        self.keys("/")
        self.hold(0.5)
        self.type("HttpTransport")
        self.hold(2)
        self.keys("<CR>")
        self.hold(0.5)
        self.caption("e", "Step in with a direction to explore")
        self.keys("e")
        self.hold(0.5)
        self.type("Trace retries and final failure")
        self.hold(1)
        self.caption("Ctrl-S", "Send the prompt; inspect the transport")
        self.keys("<C-s>")
        self.ready("Inside HttpTransport")
        self.hold(2)
        self.caption("a", "Ask a question about this diagram")
        self.keys("a")
        self.hold(0.5)
        self.type("Can retries continue forever?")
        self.hold(1)
        self.caption("Ctrl-S", "Answers highlight the diagram and cite source")
        self.keys("<C-s>")
        self.hold(4)
        # Validate that this clip actually includes a grounded answer.
        result = self.lua('local s = require("inkling.view")._state(); '
                          'return table.concat(vim.api.nvim_buf_get_lines(s.chat_buf, 0, -1, false), "\\n")')
        assert "three attempts" in result and "transport.py" in result, result
        self.finish("navigate-and-ask")

    def review(self):
        self.reset()
        self.caption(":Inkling review main", "Review committed changes on a local branch")
        self.hold(0.8)
        self.type(":Inkling review main")
        self.hold(0.5)
        self.keys("<CR>")
        self.ready("Add bounded timeout retries")
        self.hold(2)
        self.caption("f", "Pick a changed file; preview the diff")
        self.keys("<C-w>lf")
        self.hold(2)
        self.keys("<CR>")
        self.hold(2)
        self.caption("c  Before", "Inspect behavior at the merge base")
        self.keys("c")
        self.hold(0.5)
        self.type("Before")
        self.hold(1)
        self.keys("<CR>")
        self.ready("Before: one attempt")
        self.hold(2)
        self.caption("c  After", "Compare behavior at the reviewed branch tip")
        self.keys("c")
        self.hold(0.5)
        self.type("After")
        self.hold(1)
        self.keys("<CR>")
        self.ready("After: bounded retries")
        self.finish("branch-review")


def prepare_project(work):
    project = work / "project"
    shutil.copytree(HERE / "project", project)
    transport = (project / "transport.py").read_text()
    (project / "transport.py").write_text(
        "import requests\n\n\nclass HttpTransport:\n"
        "    def __init__(self, base_url):\n        self.base_url = base_url\n\n"
        "    def get(self, path):\n"
        "        response = requests.get(self.base_url + path, timeout=5)\n"
        "        response.raise_for_status()\n        return response.json()\n")

    def git(*args):
        return run("git", "-c", "user.name=Inkling Demo", "-c", "user.email=demo@example.invalid",
                   "-c", "commit.gpgsign=false", *args, cwd=project)

    git("init", "-b", "main")
    git("add", ".")
    git("commit", "-m", "Add API client")
    git("checkout", "-b", "retry-timeouts")
    (project / "transport.py").write_text(transport)
    git("add", ".")
    git("commit", "-m", "Retry timeouts up to three times")
    return project


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--display", default=os.environ.get("DISPLAY", ":98"))
    parser.add_argument("--server", help="Attach to an already running session.lua instance")
    parser.add_argument("--kitty", default=shutil.which("kitty") or "kitty")
    parser.add_argument("--magick", default=shutil.which("magick") or "magick")
    parser.add_argument("--gifsicle", default=shutil.which("gifsicle") or "gifsicle")
    parser.add_argument("--browser", default=os.environ.get("INKLING_DEMO_BROWSER"))
    parser.add_argument("--output", type=Path, default=HERE)
    parser.add_argument("--clip", choices=["follow", "investigate", "review", "all"], default="all")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="inkling-demo-") as directory:
        work = Path(directory)
        terminal = None
        try:
            if not args.server:
                project = prepare_project(work)
                args.server = str(work / "nvim.sock")
                config = work / "kitty.conf"
                config.write_text(
                    "font_family DejaVu Sans Mono\nfont_size 12.5\nbackground #1d2021\nforeground #d4be98\n"
                    "cursor_blink_interval 0\nremember_window_size no\ninitial_window_width 1440\n"
                    "initial_window_height 900\nwindow_padding_width 10\nconfirm_os_window_close 0\n"
                    "linux_display_server x11\nenable_audio_bell no\nshell_integration disabled\n")
                env = dict(os.environ, DISPLAY=args.display, WAYLAND_DISPLAY="", LIBGL_ALWAYS_SOFTWARE="1",
                           INKLING_DEMO_ROOT=str(ROOT), INKLING_DEMO_PROJECT=str(project),
                           NVIM_LOG_FILE=str(work / "nvim.log"))
                for key in ("TMUX", "TMUX_PANE"):
                    env.pop(key, None)
                if args.browser:
                    env["INKLING_DEMO_BROWSER"] = args.browser
                terminal = subprocess.Popen([args.kitty, "--config", str(config), "--title", "inkling.nvim",
                                             "nvim", "--listen", args.server, "-u", str(HERE / "session.lua"),
                                             "-i", "NONE"], env=env)
                deadline = time.monotonic() + 15
                while not Path(args.server).exists():
                    if terminal.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError("Kitty/Neovim did not start")
                    time.sleep(0.1)
                time.sleep(0.7)
            recorder = Recorder(args, work)
            for name in ("follow", "investigate", "review"):
                if args.clip in ("all", name):
                    getattr(recorder, name)()
        finally:
            if terminal:
                terminal.terminate()
                terminal.wait(timeout=10)


if __name__ == "__main__":
    main()
