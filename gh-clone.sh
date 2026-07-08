#!/usr/bin/env bash
set -u
set -o pipefail

DEFAULT_BASE_DIR="/var/www"
BASE_DIR="$DEFAULT_BASE_DIR"
OWNER=""
USE_HTTPS=false
INCLUDE_ARCHIVED=false
DRY_RUN=false
LIST_OWNERS=false
ALL_REPOS=false
DIR_SET=false
REPO_LIMIT=1000

REPOS=()

usage() {
    cat <<'USAGE'
Usage:
  ./gh-clone.sh
  ./gh-clone.sh [options] <dir>
  ./gh-clone.sh [options] <owner/repo> [owner/repo...]
  ./gh-clone.sh [options] <dir> <owner/repo> [owner/repo...]
  ./gh-clone.sh [options] --owner <owner>
  ./gh-clone.sh [options] <dir> --owner <owner>
  ./gh-clone.sh [options] --all
  ./gh-clone.sh [options] <dir> --all
  ./gh-clone.sh [options] --owner <owner> --all
  ./gh-clone.sh [options] <dir> --owner <owner> --all
  ./gh-clone.sh [options] --list-owners

Description:
  Clone GitHub repositories from your personal account or organizations.

  If no repository arguments are provided, the script starts an interactive
  multi-select picker.

  Without --owner:
    The picker shows repositories from your GitHub user and all organizations
    returned by GitHub CLI.

  With --owner:
    The picker only shows repositories from that owner.

Arguments:
  dir
      Optional base directory where repositories are cloned.

      Default:
        /var/www

      Repositories are cloned to:
        <dir>/<owner>/<repo>

      The directory argument is detected automatically when a positional argument
      does not match the owner/repo format.

  owner/repo
      One or more repositories to clone directly.

Options:
  -o, --owner <owner>
      Select the GitHub owner/organization.

      In interactive mode:
        Browse repositories from this owner only.

      With --all:
        Clone all repositories from this owner.

  --all
      Clone all repositories without opening the interactive picker.

      With --owner:
        Clone all repositories for that owner.

      Without --owner:
        Clone all repositories from your GitHub user and all organizations
        returned by GitHub CLI.

  --https
      Clone using HTTPS instead of SSH.

      Default clone URL:
        git@github.com:owner/repo.git

  --list-owners
      List your GitHub username and organizations available through GitHub CLI.

  --archived
      Include archived repositories.

      By default, archived repositories are hidden.

  --dry-run
      Print the commands that would be executed without cloning anything.

  -h, --help
      Show this help message.

Examples:
  ./gh-clone.sh
      Show repositories from all owners in one picker and clone selected repos to
      /var/www/<owner>/<repo>.

  ./gh-clone.sh ~/code
      Show repositories from all owners in one picker and clone selected repos to
      ~/code/<owner>/<repo>.

  ./gh-clone.sh --owner diakrit
      Browse repositories under diakrit only and clone selected repos to
      /var/www/diakrit/<repo>.

  ./gh-clone.sh ~/code --owner diakrit
      Browse repositories under diakrit only and clone selected repos to
      ~/code/diakrit/<repo>.

  ./gh-clone.sh diakrit/api
      Clone diakrit/api to /var/www/diakrit/api.

  ./gh-clone.sh ~/code diakrit/api
      Clone diakrit/api to ~/code/diakrit/api.

  ./gh-clone.sh diakrit/api virtuance/frontend
      Clone multiple repositories directly.

  ./gh-clone.sh ~/code diakrit/api virtuance/frontend
      Clone multiple repositories to ~/code/<owner>/<repo>.

  ./gh-clone.sh --all
      Clone all repositories from your GitHub user and all organizations to
      /var/www/<owner>/<repo>.

  ./gh-clone.sh ~/code --all
      Clone all repositories from your GitHub user and all organizations to
      ~/code/<owner>/<repo>.

  ./gh-clone.sh --owner diakrit --all
      Clone all repositories from diakrit to /var/www/diakrit/<repo>.

  ./gh-clone.sh ~/code --owner diakrit --all
      Clone all repositories from diakrit to ~/code/diakrit/<repo>.

  ./gh-clone.sh --dry-run ~/code --all
      Print the commands that would be executed for all repositories.

  ./gh-clone.sh --https diakrit/api
      Clone using HTTPS instead of SSH.

Interactive controls:
  Type       Filter repositories
  ↑/↓        Move
  Space      Select/deselect repository
  Enter      Clone selected repositories
  Ctrl+A     Select all
  Ctrl+D     Deselect all
  Ctrl+T     Toggle all
  Esc        Cancel
USAGE
}

