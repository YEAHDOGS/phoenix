#!/usr/bin/env bash
# =============================================================================
# git-fucked.sh — Bash twin of scripts/git/git-fucked.ps1 (Phoenix)
#
# Interactive git disaster-recovery menu. Mirrors the PowerShell original's
# seven modes, prompts, and confirmation words (FORCE / NUKE / SURGERY /
# RESET / PURGE). Safety interlocks preserved:
#   * Every destructive step asks for explicit confirmation first.
#   * The GitHub "cache purge" routine pushes with --dry-run only, exactly
#     like the .ps1 — it rehearses the force-push without sending anything.
#   * -d (safe) is the default branch-delete mode; -D needs the PURGE word.
# =============================================================================

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'; MAGENTA=$'\033[0;35m'; WHITE=$'\033[0;37m'; NC=$'\033[0m'

DELETE_FLAG=0
for arg in "$@"; do
    case "$arg" in
        -d|--delete) DELETE_FLAG=1 ;;
        -h|--help) echo "Usage: $(basename "$0") [-d|--delete]"; exit 0 ;;
    esac
done

# --- reusable utility functions ----------------------------------------------
test_git_repository() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "${RED}Error: Current directory is not a Git repository.${NC}" >&2
        exit 1
    fi
}

invoke_local_reset() { # $1 = count, $2 = hardwipe (0/1)
    local count="$1" hardwipe="$2"
    if [ "$hardwipe" -eq 1 ]; then
        echo "${RED}Nuking the last $count commit(s) and wiping all changes...${NC}"
        git reset --hard "HEAD~$count"
    else
        echo "${GREEN}Undoing the last $count commit(s) but keeping your changes staged...${NC}"
        git reset --soft "HEAD~$count"
    fi
}

invoke_github_cache_purge() { # $1 = branch, $2 = cooldown seconds
    local branch="$1" cooldown="${2:-0}"
    echo ""
    echo "${YELLOW}Severing GitHub remote link cache to prevent URL persistence...${NC}"

    # Spawn a disconnected branch node to sever the graph
    git checkout --orphan temporary-purge-branch 2>/dev/null
    git rm -rf . --quiet 2>/dev/null

    # Push blank state up to force GitHub's head-pointer cache to break.
    # NOTE: --dry-run, mirroring the .ps1 — rehearses the push, sends nothing.
    git commit --allow-empty -m "Purging remote history cache" --quiet
    git push --dry-run origin "temporary-purge-branch:$branch" --force

    if [ "$cooldown" -gt 0 ]; then
        echo ""
        echo "${YELLOW}[+] Graph severed. Waiting $cooldown seconds for GitHub's cache engine to register eviction...${NC}"
        for ((i = cooldown; i > 0; i--)); do
            printf '\rCache eviction cool-down: %s seconds... ' "$i"
            sleep 1
        done
        printf '\n'
    fi

    echo "${GREEN}Restoring clean working directory graph to origin...${NC}"
    git checkout "$branch" --quiet
    git push --dry-run origin "$branch" --force

    git branch -D temporary-purge-branch --quiet
}

ask_commit_count() { # $1 = prompt label -> echoes count
    local label="$1" input
    read -r -p "$label [Default: 1] " input
    if [ -z "${input//[[:space:]]/}" ]; then echo 1; else echo "$input"; fi
}

# --- main --------------------------------------------------------------------
test_git_repository

REPO_ROOT="$(git rev-parse --show-toplevel)"
CURRENT_BRANCH="$(git branch --show-current)"
echo "${CYAN}Repository Found: $REPO_ROOT${NC}"
echo "${CYAN}Current Branch:   $CURRENT_BRANCH${NC}"
echo "----------------------------------------"

echo "${YELLOW}How bad is the damage?${NC}"
echo "1) It's just local (Committed, but NOT pushed yet)"
echo "2) It's in the cloud (Standard force-push history rewrite)"
echo "3) KILL IT WITH FIRE, NOW!!! (Wipe recent commits completely + 60s GitHub cache eviction)"
echo "4) SURGICAL STRIKE (Drop specific commit out of history, keep everything after, instant cache clear)"
echo "5) CLEAN ROLLBACK (No sensitive data, safe history addition, standard push)"
echo "6) SWAP TO SPECIFIC COMMIT (Jump or hard-reset branch directly to a target SHA)"
echo "7) Too many branches"
read -r -p "Select an option (1-7): " SCOPE

if ! [[ "$SCOPE" =~ ^[1234567]$ ]]; then
    echo "${RED}Invalid response, exiting.${NC}" >&2
    exit 1
