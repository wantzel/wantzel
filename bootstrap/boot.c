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
#define VERSION "0.2.1"
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
#define FX_WSYS 4   /* call __wsys, the Windows system call emulation */
#define FX_WINIT 5  /* call __winit, builds argv from the command line */
#define FX_IAT  6   /* rip-relative reference to an import table slot */
#define FX_FADR 7   /* the ABSOLUTE address of a routine, as a 64-bit value */
#define FX_SHIM 8
#define FX_SLOT 9   /* an import's IAT slot, resolved after every import is known */

/* the import index extslot last used, or -1 for a built-in */
long extlast;

/* virtual layout */
#define VBASE  0x400000
#define HDRLEN 120
#define HDRMAX 512
/* imported DLL functions.  The IAT holds KCOUNT kernel32 thunks, a null,
   then WCOUNT ws2_32 thunks, a null.  winapi(slot) indexes slot*8 into the
   IAT, so ws2_32 slots start at KCOUNT+1: the runtime numbers them that way. */
#define KCOUNT 27   /* kernel32 functions, IAT slots 0..26 */
#define WCOUNT 11   /* ws2_32 functions, IAT slots 28..38 */
#define ACOUNT 1    /* advapi32 functions, IAT slot 40 */
#define UCOUNT 9    /* user32 functions, IAT slots 42..50 */
#define NIMP   48   /* KCOUNT + WCOUNT + ACOUNT + UCOUNT, total names in impname */
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
long winmode, sysrawaddr, entryoff;
long tgiven;                        /* was --target= given? the output name never decides */

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
        if(pos + 2 >= srcend){ fail("a hex escape needs two digits"); }
        h = hexdig(srcb(pos + 1));
        l = hexdig(srcb(pos + 2));
        if(h < 0 || l < 0){ fail("a hex escape needs exactly two hex digits, as in x41 or xff after a backslash"); }
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
   remains the fallback when it cannot (no /proc). */
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

