# Network Access Controls

> **Pillar 1** -- Can the request even reach the AI service?

The foundation. If the network doesn't allow it, nothing else matters. Every AI service on Databricks can be fully private -- zero public endpoints.

## Status

This pillar is primarily covered by cloud-specific deployment guides in [bhavink/databricks](https://github.com/bhavink/databricks):

| Cloud | Focus | Path |
|-------|-------|------|
| Azure | Private Link, NSGs, NPIP, Azure Firewall | [adb4u](https://github.com/bhavink/databricks/tree/master/adb4u) |
| AWS | Backend Private Link, VPC endpoints, Security Groups | [awsdb4u](https://github.com/bhavink/databricks/tree/master/awsdb4u) |
| GCP | Private Service Connect, VPC-SC, Firewall Rules | [gcpdb4u](https://github.com/bhavink/databricks/tree/master/gcpdb4u) |

## Key Controls

- **Private Link / PSC** -- No public internet path to workspace
- **IP Access Lists** -- Restrict API/UI to known CIDR ranges
- **Serverless NCC** -- Private connectivity from serverless compute to customer VNets
- **VPC-SC (GCP)** -- Data exfiltration prevention at the cloud perimeter
- **NSG / Firewall Rules** -- Restrict egress from compute to approved destinations
- **Apps Networking** -- Databricks Apps run in control plane with managed private endpoints

## Related Pillars

- [Identity](../identity/) -- Network is the perimeter; identity is the next gate
- [Governance Framework](../GOVERNANCE-FRAMEWORK.md) -- Network is Pillar 1 in the seven-pillar model
