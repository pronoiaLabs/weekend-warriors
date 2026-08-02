"""In-code sample source: a zero-dependency dlt source that yields rows in Python.

WHY THIS EXISTS
    Every other source can fail for reasons that have nothing to do with this repo: an
    expired credential, a network policy, an API outage. This one cannot. It has no
    external system, no network call and no secret, so when it fails the problem is the
    environment or the code, and when it succeeds the loading path is proven end to end.

    That makes it the first thing to reach for when a real pipeline breaks and you need
    to know which half is at fault.

CONTENTS
    1. Fixture data ..... _CUSTOMERS, _ORDERS
    2. The source ....... sample_source

RUNS IDENTICALLY EVERYWHERE
        make run-local     NAME=sample   # local DuckDB, no credentials at all
        make run-snowflake NAME=sample   # laptop -> Snowflake
        make run-spcs      NAME=sample   # in-Snowflake SPCS job, no SECRET needed

    The SPCS variant is the reason this is not a test fixture. It pairs with
    deploy/spcs/dlt_dev_job_nosecret.tmpl.yaml to prove the container path works before
    any secret is bound, which separates two failures that otherwise look the same.

WHERE IT LIVES
    Under `pipelines/` deliberately. The Dockerfile copies that package into the image,
    so this source ships with the runner. Code placed outside it works locally and
    vanishes inside the container.

TWO RESOURCES ON PURPOSE
    `customers` and `orders` exercise a multi-table load with a foreign key between
    them, so the smoke test covers more than a single flat table. It is also the only
    end-to-end test in the suite that actually executes run_pipeline().
"""

from __future__ import annotations

from typing import Any, Iterator

import dlt

# ---------------------------------------------------------------------------
# 1. Fixture data
#
# Deterministic and hardcoded, which is the whole point: the same five rows load on
# every machine and in every environment, so a row count is a meaningful assertion. Any
# randomness here would make the smoke test unable to say what "correct" is.
# ---------------------------------------------------------------------------

_CUSTOMERS = [
    (1, "Alice Nguyen", "alice@example.com", "2024-01-01T09:00:00Z"),
    (2, "Bob Martinez", "bob@example.com", "2024-01-02T10:30:00Z"),
    (3, "Carol Idris", "carol@example.com", "2024-01-03T14:15:00Z"),
    (4, "Dan O'Neal", "dan@example.com", "2024-01-04T08:45:00Z"),
    (5, "Eve Zhang", "eve@example.com", "2024-01-05T16:20:00Z"),
]

_ORDERS = [
    (100, 1, "2024-01-06T11:00:00Z", 129.99, "shipped"),
    (101, 1, "2024-01-07T12:30:00Z", 19.50, "delivered"),
    (102, 2, "2024-01-07T09:10:00Z", 249.00, "processing"),
    (103, 3, "2024-01-08T15:45:00Z", 75.25, "shipped"),
    (104, 5, "2024-01-09T13:05:00Z", 42.00, "cancelled"),
]


# ---------------------------------------------------------------------------
# 2. The source
#
# `merge` on `id` rather than `append`, so re-running is idempotent. That matters more
# than it looks: this pipeline gets run repeatedly while debugging an environment, and
# an appending smoke test would grow its own tables every time and stop being a
# reliable signal.
# ---------------------------------------------------------------------------


@dlt.source(name="sample")
def sample_source(n_customers: int = 5, n_orders: int = 5) -> Any:
    """A dlt source with two deterministic tables (customers, orders).

    `n_customers` / `n_orders` cap the rows emitted (default: all 5 of each), so
    the registry `config` can shrink the sample without code changes.
    """

    @dlt.resource(name="customers", primary_key="id", write_disposition="merge")
    def customers() -> Iterator[dict[str, Any]]:
        for cid, name, email, updated_at in _CUSTOMERS[: max(0, n_customers)]:
            yield {"id": cid, "name": name, "email": email, "updated_at": updated_at}

    @dlt.resource(name="orders", primary_key="id", write_disposition="merge")
    def orders() -> Iterator[dict[str, Any]]:
        for oid, customer_id, ordered_at, amount, status in _ORDERS[: max(0, n_orders)]:
            yield {
                "id": oid,
                "customer_id": customer_id,
                "ordered_at": ordered_at,
                "amount": amount,
                "status": status,
            }

    return customers, orders
