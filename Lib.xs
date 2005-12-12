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
#define is_event(sv)	(SvTYPE(sv) == SVt_RV && sv_derived_from(sv, "Event::Lib::base"))

/* #define EVENT_LIB_DEBUG */

#ifdef EVENT_LIB_DEBUG
#   define DEBUG_warn(...)  warn(__VA_ARGS__)
#else
#   define DEBUG_warn(...)
#endif

#define EVf_EVENT_SET	    0x00000001
#define EVf_PRIO_SET	    0x00000002

#define EvFLAGS(ev)	    (ev->flags)

#define EvEVENT_SET(ev)	    (EvFLAGS(ev) & EVf_EVENT_SET)
#define EvEVENT_SET_on(ev)  EvFLAGS(ev) |= EVf_EVENT_SET
#define EvEVENT_SET_off(ev) EvFLAGS(ev) &= ~EVf_EVENT_SET

#define EvPRIO_SET(ev)	    (EvFLAGS(ev) & EVf_PRIO_SET)
#define EvPRIO_SET_on(ev)   EvFLAGS(ev) |= EVf_PRIO_SET
#define EvPRIO_SET_off(ev)  EvFLAGS(ev) &= ~EVf_PRIO_SET

SV * do_exception_handler (pTHX_ short event, SV *ev, SV *err);
void do_callback (int fd, short event, SV *ev);

struct event_args {
    struct event    ev;		/* the event that was triggered */
    SV		    *io;	/* the associated filehandle */
    CV		    *func;	/* the Perl callback to handle event */
    int		    num;	/* number of additional args */
    SV		    **args;	/* additional args */
    const char	    *type;	/* so we know into which class to bless in do_callback */
    CV		    *trapper;	/* exception handler */
    int		    evtype;	/* what kind of event or signal; always 0 for timer events */
    int		    priority;	/* what priority */
    int		    flags;	/* EVf_EVENT_SET, EVf_PRIO_SET */
};

CV *DEFAULT_EXCEPTION_HANDLER = NULL;

void free_args (struct event_args *args) {
    register int i;

    if (args->io)
	SvREFCNT_dec(args->io);
    
    SvREFCNT_dec(args->func);
    for (i = 0; i < args->num; i++)
	SvREFCNT_dec(args->args[i]);
    Safefree(args->args);

    if (args->trapper != DEFAULT_EXCEPTION_HANDLER)
	SvREFCNT_dec(args->trapper);
    
    Safefree(args);
}

SV * clone_event (pTHX_ SV *sv) {
    register int i;
    struct event_args *src = (struct event_args*)SvIV(SvRV(sv));
    struct event_args *ev;
    SV *newev = NEWSV(0,0);
    
    New(0, ev, 1, struct event_args);

    ev->io	= src->io; SvREFCNT_inc(ev->io);
    ev->func	= src->func; SvREFCNT_inc(ev->func);
    ev->num	= src->num;
    ev->type	= src->type;
    ev->evtype	= src->evtype;
    ev->trapper	= src->trapper;
    if (ev->trapper != DEFAULT_EXCEPTION_HANDLER)
	SvREFCNT_inc(ev->trapper);
    ev->priority = src->priority;
    EvFLAGS(ev) = 0;
    
    New(0, ev->args, ev->num, SV*);
    for (i = 0; i < ev->num; ++i) {
	ev->args[i] = src->args[i];
	SvREFCNT_inc(ev->args[i]);
    }
  
    sv_setref_pv(newev, src->type, (void*)ev);

    return newev;
}

SV * do_exception_handler (pTHX_ short event, SV *ev, SV *err) {
    register int i;
    int count;
    struct event_args *args = (struct event_args*)SvIV(SvRV(ev));

    dSP;
    
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    
    EXTEND(SP, event ? args->num + 3 : 2);
    PUSHs(ev);
    
    PUSHs(sv_2mortal(err));

    if (event) {
	PUSHs(sv_2mortal(newSViv(event)));
	for (i = 0; i < args->num; i++)
	    PUSHs(args->args[i]);
    }
    

    PUTBACK;
    count = call_sv((SV*)args->trapper, G_SCALAR|G_EVAL);
    
    if (SvTRUE(ERRSV))
	croak("%s", SvPV_nolen(ERRSV));
    
    SPAGAIN;
    
    if (count != 1)
	ev = &PL_sv_undef;
    else
	ev = POPs;
    
    PUTBACK;
    FREETMPS;
    LEAVE;

    return ev;
}

