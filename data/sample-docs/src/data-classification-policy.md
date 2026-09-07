# Example Corp Data Classification and Handling Policy

Document owner: IT Security. Version 1.5, effective 1 March 2026. Applies to all information created, received, or processed by Example Corp and its contractors.

## Classification levels

| Level | Description | Examples |
|---|---|---|
| Public | Approved for release outside the company | Marketing material, published job adverts, press releases |
| Internal | For employees and contractors; low impact if disclosed | Internal announcements, most policies, project plans without client data |
| Confidential | Would cause harm to Example Corp, a client, or an individual if disclosed | Client contracts, financial results before publication, employee records, source code |
| Restricted | Would cause severe harm; access limited to named individuals | Credentials and keys, security incident reports, merger and acquisition material, health data |

When in doubt, classify one level higher and ask the information owner.

## Labelling

Confidential and Restricted documents carry the level in the header or footer. Emails containing Confidential or Restricted content carry the level in the subject line in square brackets, for example `[Confidential]`.

## Handling rules

| Activity | Internal | Confidential | Restricted |
|---|---|---|---|
| Storage | Company systems | Company systems, encrypted at rest | Approved systems only, encrypted, access logged |
| Sharing outside the company | Not allowed | Only under a signed agreement, encrypted in transit | Only with written approval of the information owner and IT Security |
| Printing | Allowed in the office | Office only, collect immediately, shred after use | Not allowed |
| Personal devices and accounts | Not allowed | Not allowed | Not allowed |
| Public generative AI tools | Not allowed | Not allowed | Not allowed |

Approved storage locations are the corporate document management system, the corporate cloud drive, and the source code repositories. Removable media is not permitted for Confidential or Restricted data.

## Retention and disposal

- Financial and tax records are retained for **seven years**. Contracts are retained for seven years after they end. Recruitment records of unsuccessful candidates are deleted after four weeks unless the candidate agrees to a longer period.
- Records that reach the end of their retention period are deleted securely. Paper is shredded; devices are wiped before reuse or disposal.

## Personal data

Personal data is at least Confidential. Processing must have a lawful basis and be recorded in the processing register kept by Legal. Data subject requests are handled within one month.

## Reporting

Suspected disclosure of Confidential or Restricted information is a security incident and must be reported immediately to `security@example.corp`, following the IT Incident Response Procedure.
