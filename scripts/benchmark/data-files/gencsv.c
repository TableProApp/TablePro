#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

static uint64_t s = 0x9E3779B97F4A7C15ULL;
static inline uint64_t rnd(void) {
    s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s;
}
static inline uint32_t rn(uint32_t n) { return (uint32_t)(rnd() % n); }

static const char *last[] = {"Smith","Johnson","Williams","Brown","Jones","Garcia","Miller","Davis","Rodriguez","Martinez","Hernandez","Lopez","Gonzalez","Wilson","Anderson","Thomas","Taylor","Moore","Jackson","Martin","Lee","Perez","Thompson","White","Harris","Sanchez","Clark","Ramirez","Lewis","Robinson","Nguyen","Tran"};
static const char *first[] = {"James","Mary","Robert","Patricia","John","Jennifer","Michael","Linda","David","Elizabeth","William","Barbara","Richard","Susan","Joseph","Jessica","Thomas","Sarah","Charles","Karen","Dat","Minh","Anh","Linh"};
static const char *cats[] = {"Electronics","Books","Clothing","Home","Garden","Toys","Sports","Automotive","Beauty","Health","Grocery","Music","Movies","Office","Pet Supplies","Tools","Jewelry","Shoes","Baby","Software"};
static const char *cities[] = {"New York","Los Angeles","Chicago","Houston","Phoenix","Philadelphia","San Antonio","San Diego","Dallas","Hanoi","Ho Chi Minh City","London","Paris","Berlin","Tokyo","Sydney"};
static const char *ccs[] = {"US","VN","GB","FR","DE","JP","AU","CA","BR","IN"};
static const char *words[] = {"quick","delivery","late","damaged","great","value","would","buy","again","refund","requested","item","arrived","on","time","excellent","packaging","poor","support","helpful","color","size","fits","well","broke","after","week"};

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: gencsv <out> <targetBytes>\n"); return 1; }
    FILE *f = fopen(argv[1], "wb");
    if (!f) { perror("fopen"); return 1; }
    long long target = atoll(argv[2]);
    static char buf[1 << 20];
    setvbuf(f, buf, _IOFBF, sizeof buf);
    fputs("id,name,email,amount,order_date,category,city,quantity,active,score,country,notes\n", f);
    long long written = 0; long long id = 1;
    char line[4096];
    while (written < target) {
        const char *ln = last[rn(32)], *fn = first[rn(24)];
        int n = snprintf(line, sizeof line,
            "%lld,\"%s, %s\",%c%c%lld@example.com,%u.%02u,%04u-%02u-%02u,%s,%s,%u,%s,%u.%03u,%s,",
            id, ln, fn, fn[0] | 0x20, ln[0] | 0x20, id,
            rn(100000), rn(100),
            2015 + rn(11), 1 + rn(12), 1 + rn(28),
            cats[rn(20)], cities[rn(16)], 1 + rn(50), rn(2) ? "true" : "false",
            rn(100), rn(1000), ccs[rn(10)]);
        uint32_t kind = rn(100);
        int nw = 3 + rn(12);
        if (kind < 3) {
            line[n++] = '"';
            for (int w = 0; w < nw; w++) {
                const char *wd = words[rn(27)];
                size_t l = strlen(wd); memcpy(line + n, wd, l); n += l;
                if (w == nw / 2) { line[n++] = '\n'; } else if (w + 1 < nw) line[n++] = ' ';
            }
            line[n++] = '"';
        } else if (kind < 6) {
            line[n++] = '"';
            for (int w = 0; w < nw; w++) {
                const char *wd = words[rn(27)];
                if (w == 1) { line[n++] = '"'; line[n++] = '"'; }
                size_t l = strlen(wd); memcpy(line + n, wd, l); n += l;
                if (w == 1) { line[n++] = '"'; line[n++] = '"'; }
                if (w + 1 < nw) { line[n++] = ','; line[n++] = ' '; }
            }
            line[n++] = '"';
        } else {
            for (int w = 0; w < nw; w++) {
                const char *wd = words[rn(27)];
                size_t l = strlen(wd); memcpy(line + n, wd, l); n += l;
                if (w + 1 < nw) line[n++] = ' ';
            }
        }
        line[n++] = '\n';
        fwrite(line, 1, n, f);
        written += n; id++;
    }
    fclose(f);
    fprintf(stderr, "rows=%lld bytes=%lld\n", id - 1, written);
    return 0;
}