error() {
    echo "Error: $*" >&2
}

is_ubuntu() {
    [[ -r /etc/os-release ]] || return 1

    # shellcheck disable=SC1091
    . /etc/os-release

    [[ "${ID:-}" == "ubuntu" ]]
}

is_interactive_terminal() {
    [[ -t 0 && -t 1 ]]
}

is_stderr_terminal() {
    [[ -t 2 ]]
}

ask_yes_no() {
    local prompt="$1"
    local answer

    read -r -p "$prompt [y/N] " answer

    case "$answer" in
        y|Y|yes|YES|Yes)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

install_git_ubuntu() {
    sudo apt update
    sudo apt install -y git
}

install_fzf_ubuntu() {
    sudo apt update
    sudo apt install -y fzf
}

install_gh_ubuntu() {
    (type -p wget >/dev/null || (sudo apt update && sudo apt install wget -y)) \
        && sudo mkdir -p -m 755 /etc/apt/keyrings \
        && out="$(mktemp)" \
        && wget -nv -O "$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        && cat "$out" | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
        && rm -f "$out" \
        && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
        && sudo mkdir -p -m 755 /etc/apt/sources.list.d \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null \
        && sudo apt update \
        && sudo apt install -y gh
}

install_missing_command_ubuntu() {
    local command_name="$1"

    case "$command_name" in
        git)
            install_git_ubuntu
            ;;
        fzf)
            install_fzf_ubuntu
            ;;
        gh)
            install_gh_ubuntu
            ;;
        *)
            return 1
            ;;
    esac
}

print_missing_command_message() {
    local command_name="$1"

    echo >&2
    error "Missing required command: $command_name"

    if ! is_ubuntu; then
        echo >&2
        echo "Automatic install is only supported on Ubuntu by this script." >&2
        echo "Please install '$command_name' manually and run the script again." >&2
        return
    fi

    echo >&2
    echo "Please install '$command_name' and run the script again." >&2

    if [[ "$command_name" == "gh" ]]; then
        echo >&2
        echo "After installing GitHub CLI, authenticate with:" >&2
        echo "  gh auth login" >&2
    fi
}

require_command() {
    local command_name="$1"

    if command -v "$command_name" >/dev/null 2>&1; then
        return 0
    fi

    if is_ubuntu && is_interactive_terminal; then
        echo >&2
        error "Missing required command: $command_name"

        if ask_yes_no "Do you want to install '$command_name' now?"; then
            if ! install_missing_command_ubuntu "$command_name"; then
                echo >&2
                error "Failed to install: $command_name"
                exit 1
            fi

            if command -v "$command_name" >/dev/null 2>&1; then
                echo "Installed: $command_name"

                if [[ "$command_name" == "gh" ]]; then
                    echo
                    echo "GitHub CLI is installed. You may still need to authenticate:"
                    echo "  gh auth login"
                fi

                return 0
            fi

            echo >&2
            error "Installation completed, but '$command_name' was still not found in PATH."
            exit 1
        fi
    fi

    print_missing_command_message "$command_name"
    exit 1
}

require_gh_auth() {
    if gh auth status >/dev/null 2>&1; then
        return 0
    fi

    echo >&2
    error "GitHub CLI is installed, but you are not authenticated."

    if is_interactive_terminal && ask_yes_no "Do you want to run 'gh auth login' now?"; then
        gh auth login

        if gh auth status >/dev/null 2>&1; then
            return 0
        fi
    fi

    echo >&2
    echo "Please authenticate with:" >&2
    echo "  gh auth login" >&2
    exit 1
}

expand_path() {
    local path="$1"

    case "$path" in
        "~")
            printf '%s\n' "$HOME"
            ;;
        "~/"*)
            printf '%s/%s\n' "$HOME" "${path#~/}"
            ;;
        *)
            printf '%s\n' "$path"
            ;;
    esac
}

is_repo_arg() {
    local value="$1"

    # GitHub owner names are intentionally stricter than a generic path.
    # This keeps values like ~/code, ./code, /var/www, and foo/bar/baz as paths.
    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]+(\.git)?$ ]]
}

normalize_repo_arg() {
    local value="$1"
    value="${value%.git}"
    printf '%s\n' "$value"
}

