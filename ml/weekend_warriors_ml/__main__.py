from __future__ import annotations

import argparse

from weekend_warriors_ml.pipeline import cook, fit, inspect
from weekend_warriors_ml.session import create_session


def main() -> None:
    parser = argparse.ArgumentParser(description="NFL game-total v1 on FEATURES.")
    parser.add_argument(
        "command",
        choices=("inspect", "fit", "cook"),
        help="inspect = row counts; fit = walk-forward only; cook = fit+register+score",
    )
    parser.add_argument(
        "--no-batch",
        action="store_true",
        help="Skip mv.run_batch on ML_DEV_POOL (local pred table still written).",
    )
    args = parser.parse_args()
    session = create_session()
    try:
        if args.command == "inspect":
            inspect(session)
        elif args.command == "fit":
            fit(session)
        else:
            cook(session, batch=not args.no_batch)
    finally:
        session.close()


if __name__ == "__main__":
    main()
