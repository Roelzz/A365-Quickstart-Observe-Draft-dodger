# Copyright (c) Microsoft. All rights reserved.

"""Agent Interface - Base class for all agents"""

from abc import ABC, abstractmethod
from typing import Optional

from microsoft_agents.hosting.core import Authorization, TurnContext


class AgentInterface(ABC):
    """Abstract base class for agents implementing AgentFramework pattern"""

    @abstractmethod
    async def initialize(self) -> None:
        """Initialize the agent. Called once when the agent starts."""
        pass

    @abstractmethod
    async def process_user_message(
        self,
        message: str,
        auth: Authorization,
        auth_handler_name: Optional[str],
        context: TurnContext,
    ) -> str:
        """Process a user message and return a response.

        Args:
            message: The user's message text
            auth: Authorization context for API calls
            auth_handler_name: Name of the auth handler for token exchange
            context: The turn context for the conversation

        Returns:
            The agent's response as a string
        """
        pass

    @abstractmethod
    async def cleanup(self) -> None:
        """Clean up agent resources. Called when the agent shuts down."""
        pass


def check_agent_inheritance(agent_class: type) -> bool:
    """Check if a class properly inherits from AgentInterface"""
    return issubclass(agent_class, AgentInterface)