long fnbyname(char *s){
    long i; long j;
    i = 0;
    while(i < nfn){
        j = 0;
        while(namesb(fnam[i]+j) == sch(s,j)){
            if(sch(s,j) == 0){ return i; }
            j = j + 1;
        }
        i = i + 1;
    }
    fail("the Windows runtime is incomplete");
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

/* A system call: rax holds the Linux number, rdi..r9 the arguments.  A Linux
   executable executes the instruction; a Windows executable calls the shim
   that hands the same registers to __wsys, the emulation in Wantzel. */
long syscallinsn(){
    if(winmode != 0){
        e(0xE8); e32(sysrawaddr - (codelen+4));
    } else {
        e(0x0F); e(0x05);
    }
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
   quarter of a GUI binary. */
/* trapskip(fi) -- where the name of file fi starts, for a message stored IN THE BINARY.

   THE PROBLEM THIS SOLVES. trap embeds "<file>:<line>" as a string in the output, and the
   file name used to be whatever the compiler had resolved. So the same source compiled to
   two different binaries:

       wantzel src/main.wz out.exe                  ->  "src/main.wz:101"
       wantzel /abs/path/to/src/main.wz out.exe     ->  "/abs/path/to/src/main.wz:101"

   Measured on 16-09-2026 in a GUI program with 1288 checks: 513024 bytes against 581632,
   a 68KB difference out of identical source. Two things are wrong with that. A build is
   supposed to be reproducible, and it was not -- a build server naming its sources
   absolutely cannot produce the artifact a developer verified. And the second is worse:
   the build machine's directory layout, including a user's home directory, ends up inside
   every executable anyone ships. The embedded LIBRARY files leaked it either way, because
   they are named <libdir>/<name> and libdir is found from /proc/self/exe.

   THE RULE IS THE LAST TWO SEGMENTS OF THE DIRECTORY, AT MOST. A diagnostic has to say
   which file and which line; what it does not have to say is where the tree was checked
   out. "src/win32/main.wz:412" and "lib/io.wz:88" point a reader at the right file in the
   project, and carry nothing about the machine that built it.

   WHY SEGMENTS AND NOT A COMMON PREFIX, which is what I tried first: the main file can sit
   DEEPER than its includes (src/win32/main.wz including src/agent.wz), so stripping the
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
    o = datstr(1,mlen);

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
long dowinapi();
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

/* The Windows x64 convention: rcx, rdx, r8, r9, then the stack.  Arguments
   five to seven wait in r10, r11 and rdi until the call frame exists. */
long popwin(long i){
    if(i==0){ e(0x59); } else if(i==1){ e(0x5A); }
    else if(i==2){ e(0x41); e(0x58); } else if(i==3){ e(0x41); e(0x59); }
    else if(i==4){ e(0x41); e(0x5A); } else if(i==5){ e(0x41); e(0x5B); }
    else { e(0x5F); }
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
    if(eqt("winapi")){ return 16; }
    if(eqt("winproc")){ return 19; }
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

/* winapi(slot, args...): call an imported Windows function through the
   import address table.  The stack is aligned to sixteen bytes and given
   the 32-byte shadow space the convention demands; rsi keeps the old rsp,
   which every Windows function preserves. */
/* The call itself: arguments into the Windows registers, stack aligned, then an indirect
   call through the import address table. Shared by both winapi() forms. */
/* Call an imported function with n arguments, in the Windows convention.
   The arguments are already on OUR stack, pushed in order, so they are read from there
   instead of juggled through registers -- which is what removes the old limit of seven:
   the first four go in rcx, rdx, r8, r9 and the rest are copied into the shadow frame.
   On entry, relative to rsp: [0] is the last argument, [8*(n-1)] the first, [8*n] the
   IAT slot pushed before them. */
long winemit(long n){
    long i; long frame;
    e(0x48); e(0x89); e(0xE6);                      /* mov rsi,rsp          */
    e(0x48); e(0x8B); e(0x86); e32(8 * n);          /* mov rax,[rsi+8n]     */
    frame = 32;
    if(n > 4){ frame = frame + 8 * (n - 4); }
    if((frame % 16) != 0){ frame = frame + 8; }
    e(0x48); e(0x83); e(0xE4); e(0xF0);             /* and rsp,-16          */
    e(0x48); e(0x81); e(0xEC); e32(frame);          /* sub rsp,frame        */
    if(n > 0){ e(0x48); e(0x8B); e(0x8E); e32(8 * (n - 1)); }   /* mov rcx,[rsi+..] */
    if(n > 1){ e(0x48); e(0x8B); e(0x96); e32(8 * (n - 2)); }   /* mov rdx,[rsi+..] */
    if(n > 2){ e(0x4C); e(0x8B); e(0x86); e32(8 * (n - 3)); }   /* mov r8 ,[rsi+..] */
    if(n > 3){ e(0x4C); e(0x8B); e(0x8E); e32(8 * (n - 4)); }   /* mov r9 ,[rsi+..] */
    i = 4;
    while(i < n){
        e(0x4C); e(0x8B); e(0x96); e32(8 * (n - 1 - i));        /* mov r10,[rsi+..] */
        e(0x4C); e(0x89); e(0x54); e(0x24); e(8 * i);           /* mov [rsp+8i],r10 */
        i = i + 1;
    }
    e(0x48); e(0x8D); e(0x3D); fixup(FX_IAT,0); e32(0); /* lea rdi,[rip+iat] */
    e(0xFF); e(0x14); e(0xC7);                      /* call [rdi+rax*8]     */
    e(0x48); e(0x89); e(0xF4);                      /* mov rsp,rsi          */
    e(0x48); e(0x81); e(0xC4); e32(8 * (n + 1));    /* add rsp,8*(n+1)      */
    return T_INT;
}

long datlen0(long at);
long extput(long at, long n);
long endsdll(long at, long n);
long extslot(long dl, long dn, long fn, long fl);

/* The routine whose name is the token we are looking at, or -1. */
long fnbyname2(void){
    long i; long j;
    i = 0;
    while(i < nfn){
        j = 0;
        while(namesb(fnam[i]+j) == (unsigned char)tbuf[j] && tbuf[j] != 0){ j = j + 1; }
        if(namesb(fnam[i]+j) == 0 && tbuf[j] == 0){ return i; }
        i = i + 1;
    }
    return -1;
}

long dowinapi(){
    long n; long i;
    if(winmode == 0){ fail("winapi() is only available in a Windows executable"); }
    lparen();
    /* winapi("user32.dll", "MessageBoxA", ...) -- the source names the import and the
       compiler records it, so reaching a new DLL function is data rather than a change
       here. The slot form below stays: the generated runtime uses it throughout. */
    if(tok == TK_STR){
        long dn; long dl; long fn; long fl; long sl;
        dl = datlen0(tval); dn = extput(tval, dl);
        next();
        if(tok != 44){ fail("winapi(): after a DLL name comes the function name"); }
        next();
        if(tok != TK_STR){ fail("winapi(): the function name must be a string literal"); }
        fl = datlen0(tval); fn = extput(tval, fl);
        next();
        if(dn < 0 || fn < 0){ fail("winapi(): too many imported names"); }
        /* What can be judged here IS judged here: whether the DLL exists and whether it
           exports this function are the target machine's business, but an empty name or a
           DLL without its extension is wrong on any machine. */
        if(dl == 0){ fail("winapi(): the DLL name is empty"); }
        if(fl == 0){ fail("winapi(): the function name is empty"); }
        if(!endsdll(dn, dl)){
            fail("winapi(): a DLL name ends in .dll, for example \"user32.dll\"");
        }
        sl = extslot(dl, dn, fn, fl);
        if(sl < 0){ fail("winapi(): too many imported functions or DLLs"); }
        /* The slot cannot be known yet: extiat counts the imports of the same DLL that
           come BEFORE this one, and a later winapi() naming that DLL is still unparsed.
           A value baked in here is one short as soon as imports interleave, and the call
           lands on a null terminator -- address zero. Emit a fixup instead. */
        if(extlast >= 0){ e(0xB8); fixup(FX_SLOT, extlast); e32(0); }
        else { imm(sl); }
        push();
        n = 0;
        while(tok == 44){
            next();
            if(n >= 15){ fail("winapi() takes at most fifteen arguments"); }
            argint(); push();
            n = n + 1;
        }
        rparen();
        return winemit(n);
    }
    /* A slot is an index into the import address table, so a wrong one calls whatever
       happens to sit there. When it is a literal the compiler knows enough to refuse. */
    if(tok == TK_INT){
        if(tval < 0 || tval >= NIMP){ fail("winapi(): that import slot does not exist"); }
    }
    argint(); push();
    n = 0;
    while(tok == 44){
        next();
        if(n >= 15){ fail("winapi() takes at most fifteen arguments"); }
        argint(); push();
        n = n + 1;
    }
    rparen();
    return winemit(n);
}

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
    if(b == 16){ return dowinapi(); }
    if(b == 19){
        /* winproc(name): the address of a routine, as an int, so Windows can call it back.
           Deliberately not addr() on any routine -- that would be a function pointer in a
           language that does not have one. This opens the door exactly as wide as the need. */
        long fi;
        if(winmode == 0){ fail("winproc() is only available in a Windows executable"); }
        lparen();
        if(tok != TK_ID){ fail("winproc() takes the name of a routine"); }
        fi = fnbyname2();
        if(fi < 0){ fail("winproc(): no such routine"); }
        next(); rparen();
        /* An ADAPTER, not the routine's own address. Windows hands a callback its
           arguments in rcx, rdx, r8, r9; a Wantzel routine expects them in rdi, rsi, rdx,
           rcx. Returning the bare address would compile and then read the wrong registers.
           Four arguments is not a limit we chose: it is what the Windows convention passes
           in registers, and every callback in the Win32 surface fits in it. */
        {
            long gi; long at;
            gi = jfwd(0, 0xE9);                        /* jump over the shim   */
            at = codelen;                              /* the shim's address   */
            /* rdi, rsi and rbx are NONVOLATILE on Windows and volatile on Linux -- the
               one place the conventions disagree about who owns a register. Wantzel uses
               rdi and rsi for parameters, so not saving them hands Windows back its own
               registers with our values in them: a crash later, somewhere else. */
            e(0x57);                                   /* push rdi             */
            e(0x56);                                   /* push rsi             */
            e(0x53);                                   /* push rbx             */
            e(0x49); e(0x89); e(0xCA);                 /* mov r10, rcx         */
            e(0x49); e(0x89); e(0xD3);                 /* mov r11, rdx         */
            e(0x4C); e(0x89); e(0xD7);                 /* mov rdi, r10         */
            e(0x4C); e(0x89); e(0xDE);                 /* mov rsi, r11         */
            e(0x4C); e(0x89); e(0xC2);                 /* mov rdx, r8          */
            e(0x4C); e(0x89); e(0xC9);                 /* mov rcx, r9          */
            e(0x48); e(0x83); e(0xEC); e(0x20);        /* sub rsp,32  shadow   */
            e(0xE8); fixup(FX_CALL, fi); e32(0);       /* call the routine     */
            e(0x48); e(0x83); e(0xC4); e(0x20);        /* add rsp,32           */
            e(0x5B); e(0x5E); e(0x5F);                 /* pop rbx, rsi, rdi    */
            e(0xC3);                                   /* ret, result in rax   */
            patch(gi);
            e(0x48); e(0xB8); fixup(FX_SHIM, at); e64(0);  /* mov rax, <shim>  */
        }
        return T_INT;
    }               /* winapi(slot,args):int */
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
           notation and nothing else, and the word after '=' says which. */
        if(tok == KW_SCHEMA){
            if(nsc >= MAXS){ fail("too many schemas"); }
            i = 0;
            while(tnamebuf[i] != 0){
                schname[i] = tnamebuf[i]; scnam[nsc*64+i] = tnamebuf[i]; i = i + 1;
            }
            schname[i] = 0; scnam[nsc*64+i] = 0;
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
                if(tok != TK_ID){ fail("field name expected"); }
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
        if(tok != KW_END){ fail("missing end of the record"); }
        next();
        if(tok != 59){ fail("missing ; after the type"); }
        next();
        while((off % 8) != 0){ off = off + 1; }
        if(off == 0){ fail("a record needs at least one field"); }
        rtsize[r] = off;
        nrt = nrt + 1;
    }
    return 0;
}

long declconsts(long islocal){
    long o; long v; long t;
    next();                                          /* skip 'const' */
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
    return 0;
}


/* ------------------------------------------------------------------ */
/* schema: parse the declaration, then generate Wantzel source for it      */
/* ------------------------------------------------------------------ */
/* Generated text is appended to the source buffer and entered through the
   same mechanism as an include, so it is compiled like any other code. */
/* One byte of generated source, with the room checked BEFORE the write -- the same
   reason as dput above: a check afterwards has already stored the byte that does not
   fit, which turns "the source is too large" into a bounds trap inside this compiler. */
long sput(long c){
    if(srclen >= SRCMAX){ fail("generated source is too large"); }
    src[srclen] = (char)c; srclen = srclen + 1; return 0;
}

long gen(char *t){
    long i;
    i = 0;
    while(t[i] != 0){ sput((long)(unsigned char)t[i]); i = i + 1; }
    return 0;
}
long gennum(long v){
    long n; long i;
    n = numstr(v);
    i = 0;
    while(i < n){ sput((long)(unsigned char)nbuf[i]); i = i + 1; }
    return 0;
}
long genname(){                       /* the schema name */
    long i;
    i = 0;
    while(schname[i] != 0){ sput((long)(unsigned char)schname[i]); i = i + 1; }
    return 0;
}
long genfld(long f){                  /* the bare field name */
    long i;
    i = 0;
    while(sfld[f*64+i] != 0){ sput((long)(unsigned char)sfld[f*64+i]); i = i + 1; }
    return 0;
}
long genr(long f){                    /* r[0].field */
    gen("r[0]."); genfld(f);
    return 0;
}
long gensub(long f){                  /* the nested schema's name */
    long i;
    i = 0;
    while(scnam[sfsub[f]*64+i] != 0){ sput((long)(unsigned char)scnam[sfsub[f]*64+i]); i = i + 1; }
    return 0;
}
long genjs(long f){                   /* the JSON key, as it was written */
    long i;
    i = 0;
    while(sfjson[f*64+i] != 0){ sput((long)(unsigned char)sfjson[f*64+i]); i = i + 1; }
    return 0;
}
long genquoted(long e){               /* "value" from the enum pool */
    long i;
    sput(34);
    i = 0;
    while(senum[e*64+i] != 0){ sput((long)(unsigned char)senum[e*64+i]); i = i + 1; }
    sput(34);
    return 0;
}
long genident(long e){                /* enum value as an identifier */
    long i; long c;
    i = 0;
    while(senum[e*64+i] != 0){
        c = (long)(unsigned char)senum[e*64+i];
        if(!isal(c) && !isdg(c)){ c = 95; }
        sput(c); i = i + 1;
    }
    return 0;
}

/* the Wantzel type of a field's element */
long genelemtype(long f){
    long t;
    t = sftype[f];
    if(t == SF_INT || t == SF_ENUM){ gen("int"); }
    else if(t == SF_REAL){ gen("real"); }
    else if(t == SF_BOOL){ gen("bool"); }
    else if(t == SF_SUB){ gensub(f); }
    return 0;
}

/* the record fields of one schema field */
long gendecl(long f){
    long t;
    t = sftype[f];
    gen("  ");
    if(sfarr[f]){
        if(t == SF_TEXTN){
            genfld(f); gen(": array[0.."); gennum(sfcount[f]*sftlen[f]-1); gen("] of char;\n  ");
            genfld(f); gen("_len: array[0.."); gennum(sfcount[f]-1); gen("] of int;\n  ");
        } else {
            genfld(f); gen(": array[0.."); gennum(sfcount[f]-1); gen("] of "); genelemtype(f); gen(";\n  ");
        }
        genfld(f); gen("_n: int;\n  ");
    } else if(t == SF_TEXT || t == SF_JSON){
        genfld(f); gen("_at: int;\n  "); genfld(f); gen("_end: int;\n  ");
    } else if(t == SF_TEXTN){
        genfld(f); gen(": array[0.."); gennum(sftlen[f]-1); gen("] of char;\n  ");
        genfld(f); gen("_n: int;\n  ");
    } else {
        genfld(f); gen(": "); genelemtype(f); gen(";\n  ");
    }
    genfld(f); gen("_ok: bool;\n  "); genfld(f); gen("_null: bool;\n");
    return 0;
}

/* read one value at `at` into target tgt (0: the field, 1: element v1) */
long genread(long f,long tgt){
    long t; long ei;
    t = sftype[f];
    if(t == SF_INT){
        gen("        at := json.number(b, at, last);\n        if at < 0 then return -1;\n        ");
        genr(f); if(tgt){ gen("[v1]"); } gen(" := json.ival;\n");
    } else if(t == SF_REAL){
        gen("        at := json.real(b, at, last);\n        if at < 0 then return -1;\n        ");
        genr(f); if(tgt){ gen("[v1]"); } gen(" := json.rval;\n");
    } else if(t == SF_BOOL){
        gen("        at := json.boolean(b, at, last);\n        if at < 0 then return -1;\n        ");
        genr(f); if(tgt){ gen("[v1]"); } gen(" := json.bval;\n");
    } else if(t == SF_TEXT){
        gen("        at := json.string(b, at, last);\n        if at < 0 then return -1;\n        ");
        genr(f); gen("_at := json.sat;\n        "); genr(f); gen("_end := json.send;\n");
    } else if(t == SF_JSON){
        gen("        v0 := json.ws(b, at, last);\n        at := json.skip(b, at, last);\n        if at < 0 then return -1;\n        ");
        genr(f); gen("_at := v0;\n        "); genr(f); gen("_end := at;\n");
    } else if(t == SF_ENUM){
        gen("        at := json.string(b, at, last);\n        if at < 0 then return -1;\n        ");
        genr(f); gen(" := -1;\n");
        ei = 0;
        while(ei < sfen[f]){
            if(ei == 0){ gen("        if json.eq(b, json.sat, json.send, "); }
            else { gen("        else if json.eq(b, json.sat, json.send, "); }
            genquoted(sfe0[f]+ei);
            gen(") then "); genr(f); gen(" := "); gennum(ei); gen("\n");
            ei = ei + 1;
        }
        gen("        else ;\n");
    } else if(t == SF_TEXTN){
        gen("        at := json.string(b, at, last);\n        if at < 0 then return -1;\n");
        if(tgt){
            gen("        n := json.copystr(b, json.sat, json.send, "); genr(f);
            gen("[v1 * "); gennum(sftlen[f]); gen("..v1 * "); gennum(sftlen[f]); gen(" + "); gennum(sftlen[f]-1); gen("]);\n");
            gen("        if n < 0 then return -1;\n        "); genr(f); gen("_len[v1] := n;\n");
        } else {
            gen("        n := json.copystr(b, json.sat, json.send, "); genr(f); gen(");\n");
            gen("        if n < 0 then return -1;\n        "); genr(f); gen("_n := n;\n");
        }
    } else if(t == SF_SUB){
        gen("        at := "); gensub(f); gen(".parse(b, at, last, "); genr(f);
        if(tgt){ gen("[v1..v1]"); }
        gen(");\n        if at < 0 then return -1;\n");
    }
    return 0;
}

/* one "if json.eq(...) then <read the value> end else" arm */
long genarm(long f){
    gen("    if json.eq(b, k0, k1, \""); genjs(f); gen("\") then\n    begin\n");
    gen("      if json.isnull(b, at, last) then\n      begin\n");
    gen("        at := json.ws(b, at, last) + 4;\n        "); genr(f); gen("_null := true;\n      end\n      else\n      begin\n");
    if(sfarr[f]){
        gen("        at := json.ws(b, at, last);\n        if at >= last then return -1;\n");
        gen("        if b[at] <> '[' then return -1;\n        at := at + 1;\n        v1 := 0;\n");
        gen("        while true do\n        begin\n");
        gen("        at := json.ws(b, at, last);\n        if at >= last then return -1;\n");
        gen("        if b[at] = ']' then\n        begin\n          at := at + 1;\n          break;\n        end;\n");
        gen("        if b[at] = ',' then\n        begin\n          at := at + 1;\n          continue;\n        end;\n");
        gen("        if v1 >= "); gennum(sfcount[f]); gen(" then return -1;\n");
        genread(f,1);
        gen("        v1 := v1 + 1;\n        end;\n        "); genr(f); gen("_n := v1;\n");
    } else {
        genread(f,0);
    }
    gen("      end;\n      "); genr(f); gen("_ok := true;\n    end\n    else ");
    return 0;
}

/* The truncation test that follows every appending call in a generated writer.
   json.putreal, json.putraw, json.putstr, io.push and io.pushnum truncate at len(dst)
   instead of signalling, so after such a call `at = len(dst)` is the only
   evidence that something was dropped.  For an error message truncation is harmless;
   for a JSON object it is not -- what comes out is not a shorter object but a syntax
   error -- so the writer turns it into the refusal -1 here. */
long genfull(){
    gen("      if at >= len(dst) then return -1;\n");
    return 0;
}

/* write one value; src expression is the field (tgt 0) or element v1 (tgt 1) */
long genput(long f,long tgt){
    long t; long ei;
    t = sftype[f];
    if(t == SF_INT){ gen("      at := io.pushnum(dst, at, "); genr(f); if(tgt){ gen("[v1]"); } gen(");\n"); genfull(); }
    else if(t == SF_REAL){
        /* json.putreal is the one appender that neither truncates nor signals: without
           room for its longest form (32 bytes of headroom) it writes NOTHING and returns
           `at` unchanged, which would leave a key with no value at all in the output --
           invalid JSON that the len(dst) test below cannot see, because `at` never
           reached the end.  So the room is tested here, before the call, and a refusal
           comes out instead. */
        gen("      if (at < 0) or (at + 32 > len(dst)) then return -1;\n");
        gen("      at := json.putreal(dst, at, "); genr(f); if(tgt){ gen("[v1]"); } gen(");\n"); genfull();
    }
    else if(t == SF_BOOL){
        gen("      if "); genr(f); if(tgt){ gen("[v1]"); }
        gen(" then at := io.push(dst, at, \"true\") else at := io.push(dst, at, \"false\");\n");
        genfull();
    }
    else if(t == SF_TEXT){
        gen("      at := json.putb(dst, at, '\"');\n      at := json.putraw(dst, at, src, "); genr(f); gen("_at, "); genr(f); gen("_end);\n");
        genfull();
        gen("      at := json.putb(dst, at, '\"');\n");
    }
    else if(t == SF_JSON){ gen("      at := json.putraw(dst, at, src, "); genr(f); gen("_at, "); genr(f); gen("_end);\n"); genfull(); }
    else if(t == SF_ENUM){
        ei = 0;
        while(ei < sfen[f]){
            if(ei == 0){ gen("      if "); } else { gen("      else if "); }
            genr(f); gen(" = "); gennum(ei); gen(" then at := json.putstr(dst, at, "); genquoted(sfe0[f]+ei); gen(")\n");
            ei = ei + 1;
        }
        if(sfen[f] > 0){ gen("      else "); } else { gen("      "); }
        gen("at := io.push(dst, at, \"null\");\n");
        genfull();
    }
    else if(t == SF_TEXTN){
        if(tgt){
            gen("      at := json.putslice(dst, at, "); genr(f); gen(", v1 * "); gennum(sftlen[f]);
            gen(", v1 * "); gennum(sftlen[f]); gen(" + "); genr(f); gen("_len[v1]);\n");
        } else {
            gen("      at := json.putslice(dst, at, "); genr(f); gen(", 0, "); genr(f); gen("_n);\n");
        }
    }
    else if(t == SF_SUB){
        gen("      at := "); gensub(f); gen(".write(dst, at, "); genr(f); if(tgt){ gen("[v1..v1]"); } gen(", src);\n");
    }
    return 0;
}

long genschema(){
    long f; long ei;
    /* --- the record type --- */
    gen("\ntype\n  "); genname(); gen(" = record\n");
    f = 0;
    while(f < nfld){ gendecl(f); f = f + 1; }
    gen("  end;\n");
    /* --- enum constants and the field count --- */
    gen("const\n");
    f = 0;
    while(f < nfld){
        if(sftype[f] == SF_ENUM){
            ei = 0;
            while(ei < sfen[f]){
                gen("  "); genname(); gen("."); genfld(f); gen(".");
                genident(sfe0[f]+ei);
                gen(" = "); gennum(ei); gen(";\n");
                ei = ei + 1;
            }
        }
        f = f + 1;
    }
    gen("  "); genname(); gen(".fields = "); gennum(nfld); gen(";\n");
    /* --- clear --- */
    gen("\nprocedure "); genname(); gen(".clear(r: array of "); genname(); gen(");\nbegin\n");
    f = 0;
    while(f < nfld){
        if(sfarr[f]){ gen("  "); genr(f); gen("_n := 0;\n"); }
        else if(sftype[f] == SF_INT){ gen("  "); genr(f); gen(" := 0;\n"); }
        else if(sftype[f] == SF_ENUM){ gen("  "); genr(f); gen(" := -1;\n"); }
        else if(sftype[f] == SF_REAL){ gen("  "); genr(f); gen(" := real(0);\n"); }
        else if(sftype[f] == SF_BOOL){ gen("  "); genr(f); gen(" := false;\n"); }
        else if(sftype[f] == SF_TEXT || sftype[f] == SF_JSON){ gen("  "); genr(f); gen("_at := 0;\n  "); genr(f); gen("_end := 0;\n"); }
        else if(sftype[f] == SF_TEXTN){ gen("  "); genr(f); gen("_n := 0;\n"); }
        else if(sftype[f] == SF_SUB){ gen("  "); gensub(f); gen(".clear("); genr(f); gen(");\n"); }
        gen("  "); genr(f); gen("_ok := false;\n  "); genr(f); gen("_null := false;\n");
        f = f + 1;
    }
    gen("end;\n");
    /* --- parse --- */
    gen("\nfunction "); genname(); gen(".parse(b: array of char; at: int; last: int; r: array of "); genname();
    gen("): int;\nvar k0, k1, v0, v1, n: int;\nbegin\n  "); genname(); gen(".clear(r);\n");
    gen("  k0 := 0; k1 := 0; v0 := 0; v1 := 0; n := 0;\n");
    gen("  json.badkey0 := 0; json.badkey1 := 0;\n");
    gen("  at := json.ws(b, at, last);\n");
    gen("  if at >= last then return -1;\n");
    gen("  if b[at] <> '{' then return -1;\n");
    gen("  at := at + 1;\n");
    gen("  while true do\n  begin\n");
    gen("    at := json.ws(b, at, last);\n");
    gen("    if at >= last then return -1;\n");
    gen("    if b[at] = '}' then\n    begin\n");
    f = 0;
    while(f < nfld){
        if(!sfopt[f]){ gen("      if (not "); genr(f); gen("_ok) or "); genr(f); gen("_null then return -1;\n"); }
        f = f + 1;
    }
    gen("      return at + 1;\n    end;\n");
    gen("    if b[at] = ',' then\n    begin\n      at := at + 1;\n      continue;\n    end;\n");
    gen("    at := json.string(b, at, last);\n");
    gen("    if at < 0 then return -1;\n");
    gen("    k0 := json.sat;\n    k1 := json.send;\n");
    gen("    at := json.ws(b, at, last);\n");
    gen("    if at >= last then return -1;\n");
    gen("    if b[at] <> ':' then return -1;\n");
    gen("    at := at + 1;\n");
    f = 0;
    while(f < nfld){ genarm(f); f = f + 1; }
    /* An UNKNOWN KEY IS REFUSED; this chain used to end in a json.skip that swallowed
       it, so a caller sending a renamed field got a normal answer computed with the
       default.  json.badkey0/1 name the key. */
    gen("\n    begin\n      json.badkey0 := k0; json.badkey1 := k1;\n      return -1;\n    end;\n");
    gen("  end;\n  return -1;\nend;\n");
    /* --- write --- */
    gen("\n// Returns the position after the object, or -1 when it does not fit in dst.\n");
    gen("  // A short buffer is a refusal, not a truncation: half a JSON object is not a\n");
    gen("  // shorter object but a syntax error, and this text goes out as the\n");
    gen("  // structuredContent of a protocol reply.\n");
    gen("function "); genname(); gen(".write(dst: array of char; at: int; r: array of "); genname();
    gen("; src: array of char): int;\nvar v1: int;\n    first: bool;\nbegin\n");
    gen("  at := json.putb(dst, at, '{');\n  first := true;\n  v1 := 0;\n");
    f = 0;
    while(f < nfld){
        if(sfopt[f]){ gen("  if "); genr(f); gen("_ok then\n"); }
        gen("  begin\n    if not first then at := json.putb(dst, at, ',');\n    first := false;\n");
        gen("    at := io.push(dst, at, \"\\\""); genjs(f); gen("\\\":\");\n    if at >= len(dst) then return -1;\n");
        gen("    if "); genr(f); gen("_null then\n    begin\n      at := io.push(dst, at, \"null\");\n      if at >= len(dst) then return -1;\n    end\n    else\n    begin\n");
        if(sfarr[f]){
            gen("      at := json.putb(dst, at, '[');\n");
            gen("      for v1 := 0 to "); genr(f); gen("_n - 1 do\n      begin\n");
            gen("      if v1 > 0 then at := json.putb(dst, at, ',');\n");
            genput(f,1);
            gen("      end;\n      at := json.putb(dst, at, ']');\n");
        } else {
            genput(f,0);
        }
        gen("    end;\n  end;\n");
        f = f + 1;
    }
    gen("  return json.putb(dst, at, '}');\nend;\n");
    return 0;
}

/* --- the JSON Schema text --- */
long jsc(long c){
    if(jslen >= JSMAX-1){ fail("the JSON Schema of this schema is too large"); }
    jsbuf[jslen] = (char)c; jslen = jslen + 1;
    return 0;
}
long jss(char *s){ long i; i = 0; while(s[i] != 0){ jsc((long)(unsigned char)s[i]); i = i + 1; } return 0; }
long jsnum(long v){ long n; long i; n = numstr(v); i = 0; while(i < n){ jsc((long)(unsigned char)nbuf[i]); i = i + 1; } return 0; }
long jsdat(long o){                   /* a NUL-terminated text from the data segment, escaped */
    long c;
    while(dat[o] != 0){
        c = (long)(unsigned char)dat[o];
        if(c == 34 || c == 92){ jsc(92); jsc(c); }
        else if(c == 10){ jsc(92); jsc(110); }
        else if(c < 32){ jsc(32); }
        else { jsc(c); }
        o = o + 1;
    }
    return 0;
}
long jsraw(long o){ while(dat[o] != 0){ jsc((long)(unsigned char)dat[o]); o = o + 1; } return 0; }
long jselem(long f){                  /* the schema of one element */
    long t; long ei; long i;
    t = sftype[f];
    if(t == SF_INT){ jss("{\"type\":\"integer\"}"); }
    else if(t == SF_REAL){ jss("{\"type\":\"number\"}"); }
    else if(t == SF_BOOL){ jss("{\"type\":\"boolean\"}"); }
    else if(t == SF_TEXT){ jss("{\"type\":\"string\"}"); }
    else if(t == SF_TEXTN){ jss("{\"type\":\"string\",\"maxLength\":"); jsnum(sftlen[f]); jsc(125); }
    else if(t == SF_JSON){ jss("{}"); }
    else if(t == SF_SUB){ jsraw(scjs[sfsub[f]]); }
    else {
        jss("{\"type\":\"string\",\"enum\":[");
        ei = 0;
        while(ei < sfen[f]){
            if(ei > 0){ jsc(44); }
            jsc(34);
            i = 0;
            while(senum[(sfe0[f]+ei)*64+i] != 0){ jsc((long)(unsigned char)senum[(sfe0[f]+ei)*64+i]); i = i + 1; }
            jsc(34);
            ei = ei + 1;
        }
        jss("]}");
    }
    return 0;
}
long genjsonschema(){
    long f; long i; long first;
    jslen = 0;
    jss("{\"type\":\"object\",\"properties\":{");
    f = 0;
    while(f < nfld){
        if(f > 0){ jsc(44); }
        jsc(34); i = 0; while(sfjson[f*64+i] != 0){ jsc((long)(unsigned char)sfjson[f*64+i]); i = i + 1; } jsc(34); jsc(58);
        if(sfarr[f]){
            jss("{\"type\":\"array\",\"items\":"); jselem(f); jss(",\"maxItems\":"); jsnum(sfcount[f]);
            if(sfdesc[f] >= 0){ jss(",\"description\":\""); jsdat(sfdesc[f]); jsc(34); }
            jsc(125);
        } else if(sfdesc[f] >= 0){
            jselem(f);
            jslen = jslen - 1;                     /* reopen the element object */
            if(sftype[f] == SF_JSON){ jss("\"description\":\""); }
            else { jss(",\"description\":\""); }
            jsdat(sfdesc[f]); jsc(34); jsc(125);
        } else {
            jselem(f);
        }
        f = f + 1;
    }
    jss("},\"required\":[");
    first = 1;
    f = 0;
    while(f < nfld){
        if(!sfopt[f]){
            if(!first){ jsc(44); }
            first = 0;
            jsc(34); i = 0; while(sfjson[f*64+i] != 0){ jsc((long)(unsigned char)sfjson[f*64+i]); i = i + 1; } jsc(34);
        }
        f = f + 1;
    }
    jss("]}");
    jsc(0);
    /* into the data segment, as the value of the str constant Name.jsonschema */
    while((datlen % 8) != 0){ dput(0); }
    i = 0;
    while(i < 8){ dput(band((jslen-1) >> (i*8),255)); i = i + 1; }
    scjs[nsc] = datlen;
    i = 0;
    while(i < jslen){ dput((long)(unsigned char)jsbuf[i]); i = i + 1; }
    return 0;
}

long findschema(){                    /* the schema whose name is in tbuf, or -1 */
    long i; long j;
    i = 0;
    while(i < nsc){
        j = 0;
        while(scnam[i*64+j] == tbuf[j]){
            if(tbuf[j] == 0){ return i; }
            j = j + 1;
        }
        i = i + 1;
    }
    return -1;
}

/* The body of one schema, from the field list to 'end'.  The name, the '=' and the word
   'schema' are already read by decltypes, the only caller.  Counterpart of
   src/wantzel.wz:declschema. */
long declschema(){
    long i; long f; long fi; long lo; long hi;
    nfld = 0; nenum = 0;
    while(tok == TK_ID){
        if(nfld >= MAXFLD){ fail("too many fields in a schema"); }
        i = 0;
        while(tbuf[i] != 0){
            if(i >= 62){ fail("field name too long"); }
            sfld[nfld*64+i] = tbuf[i];
            sfjson[nfld*64+i] = obuf[i];
            i = i + 1;
        }
        sfld[nfld*64+i] = 0;
        sfjson[nfld*64+i] = 0;
        sfopt[nfld] = 0; sfe0[nfld] = 0; sfen[nfld] = 0; sfarr[nfld] = 0;
        sfcount[nfld] = 0; sftlen[nfld] = 0; sfsub[nfld] = -1; sfdesc[nfld] = -1;
        next();
        if(tok != 58){ fail("missing : after a schema field"); }
        next();
        if(tok == KW_ARRAY){
            next();
            if(tok != 91){ fail("missing [ in array field"); }
            next();
            lo = cexpr();
            if(tok != TK_RANGE){ fail("missing .. in array bounds"); }
            next();
            hi = cexpr();
            if(tok != 93){ fail("missing ] in array field"); }
            next();
            if(lo != 0 || hi < 0){ fail("a schema array is declared array[0..N] of ..."); }
            if(tok != KW_OF){ fail("missing of in array field"); }
            next();
            sfarr[nfld] = 1; sfcount[nfld] = hi + 1;
        }
        if(tok == KW_INT){ sftype[nfld] = SF_INT; next(); }
        else if(tok == KW_BOOL){ sftype[nfld] = SF_BOOL; next(); }
        else if(tok == KW_REAL){ sftype[nfld] = SF_REAL; next(); }
        else if(tok == TK_ID && eqt("text")){
            next();
            sftype[nfld] = SF_TEXT;
            if(tok == 91){                          /* text[N]: a copy */
                next();
                sftype[nfld] = SF_TEXTN;
                sftlen[nfld] = cexpr();
                if(sftlen[nfld] < 1){ fail("text[N] needs N >= 1"); }
                if(tok != 93){ fail("missing ] after the text length"); }
                next();
            }
            else if(tok == KW_OF){
                next();
                sftype[nfld] = SF_ENUM;
                if(tok != 40){ fail("missing ( after 'of'"); }
                next();
                sfe0[nfld] = nenum;
                while(1){
                    if(tok != TK_STR){ fail("a quoted value is expected here"); }
                    if(nenum >= MAXENUM){ fail("too many enumerated values"); }
                    i = 0;
                    while(dat[tval+i] != 0){
                        if(i >= 62){ fail("enumerated value too long"); }
                        senum[nenum*64+i] = dat[tval+i]; i = i + 1;
                    }
                    senum[nenum*64+i] = 0;
                    datlen = datmark;          /* not program data */
                    nenum = nenum + 1;
                    sfen[nfld] = sfen[nfld] + 1;
                    next();
                    if(tok != 44){ break; }
                    next();
                }
                if(tok != 41){ fail("missing ) after the values"); }
                next();
            }
        }
        else if(tok == TK_ID && eqt("json")){ sftype[nfld] = SF_JSON; next(); }
        else if(tok == TK_ID && findschema() >= 0){ sftype[nfld] = SF_SUB; sfsub[nfld] = findschema(); next(); }
        else { fail("a schema field is int, real, bool, text, text[N], text of (...), json, or a schema declared earlier"); }
        if(sfarr[nfld] && (sftype[nfld] == SF_TEXT || sftype[nfld] == SF_JSON || sftype[nfld] == SF_ENUM)){
            fail("a schema array holds int, real, bool, text[N] or a schema");
        }
        if(tok == 63){ sfopt[nfld] = 1; next(); }
        if(tok == TK_STR){ sfdesc[nfld] = tval; next(); }     /* the description stays in the data segment */
        if(tok != 59){ fail("missing ; after a schema field"); }
        next();
        nfld = nfld + 1;
    }
    if(tok != KW_END){ fail("missing end of the schema"); }
    next();
    if(tok != 59){ fail("missing ; after the schema"); }
    /* the JSON Schema text and its str constant */
    genjsonschema();
    i = 0;
    while(schname[i] != 0){ tbuf[i] = schname[i]; i = i + 1; }
    tbuf[i] = 46; tbuf[i+1] = 106; tbuf[i+2] = 115; tbuf[i+3] = 111; tbuf[i+4] = 110;
    tbuf[i+5] = 115; tbuf[i+6] = 99; tbuf[i+7] = 104; tbuf[i+8] = 101; tbuf[i+9] = 109; tbuf[i+10] = 97; tbuf[i+11] = 0;
    if(ngl >= MAXG){ fail("too many globals"); }
    gnam[ngl] = intern(); gkind[ngl] = SK_CONST; gtyp[ngl] = T_STR; gval[ngl] = scjs[nsc];
    garr[ngl] = 0; glo[ngl] = 0; ghi[ngl] = 0;
    gfile[ngl] = -1;                 /* compiler-generated: always public */
    gindex(ngl);
    ngl = ngl + 1;
    nsc = nsc + 1;
    /* generate, then compile the generated text like an include */
    if(incdepth >= 16){ fail("includes nested too deeply"); }
    pathbuf[0] = 60; f = 1;
    i = 0;
    while(schname[i] != 0){ pathbuf[f] = schname[i]; f = f + 1; i = i + 1; }
    pathbuf[f] = 62; pathbuf[f+1] = 0;
    fi = addfile();
    incpos[incdepth] = pos; incend[incdepth] = srcend;
    incline[incdepth] = line; incfile[incdepth] = curfile;
    incdepth = incdepth + 1;
    f = srclen;
    genschema();
    pos = f; srcend = srclen; line = 1; curfile = fi;
    next();
    return 0;
}


/* ------------------------------------------------------------------ */
/* tools: a declared tool table becomes tools/list text and a dispatcher */
/* ------------------------------------------------------------------ */
#define MAXT 1024
char tlnam[MAXT*64];
long tlin[MAXT], tlout[MAXT], tldesc[MAXT], tlro[MAXT], tlid[MAXT], tldes[MAXT];
long ntl, tlseen;
long tlline[MAXT], tlfile[MAXT];   /* where the tool was DECLARED, in the real source */
long tlfwdfile;                    /* pseudo-file id of the generated <tools> text */
long tlfwdn;                       /* forwards seen in it, in gentools order */

long gentl(long i){ long j; j = 0; while(tlnam[i*64+j] != 0){ sput((long)(unsigned char)tlnam[i*64+j]); j = j + 1; } return 0; }
long gensc(long k){ long j; j = 0; while(scnam[k*64+j] != 0){ sput((long)(unsigned char)scnam[k*64+j]); j = j + 1; } return 0; }
long jstl(long i){ long j; j = 0; while(tlnam[i*64+j] != 0){ jsc((long)(unsigned char)tlnam[i*64+j]); j = j + 1; } return 0; }

long gentools(){
    long i;
    /* --- the tools/list text, as the str constant tool.list --- */
    jslen = 0;
    i = 0;
    while(i < ntl){
        if(i > 0){ jsc(44); }
        jss("{\"name\":\""); jstl(i); jss("\",\"description\":\""); jsdat(tldesc[i]);
        jss("\",\"inputSchema\":"); jsraw(scjs[tlin[i]]);
        jss(",\"outputSchema\":"); jsraw(scjs[tlout[i]]);
        jss(",\"annotations\":{\"readOnlyHint\":"); if(tlro[i]){ jss("true"); } else { jss("false"); }
        jss(",\"destructiveHint\":"); if(tldes[i]){ jss("true"); } else { jss("false"); }
        jss(",\"idempotentHint\":"); if(tlid[i]){ jss("true"); } else { jss("false"); }
        jss("}}");
        i = i + 1;
    }
    jsc(0);
    while((datlen % 8) != 0){ dput(0); }
    i = 0;
    while(i < 8){ dput(band((jslen-1) >> (i*8),255)); i = i + 1; }
    tlseen = datlen;
    i = 0;
    while(i < jslen){ dput((long)(unsigned char)jsbuf[i]); i = i + 1; }
    i = 0;
    while("tool.list"[i] != 0){ tbuf[i] = "tool.list"[i]; i = i + 1; }
    tbuf[i] = 0;
    if(ngl >= MAXG){ fail("too many globals"); }
    gnam[ngl] = intern(); gkind[ngl] = SK_CONST; gtyp[ngl] = T_STR; gval[ngl] = tlseen;
    garr[ngl] = 0; glo[ngl] = 0; ghi[ngl] = 0;
    gfile[ngl] = -1;                 /* compiler-generated: always public */
    gindex(ngl);
    ngl = ngl + 1;
    /* --- constants, argument/result records, handler declarations --- */
    gen("\nconst\n  tool.count = "); gennum(ntl); gen(";\n");
    i = 0;
    while(i < ntl){ gen("  tool.id_"); gentl(i); gen(" = "); gennum(i); gen(";\n"); i = i + 1; }
    gen("var\n  tool.err: array[0..255] of char;\n  tool.errn: int;\n  tool.vbuf: array[0..1048575] of char;\n  tool.vn: int;\n");
    i = 0;
    while(i < ntl){
        gen("  tool.in_"); gentl(i); gen(": "); gensc(tlin[i]); gen(";\n");
        gen("  tool.out_"); gentl(i); gen(": "); gensc(tlout[i]); gen(";\n");
        i = i + 1;
    }
    gen("\n// a handler returns 0, or calls tool.fail with a message and returns its result\n");
    gen("function tool.fail(s: str): int;\nbegin\n  tool.errn := io.push(tool.err, 0, s);\n  return 1;\nend;\n");
    i = 0;
    while(i < ntl){
        gen("function tool."); gentl(i); gen("(a: array of "); gensc(tlin[i]); gen("; r: array of "); gensc(tlout[i]); gen("): int; forward;\n");
        i = i + 1;
    }
    /* --- byname --- */
    gen("\nfunction tool.byname(b: array of char; at: int; upto: int): int;\nbegin\n");
    i = 0;
    while(i < ntl){
        gen("  if json.eq(b, at, upto, \""); gentl(i); gen("\") then return "); gennum(i); gen(";\n");
        i = i + 1;
    }
    gen("  return -1;\nend;\n");
    /* --- run: parse arguments, call the handler, write the result JSON into dst --- */
    gen("\n// returns the length written, -1 for bad arguments, -2 when the handler failed\n");
    gen("  // (see tool.err), -3 when the result JSON does not fit in dst.  The writer\n");
    gen("  // refuses rather than truncating -- half an object is a syntax error -- and -3\n");
    gen("  // keeps that apart from -1, which would blame the caller's arguments for it.\n");
    gen("function tool.run(idx: int; b: array of char; at: int; upto: int; dst: array of char): int;\nvar rc: int;\nbegin\n  rc := 0;\n  tool.errn := 0;\n");
    i = 0;
    while(i < ntl){
        if(i == 0){ gen("  if idx = "); } else { gen("  else if idx = "); }
        gennum(i); gen(" then\n    begin\n      if "); gensc(tlin[i]); gen(".parse(b, at, upto, tool.in_"); gentl(i); gen(") < 0 then return -1;\n");
        gen("      "); gensc(tlout[i]); gen(".clear(tool.out_"); gentl(i); gen(");\n");
        gen("      tool.vn := 0;\n      rc := tool."); gentl(i); gen("(tool.in_"); gentl(i); gen(", tool.out_"); gentl(i); gen(");\n");
        gen("      if rc <> 0 then return -2;\n");
        gen("      rc := "); gensc(tlout[i]); gen(".write(dst, 0, tool.out_"); gentl(i); gen(", tool.vbuf);\n");
        gen("      if rc < 0 then return -3;\n      return rc;\n    end");
        /* No ';' before an 'else': an arm closes bare, the chain is ended once after
           the loop. A trailing ';' is reported as 'unexpected else'. */
        if(i < ntl - 1){ gen("\n"); } else { gen(";\n"); }
        i = i + 1;
    }
    gen("  return -1;\nend;\n");
    return 0;
}

/* tools  <name>(<InSchema>): <OutSchema> "<description>" [readonly] [idempotent] [destructive]; ... end; */
long decltools(){
    long i; long f; long fi;
    if(ntl > 0){ fail("tools are declared once"); }
    next();
    while(tok == TK_ID){
        if(ntl >= MAXT){ fail("too many tools"); }
        i = 0;
        while(tbuf[i] != 0){ if(i >= 62){ fail("tool name too long"); } tlnam[ntl*64+i] = tbuf[i]; i = i + 1; }
        tlnam[ntl*64+i] = 0;
        tlro[ntl] = 0; tlid[ntl] = 0; tldes[ntl] = 0; tldesc[ntl] = -1;
        tlline[ntl] = line; tlfile[ntl] = curfile;   /* the writer's own line */
        next();
        if(tok != 40){ fail("a tool is declared as name(InSchema): OutSchema \"description\""); }
        next();
        if(tok != TK_ID || findschema() < 0){ fail("the argument type of a tool is a schema"); }
        tlin[ntl] = findschema(); next();
        if(tok != 41){ fail("missing ) after the tool argument type"); }
        next();
        if(tok != 58){ fail("missing : before the tool result type"); }
        next();
        if(tok != TK_ID || findschema() < 0){ fail("the result type of a tool is a schema"); }
        tlout[ntl] = findschema(); next();
        if(tok != TK_STR){ fail("a tool needs a description in quotes"); }
        tldesc[ntl] = tval; next();
        while(tok == TK_ID){
            if(eqt("readonly")){ tlro[ntl] = 1; }
            else if(eqt("idempotent")){ tlid[ntl] = 1; }
            else if(eqt("destructive")){ tldes[ntl] = 1; }
            else { fail("a tool annotation is readonly, idempotent or destructive"); }
            next();
        }
        if(tok != 59){ fail("missing ; after a tool"); }
        next();
        ntl = ntl + 1;
    }
    if(tok != KW_END){ fail("missing end of the tools"); }
    next();
    if(tok != 59){ fail("missing ; after the tools"); }
    if(ntl == 0){ fail("the tools block is empty"); }
    if(incdepth >= 16){ fail("includes nested too deeply"); }
    i = 0;
    while("<tools>"[i] != 0){ pathbuf[i] = "<tools>"[i]; i = i + 1; }
    pathbuf[i] = 0;
    fi = addfile();
    tlfwdfile = fi; tlfwdn = 0;      /* see declroutine: the forwards below get the
                                        writer's own line rather than a <tools> line */
    incpos[incdepth] = pos; incend[incdepth] = srcend;
    incline[incdepth] = line; incfile[incdepth] = curfile;
    incdepth = incdepth + 1;
    f = srclen;
    gentools();
    pos = f; srcend = srclen; line = 1; curfile = fi;
    next();
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
    next();
    nloc = 0; frame = 0;
    np = 0;
    if(tok == 40){
        next();
        while(1){
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
        /* A FORWARD OUT OF THE GENERATED <tools> TEXT POINTS AT THE WRITER'S OWN
           DECLARATION: "<tools>:19" names a file nobody can open.
           gentools emits one forward per tool, in table order. */
        if(curfile == tlfwdfile && tlfwdn < ntl){
            fline[fi] = tlline[tlfwdn];
            ffile[fi] = tlfile[tlfwdn];
            tlfwdn = tlfwdn + 1;
        }
        next();
        if(tok != 59){ fail("missing ; after forward"); }
        next();
        return 0;
    }
    /* --- body --- */
    parmbytes = frame;
    fadr[fi] = codelen; fdef[fi] = 1;
    curfn = fi; curret = t;
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
    nloc = 0;                                       /* locals do not outlive the routine */
    return 0;
}

/* ------------------------------------------------------------------ */
/* the Windows runtime, compiled into every .exe before the program     */
/* ------------------------------------------------------------------ */
long genwin(){
    gen("// Windows runtime: the Linux system calls a Wantzel program uses, mapped onto\n");
    gen("  // kernel32 and ws2_32.  __wsys receives the Linux syscall number and its\n");
    gen("  // arguments and does the Windows equivalent; __winit turns the command line\n");
    gen("  // into an argc/argv block.  All of this is ordinary Wantzel, compiled into every\n");
    gen("  // .exe ahead of the program, so the code generator needs no Windows knowledge.\n");
    gen("  // epoll is emulated over WSAPoll, with a small interest table kept here.\n");
    gen("const\n");
    gen("  __K_GETSTDHANDLE = 0;\n");
    gen("  __K_WRITEFILE = 1;\n");
    gen("  __K_READFILE = 2;\n");
    gen("  __K_CREATEFILEA = 3;\n");
    gen("  __K_CLOSEHANDLE = 4;\n");
    gen("  __K_EXITPROCESS = 5;\n");
    gen("  __K_GETCMDLINE = 6;\n");
    gen("  __K_LSTRCPYN = 7;\n");
    gen("  __K_GETTIME = 8;\n");
    gen("  __K_SLEEP = 9;\n");
    gen("  __K_GETATTREX = 10;\n");
    gen("  __K_FINDFIRST = 11;\n");
    gen("  __K_FINDNEXT = 12;\n");
    gen("  __K_FINDCLOSE = 13;\n");
    gen("  __K_CREATEMAP = 14;\n");
    gen("  __K_MAPVIEW = 15;\n");
    gen("  __K_UNMAPVIEW = 16;\n");
    gen("  __K_FLUSHVIEW = 17;\n");
    gen("  __K_FLUSHFILE = 18;\n");
    gen("  __K_MOVEFILE = 19;\n");
    gen("  __K_SETPTR = 20;\n");
    gen("  __K_SETEOF = 21;\n");
    gen("  __K_DELETEFILE = 22;\n");
    gen("  __K_CREATEDIR = 23;\n");
    gen("  __K_REMOVEDIR = 24;\n");
    gen("  __K_LOCKFILE = 25;\n");
    gen("  __K_UNLOCKFILE = 26;\n");
    gen("  __W_WSASTARTUP = 28;\n");
    gen("  __W_SOCKET = 29;\n");
    gen("  __W_CLOSESOCKET = 30;\n");
    gen("  __W_SETSOCKOPT = 31;\n");
    gen("  __W_IOCTL = 32;\n");
    gen("  __W_BIND = 33;\n");
    gen("  __W_LISTEN = 34;\n");
    gen("  __W_ACCEPT = 35;\n");
    gen("  __W_SEND = 36;\n");
    gen("  __W_RECV = 37;\n");
    gen("  __W_WSAPOLL = 38;\n");
    gen("  __A_RANDOM = 40;\n");
    gen("  __WMAXFD = 1024;\n");
    gen("var\n");
    gen("  __wargv: array[0..63] of int;\n");
    gen("  __wargs: array[0..4095] of char;\n");
    gen("  __wdig: array[0..31] of char;\n");
    gen("  __wcount, __wdummy, __wstarted: int;\n");
    gen("  __wsh: array[0..__WMAXFD - 1] of int;   // socket handle for small fd, or 0\n");
    gen("  __wev: array[0..__WMAXFD - 1] of int;   // epoll events requested for fd\n");
    gen("  __wpoll: array[0..__WMAXFD * 16 - 1] of char;   // WSAPOLLFD array\n");
    gen("  __wrow: array[0..__WMAXFD - 1] of int;   // poll row -> fd\n");
    gen("  __wsa: array[0..15] of char;   // a working sockaddr\n");
    gen("  __wtime: array[0..7] of char;\n");
    gen("  __wdh: array[0..__WMAXFD - 1] of int;   // FindFirst handle per dir fd, or 0\n");
    gen("  __wdfirst: array[0..__WMAXFD - 1] of int;   // 1 = first entry already in __wfd32\n");
    gen("  __wfind: array[0..319] of char;   // WIN32_FIND_DATAA\n");
    gen("  __wpath: array[0..1039] of char;   // path + backslash-star\n");
    gen("  __wovl: array[0..31] of char;   // a zeroed OVERLAPPED for LockFileEx\n");
    gen("  __wpos: array[0..7] of char;   // SetFilePointerEx result\n");
    gen("\n");
    gen("procedure __wp32(b: array of char; at: int; v: int);\n");
    gen("begin\n");
    gen("  b[at]     := chr(band(v, 255));\n");
    gen("  b[at + 1] := chr(band(v shr 8, 255));\n");
    gen("  b[at + 2] := chr(band(v shr 16, 255));\n");
    gen("  b[at + 3] := chr(band(v shr 24, 255));\n");
    gen("end;\n");
    gen("\n");
    gen("function __wg32(b: array of char; at: int): int;\n");
    gen("var v: int;\n");
    gen("begin\n");
    gen("  v := ord(b[at]);\n");
    gen("  v := bor(v, ord(b[at + 1]) shl 8);\n");
    gen("  v := bor(v, ord(b[at + 2]) shl 16);\n");
    gen("  v := bor(v, ord(b[at + 3]) shl 24);\n");
    gen("  return v;\n");
    gen("end;\n");
    gen("\n");
    gen("function __whandle(fd: int): int;\n");
    gen("begin\n");
    gen("  if fd = 0 then return winapi(__K_GETSTDHANDLE, 0 - 10);\n");
    gen("  if fd = 1 then return winapi(__K_GETSTDHANDLE, 0 - 11);\n");
    gen("  if fd = 2 then return winapi(__K_GETSTDHANDLE, 0 - 12);\n");
    gen("  return fd;\n");
    gen("end;\n");
    gen("\n");
    gen("function __wissock(fd: int): bool;\n");
    gen("begin\n");
    gen("  return (fd > 2) and (fd < __WMAXFD) and (__wsh[fd] > 0);\n");
    gen("end;\n");
    gen("\n");
    gen("function __wisdir(fd: int): bool;\n");
    gen("begin\n");
    gen("  return (fd > 2) and (fd < __WMAXFD) and (__wdh[fd] <> 0);\n");
    gen("end;\n");
    gen("\n");
    gen("\n");
    gen("function __wwrite(fd: int; a: int; n: int): int;\n");
    gen("var ok, r: int;\n");
    gen("begin\n");
    gen("  if __wissock(fd) then\n");
    gen("  begin\n");
    gen("    r := winapi(__W_SEND, __wsh[fd], a, n, 0);\n");
    gen("    if r < 0 then return 0 - 11;   // treat as EAGAIN-ish\n");
    gen("    return r;\n");
    gen("  end;\n");
    gen("  __wcount := 0;\n");
    gen("  ok := winapi(__K_WRITEFILE, __whandle(fd), a, n, addr(__wcount), 0);\n");
    gen("  if band(ok, 0xFFFFFFFF) = 0 then return 0 - 1;\n");
    gen("  return band(__wcount, 0xFFFFFFFF);\n");
    gen("end;\n");
    gen("\n");
    gen("function __wread(fd: int; a: int; n: int): int;\n");
    gen("var ok, r: int;\n");
    gen("begin\n");
    gen("  if __wissock(fd) then\n");
    gen("  begin\n");
    gen("    r := winapi(__W_RECV, __wsh[fd], a, n, 0);\n");
    gen("    if r < 0 then return 0 - 11;\n");
    gen("    return r;\n");
    gen("  end;\n");
    gen("  __wcount := 0;\n");
    gen("  ok := winapi(__K_READFILE, __whandle(fd), a, n, addr(__wcount), 0);\n");
    gen("  if band(ok, 0xFFFFFFFF) = 0 then return 0;\n");
    gen("  return band(__wcount, 0xFFFFFFFF);\n");
    gen("end;\n");
    gen("\n");
    gen("function __wopen(path: int; flags: int): int;\n");
    gen("var access, disp, h: int;\n");
    gen("begin\n");
    gen("  access := 0x80000000;\n");
    gen("  if band(flags, 3) = 1 then access := 0x40000000;\n");
    gen("  if band(flags, 3) = 2 then access := 0xC0000000;\n");
    gen("  disp := 3;\n");
    gen("  if band(flags, 64) <> 0 then disp := 4;\n");
    gen("  if band(flags, 512) <> 0 then disp := 5;\n");
    gen("  if band(flags, 576) = 576 then disp := 2;\n");
    gen("  h := winapi(__K_CREATEFILEA, path, access, 3, 0, disp, 0x80, 0);\n");
    gen("  if h = 0 - 1 then return 0 - 1;\n");
    gen("  if band(flags, 1024) <> 0 then __wdummy := winapi(__K_SETPTR, h, 0, 0, 2);   // O_APPEND: seek to the end\n");
    gen("  return h;\n");
    gen("end;\n");
    gen("\n");
    gen("// mmap over CreateFileMapping/MapViewOfFile; fd < 0 maps the page file\n");
    gen("function __wmmap(n: int; prot: int; fd: int; off: int): int;\n");
    gen("var h, m, a, p, acc: int;\n");
    gen("begin\n");
    gen("  p := 2; acc := 4;   // PAGE_READONLY, FILE_MAP_READ\n");
    gen("  if band(prot, 2) <> 0 then\n");
    gen("  begin\n");
    gen("    p := 4; acc := 0x0F001F;   // PAGE_READWRITE, FILE_MAP_ALL_ACCESS\n");
    gen("  end;\n");
    gen("  if fd < 0 then\n");
    gen("  begin\n");
    gen("    m := winapi(__K_CREATEMAP, 0 - 1, 0, p, n shr 32, band(n, 0xFFFFFFFF), 0);\n");
    gen("    if m = 0 then return 0 - 12;\n");
    gen("    a := winapi(__K_MAPVIEW, m, acc, 0, 0, n);\n");
    gen("  end\n");
    gen("  else\n");
    gen("  begin\n");
    gen("    h := __whandle(fd);\n");
    gen("    m := winapi(__K_CREATEMAP, h, 0, p, 0, 0, 0);\n");
    gen("    if m = 0 then return 0 - 12;\n");
    gen("    a := winapi(__K_MAPVIEW, m, acc, off shr 32, band(off, 0xFFFFFFFF), n);\n");
    gen("  end;\n");
    gen("  __wdummy := winapi(__K_CLOSEHANDLE, m);\n");
    gen("  if a = 0 then return 0 - 12;\n");
    gen("  return a;\n");
    gen("end;\n");
    gen("\n");
    gen("function __wlseek(fd: int; off: int; whence: int): int;\n");
    gen("var ok: int;\n");
    gen("begin\n");
    gen("  ok := winapi(__K_SETPTR, __whandle(fd), off, addr(__wpos[0]), whence);\n");
    gen("  if band(ok, 0xFFFFFFFF) = 0 then return 0 - 22;\n");
    gen("  return bor(band(__wg32(__wpos, 0), 0xFFFFFFFF), __wg32(__wpos, 4) shl 32);\n");
    gen("end;\n");
    gen("\n");
    gen("function __wftruncate(fd: int; n: int): int;\n");
    gen("var h, ok: int;\n");
    gen("begin\n");
    gen("  h := __whandle(fd);\n");
    gen("  ok := winapi(__K_SETPTR, h, n, 0, 0);\n");
    gen("  if band(ok, 0xFFFFFFFF) = 0 then return 0 - 22;\n");
    gen("  ok := winapi(__K_SETEOF, h);\n");
    gen("  if band(ok, 0xFFFFFFFF) = 0 then return 0 - 22;\n");
    gen("  return 0;\n");
    gen("end;\n");
    gen("\n");
    gen("// flock: LOCK_SH 1, LOCK_EX 2, LOCK_NB 4, LOCK_UN 8 over the whole file\n");
    gen("function __wflock(fd: int; op: int): int;\n");
    gen("var h, flags, ok, i: int;\n");
    gen("begin\n");
    gen("  h := __whandle(fd);\n");
    gen("  i := 0;\n");
    gen("  while i < 32 do\n");
    gen("  begin\n");
    gen("    __wovl[i] := chr(0);\n");
    gen("    i := i + 1;\n");
    gen("  end;\n");
    gen("  if band(op, 8) <> 0 then\n");
    gen("  begin\n");
    gen("    ok := winapi(__K_UNLOCKFILE, h, 0, 0xFFFFFFFF, 0xFFFFFFFF, addr(__wovl[0]));\n");
    gen("    return 0;\n");
    gen("  end;\n");
    gen("  flags := 0;\n");
    gen("  if band(op, 2) <> 0 then flags := 2;\n");
    gen("  if band(op, 4) <> 0 then flags := bor(flags, 1);\n");
    gen("  ok := winapi(__K_LOCKFILE, h, flags, 0, 0xFFFFFFFF, 0xFFFFFFFF, addr(__wovl[0]));\n");
    gen("  if band(ok, 0xFFFFFFFF) = 0 then return 0 - 11;\n");
    gen("  return 0;\n");
    gen("end;\n");
    gen("\n");
    gen("procedure __wclose(fd: int);\n");
    gen("begin\n");
    gen("  if __wisdir(fd) then\n");
    gen("  begin\n");
    gen("    __wdummy := winapi(__K_FINDCLOSE, __wdh[fd]);\n");
    gen("    __wdh[fd] := 0;\n");
    gen("    __wsh[fd] := 0;\n");
    gen("    return;\n");
    gen("  end;\n");
    gen("  if __wissock(fd) then\n");
    gen("  begin\n");
    gen("    __wdummy := winapi(__W_CLOSESOCKET, __wsh[fd]);\n");
    gen("    __wsh[fd] := 0;\n");
    gen("    __wev[fd] := 0;\n");
    gen("  end\n");
    gen("  else __wdummy := winapi(__K_CLOSEHANDLE, fd);\n");
    gen("end;\n");
    gen("\n");
    gen("procedure __wputs(s: str);\n");
    gen("begin\n");
    gen("  __wdummy := __wwrite(2, sadr(s), slen(s));\n");
    gen("end;\n");
    gen("\n");
    gen("procedure __wneedwsa;\n");
    gen("var b: array[0..511] of char;\n");
    gen("begin\n");
    gen("  if __wstarted <> 0 then return;\n");
    gen("  __wstarted := 1;\n");
    gen("  __wdummy := winapi(__W_WSASTARTUP, 0x0202, addr(b[0]));\n");
    gen("end;\n");
    gen("\n");
    gen("function __wslot: int;\n");
    gen("var i: int;\n");
    gen("begin\n");
    gen("  i := 3;\n");
    gen("  while i < __WMAXFD do\n");
    gen("  begin\n");
    gen("    if __wsh[i] = 0 then return i;\n");
    gen("    i := i + 1;\n");
    gen("  end;\n");
    gen("  return 0 - 1;\n");
    gen("end;\n");
    gen("\n");
    gen("function __wsock: int;\n");
    gen("var h, fd: int;\n");
    gen("begin\n");
    gen("  __wneedwsa;\n");
    gen("  h := winapi(__W_SOCKET, 2, 1, 6);\n");
    gen("  if h = 0 - 1 then return 0 - 24;\n");
    gen("  fd := __wslot;\n");
    gen("  if fd < 0 then\n");
    gen("  begin\n");
    gen("    __wdummy := winapi(__W_CLOSESOCKET, h);\n");
    gen("    return 0 - 24;\n");
    gen("  end;\n");
    gen("  __wsh[fd] := h;\n");
    gen("  __wev[fd] := 0;\n");
    gen("  return fd;\n");
    gen("end;\n");
    gen("\n");
    gen("// Winsock's sockaddr_in matches Linux's byte for byte for AF_INET: family at\n");
    gen("  // 0 (2), port big-endian at 2, address at 4.  So the caller's 16-byte buffer\n");
    gen("  // passes straight through.\n");
    gen("function __wbind(fd: int; sa: int; sln: int): int;\n");
    gen("var r: int;\n");
    gen("begin\n");
    gen("  if not __wissock(fd) then return 0 - 9;\n");
    gen("  r := winapi(__W_BIND, __wsh[fd], sa, sln);\n");
    gen("  if r < 0 then return 0 - 98;\n");
    gen("  return 0;\n");
    gen("end;\n");
    gen("\n");
    gen("function __wlisten(fd: int; backlog: int): int;\n");
    gen("var r: int;\n");
    gen("begin\n");
    gen("  if not __wissock(fd) then return 0 - 9;\n");
    gen("  r := winapi(__W_LISTEN, __wsh[fd], backlog);\n");
    gen("  if r < 0 then return 0 - 98;\n");
    gen("  return 0;\n");
    gen("end;\n");
    gen("\n");
    gen("function __waccept(fd: int): int;\n");
    gen("var h, nfd, nb: int;\n");
    gen("begin\n");
    gen("  if not __wissock(fd) then return 0 - 9;\n");
    gen("  h := winapi(__W_ACCEPT, __wsh[fd], 0, 0);\n");
    gen("  if h = 0 - 1 then return 0 - 11;   // WSAEWOULDBLOCK -> EAGAIN\n");
    gen("  nfd := __wslot;\n");
    gen("  if nfd < 0 then\n");
    gen("  begin\n");
    gen("    __wdummy := winapi(__W_CLOSESOCKET, h);\n");
    gen("    return 0 - 24;\n");
    gen("  end;\n");
    gen("  __wsh[nfd] := h;\n");
    gen("  __wev[nfd] := 0;\n");
    gen("  nb := 1;\n");
    gen("  __wp32(__wsa, 0, nb);\n");
    gen("  __wdummy := winapi(__W_IOCTL, h, 0x8004667E, addr(__wsa[0]));   // FIONBIO\n");
    gen("  return nfd;\n");
    gen("end;\n");
    gen("\n");
    gen("function __wsetopt(fd: int; opt: int; a: int; sln: int): int;\n");
    gen("begin\n");
    gen("  if not __wissock(fd) then return 0 - 9;\n");
    gen("  // SO_REUSEADDR is 4 on Windows; SO_REUSEPORT does not exist, ignore it\n");
    gen("  if opt = 15 then return 0;\n");
    gen("  __wdummy := winapi(__W_SETSOCKOPT, __wsh[fd], 0xFFFF, 4, a, sln);\n");
    gen("  return 0;\n");
    gen("end;\n");
    gen("\n");
    gen("function __wnonblock(fd: int): int;\n");
    gen("var nb: int;\n");
    gen("begin\n");
    gen("  if not __wissock(fd) then return 0;\n");
    gen("  nb := 1;\n");
    gen("  __wp32(__wsa, 0, nb);\n");
    gen("  __wdummy := winapi(__W_IOCTL, __wsh[fd], 0x8004667E, addr(__wsa[0]));\n");
    gen("  return 0;\n");
    gen("end;\n");
    gen("\n");
    gen("procedure __wput32abs(a: int; v: int);\n");
    gen("begin\n");
    gen("  poke(a, band(v, 255));\n");
    gen("  poke(a + 1, band(v shr 8, 255));\n");
    gen("  poke(a + 2, band(v shr 16, 255));\n");
    gen("  poke(a + 3, band(v shr 24, 255));\n");
    gen("end;\n");
    gen("\n");
    gen("// epoll_ctl: op 1=ADD, 2=DEL, 3=MOD.  The event mask sits at [ev+0].\n");
    gen("function __wepctl(op: int; fd: int; ev: int): int;\n");
    gen("var mask: int;\n");
    gen("begin\n");
    gen("  if (fd < 3) or (fd >= __WMAXFD) then return 0 - 9;\n");
    gen("  if op = 2 then\n");
    gen("  begin\n");
    gen("    __wev[fd] := 0;\n");
    gen("    return 0;\n");
    gen("  end;\n");
    gen("  mask := bor(peek(ev), peek(ev + 1) shl 8);\n");
    gen("  mask := bor(mask, peek(ev + 2) shl 16);\n");
    gen("  mask := bor(mask, peek(ev + 3) shl 24);\n");
    gen("  __wev[fd] := mask;\n");
    gen("  return 0;\n");
    gen("end;\n");
    gen("\n");
    gen("// epoll_wait: build a WSAPOLLFD array from the interest table, poll it, then\n");
    gen("  // write ready events into the caller's array (12 bytes each: events, fd).\n");
    gen("function __wepwait(a: int; maxev: int; timeout: int): int;\n");
    gen("var i, np, r, k, out, revents, ev, base, pe: int;\n");
    gen("begin\n");
    gen("  np := 0;\n");
    gen("  i := 3;\n");
    gen("  while i < __WMAXFD do\n");
    gen("  begin\n");
    gen("    if (__wsh[i] <> 0) and (__wev[i] <> 0) then\n");
    gen("    begin\n");
    gen("      base := np * 16;\n");
    gen("      __wp32(__wpoll, base, band(__wsh[i], 0xFFFFFFFF));\n");
    gen("      __wp32(__wpoll, base + 4, __wsh[i] shr 32);\n");
    gen("      ev := 0;\n");
    gen("      if band(__wev[i], 1) <> 0 then ev := bor(ev, 0x0300);   // IN -> RDNORM|RDBAND\n");
    gen("      if band(__wev[i], 4) <> 0 then ev := bor(ev, 0x0010);   // OUT -> WRNORM\n");
    gen("      __wpoll[base + 8] := chr(band(ev, 255));\n");
    gen("      __wpoll[base + 9] := chr(band(ev shr 8, 255));\n");
    gen("      __wpoll[base + 10] := chr(0);\n");
    gen("      __wpoll[base + 11] := chr(0);\n");
    gen("      __wpoll[base + 12] := chr(0);\n");
    gen("      __wpoll[base + 13] := chr(0);\n");
    gen("      __wpoll[base + 14] := chr(0);\n");
    gen("      __wpoll[base + 15] := chr(0);\n");
    gen("      __wrow[np] := i;\n");
    gen("      np := np + 1;\n");
    gen("    end;\n");
    gen("    i := i + 1;\n");
    gen("  end;\n");
    gen("  if np = 0 then\n");
    gen("  begin\n");
    gen("    if timeout > 0 then __wdummy := winapi(__K_SLEEP, timeout);\n");
    gen("    return 0;\n");
    gen("  end;\n");
    gen("  r := winapi(__W_WSAPOLL, addr(__wpoll[0]), np, timeout);\n");
    gen("  if band(r, 0xFFFFFFFF) = 0xFFFFFFFF then return 0 - 4;\n");
    gen("  if r = 0 then return 0;\n");
    gen("  out := 0;\n");
    gen("  k := 0;\n");
    gen("  while k < np do\n");
    gen("  begin\n");
    gen("    base := k * 16;\n");
    gen("    revents := bor(ord(__wpoll[base + 10]), ord(__wpoll[base + 11]) shl 8);\n");
    gen("    if revents <> 0 then\n");
    gen("    begin\n");
    gen("      ev := 0;\n");
    gen("      if band(revents, 0x0300) <> 0 then ev := bor(ev, 1);   // IN\n");
    gen("      if band(revents, 0x0010) <> 0 then ev := bor(ev, 4);   // OUT\n");
    gen("      if band(revents, 0x0001) <> 0 then ev := bor(ev, 8);   // ERR\n");
    gen("      if band(revents, 0x0002) <> 0 then ev := bor(ev, 16);   // HUP\n");
    gen("      pe := a + out * 12;\n");
    gen("      __wput32abs(pe, ev);\n");
    gen("      __wput32abs(pe + 4, __wrow[k]);\n");
    gen("      __wput32abs(pe + 8, 0);\n");
    gen("      out := out + 1;\n");
    gen("      if out >= maxev then return out;\n");
    gen("    end;\n");
    gen("    k := k + 1;\n");
    gen("  end;\n");
    gen("  return out;\n");
    gen("end;\n");
    gen("\n");
    gen("// clock_gettime-ish: return nanoseconds since the Unix epoch, good enough for\n");
    gen("  // the io.now() the library exposes.  FILETIME is 100ns ticks since 1601.\n");
    gen("function __wnow: int;\n");
    gen("var lo, hi, t: int;\n");
    gen("begin\n");
    gen("  __wdummy := winapi(__K_GETTIME, addr(__wtime[0]));\n");
    gen("  lo := __wg32(__wtime, 0);\n");
    gen("  hi := __wg32(__wtime, 4);\n");
    gen("  t := bor(lo, hi shl 32);\n");
    gen("  t := t - 116444736000000000;   // 1601 -> 1970 in 100ns ticks\n");
    gen("  return t * 100;   // 100ns -> ns\n");
    gen("end;\n");
    gen("\n");
    gen("// WIN32_FIND_DATAA: dwFileAttributes at 0, ftLastWriteTime at 20 (8 bytes),\n");
    gen("  // nFileSizeHigh at 28, nFileSizeLow at 32, cFileName at 44 (260 bytes).\n");
    gen("function __wattr_isdir(attr: int): bool;\n");
    gen("begin\n");
    gen("  return band(attr, 16) <> 0;   // FILE_ATTRIBUTE_DIRECTORY\n");
    gen("end;\n");
    gen("\n");
    gen("// GetFileAttributesExA fills a WIN32_FILE_ATTRIBUTE_DATA (36 bytes):\n");
    gen("  // attributes at 0, ftLastWriteTime at 20, sizeHigh at 28, sizeLow at 32.\n");
    gen("function __wstatinto(path: int; stbuf: int): int;\n");
    gen("var ok, attr, mode, sz, lo, hi, mt, mlo, mhi: int;\n");
    gen("begin\n");
    gen("  ok := winapi(__K_GETATTREX, path, 0, addr(__wfind[0]));   // GetFileAttributesExA\n");
    gen("  if band(ok, 0xFFFFFFFF) = 0 then return 0 - 2;\n");
    gen("  attr := __wg32(__wfind, 0);\n");
    gen("  mode := 0x8000;   // S_IFREG\n");
    gen("  if __wattr_isdir(attr) then mode := 0x4000;   // S_IFDIR\n");
    gen("  mode := bor(mode, 0x1FF);   // rwxrwxrwx bits\n");
    gen("  lo := __wg32(__wfind, 32);\n");
    gen("  hi := __wg32(__wfind, 28);\n");
    gen("  sz := bor(band(lo, 0xFFFFFFFF), hi shl 32);\n");
    gen("  mlo := __wg32(__wfind, 20);\n");
    gen("  mhi := __wg32(__wfind, 24);\n");
    gen("  mt := bor(band(mlo, 0xFFFFFFFF), mhi shl 32);\n");
    gen("  mt := mt - 116444736000000000;\n");
    gen("  mt := mt div 10000000;   // 100ns ticks -> seconds\n");
    gen("  // mode at offset 24, size at 48, mtime at 88 (see lib/fs.wz)\n");
    gen("  __wput32abs(stbuf + 24, mode);\n");
    gen("  __wput32abs(stbuf + 48, band(sz, 0xFFFFFFFF));\n");
    gen("  __wput32abs(stbuf + 52, sz shr 32);\n");
    gen("  __wput32abs(stbuf + 88, band(mt, 0xFFFFFFFF));\n");
    gen("  __wput32abs(stbuf + 92, mt shr 32);\n");
    gen("  return 0;\n");
    gen("end;\n");
    gen("\n");
    gen("// opendir(path): start a FindFirstFileA over path\\* and return a dir fd\n");
    gen("function __wopendir(path: int): int;\n");
    gen("var i, o, h, fd: int;\n");
    gen("    c: char;\n");
    gen("begin\n");
    gen("  o := 0;\n");
    gen("  while o < 1030 do\n");
    gen("  begin\n");
    gen("    c := chr(peek(path + o));\n");
    gen("    if c = chr(0) then break;\n");
    gen("    __wpath[o] := c;\n");
    gen("    o := o + 1;\n");
    gen("  end;\n");
    gen("  if (o > 0) and (__wpath[o - 1] <> '/') and (__wpath[o - 1] <> chr(92)) then\n");
    gen("  begin\n");
    gen("    __wpath[o] := chr(92);\n");
    gen("    o := o + 1;\n");
    gen("  end;\n");
    gen("  __wpath[o] := '*';\n");
    gen("  __wpath[o + 1] := chr(0);\n");
    gen("  h := winapi(__K_FINDFIRST, addr(__wpath[0]), addr(__wfind[0]));\n");
    gen("  if h = 0 - 1 then return 0 - 2;\n");
    gen("  fd := __wslot;\n");
    gen("  if fd < 0 then\n");
    gen("  begin\n");
    gen("    __wdummy := winapi(__K_FINDCLOSE, h);\n");
    gen("    return 0 - 24;\n");
    gen("  end;\n");
    gen("  __wsh[fd] := 0 - 2;   // mark the slot busy but not a socket\n");
    gen("  __wdh[fd] := h;\n");
    gen("  __wdfirst[fd] := 1;   // the first entry is already in __wfind\n");
    gen("  return fd;\n");
    gen("end;\n");
    gen("\n");
    gen("// getdents into the caller's buffer at address a, capacity cap.  Emits Linux\n");
    gen("  // dirent64-ish records: reclen (2 bytes) at +16, type (1 byte) at +18, the\n");
    gen("  // NUL-terminated name from +19.  Returns bytes written, or 0 at the end.\n");
    gen("function __wgetdents(fd: int; a: int; cap: int): int;\n");
    gen("var used, attr, i, nl, reclen, base, more, t: int;\n");
    gen("    c: char;\n");
    gen("begin\n");
    gen("  if not __wisdir(fd) then return 0 - 9;\n");
    gen("  used := 0;\n");
    gen("  while true do\n");
    gen("  begin\n");
    gen("    if __wdfirst[fd] = 0 then\n");
    gen("    begin\n");
    gen("      more := winapi(__K_FINDNEXT, __wdh[fd], addr(__wfind[0]));\n");
    gen("      if band(more, 0xFFFFFFFF) = 0 then break;\n");
    gen("    end;\n");
    gen("    __wdfirst[fd] := 0;\n");
    gen("    // name length\n");
    gen("    nl := 0;\n");
    gen("    while nl < 259 do\n");
    gen("    begin\n");
    gen("      if __wfind[44 + nl] = chr(0) then break;\n");
    gen("      nl := nl + 1;\n");
    gen("    end;\n");
    gen("    reclen := 19 + nl + 1;\n");
    gen("    reclen := (reclen + 7) div 8 * 8;\n");
    gen("    if used + reclen > cap then\n");
    gen("    begin\n");
    gen("      // no room: reprocess this entry next call by pretending it is first\n");
    gen("      __wdfirst[fd] := 1;\n");
    gen("      break;\n");
    gen("    end;\n");
    gen("    base := a + used;\n");
    gen("    __wput32abs(base, 0);   // d_ino low\n");
    gen("    __wput32abs(base + 4, 0);\n");
    gen("    __wput32abs(base + 8, 0);   // d_off\n");
    gen("    __wput32abs(base + 12, 0);\n");
    gen("    poke(base + 16, band(reclen, 255));\n");
    gen("    poke(base + 17, band(reclen shr 8, 255));\n");
    gen("    attr := __wg32(__wfind, 0);\n");
    gen("    t := 8;   // DT_REG\n");
    gen("    if __wattr_isdir(attr) then t := 4;   // DT_DIR\n");
    gen("    poke(base + 18, t);\n");
    gen("    i := 0;\n");
    gen("    while i < nl do\n");
    gen("    begin\n");
    gen("      poke(base + 19 + i, ord(__wfind[44 + i]));\n");
    gen("      i := i + 1;\n");
    gen("    end;\n");
    gen("    poke(base + 19 + nl, 0);\n");
    gen("    used := used + reclen;\n");
    gen("  end;\n");
    gen("  return used;\n");
    gen("end;\n");
    gen("\n");
    gen("\n");
    gen("function __wsys(nr: int; a: int; b: int; c: int; d: int; e: int; f: int): int;\n");
    gen("var t: int;\n");
    gen("begin\n");
    gen("  if nr = 1 then return __wwrite(a, b, c);\n");
    gen("  if nr = 0 then return __wread(a, b, c);\n");
    gen("  if nr = 2 then\n");
    gen("  begin\n");
    gen("    if band(b, 65536) <> 0 then return __wopendir(a);   // O_DIRECTORY\n");
    gen("    return __wopen(a, b);\n");
    gen("  end;\n");
    gen("  if (nr = 4) or (nr = 6) then return __wstatinto(a, b);   // stat / lstat\n");
    gen("  if nr = 217 then return __wgetdents(a, b, c);   // getdents\n");
    gen("  if nr = 3 then\n");
    gen("  begin\n");
    gen("    __wclose(a);\n");
    gen("    return 0;\n");
    gen("  end;\n");
    gen("  if nr = 41 then return __wsock;   // socket\n");
    gen("  if nr = 49 then return __wbind(a, b, c);   // bind\n");
    gen("  if nr = 50 then return __wlisten(a, b);   // listen\n");
    gen("  if nr = 43 then return __waccept(a);   // accept\n");
    gen("  if nr = 288 then return __waccept(a);   // accept4\n");
    gen("  if nr = 54 then return __wsetopt(a, c, d, e);   // setsockopt\n");
    gen("  if nr = 72 then return __wnonblock(a);   // fcntl F_SETFL\n");
    gen("  if nr = 44 then return __wwrite(a, b, c);   // sendto -> send\n");
    gen("  if nr = 48 then return 0;   // shutdown: no-op\n");
    gen("  if nr = 291 then return 1000000;   // epoll_create -> token\n");
    gen("  if nr = 233 then return __wepctl(b, c, d);   // epoll_ctl\n");
    gen("  if nr = 232 then return __wepwait(b, c, d);   // epoll_wait\n");
    gen("  if nr = 228 then   // clock_gettime: fill the timespec\n");
    gen("  begin\n");
    gen("    t := __wnow;\n");
    gen("    __wput32abs(b, band(t div 1000000000, 0xFFFFFFFF));\n");
    gen("    __wput32abs(b + 4, (t div 1000000000) shr 32);\n");
    gen("    __wput32abs(b + 8, t mod 1000000000);\n");
    gen("    __wput32abs(b + 12, 0);\n");
    gen("    return 0;\n");
    gen("  end;\n");
    gen("  if nr = 9 then return __wmmap(b, c, e, f);   // mmap\n");
    gen("  if nr = 11 then   // munmap\n");
    gen("  begin\n");
    gen("    __wdummy := winapi(__K_UNMAPVIEW, a);\n");
    gen("    return 0;\n");
    gen("  end;\n");
    gen("  if nr = 26 then   // msync\n");
    gen("  begin\n");
    gen("    __wdummy := winapi(__K_FLUSHVIEW, a, b);\n");
    gen("    return 0;\n");
    gen("  end;\n");
    gen("  if nr = 74 then   // fsync\n");
    gen("  begin\n");
    gen("    __wdummy := winapi(__K_FLUSHFILE, __whandle(a));\n");
    gen("    return 0;\n");
    gen("  end;\n");
    gen("  if nr = 82 then   // rename\n");
    gen("  begin\n");
    gen("    t := winapi(__K_MOVEFILE, a, b, 9);   // REPLACE_EXISTING | WRITE_THROUGH\n");
    gen("    if band(t, 0xFFFFFFFF) = 0 then return 0 - 2;\n");
    gen("    return 0;\n");
    gen("  end;\n");
    gen("  if nr = 8 then return __wlseek(a, b, c);   // lseek\n");
    gen("  if nr = 77 then return __wftruncate(a, b);   // ftruncate\n");
    gen("  if nr = 87 then   // unlink\n");
    gen("  begin\n");
    gen("    t := winapi(__K_DELETEFILE, a);\n");
    gen("    if band(t, 0xFFFFFFFF) = 0 then return 0 - 2;\n");
    gen("    return 0;\n");
    gen("  end;\n");
    gen("  if nr = 83 then   // mkdir\n");
    gen("  begin\n");
    gen("    t := winapi(__K_CREATEDIR, a, 0);\n");
    gen("    if band(t, 0xFFFFFFFF) = 0 then return 0 - 17;\n");
    gen("    return 0;\n");
    gen("  end;\n");
    gen("  if nr = 84 then   // rmdir\n");
    gen("  begin\n");
    gen("    t := winapi(__K_REMOVEDIR, a);\n");
    gen("    if band(t, 0xFFFFFFFF) = 0 then return 0 - 2;\n");
    gen("    return 0;\n");
    gen("  end;\n");
    gen("  if nr = 73 then return __wflock(a, b);   // flock\n");
    gen("  if nr = 318 then   // getrandom\n");
    gen("  begin\n");
    gen("    t := winapi(__A_RANDOM, a, b);\n");
    gen("    if band(t, 0xFF) = 0 then return 0 - 1;\n");
    gen("    return b;\n");
    gen("  end;\n");
    gen("  if nr = 35 then   // nanosleep\n");
    gen("  begin\n");
    gen("    __wdummy := winapi(__K_SLEEP, 1);\n");
    gen("    return 0;\n");
    gen("  end;\n");
    gen("  if nr = 90 then return 0;   // chmod: no-op\n");
    /* readlink: -1 and not a trap. Windows has no /proc/self/exe, which setlibdir asks
       for first; the error is what makes it fall back to argv[0]. Counterpart of
       src/wantzel.wz. */
    gen("  if nr = 89 then return 0 - 1;   // readlink: no /proc, caller falls back\n");
    gen("  if nr = 57 then return 0;   // fork: no worker processes, run single-process\n");
    gen("  if nr = 61 then return 0;   // wait4: nothing to wait for\n");
    gen("  if (nr = 60) or (nr = 231) then winapi(__K_EXITPROCESS, band(a, 0xFFFFFFFF));\n");
    gen("  __wputs(\"runtime error: an unsupported system call was made on Windows\\n\");\n");
    gen("  winapi(__K_EXITPROCESS, 70);\n");
    gen("  return 0 - 1;\n");
    gen("end;\n");
    gen("\n");
    gen("function __winit: int;\n");
    gen("var i, o, n, k, na: int;\n");
    gen("    inq: bool;\n");
    gen("    c: char;\n");
    gen("begin\n");
    gen("  __wdummy := winapi(__K_GETCMDLINE);\n");
    gen("  __wdummy := winapi(__K_LSTRCPYN, addr(__wargs[0]), __wdummy, 4095);\n");
    gen("  __wargs[4095] := chr(0);\n");
    gen("  i := 0; o := 0; na := 0;\n");
    gen("  while true do\n");
    gen("  begin\n");
    gen("    while (__wargs[i] = chr(32)) or (__wargs[i] = chr(9)) do i := i + 1;\n");
    gen("    if __wargs[i] = chr(0) then break;\n");
    gen("    if na >= 62 then break;\n");
    gen("    __wargv[na + 1] := addr(__wargs[o]);\n");
    gen("    na := na + 1;\n");
    gen("    inq := false;\n");
    gen("    while true do\n");
    gen("    begin\n");
    gen("      c := __wargs[i];\n");
    gen("      if c = chr(0) then break;\n");
    gen("      if (not inq) and ((c = chr(32)) or (c = chr(9))) then break;\n");
    gen("      if c = chr(92) then\n");
    gen("      begin\n");
    gen("        n := 0;\n");
    gen("        while __wargs[i] = chr(92) do\n");
    gen("        begin\n");
    gen("          n := n + 1;\n");
    gen("          i := i + 1;\n");
    gen("        end;\n");
    gen("        if __wargs[i] = chr(34) then\n");
    gen("        begin\n");
    gen("          k := 0;\n");
    gen("          while k < n div 2 do\n");
    gen("          begin\n");
    gen("            __wargs[o] := chr(92);\n");
    gen("            o := o + 1;\n");
    gen("            k := k + 1;\n");
    gen("          end;\n");
    gen("          if (n mod 2) = 1 then\n");
    gen("          begin\n");
    gen("            __wargs[o] := chr(34);\n");
    gen("            o := o + 1;\n");
    gen("          end\n");
    gen("          else inq := not inq;\n");
    gen("          i := i + 1;\n");
    gen("        end\n");
    gen("        else\n");
    gen("        begin\n");
    gen("          k := 0;\n");
    gen("          while k < n do\n");
    gen("          begin\n");
    gen("            __wargs[o] := chr(92);\n");
    gen("            o := o + 1;\n");
    gen("            k := k + 1;\n");
    gen("          end;\n");
    gen("        end;\n");
    gen("      end\n");
    gen("      else if c = chr(34) then\n");
    gen("      begin\n");
    gen("        inq := not inq;\n");
    gen("        i := i + 1;\n");
    gen("      end\n");
    gen("      else\n");
    gen("      begin\n");
    gen("        __wargs[o] := c;\n");
    gen("        o := o + 1;\n");
    gen("        i := i + 1;\n");
    gen("      end;\n");
    gen("    end;\n");
    gen("    c := __wargs[i];\n");
    gen("    __wargs[o] := chr(0);\n");
    gen("    o := o + 1;\n");
    gen("    if c <> chr(0) then i := i + 1;\n");
    gen("  end;\n");
    gen("  __wargv[0] := na;\n");
    gen("  __wargv[na + 1] := 0;\n");
    gen("  return addr(__wargv[0]);\n");
    gen("end;\n");
    return 0;
}

long injectwin(){
    long fi; long f; long i;
    if(incdepth >= 16){ fail("includes nested too deeply"); }
    i = 0;
    while(i < 9){ pathbuf[i] = "<windows>"[i]; i = i + 1; }
    pathbuf[9] = 0;
    fi = addfile();
    incpos[incdepth] = pos; incend[incdepth] = srcend;
    incline[incdepth] = line; incfile[incdepth] = curfile;
    incdepth = incdepth + 1;
    f = srclen;
    genwin();
    pos = f; srcend = srclen; line = 1; curfile = fi;
    next();
    return 0;
}

/* ------------------------------------------------------------------ */
/* program                                                             */
/* ------------------------------------------------------------------ */
long emitprelude(){
    long i; long j; long k;
    entryoff = 0;
    if(winmode != 0){
        /* __sysraw: hand the Linux register set to __wsys(nr,a,b,c,d,e,f) */
        sysrawaddr = codelen;
        e(0x41); e(0x54);                           /* push r12         */
        e(0x4D); e(0x89); e(0xCC);                  /* mov r12,r9       */
        e(0x4D); e(0x89); e(0xC1);                  /* mov r9,r8        */
        e(0x4D); e(0x89); e(0xD0);                  /* mov r8,r10       */
        e(0x48); e(0x89); e(0xD1);                  /* mov rcx,rdx      */
        e(0x48); e(0x89); e(0xF2);                  /* mov rdx,rsi      */
        e(0x48); e(0x89); e(0xFE);                  /* mov rsi,rdi      */
        e(0x48); e(0x89); e(0xC7);                  /* mov rdi,rax (nr) */
        e(0xE8); fixup(FX_WSYS,0); e32(0);          /* call __wsys      */
        e(0x41); e(0x5C);                           /* pop r12          */
        e(0xC3);                                    /* ret              */
        /* entry: __winit builds an argc/argv block; its address goes where a
           Linux executable keeps its initial stack pointer */
        entryoff = codelen;
        e(0xE8); fixup(FX_WINIT,0); e32(0);         /* call __winit     */
        e(0x49); e(0xBA); fixup(FX_BSS,0); e64(0);  /* mov r10,&__argp  */
        e(0x49); e(0x89); e(0x02);                  /* mov [r10],rax    */
    } else {
        /* entry stub: remember the initial stack pointer, run main, exit(0) */
        e(0x49); e(0xBA); fixup(FX_BSS,0); e64(0);  /* mov r10,&__argp */
        e(0x49); e(0x89); e(0x22);                  /* mov [r10],rsp   */
    }
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
    long i, nunres;
    emitprelude();
    /* The Windows runtime is injected BEFORE the first token is read. injectwin saves the
       read position and returns to it when the injected source ends, so anything already
       read at that moment would be lost. With nothing read yet, the saved position is the
       start of the file and the first real token is read on the way back. */
    if(winmode != 0){ injectwin(); } else { next(); }
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
    next();
    mainaddr = codelen;
    nloc = 0; frame = 0; curfn = -1; curret = T_VOID;
    nbrk = 0; ncnt = 0; brkbase = -1; cntbase = -1;
    e(0x55); e(0x48); e(0x89); e(0xE5);
    e(0x48); e(0x81); e(0xEC); framepatch = codelen; e32(0);   /* sub rsp,N: room for hidden slots */
    stmtlist();
    if(tok != KW_END){ fail("missing end of the main program"); }
    next();
    if(tok != 46){ fail("missing . after the final end"); }
    next();
    if(tok != TK_EOF){ fail("text after the end of the program"); }
    e(0x48); e(0x31); e(0xC0);
    epilogue();
    while((frame % 16) != 0){ frame = frame + 8; }
    e32at(framepatch,frame);
    e32at(mainpatch,mainaddr - (mainpatch+4));
    return 0;
}

/* ------------------------------------------------------------------ */
/* ELF output                                                          */
/* ------------------------------------------------------------------ */
char hdr[HDRMAX];
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
    return 0;
}

/* ------------------------------------------------------------------ */
/* PE output: a 64-bit Windows executable                             */
/* ------------------------------------------------------------------ */
/* Three sections: .text, .rdata (the string data followed by the import
   tables for kernel32) and .bss.  No relocations, so the image is fixed at
   VBASE, exactly like the ELF; no section is both writable and executable. */
long pd(long b){ dput(b); return 0; }
long pd16(long v){ pd(v); pd(v>>8); return 0; }
long pd32(long v){ pd16(v); pd16(v>>16); return 0; }
long pds(char *s){ long i; i = 0; while(i < slen(s)){ pd((long)(unsigned char)s[i]); i = i + 1; } pd(0); return 0; }
long phs(char *s){ long i; i = 0; while(i < slen(s)){ ph((long)(unsigned char)s[i]); i = i + 1; } return 0; }

/* Imported functions, in IAT slot order.  winapi(slot) calls slot*8 into the
   IAT.  Slots 0..KCOUNT-1 live in kernel32, KCOUNT+1..NIMP in ws2_32; the two
   DLLs get their own null-terminated thunk arrays, hence the gap slot. */
long extdll[MAXEXT]; long extfn[MAXEXT]; long extdnam[MAXEXTD];
char extnam[16384]; long next_; long nextd; long extnamlen;

/* length of a NUL-terminated name in extnam */
long zlen(char *a, long at){ long n; n = 0; while(a[at+n] != 0){ n = n + 1; } return n; }

/* copy a string literal into extnam, NUL-terminated; -1 when full */
long extput(long at, long n){
    long o; long i;
    if(extnamlen + n + 1 > 16384){ return -1; }
    o = extnamlen; i = 0;
    while(i < n){ extnam[o+i] = dat[at+i]; i = i + 1; }
    extnam[o+n] = 0;
    extnamlen = extnamlen + n + 1;
    return o;
}

/* the length of a string literal: it sits in the eight bytes before the text */
long datlen0(long at){
    long n; long i;
    n = 0; i = 7;
    while(i >= 0){ n = (n << 8) | (unsigned char)dat[at-8+i]; i = i - 1; }
    return n;
}

/* case-insensitive compare of a name in extnam against a literal */
long eqname(long at, long n, char *lit){
    long i; long a; long b; long m;
    m = 0; while(lit[m] != 0){ m = m + 1; }
    if(n != m){ return 0; }
    i = 0;
    while(i < n){
        a = (unsigned char)extnam[at+i]; b = (unsigned char)lit[i];
        if(a >= 65 && a <= 90){ a = a + 32; }
        if(b >= 65 && b <= 90){ b = b + 32; }
        if(a != b){ return 0; }
        i = i + 1;
    }
    return 1;
}

/* does the name end in ".dll"? */
long endsdll(long at, long n){
    long c;
    if(n < 5){ return 0; }
    if(extnam[at+n-4] != '.'){ return 0; }
    c = (unsigned char)extnam[at+n-3]; if(c >= 65 && c <= 90){ c = c + 32; }
    if(c != 100){ return 0; }
    c = (unsigned char)extnam[at+n-2]; if(c >= 65 && c <= 90){ c = c + 32; }
    if(c != 108){ return 0; }
    c = (unsigned char)extnam[at+n-1]; if(c >= 65 && c <= 90){ c = c + 32; }
    return c == 108;
}

char *dllname(long d);
long dllfirst(long d);
char *impname(long i);
long ndll(void);

/* The IAT slot of extra import i: every DLL before it contributed its functions plus one
   null terminator, which is why the slot runs ahead of the name index. */
/* The IAT slot of extra import i. The name table is written GROUPED BY DLL while imports
   are recorded in the order the source names them, so the position is not i: it is how many
   imports of earlier DLLs come first, plus how many of its own came before it. Using i
   directly put CreateFontA in user32 and GetModuleHandleA in gdi32. */
long extiat(long i){
    long k; long pos;
    pos = 0; k = 0;
    while(k < next_){
        if(extdll[k] < extdll[i]){ pos = pos + 1; }
        else if(extdll[k] == extdll[i] && k < i){ pos = pos + 1; }
        k = k + 1;
    }
    return NIMP + pos + 4 + extdll[i];
}

/* which extra import sits at grouped position p -- the inverse of the walk above */
long extat(long p){
    long d; long k; long seen;
    seen = 0; d = 0;
    while(d < nextd){
        k = 0;
        while(k < next_){
            if(extdll[k] == d){
                if(seen == p){ return k; }
                seen = seen + 1;
            }
            k = k + 1;
        }
        d = d + 1;
    }
    return 0;
}

/* the slot of a function in a built-in DLL, or -1 when that DLL does not export it here */
long builtinslot(long d, long fn, long fl){
    long i;
    i = dllfirst(d);
    while(i < dllfirst(d + 1)){
        if(eqname(fn, fl, impname(i))){ return i + d; }
        i = i + 1;
    }
    return -1;
}

/* Record a (DLL, function) pair the source asked for and return its import slot, or -1
   when a table is full. */
long extslot(long dl, long dn, long fn, long fl){
    long i; long k; long o; long d;
    i = 0;
    while(i < 4){
        if(eqname(dn, dl, dllname(i))){
            k = builtinslot(i, fn, fl);
            if(k >= 0){ extlast = -1; return k; }    /* already imported: reuse that slot */
            i = 4;                     /* known DLL, function we do not have: see below */
        } else { i = i + 1; }
    }
    d = -1; i = 0;
    while(i < nextd){
        o = extdnam[i]; k = 0;
        while(k < dl && extnam[o+k] == extnam[dn+k]){ k = k + 1; }
        if(k == dl && extnam[o+k] == 0){ d = i; }
        i = i + 1;
    }
    if(d < 0){
        if(nextd >= MAXEXTD){ return -1; }
        d = nextd; extdnam[d] = dn; nextd = nextd + 1;
    }
    i = 0;
    while(i < next_){
        if(extdll[i] == d){
            o = extfn[i]; k = 0;
            while(k < fl && extnam[o+k] == extnam[fn+k]){ k = k + 1; }
            if(k == fl && extnam[o+k] == 0){ extlast = i; return extiat(i); }
        }
        i = i + 1;
    }
    if(next_ >= MAXEXT){ return -1; }
    extdll[next_] = d; extfn[next_] = fn; next_ = next_ + 1;
    extlast = next_ - 1;
    return extiat(next_ - 1);
}

/* name and length of import i, built-in or source-named */
long impnamelen(long i){
    if(i < NIMP){ long n; char *p; p = impname(i); n = 0; while(p[n] != 0){ n = n + 1; } return n; }
    return zlen(extnam, extfn[extat(i - NIMP)]);
}

void pdsimp(long i){
    long o; long k;
    if(i < NIMP){ pds(impname(i)); return; }
    o = extfn[extat(i - NIMP)]; k = 0;
    while(extnam[o+k] != 0){ pd((unsigned char)extnam[o+k]); k = k + 1; }
    pd(0);
}

long dllnamelen(long d){
    if(d < 4){ long n; char *p; p = dllname(d); n = 0; while(p[n] != 0){ n = n + 1; } return n; }
    return zlen(extnam, extdnam[d - 4]);
}

void pdsdll(long d){
    long o; long i;
    if(d < 4){ pds(dllname(d)); return; }
    o = extdnam[d - 4]; i = 0;
    while(extnam[o+i] != 0){ pd((unsigned char)extnam[o+i]); i = i + 1; }
    pd(0);
}

/* how many functions the source named from extra DLL e */
long extcount(long e){
    long i; long n;
    n = 0; i = 0;
    while(i < next_){ if(extdll[i] == e){ n = n + 1; } i = i + 1; }
    return n;
}

char *impname(long i){
    if(i == 0){ return "GetStdHandle"; }
    if(i == 1){ return "WriteFile"; }
    if(i == 2){ return "ReadFile"; }
    if(i == 3){ return "CreateFileA"; }
    if(i == 4){ return "CloseHandle"; }
    if(i == 5){ return "ExitProcess"; }
    if(i == 6){ return "GetCommandLineA"; }
    if(i == 7){ return "lstrcpynA"; }
    if(i == 8){ return "GetSystemTimeAsFileTime"; }
    if(i == 9){ return "Sleep"; }
    if(i == 10){ return "GetFileAttributesExA"; }
    if(i == 11){ return "FindFirstFileA"; }
    if(i == 12){ return "FindNextFileA"; }
    if(i == 13){ return "FindClose"; }
    if(i == 14){ return "CreateFileMappingA"; }
    if(i == 15){ return "MapViewOfFile"; }
    if(i == 16){ return "UnmapViewOfFile"; }
    if(i == 17){ return "FlushViewOfFile"; }
    if(i == 18){ return "FlushFileBuffers"; }
    if(i == 19){ return "MoveFileExA"; }
    if(i == 20){ return "SetFilePointerEx"; }
    if(i == 21){ return "SetEndOfFile"; }
    if(i == 22){ return "DeleteFileA"; }
    if(i == 23){ return "CreateDirectoryA"; }
    if(i == 24){ return "RemoveDirectoryA"; }
    if(i == 25){ return "LockFileEx"; }
    if(i == 26){ return "UnlockFileEx"; }
    if(i == 27){ return "WSAStartup"; }
    if(i == 28){ return "socket"; }
    if(i == 29){ return "closesocket"; }
    if(i == 30){ return "setsockopt"; }
    if(i == 31){ return "ioctlsocket"; }
    if(i == 32){ return "bind"; }
    if(i == 33){ return "listen"; }
    if(i == 34){ return "accept"; }
    if(i == 35){ return "send"; }
    if(i == 36){ return "recv"; }
    if(i == 37){ return "WSAPoll"; }
    if(i == 38){ return "SystemFunction036"; }
    /* user32, from name 39: the smallest set that puts a window on the screen with an
       editable text area in it. No gdi32 -- an EDIT control draws itself (D-0000-0004). */
    if(i == 39){ return "RegisterClassExA"; }
    if(i == 40){ return "CreateWindowExA"; }
    if(i == 41){ return "DefWindowProcA"; }
    if(i == 42){ return "GetMessageA"; }
    if(i == 43){ return "TranslateMessage"; }
    if(i == 44){ return "DispatchMessageA"; }
    if(i == 45){ return "PostQuitMessage"; }
    if(i == 46){ return "ShowWindow"; }
    return "SendMessageA";
}
/* The DLLs, as a table instead of three hand-kept constants. Adding one is a row here and
   a row in dllfirst -- the import directory and the IAT/ILT are written by a loop over
   ndll, so nothing counts DLLs by hand. When the three groups were unrolled, a fourth DLL
   twice produced an .exe that built, had the right size, and hung. */
long ndll(void){ return 4 + nextd; }

char *dllname(long d){
    if(d == 0) return "KERNEL32.dll";
    if(d == 1) return "WS2_32.dll";
    if(d == 2) return "ADVAPI32.dll";
    return "USER32.dll";
}

/* index of the first function of DLL d in impname(); dllfirst(ndll()) is the total */
long dllfirst(long d){
    if(d == 0) return 0;
    if(d == 1) return KCOUNT;
    if(d == 2) return KCOUNT + WCOUNT;
    if(d == 3) return KCOUNT + WCOUNT + ACOUNT;
    { long i; long n; n = NIMP; i = 0;
      while(i < d - 4 && i < nextd){ n = n + extcount(i); i = i + 1; }
      return n; }
}

/* offset of hint/name entry i within the name block */
long impoff(long i){
    long o; long k; long n;
    o = 0; k = 0;
    while(k < i){
        n = 3 + impnamelen(k);
        if((n % 2) == 1){ n = n + 1; }
        o = o + n; k = k + 1;
    }
    return o;
}
long align(long v,long a){ while((v % a) != 0){ v = v + 1; } return v; }

long writepe(){
    long textrva; long textraw; long rdatarva; long rdataraw; long bssrva; long imgsize;
    long codeva; long datava; long bssva; long iatva; long idt; long iat; long names;
    long i; long k; long v; long fd; long wsys; long winit;
    long iatlen; long d; long dnam;
    /* The IAT (and identical ILT) each hold KCOUNT kernel32 thunks, a null,
       WCOUNT ws2_32 thunks, a null, ACOUNT advapi32 thunks, and a null:
       NIMP + 3 eight-byte entries. */
    iatlen = 8 * (NIMP + next_ + ndll());  /* every import, plus one terminator per DLL */
    while((codelen % 8) != 0){ e(0x90); }
    while((datlen % 8) != 0){ pd(0); }
    textrva = 0x1000;
    rdatarva = align(textrva + codelen, 0x1000);
    idt = datlen;
    iat = idt + 20 * (ndll() + 1);         /* one entry per DLL, plus a null one */
    names = iat + iatlen + iatlen;         /* IAT, then ILT, then the names */
    /* --- import directory table: one entry per DLL, then a null one --- */
    d = 0;
    dnam = impoff(NIMP + next_);           /* the DLL names sit after the hint/name table */
    while(d < ndll()){
        /* thunk k of DLL d sits at slot dllfirst(d) + d + k: every earlier group has
           contributed its own functions plus one terminator. */
        v = 8 * (dllfirst(d) + d);
        pd32(rdatarva + iat + iatlen + v);            /* this DLL's ILT */
        pd32(0); pd32(0);
        pd32(rdatarva + names + dnam);                /* its name */
        pd32(rdatarva + iat + v);                     /* its IAT */
        dnam = dnam + dllnamelen(d) + 1;
        d = d + 1;
    }
    pd32(0); pd32(0); pd32(0); pd32(0); pd32(0);      /* null directory entry */
    /* --- the IAT, then an identical ILT --- */
    k = 0;
    while(k < 2){
        d = 0;
        while(d < ndll()){
            i = dllfirst(d);
            while(i < dllfirst(d + 1)){ pd32(rdatarva + names + impoff(i)); pd32(0); i = i + 1; }
            pd32(0); pd32(0);                         /* one terminator per DLL */
            d = d + 1;
        }
        k = k + 1;
    }
    /* --- hint/name table --- */
    i = 0;
    while(i < NIMP + next_){
        pd16(0); pdsimp(i);
        if((impnamelen(i) % 2) == 0){ pd(0); }
        i = i + 1;
    }
    d = 0;
    while(d < ndll()){ pdsdll(d); d = d + 1; }
    textraw = align(codelen, 512);
    rdataraw = align(datlen, 512);
    bssrva = align(rdatarva + datlen, 0x1000);
    imgsize = align(bssrva + bsslen, 0x1000);
    codeva = VBASE + textrva;
    datava = VBASE + rdatarva;
    bssva = VBASE + bssrva;
    iatva = datava + iat;
    wsys = fnbyname("__wsys");
    winit = fnbyname("__winit");

    i = 0;
    while(i < nfx){
        k = fxkind[i];
        if(k == FX_CALL){ e32at(fxoff[i],fadr[fxval[i]] - (fxoff[i]+4)); }
        else if(k == FX_BSS32){ e32at(fxoff[i],bssva + fxval[i]); }
        else if(k == FX_WSYS){ e32at(fxoff[i],fadr[wsys] - (fxoff[i]+4)); }
        else if(k == FX_WINIT){ e32at(fxoff[i],fadr[winit] - (fxoff[i]+4)); }
        else if(k == FX_IAT){ e32at(fxoff[i],iatva - (codeva + fxoff[i] + 4)); }
        else if(k == FX_SLOT){ e32at(fxoff[i], extiat(fxval[i])); }
        else if(k == FX_SHIM){
            long a; a = codeva + fxval[i];
            e32at(fxoff[i], a);
            e32at(fxoff[i] + 4, a >> 32);
        }
        else if(k == FX_FADR){
            /* The address a callback needs: absolute, because Windows calls it from its
               own code and nothing rip-relative would mean anything there. */
            long a; a = codeva + fadr[fxval[i]];
            e32at(fxoff[i], a);
            e32at(fxoff[i] + 4, a >> 32);
        }
        else {
            if(k == FX_DATA){ v = datava + fxval[i]; } else { v = bssva + fxval[i]; }
            e32at(fxoff[i],v);
            e32at(fxoff[i]+4,v>>32);
        }
        i = i + 1;
    }

    hlen = 0;
    /* DOS header and stub */
    ph(77); ph(90); ph16(0x90); ph16(3); ph16(0); ph16(4);
    ph16(0); ph16(0xFFFF); ph16(0); ph16(0xB8);
    ph16(0); ph16(0); ph16(0); ph16(0x40);
    while(hlen < 60){ ph(0); }
    ph32(0x80);                                     /* e_lfanew */
    ph(0x0E); ph(0x1F); ph(0xBA); ph(0x0E); ph(0); ph(0xB4); ph(0x09);
    ph(0xCD); ph(0x21); ph(0xB8); ph(0x01); ph(0x4C); ph(0xCD); ph(0x21);
    phs("This program cannot be run in DOS mode.");
    ph(13); ph(13); ph(10); ph(36);
    while(hlen < 128){ ph(0); }
    /* PE signature and COFF header */
    ph(80); ph(69); ph(0); ph(0);
    ph16(0x8664); ph16(3); ph32(0); ph32(0); ph32(0); ph16(240); ph16(0x23);
    /* optional header */
    ph16(0x20B); ph(1); ph(0);
    ph32(textraw); ph32(rdataraw); ph32(align(bsslen,512));
    ph32(textrva + entryoff); ph32(textrva);
    ph64(VBASE);
    ph32(0x1000); ph32(512);
    ph16(6); ph16(0); ph16(0); ph16(0); ph16(6); ph16(0);
    ph32(0);
    ph32(imgsize); ph32(HDRMAX); ph32(0);
    ph16(3); ph16(0x8100);                          /* subsystem CUI, dllchar */
    ph64(0x800000); ph64(0x800000); ph64(0x100000); ph64(0x1000);
    ph32(0); ph32(16);
    ph32(0); ph32(0);                               /* export */
    ph32(rdatarva + idt); ph32(60);                 /* import directory */
    i = 0;
    while(i < 10){ ph32(0); ph32(0); i = i + 1; }
    ph32(rdatarva + iat); ph32(iatlen);             /* IAT directory */
    ph32(0); ph32(0); ph32(0); ph32(0); ph32(0); ph32(0);
    /* section table */
    phs(".text"); ph(0); ph(0); ph(0);
    ph32(codelen); ph32(textrva); ph32(textraw); ph32(HDRMAX);
    ph32(0); ph32(0); ph16(0); ph16(0); ph32(0x60000020);
    phs(".rdata"); ph(0); ph(0);
    ph32(datlen); ph32(rdatarva); ph32(rdataraw); ph32(HDRMAX + textraw);
    ph32(0); ph32(0); ph16(0); ph16(0); ph32(0x40000040);
    phs(".bss"); ph(0); ph(0); ph(0); ph(0);
    ph32(bsslen); ph32(bssrva); ph32(0); ph32(0);
    ph32(0); ph32(0); ph16(0); ph16(0); ph32(0xC0000080);
    while(hlen < HDRMAX){ ph(0); }

    while((codelen % 512) != 0){ e(0); }
    while((datlen % 512) != 0){ pd(0); }
    fd = opn((long)&outname[0],577,493);
    if(fd < 0){ fail("cannot create the output file"); }
    wrbuf(fd,(long)&hdr[0],hlen);
    wrbuf(fd,(long)&code[0],codelen);
    wrbuf(fd,(long)&dat[0],datlen);
    cls(fd);
    chm((long)&outname[0],493);
    return 0;
}

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
    parseprogram();
    if(winmode != 0){ writepe(); } else { writeelf(); }
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
    long i;
    /* --version before the argument count check: asking a compiler what it is should
       not require giving it a source file and an output name.  src/wantzel.wz carries
       the same string in its VERSION constant. */
    if(argc == 2 && (argeqs(argv[1],"--version") || argeqs(argv[1],"-v"))){
        wrs(1,"wantzel " VERSION "\n");
        return 0;
    }
    /* Run with no arguments at all, say what this program IS.  Someone who finds the
       binary without the repository around it has no other way to tell.  Only here: a
       successful compile stays silent, so this cannot end up in a build log. */
    if(argc < 3){
        wrs(2,"wantzel " VERSION " -- a compiler for code that AI writes: strict, dependency-free, extremely fast.\n");
        wrs(2,"Copyright (c) 2026 Floris Knol.  MIT licence.  https://github.com/wantzel/wantzel\n\n");
        wrs(2,"usage: wantzel <source.wz> <executable> [--target=linux|windows]\n");
        wrs(2,"       wantzel --version\n");
        return 1;
    }
    if(argc > 4){
        wrs(2,"usage: wantzel <source.wz> <executable> [--target=linux|windows]\n");
        return 1;
    }
    setlibdir(argv[0]);
    i = 0; while(argv[1][i] != 0){ pathbuf[i] = argv[1][i]; i = i + 1; }
    pathbuf[i] = 0;
    i = 0; while(argv[2][i] != 0){ outname[i] = argv[2][i]; i = i + 1; }
    outname[i] = 0; outnamelen = i;
    /* THE TARGET COMES FROM --target= AND FROM NOWHERE ELSE.  A name ending in .exe
       used to select Windows on its own, which made the output NAME a second and
       invisible way to choose the target.  A .exe name without --target
       is refused rather than quietly built for Linux. */
    winmode = 0;
    tgiven = 0;
    if(argc == 4){
        if(argeqc(argv[3],"--target=windows") || argeqc(argv[3],"-twindows")){ winmode = 1; tgiven = 1; }
        else if(argeqc(argv[3],"--target=linux") || argeqc(argv[3],"-tlinux")){ winmode = 0; tgiven = 1; }
        else {
            wrs(2,"wantzel: unknown option (use --target=linux or --target=windows)\n");
            return 1;
        }
    }
    if(tgiven == 0 && i >= 4){
        if(outname[i-4] == '.' && lower((long)(unsigned char)outname[i-3]) == 101
           && lower((long)(unsigned char)outname[i-2]) == 120
           && lower((long)(unsigned char)outname[i-1]) == 101){
            wrs(2,"wantzel: the output name ends in .exe but no target was given; add --target=windows (or --target=linux to build an ELF under that name)\n");
            return 1;
        }
    }
    return (int)compile();
}