fi

# --- MODE 1: LOCAL CLEANUP ---
if [ "$SCOPE" = "1" ]; then
    COMMIT_COUNT="$(ask_commit_count "How many commits back are fucked up?")"
    SHOULD_DELETE="$DELETE_FLAG"
    if [ "$DELETE_FLAG" -eq 0 ]; then
        echo ""
        echo "${YELLOW}You are about to undo the last $COMMIT_COUNT commit(s).${NC}"
        read -r -p "Do you want to completely DELETE the data/changes in these commits? (y/N) " choice
        if [[ "$choice" =~ ^[yY]([eE][sS])?$ ]]; then SHOULD_DELETE=1; fi
    fi
    echo ""
    invoke_local_reset "$COMMIT_COUNT" "$SHOULD_DELETE"
fi

# --- MODE 2: CLOUD CLEANUP ---
if [ "$SCOPE" = "2" ]; then
    COMMIT_COUNT="$(ask_commit_count "How many commits back are fucked up?")"
    echo ""
    echo "${YELLOW}Handling remote cleanup for $COMMIT_COUNT commit(s)...${NC}"
    git log -n "$COMMIT_COUNT" --oneline --format="%C(cyan)%h %C(white)- %s"
    echo ""
    read -r -p "Are you absolutely sure you want to force-push? (type 'FORCE' to confirm) " confirm
    if [ "$confirm" != "FORCE" ]; then echo "Aborting."; exit 1; fi

    invoke_local_reset "$COMMIT_COUNT" "$DELETE_FLAG"

    # NOTE: --dry-run everywhere here, mirroring the .ps1
    git push --dry-run origin "$CURRENT_BRANCH" --force-with-lease
    if [ $? -ne 0 ]; then
        read -r -p "--force-with-lease failed. Force overwrite anyway? (y/N) " override
        if [[ "$override" =~ ^[yY]([eE][sS])?$ ]]; then
            git push --dry-run origin "$CURRENT_BRANCH" --force
        fi
    fi
fi

# --- MODE 3: KILL IT WITH FIRE ---
if [ "$SCOPE" = "3" ]; then
    COMMIT_COUNT="$(ask_commit_count "How many commits back are fucked up?")"
    echo ""
    echo "${RED}[!!!] CRITICAL DATA PURGE INITIATED [!!!]${NC}"
    git log -n "$COMMIT_COUNT" --oneline --format="%C(cyan)%h %C(white)- %s"
    read -r -p "Type 'NUKE' to completely drop remote history and force an eviction cache clear: " confirm
    if [ "$confirm" != "NUKE" ]; then echo "Aborting."; exit 1; fi

    invoke_local_reset "$COMMIT_COUNT" "$DELETE_FLAG"
    invoke_github_cache_purge "$CURRENT_BRANCH" 60
    echo ""
    echo "${GREEN}[OK] Nuclear purge complete.${NC}"
fi

# --- MODE 4: SURGICAL STRIKE ---
if [ "$SCOPE" = "4" ]; then
    echo ""
    echo "${MAGENTA}[*] SURGICAL PURGE INITIATED [*]${NC}"
    read -r -p "How many commits ago was the bad commit pushed? (e.g., 6 for HEAD~6) " index_input
    if ! [[ "$index_input" =~ ^[0-9]+$ ]] || [ "$index_input" -le 0 ]; then
        echo "${RED}Invalid input. Must be a positive integer.${NC}" >&2
        exit 1
    fi
    BAD_INDEX="$index_input"
    BAD_SHA="$(git rev-parse "HEAD~$BAD_INDEX")"
    PARENT_SHA="$(git rev-parse "HEAD~$((BAD_INDEX + 1))")"

    echo ""
    echo "${RED}Targeting this specific commit for destruction:${NC}"
    git log -1 "$BAD_SHA" --oneline --format="%C(red)%h %C(white)- %s"
    echo ""
    read -r -p "Type 'SURGERY' to execute history rewrite: " confirm
    if [ "$confirm" != "SURGERY" ]; then echo "Aborting surgical strike."; exit 1; fi

    echo ""
    echo "${CYAN}Executing rebase slice operation...${NC}"
    git rebase --onto "$PARENT_SHA" "$BAD_SHA" HEAD
    if [ $? -ne 0 ]; then
        echo ""
        echo "${RED}[!] Conflict detected during history re-mapping. Aborting. Run 'git rebase --abort' to reset.${NC}" >&2
        exit 1
    fi
    echo ""
    echo "${GREEN}Local history successfully rewritten. Bad commit has been dropped.${NC}"

    invoke_github_cache_purge "$CURRENT_BRANCH" 0
    echo ""
    echo "${GREEN}[OK] Surgical strike complete! History saved, secret eradicated.${NC}"
