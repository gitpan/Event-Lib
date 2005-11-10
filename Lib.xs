#ifdef WIN32
#undef read
#undef write
#else
#include <sys/time.h>
#endif

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <event.h>

#include "ppport.h"

#include "const-c.inc"

#define CALLBACK_CAST	(void (*)(int, short, void*))
#define to_perlio(sv)	IoIFP(sv_2io(sv))

#define EVf_DONT_FREE	SVf_FAKE

struct event_args {
    struct event    *ev;	/* the event that was triggered */
    SV		    *io;	/* the associated filehandle */
    CV		    *func;	/* the Perl callback to handle event */
    int		    num;	/* number of additional args */
    SV		    **args;	/* additional args */
    const char	    *type;	/* so we know into which class to bless in do_callback */
};

void free_args (struct event_args *args) {
    register int i;

    if (args->io)
	SvREFCNT_dec(args->io);
    
    SvREFCNT_dec(args->func);
    for (i = 0; i < args->num; i++)
	SvREFCNT_dec(args->args[i]);
    Safefree(args->args);
    Safefree(args->ev);
    Safefree(args);
}

void do_callback (int fd, short event, struct event_args *args) {
    register int i;
    SV *ev;
    dSP;
    
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    
    EXTEND(SP, args->num + 2);
    ev = sv_newmortal();
    sv_setref_pv(ev, args->type, (void*) args);

    /* the mortal ev must not be DESTROYed the usual way (i.e.: freeing the C
     * struct it points to).  To signal this, the SVf_FAKE flag (alias
     * EVf_DONT_FREE) is used and checked for in each of the DESTROY methods */
    SvFLAGS(SvRV(ev)) |= EVf_DONT_FREE;
    PUSHs(ev);
    PUSHs(sv_2mortal(newSViv(event)));

    for (i = 0; i < args->num; i++)
	PUSHs(args->args[i]);

    PUTBACK;
    call_sv((SV*)args->func, G_VOID|G_EVAL);
    if (SvTRUE(ERRSV))
	croak("%s", SvPV_nolen(ERRSV));
    SPAGAIN;
    PUTBACK;
    FREETMPS;
    LEAVE;

}

#ifdef WIN32
#define THEINLINE __forceinline
#else
#define THEINLINE inline
#endif

THEINLINE void make_timeval (struct timeval *tv, double t) {
    tv->tv_sec = (long)t;
    tv->tv_usec = (t - (long)t) * 1e6f;
}

THEINLINE double delta_timeval (struct timeval *t1, struct timeval *t2) {
    double t1t = t1->tv_sec + (double)t1->tv_usec / 1e6f;
    double t2t = t2->tv_sec + (double)t2->tv_usec / 1e6f; 
    return t2t - t1t;
}

#ifdef HAVE_LOG_CALLBACKS
static const char* str[] = { "debug", "msg", "warn", "err", "???" };

void log_cb (int sev, const char *msg) {
    if (sev >= _EVENT_LOG_ERR) {
	if (sev > _EVENT_LOG_ERR) 
	    sev = _EVENT_LOG_ERR + 1;
	PerlIO_printf(PerlIO_stderr(), "[%s] %s\n", str[sev], msg);
    }
}
#endif

MODULE = Event::Lib		PACKAGE = Event::Lib		

INCLUDE: const-xs.inc

BOOT:
{
#ifdef HAVE_LOG_CALLBACKS
    event_set_log_callback(log_cb);
#endif
    event_init();
}

void
event_init()
PROTOTYPE:
CODE:
{
    event_init();
}

struct event_args *
event_new (io, event, func, ...)
    SV	    *io;
    short   event;
    SV	    *func;
PREINIT:
    static char *CLASS = "Event::Lib::event";
CODE:
{
    register int i;
    struct event_args *args;
    
    New(0, args, 1, struct event_args); 
    New(0, args->ev, 1, struct event);

    if (!SvROK(func) && (SvTYPE(SvRV(func)) != SVt_PVCV))
	croak("Third argument to event_new must be code-reference");
   
    args->io = io;
    args->func = (CV*)SvRV(func);
    args->type = CLASS;
    SvREFCNT_inc(args->io);
    SvREFCNT_inc(args->func);

    args->num = items - 3;
    New(0, args->args, args->num, SV*);

    for (i = 0; i < args->num; i++) {
	args->args[i] = ST(i+3);
	SvREFCNT_inc(args->args[i]);
    }

    event_set(args->ev, PerlIO_fileno(to_perlio(io)), event, CALLBACK_CAST do_callback, args);
    RETVAL = args;
}
OUTPUT:
    RETVAL

