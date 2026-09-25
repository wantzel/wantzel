/* agent-permissions: read
 *
 * NOT because this file is finished, but because it has a COUNTERPART: src/wantzel.wz is
 * the same logic in Wantzel, and changing one without the other breaks the bootstrap fixed
 * point -- which is discovered much later, by someone else. Change both, in one commit,
 * under a ticket that asks for it.
 */
/* boot.c -- bootstrap compiler for the Wantzel language.
 *
 * This is the ONLY file that ever needs an external C compiler.  It is a
 * complete Wantzel compiler: it reads a .wz source file and writes a static
 * x86-64 Linux ELF executable directly, using no assembler, no linker and
 * no runtime library.  Once built, src/wantzel.wz (the same compiler written
 * in Wantzel) can be compiled by this program, after which the language is
 * self-hosting and boot.c is no longer needed.
 *
 * The code is deliberately written in a restricted C dialect that maps
 * one-to-one onto Wantzel: every value is a long, buffers are plain arrays,
 * no structs, no switch, no for-loops, no pointer arithmetic beyond
 * &array[i], and all bit operations are written as explicit calls.
 */

#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

/* ------------------------------------------------------------------ */
/* limits                                                              */
/* ------------------------------------------------------------------ */
/* The release this compiler was built from; src/wantzel.wz has the same string. */
#define VERSION "0.4.0"
#define SRCMAX  67108864
#define CODEMAX 67108864
#define DATMAX  33554432
#define NAMEMAX 8388608
#define FNPMAX    524000   /* the pool of source file names; fnpool holds 524288 */
#define MAXG       16384
#define MAXF        8192
/* Buckets for the name index over globals and routines.  A power of two so the
   modulo is a mask, and four times MAXG so a full table still averages well under
   one name per bucket.  The index is what keeps a lookup from walking every name:
   without it, compiling 16,384 globals costs four times what 8,192 cost. */
#define NHASH      65536
#define HMASK      65535
#define MAXL        2048
#define MAXP          10
#define MAXFIX   4194304
#define DBGMAX  16777216   /* the debug sidecar, collected in memory; see docs/design.md */
#define TBMAX       4096

/* type codes */
#define T_VOID 0
#define T_INT  1
#define T_CHAR 2
#define T_BOOL 3
#define T_STR  4
#define T_REAL 5
#define T_REC  16   /* record type k has type code T_REC + k */
#define MAXR   1024
#define MAXRF  32768

/* token codes: printable ASCII stands for itself */
#define TK_EOF    0
#define TK_INT    1
#define TK_CHR    2
#define TK_STR    3
#define TK_ID     4
#define TK_ASSIGN 5
#define TK_NE     6
#define TK_LE     7
#define TK_GE     8
#define TK_RANGE  9
#define TK_REAL  10
/* keywords */
#define KW_CONST     101
#define KW_VAR       102
#define KW_ARRAY     103
#define KW_OF        104
#define KW_FUNCTION  105
#define KW_PROCEDURE 106
#define KW_FORWARD   107
#define KW_BEGIN     108
#define KW_END       109
#define KW_IF        110
#define KW_THEN      111
#define KW_ELSE      112
#define KW_WHILE     113
#define KW_DO        114
#define KW_RETURN    117
#define KW_BREAK     118
#define KW_CONTINUE  119
#define KW_DIV       120
#define KW_MOD       121
#define KW_AND       122
#define KW_OR        123
#define KW_NOT       124
#define KW_SHL       125
#define KW_SHR       126
#define KW_TRUE      127
#define KW_FALSE     128
#define KW_INT       129
#define KW_CHAR      130
#define KW_BOOL      131
#define KW_STR       132
#define KW_INCLUDE   133
#define KW_SCHEMA    134
#define KW_RECORD    135
#define KW_REAL      136
#define KW_TYPE      137
#define KW_FOR       138
#define KW_TO        139
#define KW_DOWNTO    140
#define KW_LOCAL     141
#define KW_TOOLS     142

/* symbol kinds */
#define SK_VAR   0
#define SK_CONST 1

/* fixup kinds */
#define FX_DATA 0   /* patch imm64 with a data-segment address */
#define FX_BSS  2   /* patch imm64 with a bss (global) address */
#define FX_BSS32 3  /* patch imm32 with a bss address (fits: bss < 2GB) */
#define FX_CALL 1   /* patch rel32 with function address */

/* virtual layout */
#define VBASE  0x400000
#define HDRLEN 120  /* the ELF header: one file header and one program header */
/* Imports the SOURCE asks for, by name, on top of the built-in ones. Counterpart of the
   same tables in src/wantzel.wz: a DLL function is data, not a compiler change. */
#define MAXEXT  256
#define MAXEXTD 16

/* ------------------------------------------------------------------ */
/* storage                                                             */
/* ------------------------------------------------------------------ */
char src[SRCMAX];    long srclen;
char code[CODEMAX];  long codelen;
char dat[DATMAX];    long datlen;
char names[NAMEMAX]; long namelen;
char tbuf[TBMAX];
char obuf[TBMAX];
char nearbuf[TBMAX];   /* the nearest declared name, for a typo hint */
long nearbufn;
char mbuf[512]; long mlen;
/* The fixed heading per kind of runtime check, stored once instead of once per check. */
long tphoff[16]; long tphlen[16]; char *tphtxt[16]; long ntph;
char nbuf[32];

/* globals */
long gnam[MAXG], gkind[MAXG], gtyp[MAXG], gval[MAXG];
long garr[MAXG], glo[MAXG], ghi[MAXG];
/* The name index: for each bucket the newest entry in it, and for each entry the
   one before it in the same bucket.  -1 ends a chain.  Globals and routines have
   their own index because they are looked up separately.  Entries are only ever
   added -- ngl and nfn never shrink -- so a chain never has to be unlinked. */
long ghead[NHASH], gnext[MAXG];
/* Visibility per file: -1 is public and that is the default, so existing source compiles
   unchanged.  A file index means the name is only visible in that file. */
long gfile[MAXG];
long declloc;
long fhead[NHASH], fnext[MAXF];
long hashed = 0;
long ngl, bsslen;

/* functions */
long fnam[MAXF], frtyp[MAXF], fnpar[MAXF], fptyp[MAXF*MAXP];
long fadr[MAXF], fdef[MAXF], fline[MAXF], fnreg[MAXF], fparr[MAXF*MAXP];
long ffile[MAXF];   /* the file a forward declaration stood in */
long fvis[MAXF];    /* visibility: -1 is public, the default */
long nfn;

/* record types and their fields */
long rtnam[MAXR], rtsize[MAXR], rtf0[MAXR], rtnf[MAXR];
long nrt;
long fdnam[MAXRF], fdtyp[MAXRF], fdoff[MAXRF], fdarr[MAXRF], fdlo[MAXRF], fdhi[MAXRF];
long nfd;
/* the field path split off a dotted name, and what a designator resolved to */
char fpath[TBMAX]; long fplen;
long refisarr, refet, reflo, refhi, refdyn, refidx, allowslice;

/* locals of the function being compiled */
long lnam[MAXL], ltyp[MAXL], loff[MAXL], lkind[MAXL];
long larr[MAXL], llo[MAXL], lhi[MAXL];
long nloc, frame, curfn, curret;

/* fixups */
long fxoff[MAXFIX], fxkind[MAXFIX], fxval[MAXFIX];
long nfx;

/* loop context */
long brkfix[256], nbrk, brkbase, contaddr;

/* lexer state */
long tok, tval, line, pos;
char outname[256]; long outnamelen;
char fnpool[524288]; long fnplen;             /* names of all source files   */
long filenam[1024], filelen[1024], nfiles, curfile;
long incpos[16], incend[16], incline[16], incfile[16], incdepth;
long srclen; long srcend;
char pathbuf[1024];
/* Where the compiler looks for its library, plus the identity of every file read in
   (st_dev + st_ino from stat(2)).  Counterpart of src/wantzel.wz. */
char libdir[1024]; long libdirlen;
/* the name of the type being declared, before it is known whether it is a record or a
   schema -- see decltypes. Counterpart of tnamebuf in src/wantzel.wz. */
char tnamebuf[64];
/* the compiler's own path, read from /proc/self/exe -- see setlibdir */
char selfbuf[1024];
/* the lib/ path tried for a bare include name: the fallback overwrites pathbuf with the
   relative name, so it is kept here for the error message.  Counterpart of
   src/wantzel.wz:triedlib. */
char triedlib[1024]; long triedlibn;
char stbuf[144];
long fdev[1024]; long fino[1024];

/* misc */
long trapaddr, argaddr, scanaddr, mainaddr, mainpatch, framepatch;
/* THE PLACE OF THE LAST CHECK, so a line with several of them stores one copy.  Counterpart
   of the same four variables in src/wantzel.wz; see there for the measurement.  Measured in
   bin/wantzel: 1016 place strings, 662 distinct -- a third were duplicates from lines holding
   more than one check, and each copy costs its text plus an eight-byte length and padding. */
/* -1 is belt and braces: tplastline starts at 0 and no source line is 0, so the guard in
   trap() cannot match before a real place is written.  It says what is meant, and it keeps
   the first check safe if line 0 ever becomes reachable. */
long tplast = -1, tplastlen, tplastline, tplastfile;
long entryoff;
/* DEBUG INFORMATION: --debug writes <output>.wzdbg, see docs/design.md.  The
   binary is untouched; the sidecar is the only difference.  The records that come in
   address order (line, func, param, local) are collected in dbg as they are produced,
   because a routine's locals are gone by the time the file is written.  Counterpart of
   the same variables in src/wantzel.wz. */
long dbgmode;                       /* was --debug given? */
char dbg[DBGMAX]; long dbglen;
long codebase;                      /* the address of code[0] in the image, known before parsing */
long fend[MAXF], fhline[MAXF], fhfile[MAXF];   /* where a routine ends, and its header */
long dbdata, dbbss;                 /* where the writer put the data and the bss */

/* ------------------------------------------------------------------ */
/* thin io layer (the Wantzel version calls sysN directly)                 */
/* ------------------------------------------------------------------ */
long slen(char *s){ long n; n=0; while(s[n]!=0){ n=n+1; } return n; }
long sch(char *s,long i){ if(i >= slen(s)){ return 0; } return (long)(unsigned char)s[i]; }
long srcb(long i){ return (long)(unsigned char)src[i]; }
long tbufb(long i){ return (long)(unsigned char)tbuf[i]; }
long namesb(long i){ return (long)(unsigned char)names[i]; }
long wrbuf(long fd,long a,long n){ write(fd,(void*)a,n); return 0; }
long wrs(long fd,char *s){ write(fd,s,slen(s)); return 0; }
long rdbuf(long fd,long a,long n){ return read(fd,(void*)a,n); }
long opn(long a,long fl,long mode){ return open((char*)a,fl,mode); }

long band(long a,long b){ return a & b; }
long bor(long a,long b){ return a | b; }
long bxor(long a,long b){ return a ^ b; }
long bnot(long a){ return ~a; }

/* decimal rendering into nbuf, returns length */
long numstr(long v){
    long n; long i; long j; long c;
    n = 0;
    if(v == 0){ nbuf[0] = 48; return 1; }
    if(v < 0){ nbuf[0] = 45; v = 0 - v; n = 1; }
    i = n;
    while(v > 0){ nbuf[n] = 48 + (v % 10); v = v / 10; n = n + 1; }
    j = n - 1;
    while(i < j){ c = nbuf[i]; nbuf[i] = nbuf[j]; nbuf[j] = c; i = i + 1; j = j - 1; }
    return n;
}

long wrnum(long fd,long v){ long n; n = numstr(v); wrbuf(fd,(long)&nbuf[0],n); return 0; }

long cls(long fd){ return close(fd); }
long chm(long a,long m){ return chmod((char*)a,m); }

long wrname(long fd){ wrbuf(fd,(long)&fnpool[filenam[curfile]],filelen[curfile]); return 0; }
/* the name of file fi, which is not necessarily the one being read now */
long wrfile(long fd, long fi){ wrbuf(fd,(long)&fnpool[filenam[fi]],filelen[fi]); return 0; }
/* an interned name, from the pool; they are NUL-terminated */
long wrnam(long fd, long off){
    long n = 0;
    while(namesb(off+n) != 0){ n = n + 1; }
    wrbuf(fd,(long)&names[off],n);
    return 0;
}

long fail(char *m){
    wrs(2,"wantzel: "); wrname(2); wrs(2,":"); wrnum(2,line);
    wrs(2,": "); wrs(2,m); wrs(2,"\n");
    _exit(1);
    return 0;
}

/* Does the name just read carry a capital?  Then the collision about to be reported is
   very probably about CASE and not about the name itself. */
long hascap(void){
    long i = 0;
    while(obuf[i] != 0){
        if((long)(unsigned char)obuf[i] >= 65 && (long)(unsigned char)obuf[i] <= 90){ return 1; }
        i = i + 1;
    }
    return 0;
}

/* "name already used ...", plus, when the name carries capitals, that names are
   case-insensitive and BOTH spellings.  Without that the message reads as though the
   name itself were taken, so the writer picks a different name instead of seeing that
   STORE.SET and store.set ARE one name. */
long failtaken(char *m){
    long i;
    wrs(2,"wantzel: "); wrname(2); wrs(2,":"); wrnum(2,line);
    wrs(2,": "); wrs(2,m);
    if(hascap()){
        wrs(2,"; names are case-insensitive, so ");
        i = 0; while(obuf[i] != 0){ i = i + 1; }
        wrbuf(2,(long)(size_t)&obuf[0],i);
        wrs(2," is the same name as ");
        i = 0; while(tbuf[i] != 0){ i = i + 1; }
        wrbuf(2,(long)(size_t)&tbuf[0],i);
    }
    wrs(2,"\n");
    _exit(1);
    return 0;
}

/* failkeyword -- a keyword where a NAME was expected, and the word is named.

   A schema field called `type` used to be reported as "missing end of the schema" on its
   own line: the field loop stops at the first token that is not an identifier, a keyword
   is not one, and what the parser then found missing was the end.  The line was right and
   the message was wrong -- the reader searches that line for an end that was never
   missing while the word that IS the problem looks like an ordinary name.  A record
   field, a tool and every "name expected" site had the same gap.  Counterpart of the
   routine in src/wantzel.wz.  The repair is derivable for a schema field, so it is given. */
long failkeyword(char *what, long jsonkey){
    long i;
    wrs(2,"wantzel: "); wrname(2); wrs(2,":"); wrnum(2,line); wrs(2,": ");
    i = 0; while(obuf[i] != 0){ i = i + 1; }
    wrbuf(2,(long)(size_t)&obuf[0],i);
    wrs(2," is a keyword and cannot name "); wrs(2,what);
    if(jsonkey){
        wrs(2," -- name the field differently and keep the JSON key: kind \"");
        wrbuf(2,(long)(size_t)&obuf[0],i);
        wrs(2,"\": ...");
    }
    wrs(2,"\n");
    _exit(1);
    return 0;
}

/* iskw -- is the current token a keyword?  Every "name expected" site asks this first. */
long iskw(void){
    return tok >= KW_CONST && tok <= KW_TOOLS;
}

/* kwnamed -- is the current keyword standing where a NAME belongs, judged by the character
   after it?  Counterpart of the routine in src/wantzel.wz, which says why. */
