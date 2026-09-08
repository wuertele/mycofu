#!/usr/bin/env python3
"""Unit tests for nocloud-init.py — the cloud-init replacement.

Run with:
    python3 -m pytest tests/test_nocloud_init.py -v
    # or without pytest:
    python3 -m unittest tests.test_nocloud_init -v
"""

import base64
import importlib.util
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest import mock

# Import nocloud-init.py via importlib (hyphenated filename)
_spec = importlib.util.spec_from_file_location(
    "nocloud_init",
    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 "..", "framework", "nix", "modules", "nocloud-init.py"),
)
nocloud_init = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(nocloud_init)


# ── parse_user_data tests ────────────────────────────────────────────


class TestParseUserData(unittest.TestCase):
    """Tests for the minimal YAML parser."""

    def test_realistic_full_document(self):
        """Parse a document matching the Tofu user-data template output."""
        text = """\
#cloud-config
hostname: dns1-prod
manage_etc_hosts: true
ssh_authorized_keys:
  - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA operator@workstation
write_files:
  - path: /run/secrets/pdns-api-key
    content: |
      supersecretkey
    permissions: '0400'
    owner: root:root
"""
        data = nocloud_init.parse_user_data(text)
        self.assertEqual(data["hostname"], "dns1-prod")
        self.assertEqual(data["manage_etc_hosts"], "true")
        self.assertEqual(data["ssh_authorized_keys"],
                         ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA operator@workstation"])
        self.assertEqual(len(data["write_files"]), 1)
        wf = data["write_files"][0]
        self.assertEqual(wf["path"], "/run/secrets/pdns-api-key")
        self.assertEqual(wf["content"], "supersecretkey\n")
        self.assertEqual(wf["permissions"], "0400")
        self.assertEqual(wf["owner"], "root:root")

    def test_scalar_unquoted(self):
        data = nocloud_init.parse_user_data("hostname: myhost\n")
        self.assertEqual(data["hostname"], "myhost")

    def test_scalar_single_quoted(self):
        data = nocloud_init.parse_user_data("permissions: '0400'\n")
        self.assertEqual(data["permissions"], "0400")

    def test_scalar_double_quoted(self):
        data = nocloud_init.parse_user_data('name: "hello world"\n')
        self.assertEqual(data["name"], "hello world")

    def test_simple_sequence(self):
        text = "ssh_authorized_keys:\n  - key1\n  - key2\n"
        data = nocloud_init.parse_user_data(text)
        self.assertEqual(data["ssh_authorized_keys"], ["key1", "key2"])

    def test_mapping_sequence_with_block_scalar(self):
        text = """\
write_files:
  - path: /tmp/test
    content: |
      line1
      line2
    permissions: '0644'
"""
        data = nocloud_init.parse_user_data(text)
        self.assertEqual(len(data["write_files"]), 1)
        wf = data["write_files"][0]
        self.assertEqual(wf["path"], "/tmp/test")
        self.assertEqual(wf["content"], "line1\nline2\n")
        self.assertEqual(wf["permissions"], "0644")

    def test_block_scalar_trailing_blanks_stripped(self):
        text = """\
write_files:
  - path: /tmp/test
    content: |
      data


    permissions: '0644'
"""
        data = nocloud_init.parse_user_data(text)
        self.assertEqual(data["write_files"][0]["content"], "data\n")

    def test_comments_and_blank_lines(self):
        text = """\
#cloud-config

# This is a comment
hostname: test

# Another comment
"""
        data = nocloud_init.parse_user_data(text)
        self.assertEqual(data["hostname"], "test")

    def test_empty_document(self):
        data = nocloud_init.parse_user_data("")
        self.assertEqual(data, {})

    def test_comments_only(self):
        data = nocloud_init.parse_user_data("#cloud-config\n# just comments\n")
        self.assertEqual(data, {})

    def test_multiple_write_files(self):
        text = """\
write_files:
  - path: /run/secrets/key1
    content: |
      secret1
    permissions: '0400'
    owner: root:root
  - path: /run/secrets/key2
    content: |
      secret2
    permissions: '0400'
    owner: root:root
"""
        data = nocloud_init.parse_user_data(text)
        self.assertEqual(len(data["write_files"]), 2)
        self.assertEqual(data["write_files"][0]["path"], "/run/secrets/key1")
        self.assertEqual(data["write_files"][0]["content"], "secret1\n")
        self.assertEqual(data["write_files"][1]["path"], "/run/secrets/key2")
        self.assertEqual(data["write_files"][1]["content"], "secret2\n")

    def test_sequence_item_without_colon_not_treated_as_mapping(self):
        """ssh keys contain spaces but no colons — must be simple items."""
        text = "ssh_authorized_keys:\n  - ssh-ed25519 AAAAC3 user@host\n"
        data = nocloud_init.parse_user_data(text)
        self.assertEqual(data["ssh_authorized_keys"],
                         ["ssh-ed25519 AAAAC3 user@host"])

    def test_sequence_item_with_colon_treated_as_mapping(self):
        """Items with colon in key:value position are mapping items."""
        text = "items:\n  - key: value\n"
        data = nocloud_init.parse_user_data(text)
        self.assertEqual(data["items"], [{"key": "value"}])


# ── handle_hostname tests ────────────────────────────────────────────


class TestHandleHostname(unittest.TestCase):

    def test_sets_hostname(self):
        with mock.patch.object(nocloud_init.subprocess, "run") as mock_run:
            nocloud_init.handle_hostname({"hostname": "dns1-prod"})
            mock_run.assert_called_once_with(
                ["hostname", "dns1-prod"], check=True)

    def test_no_hostname_key(self):
        with mock.patch.object(nocloud_init.subprocess, "run") as mock_run:
            nocloud_init.handle_hostname({})
            mock_run.assert_not_called()

    def test_empty_hostname(self):
        with mock.patch.object(nocloud_init.subprocess, "run") as mock_run:
            nocloud_init.handle_hostname({"hostname": ""})
            mock_run.assert_not_called()

    def test_command_failure_raises(self):
        with mock.patch.object(
                nocloud_init.subprocess, "run",
                side_effect=subprocess.CalledProcessError(1, "hostname")):
            with self.assertRaises(subprocess.CalledProcessError):
                nocloud_init.handle_hostname({"hostname": "fail"})


# ── handle_ssh_keys tests ────────────────────────────────────────────


class _FakePathlib:
    """Stand-in for pathlib that redirects /root/.ssh to a temp dir.

    Only replaces the module-level reference in nocloud_init, so the
    real pathlib.Path is never patched globally.
    """

    def __init__(self, ssh_dir):
        self._ssh_dir = ssh_dir

    def Path(self, p):
        if p == "/root/.ssh":
            return pathlib.Path(self._ssh_dir)
        return pathlib.Path(p)


class TestHandleSSHKeys(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.ssh_dir = pathlib.Path(self.tmpdir) / ".ssh"

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _call(self, data):
        """Call handle_ssh_keys with /root/.ssh redirected to tmpdir."""
        fake = _FakePathlib(self.ssh_dir)
        with mock.patch.object(nocloud_init, "pathlib", fake):
            nocloud_init.handle_ssh_keys(data)

    def test_writes_keys(self):
        self._call({"ssh_authorized_keys": ["ssh-ed25519 AAAA key1"]})
        auth = self.ssh_dir / "authorized_keys"
        self.assertTrue(auth.exists())
        self.assertIn("ssh-ed25519 AAAA key1", auth.read_text())

    def test_dedup_across_calls(self):
        """Dedup works against keys already in the file (the real-world case)."""
        self._call({"ssh_authorized_keys": ["key1"]})
        self._call({"ssh_authorized_keys": ["key1"]})
        auth = self.ssh_dir / "authorized_keys"
        lines = [l for l in auth.read_text().splitlines() if l]
        self.assertEqual(lines.count("key1"), 1)

    def test_appends_to_existing(self):
        self.ssh_dir.mkdir(parents=True, exist_ok=True)
        auth = self.ssh_dir / "authorized_keys"
        auth.write_text("existing-key\n")
        os.chmod(auth, 0o600)
        self._call({"ssh_authorized_keys": ["new-key"]})
        content = auth.read_text()
        self.assertIn("existing-key", content)
        self.assertIn("new-key", content)

    def test_no_duplicate_with_existing(self):
        self.ssh_dir.mkdir(parents=True, exist_ok=True)
        auth = self.ssh_dir / "authorized_keys"
        auth.write_text("existing-key\n")
        os.chmod(auth, 0o600)
        self._call({"ssh_authorized_keys": ["existing-key"]})
        lines = [l for l in auth.read_text().splitlines() if l]
        self.assertEqual(lines.count("existing-key"), 1)

    def test_empty_keys_list(self):
        self._call({"ssh_authorized_keys": []})
        auth = self.ssh_dir / "authorized_keys"
        self.assertFalse(auth.exists())

    def test_no_ssh_key_field(self):
        self._call({})
        auth = self.ssh_dir / "authorized_keys"
        self.assertFalse(auth.exists())

    def test_users_format(self):
        data = {
            "users": [
                {"ssh_authorized_keys": ["user-key-1"]},
            ]
        }
        self._call(data)
        auth = self.ssh_dir / "authorized_keys"
        self.assertIn("user-key-1", auth.read_text())

    def test_directory_permissions(self):
        self._call({"ssh_authorized_keys": ["testkey"]})
        self.assertEqual(stat.S_IMODE(os.stat(self.ssh_dir).st_mode), 0o700)

    def test_file_permissions(self):
        self._call({"ssh_authorized_keys": ["testkey"]})
        auth = self.ssh_dir / "authorized_keys"
        self.assertEqual(stat.S_IMODE(os.stat(auth).st_mode), 0o600)


# ── handle_write_files tests ─────────────────────────────────────────


class TestHandleWriteFiles(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _make_data(self, entries):
        """Rewrite paths to use tmpdir."""
        for e in entries:
            e["path"] = os.path.join(self.tmpdir, e["path"].lstrip("/"))
        return {"write_files": entries}

    def test_plain_text(self):
        data = self._make_data([{
            "path": "/test.txt",
            "content": "hello\n",
            "permissions": "0644",
        }])
        nocloud_init.handle_write_files(data)
        p = pathlib.Path(data["write_files"][0]["path"])
        self.assertEqual(p.read_text(), "hello\n")
        self.assertEqual(stat.S_IMODE(os.stat(p).st_mode), 0o644)

    def test_base64_encoding(self):
        raw = b"binary\x00data"
        encoded = base64.b64encode(raw).decode()
        data = self._make_data([{
            "path": "/binary.dat",
            "content": encoded,
            "encoding": "b64",
            "permissions": "0600",
        }])
        nocloud_init.handle_write_files(data)
        p = pathlib.Path(data["write_files"][0]["path"])
        self.assertEqual(p.read_bytes(), raw)

    def test_base64_alias(self):
        raw = b"test"
        encoded = base64.b64encode(raw).decode()
        data = self._make_data([{
            "path": "/b64test",
            "content": encoded,
            "encoding": "base64",
            "permissions": "0644",
        }])
        nocloud_init.handle_write_files(data)
        p = pathlib.Path(data["write_files"][0]["path"])
        self.assertEqual(p.read_bytes(), raw)

    def test_permission_parsing(self):
        data = self._make_data([{
            "path": "/secret",
            "content": "key\n",
            "permissions": "0400",
        }])
        nocloud_init.handle_write_files(data)
        p = pathlib.Path(data["write_files"][0]["path"])
        self.assertEqual(stat.S_IMODE(os.stat(p).st_mode), 0o400)

    def test_invalid_permissions_fallback(self):
        data = self._make_data([{
            "path": "/badperms",
            "content": "x\n",
            "permissions": "notanumber",
        }])
        nocloud_init.handle_write_files(data)
        p = pathlib.Path(data["write_files"][0]["path"])
        self.assertEqual(stat.S_IMODE(os.stat(p).st_mode), 0o644)

    def test_missing_path_skipped(self):
        data = {"write_files": [{"content": "orphan"}]}
        nocloud_init.handle_write_files(data)

    def test_parent_directory_creation(self):
        data = self._make_data([{
            "path": "/a/b/c/deep.txt",
            "content": "deep\n",
            "permissions": "0644",
        }])
        nocloud_init.handle_write_files(data)
        p = pathlib.Path(data["write_files"][0]["path"])
        self.assertTrue(p.exists())
        self.assertEqual(p.read_text(), "deep\n")

    def test_multiple_files(self):
        data = self._make_data([
            {"path": "/file1", "content": "one\n", "permissions": "0644"},
            {"path": "/file2", "content": "two\n", "permissions": "0600"},
        ])
        nocloud_init.handle_write_files(data)
        self.assertEqual(
            pathlib.Path(data["write_files"][0]["path"]).read_text(), "one\n")
        self.assertEqual(
            pathlib.Path(data["write_files"][1]["path"]).read_text(), "two\n")

    def test_not_a_list(self):
        """write_files that isn't a list should be a no-op."""
        nocloud_init.handle_write_files({"write_files": "not a list"})

    def test_non_dict_entry_skipped(self):
        nocloud_init.handle_write_files({"write_files": ["just a string"]})


# ── Handler isolation in main() ──────────────────────────────────────


class TestMainHandlerIsolation(unittest.TestCase):
    """Verify that one handler failing doesn't block the others."""

    def _run_main(self, hostname_effect=None, ssh_effect=None, wf_effect=None):
        """Run main() with mocked mount/unmount and handler side effects."""
        # Create a real temp dir with a user-data file so main() finds it
        mount_dir = tempfile.mkdtemp()
        ud_path = os.path.join(mount_dir, "user-data")
        with open(ud_path, "w") as f:
            f.write("hostname: test\n")

        # Create mocks with __name__ set (main() accesses handler.__name__)
        m_host = mock.MagicMock(side_effect=hostname_effect)
        m_host.__name__ = "handle_hostname"
        m_ssh = mock.MagicMock(side_effect=ssh_effect)
        m_ssh.__name__ = "handle_ssh_keys"
        m_wf = mock.MagicMock(side_effect=wf_effect)
        m_wf.__name__ = "handle_write_files"

        try:
            with mock.patch.object(nocloud_init, "mount_cidata",
                                   return_value=mount_dir), \
                 mock.patch.object(nocloud_init, "unmount_cidata"), \
                 mock.patch.object(nocloud_init, "handle_hostname", m_host), \
                 mock.patch.object(nocloud_init, "handle_ssh_keys", m_ssh), \
                 mock.patch.object(nocloud_init, "handle_write_files", m_wf):
                rc = nocloud_init.main()
                return rc, m_host, m_ssh, m_wf
        finally:
            shutil.rmtree(mount_dir, ignore_errors=True)

    def test_one_handler_fails_others_still_run(self):
        rc, m_host, m_ssh, m_wf = self._run_main(
            hostname_effect=RuntimeError("boom"))
        m_host.assert_called_once()
        m_ssh.assert_called_once()
        m_wf.assert_called_once()
        self.assertEqual(rc, 1)

    def test_all_handlers_fail(self):
        rc, _, _, _ = self._run_main(
            hostname_effect=RuntimeError("a"),
            ssh_effect=RuntimeError("b"),
            wf_effect=RuntimeError("c"))
        self.assertEqual(rc, 1)

    def test_all_handlers_succeed(self):
        rc, _, _, _ = self._run_main()
        self.assertEqual(rc, 0)

    def test_mount_failure_returns_nonzero(self):
        with mock.patch.object(nocloud_init, "mount_cidata",
                               side_effect=OSError("no device")):
            rc = nocloud_init.main()
        self.assertEqual(rc, 1)

    def test_no_user_data_returns_zero(self):
        empty_dir = tempfile.mkdtemp()
        try:
            with mock.patch.object(nocloud_init, "mount_cidata",
                                   return_value=empty_dir), \
                 mock.patch.object(nocloud_init, "unmount_cidata"):
                rc = nocloud_init.main()
            self.assertEqual(rc, 0)
        finally:
            shutil.rmtree(empty_dir, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
