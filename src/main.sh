cmd_help() {
    cat << HELP
glibcx - Universal Native-Speed glibc Binary Runner for Termux (v0.3.0-dev)

USAGE:
    glibcx setup                   Install prerequisites and configure PATH / Shizuku
    glibcx patch <binary_path>     Inspect, verify, register, and compile a native wrapper
      --runtime <profile>          Select an installed runtime (system is explicit development use)
      --dry-run                    Inspect and verify without locks or file changes
      --offline                    Use only installed profiles and cached packages
      --refresh                    Refresh authenticated repository metadata
      --no-resolve                 Do not fetch unresolved startup DSOs
      --proc-exe=auto|on|off       Select optional /proc/self/exe compatibility mode
      --no-verify                  Explicitly record an unverified wrapper
      --verbose                    Show the full dependency and GLIBC audit
    glibcx run <binary> [-- args]  Ephemeral execution through its registered runtime
    glibcx restore <binary_path>   Remove wrapper and registry entry (alias: unpatch; original binary untouched)
    glibcx rollback <binary> [N]  Atomically activate a retained app generation
    glibcx vendor <binary> <libs>  Transactionally vendor DSOs and rebuild the dependency lock
    glibcx upgrade <binary_path>   Re-patch a registered binary (after self-update)
    glibcx list                    List all managed binaries with status and drift check
    glibcx info <binary_path>      Show full registry entry for a binary
    glibcx doctor <binary_path>    Read-only ELF, loader, dependency, and drift diagnostics
    glibcx deps <binary_path> [--refresh|--verbose]
                                  Show or refresh the locked startup dependency graph
    glibcx trace-libs <binary> [-- args]
                                  Execute with controlled loader tracing; do not change the lock
    glibcx clean                   Remove registry entries for missing binaries
    glibcx runtime install <profile|recommended> [--offline]
                                  Install a signed managed runtime
    glibcx runtime <command>       Also supports list, import-system, verify, and remove
    glibcx benchmark               Download + patch 11 popular binaries not in Termux
    glibcx self-update [--force]   Update glibcx to the latest release

SMART PROVIDERS:
    glibcx npm install <pkg> [--runtime <id>]
                                  Smart-install an NPM package (Android-native first)
    glibcx gh install <repo> [--runtime <id>]
                                  Fetch and patch the latest Linux ARM64 GitHub Release
    glibcx fetch <url> [--runtime <id>]
                                  Download an archive/binary, extract, and patch it
    glibcx intercept '<cmd>' [--runtime <id>]
                                  Run an install script and patch new binaries

SUCCESS CRITERIA:
    glibcx benchmark         Download + patch 11 popular binaries not in Termux
    glibcx help              Show this help

    glibcx fetch https://example.com/tool-linux-arm64.tar.gz --runtime system
    glibcx intercept 'curl -fsSL https://bun.sh/install | bash' --runtime system
EXAMPLES:
    glibcx runtime import-system
    glibcx npm install @anthropic-ai/claude-code --runtime system
    glibcx gh install sharkdp/fd --runtime system
    glibcx gh install ast-grep/ast-grep --runtime system
    glibcx fetch https://example.com/tool-linux-arm64.tar.gz --runtime system
    glibcx intercept 'curl -fsSL https://bun.sh/install | bash' --runtime system
    glibcx run ./my-binary -- --version
HELP
}

case "${1:-}" in
    setup)       cmd_setup ;;
    npm)         shift; cmd_npm "$@" ;;
    gh)          shift; cmd_gh "$@" ;;
    fetch)       shift; cmd_fetch "$@" ;;
    intercept)   shift; cmd_intercept "$@" ;;
    patch)       shift; cmd_patch "$@" ;;
    rollback)    shift; cmd_rollback "$@" ;;
    restore|unpatch) cmd_restore "${2:-}" ;;
    vendor)      shift; cmd_vendor "$@" ;;
    upgrade)     cmd_upgrade "${2:-}" ;;
    list)        cmd_list ;;
    info)        cmd_info "${2:-}" ;;
    doctor)      cmd_doctor "${2:-}" ;;
    deps)        shift; cmd_deps "$@" ;;
    trace-libs)  shift; cmd_trace_libs "$@" ;;
    clean)       shift; cmd_clean "$@" ;;
    runtime)     shift; cmd_runtime "$@" ;;
    run)         shift; cmd_run "$@" ;;
    benchmark)   cmd_bench ;;
    self-update) shift; cmd_selfupdate "$@" ;;
    help|--help|-h) cmd_help ;;
    *)           cmd_help; exit 1 ;;
esac
