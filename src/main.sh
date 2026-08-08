cmd_help() {
    cat << HELP
glibcx - Universal Native-Speed glibc Binary Runner for Termux (v0.2.0)

USAGE:
    glibcx setup                   Install prerequisites and configure PATH / Shizuku
    glibcx patch <binary_path>     Audit, register, and compile a native wrapper
    glibcx run <binary> [-- args]  Ephemeral trial execution via ld.so (no file changes)
    glibcx restore <binary_path>   Restore original binary and remove wrapper (alias: unpatch)
    glibcx vendor <binary> <libs>  Copy external .so files into the wrapper's library path
    glibcx upgrade <binary_path>   Re-patch a registered binary (after self-update)
    glibcx list                    List all managed binaries with status and drift check
    glibcx info <binary_path>      Show full registry entry for a binary
    glibcx clean                   Remove registry entries for missing binaries
    glibcx benchmark               Download + patch 10 popular binaries not in Termux
    glibcx self-update [--force]   Update glibcx to the latest release

SMART PROVIDERS:
    glibcx npm install <pkg>       Smart-install an NPM package (Android-native first)
    glibcx gh install <owner/repo> Fetch and patch the latest Linux ARM64 GitHub Release
    glibcx fetch <url>             Download any .tar.gz / .zip / binary, extract & patch
    glibcx intercept '<cmd>'       Run an install script and auto-patch any new binaries

SUCCESS CRITERIA:
    glibcx benchmark         Download + patch 10 popular binaries not in Termux
    glibcx help              Show this help

    glibcx fetch https://example.com/tool-linux-arm64.tar.gz
    glibcx intercept 'curl -fsSL https://bun.sh/install | bash'
EXAMPLES:
    glibcx npm install @anthropic-ai/claude-code
    glibcx gh install sharkdp/fd
    glibcx gh install ast-grep/ast-grep
    glibcx fetch https://example.com/tool-linux-arm64.tar.gz
    glibcx intercept 'curl -fsSL https://bun.sh/install | bash'
    glibcx run ./my-binary -- --version
HELP
}

case "${1:-}" in
    setup)       cmd_setup ;;
    npm)         shift; cmd_npm "$@" ;;
    gh)          shift; cmd_gh "$@" ;;
    fetch)       shift; cmd_fetch "$@" ;;
    intercept)   shift; cmd_intercept "$@" ;;
    patch)       cmd_patch "${2:-}" ;;
    restore|unpatch) cmd_restore "${2:-}" ;;
    vendor)      shift; cmd_vendor "$@" ;;
    upgrade)     cmd_upgrade "${2:-}" ;;
    list)        cmd_list ;;
    info)        cmd_info "${2:-}" ;;
    clean)       cmd_clean ;;
    run)         shift; cmd_run "$@" ;;
    benchmark)   cmd_bench ;;
    self-update) cmd_selfupdate ;;
    help|--help|-h) cmd_help ;;
    *)           cmd_help; exit 1 ;;
esac
