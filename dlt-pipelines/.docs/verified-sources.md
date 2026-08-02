---
title: Sources
description: Available sources
keywords: ['source']
---


Planning to use `dlt` in production and need a source that isn't listed? We're happy to help you build it: <Link/>.

### Core sources

- [REST APIs](./rest_api/index.md)
- [30+ SQL databases](./sql_database/index.md)
- [Object store & filesystem](./filesystem/index.md)

### Verified sources

Choose from our collection of verified sources, developed and maintained by the `dlt` team and community. Each source is rigorously tested against a real API and provided as Python code for easy customization.

:::tip
If you couldn't find a source implementation, you can easily create your own. Check out the [resource page](../../general-usage/resource.md) to learn how!
:::

[Airtable](./airtable.md) Â· [Amazon Kinesis](./amazon_kinesis.md) Â· [Asana](./asana.md) Â· [Chess](./chess.md) Â· [Facebook Ads](./facebook_ads.md) Â· [Freshdesk](./freshdesk.md) Â· [GitHub](./github.md) Â· [Google Ads](./google_ads.md) Â· [Google Analytics](./google_analytics.md) Â· [Google Sheets](./google_sheets.md) Â· [HubSpot](./hubspot.md) Â· [Inbox](./inbox.md) Â· [Jira](./jira.md) Â· [Kafka](./kafka.md) Â· [Matomo](./matomo.md) Â· [MongoDB](./mongodb.md) Â· [Mux](./mux.md) Â· [Notion](./notion.md) Â· [Personio](./personio.md) Â· [Postgres Replication](./pg_replication.md) Â· [Pipedrive](./pipedrive.md) Â· [Salesforce](./salesforce.md) Â· [Scrapy](./scrapy.md) Â· [Shopify](./shopify.md) Â· [Slack](./slack.md) Â· [Strapi](./strapi.md) Â· [Stripe](./stripe.md) Â· [Workable](./workable.md) Â· [Zendesk](./zendesk.md)

### What's the difference between core and verified sources?

The main difference between the [core sources](#core-sources) and [verified sources](#verified-sources) lies in their structure.
Core sources are generic collections, meaning they can connect to a variety of systems. For example, the [SQL Database source](./sql_database/index.md) can connect to any
database that supports SQLAlchemy.

According to our telemetry, core sources are the most widely used among our users!

It's also important to note that core sources are integrated into the `dlt` core library,
whereas verified sources are maintained in a separate [repository](https://github.com/dlt-hub/verified-sources).
To use a verified source, you need to run the `dlt` init command, which will download the verified source code to
your working directory.


### Get help

* Source missing? [Request a new verified source.](https://github.com/dlt-hub/verified-sources/issues/new?template=source-request.md)
* Missing endpoint or a feature? [Request or contribute](https://github.com/dlt-hub/verified-sources/issues/new?template=extend-a-source.md)
* [Join our Slack community](https://dlthub.com/community) and ask in the technical-help channel.