add_positional_arg() {
    local value="$1"

    if is_repo_arg "$value"; then
        REPOS+=("$(normalize_repo_arg "$value")")
        return
    fi

    if [[ "$DIR_SET" == true ]]; then
        error "More than one directory argument was provided."
        error "Ambiguous argument: $value"
        exit 1
    fi

    BASE_DIR="$(expand_path "$value")"
    DIR_SET=true
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -o|--owner)
                if [[ $# -lt 2 || -z "${2:-}" ]]; then
                    error "Missing value for $1"
                    exit 1
                fi
                OWNER="$2"
                shift 2
                ;;
            --owner=*)
                OWNER="${1#--owner=}"
                if [[ -z "$OWNER" ]]; then
                    error "Missing value for --owner"
                    exit 1
                fi
                shift
                ;;
            --all)
                ALL_REPOS=true
                shift
                ;;
            --https)
                USE_HTTPS=true
                shift
                ;;
            --list-owners)
                LIST_OWNERS=true
                shift
                ;;
            --archived)
                INCLUDE_ARCHIVED=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    add_positional_arg "$1"
                    shift
                done
                ;;
            -*)
                error "Unknown option: $1"
                echo >&2
                usage >&2
                exit 1
                ;;
            *)
                add_positional_arg "$1"
                shift
                ;;
        esac
    done
}

list_owners() {
    {
        gh api user --jq '.login'
        gh api user/orgs --paginate --jq '.[].login'
    } | awk 'NF' | sort -u
}

list_repositories_for_owner() {
    local owner="$1"

    # Forks are included by default because we do not pass --source.
    #
    # When --archived is enabled, we combine normal repos and archived repos
    # because gh's --archived flag means "show only archived repositories".
    if [[ "$INCLUDE_ARCHIVED" == true ]]; then
        {
            gh repo list "$owner" \
                --limit "$REPO_LIMIT" \
                --no-archived \
                --json name \
                --jq '.[].name'

            gh repo list "$owner" \
                --limit "$REPO_LIMIT" \
                --archived \
                --json name \
                --jq '.[].name' 2>/dev/null || true
        } | awk 'NF' | sort -u
    else
        gh repo list "$owner" \
            --limit "$REPO_LIMIT" \
            --no-archived \
            --json name \
            --jq '.[].name' |
            awk 'NF' |
            sort -u
    fi
}

list_full_repositories_for_owner() {
    local owner="$1"

    list_repositories_for_owner "$owner" |
        awk -v owner="$owner" 'NF { print owner "/" $0 }'
}

list_full_repositories_for_all_owners() {
    local owner

    while IFS= read -r owner; do
        [[ -n "$owner" ]] || continue

        if is_stderr_terminal; then
            printf "\r\033[KLoading repos from owner '%s'..." "$owner" >&2
        else
            echo "Loading repos from owner '$owner'..." >&2
        fi

        list_full_repositories_for_owner "$owner"
    done < <(list_owners)

    if is_stderr_terminal; then
        printf '\r\033[K' >&2
    fi
}

select_repositories_interactively_for_owner() {
    local owner="$1"
    local repositories
    local selected

    if is_stderr_terminal; then
        printf "\r\033[KLoading repos from owner '%s'..." "$owner" >&2
    else
        echo "Loading repos from owner '$owner'..." >&2
    fi

    repositories="$(list_repositories_for_owner "$owner")"

    if is_stderr_terminal; then
        printf '\r\033[K' >&2
    fi

    if [[ -z "$repositories" ]]; then
        return 1
    fi

    selected="$(printf '%s\n' "$repositories" | fzf \
        --multi \
        --height='80%' \
        --layout=reverse \
        --border \
        --prompt='Repositories > ' \
        --pointer='▶ ' \
        --marker='✓ ' \
        --bind='space:toggle,tab:toggle,ctrl-a:select-all,ctrl-d:deselect-all,ctrl-t:toggle-all' \
        --header='SPACE = Select  ENTER = Clone  Ctrl+A = All  Ctrl+D = None  Ctrl+T = Toggle  ESC = Cancel' \
        --preview="gh repo view '$owner'/{} 2>/dev/null || true" \
        --preview-window='right:60%:wrap')" || return 1

    [[ -n "$selected" ]] || return 1

    printf '%s\n' "$selected" |
        awk -v owner="$owner" 'NF { print owner "/" $0 }'
}

