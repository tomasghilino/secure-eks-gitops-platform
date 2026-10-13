from checkov.common.models.enums import CheckCategories, CheckResult
from checkov.terraform.checks.data.base_check import BaseDataCheck


def flatten(value):
    if isinstance(value, list):
        return [item for element in value for item in flatten(element)]
    return [] if value is None else [value]


# checkov's own github rule (CKV_AWS_358) only recognises a literal provider arn, so a trust policy
# that references the provider resource passes even with sub = "*"
class WebIdentitySubject(BaseDataCheck):
    def __init__(self):
        super().__init__(
            name="Ensure web identity trust policies pin one exact subject",
            id="CKV_SEGP_1",
            categories=[CheckCategories.IAM],
            supported_data=["aws_iam_policy_document"],
        )

    def scan_data_conf(self, conf):
        statements = [
            s for s in conf.get("statement", [])
            if "sts:AssumeRoleWithWebIdentity" in flatten(s.get("actions"))
        ]
        if not statements:
            return CheckResult.UNKNOWN
        for statement in statements:
            subjects = [
                c for c in statement.get("condition", [])
                if any(str(v).endswith(":sub") for v in flatten(c.get("variable")))
            ]
            if not subjects:
                return CheckResult.FAILED
            for condition in subjects:
                values = flatten(condition.get("values"))
                if flatten(condition.get("test")) != ["StringEquals"] or not values:
                    return CheckResult.FAILED
                if any("*" in str(v) or "?" in str(v) for v in values):
                    return CheckResult.FAILED
        return CheckResult.PASSED


check = WebIdentitySubject()
