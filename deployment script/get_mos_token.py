"""Get MOS (Microsoft Online Services) token via device code flow.

Used to publish agent blueprints to Teams on macOS where the a365 CLI's
built-in MOS token acquisition fails (WAM not available).

Usage:
    python scripts/get_mos_token.py                          # uses TENANT_ID from .env
    python scripts/get_mos_token.py --tenant-id <TENANT_ID>  # explicit tenant
"""

import argparse
import os
import sys

sys.stdout.reconfigure(line_buffering=True)

try:
    import msal
except ImportError:
    print("ERROR: msal not installed. Run: uv add msal")
    sys.exit(1)


def get_mos_token(tenant_id: str) -> str:
    # TPS first-party app — same client the a365 CLI's MosTokenService uses internally
    client_id = "caef0b02-8d39-46ab-b28c-f517033d8a21"
    authority = f"https://login.microsoftonline.com/{tenant_id}"
    scopes = ["e8be65d6-d430-4289-a665-51bf2a194bda/.default"]

    app = msal.PublicClientApplication(client_id, authority=authority)
    flow = app.initiate_device_flow(scopes=scopes)

    if "user_code" not in flow:
        print(f"ERROR: Could not initiate device flow: {flow}")
        sys.exit(1)

    print(flow["message"])
    sys.stdout.flush()

    result = app.acquire_token_by_device_flow(flow)

    if "access_token" in result:
        token_path = "/tmp/mos_token.txt"
        with open(token_path, "w") as f:
            f.write(result["access_token"])
        print(f"Token saved to {token_path}")
        return result["access_token"]
    else:
        print(f"ERROR: {result.get('error_description', result)}")
        sys.exit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Get MOS token for a365 publish")
    parser.add_argument(
        "--tenant-id",
        default=os.getenv("TENANT_ID"),
        help="Azure AD tenant ID (default: TENANT_ID from environment)",
    )
    args = parser.parse_args()

    if not args.tenant_id:
        # Try loading from .env
        try:
            from dotenv import load_dotenv
            load_dotenv()
            args.tenant_id = os.getenv("TENANT_ID")
        except ImportError:
            pass

    if not args.tenant_id:
        print("ERROR: --tenant-id required (or set TENANT_ID in .env)")
        sys.exit(1)

    get_mos_token(args.tenant_id)
