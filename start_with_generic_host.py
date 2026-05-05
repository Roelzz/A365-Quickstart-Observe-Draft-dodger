# Copyright (c) Microsoft. All rights reserved.

"""Start with Generic Host - Entry point for Draft Dodger"""

from agent import DraftDodgerAgent
from host_agent_server import create_and_run_host


if __name__ == "__main__":
    create_and_run_host(DraftDodgerAgent)