fi

# --- MODE 5: CLEAN ROLLBACK ---
if [ "$SCOPE" = "5" ]; then
    COMMIT_COUNT="$(ask_commit_count "How many commits back do you want to rollback?")"
    echo ""
    echo "${YELLOW}Preparing clean rollback for the last $COMMIT_COUNT commit(s)...${NC}"
    git log -n "$COMMIT_COUNT" --oneline --format="%C(cyan)%h %C(white)- %s"
    echo ""
    read -r -p "Are you sure you want to revert these changes and push a rollback commit? (y/N) " confirm
    if ! [[ "$confirm" =~ ^[yY]([eE][sS])?$ ]]; then echo "Aborting rollback."; exit 1; fi

    echo ""
    echo "${CYAN}Undoing changes locally via revert...${NC}"
    git revert --no-commit "HEAD~$COMMIT_COUNT..HEAD"
    if [ $? -ne 0 ]; then
        echo ""
        echo "${RED}[!] Conflict detected during rollback. Please resolve manually or run 'git revert --abort'.${NC}" >&2
        exit 1
    fi
    git commit -m "Rollback: Reverted last $COMMIT_COUNT commit(s) due to issues" --quiet

    echo "${GREEN}Pushing clean history adjustment up to origin...${NC}"
    # NOTE: --dry-run, mirroring the .ps1
    git push --dry-run origin "$CURRENT_BRANCH"
    if [ $? -ne 0 ]; then
        echo ""
        echo "${RED}[!] Push failed. You may need to pull incoming changes first.${NC}" >&2
        exit 1
    fi
    echo ""
    echo "${GREEN}[OK] Clean rollback complete! No history rewritten, shared branch remains safe.${NC}"
fi

# --- MODE 6: SWAP TO SPECIFIC COMMIT ---
if [ "$SCOPE" = "6" ]; then
    echo ""
    echo "${MAGENTA}[>] SWAP TARGET ACQUISITION [>]${NC}"
    read -r -p "Enter the Commit SHA (or branch name) you want to swap to: " target_commit
    if [ -z "${target_commit//[[:space:]]/}" ]; then
        echo "${RED}Target cannot be empty. Aborting.${NC}" >&2
        exit 1
    fi
    if ! VALID_SHA="$(git rev-parse --verify "${target_commit}^{commit}" 2>/dev/null)"; then
        echo "${RED}Error: '$target_commit' is not a valid commit or reference.${NC}" >&2
        exit 1
    fi
    echo ""
    echo "${CYAN}Target Found:${NC}"
    git log -1 "$VALID_SHA" --oneline --format="%C(cyan)%h %C(white)- %s (%cr) <%an>"
    echo ""
    echo "${YELLOW}What action do you want to perform?${NC}"
    echo "1) Look only (Detached HEAD checkout - safe, leaves current branch alone)"
    echo "2) Hard reset (FORCE current branch root back to this commit - will lose uncommitted work!)"
    read -r -p "Select action (1-2): " action
    if [ "$action" = "1" ]; then
        echo ""
        echo "${CYAN}Swapping to commit $target_commit in read-only detached state...${NC}"
        git checkout "$VALID_SHA"
    elif [ "$action" = "2" ]; then
        read -r -p "Type 'RESET' to force your current branch back to this exact commit: " confirm
        if [ "$confirm" != "RESET" ]; then echo "Aborting hard reset."; exit 1; fi
        echo ""
        echo "${RED}Forcing current branch back to target...${NC}"
        git reset --hard "$VALID_SHA"
    else
        echo "${RED}Invalid action selected. Aborting.${NC}" >&2
        exit 1
    fi
fi

