# Copyright (c) Microsoft. All rights reserved.

"""Token Cache - Simple in-memory token cache for observability"""

import logging
from typing import Dict, Optional

logger = logging.getLogger(__name__)

# Simple in-memory token cache
# Key: (tenant_id, agent_id), Value: token
_token_cache: Dict[tuple, str] = {}


def cache_agentic_token(tenant_id: str, agent_id: str, token: str) -> None:
    """Cache an agentic token for later use"""
    key = (tenant_id, agent_id)
    _token_cache[key] = token
    logger.debug(f"Cached token for tenant={tenant_id}, agent={agent_id}")


def get_cached_agentic_token(tenant_id: str, agent_id: str) -> Optional[str]:
    """Get a cached agentic token"""
    key = (tenant_id, agent_id)
    token = _token_cache.get(key)
    if token:
        logger.debug(f"Retrieved cached token for tenant={tenant_id}, agent={agent_id}")
    else:
        logger.debug(f"No cached token for tenant={tenant_id}, agent={agent_id}")
    return token


def clear_token_cache() -> None:
    """Clear all cached tokens"""
    _token_cache.clear()
    logger.debug("Token cache cleared")
