# Example Corp IT Incident Response Procedure

Document owner: IT Operations. Version 2.0, effective 1 January 2026. Applies to incidents affecting Example Corp systems and the managed services delivered to clients.

## Definitions

An incident is an unplanned interruption or degradation of an IT service. A security incident is any event that threatens the confidentiality, integrity, or availability of information; security incidents follow this procedure with IT Security as the owning team.

## Severity levels and targets

| Severity | Description | Response target | Resolution target | Coverage |
|---|---|---|---|---|
| Sev 1 | Critical service down for all users or a client, data breach in progress | 15 minutes | 4 hours | 24x7 |
| Sev 2 | Major degradation, a critical function unavailable for a large group | 30 minutes | 8 hours | 24x7 |
| Sev 3 | Limited impact, workaround available | 4 business hours | 3 business days | Business hours |
| Sev 4 | Minor issue or cosmetic defect | 1 business day | 10 business days | Business hours |

Response time is measured from the moment the incident is logged to the first action by the assigned engineer.

## Reporting an incident

- Employees report incidents to the IT service desk at extension 4000, `servicedesk@example.corp`, or the portal at `it.example.corp`. Outside business hours Sev 1 and Sev 2 incidents are reported through the on-call number listed on the portal.
- Monitoring alerts create incidents automatically in the service management tool.
- Suspected security incidents, including phishing and lost devices, are reported immediately to IT Security at `security@example.corp` in addition to the service desk.

## Roles

- **Incident commander**: the on-call operations lead for Sev 1 and Sev 2 incidents; coordinates, decides on escalation, and owns communication.
- **Resolver teams**: the teams working on diagnosis and fix.
- **Communications lead**: keeps the status page and stakeholders updated. For client-affecting incidents the account manager informs the client.

## Communication

- Sev 1: status updates every **30 minutes** on the incident channel in Slack and on the status page until resolution.
- Sev 2: status updates every hour.
- Sev 3 and Sev 4: update when the status changes.
- Client-facing communication follows the wording agreed in the client's managed services agreement.

## Escalation

If a Sev 1 incident is not resolved within two hours, the incident commander escalates to the Head of IT Operations. After four hours the Chief Information Officer is informed and decides on invoking the business continuity plan.

## After the incident

- A post-incident review is held within **five business days** for every Sev 1 and Sev 2 incident. The review is blameless and produces a written report with a timeline, root cause, and follow-up actions with owners.
- Follow-up actions are tracked in the service management tool and reviewed monthly by IT Operations.
- Security incidents involving personal data are assessed for notification duties within 72 hours, as required by data protection law, in coordination with Legal.
