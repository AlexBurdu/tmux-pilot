"""Unit tests for mcp/server.py event listener system."""

import json
import os
import sys
import tempfile
import unittest
from unittest.mock import patch, MagicMock

# Add mcp/ to path so we can import server
sys.path.insert(
    0,
    os.path.join(
        os.path.dirname(__file__), "..", "mcp"
    ),
)

# Import server module
import server


class TestLoadListeners(unittest.TestCase):
    """Test _load_listeners function."""

    def setUp(self):
        # Reset listeners before each test
        server._listeners = []

    def test_no_config_file(self):
        """Test that _load_listeners works with no config file."""
        server._load_listeners()
        self.assertEqual(len(server._listeners), 0)

    def test_empty_listeners_array(self):
        """Test that _load_listeners works with empty listeners array."""
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            json.dump({"listeners": []}, f)
            config_path = f.name
        
        try:
            with patch('os.path.expanduser', return_value=config_path):
                server._load_listeners()
            self.assertEqual(len(server._listeners), 0)
        finally:
            os.unlink(config_path)

    def test_valid_listener_module(self):
        """Test that _load_listeners loads a valid module."""
        # Create a mock module
        mock_module = MagicMock()
        mock_module.create_listener.return_value = lambda event: None
        
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            json.dump({"listeners": ["tests.mock_listener"]}, f)
            config_path = f.name
        
        try:
            with patch('os.path.expanduser', return_value=config_path):
                with patch('importlib.import_module', return_value=mock_module):
                    server._load_listeners()
            self.assertEqual(len(server._listeners), 1)
        finally:
            os.unlink(config_path)

    def test_invalid_module_path(self):
        """Test that _load_listeners handles invalid module paths."""
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            json.dump({"listeners": ["invalid.module.path"]}, f)
            config_path = f.name
        
        try:
            with patch('os.path.expanduser', return_value=config_path):
                with patch('importlib.import_module', side_effect=ImportError("Module not found")):
                    server._load_listeners()
            self.assertEqual(len(server._listeners), 0)
        finally:
            os.unlink(config_path)

    def test_module_without_create_listener(self):
        """Test that _load_listeners handles modules without create_listener."""
        mock_module = MagicMock()
        del mock_module.create_listener
        
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            json.dump({"listeners": ["tests.mock_listener"]}, f)
            config_path = f.name
        
        try:
            with patch('os.path.expanduser', return_value=config_path):
                with patch('importlib.import_module', return_value=mock_module):
                    server._load_listeners()
            self.assertEqual(len(server._listeners), 0)
        finally:
            os.unlink(config_path)

    def test_create_listener_returns_non_callable(self):
        """Test that _load_listeners handles create_listener returning non-callable."""
        mock_module = MagicMock()
        mock_module.create_listener.return_value = "not a function"
        
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            json.dump({"listeners": ["tests.mock_listener"]}, f)
            config_path = f.name
        
        try:
            with patch('os.path.expanduser', return_value=config_path):
                with patch('importlib.import_module', return_value=mock_module):
                    server._load_listeners()
            self.assertEqual(len(server._listeners), 0)
        finally:
            os.unlink(config_path)


class TestEmit(unittest.TestCase):
    """Test _emit function."""

    def setUp(self):
        # Reset listeners before each test
        server._listeners = []

    def test_no_op_with_empty_listeners(self):
        """Test that _emit is a no-op when _listeners is empty."""
        event = {"event": "test"}
        server._emit(event)
        # Should not raise any exception

    def test_calls_all_listeners(self):
        """Test that _emit calls all registered listeners."""
        listener1 = MagicMock()
        listener2 = MagicMock()
        server._listeners = [listener1, listener2]
        
        event = {"event": "test", "data": "value"}
        server._emit(event)
        
        listener1.assert_called_once()
        listener2.assert_called_once()
        
        # Check that timestamp was added
        call_arg = listener1.call_args[0][0]
        self.assertIn("ts", call_arg)
        self.assertEqual(call_arg["event"], "test")
        self.assertEqual(call_arg["data"], "value")

    def test_catches_listener_exceptions(self):
        """Test that _emit catches exceptions from listeners."""
        def failing_listener(event):
            raise Exception("Test exception")
        
        server._listeners = [failing_listener]
        
        event = {"event": "test"}
        # Should not raise exception
        server._emit(event)

    def test_adds_timestamp_to_event(self):
        """Test that _emit adds timestamp to event."""
        listener = MagicMock()
        server._listeners = [listener]
        
        event = {"event": "test"}
        server._emit(event)
        
        call_arg = listener.call_args[0][0]
        self.assertIn("ts", call_arg)
        # Timestamp should be in ISO format (ends with Z or +00:00)
        self.assertTrue(call_arg["ts"].endswith("Z") or call_arg["ts"].endswith("+00:00"))


if __name__ == "__main__":
    unittest.main()