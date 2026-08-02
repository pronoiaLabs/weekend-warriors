"""Batch dlt ingestion: the registry-driven runner for scheduled loads.

Everything here is about
run-to-completion dlt pipelines defined in batch/registries/*.yml, executed by
run.py and (in Snowflake) fired by cron Tasks. Shared helpers live in
pipelines.common.
"""