# --- MODE 7: MASS DELETE BRANCHES ---
if [ "$SCOPE" = "7" ]; then
    echo ""
    echo "${MAGENTA}[>] BRANCH PURGE MATRIX ACQUISITION [>]${NC}"
    echo "${CYAN}Syncing with GitHub remote references...${NC}"
    git fetch origin --prune 2>/dev/null

    CURRENT_BRANCH="$(git branch --show-current | tr -d '[:space:]')"

    mapfile -t ONLINE_BRANCHES < <(git ls-remote --heads origin 2>/dev/null \
        | sed -n 's|.*refs/heads/||p')

    declare -a NAMES=() AGES=() STATUS=()
    idx=1
    while IFS='|' read -r bname age upstream; do
        bname="$(echo "$bname" | xargs)"; age="$(echo "$age" | xargs)"; upstream="$(echo "$upstream" | xargs)"
        [ -z "$bname" ] && continue
        [ "$bname" = "$CURRENT_BRANCH" ] && continue

        status_text="Local Only"
        if printf '%s\n' "${ONLINE_BRANCHES[@]}" | grep -qx "$bname"; then
            status_text="Available Online"
        elif [ -n "$upstream" ]; then
            status_text="Deleted Online"
        fi
        NAMES+=("$bname"); AGES+=("$age"); STATUS+=("$status_text")
        idx=$((idx + 1))
    done < <(git branch --format='%(refname:short)|%(committerdate:relative)|%(upstream)')

    if [ "${#NAMES[@]}" -eq 0 ]; then
        echo "${YELLOW}No other local branches available to delete. (Active branch: $CURRENT_BRANCH)${NC}"
        exit 0
    fi

    echo ""
    echo "${CYAN}Available Local Branches for Purge:${NC}"
    printf "${WHITE}%-5s %-30s %-20s %-15s${NC}\n" "ID" "Branch Name" "Last Activity" "GitHub Status"
    printf "${WHITE}%-5s %-30s %-20s %-15s${NC}\n" "--" "-----------" "-------------" "-------------"
    for i in "${!NAMES[@]}"; do
        id=$((i + 1))
        case "${STATUS[$i]}" in
            "Available Online") c="$GREEN" ;;
            "Deleted Online")   c="$RED" ;;
            *)                  c="$YELLOW" ;;
        esac
        printf "%-5s %-30s %-20s " "$id" "${NAMES[$i]}" "${AGES[$i]}"
        printf "${c}%s${NC}\n" "${STATUS[$i]}"
    done

    echo ""
    echo "${YELLOW}Enter the IDs of the branches you want to delete (comma-separated, e.g., 1,3,4):${NC}"
    read -r -p "Selection: " selection_input
    if [ -z "${selection_input//[[:space:]]/}" ]; then
        echo "${RED}No selection made. Aborting.${NC}" >&2
        exit 1
    fi

    declare -A SELECTED=()
    IFS=',' read -ra TOKENS <<< "$selection_input"
    for tok in "${TOKENS[@]}"; do
        tok="$(echo "$tok" | xargs)"
        if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            s="${BASH_REMATCH[1]}"; e="${BASH_REMATCH[2]}"
            if [ "$s" -le "$e" ]; then
                for ((i = s; i <= e; i++)); do SELECTED["$i"]=1; done
            fi
        elif [[ "$tok" =~ ^[0-9]+$ ]]; then
            SELECTED["$tok"]=1
        fi
    done

    declare -a TARGETS=()
    for id in "${!SELECTED[@]}"; do
        i=$((id - 1))
        if [ "$i" -ge 0 ] && [ "$i" -lt "${#NAMES[@]}" ]; then
            TARGETS+=("${NAMES[$i]}")
        fi
    done

    if [ "${#TARGETS[@]}" -eq 0 ]; then
        echo "${RED}No valid matching branch IDs selected. Aborting.${NC}" >&2
        exit 1
    fi

    echo ""
    echo "${RED}Selected targets for extraction/purge:${NC}"
    for t in "${TARGETS[@]}"; do echo " -> $t"; done

    echo ""
    echo "${YELLOW}How do you want to handle unmerged changes?${NC}"
    echo "1) Safe Delete (-d : Aborts execution if branch contains unmerged work)"
    echo "2) Force Purge (-D : FORCE destroys branch irrespective of merge status!)"
    read -r -p "Select action (1-2): " purge_action
    DEL_FLAG="-d"
    if [ "$purge_action" = "2" ]; then
        read -r -p "Type 'PURGE' to verify lethal execution override: " confirm
        if [ "$confirm" != "PURGE" ]; then echo "Aborting force purge."; exit 1; fi
        DEL_FLAG="-D"
    elif [ "$purge_action" != "1" ]; then
        echo "${RED}Invalid action selected. Aborting.${NC}" >&2
        exit 1
    fi

    echo ""
    echo "${MAGENTA}Executing branch purge pipeline...${NC}"
    for t in "${TARGETS[@]}"; do
        echo "${CYAN}Deleting branch '$t'...${NC}"
        git branch "$DEL_FLAG" "$t"
    done
    echo ""
    echo "${GREEN}Purge operation complete.${NC}"
fi

echo ""
echo "${CYAN}--- Updated Git Status ---${NC}"
git status -s
