#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

static pthread_once_t resolve_once = PTHREAD_ONCE_INIT;
static __thread unsigned int shim_depth;

static ssize_t (*next_readlink)(const char *, char *, size_t);
static ssize_t (*next_readlinkat)(int, const char *, char *, size_t);
static int (*next_open)(const char *, int, ...);
static int (*next_open64)(const char *, int, ...);
static int (*next_openat)(int, const char *, int, ...);
static int (*next_openat64)(int, const char *, int, ...);
static int (*next_execve)(const char *, char *const[], char *const[]);
static int (*next_execveat)(int, const char *, char *const[], char *const[], int);

static void resolve_one(void **slot, const char *name) {
    *slot = dlsym(RTLD_NEXT, name);
}

static void resolve_symbols(void) {
    resolve_one((void **)&next_readlink, "readlink");
    resolve_one((void **)&next_readlinkat, "readlinkat");
    resolve_one((void **)&next_open, "open");
    resolve_one((void **)&next_open64, "open64");
    resolve_one((void **)&next_openat, "openat");
    resolve_one((void **)&next_openat64, "openat64");
    resolve_one((void **)&next_execve, "execve");
    resolve_one((void **)&next_execveat, "execveat");
}

__attribute__((constructor)) static void initialize_shim(void) {
    (void)pthread_once(&resolve_once, resolve_symbols);
}

static bool exact_proc_exe(const char *path) {
    char current[64];
    int length;
    if (path == NULL) return false;
    if (strcmp(path, "/proc/self/exe") == 0) return true;
    length = snprintf(current, sizeof(current), "/proc/%ld/exe", (long)getpid());
    return length > 0 && (size_t)length < sizeof(current) && strcmp(path, current) == 0;
}

static const char *real_target(void) {
    const char *value = getenv("GLIBCX_REAL_EXE");
    return value != NULL && value[0] == '/' ? value : NULL;
}

static const char *wrapper_target(void) {
    const char *value = getenv("GLIBCX_WRAPPER_EXE");
    return value != NULL && value[0] == '/' ? value : NULL;
}

static const char *rewrite_open_path(const char *path) {
    const char *target = real_target();
    return target != NULL && exact_proc_exe(path) ? target : path;
}

static bool open_needs_mode(int flags) {
    if ((flags & O_CREAT) != 0) return true;
#ifdef O_TMPFILE
    if ((flags & O_TMPFILE) == O_TMPFILE) return true;
#endif
    return false;
}

ssize_t readlink(const char *path, char *buffer, size_t buffer_size) {
    const char *target;
    size_t length;
    pthread_once(&resolve_once, resolve_symbols);
    if (shim_depth++ != 0 || !exact_proc_exe(path) || (target = real_target()) == NULL) {
        shim_depth--;
        if (next_readlink == NULL) { errno = ENOSYS; return -1; }
        return next_readlink(path, buffer, buffer_size);
    }
    if (buffer_size == 0) {
        shim_depth--;
        errno = EINVAL;
        return -1;
    }
    length = strlen(target);
    if (length > buffer_size) length = buffer_size;
    if (length != 0) memcpy(buffer, target, length);
    shim_depth--;
    return (ssize_t)length;
}

ssize_t readlinkat(int directory_fd, const char *path, char *buffer, size_t buffer_size) {
    const char *target;
    size_t length;
    pthread_once(&resolve_once, resolve_symbols);
    if (shim_depth++ != 0 || !exact_proc_exe(path) || (target = real_target()) == NULL) {
        shim_depth--;
        if (next_readlinkat == NULL) { errno = ENOSYS; return -1; }
        return next_readlinkat(directory_fd, path, buffer, buffer_size);
    }
    if (buffer_size == 0) {
        shim_depth--;
        errno = EINVAL;
        return -1;
    }
    length = strlen(target);
    if (length > buffer_size) length = buffer_size;
    if (length != 0) memcpy(buffer, target, length);
    shim_depth--;
    return (ssize_t)length;
}

ssize_t __readlink_chk(const char *path, char *buffer, size_t buffer_size, size_t object_size) {
    if (buffer_size > object_size) { errno = ERANGE; return -1; }
    return readlink(path, buffer, buffer_size);
}

ssize_t __readlinkat_chk(int directory_fd, const char *path, char *buffer,
                         size_t buffer_size, size_t object_size) {
    if (buffer_size > object_size) { errno = ERANGE; return -1; }
    return readlinkat(directory_fd, path, buffer, buffer_size);
}

