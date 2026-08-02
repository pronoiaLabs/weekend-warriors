"""Shared code used across the pipeline packages.

Keeps mode-agnostic helpers (structured logging, Snowflake connection/SPCS
detection) in one place so each pipeline package never has to import from
`pipelines.batch` and vice versa.
"""