int
priority_init (nump)
    int nump;
PROTOTYPE: $
CODE:
{
#ifdef HAVE_PRIORITIES
    RETVAL = event_priority_init(nump);
#else
    RETVAL = 1;
#endif
}
OUTPUT:
    RETVAL

struct event_args *
signal_new (signal, func, ...)
    int signal;
    SV	*func;
PROTOTYPE: $&;@
PREINIT:
    static char *CLASS = "Event::Lib::signal";
CODE:
{
    register int i;
    struct event_args *args;
    New(0, args, 1, struct event_args);
    New(0, args->ev, 1, struct event);
    args->io = NULL;
    args->func = (CV*)SvRV(func);
    args->type = CLASS;
    SvREFCNT_inc(args->func);
    
    args->num = items - 2;
    New(0, args->args, args->num, SV*);

    for (i = 0; i < args->num; i++) {
	args->args[i] = ST(i+2);
	SvREFCNT_inc(args->args[i]);
    }
    
    signal_set(args->ev, signal, CALLBACK_CAST do_callback, args);
    RETVAL = args;
}
OUTPUT:
    RETVAL


struct event_args *
timer_new (func, ...)
    SV *func;
PROTOTYPE: &;@
PREINIT:
    static char *CLASS = "Event::Lib::timer";
CODE:
{
    register int i;
    struct event_args *args;
    New(0, args, 1, struct event_args);
    New(0, args->ev, 1, struct event);
    args->io = NULL;
    args->func = (CV*)SvRV(func);
    args->type = CLASS;
    SvREFCNT_inc(args->func);
    
    args->num = items - 1;
    New(0, args->args, args->num, SV*);

    for (i = 0; i < args->num; i++) {
	args->args[i] = ST(i+1);
	SvREFCNT_inc(args->args[i]);
    }

    evtimer_set(args->ev, CALLBACK_CAST do_callback, args);
    RETVAL = args;
}
OUTPUT:
    RETVAL
    
#if 0    
struct bufferevent *
bufferevent_new (io, rcb, wcb, ecb)
    SV *io;
    SV *rcb;
    SV *wcb;
    SV *ecb;
PREINIT:
    static char *CLASS = "Event::Lib::bufferevent";
CODE:
{
}

#endif

void
event_add (args, ...)
    struct event_args *args;
CODE:
{
    struct timeval tv = { 1, 0 };
    int time_given = 0;
    
    if (sv_isa(ST(0), "Event::Lib::timer") && items == 1)
	time_given = 1;

    if (items > 1) {
	make_timeval(&tv, SvNV(ST(1)));
	time_given = 1;
    }

    if (event_add(args->ev, time_given ? &tv : NULL) == 0)
	XSRETURN_YES;

    XSRETURN_NO;
}	

void
event_del (args)
    struct event_args *args;
CODE:
{
    if (event_del(args->ev) == 0)
	XSRETURN_YES;
    XSRETURN_NO;
}

void
event_free (args)
    struct event_args *args;
CODE:
{
    event_del(args->ev);
    free_args(args);

    /* unbless referent:
     * this is crucial because access to the object after it
     * has been freed could lead to segfaults */
    SvFLAGS(SvRV(ST(0))) &= ~SVs_OBJECT;
}

void
event_dispatch (flags = 0, ...)
    int flags;
PROTOTYPE: ;$$
CODE:
{
    if (items > 1) {
	struct timeval tv;
	make_timeval(&tv, SvNV(ST(1)));
	event_loopexit(&tv);
    }

    event_loop(flags);
}

MODULE = Event::Lib		PACKAGE = Event::Lib::base

void
add (args, ...)
    struct event_args *args;
CODE:
{
    struct timeval tv = { 1, 0 };
    int time_given = 0;
    
    if (sv_isa(ST(0), "Event::Lib::timer") && items == 1) 
	time_given = 1;

    if (items > 1) {
	make_timeval(&tv, SvNV(ST(1)));
	time_given = 1;
    }

    if (event_add(args->ev, time_given ? &tv : NULL) == 0)
	XSRETURN_YES;

    XSRETURN_NO;
}	

