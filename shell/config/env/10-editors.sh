#!/usr/bin/env bash
# Editor environment — sets EDITOR, VISUAL, and related vars.
# No subprocesses.

if [[ -n "${DISPLAY}" || -n "${WAYLAND_DISPLAY}" || "${DOTFILES_OS}" == "Mac" ]]; then
    # Prefer code/code-insiders when a display is available
    if [[ -x "$(command -v code-insiders 2>/dev/null)" ]]; then
        export VISUAL="code-insiders --wait"
    elif [[ -x "$(command -v code 2>/dev/null)" ]]; then
        export VISUAL="code --wait"
    else
        export VISUAL="${VISUAL:-vim}"
    fi
else
    export VISUAL="${VISUAL:-vim}"
fi

export EDITOR="${EDITOR:-vim}"

# Make less friendlier for non-text input files
export LESS="-R"
export PAGER="${PAGER:-less}"
