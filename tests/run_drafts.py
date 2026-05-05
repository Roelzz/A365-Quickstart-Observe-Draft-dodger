"""Run a few diverse drafts through Draft Dodger end-to-end.

Hits the live Foundry Responses API. Requires `az login` and a working .env.
Not part of the unit-test suite (costs money, slow, needs network).

Run with:
    uv run python tests/run_drafts.py
"""

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agent import DraftDodgerAgent


DRAFTS: list[tuple[str, str]] = [
    (
        "1. NUCLEAR — career-ending resignation rant",
        """Hi Mark,

After 4 years of being underpaid, ignored in promotion rounds, and watching less competent people get the credit for MY work, I am DONE. Effective immediately, I quit. Do not contact me. Do not ask me to "transition" anything — figure it out yourself like I had to figure out everything else.

For the record: Sarah is the reason this team is dysfunctional. Everyone knows it. You're just too cowardly to do anything about it. Good luck explaining the Q4 numbers without me.

Have fun,
Alex""",
    ),
    (
        "2. PASSIVE-AGGRESSIVE — chasing a colleague",
        """Hi Priya,

Just circling back on this since I haven't heard anything in 6 days. Per my last email (and the one before that), I really do need the deck for the board meeting. I'm sure you've been very busy with whatever it is you've been working on, but this is kind of a priority for the rest of the team.

Let me know if you'd like me to put it on your calendar. Again.

Thanks,
Jamie""",
    ),
    (
        "3. CLEAN — straightforward status update",
        """Hi team,

Quick update on the integration work. The auth flow is wired up end-to-end and tests are passing. I'm pushing the PR this afternoon and aiming to have it merged before Friday's release.

Two open questions for tomorrow's standup:
- Do we want to log the refresh token rotation, or is that too noisy?
- Should error responses include the trace ID, or only show it in the UI?

Let me know if anything else needs to land in this release.

Thanks,
Sam""",
    ),
    (
        "4. AWKWARDLY OVER-FORMAL — to a peer",
        """Dear Esteemed Colleague Tom,

Pursuant to our recent verbal communication of yesterday, I hereby formally write to inquire as to the precise temporal coordinates at which it would be most amenable to your busy schedule for us to engage in a collaborative discussion regarding the matter of the upcoming office potluck event.

I remain, with utmost respect,
Yours faithfully,
Lisa (from two desks over)""",
    ),
    (
        "5. BORDERLINE — frustrated but professional",
        """Hi Chris,

Thanks for the feedback on the proposal. I want to make sure I understand correctly: the team initially asked for option A in the kickoff, then in the review you asked for option B, and now we're being asked to revisit option A again.

Before I rework the document a third time, can we get alignment on which direction we're committing to? Happy to set up a quick 15 minutes if that's easier.

Best,
Morgan""",
    ),
]


async def run_one(idx: int, label: str, draft: str, agent: DraftDodgerAgent) -> None:
    print("=" * 80)
    print(f"CASE {label}")
    print("=" * 80)
    print("DRAFT:")
    print(draft)
    print()
    print("VERDICT:")
    response = await agent.process_user_message(draft, None, None, None)
    print(response)
    print()


async def main() -> None:
    agent = DraftDodgerAgent()
    await agent.initialize()
    try:
        for idx, (label, draft) in enumerate(DRAFTS, start=1):
            await run_one(idx, label, draft, agent)
    finally:
        await agent.cleanup()


if __name__ == "__main__":
    asyncio.run(main())