select_repositories_interactively_all_owners() {
    local repositories
    local selected

    repositories="$(list_full_repositories_for_all_owners)"

    if [[ -z "$repositories" ]]; then
        return 1
    fi

    selected="$(printf '%s\n' "$repositories" | fzf \
        --multi \
        --height='80%' \
        --layout=reverse \
        --border \
        --prompt='Repositories > ' \
        --pointer='▶ ' \
        --marker='✓ ' \
        --bind='space:toggle,tab:toggle,ctrl-a:select-all,ctrl-d:deselect-all,ctrl-t:toggle-all' \
        --header='SPACE = Select  ENTER = Clone  Ctrl+A = All  Ctrl+D = None  Ctrl+T = Toggle  ESC = Cancel' \
        --preview='gh repo view {} 2>/dev/null || true' \
        --preview-window='right:60%:wrap')" || return 1

    [[ -n "$selected" ]] || return 1
    printf '%s\n' "$selected"
}

clone_url_for_repo() {
    local owner="$1"
    local repo="$2"

    if [[ "$USE_HTTPS" == true ]]; then
        printf 'https://github.com/%s/%s.git\n' "$owner" "$repo"
    else
        printf 'git@github.com:%s/%s.git\n' "$owner" "$repo"
    fi
}

clone_repository() {
    local full_repo="$1"
    local owner="${full_repo%%/*}"
    local repo="${full_repo#*/}"
    local owner_dir="$BASE_DIR/$owner"
    local target_dir="$owner_dir/$repo"
    local clone_url

    clone_url="$(clone_url_for_repo "$owner" "$repo")"

    if [[ -d "$target_dir/.git" ]]; then
        echo "Already cloned, skipping: $full_repo -> $target_dir"
        return 0
    fi

    if [[ -e "$target_dir" ]]; then
        error "Target exists but is not a Git repository: $target_dir"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        printf 'mkdir -p %q\n' "$owner_dir"
        printf 'git clone %q %q\n' "$clone_url" "$target_dir"
        return 0
    fi

    if ! mkdir -p "$owner_dir"; then
        error "Could not create directory: $owner_dir"
        return 1
    fi

    echo "Cloning $full_repo -> $target_dir"

    if ! git clone "$clone_url" "$target_dir"; then
        error "Failed to clone: $full_repo"
        return 1
    fi
}

clone_repositories() {
    local failures=0
    local repo

    for repo in "$@"; do
        if ! clone_repository "$repo"; then
            failures=$((failures + 1))
        fi
    done

    if [[ "$failures" -gt 0 ]]; then
        error "$failures clone operation(s) failed."
        return 1
    fi
}

main() {
    parse_args "$@"

    if [[ "$LIST_OWNERS" == true ]]; then
        require_command gh
        require_gh_auth
        list_owners
        exit 0
    fi

    if [[ "${#REPOS[@]}" -gt 0 && -n "$OWNER" ]]; then
        error "--owner is only used for interactive mode or --all mode and cannot be combined with direct owner/repo arguments."
        exit 1
    fi

    if [[ "${#REPOS[@]}" -gt 0 && "$ALL_REPOS" == true ]]; then
        error "--all cannot be combined with direct owner/repo arguments."
        exit 1
    fi

    if [[ "$ALL_REPOS" == true ]]; then
        require_command gh
        require_gh_auth

        if [[ "$DRY_RUN" != true ]]; then
            require_command git
        fi

        if [[ -n "$OWNER" ]]; then
            mapfile -t REPOS < <(list_full_repositories_for_owner "$OWNER")
        else
            mapfile -t REPOS < <(list_full_repositories_for_all_owners)
        fi

        if [[ "${#REPOS[@]}" -eq 0 ]]; then
            echo "No repositories found."
            exit 0
        fi

        clone_repositories "${REPOS[@]}"
        exit $?
    fi

    if [[ "${#REPOS[@]}" -gt 0 ]]; then
        if [[ "$DRY_RUN" != true ]]; then
            require_command git
        fi

        clone_repositories "${REPOS[@]}"
        exit $?
    fi

    require_command gh
    require_command fzf

    if [[ "$DRY_RUN" != true ]]; then
        require_command git
    fi

    require_gh_auth

    if [[ -n "$OWNER" ]]; then
        mapfile -t REPOS < <(select_repositories_interactively_for_owner "$OWNER")
    else
        mapfile -t REPOS < <(select_repositories_interactively_all_owners)
    fi

    if [[ "${#REPOS[@]}" -eq 0 ]]; then
        echo "No repositories selected."
        exit 0
    fi

    clone_repositories "${REPOS[@]}"
}

main "$@"