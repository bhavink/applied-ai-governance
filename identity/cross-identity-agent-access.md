# One User, Two Identity Systems

## The question

Can an agent safely use data from two systems when each system signs users in differently?

For example:

- Databricks users sign in through Okta.
- Microsoft 365 users sign in through Microsoft Entra ID.
- An agent needs to answer from both systems without showing a person data they cannot normally access.

## The short answer

**Yes, this can work, but it is not automatic.**

A shared agent endpoint does not prove that the two user identities are the same person. The system must map both identities to one known user, and each data source must still check that user's permissions.

Do not promise this design until it passes a two-user access test.

## Prerequisites

All of these must be true before the design can preserve personal access:

1. **Every person must already have a Databricks account identity.** Usually, users are added automatically from the company's identity system. The identity handoff cannot create missing Databricks users.
2. **The Microsoft identity must match the correct Databricks user.** Use a stable, unique value that exists in both systems. A verified email address can work when both systems keep it identical, but a permanent user ID is safer when available.
3. **The user must have access to the Databricks workspace and agent.** Being known at the Databricks account level is not enough by itself.
4. **The user must have the required Databricks data permissions.** This includes permission to use the required data, query service, and agent.
5. **The user must have the required Microsoft 365 permissions.** The connector must respect the user's existing access to documents, sites, mail, or other requested content.
6. **The agent must call Databricks as the person.** It must not replace the person's identity with one shared application identity.
7. **The Microsoft 365 call must enforce the person's permissions.** It must either run as the person or use a connector that applies that person's access rules.
8. **The Genie Agent must evaluate data access as the end user.** Current Genie Agent documentation says the author's embedded credentials can provide warehouse access while Unity Catalog still checks the end user's data permissions. Do not treat embedded warehouse credentials as proof of shared data access.

Databricks identity federation maps a signed external identity to an existing Databricks user. It does not create the user or discover that two unrelated accounts belong to the same person.

If any prerequisite is missing, use a shared-data design with a tightly limited service identity, or stop until the identity setup is complete. Do not describe the result as per-user access.

## What a single endpoint does not guarantee

A single endpoint can simplify how applications call the agent. It does **not** by itself guarantee:

- that an Okta user and a Microsoft user are matched correctly;
- that Databricks permissions are applied to the human user;
- that Microsoft 365 permissions are applied to the human user;
- that downstream agents keep the human identity; or
- that cached answers cannot cross user boundaries.

Those behaviors must be configured and tested separately.

## The simplest safe design

```text
Person signs in
      |
      v
Agent receives the person's identity
      |
      +--> Databricks call as that person --> Databricks permissions apply
      |
      +--> Microsoft 365 call as that person --> Microsoft permissions apply
      |
      v
Agent combines only the results that person may see
```

Never replace the person's identity with one shared service account when personal access must be preserved.

## How Genie One reaches Microsoft 365

```text
Copilot, Foundry, or another agent
      |
      v
Genie One MCP service, called as the end user
      |
      v
Genie One
      |
      v
Databricks-managed Microsoft 365 MCP connector
      |
      v
SharePoint, Teams, Outlook, or Calendar
```

Each user authorizes the Microsoft 365 connector separately. Their Microsoft OAuth token is not shared with other users. Unity Gateway checks and audits the tool call.

This does not require Okta and Microsoft Entra to exchange tokens directly. The important link is the Databricks user: the incoming agent request must resolve to the same Databricks user who authorized the Microsoft 365 connection.

The public documentation confirms the individual parts of this flow. It does not explicitly guarantee the complete chained flow for every external agent. Prove that association with the two-user test below.

## The proof test

Create two test users with deliberately different access:

| Test user | Databricks access | Microsoft 365 access |
|---|---|---|
| User A | Databricks record A only | Microsoft document A only |
| User B | Databricks record B only | Microsoft document B only |

Ask both users the same questions through every supported entry point:

1. A Databricks-only question.
2. A Microsoft 365-only question.
3. A question that combines both sources.
4. A question that tries to retrieve the other user's data.

The design passes only when:

- User A never receives User B's records or documents.
- User B never receives User A's records or documents.
- Databricks audit records show the correct human identity.
- Microsoft audit records show the correct human identity or delegated permission check.
- The same result holds from each supported agent channel.

Also repeat the test after signing out, changing a permission, and disabling a user. This checks token reuse, caching, and permission updates.

## Decision

Use this wording until the proof test passes:

> The design is technically possible. A shared endpoint alone does not bridge two identity systems. We must configure an exact user mapping, preserve the user's identity to both data sources, and prove access isolation with two users before calling the design supported for production.

## Detailed references

- [Genie One MCP service](https://learn.microsoft.com/en-us/azure/databricks/agents/mcp-tools/genie-mcp)
- [Genie One external sources](https://learn.microsoft.com/en-us/azure/databricks/genie-one/external-sources)
- [Built-in MCP services](https://learn.microsoft.com/en-us/azure/databricks/agents/mcp-tools/built-in-mcp-services)
- [Per-user identity federation](byoidp-peruser-federation.md)
- [Microsoft Teams and Copilot Studio identity](teams-copilot-genie-obo.md)
- [Authentication patterns](authentication.md)
