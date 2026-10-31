"""Set up a local txwtf instance's database for nicotina's tests (tests/local.sh).

Run it with the Python of a txwtf install (a cvcpkg prefix with txwtf-cp312), after
`txwtf init-db`, before `txwtf backend`. It uses txwtf's own core functions, the ones the
server runs, so the accounts are what the API would make:

  ada    plain sign-in; a description, 1234.56789 SCRIP minted to her, two posts and a
         reply to the first (txwtf's create_post), for the profile's Posts and Replies tabs
  grace  a verified email and the emailed second factor turned on
  linus  force_password_change set

All three take the password given with --password. It also points the instance's email.smtp
settings at a local SMTP server (tests/smtp_sink.py), without TLS, so the sign-in code
email can be read back, and turns off the email deliverability check.

  python3.12 txwtf_local.py --db-url sqlite+aiosqlite:////abs/txwtf.db --password PW --smtp-port N
"""

import argparse
import asyncio
from decimal import Decimal

from sqlmodel import select

from txwtf.core import register_user, set_setting
from txwtf.core.db import get_engine, get_session
from txwtf.core.model import User
from txwtf.core.scrip import ensure_scrip_currency, mint_scrip
from txwtf.core.social import create_post

ACCOUNTS = {
    "ada": {
        "name": "Ada Lovelace",
        "email": "ada@example.org",
        "description": "Writes notes on the analytical engine. Prefers punched cards to paper tape.",
        "scrip": "1234.56789",
        # oldest first; a post that starts with "> " replies to the one before it
        "posts": ["Hello from the analytical engine.", "> Note G is the long one.",
                  "Bernoulli numbers, step by step."],
    },
    "grace": {"name": "Grace Hopper", "email": "grace@example.org", "two_factor": True},
    "linus": {"name": "Linus", "email": "linus@example.org", "force_password_change": True},
}


async def provision(db_url, password, smtp_port):
    engine = get_engine(db_url)
    async with get_session(engine) as session:
        for key, value in (
            ("host", "127.0.0.1"),
            ("port", str(smtp_port)),
            ("use_tls", "0"),
            ("use_ssl", "0"),
            ("from_address", "noreply@example.org"),
            ("from_name", "txwtf (nicotina tests)"),
        ):
            await set_setting(session, "email", "smtp", key, value)
        await set_setting(session, "email", "enabled", "1")  # off by default
        # The accounts' @example.org addresses accept no mail; the sink takes it all anyway.
        await set_setting(session, "email_validate_deliv_enabled", "0")

        for username, a in ACCOUNTS.items():
            await register_user(
                session,
                username,
                password,
                password,
                a["name"],
                a["email"],
                add_user_to_default_group=True,
            )
            user = (await session.exec(select(User).where(User.username == username))).one()
            user.description = a.get("description")
            if a.get("two_factor"):
                user.email_verified = True
                user.login_2fa_email_enabled = True
            if a.get("force_password_change"):
                user.force_password_change = True
            session.add(user)
            await session.commit()
            if a.get("scrip"):
                await ensure_scrip_currency(session)
                await mint_scrip(session, user.id, Decimal(a["scrip"]), reason="nicotina tests")
                await session.commit()
            last = None
            for content in a.get("posts", []):
                reply = content.startswith("> ")
                post = await create_post(session, user.id, content[2:] if reply else content,
                                         reply_to_id=last.id if reply else None, emit_event=False)
                await session.commit()
                last = post
    await engine.dispose()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--db-url", required=True)
    ap.add_argument("--password", required=True)
    ap.add_argument("--smtp-port", type=int, required=True)
    args = ap.parse_args()
    asyncio.run(provision(args.db_url, args.password, args.smtp_port))
    print("provisioned:", " ".join(ACCOUNTS))


if __name__ == "__main__":
    main()
