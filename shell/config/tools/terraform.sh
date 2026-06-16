#!/usr/bin/env bash
# Terraform / OpenTofu / Terragrunt tool configuration.
# Sourced when terraform or tofu is present (guarded in loader.sh).

# ── aliases ───────────────────────────────────────────────────────────────────
if command -v tofu &>/dev/null; then
    # OpenTofu (preferred when both installed)
    alias tf="tofu"
    alias tfi="tofu init"
    alias tfp="tofu plan"
    alias tfpd="tofu plan -destroy"
    alias tfa="tofu apply"
    alias tfaa="tofu apply -auto-approve"
    alias tfd="tofu destroy"
    alias tfr="tofu refresh"
    alias tfsh="tofu show"
    alias tfsl="tofu state list"
    alias tfo="tofu output"
    alias tfv="tofu version"
    alias tffmt="tofu fmt"
    alias tfva="tofu validate"
    alias tfws="tofu workspace"

    alias otf="tofu"
    alias otfi="tofu init"
    alias otfp="tofu plan"
    alias otfpd="tofu plan -destroy"
    alias otfa="tofu apply"
    alias otfaa="tofu apply -auto-approve"
    alias otfd="tofu destroy"
    alias otfr="tofu refresh"
    alias otfsh="tofu show"
    alias otfsl="tofu state list"
    alias otfo="tofu output"
    alias otfv="tofu version"
    alias otffmt="tofu fmt"
    alias otfva="tofu validate"
    alias otfws="tofu workspace"
fi

if command -v terraform &>/dev/null; then
    # tf* only when OpenTofu is absent
    if ! command -v tofu &>/dev/null; then
        alias tf="terraform"
        alias tfi="terraform init"
        alias tfp="terraform plan"
        alias tfpd="terraform plan -destroy"
        alias tfa="terraform apply"
        alias tfaa="terraform apply -auto-approve"
        alias tfd="terraform destroy"
        alias tfr="terraform refresh"
        alias tfsh="terraform show"
        alias tfsl="terraform state list"
        alias tfo="terraform output"
        alias tfv="terraform version"
        alias tffmt="terraform fmt"
        alias tfva="terraform validate"
        alias tfws="terraform workspace"
    fi

    alias hctf="terraform"
    alias hctfi="terraform init"
    alias hctfp="terraform plan"
    alias hctfpd="terraform plan -destroy"
    alias hctfa="terraform apply"
    alias hctfaa="terraform apply -auto-approve"
    alias hctfd="terraform destroy"
    alias hctfr="terraform refresh"
    alias hctfsh="terraform show"
    alias hctfsl="terraform state list"
    alias hctfo="terraform output"
    alias hctfv="terraform version"
    alias hctffmt="terraform fmt"
    alias hctfva="terraform validate"
    alias hctfws="terraform workspace"
fi

if command -v terragrunt &>/dev/null; then
    alias tg="terragrunt"
    alias tgi="terragrunt init"
    alias tgp="terragrunt plan"
    alias tgpd="terragrunt plan -destroy"
    alias tga="terragrunt apply"
    alias tgaa="terragrunt apply -auto-approve"
    alias tgd="terragrunt destroy"
    alias tgr="terragrunt refresh"
    alias tgo="terragrunt output"
    alias tgv="terragrunt version"
    alias tgfmt="terragrunt fmt"
    alias tgva="terragrunt validate"
    alias tgws="terragrunt workspace"
fi

# ── environment variables ─────────────────────────────────────────────────────


# ── functions ─────────────────────────────────────────────────────────────────
get-latest-terraform-version() {
    curl -s https://checkpoint-api.hashicorp.com/v1/check/terraform \
        | tr -d '\r' \
        | grep -Eo '"current_version":"[0-9]+\.[0-9]+\.[0-9]+"' \
        | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+'
}

get-latest-opentofu-version() {
    curl -s https://api.github.com/repos/opentofu/opentofu/releases/latest \
        | tr -d '\r' \
        | grep -Eo '"tag_name": ?"v[0-9]+\.[0-9]+\.[0-9]+"' \
        | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+'
}