long kwnamed(long c1, long c2){
    long p; long c;
    if(!iskw()){ return 0; }
    p = pos;
    while(p < srcend){
        c = srcb(p);
        if(c != 32 && c != 9 && c != 13 && c != 10){ return c == c1 || c == c2; }
        p = p + 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* lexer                                                               */
/* ------------------------------------------------------------------ */
long isal(long c){ return (c>=97 && c<=122) || (c>=65 && c<=90) || c==95; }
long isdg(long c){ return c>=48 && c<=57; }
long ishx(long c){ return isdg(c) || (c>=97 && c<=102) || (c>=65 && c<=70); }
long lower(long c){ if(c>=65 && c<=90){ return c+32; } return c; }

/* compare the identifier just scanned against a literal */
long eqt(char *s){
    long i;
    i = 0;
    while(1){
        if(tbufb(i) != sch(s,i)){ return 0; }
        if(tbufb(i) == 0){ return 1; }
        i = i + 1;
    }
    return 0;
}

long keyword(){
    long c;
    /* Dispatch on the first character before comparing.  Every identifier used to be
       compared against all 43 keywords in turn, so a name that is not a keyword -- which
       is nearly all of them -- paid for the whole list.  One comparison on the first byte
       cuts that to the handful of keywords that can still match. */
    c = tbufb(0);
    if(c == 97){
        if(eqt("array")){ return KW_ARRAY; }
        if(eqt("and")){ return KW_AND; }
    }
    if(c == 98){
        if(eqt("begin")){ return KW_BEGIN; }
        if(eqt("break")){ return KW_BREAK; }
        if(eqt("bool")){ return KW_BOOL; }
    }
    if(c == 99){
        if(eqt("const")){ return KW_CONST; }
        if(eqt("continue")){ return KW_CONTINUE; }
        if(eqt("char")){ return KW_CHAR; }
    }
    if(c == 100){
        if(eqt("do")){ return KW_DO; }
        if(eqt("div")){ return KW_DIV; }
        if(eqt("downto")){ return KW_DOWNTO; }
    }
    if(c == 101){
        if(eqt("end")){ return KW_END; }
        if(eqt("else")){ return KW_ELSE; }
    }
    if(c == 102){
        if(eqt("function")){ return KW_FUNCTION; }
        if(eqt("forward")){ return KW_FORWARD; }
        if(eqt("false")){ return KW_FALSE; }
        if(eqt("for")){ return KW_FOR; }
    }
    if(c == 105){
        if(eqt("if")){ return KW_IF; }
        if(eqt("int")){ return KW_INT; }
        if(eqt("include")){ return KW_INCLUDE; }
    }
    if(c == 108){
        if(eqt("local")){ return KW_LOCAL; }
    }
    if(c == 109){
        if(eqt("mod")){ return KW_MOD; }
    }
    if(c == 110){
        if(eqt("not")){ return KW_NOT; }
    }
    if(c == 111){
        if(eqt("of")){ return KW_OF; }
        if(eqt("or")){ return KW_OR; }
    }
    if(c == 112){
        if(eqt("procedure")){ return KW_PROCEDURE; }
    }
    if(c == 114){
        if(eqt("return")){ return KW_RETURN; }
        if(eqt("record")){ return KW_RECORD; }
        if(eqt("real")){ return KW_REAL; }
    }
    if(c == 115){
        if(eqt("shl")){ return KW_SHL; }
        if(eqt("shr")){ return KW_SHR; }
        if(eqt("str")){ return KW_STR; }
        if(eqt("schema")){ return KW_SCHEMA; }
    }
    if(c == 116){
        if(eqt("then")){ return KW_THEN; }
        if(eqt("true")){ return KW_TRUE; }
        if(eqt("type")){ return KW_TYPE; }
        if(eqt("to")){ return KW_TO; }
        if(eqt("tools")){ return KW_TOOLS; }
    }
    if(c == 117){
    }
    if(c == 118){
        if(eqt("var")){ return KW_VAR; }
    }
    if(c == 119){
        if(eqt("while")){ return KW_WHILE; }
    }
    return TK_ID;
}

/* the value of one hex digit, or -1 */
long hexdig(long c){
    if(c >= 48 && c <= 57){ return c - 48; }
    if(c >= 97 && c <= 102){ return c - 87; }
    if(c >= 65 && c <= 70){ return c - 55; }
    return -1;
}

#define HEXESC "a hex escape needs exactly two hex digits, as in x41 or xff after a backslash"

/* The byte an escape stands for.  A hex escape reads two more characters here and
   advances pos past them itself.  EXACTLY TWO HEX DIGITS, never a variable number --
   that is where C put its own trap, where a hex escape keeps eating digits and a byte
   followed by a literal hex character silently becomes one different character. */
long escape(long c){
    long h; long l;
    if(c == 110){ return 10; }   /* n */
    if(c == 116){ return 9; }    /* t */
    if(c == 114){ return 13; }   /* r */
    if(c == 48){ return 0; }     /* 0 */
    if(c == 92){ return 92; }    /* \ */
    if(c == 39){ return 39; }    /* ' */
    if(c == 34){ return 34; }    /* " */
    if(c == 120 || c == 88){     /* x or X */
        /* THE SAME MESSAGE AS BELOW, and on purpose: both mean "this escape has no two
           hex digits".  Which fires depends on whether the source happens to end first,
           and that is not a distinction the reader can act on.  src/wantzel.wz keeps the
           text in one constant; here it is a macro for the same reason. */
        if(pos + 2 >= srcend){ fail(HEXESC); }
        h = hexdig(srcb(pos + 1));
        l = hexdig(srcb(pos + 2));
        if(h < 0 || l < 0){ fail(HEXESC); }
        pos = pos + 2;
        return h * 16 + l;
    }
    fail("unknown escape sequence");
    return 0;
}

/* append a string to the data segment, 8-byte length prefix, NUL end.
   returns the offset of the first text byte. */
long datmark;
/* One byte into the data segment, with the room checked BEFORE the write.

   The order matters: checking afterwards means the byte that does not fit has
   already been stored, so a source that fills the segment stops with a bounds
   trap naming this compiler instead of a compile error naming the source.  Every
   write into dat goes through here for that reason. */
long dput(long b){
    if(datlen >= DATMAX){ fail("data segment overflow: the source is too large"); }
    dat[datlen] = (char)band(b,255); datlen = datlen + 1; return 0;
}

long datstr(long usem,long n){
    long o; long i;
    datmark = datlen;
    while((datlen % 8) != 0){ dput(0); }
    i = 0;
    while(i < 8){ dput(band(n >> (i*8),255)); i = i + 1; }
    o = datlen;
    i = 0;
    while(i < n){
        if(usem){ dput((long)(unsigned char)mbuf[i]); } else { dput((long)(unsigned char)tbuf[i]); }
        i = i + 1;
    }
    dput(0);
    return o;
}

/* The IEEE-754 bits of m * 10^ex.  Powers of ten up to 1e22 are exact in a
   double, so a literal with at most 18 significant digits rounds once. */
union dbl { double d; long l; };
long realbits(long m,long ex){
    union dbl u; double p; long k;
    p = 1.0;
    k = ex; if(k < 0){ k = 0 - k; }
    while(k > 0){ p = p * 10.0; k = k - 1; }
    u.d = (double)m;
    if(ex < 0){ u.d = u.d / p; } else { u.d = u.d * p; }
    return u.l;
}

long next(){
    long c; long d; long n; long i; long m; long nd; long ex; long isreal; long esign; long ev;
    while(1){
        if(pos >= srcend){
            if(incdepth == 0){ tok = TK_EOF; return 0; }
            incdepth = incdepth - 1;
            pos = incpos[incdepth]; srcend = incend[incdepth];
            line = incline[incdepth]; curfile = incfile[incdepth];
            continue;
        }
        c = srcb(pos);
        if(c == 10){ line = line + 1; pos = pos + 1; }
        else if(c==32 || c==9 || c==13){ pos = pos + 1; }
        /* A brace is not a comment.  { } used to open one and it ended at the FIRST
           closing brace, so a brace inside the text -- a JSON example, an f-string,
           the words "default {}" -- ended the comment early and the rest of the
           sentence was read as code.  The error then landed far from its cause, on a
           line that looked correct. */
        else if(c == 123){ fail("{ } is not a comment; use // to the end of the line"); }
        else if(c==47 && pos+1<srcend && srcb(pos+1)==47){   /* // */
            while(pos < srcend && srcb(pos) != 10){ pos = pos + 1; }
        }
        else { break; }
    }
    c = srcb(pos);
    if(isal(c)){
        n = 0;
        while(pos < srcend && (isal(srcb(pos)) || isdg(srcb(pos)))){
            if(n >= TBMAX-1){ fail("identifier too long"); }
            obuf[n] = (char)srcb(pos);
            tbuf[n] = (char)lower(srcb(pos));
            n = n + 1; pos = pos + 1;
        }
        tbuf[n] = 0; obuf[n] = 0;
        tok = keyword();
        /* a dotted name is one identifier: net.socket, Rpc.method */
        if(tok == TK_ID){
            while(pos+1 < srcend && srcb(pos) == 46 && (isal(srcb(pos+1)) || isdg(srcb(pos+1)))){
                if(n >= TBMAX-2){ fail("identifier too long"); }
                tbuf[n] = 46; obuf[n] = 46; n = n + 1; pos = pos + 1;
                while(pos < srcend && (isal(srcb(pos)) || isdg(srcb(pos)))){
                    if(n >= TBMAX-1){ fail("identifier too long"); }
                    obuf[n] = (char)srcb(pos);
                    tbuf[n] = (char)lower(srcb(pos));
                    n = n + 1; pos = pos + 1;
                }
            }
            tbuf[n] = 0; obuf[n] = 0;
        }
        return 0;
    }
    if(isdg(c)){
        tval = 0;
        if(c==48 && pos+1<srcend && lower(srcb(pos+1))==120){
            pos = pos + 2;
            if(!ishx(srcb(pos))){ fail("malformed hex literal"); }
            while(pos < srcend && ishx(srcb(pos))){
                d = lower(srcb(pos));
                if(d >= 97){ d = d - 87; } else { d = d - 48; }
                tval = tval*16 + d;
                pos = pos + 1;
            }
        } else {
            m = 0; nd = 0; ex = 0;
            while(pos < srcend && isdg(srcb(pos))){
                d = srcb(pos) - 48;
                tval = tval*10 + d;
                if(nd < 18){ m = m*10 + d; if(m != 0){ nd = nd + 1; } } else { ex = ex + 1; }
                pos = pos + 1;
            }
            isreal = 0;
            if(pos+1 < srcend && srcb(pos) == 46 && isdg(srcb(pos+1))){
                isreal = 1;
                pos = pos + 1;
                while(pos < srcend && isdg(srcb(pos))){
                    d = srcb(pos) - 48;
                    if(nd < 18){ m = m*10 + d; if(m != 0){ nd = nd + 1; } ex = ex - 1; }
                    pos = pos + 1;
                }
            }
            if(pos+1 < srcend && lower(srcb(pos)) == 101
               && (isdg(srcb(pos+1)) || ((srcb(pos+1) == 43 || srcb(pos+1) == 45) && pos+2 < srcend && isdg(srcb(pos+2))))){
                isreal = 1;
                pos = pos + 1;
                esign = 1;
                if(srcb(pos) == 45){ esign = 0-1; pos = pos + 1; }
                else if(srcb(pos) == 43){ pos = pos + 1; }
                ev = 0;
                while(pos < srcend && isdg(srcb(pos))){
                    if(ev < 100000){ ev = ev*10 + (srcb(pos) - 48); }
                    pos = pos + 1;
                }
                ex = ex + esign*ev;
            }
            if(isreal){
                tval = realbits(m,ex);
                tok = TK_REAL;
                return 0;
            }
        }
        tok = TK_INT;
        return 0;
    }
    if(c == 39){                                   /* 'c' */
        pos = pos + 1;
        if(pos >= srcend){ fail("unterminated char literal"); }
        d = srcb(pos); pos = pos + 1;
        if(d == 92){ d = escape(srcb(pos)); pos = pos + 1; }
        if(pos >= srcend || srcb(pos) != 39){ fail("unterminated char literal"); }
        pos = pos + 1;
        tval = d; tok = TK_CHR;
        return 0;
    }
    if(c == 34){                                   /* "text" */
        pos = pos + 1;
        n = 0;
        while(1){
            if(pos >= srcend){ fail("unterminated string literal"); }
            d = srcb(pos);
            if(d == 34){ pos = pos + 1; break; }
            if(d == 10){ fail("newline in string literal"); }
            if(d == 92){ pos = pos + 1; d = escape(srcb(pos)); }
            if(n >= TBMAX-1){ fail("string literal too long"); }
            tbuf[n] = (char)d; n = n + 1; pos = pos + 1;
        }
        tval = datstr(0,n);
        tok = TK_STR;
        return 0;
    }
    pos = pos + 1;
    if(c==58 && pos<srcend && srcb(pos)==61){ pos=pos+1; tok=TK_ASSIGN; return 0; }
    if(c==60 && pos<srcend && srcb(pos)==62){ pos=pos+1; tok=TK_NE; return 0; }
    if(c==60 && pos<srcend && srcb(pos)==61){ pos=pos+1; tok=TK_LE; return 0; }
    if(c==62 && pos<srcend && srcb(pos)==61){ pos=pos+1; tok=TK_GE; return 0; }
    if(c==46 && pos<srcend && srcb(pos)==46){ pos=pos+1; tok=TK_RANGE; return 0; }
    if(c==40||c==41||c==91||c==93||c==44||c==59||c==58||c==46||c==43||c==45||c==42||c==47||c==61||c==60||c==62||c==63){
        tok = c; return 0;
    }
    fail("illegal character");
    return 0;
}

long expect(long t,char *what){
    if(tok != t){ fail(what); }
    next();
    return 0;
}

/* ------------------------------------------------------------------ */
/* schema declarations                                                 */
/* ------------------------------------------------------------------ */
/* A schema is a record type plus a generated parser, writer and JSON
   Schema text.  Everything below produces Wantzel source that is compiled
   through the include mechanism, so the code generator itself needs no
   knowledge of JSON. */
#define MAXFLD  128
#define MAXENUM 1024
#define MAXS    512
#define JSMAX   4194304
#define SF_INT   1
#define SF_BOOL  2
#define SF_TEXT  3     /* a view into the parsed buffer */
#define SF_JSON  4     /* any value, as a view */
#define SF_ENUM  5     /* text of (...) -> int */
#define SF_REAL  6
#define SF_TEXTN 7     /* text[N]: an unescaped copy */
#define SF_SUB   8     /* a nested schema */

char schname[64];
char sfld[MAXFLD*64];
char sfjson[MAXFLD*64];
long sftype[MAXFLD], sfopt[MAXFLD], sfe0[MAXFLD], sfen[MAXFLD];
long sfarr[MAXFLD], sfcount[MAXFLD], sftlen[MAXFLD], sfsub[MAXFLD], sfdesc[MAXFLD];
long nfld;
char senum[MAXENUM*64];
long nenum;
char scnam[MAXS*64];        /* declared schemas, for nesting */
long scjs[MAXS];            /* data offset of each schema's JSON Schema text */
long nsc;
char jsbuf[JSMAX]; long jslen;

/* ------------------------------------------------------------------ */
/* source files and includes                                           */
/* ------------------------------------------------------------------ */
/* record the name currently in pathbuf, return its file index */
/* st_dev and st_ino identify a file UNIQUELY, whichever path you reach it by.  This
   bootstrap uses libc (stat), where src/wantzel.wz makes the raw syscall and reads the
   struct at byte offsets -- same data, different route. */
static struct stat stx;
long stt(long a){ return stat((char*)a, &stx) == 0 ? 0 : -1; }
long stfield(long at){ return at == 0 ? (long)stx.st_dev : (long)stx.st_ino; }

long addfile(){
    long i;
    if(nfiles >= 1024){ fail("too many source files"); }
    filenam[nfiles] = fnplen;
    i = 0;
    while(pathbuf[i] != 0){
        if(fnplen >= FNPMAX){ fail("source file name pool overflow: too many or too long source paths"); }
        fnpool[fnplen] = pathbuf[i]; fnplen = fnplen + 1; i = i + 1; }
    filelen[nfiles] = i;
    fdev[nfiles] = 0; fino[nfiles] = 0;
    if(stt((long)&pathbuf[0]) >= 0){ fdev[nfiles] = stfield(0); fino[nfiles] = stfield(8); }
    if(fnplen >= FNPMAX){ fail("source file name pool overflow: too many or too long source paths"); }
    fnpool[fnplen] = 0; fnplen = fnplen + 1;
    nfiles = nfiles + 1;
    return nfiles - 1;
}

/* is the name in pathbuf the name of file fi? */
long samefile(long fi){
    long i;
    /* On IDENTITY and not on the path string: that way lib/io.wz is the same file as
       ../../elsewhere/lib/io.wz, while a test called kv.wz is something other than the
       library kv.wz.  Falls back to the string comparison when stat fails. */
    if(stt((long)&pathbuf[0]) >= 0){
        if(fdev[fi] != 0 || fino[fi] != 0){
            return (fdev[fi] == stfield(0)) && (fino[fi] == stfield(8));
        }
    }
    i = 0;
    while(1){
        if(fnpool[filenam[fi]+i] != pathbuf[i]){ return 0; }
        if(pathbuf[i] == 0){ return 1; }
        i = i + 1;
    }
    return 0;
}

/* read the file named in pathbuf onto the end of src; -1 if it will not open */
long readfile(){
    long fd; long n; long start;
    fd = opn((long)&pathbuf[0],0,0);
    if(fd < 0){ return -1; }
    start = srclen;
    while(1){
        if(srclen + 65536 > SRCMAX){ cls(fd); fail("source is too large"); }
        n = rdbuf(fd,(long)&src[srclen],65536);
        if(n <= 0){ break; }
        srclen = srclen + n;
    }
    cls(fd);
    return srclen - start;
}

/* pathbuf := directory of the current file + the name stored at dat[doff] */
long makepath(long doff){
    long i; long cut; long n; long base;
    base = filenam[curfile];
    n = filelen[curfile];
    cut = 0; i = 0;
    while(i < n){ if(fnpool[base+i] == 47){ cut = i + 1; } i = i + 1; }
    if(dat[doff] == 47){ cut = 0; }        /* an absolute path stands alone */
    i = 0;
    while(i < cut){ pathbuf[i] = fnpool[base+i]; i = i + 1; }
    n = cut;
    i = 0;
    while(dat[doff+i] != 0){
        if(n >= 1022){ fail("include path too long"); }
        pathbuf[n] = dat[doff+i]; n = n + 1; i = i + 1;
    }
    pathbuf[n] = 0;
    return 0;
}

/* The directory the compiler itself is in plus "lib/": the search path for includes.

   THE ANCHOR IS /proc/self/exe AND NOT argv[0], counterpart of src/wantzel.wz.  argv[0]
   is whatever the caller said: started through PATH it is the bare word "wantzel" with no
   '/' in it, cut stays 0, and the search path collapses to a relative "lib/" that depends
   on the working directory.  readlink answers where the process really came from; argv[0]
   remains the fallback when it cannot (no /proc).  Counterpart of src/wantzel.wz. */
long setlibdir(char *a0){
    long i; long cut; long n;
    libdirlen = 0; i = 0; cut = 0;
    n = readlink("/proc/self/exe", selfbuf, 1023);
    if(n > 0){
        i = 0; while(i < n){ if(selfbuf[i] == 47){ cut = i + 1; } i = i + 1; }
        i = 0; while(i < cut){ libdir[i] = selfbuf[i]; i = i + 1; }
    } else {
        while(a0[i] != 0 && i < 900){ if(a0[i] == 47){ cut = i + 1; } i = i + 1; }
        i = 0; while(i < cut){ libdir[i] = a0[i]; i = i + 1; }
    }
    libdirlen = cut;
    /* If the compiler sits in .../bin/, its library belongs in .../lib/ beside it
       (prefix/bin next to prefix/lib).  Counterpart of src/wantzel.wz. */
    if(libdirlen >= 4 && libdir[libdirlen-4] == 'b' && libdir[libdirlen-3] == 'i'
       && libdir[libdirlen-2] == 'n' && libdir[libdirlen-1] == 47){ libdirlen = libdirlen - 4; }
    libdir[libdirlen] = 'l'; libdir[libdirlen+1] = 'i';
    libdir[libdirlen+2] = 'b'; libdir[libdirlen+3] = 47;
    libdirlen = libdirlen + 4;
    return 0;
}

/* "undeclared identifier", with the library that declares it when there is one.
 *
 * WHY THIS EXISTS.  Forgetting the include is the first mistake a newcomer makes, and
 * "undeclared identifier" on io.puts says nothing about where io.puts lives -- while the
 * compiler can simply look.
 *
 * The counterpart in src/wantzel.wz searches the library it CARRIES; this one has no
 * embedded copy and reads lib/ from disk, so it tests whether libdir holds a file named
 * after the part before the first dot. Same message, same effect, by the means each has.
 */
/* Not in any library: still say WHICH name. The bare message meant reading the whole
   routine to find the one identifier that was wrong. */
long laterinclude(void);

/* AND WHEN THERE IS AN INCLUDE BELOW, SAY SO. Measured over the error log: of nine logged
   "undeclared identifier" cases, SIX were the include order -- the name exists, it just
   comes later -- and NONE was a misspelling of an existing name.  The bare message is true
   and sends the reader looking for a typo that is not there.

   The compiler cannot name the file: at this point the later includes have not been read.
   Claiming "declared in model.wz" would be a guess, and a wrong guess in an error message
   costs more than no guess at all. */
void failname(void){
    wrs(2,"wantzel: "); wrname(2); wrs(2,":"); wrnum(2,line);
    wrs(2,": undeclared identifier: ");
    { long j; j = 0; while(obuf[j] != 0){ j = j + 1; } wrbuf(2,(long)(size_t)&obuf[0],j); }
    wrs(2,"\n");
    if(laterinclude() >= 0){
        wrs(2,"  there is an include further down this file; a name is only visible after the include that declares it\n");
    }
    _exit(1);
}

/* isnamech(c) -- part of a name? Letters, digits, '_' and the dot that qualifies it. */
long isnamech(char c){
    if(c >= 'a' && c <= 'z'){ return 1; }
    if(c >= 'A' && c <= 'Z'){ return 1; }
    if(c >= '0' && c <= '9'){ return 1; }
    return c == '_' || c == '.';
}

/* onetypo(a, an, at, bn) -- do `a` and src[at..at+bn] differ by at most ONE insertion,
   deletion or substitution?

   DISTANCE ONE, AND DELIBERATELY NOT MORE. Measured against the 144 real errors in the
   error log: every name a writer actually invented -- print, writeln, say, js.obj -- has
   its nearest real neighbour 3 to 5 edits away, and suggesting "Init" for "print" is
   worse than saying nothing. */
long onetypo(char *a, long an, long at, long bn){
    long i; long j; long diff;
    if(an == bn){
        diff = 0;
        i = 0;
        while(i < an){
            if(a[i] != src[at + i]){ diff = diff + 1; }
            if(diff > 1){ return 0; }
            i = i + 1;
        }
        return diff == 1;
    }
    if(an == bn + 1){
        i = 0;
        while(i < bn && a[i] == src[at + i]){ i = i + 1; }
        j = i;
        while(j < bn){
            if(a[j + 1] != src[at + j]){ return 0; }
            j = j + 1;
        }
        return 1;
    }
    if(bn == an + 1){
        i = 0;
        while(i < an && a[i] == src[at + i]){ i = i + 1; }
        j = i;
        while(j < an){
            if(a[j] != src[at + j + 1]){ return 0; }
            j = j + 1;
        }
        return 1;
    }
    return 0;
}

/* kwhere(at, upto, w) -- does the word w start exactly at `at`? */
long kwhere(long at, long upto, char *w){
    long i; long n;
    n = 0; while(w[n] != 0){ n = n + 1; }
    if(at + n > upto){ return 0; }
    i = 0;
    while(i < n){
        if(src[at + i] != w[i]){ return 0; }
        i = i + 1;
    }
    return 1;
}

/* laterinclude -- is there still an `include` ahead of us in what has been read?

   A cheap look, not a second pass: everything read so far sits in one buffer, so scanning
   from the failure point to the end of the current file walks bytes that are already there.
   It does not prove the name is in that include -- it proves the SHAPE of the problem is
   possible, which is what sends the reader to the include order instead of to a spelling
   mistake. */
long laterinclude(void){
    long i;
    i = pos;
    while(i < srcend){
        if(kwhere(i, srcend, "include")){ return i; }
        i = i + 1;
    }
    return -1;
}

/* namehere(at, upto, want, wantn) -- is exactly `want` at `at`, and nothing more?

   THE END MATTERS: without it io.put would match io.putn, and the compiler would keep
   quiet about a name that really is missing. */
long namehere(long at, long upto, char *want, long wantn){
    long i; char c;
    if(at + wantn > upto){ return 0; }
    i = 0;
    while(i < wantn){
        if(src[at + i] != want[i]){ return 0; }
        i = i + 1;
    }
    c = src[at + wantn];
    if(c >= 'a' && c <= 'z'){ return 0; }
    if(c >= 'A' && c <= 'Z'){ return 0; }
    if(c >= '0' && c <= '9'){ return 0; }
    return c != '_' && c != '.';
}

/* libdeclares(at, n, want, wantn) -- is `want` declared in the library text at
   src[at..at+n]?

   A DECLARATION POSITION, NOT ANY OCCURRENCE. The name has to follow `procedure`,
   `function`, `const`, `var` or `type` -- otherwise io.puts would "declare" itself in
   every file that CALLS it, and the answer would be yes everywhere.

   THIS IS NOT THE SEARCH THAT WAS REMOVED. That one scanned EVERY library to work out
   which file declares a name, and needed a preference rule because store.table also
   occurs in oauth.wz. This reads ONE file whose name the convention already gave us. */
long libdeclares(long at, long n, char *want, long wantn){
    long i; long j; long k; long e;
    e = at + n;
    i = at;
    while(i < e){
        while(i < e && (src[i] == ' ' || src[i] == 9)){ i = i + 1; }
        j = i;
        while(j < e && src[j] != 10){ j = j + 1; }
        k = i;
        if(kwhere(k, j, "procedure ")){ k = k + 10; }
        else if(kwhere(k, j, "function ")){ k = k + 9; }
        else if(kwhere(k, j, "const ")){ k = k + 6; }
        else if(kwhere(k, j, "var ")){ k = k + 4; }
        else if(kwhere(k, j, "type ")){ k = k + 5; }
        else { k = -1; }
        if(k >= 0){
            while(k < j && (src[k] == ' ' || src[k] == 9)){ k = k + 1; }
            if(namehere(k, j, want, wantn)){ return 1; }
        }
        i = j + 1;
    }
    return 0;
}

/* nearname(at, n, want, wantn) -- the declared name in this library that is ONE typo
   away, or 0 if there is none. Fills nearbuf.

   ONLY WITHIN THIS MODULE, which is what the compiler knows at this point anyway: the
   name before the dot picked the file. That filter is doing real work -- it is the reason
   `print` and `writeln` get no suggestion at all rather than a wrong one. */
long nearname(long at, long n, char *want, long wantn){
    long i; long j; long k; long e; long nl;
    e = at + n;
    i = at;
    while(i < e){
        while(i < e && (src[i] == ' ' || src[i] == 9)){ i = i + 1; }
        j = i;
        while(j < e && src[j] != 10){ j = j + 1; }
        k = i;
        if(kwhere(k, j, "procedure ")){ k = k + 10; }
        else if(kwhere(k, j, "function ")){ k = k + 9; }
        else if(kwhere(k, j, "const ")){ k = k + 6; }
        else if(kwhere(k, j, "var ")){ k = k + 4; }
        else if(kwhere(k, j, "type ")){ k = k + 5; }
        else { k = -1; }
        if(k >= 0){
            while(k < j && (src[k] == ' ' || src[k] == 9)){ k = k + 1; }
            nl = 0;
            while(k + nl < j && isnamech(src[k + nl])){ nl = nl + 1; }
            if(nl > 0 && onetypo(want, wantn, k, nl)){
                if(nl >= TBMAX){ return 0; }
                nearbufn = 0;
                while(nearbufn < nl){ nearbuf[nearbufn] = src[k + nearbufn]; nearbufn = nearbufn + 1; }
                return nearbufn;
            }
        }
        i = j + 1;
    }
    return 0;
}

/* failnear(n) -- "undeclared identifier: X -- did you mean Y?"

   THE NAME FIRST, THE SUGGESTION AFTER A DASH. The fact the reader needs is that X does
   not exist; the nearest name is help, not the finding. */
void failnear(long n){
    wrs(2,"wantzel: "); wrname(2); wrs(2,":"); wrnum(2,line);
    wrs(2,": undeclared identifier: ");
    { long j; j = 0; while(obuf[j] != 0){ j = j + 1; } wrbuf(2,(long)(size_t)&obuf[0],j); }
    wrs(2," -- did you mean ");
    wrbuf(2,(long)(size_t)&nearbuf[0],n);
    wrs(2,"?\n");
    _exit(1);
}

long failundeclared(void){
    long i; long n; long fd; long mark; long n2; long olen; long erin; long near;
    n = 0;
    while(tbuf[n] != 0 && tbuf[n] != '.'){ n = n + 1; }
    if(tbuf[n] != '.' || n == 0){ failname(); }
    /* pathbuf := <libdir><prefix>.wz */
    i = 0; while(i < libdirlen){ pathbuf[i] = libdir[i]; i = i + 1; }
    if(i + n + 4 >= 1022){ failname(); }
    { long j; j = 0; while(j < n){ pathbuf[i+j] = tbuf[j]; j = j + 1; } }
    i = i + n;
    pathbuf[i] = '.'; pathbuf[i+1] = 'w'; pathbuf[i+2] = 'z'; pathbuf[i+3] = 0;
    fd = (long)open(pathbuf, 0, 0);
    if(fd < 0){ failname(); }
    close((int)fd);
    /* THE FILE EXISTS -- BUT IS IT ALREADY INCLUDED? Then this name is NOT in it, and the
       suggestion would be wrong twice over: wrong about where the name lives, and wrong
       about what to do, because the include is already there.

       MEASURED 18-09-2026: io.putc does not exist, io.wz was included three
       lines above, and the compiler answered "io.putc is declared in io.wz; add: include
       "io.wz";". An agent adds the include it already has, recompiles, gets the identical
       error, and loops.

       pathbuf holds the library path right now, which is what samefile compares against. */
    /* THE FILE EXISTS -- BUT IS THE NAME IN IT? That is the question the old code never
       asked, and it is the whole bug. Asking about the name answers both halves at once,
       whether or not the file is already included.

       The text is read and then dropped: srclen goes back to where it was. */
    olen = 0;
    while(obuf[olen] != 0){ olen = olen + 1; }
    mark = srclen;
    n2 = readfile();
    if(n2 > 0){
        erin = libdeclares(mark, n2, obuf, olen);
        if(!erin){
            near = nearname(mark, n2, obuf, olen);
            srclen = mark;
            if(near > 0){ failnear(near); }
            failname();
        }
        srclen = mark;
    } else { srclen = mark; }
    wrs(2,"wantzel: "); wrname(2); wrs(2,":"); wrnum(2,line);
    wrs(2,": undeclared identifier: ");
    { long j; j = 0; while(obuf[j] != 0){ j = j + 1; } wrbuf(2,(long)(size_t)&obuf[0],j); }
    wrs(2," is declared in ");
    wrbuf(2,(long)(size_t)&tbuf[0],n); wrs(2,".wz; add: include \"");
    wrbuf(2,(long)(size_t)&tbuf[0],n); wrs(2,".wz\";\n");
    _exit(1);
    return 0;
}

/* does the name from the include contain a '/'? then it is a path, not a library name */
long haspath(long doff){
    long i;
    i = 0;
    while(dat[doff+i] != 0){ if(dat[doff+i] == 47){ return 1; } i = i + 1; }
    return 0;
}

/* pathbuf := <search path>/<name from the include> */
long makelibpath(long doff){
    long i; long n;
    n = 0;
    while(n < libdirlen){ pathbuf[n] = libdir[n]; n = n + 1; }
    i = 0;
    while(dat[doff+i] != 0){
        if(n >= 1022){ fail("include path too long"); }
        pathbuf[n] = dat[doff+i]; n = n + 1; i = i + 1;
    }
    pathbuf[n] = 0;
    return 0;
}

/* does pathbuf exist? */
long fileexists(){
    long fd;
    fd = opn((long)&pathbuf[0],0,0);
    if(fd < 0){ return 0; }
    cls(fd);
    return 1;
}

/* pathbuf opschonen: "a/./b" -> "a/b", "a/x/../b" -> "a/b" */
long normpath(){
    long i; long n; long w; long seg;
    n = 0; while(pathbuf[n] != 0){ n = n + 1; }
    w = 0; i = 0;
    while(i < n){
        if(pathbuf[i] == 46 && i + 1 < n && pathbuf[i+1] == 47 && (w == 0 || pathbuf[w-1] == 47)){
            i = i + 2;
        } else if(pathbuf[i] == 46 && i + 2 < n && pathbuf[i+1] == 46 && pathbuf[i+2] == 47
                  && (w == 0 || pathbuf[w-1] == 47)){
            seg = 0;
            if(w >= 2){
                seg = w - 1;
                while(seg > 0 && pathbuf[seg-1] != 47){ seg = seg - 1; }
                if(w - seg == 3 && pathbuf[seg] == 46 && pathbuf[seg+1] == 46){ seg = 0; }
            }
            if(seg > 0){ w = seg; i = i + 3; }
            else { pathbuf[w] = pathbuf[i]; w = w + 1; i = i + 1; }
        } else { pathbuf[w] = pathbuf[i]; w = w + 1; i = i + 1; }
    }
    pathbuf[w] = 0;
    return 0;
}

long doinclude(){
    long doff; long i; long fi; long n; long start;
    next();
    if(tok != TK_STR){ fail("include needs a file name in quotes"); }
    doff = tval;
    next();
    if(tok != 59){ fail("missing ; after include"); }
    /* A BARE NAME is a library name, a name with a '/' is a path.
       Counterpart of src/wantzel.wz. */
    triedlibn = 0;
    if(haspath(doff)){ makepath(doff); }
    else {
        makelibpath(doff);
        /* keep the library path before makepath writes the relative name over it */
        if(!fileexists()){
            while(pathbuf[triedlibn] != 0 && triedlibn < 1023){
                triedlib[triedlibn] = pathbuf[triedlibn]; triedlibn = triedlibn + 1;
            }
            triedlib[triedlibn] = 0;
            makepath(doff);
        }
    }
    normpath();
    datlen = datmark;                 /* the path is not program data */
    i = 0;
    while(i < nfiles){
        if(samefile(i)){ break; }
        i = i + 1;
    }
    if(i < nfiles){ next(); return 0; }          /* already included */
    if(incdepth >= 16){ fail("includes nested too deeply"); }
    fi = addfile();
    incpos[incdepth] = pos; incend[incdepth] = srcend;
    incline[incdepth] = line; incfile[incdepth] = curfile;
    incdepth = incdepth + 1;
    start = srclen;
    n = readfile();
    /* NAMING THE PATH IT TRIED, not just "cannot open": a bare library name is resolved
       against <compiler dir>/lib/ first, so the path attempted is not what is written on
       the line. The counterpart in src/wantzel.wz is failinclude. */
    if(n < 0){
        long q;
        wrs(2,"wantzel: "); wrname(2); wrs(2,":"); wrnum(2,line);
        wrs(2,": cannot open the included file: ");
        q = 0; while(pathbuf[q] != 0){ q = q + 1; }
        wrbuf(2,(long)(size_t)&pathbuf[0],q);
        if(triedlibn > 0){
            wrs(2,"\n  looked in the library first: ");
            wrbuf(2,(long)(size_t)&triedlib[0],triedlibn);
        }
        wrs(2,"\n");
        _exit(1);
    }
    pos = start; srcend = start + n; line = 1; curfile = fi;
    next();
    return 0;
}

/* ------------------------------------------------------------------ */
/* symbol tables                                                       */
/* ------------------------------------------------------------------ */
long intern(){
    long o; long i;
    o = namelen;
    i = 0;
    while(tbufb(i) != 0){
        if(namelen >= NAMEMAX){ fail("name pool overflow: the source is too large"); }
        names[namelen] = tbuf[i]; namelen = namelen + 1; i = i + 1;
    }
    if(namelen >= NAMEMAX){ fail("name pool overflow: the source is too large"); }
    names[namelen] = 0; namelen = namelen + 1;
    return o;
}

/* does the interned name at off equal the identifier in tbuf? */
long nameq(long off){
    long i;
    i = 0;
    while(1){
        if(namesb(off+i) != tbufb(i)){ return 0; }
        if(tbufb(i) == 0){ return 1; }
        i = i + 1;
    }
    return 0;
}

long findloc(){
    long i;
    i = nloc - 1;
    while(i >= 0){
        if(nameq(lnam[i])){ return i; }
        i = i - 1;
    }
    return -1;
}

/* The hash of the identifier now in tbuf.  Identifiers are lowercased on the way into
   tbuf (see the lexer), so this hashes the same bytes nameq compares and the index
   inherits the case-insensitivity instead of having to repeat it.

   FNV-1a, which is a multiply and an xor per byte and needs no table.  The result is
   masked into a bucket, never used as an identity: every hit is still confirmed with
   nameq, so a collision costs a comparison and never a wrong answer. */
long tokhash(){
    long h; long i; long c;
    h = 2166136261L;
    i = 0;
    while(1){
        c = tbufb(i);
        if(c == 0){ return h & HMASK; }
        h = h ^ c;
        h = (h * 16777619L) & 4294967295L;
        i = i + 1;
    }
    return h & HMASK;
}

/* The same hash, over a name already in the pool rather than the token in tbuf.  Two
   entry points because a name is sometimes added straight from the token and sometimes
   from an offset interned earlier; they must agree byte for byte or a name would be
   filed in one bucket and sought in another. */
long namehash(long off){
    long h; long i; long c;
    h = 2166136261L;
    i = 0;
    while(1){
        c = namesb(off + i);
        if(c == 0){ return h & HMASK; }
        h = h ^ c;
        h = (h * 16777619L) & 4294967295L;
        i = i + 1;
    }
    return h & HMASK;
}

/* Fill the buckets with -1 the first time anything is looked up or added.  Doing it
   here rather than in an init routine keeps the change to the lookup path only. */
void hashinit(){
    long i;
    if(hashed){ return; }
    i = 0;
    while(i < NHASH){
        ghead[i] = -1;
        fhead[i] = -1;
        i = i + 1;
    }
    hashed = 1;
}

/* File global g, whose name is already in gnam[g], in its bucket.  Called right after
   the entry is filled in and before ngl moves on. */
void gindex(long g){
    long b;
    hashinit();
    b = namehash(gnam[g]);
    gnext[g] = ghead[b];
    ghead[b] = g;
}

/* The same for routine f. */
void findex(long f){
    long b;
    hashinit();
    b = namehash(fnam[f]);
    fnext[f] = fhead[b];
    fhead[b] = f;
}

/* Walk only the names that hash to the same bucket, newest first.  That order is the
   one the old linear scan had (it counted down from ngl - 1), and it is kept although
   nothing depends on it any more: a duplicate global is refused at declaration, so a
   name is in here at most once. */
long findglob(){
    long i;
    hashinit();
    i = ghead[tokhash()];
    while(i >= 0){
        /* A local name from another file does not exist here. */
        if(nameq(gnam[i]) && (gfile[i] < 0 || gfile[i] == curfile)){ return i; }
        i = gnext[i];
    }
    return -1;
}

long findfn(){
    long i;
    hashinit();
    i = fhead[tokhash()];
    while(i >= 0){
        /* A local routine from another file does not exist here. */
        if(nameq(fnam[i]) && (fvis[i] < 0 || fvis[i] == curfile)){ return i; }
        i = fnext[i];
    }
    return -1;
}

long tsize(long t){
    if(t==T_CHAR || t==T_BOOL){ return 1; }
    if(t >= T_REC){ return rtsize[t-T_REC]; }
    return 8;
}

long findtype(){
    long i;
    i = nrt - 1;
    while(i >= 0){
        if(nameq(rtnam[i])){ return i; }
        i = i - 1;
    }
    return -1;
}

/* Split the dotted identifier in tbuf into the longest prefix that names a
   variable and a residual field path, which lands in fpath.  Returns the
   local index in spli / global index in spgi, or 0 when nothing matches. */
long spli, spgi;
long splitname(){
    long k; long i;
    fplen = 0;
    k = 0;
    while(tbuf[k] != 0){ k = k + 1; }
    k = k - 1;
    while(k > 0){
        if(tbuf[k] == 46){
            tbuf[k] = 0;
            spli = findloc(); spgi = -1;
            if(spli < 0){ spgi = findglob(); }
            if(spli >= 0 || spgi >= 0){
                i = k + 1;
                while(tbuf[i] != 0){ fpath[fplen] = tbuf[i]; fplen = fplen + 1; i = i + 1; }
                fpath[fplen] = 0;
                tbuf[k] = 46;
                return 1;
            }
            tbuf[k] = 46;
        }
        k = k - 1;
    }
    return 0;
}

/* the field of record type t whose name is fpath[a..b) */
long findfield(long t,long a,long b){
    long r; long f; long i; long ok;
    r = t - T_REC;
    f = rtf0[r];
    while(f < rtf0[r] + rtnf[r]){
        ok = 1;
        i = 0;
        while(i < b - a){
            if(namesb(fdnam[f]+i) != (long)(unsigned char)fpath[a+i]){ ok = 0; break; }
            i = i + 1;
        }
        if(ok && namesb(fdnam[f]+(b-a)) == 0){ return f; }
        f = f + 1;
    }
    fail("no such field in this record");
    return -1;
}

char *tname(long t){
    if(t >= T_REC){ return "record"; }
    if(t == T_INT){ return "int"; }
    if(t == T_CHAR){ return "char"; }
    if(t == T_BOOL){ return "bool"; }
    if(t == T_STR){ return "str"; }
    if(t == T_REAL){ return "real"; }
    return "void";
}

/* ---- the debug sidecar: text into dbg, written by writedbg once the addresses are known */
long dbc(long c){
    if(dbglen >= DBGMAX){ fail("debug information overflow"); }
    dbg[dbglen] = (char)band(c,255);
    dbglen = dbglen + 1;
    return 0;
}
long dbs(char *s){ long i; i = 0; while(sch(s,i) != 0){ dbc(sch(s,i)); i = i + 1; } return 0; }
long dbnum(long v){ long n; long i; n = numstr(v); i = 0; while(i < n){ dbc((long)(unsigned char)nbuf[i]); i = i + 1; } return 0; }
long dbnam(long off){ while(namesb(off) != 0){ dbc(namesb(off)); off = off + 1; } return 0; }
/* a type word: int, char, bool, real, str, void, or the name of a record type */
long dbtype(long t){ if(t >= T_REC){ dbnam(rtnam[t - T_REC]); } else { dbs(tname(t)); } return 0; }
/* the six fields every variable-like record carries: name, where, type, arr, lo, hi */
long dbvar(char *kind,long nam,long where,long t,long arr,long lo,long hi){
    dbs(kind); dbc(32); dbnam(nam); dbc(32); dbnum(where); dbc(32); dbtype(t); dbc(32);
    dbnum(arr); dbc(32);
    if(arr == 1){ dbnum(lo); dbc(32); dbnum(hi); } else { dbs("0 0"); }
    dbc(10);
    return 0;
}
/* a line-table entry for the code about to be emitted: kind is 's', 'p' or 'e' */
long dbline(long kind){
    if(dbgmode == 0){ return 0; }
    dbs("line "); dbnum(codebase + codelen); dbc(32); dbnum(curfile); dbc(32); dbnum(line);
    dbc(32); dbc(kind); dbc(10);
    return 0;
}
/* the func record of routine fi and its parameters and locals, while they still exist */
long dbfunc(long fi,long np,long t){
    long i;
    if(dbgmode == 0){ return 0; }
    dbs("func "); dbnam(fnam[fi]); dbc(32); dbnum(codebase + fadr[fi]); dbc(32);
    dbnum(codebase + fend[fi]); dbc(32); dbnum(fhfile[fi]); dbc(32); dbnum(fhline[fi]);
    dbc(32); dbnum(frame); dbc(32); dbtype(t); dbc(10);
    i = 0;
    while(i < nloc){
        if(lkind[i] == SK_VAR){
            if(i < np){ dbvar("param",lnam[i],loff[i],ltyp[i],larr[i],0,0); }
            else { dbvar("local",lnam[i],loff[i],ltyp[i],larr[i],llo[i],lhi[i]); }
        }
        i = i + 1;
    }
    return 0;
}

long want(long got,long need,char *ctx){
    if(got != need){
        wrs(2,"wantzel: "); wrname(2); wrs(2,":"); wrnum(2,line);
        wrs(2,": type error in "); wrs(2,ctx);
        wrs(2,": expected "); wrs(2,tname(need));
        wrs(2,", found "); wrs(2,tname(got)); wrs(2,"\n");
        _exit(1);
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* code emission                                                       */
/* ------------------------------------------------------------------ */
long e(long b){
    if(codelen >= CODEMAX){ fail("code segment overflow"); }
    code[codelen] = (char)band(b,255);
    codelen = codelen + 1;
    return 0;
}
long e32at(long o,long v){
    code[o]   = (char)band(v,255);
    code[o+1] = (char)band(v>>8,255);
    code[o+2] = (char)band(v>>16,255);
    code[o+3] = (char)band(v>>24,255);
    return 0;
}
long e32(long v){ e(v); e(v>>8); e(v>>16); e(v>>24); return 0; }
long e64(long v){ e32(v); e32(v>>32); return 0; }

long fixup(long kind,long val){
    if(nfx >= MAXFIX){ fail("too many relocations"); }
    fxoff[nfx] = codelen; fxkind[nfx] = kind; fxval[nfx] = val;
    nfx = nfx + 1;
    return 0;
}

/* mov rax, <constant> -- in the shortest encoding that fits */
long imm(long v){
    if(v == 0){ e(0x31); e(0xC0); return 0; }                 /* xor eax,eax  */
    if(v > 0 && v < 2147483648){ e(0xB8); e32(v); return 0; } /* mov eax,imm32 */
    if(v < 0 && v >= 0-2147483648){ e(0x48); e(0xC7); e(0xC0); e32(v); return 0; }
    e(0x48); e(0xB8); e64(v);                                 /* movabs        */
    return 0;
}
/* mov rax, <address of data offset o> */
long immdata(long o){ e(0x48); e(0xB8); fixup(FX_DATA,o); e64(0); return 0; }
/* mov rax, <address of bss offset o> */
long immbss(long o){ e(0x48); e(0xB8); fixup(FX_BSS,o); e64(0); return 0; }

long push(){ e(0x50); return 0; }             /* push rax          */
long popc(){ e(0x59); return 0; }             /* pop rcx           */
long xchgac(){ e(0x48); e(0x89); e(0xC1); e(0x58); return 0; } /* mov rcx,rax ; pop rax */

/* jump helpers: emit with empty target, patch later */
long jfwd(long op1,long op2){
    long o;
    if(op1 != 0){ e(op1); }
    e(op2); o = codelen; e32(0);
    return o;
}
long patch(long o){ e32at(o,codelen - (o+4)); return 0; }
long jmpto(long op1,long op2,long target){
    if(op1 != 0){ e(op1); }
    e(op2); e32(target - (codelen+4));
    return 0;
}

/* rax := scalar variable */
long loadlocal(long off,long t){
    if(tsize(t) == 1){ e(0x48); e(0x0F); e(0xB6); e(0x85); }  /* movzx rax,byte[rbp+off] */
    else { e(0x48); e(0x8B); e(0x85); }                       /* mov   rax,[rbp+off]     */
    e32(off);
    return 0;
}
long loadglobal(long off,long t){
    if(tsize(t) == 1){ e(0x48); e(0x0F); e(0xB6); e(0x04); e(0x25); }
    else { e(0x48); e(0x8B); e(0x04); e(0x25); }
    fixup(FX_BSS32,off); e32(0);
    return 0;
}
/* scalar variable := rax */
long storelocal(long off,long t){
    if(tsize(t) == 1){ e(0x88); e(0x85); }                    /* mov [rbp+off],al  */
    else { e(0x48); e(0x89); e(0x85); }                       /* mov [rbp+off],rax */
    e32(off);
    return 0;
}
long storeglobal(long off,long t){
    if(tsize(t) == 1){ e(0x88); e(0x04); e(0x25); }
    else { e(0x48); e(0x89); e(0x04); e(0x25); }
    fixup(FX_BSS32,off); e32(0);
    return 0;
}

long lea_local(long off){ e(0x48); e(0x8D); e(0x85); e32(off); return 0; }  /* lea rax,[rbp+off] */

/* load rax from the address in rax, for a value of type t */
long loadind(long t){
    if(tsize(t) == 1){ e(0x48); e(0x0F); e(0xB6); e(0x00); }   /* movzx rax,byte[rax] */
    else { e(0x48); e(0x8B); e(0x00); }                        /* mov rax,[rax]       */
    return 0;
}
/* store rax at the address in rcx */
long storeind(long t){
    if(tsize(t) == 1){ e(0x88); e(0x01); }                     /* mov [rcx],al */
    else { e(0x48); e(0x89); e(0x01); }                        /* mov [rcx],rax */
    return 0;
}

/* --- real arithmetic ------------------------------------------------
   A real travels in rax as its 64-bit pattern, so every path that moves
   an int (stack, registers, memory, calls) moves a real unchanged.  Only
   the operations themselves go through xmm0/xmm1. */
long xmm0rax(){ e(0x66); e(0x48); e(0x0F); e(0x6E); e(0xC0); return 0; }   /* movq xmm0,rax */
long xmm1rcx(){ e(0x66); e(0x48); e(0x0F); e(0x6E); e(0xC9); return 0; }   /* movq xmm1,rcx */
long raxxmm0(){ e(0x66); e(0x48); e(0x0F); e(0x7E); e(0xC0); return 0; }   /* movq rax,xmm0 */
/* rax := rax <op> rcx for reals; op is the SSE opcode byte */
long realop(long op){
    xmm0rax(); xmm1rcx();
    e(0xF2); e(0x0F); e(op); e(0xC1);
    raxxmm0();
    return 0;
}

/* A system call: rax holds the Linux number, rdi..r9 the arguments, and the
   SYSCALL instruction is emitted literally. */
long syscallinsn(){
    e(0x0F); e(0x05);
    return 0;
}

/* emit the shared trap routine: rdi = message, rsi = length */
/* Two writes to stderr and then exit(1). The caller passes the shared heading in rdi/rsi and
   the file-and-line in rdx/rcx -- splitting the sentence is what keeps one copy of
   "runtime error: array index out of range" instead of one per check. */
long emittrap(){
    trapaddr = codelen;
    e(0x52);                                /* push rdx      */
    e(0x51);                                /* push rcx      */
    e(0x48); e(0x89); e(0xF2);              /* mov rdx,rsi   */
    e(0x48); e(0x89); e(0xFE);              /* mov rsi,rdi   */
    imm(2); e(0x48); e(0x89); e(0xC7);      /* mov rdi,2     */
    imm(1);                                 /* mov rax,1     */
    syscallinsn();                          /* syscall       */
    e(0x59);                                /* pop rcx       */
    e(0x5A);                                /* pop rdx       */
    e(0x48); e(0x89); e(0xD6);              /* mov rsi,rdx   */
    e(0x48); e(0x89); e(0xCA);              /* mov rdx,rcx   */
    imm(2); e(0x48); e(0x89); e(0xC7);      /* mov rdi,2     */
    imm(1);
    syscallinsn();
    imm(1); e(0x48); e(0x89); e(0xC7);      /* mov rdi,1     */
    imm(231);                               /* exit_group    */
    syscallinsn();
    return 0;
}

long mcat(char *s){
    long i;
    i = 0;
    while(i < slen(s)){ mbuf[mlen] = s[i]; mlen = mlen + 1; i = i + 1; }
    return 0;
}

long eqstr(char *a, char *b){
    long i;
    if(slen(a) != slen(b)) return 0;
    i = 0;
    while(i < slen(a)){ if(a[i] != b[i]) return 0; i = i + 1; }
    return 1;
}

/* The fixed heading for a kind of check -- "runtime error: ... at " -- stored once and
   reused. Returns its index in the table. */
long trapheading(char *msg){
    long i; long o;
    i = 0;
    while(i < ntph){ if(eqstr(tphtxt[i], msg)) return i; i = i + 1; }
    if(ntph >= 16) return -1;
    mlen = 0;
    mcat("runtime error: "); mcat(msg); mcat(" at ");
    o = datstr(1,mlen);
    tphoff[ntph] = o; tphlen[ntph] = mlen; tphtxt[ntph] = msg;
    ntph = ntph + 1;
    return ntph - 1;
}

/* Two writes rather than one: the heading, which every check of this kind shares, and the
   place, which differs per check. Storing the whole sentence per check made the messages a
   quarter of a large binary. */
/* trapskip(fi) -- where the name of file fi starts, for a message stored IN THE BINARY.

   THE PROBLEM THIS SOLVES. trap embeds "<file>:<line>" as a string in the output, and the
   file name used to be whatever the compiler had resolved. So the same source compiled to
   two different binaries:

       wantzel src/main.wz out                  ->  "src/main.wz:101"
       wantzel /abs/path/to/src/main.wz out     ->  "/abs/path/to/src/main.wz:101"

   Measured on 16-09-2026 in a large program with 1288 checks: 513024 bytes against 581632,
   a 68KB difference out of identical source. Two things are wrong with that. A build is
   supposed to be reproducible, and it was not -- a build server naming its sources
   absolutely cannot produce the artifact a developer verified. And the second is worse:
   the build machine's directory layout, including a user's home directory, ends up inside
   every executable anyone ships. The embedded LIBRARY files leaked it either way, because
   they are named <libdir>/<name> and libdir is found from /proc/self/exe.

   THE RULE IS THE LAST TWO SEGMENTS OF THE DIRECTORY, AT MOST. A diagnostic has to say
   which file and which line; what it does not have to say is where the tree was checked
   out. "src/ui/main.wz:412" and "lib/io.wz:88" point a reader at the right file in the
   project, and carry nothing about the machine that built it.

   WHY SEGMENTS AND NOT A COMMON PREFIX, which is what I tried first: the main file can sit
   DEEPER than its includes (src/ui/main.wz including src/agent.wz), so stripping the
   main file's directory strips nothing from the ones that matter. Counting from the END is
   independent of which file is the entry point, which is the property that was missing. */
long trapskip(long fi){
    long i; long n; long seg;
    n = filelen[fi];
    /* Count directory separators backwards, and stop after two. A name with fewer is
       already short enough to embed whole. */
    seg = 0;
    i = n - 1;
    while(i >= 0){
        if(fnpool[filenam[fi]+i] == 47){
            seg = seg + 1;
            if(seg >= 3){ return i + 1; }
        }
        i = i - 1;
    }
    return 0;
}

long trap(char *msg){
    long i; long o; long k; long h; long sk;
    h = trapheading(msg);

    mlen = 0;
    sk = trapskip(curfile);
    i = sk; while(i < filelen[curfile]){ mbuf[mlen]=fnpool[filenam[curfile]+i]; mlen=mlen+1; i=i+1; }
    mbuf[mlen] = 58; mlen = mlen + 1;
    k = numstr(line);
    i = 0; while(i < k){ mbuf[mlen]=nbuf[i]; mlen=mlen+1; i=i+1; }
    mbuf[mlen] = 10; mlen = mlen + 1;

    /* THE SAME PLACE AS THE PREVIOUS CHECK?  Then reuse what is already stored. */
    if(tplast >= 0 && tplastline == line && tplastfile == curfile){
        o = tplast;
        mlen = tplastlen;
    } else {
        o = datstr(1,mlen);
        tplast = o; tplastlen = mlen; tplastline = line; tplastfile = curfile;
    }

    if(h < 0){
        /* the table is full, which needs more kinds of check than exist; fall back to the
           complete sentence so a message is never lost */
        e(0x48); e(0xBF); fixup(FX_DATA,o); e64(0);
        e(0x48); e(0xBE); e64(mlen);
        e(0xE8); e32(trapaddr - (codelen+4));
        return 0;
    }

    e(0x48); e(0xBF); fixup(FX_DATA,tphoff[h]); e64(0);   /* mov rdi,heading */
    e(0x48); e(0xBE); e64(tphlen[h]);                     /* mov rsi,len     */
    e(0x48); e(0xBA); fixup(FX_DATA,o); e64(0);           /* mov rdx,place   */
    e(0x48); e(0xB9); e64(mlen);                          /* mov rcx,len     */
    e(0xE8); e32(trapaddr - (codelen+4));                 /* call trap       */
    return 0;
}

/* ------------------------------------------------------------------ */
/* expressions                                                         */
/* ------------------------------------------------------------------ */
long expr();
long factor();
long argint();
long lparen();
long rparen();
long comma();

/* pop the i-th outgoing argument into its calling-convention register */
/* Argument registers.  The first six follow the System V order so that the
   syscall builtins share the code; r12..r15 extend it for our own calls,
   which nothing touches between the pops and the call itself. */
long popreg(long i){
    if(i==0){ e(0x5F); } else if(i==1){ e(0x5E); } else if(i==2){ e(0x5A); }
    else if(i==3){ e(0x59); } else if(i==4){ e(0x41); e(0x58); }
    else if(i==5){ e(0x41); e(0x59); }
    else if(i==6){ e(0x41); e(0x5C); } else if(i==7){ e(0x41); e(0x5D); }
    else if(i==8){ e(0x41); e(0x5E); } else { e(0x41); e(0x5F); }
    return 0;
}
/* same, for the syscall convention (arg 4 goes in r10) */
long popsys(long i){
    if(i==0){ e(0x5F); } else if(i==1){ e(0x5E); } else if(i==2){ e(0x5A); }
    else if(i==3){ e(0x41); e(0x5A); } else if(i==4){ e(0x41); e(0x58); }
    else { e(0x41); e(0x59); }
    return 0;
}

long bicode(){
    if(eqt("ord")){ return 1; }
    if(eqt("chr")){ return 2; }
    if(eqt("band")){ return 3; }
    if(eqt("bor")){ return 4; }
    if(eqt("bxor")){ return 5; }
    if(eqt("bnot")){ return 6; }
    if(eqt("len")){ return 7; }
    if(eqt("addr")){ return 8; }
    if(eqt("slen")){ return 9; }
    if(eqt("schar")){ return 10; }
    if(eqt("halt")){ return 11; }
    if(eqt("argc")){ return 12; }
    if(eqt("argch")){ return 13; }
    if(eqt("sadr")){ return 14; }
    if(eqt("scan")){ return 15; }
    if(eqt("poke")){ return 17; }
    if(eqt("peek")){ return 18; }
    if(eqt("trunc")){ return 28; }
    if(eqt("round")){ return 29; }
    if(eqt("sqrt")){ return 30; }
    if(eqt("pack32")){ return 31; }
    if(eqt("unpack32")){ return 32; }
    if(eqt("view")){ return 33; }
    if(eqt("sys1")){ return 21; }
    if(eqt("sys2")){ return 22; }
    if(eqt("sys3")){ return 23; }
    if(eqt("sys4")){ return 24; }
    if(eqt("sys5")){ return 25; }
    if(eqt("sys6")){ return 26; }
    return 0;
}

/* --- pending simple operand ----------------------------------------
   factor() records whether the value it just produced was simple enough to
   fold straight into the next instruction: a constant, or a scalar variable.
   term()/simple()/expr() can then roll the emitted code back and use an
   immediate or memory operand instead of going through push/pop. */
long lvkind, lvimm, lvoff, lvtype, lvpos, lvfx;

/* <op> rax, [scalar variable] */
long memop(long opc){
    e(0x48); e(opc);
    if(lvkind == 2){ e(0x85); e32(lvoff); }
    else { e(0x04); e(0x25); fixup(FX_BSS32,lvoff); e32(0); }
    return 0;
}
/* rcx := the pending operand */
long opintocx(){
    if(lvkind == 1){ e(0x48); e(0xC7); e(0xC1); e32(lvimm); return 0; }
    e(0x48); e(0x8B);
    if(lvkind == 2){ e(0x8D); e32(lvoff); }
    else { e(0x0C); e(0x25); fixup(FX_BSS32,lvoff); e32(0); }
    return 0;
}
long divcode(long op){
    e(0x48); e(0x99);                       /* cqo      */
    e(0x48); e(0xF7); e(0xF9);              /* idiv rcx */
    if(op == KW_MOD){ e(0x48); e(0x89); e(0xD0); }
    return 0;
}

long fold(long op);
/* roll the emitted code back to pp and fold instead; 0 if not possible */
long fold2(long op,long pp,long pf){
    long sp; long sf;
    sp = codelen; sf = nfx;
    codelen = pp; nfx = pf;
    if(fold(op)){ return 1; }
    codelen = sp; nfx = sf;
    return 0;
}

/* Fold the pending operand into rax with operator op (0 means compare).
   Returns 1 when it did so, 0 when the caller must use the register path. */
long fold(long op){
    if(lvkind == 1){
        if(lvimm < 0-2147483648 || lvimm > 2147483647){ return 0; }
        if(op == 43){ e(0x48); e(0x05); e32(lvimm); return 1; }
        if(op == 45){ e(0x48); e(0x2D); e32(lvimm); return 1; }
        if(op == 42){ e(0x48); e(0x69); e(0xC0); e32(lvimm); return 1; }
        if(op == 0){ e(0x48); e(0x3D); e32(lvimm); return 1; }
        if(op == KW_SHL || op == KW_SHR){
            if(lvimm < 0 || lvimm > 63){ return 0; }
            e(0x48); e(0xC1);
            if(op == KW_SHL){ e(0xE0); } else { e(0xF8); }
            e(lvimm);
            return 1;
        }
        if(op == KW_DIV || op == KW_MOD){
            if(lvimm == 0){ fail("division by zero"); }
            opintocx();
            divcode(op);
            return 1;
        }
        return 0;
    }
    if(lvtype != T_INT){ return 0; }        /* only whole words are safe */
    if(op == 43){ memop(0x03); return 1; }
    if(op == 45){ memop(0x2B); return 1; }
    if(op == 0){ memop(0x3B); return 1; }
    if(op == 42){
        e(0x48); e(0x0F); e(0xAF);
        if(lvkind == 2){ e(0x85); e32(lvoff); }
        else { e(0x04); e(0x25); fixup(FX_BSS32,lvoff); e32(0); }
        return 1;
    }
    if(op == KW_SHL || op == KW_SHR){
        opintocx();
        e(0x48); e(0xD3);
        if(op == KW_SHL){ e(0xE0); } else { e(0xF8); }
        return 1;
    }
    if(op == KW_DIV || op == KW_MOD){
        opintocx();
        e(0x48); e(0x85); e(0xC9);                /* test rcx,rcx */
        lvpos = jfwd(0x0F,0x85);
        trap("division by zero");
        patch(lvpos);
        divcode(op);
        return 1;
    }
    return 0;
}

/* --- element access -------------------------------------------------
   elemsetup() parses "[expr]", leaves the checked 0-based index in rax and
   records how the element is reached; elemload()/elemstore() then need a
   single instruction instead of computing an address. */
long elkind, eloff, eltype;

long elemsetup(long li,long gi){
    long isarr; long lo; long hi; long ok; long t; long k; long o; long et;
    if(li >= 0){
        if(lkind[li] == SK_CONST){ fail("a constant has no elements"); }
        isarr = larr[li]; lo = llo[li]; hi = lhi[li]; et = ltyp[li]; o = loff[li];
        k = 0;
        if(isarr == 2){ k = 2; }
    } else {
        if(gkind[gi] == SK_CONST){ fail("a constant has no elements"); }
        isarr = garr[gi]; lo = glo[gi]; hi = ghi[gi]; et = gtyp[gi]; o = gval[gi];
        k = 1;
    }
    if(!isarr){ fail("subscript applied to a variable that is not an array"); }
    next();
    t = expr();                       /* a nested index may clobber the globals */
    want(t,T_INT,"array index");
    if(tok == TK_RANGE){ fail("a slice can only be passed as an array argument"); }
    if(tok != 93){ fail("missing ] after array index"); }

    /* A CONSTANT INDEX OUTSIDE THE BOUNDS IS REFUSED HERE, not at run time.  The
       counterpart of the same check in src/wantzel.wz's elemsetup.

       lvkind == 1 means the expression just parsed was an immediate, with the value in
       lvimm -- a literal or a named constant.

       k == 2 is an `array of T` parameter, whose length only the caller knows, so the
       runtime check below is the only one possible for it.  This check is in addition to
       that one, not instead of it. */
    if(k != 2 && lvkind == 1 && (lvimm < lo || lvimm > hi)){
        fail("array index out of range at compile time");
    }

    next();
    elkind = k; eloff = o; eltype = et;
    if(elkind == 2){
        e(0x48); e(0x3B); e(0x85); e32(eloff-8);       /* cmp rax,[rbp+len] */
        ok = jfwd(0x0F,0x82);                          /* jb  ok            */
    } else {
        if(lo != 0){ e(0x48); e(0x2D); e32(lo); }      /* sub rax,lo        */
        e(0x48); e(0x3D); e32(hi-lo);                  /* cmp rax,count-1   */
        ok = jfwd(0x0F,0x86);                          /* jbe ok            */
    }
    trap("array index out of range");
    patch(ok);
    elkind = k; eloff = o; eltype = et;
    return et;
}

/* rax := element[rax] */
long elemload(){
    if(elkind == 0){
        if(tsize(eltype) == 1){ e(0x48); e(0x0F); e(0xB6); e(0x84); e(0x05); }
        else { e(0x48); e(0x8B); e(0x84); e(0xC5); }
        e32(eloff);
    } else if(elkind == 1){
        if(tsize(eltype) == 1){ e(0x48); e(0x0F); e(0xB6); e(0x80); }
        else { e(0x48); e(0x8B); e(0x04); e(0xC5); }
        fixup(FX_BSS32,eloff); e32(0);
    } else {
        e(0x48); e(0x8B); e(0x8D); e32(eloff);         /* mov rcx,[rbp+off] */
        if(tsize(eltype) == 1){ e(0x48); e(0x0F); e(0xB6); e(0x04); e(0x01); }
        else { e(0x48); e(0x8B); e(0x04); e(0xC1); }
    }
    return 0;
}

/* element[rcx] := rax */
long elemstore(){
    if(elkind == 0){
        if(tsize(eltype) == 1){ e(0x88); e(0x84); e(0x0D); }
        else { e(0x48); e(0x89); e(0x84); e(0xCD); }
        e32(eloff);
    } else if(elkind == 1){
        if(tsize(eltype) == 1){ e(0x88); e(0x81); }
        else { e(0x48); e(0x89); e(0x04); e(0xCD); }
        fixup(FX_BSS32,eloff); e32(0);
    } else {
        e(0x48); e(0x8B); e(0x95); e32(eloff);         /* mov rdx,[rbp+off] */
        if(tsize(eltype) == 1){ e(0x88); e(0x04); e(0x0A); }
        else { e(0x48); e(0x89); e(0x04); e(0xCA); }
    }
    return 0;
}

/* Emit in rax the address a designator denotes.  The head variable is
   li/gi (already scanned, with the token after it read); fpath holds the
   field path that was split off its dotted name.  Consumes any further
   "[index]" and ".field" steps.  Returns the type reached; refisarr, refet,
   reflo, refhi and refdyn describe it (an array is 1 = static, 2 = an
   array parameter whose length lives at [rbp+refdyn]). */
long pathaddr(long li,long gi){
    long isarr; long lo; long hi; long et; long dyn; long pend; long t; long ok; long sz; long a; long b; long f;
    long b1; long b2; long b3;
    if(li < 0 && gi < 0){ fail("undeclared identifier"); }
    dyn = 0;
    if(li >= 0){
        if(lkind[li] == SK_CONST){ fail("cannot assign to or take the address of a constant"); }
        isarr = larr[li]; lo = llo[li]; hi = lhi[li]; et = ltyp[li]; dyn = loff[li]-8;
        if(isarr == 2){ e(0x48); e(0x8B); e(0x85); e32(loff[li]); }  /* mov rax,[rbp+off] */
        else { lea_local(loff[li]); }
    } else {
        if(gkind[gi] == SK_CONST){ fail("cannot assign to or take the address of a constant"); }
        isarr = garr[gi]; lo = glo[gi]; hi = ghi[gi]; et = gtyp[gi];
        immbss(gval[gi]);
    }
    pend = 0; a = 0; refidx = 0;
    while(1){
        if(a < fplen){                              /* .field from the dotted name */
            b = a;
            while(b < fplen && fpath[b] != 46){ b = b + 1; }
            if(isarr != 0 || et < T_REC){ fail("only a record has fields"); }
            f = findfield(et,a,b);
            pend = pend + fdoff[f];
            isarr = fdarr[f]; lo = fdlo[f]; hi = fdhi[f]; et = fdtyp[f];
            a = b + 1;
            continue;
        }
        if(tok == 46){                              /* . name  (after an index) */
            next();
            if(iskw()){ failkeyword("a field", 0); }
            if(tok != TK_ID){ fail("field name expected after ."); }
            fplen = 0;
            while(tbuf[fplen] != 0){ fpath[fplen] = tbuf[fplen]; fplen = fplen + 1; }
            fpath[fplen] = 0;
            a = 0;
            next();
            continue;
        }
        if(tok == 91){                              /* [index] */
            if(isarr == 0){ fail("subscript applied to a variable that is not an array"); }
            if(pend != 0){ e(0x48); e(0x05); e32(pend); pend = 0; }   /* add rax,pend */
            push();
            next();
            t = expr();
            want(t,T_INT,"array index");
            if(tok == TK_RANGE){                    /* a slice: [lo..hi], inclusive like a declaration */
                if(!allowslice){ fail("a slice can only be passed as an array argument"); }
                next();
                push();                             /* lo, raw */
                t = expr();
                want(t,T_INT,"slice bound");
                if(tok != 93){ fail("missing ] after the slice"); }
                next();
                if(isarr != 2 && lo != 0){ e(0x48); e(0x2D); e32(lo); }   /* sub rax,lo */
                e(0x48); e(0x89); e(0xC1);                                 /* mov rcx,rax  (hi) */
                e(0x58);                                                   /* pop rax      (lo) */
                if(isarr != 2 && lo != 0){ e(0x48); e(0x2D); e32(lo); }
                e(0x4C); e(0x8D); e(0x59); e(0x01);                        /* lea r11,[rcx+1] */
                if(isarr == 2){ e(0x48); e(0x3B); e(0x85); e32(dyn); }     /* cmp rax,[rbp+len] */
                else { e(0x48); e(0x3D); e32(hi-lo+1); }                   /* cmp rax,count     */
                b1 = jfwd(0x0F,0x87);                                      /* ja  bad */
                if(isarr == 2){ e(0x4C); e(0x3B); e(0x9D); e32(dyn); }     /* cmp r11,[rbp+len] */
                else { e(0x49); e(0x81); e(0xFB); e32(hi-lo+1); }          /* cmp r11,count     */
                b2 = jfwd(0x0F,0x87);                                      /* ja  bad */
                e(0x49); e(0x39); e(0xC3);                                 /* cmp r11,rax */
                b3 = jfwd(0x0F,0x8C);                                      /* jl  bad */
                ok = jfwd(0,0xE9);
                patch(b1); patch(b2); patch(b3);
                trap("slice lies outside the array");
                patch(ok);
                e(0x49); e(0x29); e(0xC3);                                 /* sub r11,rax: the length */
                sz = tsize(et);
                if(sz == 8){ e(0x48); e(0xC1); e(0xE0); e(3); }
                else if(sz != 1){ e(0x48); e(0x69); e(0xC0); e32(sz); }
                popc(); e(0x48); e(0x01); e(0xC8);                         /* pop rcx; add rax,rcx */
                refisarr = 3; refet = et; reflo = lo; refhi = hi; refdyn = dyn;
                fplen = 0;
                return et;
            }
            if(tok != 93){ fail("missing ] after array index"); }

            /* A CONSTANT INDEX OUTSIDE THE BOUNDS IS REFUSED HERE, not at run time.
               The counterpart of the same check in src/wantzel.wz: a[9] on a four-element
               array used to compile clean and fail when it ran, while the compiler knew
               both the bound and the index as it read the line.

               lvkind == 1 means the expression just parsed was an immediate, with the
               value in lvimm -- a literal or a named constant.

               isarr == 2 is an `array of T` parameter, whose length only the caller
               knows, so the runtime check below is the only one possible for it. That is
               why this check is in addition to it and not instead of it. */
            if(isarr != 2 && lvkind == 1 && (lvimm < lo || lvimm > hi)){
                fail("array index out of range at compile time");
            }

            next();
            if(isarr == 2){
                e(0x48); e(0x3B); e(0x85); e32(dyn);           /* cmp rax,[rbp+len] */
                ok = jfwd(0x0F,0x82);                          /* jb  ok            */
            } else {
                if(lo != 0){ e(0x48); e(0x2D); e32(lo); }      /* sub rax,lo   */
                e(0x48); e(0x3D); e32(hi-lo);                  /* cmp rax,n-1  */
                ok = jfwd(0x0F,0x86);                          /* jbe ok       */
            }
            trap("array index out of range");
            patch(ok);
            sz = tsize(et);
            if(sz == 8){ e(0x48); e(0xC1); e(0xE0); e(3); }              /* shl rax,3 */
            else if(sz != 1){ e(0x48); e(0x69); e(0xC0); e32(sz); }      /* imul rax,rax,sz */
            popc(); e(0x48); e(0x01); e(0xC8);                 /* pop rcx; add rax,rcx */
            isarr = 0; refidx = refidx + 1;
            continue;
        }
        break;
    }
    if(pend != 0){ e(0x48); e(0x05); e32(pend); }
    refisarr = isarr; refet = et; reflo = lo; refhi = hi; refdyn = dyn;
    fplen = 0;
    return et;
}

/* Scan the name in tbuf as a designator head: sets spli/spgi and fpath.
   Returns 1 when it names a variable (possibly with a field path). */
long resolvevar(){
    fplen = 0;
    spli = findloc(); spgi = -1;
    if(spli < 0){ spgi = findglob(); }
    if(spli >= 0 || spgi >= 0){ return 1; }
    return splitname();
}

/* rax := the element count of the array a designator reached */
long reflen(){
    if(refisarr == 2){ e(0x48); e(0x8B); e(0x85); e32(refdyn); }
    else { imm(refhi - reflo + 1); }
    return 0;
}

/* push the address and the element count of an array argument */
long arrayarg(long et){
    long t; long n; long i;
    if(tok == TK_STR){                              /* a literal is an array of char */
        if(et != T_CHAR){ fail("a string literal can only be passed as an array of char"); }
        immdata(tval); push();
        n = 0; i = 7;
        while(i >= 0){ n = bor(n << 8, (long)(unsigned char)dat[tval-8+i]); i = i - 1; }
        imm(n); push();
        next();
        return 0;
    }
    if(tok != TK_ID){ fail("this parameter needs an array"); }
    if(eqt("view")){                                /* view(addr, count): any memory as an array */
        next(); lparen(); argint(); push(); comma(); argint(); push(); rparen();
        return 0;
    }
    if(!resolvevar()){ failundeclared(); }
    next();
    allowslice = 1;
    t = pathaddr(spli,spgi);
    allowslice = 0;
    if(refisarr == 0 && t >= T_REC && t == et){     /* a record passes as a one-element view */
        push(); imm(1); push();
        return 0;
    }
    /* A `str` here is worth its own message: a string LITERAL converts to array of char,
       a str VARIABLE does not, and the generic message says nothing about that
       difference. */
    if(refisarr == 0 && t == T_STR){
        fail("a str variable is not an array of char; only a string literal converts. Copy it first: n := io.push(buf, 0, s); and pass buf[0..n - 1]");
    }
    if(refisarr == 0){ fail("this parameter needs an array"); }
    if(t != et){ want(t,et,"array argument"); }
    push();
    if(refisarr == 3){ e(0x41); e(0x53); }           /* push r11: the slice length */
    else { reflen(); push(); }
    return 0;
}

/* a call to a user-defined function or procedure; name already scanned */
long callfn(long fi){
    long n; long t; long i; long nr;
    n = 0; nr = 0;
    if(tok == 40){                                  /* ( */
        next();
        if(tok != 41){
            while(1){
                if(n >= fnpar[fi]){ fail("too many arguments in call"); }
                if(fparr[fi*MAXP+n]){
                    arrayarg(fptyp[fi*MAXP+n]);
                    nr = nr + 2;
                } else {
                    t = expr();
                    want(t,fptyp[fi*MAXP+n],"argument");
                    push();
                    nr = nr + 1;
                }
                n = n + 1;
                if(tok != 44){ break; }
                next();
            }
        }
        if(tok != 41){ fail("missing ) in call"); }
        next();
    }
    if(n != fnpar[fi]){ fail("wrong number of arguments in call"); }
    i = nr - 1;
    while(i >= 0){ popreg(i); i = i - 1; }
    e(0xE8); fixup(FX_CALL,fi); e32(0);
    return frtyp[fi];
}

long argint(){
    long t;
    t = expr();
    want(t,T_INT,"builtin argument");
    return 0;
}
long lparen(){ if(tok != 40){ fail("missing ( after builtin"); } next(); return 0; }
long rparen(){ if(tok != 41){ fail("missing ) after arguments"); } next(); return 0; }
long comma(){ if(tok != 44){ fail("missing , between arguments"); } next(); return 0; }

long dobuiltin(long b){
    long t; long ok; long bad; long li; long gi; long n; long i; long nsys;
    if(b == 1){                                     /* ord(char):int */
        lparen(); t = expr(); want(t,T_CHAR,"ord"); rparen();
        return T_INT;
    }
    if(b == 2){                                     /* chr(int):char */
        lparen(); argint(); rparen();
        e(0x48); e(0x3D); e32(255);                 /* cmp rax,255 */
        ok = jfwd(0x0F,0x86);                       /* jbe ok      */
        trap("chr() argument outside 0..255");
        patch(ok);
        return T_CHAR;
    }
    if(b>=3 && b<=5){                               /* band/bor/bxor */
        lparen(); argint(); push(); comma(); argint(); rparen();
        xchgac();
        e(0x48);
        if(b==3){ e(0x21); } else if(b==4){ e(0x09); } else { e(0x31); }
        e(0xC8);
        return T_INT;
    }
    if(b == 6){                                     /* bnot */
        lparen(); argint(); rparen();
        e(0x48); e(0xF7); e(0xD0);
        return T_INT;
    }
    if(b == 7){                                     /* len(array):int */
        lparen();
        if(tok != TK_ID){ fail("len() needs an array name"); }
        if(!resolvevar()){ failundeclared(); }
        next();
        n = codelen; i = nfx;
        pathaddr(spli,spgi);
        if(refisarr == 0){ fail("len() needs an array name"); }
        if(refidx == 0){ codelen = n; nfx = i; }    /* the address is not needed */
        reflen();
        rparen();
        return T_INT;
    }
    if(b == 8){                                     /* addr(x):int */
        lparen();
        if(tok != TK_ID){ fail("addr() needs a variable"); }
        if(!resolvevar()){ failundeclared(); }
        next();
        pathaddr(spli,spgi);
        rparen();
        return T_INT;
    }
    if(b == 9){                                     /* slen(str):int */
        /* A str variable that was never assigned is (address 0, length 0) -- variables
           are zeroed -- and reading [rax-8] then dereferences address -8 and the process
           dies with no message at all. A null address answers 0. */
        lparen(); t = expr(); want(t,T_STR,"slen"); rparen();
        e(0x48); e(0x85); e(0xC0);                  /* test rax, rax */
        ok = jfwd(0x0F, 0x84);                      /* je -> leave rax at 0 */
        e(0x48); e(0x8B); e(0x40); e(0xF8);         /* mov rax,[rax-8] */
        patch(ok);
        return T_INT;
    }
    if(b == 10){                                    /* sch(str,int):char */
        /* The bound lives in the eight bytes BEFORE the text, so comparing the index
           against it is itself a dereference: on a zeroed str (address 0) the cmp read
           address -8 and the process died before its own trap could fire. The guard was
           present and correct -- it was unreachable. A null address therefore traps:
           index 0 lies outside 0..-1. Note the difference with slen, which ANSWERS 0 --
           an empty string has length 0, but has no character at position 0. */
        lparen(); t = expr(); want(t,T_STR,"schar"); push();
        comma(); argint(); rparen();
        popc();                                     /* rcx = string, rax = index */
        e(0x48); e(0x85); e(0xC9);                  /* test rcx,rcx    */
        bad = jfwd(0x0F,0x84);                      /* je -> trap      */
        e(0x48); e(0x3B); e(0x41); e(0xF8);         /* cmp rax,[rcx-8] */
        ok = jfwd(0x0F,0x82);                       /* jb ok           */
        patch(bad);
        trap("string index out of range");
        patch(ok);
        e(0x48); e(0x01); e(0xC8);                  /* add rax,rcx     */
        e(0x48); e(0x0F); e(0xB6); e(0x00);         /* movzx rax,[rax] */
        return T_CHAR;
    }
    if(b == 11){                                    /* halt(int) */
        lparen(); argint(); rparen();
        e(0x48); e(0x89); e(0xC7);                  /* mov rdi,rax */
        imm(231); syscallinsn();
        return T_VOID;
    }
    if(b == 17){                                    /* poke(addr,byte) */
        lparen(); argint(); push(); comma(); argint(); rparen();
        popc();                                     /* pop rcx (addr) */
        e(0x88); e(0x01);                           /* mov [rcx],al */
        return T_VOID;
    }
    if(b == 18){                                    /* peek(addr):int */
        lparen(); argint(); rparen();
        e(0x48); e(0x0F); e(0xB6); e(0x00);         /* movzx rax,[rax] */
        return T_INT;
    }
    if(b == 14){                                    /* sadr(str):int */
        lparen(); t = expr(); want(t,T_STR,"sadr"); rparen();
        return T_INT;
    }
    if(b == 15){                 /* scan(array of char, from, to, char):int */
        lparen();
        arrayarg(T_CHAR);                           /* base, then length */
        comma(); argint(); push();                  /* from */
        comma(); argint(); push();                  /* to   */
        comma(); t = expr(); want(t,T_CHAR,"scan"); push();
        rparen();
        e(0x41); e(0x58);                           /* pop r8  */
        e(0x59);                                    /* pop rcx */
        e(0x5A);                                    /* pop rdx */
        e(0x5E);                                    /* pop rsi */
        e(0x5F);                                    /* pop rdi */
        e(0x48); e(0x39); e(0xCA);                  /* cmp rdx,rcx */
        n = jfwd(0x0F,0x87);                        /* ja  bad     */
        e(0x48); e(0x39); e(0xF1);                  /* cmp rcx,rsi */
        ok = jfwd(0x0F,0x86);                       /* jbe ok      */
        patch(n);
        trap("scan() range lies outside the array");
        patch(ok);
        e(0xE8); e32(scanaddr - (codelen+4));
        return T_INT;
    }
    if(b == 12){                                    /* argc():int */
        lparen(); rparen();
        immbss(0); e(0x48); e(0x8B); e(0x00); e(0x48); e(0x8B); e(0x00);
        return T_INT;
    }
    if(b == 13){                                    /* argch(int,int):char */
        lparen(); argint(); push(); comma(); argint(); rparen();
        push();
        e(0x5E); e(0x5F);                           /* pop rsi ; pop rdi */
        e(0xE8); e32(argaddr - (codelen+4));
        return T_CHAR;
    }
    if(b == 28 || b == 29){                         /* trunc(real):int, round(real):int */
        lparen(); t = expr(); want(t,T_REAL,"trunc/round"); rparen();
        xmm0rax();
        e(0xF2); e(0x48); e(0x0F);
        if(b == 28){ e(0x2C); } else { e(0x2D); }   /* cvttsd2si / cvtsd2si rax,xmm0 */
        e(0xC0);
        return T_INT;
    }
    if(b == 30){                                    /* sqrt(real):real */
        lparen(); t = expr(); want(t,T_REAL,"sqrt"); rparen();
        xmm0rax();
        e(0xF2); e(0x0F); e(0x51); e(0xC0);         /* sqrtsd xmm0,xmm0 */
        raxxmm0();
        return T_REAL;
    }
    if(b == 31){                                    /* pack32(real):int -- IEEE single bits */
        lparen(); t = expr(); want(t,T_REAL,"pack32"); rparen();
        xmm0rax();
        e(0xF2); e(0x0F); e(0x5A); e(0xC0);         /* cvtsd2ss xmm0,xmm0 */
        e(0x66); e(0x0F); e(0x7E); e(0xC0);         /* movd eax,xmm0 */
        return T_INT;
    }
    if(b == 33){ fail("view(addr, count) can only be passed where an array parameter is expected"); }
    if(b == 32){                                    /* unpack32(int):real */
        lparen(); argint(); rparen();
        e(0x66); e(0x0F); e(0x6E); e(0xC0);         /* movd xmm0,eax */
        e(0xF3); e(0x0F); e(0x5A); e(0xC0);         /* cvtss2sd xmm0,xmm0 */
        raxxmm0();
        return T_REAL;
    }
    /* sys1..sys6 */
    nsys = b - 20;
    lparen();
    argint(); push();                               /* syscall number */
    n = 0;
    while(n < nsys){ comma(); argint(); push(); n = n + 1; }
    rparen();
    i = nsys - 1;
    while(i >= 0){ popsys(i); i = i - 1; }
    e(0x58);                                        /* pop rax */
    syscallinsn();
    return T_INT;
}

long factor(){
    long t; long b; long fi; long li; long gi; long sp; long sf;
    lvpos = codelen; lvfx = nfx; lvkind = 0;
    if(tok == TK_INT){ imm(tval); next(); lvkind = 1; lvimm = tval; lvtype = T_INT; return T_INT; }
    if(tok == TK_REAL){ imm(tval); next(); return T_REAL; }
    if(tok == KW_REAL){                             /* real(int):real */
        next(); lparen(); argint(); rparen();
        xmm0rax();
        e(0xF2); e(0x48); e(0x0F); e(0x2A); e(0xC0);   /* cvtsi2sd xmm0,rax */
        raxxmm0();
        return T_REAL;
    }
    if(tok == TK_CHR){ imm(tval); next(); lvkind = 1; lvimm = tval; lvtype = T_CHAR; return T_CHAR; }
    if(tok == TK_STR){ immdata(tval); next(); return T_STR; }
    if(tok == KW_TRUE){ imm(1); next(); return T_BOOL; }
    if(tok == KW_FALSE){ imm(0); next(); return T_BOOL; }
    if(tok == 40){ next(); t = expr(); if(tok != 41){ fail("missing )"); } next(); lvkind = 0; return t; }
    if(tok == 45){
        next();
        sp = codelen; sf = nfx;
        t = factor();
        if(t == T_REAL){
            e(0x48); e(0x0F); e(0xBA); e(0xF8); e(63);   /* btc rax,63: flip the sign */
            lvkind = 0;
            return T_REAL;
        }
        want(t,T_INT,"unary -");
        if(lvkind == 1){
            codelen = sp; nfx = sf;
            imm(0-lvimm);
            lvimm = 0-lvimm; lvkind = 1; lvtype = T_INT;
            return T_INT;
        }
        e(0x48); e(0xF7); e(0xD8);
        lvkind = 0;
        return T_INT;
    }
    if(tok == KW_NOT){ next(); t = factor(); want(t,T_BOOL,"not"); e(0x48); e(0x83); e(0xF0); e(1); lvkind = 0; return T_BOOL; }
    if(tok == TK_ID){
        b = bicode();
        if(b != 0){ next(); t = dobuiltin(b); lvkind = 0; return t; }
        fi = findfn();
        li = findloc();
        gi = -1;
        if(li < 0){ gi = findglob(); }
        if(li < 0 && gi < 0 && fi >= 0){
            next();
            if(frtyp[fi] == T_VOID){ fail("a procedure has no value"); }
            t = callfn(fi);
            lvkind = 0;
            return t;
        }
        if(li < 0 && gi >= 0 && gkind[gi] == SK_CONST){
            if(gtyp[gi] == T_STR){ immdata(gval[gi]); next(); return T_STR; }
            imm(gval[gi]); next();
            if(gtyp[gi] == T_REAL){ return T_REAL; }
            lvkind = 1; lvimm = gval[gi]; lvtype = gtyp[gi];
            return gtyp[gi];
        }
        if(li >= 0 && lkind[li] == SK_CONST){
            if(ltyp[li] == T_STR){ immdata(loff[li]); next(); return T_STR; }
            imm(loff[li]); next();
            if(ltyp[li] == T_REAL){ return T_REAL; }
            lvkind = 1; lvimm = loff[li]; lvtype = ltyp[li];
            return ltyp[li];
        }
        fplen = 0;
        if(li < 0 && gi < 0){
            if(!splitname()){ failundeclared(); }
            li = spli; gi = spgi;
        }
        next();
        if(fplen == 0 && tok == 91){
            if(li >= 0){ t = ltyp[li]; } else { t = gtyp[gi]; }
            if(t < T_REC){
                t = elemsetup(li,gi);
                if(tok == 46){ fail("only a record has fields"); }
                elemload();
                lvkind = 0;
                return t;
            }
        }
        if(fplen == 0 && li >= 0 && larr[li] == 0 && ltyp[li] < T_REC){
            loadlocal(loff[li],ltyp[li]);
            lvkind = 2; lvoff = loff[li]; lvtype = ltyp[li];
            return ltyp[li];
        }
        if(fplen == 0 && gi >= 0 && garr[gi] == 0 && gtyp[gi] < T_REC){
            if(gkind[gi] == SK_CONST){ fail("cannot take the value of a constant this way"); }
            loadglobal(gval[gi],gtyp[gi]);
            lvkind = 3; lvoff = gval[gi]; lvtype = gtyp[gi];
            return gtyp[gi];
        }
        t = pathaddr(li,gi);
        if(refisarr != 0){ fail("an array can only be used with a subscript, len() or addr()"); }
        if(t >= T_REC){ fail("a record has no value of its own; use its fields"); }
        loadind(t);
        lvkind = 0;
        return t;
    }
    fail("expression expected");
    return 0;
}

long term(){
    long lt; long rt; long op; long ok; long lab; long pp; long pf; long sp; long sf;
    lt = factor();
    while(tok==42 || tok==47 || tok==KW_DIV || tok==KW_MOD || tok==KW_AND || tok==KW_SHL || tok==KW_SHR){
        op = tok;
        next();
        if(lt == T_REAL){
            if(op != 42 && op != 47){ fail("a real supports * and /; use trunc() or round() for integer division"); }
            push();
            rt = factor();
            want(rt,T_REAL,"arithmetic");
            xchgac();
            if(op == 42){ realop(0x59); } else { realop(0x5E); }   /* mulsd / divsd */
            lvkind = 0;
        } else if(op == 47){
            fail("/ divides reals; use div for integers");
        } else if(op == KW_AND){
            want(lt,T_BOOL,"and");
            e(0x48); e(0x85); e(0xC0);              /* test rax,rax */
            lab = jfwd(0x0F,0x84);                  /* jz  false    */
            rt = factor();
            want(rt,T_BOOL,"and");
            patch(lab);
            lvkind = 0;
            lt = T_BOOL;
        } else {
            want(lt,T_INT,"arithmetic");
            pp = codelen; pf = nfx;
            push();
            rt = factor();
            want(rt,T_INT,"arithmetic");
            sp = 0;
            if(lvkind != 0){ sp = fold2(op,pp,pf); }
            if(!sp){
                xchgac();
                if(op == 42){ e(0x48); e(0x0F); e(0xAF); e(0xC1); }        /* imul */
                else if(op == KW_SHL){ e(0x48); e(0xD3); e(0xE0); }        /* shl  */
                else if(op == KW_SHR){ e(0x48); e(0xD3); e(0xF8); }        /* sar  */
                else {
                    e(0x48); e(0x85); e(0xC9);                            /* test rcx,rcx */
                    ok = jfwd(0x0F,0x85);                                 /* jnz ok       */
                    trap("division by zero");
                    patch(ok);
                    divcode(op);
                }
            }
            lvkind = 0;
            lt = T_INT;
        }
    }
    return lt;
}

long simple(){
    long lt; long rt; long op; long lab; long pp; long pf;
    lt = term();
    while(tok==43 || tok==45 || tok==KW_OR){
        op = tok;
        next();
        if(op == KW_OR){
            want(lt,T_BOOL,"or");
            e(0x48); e(0x85); e(0xC0);              /* test rax,rax */
            lab = jfwd(0x0F,0x85);                  /* jnz true     */
            rt = term();
            want(rt,T_BOOL,"or");
            patch(lab);
            lvkind = 0;
            lt = T_BOOL;
        } else if(lt == T_REAL){
            push();
            rt = term();
            want(rt,T_REAL,"arithmetic");
            xchgac();
            if(op == 43){ realop(0x58); } else { realop(0x5C); }   /* addsd / subsd */
            lvkind = 0;
        } else {
            want(lt,T_INT,"arithmetic");
            pp = codelen; pf = nfx;
            push();
            rt = term();
            want(rt,T_INT,"arithmetic");
            if(lvkind != 0 && fold2(op,pp,pf)){ }
            else {
                xchgac();
                if(op == 43){ e(0x48); e(0x01); e(0xC8); }
                else { e(0x48); e(0x29); e(0xC8); }
            }
            lvkind = 0;
            lt = T_INT;
        }
    }
    return lt;
}

long expr(){
    long lt; long rt; long op; long cc; long pp; long pf;
    lt = simple();
    if(tok==61 || tok==TK_NE || tok==60 || tok==62 || tok==TK_LE || tok==TK_GE){
        op = tok;
        next();
        pp = codelen; pf = nfx;
        push();
        rt = simple();
        if(lt != rt){ want(rt,lt,"comparison"); }
        if(op==61 || op==TK_NE){
            if(lt == T_STR){ fail("strings cannot be compared with = or <>; compare their characters"); }
            if(lt == T_VOID){ fail("cannot compare these values"); }
        } else {
            if(lt != T_INT && lt != T_CHAR && lt != T_REAL){ fail("only int, char and real can be ordered"); }
        }
        if(lt == T_REAL){
            xchgac();
            xmm0rax(); xmm1rcx();
            e(0x66); e(0x0F);
            if(op == 61 || op == TK_NE){ e(0x2E); } else { e(0x2F); }   /* ucomisd / comisd xmm0,xmm1 */
            e(0xC1);
            lvkind = 0;
            if(op == 61){                           /* equal: ZF and not PF */
                e(0x0F); e(0x94); e(0xC0);          /* sete al  */
                e(0x0F); e(0x9B); e(0xC1);          /* setnp cl */
                e(0x20); e(0xC8);                   /* and al,cl */
            } else if(op == TK_NE){
                e(0x0F); e(0x95); e(0xC0);          /* setne al */
                e(0x0F); e(0x9A); e(0xC1);          /* setp cl  */
                e(0x08); e(0xC8);                   /* or al,cl */
            } else {
                if(op == 60){ cc = 0x92; }          /* setb  */
                else if(op == 62){ cc = 0x97; }     /* seta  */
                else if(op == TK_LE){ cc = 0x96; }  /* setbe */
                else { cc = 0x93; }                 /* setae */
                e(0x0F); e(cc); e(0xC0);
            }
            e(0x48); e(0x0F); e(0xB6); e(0xC0);     /* movzx rax,al */
            return T_BOOL;
        }
        if(lvkind == 0 || !fold2(0,pp,pf)){
            xchgac();
            e(0x48); e(0x39); e(0xC8);              /* cmp rax,rcx */
        }
        lvkind = 0;
        if(op == 61){ cc = 0x94; }
        else if(op == TK_NE){ cc = 0x95; }
        else if(op == 60){ cc = 0x9C; }
        else if(op == 62){ cc = 0x9F; }
        else if(op == TK_LE){ cc = 0x9E; }
        else { cc = 0x9D; }
        e(0x0F); e(cc); e(0xC0);                    /* setcc al      */
        e(0x48); e(0x0F); e(0xB6); e(0xC0);         /* movzx rax,al  */
        return T_BOOL;
    }
    return lt;
}

/* ------------------------------------------------------------------ */
/* statements                                                          */
/* ------------------------------------------------------------------ */
long cntfix[256], ncnt, cntbase;

long stmt();
long stmtlist();
long cexpr();
long dofor();

long condition(char *ctx){
    long t;
    t = expr();
    want(t,T_BOOL,ctx);
    e(0x48); e(0x85); e(0xC0);                      /* test rax,rax */
    return jfwd(0x0F,0x84);                         /* jz  <patch>  */
}

long epilogue(){
    e(0x48); e(0x89); e(0xEC);                      /* mov rsp,rbp */
    e(0x5D);                                        /* pop rbp     */
    e(0xC3);                                        /* ret         */
    return 0;
}

/* a hidden 8-byte slot in the current frame */
long hidden(){
    frame = frame + 8;
    return 0 - frame;
}

/* jump chains: each pending rel32 holds the offset of the previous one */
long read32(long o){
    long v;
    v = (long)(unsigned char)code[o];
    v = bor(v, ((long)(unsigned char)code[o+1]) << 8);
    v = bor(v, ((long)(unsigned char)code[o+2]) << 16);
    v = bor(v, ((long)(unsigned char)code[o+3]) << 24);
    return v;
}
long chainpatch(long h){
    long nxt;
    while(h != 0){
        nxt = read32(h);
        patch(h);
        h = nxt;
    }
    return 0;
}

/* for v := a to b do s   |   for v := b downto a do s */
long dofor(){
    long li; long gi; long t; long slot; long down; long top; long lab; long ob; long oc; long i;
    next();
    if(tok != TK_ID){ fail("for needs a variable"); }
    li = findloc(); gi = -1;
    if(li < 0){ gi = findglob(); }
    if(li < 0 && gi < 0){ fail("undeclared identifier"); }
    if(li >= 0){
        if(lkind[li] == SK_CONST || larr[li] != 0 || ltyp[li] != T_INT){ fail("a for variable is a plain int variable"); }
    } else {
        if(gkind[gi] == SK_CONST || garr[gi] != 0 || gtyp[gi] != T_INT){ fail("a for variable is a plain int variable"); }
    }
    next();
    if(tok != TK_ASSIGN){ fail("missing := in for"); }
    next();
    t = expr(); want(t,T_INT,"for start value");
    if(li >= 0){ storelocal(loff[li],T_INT); } else { storeglobal(gval[gi],T_INT); }
    if(tok == KW_TO){ down = 0; } else if(tok == KW_DOWNTO){ down = 1; } else { fail("missing to or downto"); }
    next();
    t = expr(); want(t,T_INT,"for end value");
    slot = hidden();
    storelocal(slot,T_INT);
    if(tok != KW_DO){ fail("missing do"); }
    next();
    top = codelen;
    if(li >= 0){ loadlocal(loff[li],T_INT); } else { loadglobal(gval[gi],T_INT); }
    e(0x48); e(0x3B); e(0x85); e32(slot);          /* cmp rax,[rbp+slot] */
    if(down){ lab = jfwd(0x0F,0x8C); } else { lab = jfwd(0x0F,0x8F); }   /* jl / jg end */
    ob = brkbase; oc = cntbase; brkbase = nbrk; cntbase = ncnt;
    stmt();
    i = cntbase; while(i < ncnt){ patch(cntfix[i]); i = i + 1; }
    if(li >= 0){ loadlocal(loff[li],T_INT); } else { loadglobal(gval[gi],T_INT); }
    if(down){ e(0x48); e(0x83); e(0xE8); e(1); } else { e(0x48); e(0x83); e(0xC0); e(1); }   /* sub/add rax,1 */
    if(li >= 0){ storelocal(loff[li],T_INT); } else { storeglobal(gval[gi],T_INT); }
    jmpto(0,0xE9,top);
    patch(lab);
    i = brkbase; while(i < nbrk){ patch(brkfix[i]); i = i + 1; }
    nbrk = brkbase; ncnt = cntbase; brkbase = ob; cntbase = oc;
    return 0;
}


long stmtlist(){
    while(1){
        stmt();
        if(tok != 59){ return 0; }                  /* ; */
        next();
    }
    return 0;
}

long stmt(){
    long lab; long lab2; long top; long ob; long oc; long i; long t;
    long fi; long li; long gi; long b; long sk; long so; long st;
    if(tok == KW_BEGIN){
        next(); stmtlist();
        if(tok != KW_END){ fail("missing end"); }
        next();
        return 0;
    }
    /* a statement starts here -- not a begin, which only groups, and not an empty one */
    if(tok == KW_IF || tok == KW_WHILE || tok == KW_RETURN || tok == KW_BREAK
       || tok == KW_CONTINUE || tok == KW_FOR || tok == TK_ID){ dbline(115); }
    if(tok == KW_IF){
        next();
        lab = condition("if condition");
        if(tok != KW_THEN){ fail("missing then"); }
        next();
        stmt();
        if(tok == KW_ELSE){
            next();
            lab2 = jfwd(0,0xE9);
            patch(lab);
            stmt();
            patch(lab2);
        } else {
            patch(lab);
        }
        return 0;
    }
    if(tok == KW_WHILE){
        next();
        top = codelen;
        lab = condition("while condition");
        if(tok != KW_DO){ fail("missing do"); }
        next();
        ob = brkbase; oc = cntbase; brkbase = nbrk; cntbase = ncnt;
        stmt();
        i = cntbase; while(i < ncnt){ e32at(cntfix[i],top-(cntfix[i]+4)); i = i + 1; }
        jmpto(0,0xE9,top);
        patch(lab);
        i = brkbase; while(i < nbrk){ patch(brkfix[i]); i = i + 1; }
        nbrk = brkbase; ncnt = cntbase; brkbase = ob; cntbase = oc;
        return 0;
    }
    if(tok == KW_RETURN){
        next();
        if(curret == T_VOID){
            if(tok!=59 && tok!=KW_END && tok!=KW_ELSE){
                fail("a procedure cannot return a value");
            }
            e(0x48); e(0x31); e(0xC0);              /* xor rax,rax */
        } else {
            t = expr();
            want(t,curret,"return value");
        }
        epilogue();
        return 0;
    }
    if(tok == KW_BREAK){
        next();
        if(brkbase < 0){ fail("break outside a loop"); }
        if(nbrk >= 256){ fail("too many break statements"); }
        brkfix[nbrk] = jfwd(0,0xE9); nbrk = nbrk + 1;
        return 0;
    }
    if(tok == KW_CONTINUE){
        next();
        if(cntbase < 0){ fail("continue outside a loop"); }
        if(ncnt >= 256){ fail("too many continue statements"); }
        cntfix[ncnt] = jfwd(0,0xE9); ncnt = ncnt + 1;
        return 0;
    }
    if(tok == KW_FOR){
        dofor();
        return 0;
    }
    if(tok == TK_ID && eqt("case")){ fail("'case' is no longer part of the language; write an if-chain: if x = a then ... else if x = b then ... else ..."); }
    if(tok == KW_ELSE){ fail("unexpected else (no ';' may precede it)"); }
    if(tok == TK_ID && eqt("repeat")){ fail("'repeat ... until' is no longer part of the language; write 'while true do begin ... if done then break; end'"); }
    if(tok == TK_ID){
        b = bicode();
        if(b != 0){
            next();
            t = dobuiltin(b);
            if(t != T_VOID && b != 16 && (b < 21 || b > 26)){ fail("the value of this call is not used"); }
            return 0;
        }
        li = findloc();
        gi = -1;
        if(li < 0){ gi = findglob(); }
        fplen = 0;
        if(li < 0 && gi < 0){
            fi = findfn();
            if(fi >= 0){
                next();
                if(frtyp[fi] != T_VOID){ fail("the value of this function call is not used"); }
                callfn(fi);
                return 0;
            }
            if(!splitname()){ failundeclared(); }
            li = spli; gi = spgi;
        }
        next();
        if(li >= 0 && lkind[li] == SK_CONST){ fail("cannot assign to or take the address of a constant"); }
        if(fplen == 0 && tok == TK_ASSIGN && li >= 0 && larr[li] == 0 && ltyp[li] < T_REC){
            t = ltyp[li];
            next();
            i = expr();
            want(i,t,"assignment");
            storelocal(loff[li],t);
            return 0;
        }
        if(fplen == 0 && tok == TK_ASSIGN && li < 0 && gi >= 0 && garr[gi] == 0 && gkind[gi] == SK_VAR && gtyp[gi] < T_REC){
            t = gtyp[gi];
            next();
            i = expr();
            want(i,t,"assignment");
            storeglobal(gval[gi],t);
            return 0;
        }
        if(fplen == 0 && tok == 91){
            if(li >= 0){ t = ltyp[li]; } else { t = gtyp[gi]; }
            if(t < T_REC){
                t = elemsetup(li,gi);
                if(tok == 46){ fail("only a record has fields"); }
                sk = elkind; so = eloff; st = eltype;
                if(tok != TK_ASSIGN){ fail("missing := in assignment"); }
                next();
                push();
                i = expr();
                want(i,st,"assignment");
                popc();
                elkind = sk; eloff = so; eltype = st;
                elemstore();
                return 0;
            }
        }
        t = pathaddr(li,gi);
        if(tok != TK_ASSIGN){ fail("missing := in assignment"); }
        next();
        if(refisarr != 0){ fail("an array cannot be assigned as a whole"); }
        push();
        if(t >= T_REC){                             /* whole-record copy */
            if(tok != TK_ID){ fail("a record can only be assigned from another record"); }
            if(!resolvevar()){ failundeclared(); }
            next();
            i = pathaddr(spli,spgi);
            if(i != t || refisarr != 0){ fail("record types differ in assignment"); }
            e(0x48); e(0x89); e(0xC6);              /* mov rsi,rax        */
            e(0x5F);                                /* pop rdi            */
            e(0x48); e(0xC7); e(0xC1); e32(tsize(t)); /* mov rcx,size     */
            e(0xF3); e(0xA4);                       /* rep movsb          */
            return 0;
        }
        i = expr();
        want(i,t,"assignment");
        popc();
        storeind(t);
        return 0;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* declarations                                                        */
/* ------------------------------------------------------------------ */
long tmpnam[64];
long ptarr, ptlo, pthi;

long cexpr();

long cfactor(){
    long v; long gi;
    if(tok == TK_INT){ v = tval; next(); return v; }
    if(tok == 45){ next(); return 0 - cfactor(); }
    if(tok == 40){ next(); v = cexpr(); if(tok != 41){ fail("missing )"); } next(); return v; }
    if(tok == TK_ID){
        gi = findloc();
        if(gi >= 0){
            if(lkind[gi] != SK_CONST){ fail("a constant is required here"); }
            if(ltyp[gi] != T_INT){ fail("an integer constant is required here"); }
            v = loff[gi]; next(); return v;
        }
        gi = findglob();
        if(gi < 0){ fail("undeclared constant"); }
        if(gkind[gi] != SK_CONST){ fail("a constant is required here"); }
        if(gtyp[gi] != T_INT){ fail("an integer constant is required here"); }
        v = gval[gi]; next(); return v;
    }
    fail("constant expression expected");
    return 0;
}
long cterm(){
    long v;
    v = cfactor();
    while(tok == 42){ next(); v = v * cfactor(); }
    return v;
}
/* continue a constant expression whose first term is already known */
long cexprfrom(long v){
    long op;
    while(tok==43 || tok==45){
        op = tok; next();
        if(op == 43){ v = v + cterm(); } else { v = v - cterm(); }
    }
    return v;
}
long cexpr(){ return cexprfrom(cterm()); }

long basetype(){
    long t;
    if(tok == KW_INT){ t = T_INT; }
    else if(tok == KW_CHAR){ t = T_CHAR; }
    else if(tok == KW_BOOL){ t = T_BOOL; }
    else if(tok == KW_STR){ t = T_STR; }
    else if(tok == KW_REAL){ t = T_REAL; }
    else if(tok == TK_ID){
        t = findtype();
        if(t < 0){ fail("type expected"); }
        t = T_REC + t;
    }
    else { fail("type expected"); return 0; }
    next();
    return t;
}

/* parse a type; sets ptarr/ptlo/pthi, returns the element type */
long partype(){
    long t;
    ptarr = 0; ptlo = 0; pthi = 0;
    if(tok == KW_ARRAY){
        next();
        if(tok != 91){ fail("missing [ in array type"); }
        next();
        ptlo = cexpr();
        if(tok != TK_RANGE){ fail("missing .. in array bounds"); }
        next();
        pthi = cexpr();
        if(tok != 93){ fail("missing ] in array type"); }
        next();
        if(pthi < ptlo){ fail("empty array bounds"); }
        if(tok != KW_OF){ fail("missing of in array type"); }
        next();
        ptarr = 1;
    }
    t = basetype();
    return t;
}

long declvars(long islocal){
    long n; long i; long t; long sz; long nb;
    next();                                          /* skip 'var' */
    if(iskw()){ failkeyword("a variable", 0); }
    if(tok != TK_ID){ fail("variable name expected"); }
    while(tok == TK_ID){
        n = 0;
        while(1){
            if(bicode() != 0){ fail("that name is built in"); }
            if(findfn() >= 0){ failtaken("name already used by a routine"); }
            if(findtype() >= 0){ failtaken("name already used by a type"); }
            if(islocal){ if(findloc() >= 0){ failtaken("duplicate local declaration"); } }
            else { if(findglob() >= 0){ fail("duplicate global declaration"); } }
            if(n >= 64){ fail("too many names in one declaration"); }
            tmpnam[n] = intern(); n = n + 1;
            next();
            if(tok != 44){ break; }
            next();
            if(iskw()){ failkeyword("a variable", 0); }
            if(tok != TK_ID){ fail("variable name expected"); }
        }
        if(tok != 58){ fail("missing : in declaration"); }
        next();
        t = partype();
        nb = 1;
        if(ptarr){ nb = pthi - ptlo + 1; }
        sz = nb * tsize(t);
        while((sz % 8) != 0){ sz = sz + 1; }
        i = 0;
        while(i < n){
            if(islocal){
                if(nloc >= MAXL){ fail("too many locals"); }
                lnam[nloc] = tmpnam[i]; ltyp[nloc] = t; lkind[nloc] = SK_VAR;
                larr[nloc] = ptarr; llo[nloc] = ptlo; lhi[nloc] = pthi;
                frame = frame + sz;
                loff[nloc] = 0 - frame;
                nloc = nloc + 1;
            } else {
                if(ngl >= MAXG){ fail("too many globals"); }
                gnam[ngl] = tmpnam[i]; gkind[ngl] = SK_VAR; gtyp[ngl] = t;
                garr[ngl] = ptarr; glo[ngl] = ptlo; ghi[ngl] = pthi;
                gfile[ngl] = declloc;
                gval[ngl] = bsslen;
                bsslen = bsslen + sz;
                gindex(ngl);
                ngl = ngl + 1;
            }
            i = i + 1;
        }
        if(tok != 59){ fail("missing ; after declaration"); }
        next();
    }
    if(kwnamed(58, 44)){ failkeyword("a variable", 0); }
    return 0;
}

/* declschema is defined below but called from decltypes: a schema is declared with
   'type X = schema ... end', so the type declaration is what dispatches to it. */
long declschema(void);

/* type NAME = record <names: type;>... end;
   type NAME = schema <field: type[?] ["description"];>... end; */
long decltypes(){
    long r; long n; long i; long t; long nb; long sz; long off; long al;
    next();                                          /* skip 'type' */
    if(iskw()){ failkeyword("a type", 0); }
    if(tok != TK_ID){ fail("type name expected"); }
    while(tok == TK_ID){
        if(bicode() != 0){ fail("that name is built in"); }
        if(findglob() >= 0 || findfn() >= 0 || findtype() >= 0){ failtaken("duplicate declaration"); }
        if(nrt >= MAXR){ fail("too many record types"); }
        r = nrt;
        /* the name as bytes, before interning: a schema needs it in schname/scnam and
           which of the two kinds this is is not known until after the '='. */
        i = 0;
        while(tbuf[i] != 0){
            if(i >= 62){ fail("type name too long"); }
            tnamebuf[i] = tbuf[i]; i = i + 1;
        }
        tnamebuf[i] = 0;
        rtnam[r] = intern(); rtf0[r] = nfd; rtnf[r] = 0; rtsize[r] = 0;
        next();
        if(tok != 61){ fail("missing = in type declaration"); }
        next();
        /* a record (a memory layout) or a schema (a JSON contract): they share the
           notation and nothing else, and the word after '=' says which. This bootstrap
           compiler does not implement schema, so declschema() always
           fails -- the bookkeeping the self-hosted compiler does first (schname/scnam)
           is not needed here. */
        if(tok == KW_SCHEMA){
            next();
            declschema();
            continue;
        }
        if(tok != KW_RECORD){ fail("a type is declared as 'record ... end' or 'schema ... end'"); }
        next();
        off = 0;
        while(tok == TK_ID){
            n = 0;
            while(1){
                if(n >= 64){ fail("too many names in one declaration"); }
                i = rtf0[r];
                while(i < nfd){ if(nameq(fdnam[i])){ fail("duplicate field name"); } i = i + 1; }
                tmpnam[n] = intern(); n = n + 1;
                next();
                if(tok != 44){ break; }
                next();
                if(iskw()){ failkeyword("a record field", 0); }
                if(tok != TK_ID){ fail("field name expected in this record declaration"); }
            }
            if(tok != 58){ fail("missing : in field declaration"); }
            next();
            t = partype();
            if(t == T_REC + r){ fail("a record cannot contain itself"); }
            nb = 1;
            if(ptarr){ nb = pthi - ptlo + 1; }
            sz = nb * tsize(t);
            al = 8;
            if(tsize(t) == 1){ al = 1; }
            i = 0;
            while(i < n){
                if(nfd >= MAXRF){ fail("too many record fields"); }
                while((off % al) != 0){ off = off + 1; }
                fdnam[nfd] = tmpnam[i]; fdtyp[nfd] = t; fdoff[nfd] = off;
                fdarr[nfd] = ptarr; fdlo[nfd] = ptlo; fdhi[nfd] = pthi;
                off = off + sz;
                nfd = nfd + 1; rtnf[r] = rtnf[r] + 1;
                i = i + 1;
            }
            if(tok != 59){ fail("missing ; after a field"); }
            next();
        }
        if(tok != KW_END && iskw()){ failkeyword("a record field", 0); }
        if(tok != KW_END){ fail("missing end of the record"); }
        next();
        /* `end: int;` -- a field named end reads as the end of the record */
        if(tok == 58){ failkeyword("a record field", 0); }
        if(tok != 59){ fail("missing ; after the type"); }
        next();
        while((off % 8) != 0){ off = off + 1; }
        if(off == 0){ fail("a record needs at least one field"); }
        rtsize[r] = off;
        nrt = nrt + 1;
    }
    if(kwnamed(61, 61)){ failkeyword("a type", 0); }
    return 0;
}

long declconsts(long islocal){
    long o; long v; long t;
    next();                                          /* skip 'const' */
    if(iskw()){ failkeyword("a constant", 0); }
    if(tok != TK_ID){ fail("constant name expected"); }
    while(tok == TK_ID){
        if(bicode() != 0){ fail("that name is built in"); }
        if(islocal){ if(findloc() >= 0){ failtaken("duplicate local declaration"); } }
        else { if(findglob() >= 0 || findfn() >= 0 || findtype() >= 0){ failtaken("duplicate declaration"); } }
        o = intern();
        next();
        if(tok != 61){ fail("missing = in constant declaration"); }
        next();
        if(tok == TK_CHR){ v = tval; next(); t = T_CHAR; }
        else if(tok == TK_STR){ v = tval; next(); t = T_STR; }
        else if(tok == KW_TRUE){ next(); v = 1; t = T_BOOL; }
        else if(tok == KW_FALSE){ next(); v = 0; t = T_BOOL; }
        else if(tok == TK_REAL){ v = tval; next(); t = T_REAL; }
        else if(tok == 45){
            next();
            if(tok == TK_REAL){ v = bxor(tval, 1L<<63); next(); t = T_REAL; }
            else { v = cexprfrom(0 - cterm()); t = T_INT; }
        }
        else { v = cexpr(); t = T_INT; }
        if(islocal){
            if(nloc >= MAXL){ fail("too many locals"); }
            lnam[nloc] = o; lkind[nloc] = SK_CONST; ltyp[nloc] = t; loff[nloc] = v;
            larr[nloc] = 0; llo[nloc] = 0; lhi[nloc] = 0;
            nloc = nloc + 1;
        } else {
            if(ngl >= MAXG){ fail("too many globals"); }
            gnam[ngl] = o; gkind[ngl] = SK_CONST; gval[ngl] = v; gtyp[ngl] = t;
            garr[ngl] = 0; glo[ngl] = 0; ghi[ngl] = 0;
            gfile[ngl] = declloc;
            gindex(ngl);
            ngl = ngl + 1;
        }
        if(tok != 59){ fail("missing ; after constant declaration"); }
        next();
    }
    if(kwnamed(61, 61)){ failkeyword("a constant", 0); }
    return 0;
}

/* ------------------------------------------------------------------ */
/* schema and tools: refused here                                      */
/* ------------------------------------------------------------------ */
/* This bootstrap compiler does not implement the schema/tools source generator
   : src/wantzel.wz declares no schema and no tools
   block, so it does not need to. 'schema' and 'tools' stay reserved words -- decltypes()
   and parseprogram() still recognise them, so a source file that uses one gets this
   message instead of a parse error further down. The self-hosted compiler (bin/wantzel)
   implements both in full; see src/wantzel.wz. */
long declschema(void){
    fail("this bootstrap compiler does not implement 'schema'; build bin/wantzel first (./build.sh) and use it instead");
    return 0;
}
long decltools(void){
    fail("this bootstrap compiler does not implement 'tools'; build bin/wantzel first (./build.sh) and use it instead");
    return 0;
}

/* ------------------------------------------------------------------ */
/* routines                                                            */
/* ------------------------------------------------------------------ */
long storeparam(long i,long off){
    if(i==0){ e(0x48); e(0x89); e(0xBD); }
    else if(i==1){ e(0x48); e(0x89); e(0xB5); }
    else if(i==2){ e(0x48); e(0x89); e(0x95); }
    else if(i==3){ e(0x48); e(0x89); e(0x8D); }
    else if(i==4){ e(0x4C); e(0x89); e(0x85); }
    else if(i==5){ e(0x4C); e(0x89); e(0x8D); }
    else if(i==6){ e(0x4C); e(0x89); e(0xA5); }
    else if(i==7){ e(0x4C); e(0x89); e(0xAD); }
    else if(i==8){ e(0x4C); e(0x89); e(0xB5); }
    else { e(0x4C); e(0x89); e(0xBD); }
    e32(off);
    return 0;
}

long declroutine(long isproc){
    long fi; long known; long np; long t; long o; long i;
    long zlea; long zcnt; long ztop; long zdone; long parmbytes; long endline; long saveline; long pisarr; long nr;
    next();
    if(iskw()){ failkeyword("a routine", 0); }
    if(tok != TK_ID){ fail("routine name expected"); }
    if(bicode() != 0){ fail("that name is built in"); }
    if(findglob() >= 0){ failtaken("name already used by a variable or constant"); }
    fi = findfn();
    known = 0;
    if(fi >= 0){
        if(fdef[fi]){ failtaken("routine already defined"); }
        known = 1;
    } else {
        if(nfn >= MAXF){ fail("too many routines"); }
        fi = nfn; nfn = nfn + 1;
        fnam[fi] = intern(); fdef[fi] = 0; fadr[fi] = 0;
        fvis[fi] = declloc;
        findex(fi);
    }
    fhline[fi] = line; fhfile[fi] = curfile;
    next();
    nloc = 0; frame = 0;
    np = 0;
    if(tok == 40){
        next();
        while(1){
            if(iskw()){ failkeyword("a parameter", 0); }
            if(tok != TK_ID){ fail("parameter name expected"); }
            o = 0;
            while(1){
                if(bicode() != 0){ fail("that name is built in"); }
                if(findloc() >= 0){ fail("duplicate parameter name"); }
                if(nloc >= MAXL){ fail("too many locals"); }
                lnam[nloc] = intern(); larr[nloc] = 0; llo[nloc] = 0; lhi[nloc] = 0; lkind[nloc] = SK_VAR;
                nloc = nloc + 1; o = o + 1;
                next();
                if(tok != 44){ break; }
                next();
            }
            if(tok != 58){ fail("missing : in parameter list"); }
            next();
            pisarr = 0;
            if(tok == KW_ARRAY){
                next();
                if(tok != KW_OF){ fail("an array parameter is written 'array of <type>'"); }
                next();
                pisarr = 2;
            }
            t = basetype();
            if(t >= T_REC && pisarr == 0){ fail("a record parameter is passed as 'array of <type>' (a one-element slice will do)"); }
            i = nloc - o;
            while(i < nloc){
                ltyp[i] = t; larr[i] = pisarr;
                frame = frame + 8; loff[i] = 0 - frame;
                if(pisarr != 0){ frame = frame + 8; }
                i = i + 1;
            }
            np = nloc;
            if(tok != 59){ break; }
            next();
        }
        if(tok != 41){ fail("missing ) in parameter list"); }
        next();
        np = nloc;
    }
    nr = 0;
    i = 0;
    while(i < np){
        nr = nr + 1;
        if(larr[i] != 0){ nr = nr + 1; }
        i = i + 1;
    }
    if(np > MAXP || nr > MAXP){ fail("a routine may take at most ten arguments (an array counts as two)"); }
    if(isproc){ t = T_VOID; }
    else {
        if(tok != 58){ fail("missing : before the result type"); }
        next();
        t = basetype();
        if(t >= T_REC){ fail("a function cannot return a record; fill one through an array parameter"); }
    }
    if(known){
        if(fnpar[fi] != np){ fail("parameter count differs from the forward declaration"); }
        if(frtyp[fi] != t){ fail("result type differs from the forward declaration"); }
        i = 0;
        while(i < np){
            if(fptyp[fi*MAXP+i] != ltyp[i]){ fail("parameter type differs from the forward declaration"); }
            if(fparr[fi*MAXP+i] != larr[i]){ fail("parameter type differs from the forward declaration"); }
            i = i + 1;
        }
    } else {
        fnpar[fi] = np; frtyp[fi] = t; fnreg[fi] = nr;
        i = 0;
        while(i < np){ fptyp[fi*MAXP+i] = ltyp[i]; fparr[fi*MAXP+i] = larr[i]; i = i + 1; }
    }
    if(tok != 59){ fail("missing ; after the routine header"); }
    next();
    if(tok == KW_FORWARD){
        /* the line of the DECLARATION, before next() walks past the ';' onto the
           following line -- otherwise an unresolved forward is reported one line
           too far down. */
        fline[fi] = line;
        ffile[fi] = curfile;
        /* No <tools>-generated forward ever reaches here: this bootstrap compiler does
           not implement 'tools', so every forward is from real source
           and fline/ffile above are already right. */
        next();
        if(tok != 59){ fail("missing ; after forward"); }
        next();
        return 0;
    }
    /* --- body --- */
    parmbytes = frame;
    fadr[fi] = codelen; fdef[fi] = 1;
    curfn = fi; curret = t;
    saveline = line; line = fhline[fi];
    dbline(112);
    line = saveline;
    nbrk = 0; ncnt = 0; brkbase = -1; cntbase = -1;
    e(0x55);                                        /* push rbp    */
    e(0x48); e(0x89); e(0xE5);                      /* mov rbp,rsp */
    e(0x48); e(0x81); e(0xEC); framepatch = codelen; e32(0);   /* sub rsp,N */
    e(0x48); e(0x8D); e(0x85); zlea = codelen; e32(0);         /* lea rax,[rbp-N] */
    e(0x49); e(0xBB); zcnt = codelen; e64(0);                  /* mov r11,count   */
    ztop = codelen;
    e(0x4D); e(0x85); e(0xDB);                      /* test r11,r11 */
    zdone = jfwd(0x0F,0x84);                        /* jz done      */
    e(0x48); e(0xC7); e(0x00); e32(0);              /* mov [rax],0  */
    e(0x48); e(0x83); e(0xC0); e(8);                /* add rax,8    */
    e(0x49); e(0x83); e(0xEB); e(1);                /* sub r11,1    */
    jmpto(0,0xE9,ztop);
    patch(zdone);
    i = 0; nr = 0;
    while(i < np){
        storeparam(nr,loff[i]); nr = nr + 1;
        if(larr[i] != 0){ storeparam(nr,loff[i]-8); nr = nr + 1; }
        i = i + 1;
    }
    while(tok == KW_VAR || tok == KW_CONST){
        if(tok == KW_VAR){ declvars(1); } else { declconsts(1); }
    }
    if(tok != KW_BEGIN){ fail("missing begin in routine body"); }
    next();
    stmtlist();
    if(tok != KW_END){ fail("missing end in routine body"); }
    endline = line;
    next();
    if(tok != 59){ fail("missing ; after routine body"); }
    next();
    saveline = line; line = endline;
    dbline(101);
    line = saveline;
    if(t == T_VOID){
        e(0x48); e(0x31); e(0xC0);
        epilogue();
    } else {
        saveline = line; line = endline;
        trap("function ended without executing a return");
        line = saveline;
    }
    while((frame % 16) != 0){ frame = frame + 8; }
    e32at(framepatch,frame);
    e32at(zlea,0 - frame);
    i = (frame - parmbytes) / 8;
    e32at(zcnt,i); e32at(zcnt+4,i>>32);
    fend[fi] = codelen;
    dbfunc(fi,np,t);
    nloc = 0;                                       /* locals do not outlive the routine */
    return 0;
}


/* ------------------------------------------------------------------ */
/* program                                                             */
/* ------------------------------------------------------------------ */
long emitprelude(){
    long i; long j; long k;
    entryoff = 0;
    /* entry stub: remember the initial stack pointer, run main, exit(0). */
    e(0x49); e(0xBA); fixup(FX_BSS,0); e64(0);  /* mov r10,&__argp */
    e(0x49); e(0x89); e(0x22);                  /* mov [r10],rsp   */
    e(0xE8); mainpatch = codelen; e32(0);           /* call main       */
    e(0x31); e(0xFF);                               /* xor edi,edi     */
    imm(231); syscallinsn();                        /* exit_group(0)   */
    emittrap();
    /* __arg(i,j): the j-th character of argument i, or 0 */
    argaddr = codelen;
    e(0x49); e(0xBA); fixup(FX_BSS,0); e64(0);      /* mov r10,&__argp */
    e(0x4D); e(0x8B); e(0x12);                      /* mov r10,[r10]   */
    e(0x49); e(0x3B); e(0x3A);                      /* cmp rdi,[r10]   */
    e(0x0F); e(0x83); e32(43);                      /* jae bad         */
    e(0x4D); e(0x8B); e(0x5C); e(0xFA); e(0x08);    /* mov r11,[r10+rdi*8+8] */
    e(0x31); e(0xC0);                               /* xor eax,eax     */
    e(0x49); e(0x0F); e(0xB6); e(0x0C); e(0x03);    /* movzx rcx,[r11+rax] */
    e(0x48); e(0x85); e(0xC9);                      /* test rcx,rcx    */
    e(0x0F); e(0x84); e32(22);                      /* jz bad          */
    e(0x48); e(0x39); e(0xF0);                      /* cmp rax,rsi     */
    e(0x0F); e(0x84); e32(9);                       /* je hit          */
    e(0x48); e(0x83); e(0xC0); e(0x01);             /* add rax,1       */
    e(0xE9); e32(0-32);                             /* jmp scan        */
    e(0x48); e(0x89); e(0xC8);                      /* hit: mov rax,rcx */
    e(0xC3);
    e(0x31); e(0xC0);                               /* bad: xor eax,eax */
    e(0xC3);
    /* __scan(rdi=base, rsi=len, rdx=from, rcx=to, r8b=byte) -> rax
       Compares sixteen bytes at a time; falls back to a byte loop for the
       tail.  Never reads past 'to', which the caller has checked against
       the length of the array. */
    scanaddr = codelen;
    e(0x66); e(0x41); e(0x0F); e(0x6E); e(0xC8);    /* movd      xmm1,r8d   */
    e(0x66); e(0x0F); e(0x60); e(0xC9);             /* punpcklbw xmm1,xmm1  */
    e(0x66); e(0x0F); e(0x61); e(0xC9);             /* punpcklwd xmm1,xmm1  */
    e(0x66); e(0x0F); e(0x70); e(0xC9); e(0x00);    /* pshufd    xmm1,xmm1,0*/
    e(0x48); e(0x89); e(0xD0);                      /* mov  rax,rdx         */
    i = codelen;                                    /* L16:                 */
    e(0x4C); e(0x8D); e(0x58); e(0x10);             /* lea  r11,[rax+16]    */
    e(0x49); e(0x39); e(0xCB);                      /* cmp  r11,rcx         */
    j = jfwd(0x0F,0x87);                            /* ja   tail            */
    e(0xF3); e(0x0F); e(0x6F); e(0x04); e(0x07);    /* movdqu xmm0,[rdi+rax]*/
    e(0x66); e(0x0F); e(0x74); e(0xC1);             /* pcmpeqb xmm0,xmm1    */
    e(0x66); e(0x44); e(0x0F); e(0xD7); e(0xC8);    /* pmovmskb r9d,xmm0    */
    e(0x45); e(0x85); e(0xC9);                      /* test r9d,r9d         */
    k = jfwd(0x0F,0x85);                            /* jnz  found           */
    e(0x4C); e(0x89); e(0xD8);                      /* mov  rax,r11         */
    jmpto(0,0xE9,i);
    patch(k);                                       /* found:               */
    e(0x45); e(0x0F); e(0xBC); e(0xC9);             /* bsf  r9d,r9d         */
    e(0x4C); e(0x01); e(0xC8);                      /* add  rax,r9          */
    e(0xC3);
    patch(j);                                       /* tail:                */
    i = codelen;
    e(0x48); e(0x39); e(0xC8);                      /* cmp  rax,rcx         */
    j = jfwd(0x0F,0x83);                            /* jae  done            */
    e(0x44); e(0x0F); e(0xB6); e(0x14); e(0x07);    /* movzx r10d,[rdi+rax] */
    e(0x45); e(0x39); e(0xC2);                      /* cmp  r10d,r8d        */
    k = jfwd(0x0F,0x84);                            /* je   done            */
    e(0x48); e(0x83); e(0xC0); e(0x01);             /* add  rax,1           */
    jmpto(0,0xE9,i);
    patch(j); patch(k);                             /* done:                */
    e(0xC3);
    return 0;
}

long parseprogram(){
    long i, nunres, mline, mfile, endline, saveline;
    emitprelude();
    next();
    while(1){
        /* A source that still carries the old 'program <name>;' header gets told so. */
        if(tok == TK_ID && eqt("program")){
            fail("the 'program' header is no longer part of the language; delete that line");
        }
        if(tok == KW_INCLUDE){ doinclude(); }
        else if(tok == KW_SCHEMA){ fail("a schema is declared as 'type X = schema ... end;'"); }
        else if(tok == KW_TOOLS){ decltools(); }
        /* `local` before a declaration limits it to this file.  declloc
           carries the file number until the declaration is read, then goes back to -1. */
        else if(tok == KW_LOCAL){
            next();
            declloc = curfile;
            if(tok == KW_CONST){ declconsts(0); }
            else if(tok == KW_VAR){ declvars(0); }
            else if(tok == KW_FUNCTION){ declroutine(0); }
            else if(tok == KW_PROCEDURE){ declroutine(1); }
            else { fail("after 'local' comes var, const, procedure or function"); }
            declloc = -1;
        }
        else if(tok == KW_CONST){ declconsts(0); }
        else if(tok == KW_TYPE){ decltypes(); }
        else if(tok == KW_VAR){ declvars(0); }
        else if(tok == KW_FUNCTION){ declroutine(0); }
        else if(tok == KW_PROCEDURE){ declroutine(1); }
        else { break; }
    }
    /* Report EVERY unresolved forward, not just the first: a program that serves HTTP
       defines several hooks from more than one library, and fixing them one compile at a
       time is the slow path.  Each is named, at the file and line of its declaration. */
    i = 0;
    nunres = 0;
    while(i < nfn){
        if(!fdef[i]){
            wrs(2, "wantzel: "); wrfile(2, ffile[i]); wrs(2, ":"); wrnum(2, fline[i]);
            wrs(2, ": forward declared routine "); wrnam(2, fnam[i]);
            wrs(2, " is never defined\n");
            nunres = nunres + 1;
        }
        i = i + 1;
    }
    if(nunres > 0){ _exit(1); }
    if(tok != KW_BEGIN){ fail("missing begin of the main program"); }
    mline = line; mfile = curfile;
    next();
    mainaddr = codelen;
    nloc = 0; frame = 0; curfn = -1; curret = T_VOID;
    nbrk = 0; ncnt = 0; brkbase = -1; cntbase = -1;
    saveline = line; line = mline;
    dbline(112);
    line = saveline;
    e(0x55); e(0x48); e(0x89); e(0xE5);
    e(0x48); e(0x81); e(0xEC); framepatch = codelen; e32(0);   /* sub rsp,N: room for hidden slots */
    stmtlist();
    if(tok != KW_END){ fail("missing end of the main program"); }
    endline = line;
    next();
    if(tok != 46){ fail("missing . after the final end"); }
    next();
    if(tok != TK_EOF){ fail("text after the end of the program"); }
    saveline = line; line = endline;
    dbline(101);
    line = saveline;
    e(0x48); e(0x31); e(0xC0);
    epilogue();
    while((frame % 16) != 0){ frame = frame + 8; }
    e32at(framepatch,frame);
    e32at(mainpatch,mainaddr - (mainpatch+4));
    if(dbgmode != 0){
        dbs("main "); dbnum(codebase + mainaddr); dbc(32); dbnum(codebase + codelen); dbc(32);
        dbnum(mfile); dbc(32); dbnum(mline); dbc(32); dbnum(frame); dbs(" void\n");
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* ELF output                                                          */
/* ------------------------------------------------------------------ */
char hdr[HDRLEN];
long hlen;

long ph(long b){ hdr[hlen] = (char)band(b,255); hlen = hlen + 1; return 0; }
long ph16(long v){ ph(v); ph(v>>8); return 0; }
long ph32(long v){ ph16(v); ph16(v>>16); return 0; }
long ph64(long v){ ph32(v); ph32(v>>32); return 0; }

long writeelf(){
    long datava; long bssva; long filesz; long memsz; long i; long k; long v; long fd;
    while((codelen % 8) != 0){ e(0x90); }
    datava = VBASE + HDRLEN + codelen;
    filesz = HDRLEN + codelen + datlen;
    bssva = VBASE + filesz;
    while((bssva % 8) != 0){ bssva = bssva + 1; }
    memsz = (bssva - VBASE) + bsslen;

    i = 0;
    while(i < nfx){
        k = fxkind[i];
        if(k == FX_CALL){
            e32at(fxoff[i],fadr[fxval[i]] - (fxoff[i]+4));
        } else if(k == FX_BSS32){
            e32at(fxoff[i],bssva + fxval[i]);
        } else {
            if(k == FX_DATA){ v = datava + fxval[i]; } else { v = bssva + fxval[i]; }
            e32at(fxoff[i],v);
            e32at(fxoff[i]+4,v>>32);
        }
        i = i + 1;
    }

    hlen = 0;
    ph(0x7F); ph(69); ph(76); ph(70);
    ph(2); ph(1); ph(1); ph(0);
    ph(0); ph(0); ph(0); ph(0); ph(0); ph(0); ph(0); ph(0);
    ph16(2); ph16(0x3E); ph32(1);
    ph64(VBASE + HDRLEN);
    ph64(64); ph64(0); ph32(0);
    ph16(64); ph16(56); ph16(1); ph16(64); ph16(0); ph16(0);
    ph32(1); ph32(7);
    ph64(0); ph64(VBASE); ph64(VBASE);
    ph64(filesz); ph64(memsz); ph64(0x1000);

    fd = opn((long)&outname[0],577,493);        /* O_WRONLY|O_CREAT|O_TRUNC, 0755 */
    if(fd < 0){ fail("cannot create the output file"); }
    wrbuf(fd,(long)&hdr[0],hlen);
    wrbuf(fd,(long)&code[0],codelen);
    wrbuf(fd,(long)&dat[0],datlen);
    cls(fd);
    chm((long)&outname[0],493);
    dbdata = datava; dbbss = bssva;
    return 0;
}


/* There is no writedbg() here: this bootstrap compiler never sets dbgmode (--debug is
   refused in main(), below), so the .wzdbg sidecar is never produced. dbline/dbfunc/dbc
   and friends stay -- they are the same counterpart logic as src/wantzel.wz and every
   call already checks dbgmode first, so with dbgmode always 0 they cost one branch each
   and never write anything. See docs/design.md for the sidecar format, which the
   self-hosted compiler (bin/wantzel) still writes in full. */

long compile(){
    long n;
    line = 1;
    srclen = 0; fnplen = 0; nfiles = 0; incdepth = 0;
    declloc = -1;   /* public is the default, so existing source is unchanged */
    curfile = addfile();              /* pathbuf holds the main source name */
    n = readfile();
    if(n < 0){
        wrs(2,"wantzel: cannot open "); wrname(2); wrs(2,"\n");
        return 1;
    }
    pos = 0; srcend = n;
    bsslen = 8;                       /* reserve __argp at bss offset 0 */
    dbglen = 0;
    codebase = VBASE + HDRLEN;
    parseprogram();
    writeelf();
    return 0;
}

long argeqc(char *a,char *s){
    long i;
    i = 0;
    while(1){
        if((long)(unsigned char)a[i] != sch(s,i)){ return 0; }
        if(sch(s,i) == 0){ return 1; }
        i = i + 1;
    }
    return 0;
}

/* argv[i] equal to s, without pulling in string.h. */
long argeqs(char *a,char *s){ long i = 0; while(1){ if(a[i] != s[i]){ return 0; } if(s[i] == 0){ return 1; } i = i + 1; } }

int main(int argc,char **argv){
    long i; long ai;
    /* --version before the argument count check: asking a compiler what it is should
       not require giving it a source file and an output name.  src/wantzel.wz carries
       the same string in its VERSION constant. */
    if(argc == 2 && (argeqs(argv[1],"--version") || argeqs(argv[1],"-v"))){
        wrs(1,"wantzel " VERSION "\n");
        /* AND WHERE THE LIBRARY IS, the counterpart of the same block in src/wantzel.wz.
           Since the standard library moved to disk, a compiler copied WITHOUT its lib/
           beside it fails on `include "io.wz"` -- and the honest answer to "is my install
           right?" is the path itself, plus whether anything is there. */
        setlibdir(argv[0]);
        wrs(1,"library ");
        if(libdirlen > 0){
            long fd; long n = libdirlen;
            wrbuf(1,(long)&libdir[0],libdirlen);
            /* io.wz is the probe: every program that includes anything includes it, so
               its absence is what the user hits first.  The probe is undone again --
               libdir is the real search path. */
            if(n + 6 < (long)sizeof(libdir)){
                libdir[n]='i'; libdir[n+1]='o'; libdir[n+2]='.';
                libdir[n+3]='w'; libdir[n+4]='z'; libdir[n+5]=0;
                fd = opn((long)&libdir[0],0,0);
                libdir[n] = 0;
                if(fd < 0) wrs(1,"   NOT FOUND -- copy lib/ next to the compiler");
                else cls(fd);
            }
        } else wrs(1,"(unknown -- the compiler could not find its own path)");
        wrs(1,"\n");
        return 0;
    }
    /* Run with no arguments at all, say what this program IS.  Someone who finds the
       binary without the repository around it has no other way to tell.  Only here: a
       successful compile stays silent, so this cannot end up in a build log. */
    if(argc < 3){
        wrs(2,"wantzel0 " VERSION " -- the C bootstrap compiler. It builds src/wantzel.wz and\n");
        wrs(2,"nothing else; the self-hosted compiler (bin/wantzel) is the one to use\n");
        wrs(2,"for --debug or any everyday compile.\n\n");
        wrs(2,"usage: wantzel0 <source.wz> <executable>\n");
        wrs(2,"       wantzel0 --version\n");
        return 1;
    }
    if(argc > 3){
        wrs(2,"wantzel0: too many arguments -- it takes exactly <source.wz> <executable>,\n");
        wrs(2,"no --debug. Use bin/wantzel (the self-hosted compiler) for that.\n");
        return 1;
    }
    setlibdir(argv[0]);
    i = 0; while(argv[1][i] != 0){ pathbuf[i] = argv[1][i]; i = i + 1; }
    pathbuf[i] = 0;
    i = 0; while(argv[2][i] != 0){ outname[i] = argv[2][i]; i = i + 1; }
    outname[i] = 0; outnamelen = i;
    return (int)compile();
}
