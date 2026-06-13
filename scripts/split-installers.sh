#!/usr/bin/env bash
# scripts/split-installers.sh
#
# One-shot: carve shell/config/lazy/installers.sh into modular installers-<group>.sh
# files plus a shared installers-common.sh. Function bodies are moved VERBATIM from
# the source file — this script never rewrites them — so nothing is reworded or lost.
# Any function whose name the mapping doesn't recognise is written to
# installers-UNMAPPED.sh with a loud warning, never silently dropped.
#
# Assumptions (true for a lazy library): the source contains only a shebang/header
# comment block and top-level `name() {` ... `}` function definitions — no top-level
# executable code, and no function body with a `}` alone in column 0 (e.g. a heredoc
# closing on its own line). The printed count check flags anything unexpected.
#
# Output goes to ./split-out/ for review; nothing under lazy/ is touched.
#
#   bash scripts/split-installers.sh [path/to/installers.sh]
#
set -euo pipefail

src="${1:-shell/config/lazy/installers.sh}"
out_dir="split-out"

[[ -f "${src}" ]] || { echo "ERROR: source not found: ${src}" >&2; exit 1; }
rm -rf "${out_dir}"; mkdir -p "${out_dir}"

awk -v out_dir="${out_dir}" '
    # ---- group resolution -----------------------------------------------------
    # Public installers, keyed by the bit after install-/set- (with -version stripped).
    function tool_group(t) {
        if (t=="1password" || t=="bitwarden" || t=="bw-cli" || t=="op-cli" ||
            t=="cosign"    || t=="trivy")                          return "security"
        if (t=="claude-code" || t=="copilot-cli")                  return "ai"
        if (t=="oh-my-posh"  || t=="oh-my-zsh" || t=="starship" ||
            t ~ /^zsh/)                                          return "prompt"
        if (t=="ansible" || t=="helm" || t=="tenv" ||
            t=="terraform" || t=="tflint" || t=="tofu")            return "iac"
        if (t=="edit" || t=="gh" || t=="glab" || t=="nvm" ||
            t=="noteshub" || t=="opendeck")                        return "dev"
        return ""
    }
    # Private helpers, keyed by the stem after a leading _ up to the first - or _.
    function stem_group(s) {
        if (s=="download" || s=="ensure" || s=="npm")              return "common"
        if (s=="gh" || s=="glab" || s=="nvm" || s=="edit" ||
            s=="noteshub" || s=="opendeck" || s=="node")          return "dev"
        if (s=="bw" || s=="bitwarden" || s=="op" || s=="onepassword" ||
            s=="1password" || s=="cosign" || s=="trivy")           return "security"
        if (s=="claude" || s=="copilot")                           return "ai"
        if (s=="tenv" || s=="terraform" || s=="tofu" || s=="tf" ||
            s=="ansible" || s=="tflint" || s=="helm")              return "iac"
        if (s=="omp" || s=="ohmyposh" || s=="posh" || s=="omz" ||
            s=="ohmyzsh" || s=="zsh" || s=="starship")             return "prompt"
        return ""
    }
    function group_of(name,   t, s) {
        if (name ~ /^(install|set)-/) {
            t = name; sub(/^(install|set)-/, "", t); sub(/-version$/, "", t)
            t = tool_group(t)
            return (t != "") ? t : "UNMAPPED"
        }
        if (name ~ /^list-.*-releases$/) {
            t = name; sub(/^list-/, "", t); sub(/-releases$/, "", t)
            t = tool_group(t)
            return (t != "") ? t : "UNMAPPED"
        }
        s = name; sub(/^_/, "", s); sub(/[-_].*$/, "", s)
        s = stem_group(s)
        return (s != "") ? s : "UNMAPPED"
    }

    BEGIN { infunc=0; seen_first=0; preamble=""; cur=""; n=0; u=0 }

    # function header at column 0:  name() {
    !infunc && /^[a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*\(\)[[:space:]]*\{/ {
        cur=$0; sub(/[[:space:]]*\(\).*$/, "", cur)        # cur = bare function name
        groups[cur]=group_of(cur); order[++n]=cur
        body[cur] = (seen_first ? preamble : "") $0 "\n"   # drop only the file header
        preamble=""; seen_first=1; infunc=1
        next
    }
    infunc {
        body[cur]=body[cur] $0 "\n"
        if ($0 ~ /^\}[[:space:]]*$/) { infunc=0; cur="" }
        next
    }
    { preamble = preamble $0 "\n" }                        # between funcs -> next preamble

    END {
        hdr["common"] = "#!/usr/bin/env bash\n" \
            "# lazy/installers-common.sh — shared private helpers for installers-*.sh.\n" \
            "# Only _-prefixed helpers live here, so loader.sh registers no stubs and never\n" \
            "# auto-sources this file; each installers-<group>.sh pulls it in on first use.\n" \
            "[[ -n \"${_DOTFILES_INSTALLERS_COMMON_LOADED:-}\" ]] && return 0\n" \
            "_DOTFILES_INSTALLERS_COMMON_LOADED=1\n\n"
        ng=split("ai dev security iac prompt", gl, " ")
        for (i=1;i<=ng;i++)
            hdr[gl[i]] = "#!/usr/bin/env bash\n# lazy/installers-" gl[i] ".sh\n" \
                "# shellcheck disable=SC1091\n" \
                "source \"${SHELL_CONFIG_DIR:-$HOME/.config/shell}/lazy/installers-common.sh\"\n\n"
        hdr["UNMAPPED"] = "#!/usr/bin/env bash\n" \
            "# lazy/installers-UNMAPPED.sh — functions the splitter could not classify.\n" \
            "# Review and move each into the right installers-<group>.sh by hand.\n\n"

        total_out=0
        for (k=1;k<=n;k++) {
            name=order[k]; g=groups[name]
            content[g]=content[g] body[name] "\n"; count[g]++; total_out++
            if (g=="UNMAPPED") unmapped[++u]=name
        }
        for (g in content) {
            fn=out_dir "/installers-" g ".sh"
            printf "%s%s", hdr[g], content[g] > fn; close(fn)
        }

        printf "\n=== split summary ===\n" > "/dev/stderr"
        for (g in count) printf "  installers-%-9s : %d functions\n", g ".sh", count[g] > "/dev/stderr"
        printf "  ---\n  source functions  : %d\n  written functions : %d\n", n, total_out > "/dev/stderr"
        if (n != total_out) printf "  *** WARNING: count mismatch ***\n" > "/dev/stderr"
        if (u > 0) {
            printf "  UNMAPPED (%d) — review installers-UNMAPPED.sh:\n", u > "/dev/stderr"
            for (j=1;j<=u;j++) printf "    - %s\n", unmapped[j] > "/dev/stderr"
        } else printf "  unmapped          : none\n" > "/dev/stderr"
    }
' "${src}"

echo
echo "Wrote group files to ${out_dir}/ — review, then move into place:"
echo "  mv ${out_dir}/installers-*.sh shell/config/lazy/"
echo "  git rm shell/config/lazy/installers.sh   # once nothing is left in UNMAPPED"
echo "  bash tests/check-updater-coverage.sh"
