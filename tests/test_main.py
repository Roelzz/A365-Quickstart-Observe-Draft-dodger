"""Tests for Draft Dodger"""

from token_cache import cache_agentic_token, get_cached_agentic_token, clear_token_cache


class TestTokenCache:
    def setup_method(self):
        clear_token_cache()

    def test_cache_and_retrieve_token(self):
        cache_agentic_token("tenant-1", "agent-1", "token-abc")
        result = get_cached_agentic_token("tenant-1", "agent-1")
        assert result == "token-abc"

    def test_missing_token_returns_none(self):
        result = get_cached_agentic_token("tenant-x", "agent-x")
        assert result is None

    def test_clear_cache(self):
        cache_agentic_token("tenant-1", "agent-1", "token-abc")
        clear_token_cache()
        result = get_cached_agentic_token("tenant-1", "agent-1")
        assert result is None

    def test_overwrite_token(self):
        cache_agentic_token("tenant-1", "agent-1", "old-token")
        cache_agentic_token("tenant-1", "agent-1", "new-token")
        result = get_cached_agentic_token("tenant-1", "agent-1")
        assert result == "new-token"

    def test_multiple_agents(self):
        cache_agentic_token("tenant-1", "agent-1", "token-1")
        cache_agentic_token("tenant-1", "agent-2", "token-2")
        assert get_cached_agentic_token("tenant-1", "agent-1") == "token-1"
        assert get_cached_agentic_token("tenant-1", "agent-2") == "token-2"


class TestAgentInterface:
    def test_check_agent_inheritance(self):
        from agent_interface import check_agent_inheritance, AgentInterface

        class ValidAgent(AgentInterface):
            async def initialize(self): pass
            async def process_user_message(self, message, auth, auth_handler_name, context): return ""
            async def cleanup(self): pass

        assert check_agent_inheritance(ValidAgent) is True

    def test_non_agent_class_fails(self):
        from agent_interface import check_agent_inheritance

        class NotAnAgent:
            pass

        try:
            result = check_agent_inheritance(NotAnAgent)
            assert result is False
        except TypeError:
            pass
