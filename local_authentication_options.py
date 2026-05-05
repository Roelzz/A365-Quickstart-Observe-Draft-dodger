# Copyright (c) Microsoft. All rights reserved.

"""Local Authentication Options - Configuration for local development"""

import os
from dataclasses import dataclass
from typing import Optional


@dataclass
class LocalAuthenticationOptions:
    """Authentication options for local development"""

    bearer_token: Optional[str] = None
    client_id: Optional[str] = None
    client_secret: Optional[str] = None
    tenant_id: Optional[str] = None

    @classmethod
    def from_environment(cls) -> "LocalAuthenticationOptions":
        """Create authentication options from environment variables"""
        return cls(
            bearer_token=os.getenv("BEARER_TOKEN"),
            client_id=os.getenv("CLIENT_ID") or os.getenv("MicrosoftAppId"),
            client_secret=os.getenv("CLIENT_SECRET") or os.getenv("MicrosoftAppPassword"),
            tenant_id=os.getenv("TENANT_ID") or os.getenv("MicrosoftAppTenantId"),
        )

    @property
    def has_bearer_token(self) -> bool:
        """Check if a bearer token is available"""
        return bool(self.bearer_token)

    @property
    def has_client_credentials(self) -> bool:
        """Check if client credentials are available"""
        return bool(self.client_id and self.client_secret and self.tenant_id)
