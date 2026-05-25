#!/bin/sh
# Shared UI library — matches platform-infra conventions

RESET="\033[0m"   BOLD="\033[1m"    DIM="\033[2m"
RED="\033[31m"    GREEN="\033[32m"  YELLOW="\033[33m"
CYAN="\033[36m"   WHITE="\033[97m"

BG_BLUE="\033[44m"  BG_GREEN="\033[42m"  BG_RED="\033[41m"  BG_YELLOW="\033[43m"
BLACK="\033[30m"

TICK="✔"  CROSS="✘"  ARROW="▶"  DASH="–"  DOTS="·"

STEP=0
STEP_START=0
DEPLOY_START=$(date +%s)
ERR_LOG=$(mktemp)
trap 'rm -f "$ERR_LOG"' EXIT

step_start() {
    STEP=$((STEP + 1))
    STEP_START=$(date +%s)
    printf "  ${CYAN}${BOLD}[%d]${RESET} ${WHITE}%s${RESET} ${DIM}${DOTS} running...${RESET}" "$STEP" "$1"
}

step_ok() {
    elapsed=$(($(date +%s) - STEP_START))
    printf "\r  ${CYAN}${BOLD}[%d]${RESET} ${WHITE}%s${RESET} ${GREEN}${TICK} %s ${DIM}(%ds)${RESET}\n" "$STEP" "$1" "${2:-done}" "$elapsed"
}

step_skip() {
    printf "\r  ${CYAN}${BOLD}[%d]${RESET} ${WHITE}%s${RESET} ${YELLOW}${DASH} %s${RESET}\n" "$STEP" "$1" "$2"
}

step_fail() {
    printf "\r  ${CYAN}${BOLD}[%d]${RESET} ${WHITE}%s${RESET} ${RED}${CROSS} %s${RESET}\n" "$STEP" "$1" "$2"
}

info() {
    printf "        ${DIM}${ARROW} %s${RESET}\n" "$1"
}

print_header() {
    action="${2:-DEPLOY}"
    case "$action" in
        DEPLOY)   icon="🚀" ;;
        SETUP)    icon="⚙️" ;;
        UPDATE)   icon="🔄" ;;
        ROLLBACK) icon="↩️" ;;
        *)        icon="▶" ;;
    esac
    echo ""
    printf "  ${BG_BLUE}${WHITE}${BOLD}  %s  %s %s  ${RESET}\n" "$icon" "$action" "$1"
    printf "  ${DIM}%s${RESET}\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "  ${DIM}──────────────────────────────────${RESET}\n"
    echo ""
}

print_footer() {
    total=$(($(date +%s) - DEPLOY_START))
    case "$1" in
        ok)
            printf "\n  ${BG_GREEN}${BLACK}${BOLD}  ${TICK}  %s COMPLETE  total: %ds  ${RESET}\n\n" "${2:-DEPLOY}" "$total"
            ;;
        skip)
            printf "\n  ${BG_YELLOW}${BLACK}${BOLD}  ${DASH}  ALREADY UP TO DATE  total: %ds  ${RESET}\n\n" "$total"
            ;;
        fail)
            printf "\n  ${BG_RED}${WHITE}${BOLD}  ${CROSS}  %s FAILED  total: %ds  ${RESET}\n\n" "${2:-DEPLOY}" "$total"
            ;;
    esac
}

capture_errors() {
    if [ -s "$ERR_LOG" ]; then
        tail -5 "$ERR_LOG" | cut -c1-500
    fi
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        step_fail "$2" "$1 not found"
        print_footer "fail" "$3"
        exit 1
    fi
}