void do_callback (int fd, short event, SV *ev) {
    register int i;
    struct event_args *args = (struct event_args*)SvIV(SvRV(ev));

    dSP;
    
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    
    EXTEND(SP, args->num + 2);

    PUSHs(ev);
    PUSHs(sv_2mortal(newSViv(event)));

    for (i = 0; i < args->num; i++)
	PUSHs(args->args[i]);

    PUTBACK;
    call_sv((SV*)args->func, G_VOID|G_EVAL);
    if (SvTRUE(ERRSV))
	do_exception_handler(aTHX_ event, ev, newSVsv(ERRSV));

    if (!event_pending(&args->ev, event, NULL))
    	SvREFCNT_dec(ev);

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
unsigned int LOG_LEVEL = _EVENT_LOG_ERR;
static const char* str[] = { "debug", "msg", "warn", "err", "???" };

void log_cb (int sev, const char *msg) {
    if (sev >= LOG_LEVEL) {
	if (sev > _EVENT_LOG_ERR) 
	    sev = _EVENT_LOG_ERR + 1;
	PerlIO_printf(PerlIO_stderr(), "[%s] %s\n", str[sev], msg);
    }
}
#endif

bool EVENT_LOOP_RUNNING = FALSE;

MODULE = Event::Lib		PACKAGE = Event::Lib		

INCLUDE: const-xs.inc

BOOT:
{
#ifdef HAVE_LOG_CALLBACKS
    event_set_log_callback(log_cb);
#endif
    event_init();
    DEFAULT_EXCEPTION_HANDLER = newXS(NULL, XS_Event__Lib__default_callback, __FILE__);
}

void
_default_callback (...)
CODE:
{
    croak("%s", SvPV_nolen(ST(1)));
}
    
void
event_init()
PROTOTYPE:
CODE:
{
    event_init();
}

void
event_log_level (level)
    unsigned int level;
CODE:
{
#ifdef HAVE_LOG_CALLBACKS
    LOG_LEVEL = level;
#endif
}

void
event_register_except_handler (func)
    SV *func;
CODE:
{
    if (!SvROK(func) && (SvTYPE(SvRV(func)) != SVt_PVCV))
	croak("Argument to event_register_except_handler must be code-reference");
    DEFAULT_EXCEPTION_HANDLER = (CV*)SvRV(func);
}

struct event_args *
event_new (io, event, func, ...)
    SV	    *io;
    short   event;
    SV	    *func;
PREINIT:
    static char *CLASS = "Event::Lib::event";
    struct event_args *args;
CODE:
{
    register int i;

    if (GIMME_V == G_VOID)
	XSRETURN_UNDEF;

    if (!SvROK(func) && (SvTYPE(SvRV(func)) != SVt_PVCV))
	croak("Third argument to event_new must be code-reference");
   
    New(0, args, 1, struct event_args); 

    args->io = io;
    args->func = (CV*)SvRV(func);
    args->type = CLASS;
    args->trapper = DEFAULT_EXCEPTION_HANDLER;
    args->evtype = event;
    args->priority = -1;
    EvFLAGS(args) = 0;

    SvREFCNT_inc(args->io);
    SvREFCNT_inc(args->func);

    args->num = items - 3;
    New(0, args->args, args->num, SV*);

    for (i = 0; i < args->num; i++) {
	if (is_event(ST(i+3)))
	    args->args[i] = clone_event(aTHX_ ST(i+3));
	else	
	    args->args[i] = ST(i+3);
	SvREFCNT_inc(args->args[i]);
    }

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
PREINIT:
    static char *CLASS = "Event::Lib::signal";
    struct event_args *args;
CODE:
{
    register int i;
    
    if (GIMME_V == G_VOID)
	XSRETURN_UNDEF;
    
    if (!SvROK(func) && (SvTYPE(SvRV(func)) != SVt_PVCV))
	croak("Second argument to event_new must be code-reference");
    
    New(0, args, 1, struct event_args);

    args->io = NULL;
    args->func = (CV*)SvRV(func);
    args->type = CLASS;
    args->trapper = DEFAULT_EXCEPTION_HANDLER;
    args->evtype = signal;
    args->priority = -1;
    EvFLAGS(args) = 0;

    SvREFCNT_inc(args->func);
    
    args->num = items - 2;
    New(0, args->args, args->num, SV*);

    for (i = 0; i < args->num; i++) {
	if (is_event(ST(i+2)))
	    args->args[i] = clone_event(aTHX_ ST(i+2));
	else	
	    args->args[i] = ST(i+2);
	SvREFCNT_inc(args->args[i]);
    }
    
    RETVAL = args;
}
OUTPUT:
    RETVAL

struct event_args *
timer_new (func, ...)
    SV *func;
PREINIT:
    static char *CLASS = "Event::Lib::timer";
    struct event_args *args;
CODE:
{
    register int i;

    if (GIMME_V == G_VOID)
	XSRETURN_UNDEF;
    
    if (!SvROK(func) && (SvTYPE(SvRV(func)) != SVt_PVCV))
	croak("First argument to timer_new must be code-reference");
    
    New(0, args, 1, struct event_args);
    
    args->io = NULL;
    args->func = (CV*)SvRV(func);
    args->type = CLASS;
    args->trapper = DEFAULT_EXCEPTION_HANDLER;
    args->evtype = 0;
    args->priority = -1;
    EvFLAGS(args) = 0;

    SvREFCNT_inc(args->func);
    
    args->num = items - 1;
    New(0, args->args, args->num, SV*);

    for (i = 0; i < args->num; i++) {
	if (is_event(ST(i+1)))
	    args->args[i] = clone_event(aTHX_ ST(i+1));
	else	
	    args->args[i] = ST(i+1);
	SvREFCNT_inc(args->args[i]);
    }

    RETVAL = args;
}
OUTPUT:
    RETVAL

void
event_add (args, ...)
    struct event_args *args;
CODE:
{
    struct timeval tv = { 1, 0 };
    int time_given = 0;
  
    if (!EvEVENT_SET(args)) {
	if (strEQ(args->type, "Event::Lib::event")) {
	    event_set(&args->ev, PerlIO_fileno(to_perlio(args->io)), 
		      (short)args->evtype, 
		      CALLBACK_CAST do_callback, 
		      (void*)ST(0));
	}
	else if (strEQ(args->type, "Event::Lib::signal")) {
	    signal_set(&args->ev, 
		       args->evtype, 
		       CALLBACK_CAST do_callback, 
		       (void*)ST(0));
	}
	else if (strEQ(args->type, "Event::Lib::timer")) {
	    evtimer_set(&args->ev, 
			CALLBACK_CAST do_callback, 
			(void*)ST(0));
	}
	EvEVENT_SET_on(args);
    }
#ifdef HAVE_PRIORITIES
    if (!EvPRIO_SET(args)) {
	event_priority_set(&args->ev, args->priority);
	EvPRIO_SET_on(args);
    }
#endif

    if (sv_derived_from(ST(0), "Event::Lib::timer") && items == 1)
	time_given = 1;

    if (items > 1) {

	/* add(0) should behave like add() */
	if (SvIOK(ST(1)) && SvIV(ST(1)) == 0)
	    goto skip;
	
	make_timeval(&tv, SvNV(ST(1)));
	time_given = 1;
    }
    
    skip:
    if (event_add(&args->ev, time_given ? &tv : NULL) == 0) {
	SvREFCNT_inc(ST(0));
	XSRETURN(1);
    }

    /* event_add failed :-( */
    do_exception_handler(aTHX_ 0, ST(0), newSVpvn("Couldn't add event", 18));
}	

void
event_del (args)
    struct event_args *args;
CODE:
{
    if (event_del(&args->ev) == 0)
	XSRETURN_YES;
    XSRETURN_NO;
}

void
event_free (args, flags = 0)
    struct event_args *args;
    int flags;
CODE:
{
    if (!flags)
	warn("You should not call event_free unless it's an emergency");
    
    event_del(&args->ev);
    free_args(args);

    /* unbless referent:
     * this is crucial because access to the object after it
     * has been freed could lead to segfaults */
    SvFLAGS(SvRV(ST(0))) &= ~SVs_OBJECT;
}

void
event_mainloop ()
PROTOTYPE: 
CODE:
{
    if (EVENT_LOOP_RUNNING) {
	warn("Attempt to trigger another loop while the main-loop is already running");
	return;
    }

    EVENT_LOOP_RUNNING = TRUE;
    event_dispatch();
}

void
event_one_loop (...)
PROTOTYPE: ;$
CODE:
{
    if (EVENT_LOOP_RUNNING) {
	warn("Attempt to trigger another loop while the main-loop is already running");
	return;
    }

    if (items > 0) {
	struct timeval tv;
	make_timeval(&tv, SvNV(ST(0)));
	event_loopexit(&tv);
    }
    event_loop(EVLOOP_ONCE);
}

void
event_one_nbloop ()
PROTOTYPE:
CODE:
{
    event_loop(EVLOOP_NONBLOCK);
}

MODULE = Event::Lib		PACKAGE = Event::Lib::base

void
except_handler (args, func)
    struct event_args *args;
    SV *func;
CODE:
{
    if (!SvROK(func) && (SvTYPE(SvRV(func)) != SVt_PVCV))
	croak("Argument to event_register_except_handler must be code-reference");
    args->trapper = (CV*)SvRV(func);
    SvREFCNT_inc(args->trapper);
    XSRETURN(1);
}
    
void
callback (args)
    struct event_args *args;
CODE:
{
    ST(0) = sv_2mortal(newRV_inc((SV*)args->func));
    XSRETURN(1);
}

void
set_priority (args, prio)
    struct event_args *args;
    int prio;
CODE:
{
    args->priority = prio;
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

    if (!event_pending(&args->ev, EV_READ|EV_WRITE|EV_TIMEOUT, &tv))
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
    DEBUG_warn("[%s]", __FUNCTION__);
    if (!event_pending(&args->ev, EV_READ|EV_WRITE, NULL)) 
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
    
    if (!signal_pending(&args->ev, &tv))
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
    DEBUG_warn("[%s]", __FUNCTION__);
    if (!signal_pending(&args->ev, NULL)) 
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
    
    if (!evtimer_pending(&args->ev, &tv))
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
    DEBUG_warn("[%s]", __FUNCTION__);
    if (!evtimer_pending(&args->ev, NULL)) 
	free_args(args);
}