int open(const char *path, int flags, ...) {
    mode_t mode = 0;
    bool with_mode = open_needs_mode(flags);
    const char *rewritten;
    if (with_mode) {
        va_list arguments;
        va_start(arguments, flags);
        mode = (mode_t)va_arg(arguments, int);
        va_end(arguments);
    }
    pthread_once(&resolve_once, resolve_symbols);
    rewritten = rewrite_open_path(path);
    if (next_open == NULL) { errno = ENOSYS; return -1; }
    return with_mode ? next_open(rewritten, flags, mode) : next_open(rewritten, flags);
}

int open64(const char *path, int flags, ...) {
    mode_t mode = 0;
    bool with_mode = open_needs_mode(flags);
    const char *rewritten;
    if (with_mode) {
        va_list arguments;
        va_start(arguments, flags);
        mode = (mode_t)va_arg(arguments, int);
        va_end(arguments);
    }
    pthread_once(&resolve_once, resolve_symbols);
    rewritten = rewrite_open_path(path);
    if (next_open64 == NULL) {
        if (next_open == NULL) { errno = ENOSYS; return -1; }
        return with_mode ? next_open(rewritten, flags, mode) : next_open(rewritten, flags);
    }
    return with_mode ? next_open64(rewritten, flags, mode) : next_open64(rewritten, flags);
}

int openat(int directory_fd, const char *path, int flags, ...) {
    mode_t mode = 0;
    bool with_mode = open_needs_mode(flags);
    const char *rewritten;
    if (with_mode) {
        va_list arguments;
        va_start(arguments, flags);
        mode = (mode_t)va_arg(arguments, int);
        va_end(arguments);
    }
    pthread_once(&resolve_once, resolve_symbols);
    rewritten = rewrite_open_path(path);
    if (next_openat == NULL) { errno = ENOSYS; return -1; }
    return with_mode ? next_openat(directory_fd, rewritten, flags, mode)
                     : next_openat(directory_fd, rewritten, flags);
}

int openat64(int directory_fd, const char *path, int flags, ...) {
    mode_t mode = 0;
    bool with_mode = open_needs_mode(flags);
    const char *rewritten;
    if (with_mode) {
        va_list arguments;
        va_start(arguments, flags);
        mode = (mode_t)va_arg(arguments, int);
        va_end(arguments);
    }
    pthread_once(&resolve_once, resolve_symbols);
    rewritten = rewrite_open_path(path);
    if (next_openat64 == NULL) {
        if (next_openat == NULL) { errno = ENOSYS; return -1; }
        return with_mode ? next_openat(directory_fd, rewritten, flags, mode)
                         : next_openat(directory_fd, rewritten, flags);
    }
    return with_mode ? next_openat64(directory_fd, rewritten, flags, mode)
                     : next_openat64(directory_fd, rewritten, flags);
}

int __open_2(const char *path, int flags) {
    if (open_needs_mode(flags)) { errno = EINVAL; return -1; }
    return open(path, flags);
}

int __open64_2(const char *path, int flags) {
    if (open_needs_mode(flags)) { errno = EINVAL; return -1; }
    return open64(path, flags);
}

int __openat_2(int directory_fd, const char *path, int flags) {
    if (open_needs_mode(flags)) { errno = EINVAL; return -1; }
    return openat(directory_fd, path, flags);
}

int __openat64_2(int directory_fd, const char *path, int flags) {
    if (open_needs_mode(flags)) { errno = EINVAL; return -1; }
    return openat64(directory_fd, path, flags);
}

static bool redirect_self_execution(const char *path) {
    const char *target = real_target();
    return exact_proc_exe(path) || (target != NULL && path != NULL && strcmp(path, target) == 0);
}

int execve(const char *path, char *const arguments[], char *const environment[]) {
    const char *wrapper;
    pthread_once(&resolve_once, resolve_symbols);
    wrapper = wrapper_target();
    if (shim_depth++ == 0 && wrapper != NULL && redirect_self_execution(path)) path = wrapper;
    shim_depth--;
    if (next_execve == NULL) { errno = ENOSYS; return -1; }
    return next_execve(path, arguments, environment);
}

int execveat(int directory_fd, const char *path, char *const arguments[],
             char *const environment[], int flags) {
    const char *wrapper;
    pthread_once(&resolve_once, resolve_symbols);
    wrapper = wrapper_target();
    if (shim_depth++ == 0 && wrapper != NULL && redirect_self_execution(path)) {
        shim_depth--;
        if (next_execve == NULL) { errno = ENOSYS; return -1; }
        return next_execve(wrapper, arguments, environment);
    }
    shim_depth--;
    if (next_execveat == NULL) { errno = ENOSYS; return -1; }
    return next_execveat(directory_fd, path, arguments, environment, flags);
}
