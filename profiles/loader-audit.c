#define _GNU_SOURCE
#include <link.h>
#include <stddef.h>
#include <stdint.h>

/*
 * Loader callbacks run before application code. Keep this module independent
 * of libc and allocation: it writes a versioned, ASCII/hex protocol directly
 * to the descriptor reserved by glibcx.
 */
#define GLIBCX_AUDIT_FD 198

static uint64_t next_object_id = 1;

static long raw_write(int fd, const void *buffer, size_t length) {
    register long x0 __asm__("x0") = fd;
    register const void *x1 __asm__("x1") = buffer;
    register size_t x2 __asm__("x2") = length;
    register long x8 __asm__("x8") = 64; /* __NR_write on AArch64 */
    __asm__ volatile("svc 0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
    return x0;
}

static void write_all(const char *buffer, size_t length) {
    while (length > 0) {
        long written = raw_write(GLIBCX_AUDIT_FD, buffer, length);
        if (written <= 0) return;
        buffer += (size_t)written;
        length -= (size_t)written;
    }
}

static void write_literal(const char *text) {
    size_t length = 0;
    while (text[length] != '\0') length++;
    write_all(text, length);
}

static void write_hex_u64(uint64_t value) {
    static const char digits[] = "0123456789abcdef";
    char output[16];
    for (size_t index = 0; index < sizeof(output); index++) {
        output[sizeof(output) - index - 1] = digits[value & 0xfU];
        value >>= 4U;
    }
    write_all(output, sizeof(output));
}

static void write_hex_string(const char *text) {
    static const char digits[] = "0123456789abcdef";
    char pair[2];
    if (text == NULL) return;
    while (*text != '\0') {
        unsigned char value = (unsigned char)*text++;
        pair[0] = digits[value >> 4U];
        pair[1] = digits[value & 0xfU];
        write_all(pair, sizeof(pair));
    }
}

unsigned int la_version(unsigned int version) {
    if (version < LAV_CURRENT) return 0;
    write_literal("GXA1\tSTART\n");
    return LAV_CURRENT;
}

unsigned int la_objopen(struct link_map *map, Lmid_t lmid, uintptr_t *cookie) {
    uint64_t object_id = next_object_id++;
    *cookie = (uintptr_t)object_id;
    write_literal("GXA1\tOPEN\t");
    write_hex_u64(object_id);
    write_literal("\t");
    write_hex_u64((uint64_t)lmid);
    write_literal("\t");
    write_hex_string(map->l_name);
    write_literal("\n");
    return 0;
}

char *la_objsearch(const char *name, uintptr_t *cookie, unsigned int flag) {
    write_literal("GXA1\tSEARCH\t");
    write_hex_u64((uint64_t)*cookie);
    write_literal("\t");
    write_hex_u64((uint64_t)flag);
    write_literal("\t");
    write_hex_string(name);
    write_literal("\n");
    return (char *)name;
}

void la_activity(uintptr_t *cookie, unsigned int flag) {
    (void)cookie;
    if (flag == LA_ACT_CONSISTENT) write_literal("GXA1\tCONSISTENT\n");
}
