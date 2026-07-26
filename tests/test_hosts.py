"""Tests for remote pane collection in scripts/_hosts.sh.

The deck fetches panes from remote hosts over SSH. These tests
verify the fetch is *bounded* and *parallel*: a slow or unreachable
host must never block the deck (regression test for the prefix+e
hang), and reachable hosts must still return correctly formatted
panes.

Each test sources _hosts.sh in a real bash shell with a fake `ssh`
on PATH so no network or tmux is required. The fake `ssh` behaves
differently per host name:

  goodhost   returns one pane line immediately
  emptyhost  connects but returns nothing
  slowhost   blocks far longer than the timeout (simulates an
             unreachable/hung host)
"""

import os
import subprocess
import tempfile
import textwrap
import time
import unittest

SCRIPTS = os.path.join(
    os.path.dirname(__file__), "..", "scripts"
)

FAKE_SSH = textwrap.dedent(
    """\
    #!/usr/bin/env bash
    # Minimal fake ssh: find the host arg (first non-option,
    # skipping `-o value` pairs) and act on it.
    args=("$@")
    n=$#
    host=""
    i=0
    while (( i < n )); do
      a="${args[$i]}"
      if [[ "$a" == "-o" ]]; then i=$((i + 2)); continue; fi
      if [[ "$a" == -* ]]; then i=$((i + 1)); continue; fi
      host="$a"; break
    done
    case "$host" in
      goodhost)
        printf 'sess<~>0<~>win<~>1<~>/tmp<~>claude<~>working'
        printf '<~>desc<~>agent<~>owner1<~>uuid1\\n'
        ;;
      emptyhost) : ;;
      # exec so `timeout` can kill the sleep directly (a lingering
      # child would keep the output pipe open and defeat the bound).
      *) exec sleep 30 ;;
    esac
    """
)


def run_collect(hosts, ssh_timeout="1", extra_path=True):
    """Source _hosts.sh, populate the host cache, run
    collect_remote_all with a fake ssh, and return
    (stdout, elapsed_seconds)."""
    tmp = tempfile.mkdtemp()
    ssh_path = os.path.join(tmp, "ssh")
    with open(ssh_path, "w") as f:
        f.write(FAKE_SSH)
    os.chmod(ssh_path, 0o755)

    cache = os.path.join(tmp, "hosts")
    with open(cache, "w") as f:
        f.write("\n".join(hosts) + ("\n" if hosts else ""))

    script = textwrap.dedent(
        f"""\
        export PATH="{tmp}:$PATH"
        export PILOT_SSH_TIMEOUT="{ssh_timeout}"
        source "{SCRIPTS}/_hosts.sh"
        export PILOT_HOST_CACHE="{cache}"
        collect_remote_all
        """
    )
    start = time.monotonic()
    proc = subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        text=True,
        timeout=25,
    )
    elapsed = time.monotonic() - start
    return proc.stdout, elapsed


class TestRemoteCollection(unittest.TestCase):

    def test_reachable_host_returns_formatted_panes(self):
        out, _ = run_collect(["goodhost"])
        lines = [ln for ln in out.splitlines() if ln.strip()]
        self.assertEqual(len(lines), 1)
        fields = lines[0].split("\t")
        # target, session, win_idx, win_name, pane_idx, path
        self.assertEqual(fields[0], "sess:0.1")
        self.assertEqual(fields[1], "sess")
        # host lands in the owner-adjacent column set by awk
        self.assertIn("goodhost", fields)

    def test_empty_cache_is_noop(self):
        out, elapsed = run_collect([])
        self.assertEqual(out.strip(), "")
        self.assertLess(elapsed, 5)

    def test_slow_host_is_bounded(self):
        # The fake host sleeps 30s; the fetch must return within a
        # couple of timeouts, not 30s. This is the core regression
        # test for the prefix+e hang.
        out, elapsed = run_collect(["slowhost"], ssh_timeout="1")
        self.assertEqual(out.strip(), "")
        self.assertLess(elapsed, 8)

    def test_slow_host_does_not_block_reachable_host(self):
        # A reachable host's panes must still appear even when
        # another host is unreachable — proves parallel fetch.
        out, elapsed = run_collect(
            ["slowhost", "goodhost"], ssh_timeout="1"
        )
        self.assertIn("goodhost", out)
        self.assertIn("sess:0.1", out)
        self.assertLess(elapsed, 8)


if __name__ == "__main__":
    unittest.main()
