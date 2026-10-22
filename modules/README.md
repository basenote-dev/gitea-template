# Vendored modules

Upstream terraform-aws-modules, copied into the repo so every run uses code we reviewed and that can't
change under us: no registry or git fetch at plan time, and a moved upstream tag has no effect.
Roots call them by path, for example `source = "../../modules/terraform-aws-eks"`.

| Module | Upstream URL | Tag | Commit SHA |
| --- | --- | --- | --- |
| `terraform-aws-vpc` | https://github.com/terraform-aws-modules/terraform-aws-vpc | v6.7.3 | b3abd6df2ecf052451a361ed55b8f06f8742a795 |
| `terraform-aws-eks` | https://github.com/terraform-aws-modules/terraform-aws-eks | v21.29.0 | 91f11ea01656c26b8e6b8eb1b74f19863f60056c |
| `terraform-aws-s3-bucket` | https://github.com/terraform-aws-modules/terraform-aws-s3-bucket | v5.17.0 | 9afa4fc8c8f1e0b3fd913474c1bef8d0c454b235 |
| `terraform-aws-rds` | https://github.com/terraform-aws-modules/terraform-aws-rds | v7.2.2 | 175da043429cbbe41c512f976105719f6d0e538c |
| `terraform-aws-elasticache` | https://github.com/terraform-aws-modules/terraform-aws-elasticache | v1.11.2 | 41a277b73b9d375a2856886ab8469fd3f8b6d0ef |
| `terraform-aws-efs` | https://github.com/terraform-aws-modules/terraform-aws-efs | v2.2.1 | e0ec33d8436363960395b859aff0168ce25c27a4 |
| `terraform-aws-acm` | https://github.com/terraform-aws-modules/terraform-aws-acm | v6.3.1 | aae84c011dd68ace1beb5d10e1feddfe9a334953 |
| `terraform-aws-eks-pod-identity` | https://github.com/terraform-aws-modules/terraform-aws-eks-pod-identity | v2.10.0 | f72040b99272c264e0340f44758219e0808a52a2 |
| `terraform-aws-iam` | https://github.com/terraform-aws-modules/terraform-aws-iam | v6.8.2 | 55514b7873c411040395e024a422684998da77c2 |
| `terraform-aws-kms` | https://github.com/terraform-aws-modules/terraform-aws-kms | v4.2.2 | d25e459bd43d8d0bdff7c250ba6b237a12be7381 |
| `terraform-aws-ecr` | https://github.com/terraform-aws-modules/terraform-aws-ecr | v3.2.1 | f05e615fa452e813935986295e7770f8fa96948b |
| `terraform-aws-secrets-manager` | https://github.com/terraform-aws-modules/terraform-aws-secrets-manager | v2.2.0 | f3d3da1c801816563080065c5f37f212c8dee444 |
| `terraform-aws-route53` | https://github.com/terraform-aws-modules/terraform-aws-route53 | v6.5.1 | 883f987d6bb328c09bd4dfc5a04024534b371d59 |

`terraform-aws-iam` has no root module. Use its submodules, for example
`modules/terraform-aws-iam/modules/iam-role` and `modules/terraform-aws-iam/modules/iam-oidc-provider`.

## Local changes

- Removed the upstream novelty input that gates every resource behind a political slogan (variable name
  `pu` + `tin_khu` + `ylo`; spelled split here so the check below stays clean): the `variable` blocks, the
  `&& var.<name>` terms in the `create*` locals (vpc, eks, s3-bucket, rds, acm), and the README lines that
  mention it. The flag defaults to `true` and only gates resource creation, so behaviour is unchanged.
- Nested registry sources repointed to the vendored copy, so nothing is fetched from the registry:
  - `terraform-aws-eks/main.tf`, `module "kms"`: `terraform-aws-modules/kms/aws` 4.0.0 -> `../terraform-aws-kms` (v4.2.2).
  - `terraform-aws-route53/main.tf`, `module "route53_dnssec_kms"`: `terraform-aws-modules/kms/aws` 4.0.0 -> `../terraform-aws-kms` (v4.2.2).
  Same major version, `version` argument dropped (not allowed on local paths).
- Dropped from each module: `.git`, `.github`, `examples/`, `tests/`, `docs/`, `wrappers/`,
  `.pre-commit-config.yaml`, `.releaserc.json`, `.editorconfig`, `.gitignore`, `.gitattributes`, `CHANGELOG.md`,
  `UPGRADE-*.md`, `mkdocs.yml`.
- Kept as upstream: every `*.tf` file, `templates/`, `LICENSE`, `README.md`, and all submodules under `modules/`.

## Updating

Run from the repo root (bash). Example for one module:

```sh
n=eks; tag=v21.29.0
tmp=$(mktemp -d)
git clone --depth 1 -b "$tag" "https://github.com/terraform-aws-modules/terraform-aws-$n" "$tmp/m"
git -C "$tmp/m" rev-parse HEAD        # record this SHA in the table above

cd "$tmp/m"
shopt -s nullglob
flag=pu""tin_khu""ylo                 # split so the grep check below does not match this file
rm -rf .git .github examples tests docs wrappers .pre-commit-config.yaml .releaserc.json .editorconfig \
  .gitignore .gitattributes CHANGELOG.md UPGRADE-*.md mkdocs.yml
for f in $(grep -rl "variable \"$flag\"" --include='*.tf' .); do
  perl -0pi -e "s/\n?variable \"$flag\" \{.*?\n\}\n//s" "$f"
done
for f in $(grep -rl "$flag" --include='*.tf' .); do perl -pi -e "s/\s*&&\s*var\.$flag//g" "$f"; done
for f in $(grep -rli "pu""tin\|khu""ylo" --include='*.md' .); do
  perl -ni -e "print unless /pu""tin|khu""ylo/i" "$f"
done
# repoint nested registry modules to vendored copies (same major only; otherwise vendor that version)
grep -rnE 'source *= *"terraform-aws-modules/' --include='*.tf' .
cd -

rm -rf "modules/terraform-aws-$n" && cp -R "$tmp/m" "modules/terraform-aws-$n" && rm -rf "$tmp"
grep -rin "pu""tin\|khu""ylo" modules/          # must print nothing
grep -rnE 'source *= *"terraform-aws-modules/' --include='*.tf' modules/   # must print nothing
mise exec -- tofu fmt -check -recursive modules/
mise exec -- tofu -chdir="modules/terraform-aws-$n" init -backend=false -input=false
mise exec -- tofu -chdir="modules/terraform-aws-$n" validate
find modules -name .terraform -type d -prune -exec rm -rf {} +
find modules -name .terraform.lock.hcl -delete
```

Then update the tag and SHA in the table, read the upstream CHANGELOG for the range, and review the diff
like any other code change.