void
del (args)
    struct event_args *args;
CODE:
{
    if (event_del(args->ev) == 0)
	XSRETURN_YES;
    XSRETURN_NO;
}

int
set_priority (args, prio)
    struct event_args *args;
    int prio;
CODE:
{
#ifdef HAVE_PRIORITIES
    RETVAL = event_priority_set(args->ev, prio);
#else
    RETVAL = 1;
#endif
}
OUTPUT:
    RETVAL

void
free (args)
    struct event_args *args;
CODE:
{
    event_del(args->ev);
    free_args(args);

    /* unbless referent:
     * this is crucial because access to the object after it
     * has been freed could lead to segfaults */
    SvFLAGS(SvRV(ST(0))) &= ~SVs_OBJECT;
}

void
dispatch (args, flags = 0, ...)
    struct event_args *args;
    int flags;
CODE:
{
    if (items > 2) {
	struct timeval tv;
	make_timeval(&tv, SvNV(ST(2)));
	event_loopexit(&tv);
    }

    event_loop(flags);
}

MODULE = Event::Lib             PACKAGE = Event::Lib::event

void
fh (args)
    struct event_args *args;
CODE:
{
    ST(0) = args->io;
    XSRETURN(1);
}

void
pending (args)
    struct event_args *args;
CODE:
{
    struct timeval tv = { 0, 0 }, now;
    SV *sv;
    
    gettimeofday(&now, NULL);

    if (!event_pending(args->ev, EV_READ|EV_WRITE|EV_TIMEOUT, &tv))
	XSRETURN_NO;
    
    if (tv.tv_sec == 0 && tv.tv_usec == 0)
	sv = newSVpvn("0 but true", 10);
    else 
	sv = newSVnv(fabs(delta_timeval(&now, &tv)));

    ST(0) = sv_2mortal(sv);
    XSRETURN(1);
}

void
DESTROY (args)
    struct event_args *args;
CODE:
{
    if (SvFLAGS(SvRV(ST(0))) & EVf_DONT_FREE)
	/* Don't free the object created in the callback */
	return;

    if (!event_pending(args->ev, EV_READ|EV_WRITE, NULL)) 
	free_args(args);
}


MODULE = Event::Lib             PACKAGE = Event::Lib::signal

void
pending (args)
    struct event_args *args;
CODE:
{
    struct timeval tv = { 0, 0 }, now;
    SV *sv;
    
    gettimeofday(&now, NULL);
    
    if (!signal_pending(args->ev, &tv))
	XSRETURN_NO;
    
    if (tv.tv_sec == 0 && tv.tv_usec == 0)
	sv = newSVpvn("0 but true", 10);
    else 
	sv = newSVnv(fabs(delta_timeval(&now, &tv)));

    ST(0) = sv_2mortal(sv);
    XSRETURN(1);
}

void
DESTROY (args)
    struct event_args *args;
CODE:
{
    if (SvFLAGS(SvRV(ST(0))) & EVf_DONT_FREE)
	/* Don't free the object created in the callback */
	return;

    if (!signal_pending(args->ev, NULL)) 
	free_args(args);
}


MODULE = Event::Lib		PACKAGE = Event::Lib::timer

void
pending (args)
    struct event_args *args;
CODE:
{
    struct timeval tv = { 0, 0 }, now;
    SV *sv;

    gettimeofday(&now, NULL);
    
    if (!evtimer_pending(args->ev, &tv))
	XSRETURN_NO;
    
    if (tv.tv_sec == 0 && tv.tv_usec == 0)
	sv = newSVpvn("0 but true", 10);
    else 
	sv = newSVnv(fabs(delta_timeval(&now, &tv)));

    ST(0) = sv_2mortal(sv);
    XSRETURN(1);
}

void
DESTROY (args)
    struct event_args *args;
CODE:
{
    if (SvFLAGS(SvRV(ST(0))) & EVf_DONT_FREE)
	/* Don't free the object created in the callback */
	return;

    if (!evtimer_pending(args->ev, NULL)) 
	free_args(args);
}

MODULE = Event::Lib		PACKAGE = Event::Lib::bufferevent
