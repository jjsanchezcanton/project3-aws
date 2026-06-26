# IAM — dev user policy (single source of truth)

`dev-user-policy.json` is the **canonical, complete** permissions policy for the
dev IAM user `jjs-project3-dev`. Whatever is attached to that user in the AWS
console should always equal this file. When permissions change, edit this file
and re-apply it as a whole — do not scatter "additions" across specs.

## Why this is not managed by Terraform

Terraform authenticates to AWS *as* `jjs-project3-dev`. Having the same Terraform
state manage that user's own policy is a bootstrap / circular dependency: the
identity provisioning the stack would also be mutating its own permissions. Long-
lived human-credential permissions are also better kept auditable and out of
state. So the dev user and this policy are created and maintained by hand;
Terraform manages only resource-side roles (e.g. the Lambda execution role).
See ADR-012.

## How to apply

Console: IAM → Policies → `project3-dev-policy` → Edit → JSON → paste the full
contents of `dev-user-policy.json` → Save (set as the new default version).

CLI (alternative):

```bash
aws iam create-policy-version \
  --policy-arn arn:aws:iam::722448938150:policy/project3-dev-policy \
  --policy-document file://iam/dev-user-policy.json \
  --set-as-default
```

## Scoping notes

- **S3** is scoped by ARN to the project bucket only (`jjs-project-3-de-portfolio-*`).
- **IAM** role/policy management and **Lambda** are scoped to the `jjs-project-3-*`
  name pattern; `iam:PassRole` is conditioned to `lambda.amazonaws.com`.
- **CloudWatch Logs** management is scoped to the project's Lambda log groups; read
  actions are account-wide (Describe requires `*`).
- **Glue / Athena / Budgets** are service-wide (`Resource: "*"`) because resource-
  level scoping for these is awkward — acceptable in a solo account, would be
  tightened with resource ARNs and conditions in a shared one.
- `s3:ListAllMyBuckets` is **intentionally excluded** — account-wide bucket listing
  is not needed; verify the project bucket with `aws s3api head-bucket` instead.

This file contains **no secrets**. The AWS account ID is not sensitive; it appears
in every ARN. It is safe to commit.
