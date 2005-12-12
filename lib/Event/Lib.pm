package Event::Lib;

use 5.006;
use strict;
use warnings;

require Exporter;
require XSLoader;

our @ISA = qw(Exporter);
our $VERSION = '0.99_10';

XSLoader::load('Event::Lib', $VERSION);

use constant EVENT_FREE_NOWARN => 1;

eval q{
    use constant _EVENT_LOG_NONE	=> &_EVENT_LOG_ERR + 1;
};

@Event::Lib::event::ISA = @Event::Lib::signal::ISA = @Event::Lib::timer::ISA = qw/Event::Lib::base/;


our %EXPORT_TAGS = ( 'all' => [ qw(
	event_init
	event_log_level
	event_register_except_handler
	event_mainloop
	event_one_loop
	event_one_nbloop
	event_new
	event_add
	event_del
	event_free
	event_once
	priority_init
	signal_new
	signal_add
	signal_del
	timer_new
	timer_add
	timer_del

	EV_PERSIST
	EV_READ
	EV_SIGNAL
	EV_TIMEOUT
	EV_WRITE

	_EVENT_LOG_DEBUG
	_EVENT_LOG_MSG
	_EVENT_LOG_WARN
	_EVENT_LOG_ERR
	_EVENT_LOG_NONE

	EVENT_FREE_NOWARN
) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(
    event_init
    event_log_level
    event_register_except_handler
    event_mainloop
    event_one_loop
    event_one_nbloop
    
    event_new
    event_add
    event_del
    event_free
    event_once
    
    signal_new
    signal_add
    signal_del
   
    priority_init

    timer_new
    timer_add
    timer_del

    EV_PERSIST
    EV_READ
    EV_SIGNAL
    EV_TIMEOUT
    EV_WRITE

    _EVENT_LOG_DEBUG
    _EVENT_LOG_MSG
    _EVENT_LOG_WARN
    _EVENT_LOG_ERR
    _EVENT_LOG_NONE

    EVENT_FREE_NOWARN
);

*Event::Lib::base::add = \&event_add;
*Event::Lib::base::del = \&event_del;
*Event::Lib::base::free = \&event_free;

sub AUTOLOAD {
    # This AUTOLOAD is used to 'autoload' constants from the constant()
    # XS function.

    my $constname;
    our $AUTOLOAD;
    ($constname = $AUTOLOAD) =~ s/.*:://;
    if ($constname eq 'constant') {
	require Carp;
	Carp::croak "&Event::Lib::constant not defined";
    }

    my ($error, $val) = constant($constname);
    if ($error) { 
	require Carp;
	Carp::croak $error; 
    }

    {
	no strict 'refs';
	*$AUTOLOAD = sub { $val };
    }
    goto &$AUTOLOAD;
}

1;
__END__

=head1 NAME

Event::Lib - Perl extentions for event-based programming

=head1 SYNOPSIS

    use Event::Lib;
    use POSIX qw/SIGINT/;
    
    my $seconds;
    sub timer {
	my $event = shift;
	print "\r", ++$seconds;
	$event->add(1);
    }
    
    sub reader {
	my $event = shift;
	my $fh = $event->fh;
	print <$fh>;
	$event->add;
    }

    sub signal {
	my $event = shift;
	print "Caught SIGINT\n";
    }

    my $timer  = timer_new(\&timer);
    my $reader = event_new(\*STDIN, EV_READ, \&reader);
    my $signal = signal_new(SIGINT, \&signal);
	
    $timer->add(1);	# triggered every second
    $reader->add;
    $signal->add;
    
    event_mainloop;

=head1 DESCRIPTION

This module is a Perl wrapper around libevent(3) as available from
L<http://www.monkey.org/~provos/libevent/>.  It allows to execute a function
whenever a given event on a filehandle happens, a timeout occurs or a signal is
received.

Under the hood, one of the available mechanisms for asynchronously dealing with
events is used. This could be C<select>, C<poll>, C<epoll>, C<devpoll> or
C<kqueue>. The idea is that you don't have to worry about those details and the
various interfaces they offer. I<Event::Lib> offers a unified interface  to all
of them (but see L<"CONFIGURATION"> further below).

Once you've skimmed through the next two sections (or maybe even now), you
should have a look at L<"EXAMPLE: A SIMPLE TCP SERVER"> to get a feeling about
how it all fits together.

There's also a section briefly mentioning other event modules on the CPAN
and how they differ from I<Event::Lib> further below (L<"OTHER EVENT MODULES">).

=head1 INITIALIZATION

This happens via loading the module via C<use> or C<require>:

    use Event::Lib;
    
When you spawn off new processes, you have to call C<event_init> in each new
process otherwise the kqueue(2) mechanism wont properly initialize:

    use Event::Lib;
    
    my $pid = fork;

    if ($pid) {
	# parent
	wait;
    } else {
	# I am the child and you have to re-initialize
	event_init();
	...
    }

Note that when you use C<require> you have to package-qualify every call to
anything in I<Event::Lib>, unless you call C<< Event::Lib->import >>.

=head1 EVENTS

The standard procedure is to create a few events and afterwards enter the loop
(using C<event_mainloop>) to wait for and handle the pending events. This loop
is truely global and shared even between forked processes. The same is true for
events that you register. They will all be processed by the same loop, no matter
where or how you create them.

Each event has a Perl function associated with itself that gets triggered when
the event is due. Further event handling is delayed until the currently
executing event handler is done. If you want an event to be handled as soon as
it becomes imminent, it has to run in its own process so that it cannot be
disturbed by other event handlers. This is particularly important for
timer-based events when you expect those events to fire steadily every few
seconds.

There's one more little thing to be aware of: Sometimes it may apear that your
events aren't triggered because they produce no output in spite of your
precious C<print> statements you put in. If you see no output, then you're a
victim of buffering. The solution is to turn on autoflushing, so put

    $| = 1;

at the top of your program if no output appears on your screen or filehandles.

I<Event::Lib> knows three different kind of events: a filehandle becomes
readable/writeable, timeouts and signals.

=head2 Watching filehandles

Most often you will have a set of filehandles that you want to watch and handle
simultaneously. Think of a webserver handling multiple client requests. Such an 
event is created with C<event_new>:

=over 4

=item * event_new( $fh, $flags, $function, [@args] )

I<$fh> is the filehandle you want to watch. I<$flags> may be the bit-wise ORing
of I<EV_READ>, I<EV_WRITE> and I<EV_PERSIST>. I<EV_PERSIST> will make the event
persistent, that is: Once the event is triggered, it is not removed from the
event-loop. If you do not pass this flag, you have to re-schedule the event in
the event-handler I<$function>.

I<$function> is the callback that is executed when the given event happened.
This function is always called with at least two arguments, namely the event
object itself which was created by the above C<event_new> and an integer being
the event-type that occured (which could be EV_WRITE, EV_READ or EV_TIMEOUT).
I<@args> is an optional list of additional arguments your callback will
receive.

The function returns an event object (the very object that is later passed to the 
callback function).

Here's an example how to create a listening socket that can accept connections
from multiple clients:

    use IO::Socket::INET;
    use Event::Lib;
    
    sub accept_connection {
	my $event = shift;
	my $sock  = $event->fh;
	my $client = $sock->accept;
	...
    }
	
    my $server = IO::Socket::INET->new(
	LocalAddr	=> 'localhost',
	LocalPort	=> 9000,
	Proto		=> 'tcp',
	ReuseAddr	=> SO_REUSEADDR,
	Listen		=> 1,
	Blocking	=> 0,
    ) or die $!;

    my $main = event_new($server, EV_READ|EV_PERSIST, \&accept_connection);

    # add the event to the event loop
    $main->add;	

    event_mainloop();

The above can be done without the I<EV_PERSIST> flag as well:

    sub accept_connection {
	my $event = shift;
	my $sock = $event->fh;
	my $client = $sock->accept;
	...
	# re-schedule event
	$event->add;
    }
    ...
    my $main = event_new($server, EV_READ, \&accept_connection);
    $main->add;
    event_mainloop();

=item * event_add( $event, [$timeout] )

=item * $event-E<gt>add( [$timeout] )

This adds the event previously created with C<event_new> to the event-loop.
I<$timeout> is an optional argument specifying a timeout given as
floating-point number. It means that the event handler is triggered either when
the event happens or when I<$timeout> seconds have passed, whichever comes
first.

Consider this snippet:

    use Event::Lib;
    
    sub handler {
        my ($ev, $type) = @_;
	if ($type == EV_READ) {
	    ...
	}
	elsif ($type == EV_TIMEOUT) {
	    ...
	}
    }
    
    # wait at most for 1.5 seconds
    event_new(\*STDIN, EV_READ, \&handler)->add(1.5);
    event_one_loop;

If C<STDIN> becomes readable within 1.5 seconds, C<handler> will be called with
I<$type> set to C<EV_READ>. If nothing happens within these 1.5 seconds, it'll
be called with I<$type> set to <EV_TIMEOUT>.

When I<$timeout> is C<0> it behaves as if no timeout has been given, that is:
An infinite timeout is assumed. Any other timeout is taken literally, so C<0.0>
is not the same! In such a case, the event handler will be called immediately
with the event type set to C<EV_TIMEOUT>.

=item * $event-E<gt>fh

Returns the filehandle this I<$event> is supposed to watch. You will usually
call this in the event-handler.

=item * event_del( $event )

=item * $event-E<gt>del

This removes an event object from the event-loop. Note that the object itself
is not destroyed and freed. It is merely disabled and you can later re-enable
it by calling C<< $event->add >>.

=item * event_free( $event )

=item * $event-E<gt>free

This destroys I<$event> and frees all memory associated with it. After calling this
function/method, I<$event> is no longer an object and hence no longer usable.

It will also remove the event from the event-loop if it is still in the
event-queue.  It is ok to use this function after an event has been deleted
with C<event_delete>.

B<NOTE>: Using this function results in a warning message because it should be
I<Event::Lib>'s responsibility to free events for you. There's a very high
probability (close to 100%) that using C<event_free> will result in a segfault.

However, if you really have a scenario where you need to free events manually
(and can do so without the segfault;-), you can get rid of the warning by doing

    event_free( $event, EVENT_FREE_NOWARN );
    # or
    $event->free( EVENT_FREE_NOWARN );

You have been warned.

=back

=head2 Timer-based events

Sometimes you want events to happen periodically, regardless of any filehandles.
Such events are created with C<timer_new>:

=over 4

=item * timer_new( $function, [@args] )

This is very much the same as C<event_new>, only that it lacks its first two
parameters.  I<$function> is a reference to a Perl function that should be
executed. As always, this function will receive the event object as returned by
C<timer_new> as first argument, the type of event (always EV_TIMEOUT) plus the
optional argumentlist I<@args>.

=item * event_add( $event, [$timeout] )

=item * $event-E<gt>add( [$timeout] )

Adds I<$event> to the event-loop. The event is scheduled to be triggered every
I<$timeout> seconds where I<$timeout> can be any floating-point value. If
I<$timeout> is omitted, a value of one second is assumed.

It will throw an exception if adding the given event failed. If you still want
your program to keep running, wrap this statement into an eval block:

    my $e = event_new(...);
    eval {
	$e->add;
    } or warn "Adding failed";

Note that timer-based events are not persistent so you have to call this
method/function again in the event-handler in order to re-schedule it.

=item * event_del( $event )

=item * $event-E<gt>del

This removes the timer-event I<$event> from the event-loop. Again, I<$event>
remains intact and may later be re-scheduled with C<event_add>.

=item * event_free( $event )

=item * $event-E<gt>free

The same as its counterpart for filehandle-events, so please see above.

=back

=head2 Signal-based events

Your program can also respond to signals sent to it by other applications. To handle
signals, you create the corresponding event using C<signal_new>.

Note that thusly created events take precedence over event-handlers defined in
C<%SIG>. That means the function you assigned to C<$SIG{ $SIGNAME }> will never be 
executed if a C<Event::Lib>-handler for C<$SIGNAME> also exists.

=over 4

=item * signal_new( $signal, $function, [@args] )

Sets up I<$function> as a handler for I<$signal>. I<$signal> has to be an
integer specifying which signal to intercept and handle. For example, C<15> is
C<SIGTERM> (on most platforms, anyway). You are advised to use the symbolic
names as exported by the POSIX module:

    use Event::Lib;
    use POSIX qw/SIGINT/;

    my $signal = signal_new(SIGINT, sub { print "Someone hit ctrl-c" });
    $signal->add;
    event_mainloop();

As always, I<$function> receives the event object as first argument, the
event-type (always EV_SIGNAL) as second. I<@args> specifies an option list of
values that is to be passed to the handler.

=item * event_add( $event, [$timeout] )

=item * $event-E<gt>add( [$timeout] )

Adds the signal-event previously created with C<signal_new> to the event-loop.
I<$timeout> is an optional argument specifying a timeout given as
floating-point number. It means that the event handler is triggered either when
the event happens or when I<$timeout> seconds have passed, whichever comes
first.

I<$timeout> here has the exact same semantics as with filehandle-based events
described further above.

Note that signal-events are B<always persistent> unless I<$timeout> was given.
That means that you have to delete the event manually if you want it to happen
only once:

    sub sigint {
	my $event = shift;
	print "Someone hit ctrl-c";
	$event->del;
    }
    
    my $signal = signal_new(SIGINT, \&sigint);
    $signal->add;
    event_mainloop();

Subsequently, a persistent and timeouted signal-handler would read thusly:

    sub sigint {
	my $event = shift;
	print "Someone hit ctrl-c";
	$event->add(2.5);
    }

    my $signal = signal_new(SIGINT, \&sigint);
    $signal->add(2.5);
    event_mainloop();

=item * event_del( $event )

=item * $event-E<gt>del

=item * $event-E<gt>free

The same as their counterparts for filehandle-events, so please see above.

=back 

=head2 Common methods

=over 4

=item * $event-E<gt>pending

This will tell you whether I<$event> is still in the event-queue waiting to be
processed.  More specifically, it returns a false value if I<$event> was
already handled (and was not either persistent or re-scheduled). In case
I<$event> is still in the queue it returns the amount of seconds as a
floating-point number until it is triggered again. If I<$event> has no attached
timeout, it returns C<0 but true>.

=item * $event-E<gt>callback

Returns the callback associated with this event as code-reference so that you
can call it manually in case you think you need that:

    $event->callback->($event, $event->fh, @args);

=item * except_handler( $function )

You can associate an exception handler with each event which gets called in
case the callback for that event dies. I<$function> is a Perl code-reference
which will - when called - receive the event as first argument, the error
message with which the event handler died, the type of event and any additional
arguments associated with that event. That way you can inspect the
circumstances and provide your own error-handling.

Please see the next section L<"Exception handling"> for some background and
more details.

=back

=head2 Exception handling

Some programs simply cannot afford to die. It is a possible that a callback is
triggered and finds itself in a situation where it just cannot proceed. Think
of a callback that is supposed to append to a file and in the meantime the disk
has filled so that no space is left on the device.

It is now possible to provide exception handlers for these cases. The idea is
that these exception handlers are called with the same arguments the callback
was previously triggered with (plus the error message as second argument) which
gives you the change to further investigate the cause of the failure and
possibly take counter-measures.

You can register exception handlers per event using the C<except_handler>
method.  Furthermore, you can register one global exception handler that is
going to be used for all events that don't have their own handler:

=over 4

=item * event_register_except_handler( $function )

I<$function> is a code-reference that will be called whenever the callback
of an event dies:

    use Event::Lib;
    
    sub handler {
        my ($event, $exception, $type, @args) = @_;
        # error handling here
        ...
    }

    event_register_except_handler(\&handler);
    ...

If you don't call C<event_register_except_handler> I<Event::Lib> will use its
own basic default handler. This handler simply dies with the original error
message.

=back

=head2 Priorities

Events can be assigned a priority. The lower its assigned priority is, the
earlier this event is processed. Using prioritized events in your programs
requires two steps. The first one is to set the number of available priorities.
Setting those should happen once in your script and before calling
C<event_mainloop>:

=over 4

=item * priority_init( $priorities )

Sets the number of different events to I<$priorities>.

=back

Assigning a priority to each event then happens thusly:

=over 4

=item * $event-E<gt>set_priority( $priority )

Gives I<$event> (which can be any of the three type of events) the priority
I<$priority>. Remember that a lower priority means the event is processed
earlier!

=back

B<Note:> If your installed version of libevent does not yet contain priorities
which happens for pre-1.0 versions, the above will become no-ops. Other than
that, your scripts will remain functional.

=head1 ENTERING THE EVENT-LOOP

I<Event::Lib> offers three functions to process pending events.

=over 4

=item * event_mainloop ()

This function will start the event-loop and never return.  More precisely, it
will return only if there was an error. 

B<IMPORTANT>: When any of your events register new events they will be added to
the global queue of events and be handled in the same loop. You are therefore
not allowed to call C<event_mainloop> more than once in your program.
Attempting to do so will yield a warning and the operation is silently turned
into a no-op.

=item * event_one_loop( [$timeout] )

This function will do exactly one loop which means the next pending event is
handled. In case no event is currently ready for processing, it will block and wait
until one becomes processible.

If I<$timeout> is specified, it will wait at most I<$timeout> seconds and then
return.

=item * event_one_nbloop ()

This is the I<n>on-I<b>locking counterpart to C<event_one_loop>: It returns
immediately when no event is ready to be processed. Otherwise the next imminent
event is handled.

=back

You want to use either C<event_one_loop> or C<event_one_nbloop> instead of
C<event_mainloop> if you want to write your own event-loop. The core of such a
program could look like this:

    event_new(...)->add;
    event_new(...)->add;
    timer_new(...)->add;
    ...
    
    while () {
	event_one_nbloop();
	...
	select undef, undef, undef, 0.05;   # sleep for 0.05 seconds
    }

=head1 DEBUGGING, TRACING ET AL.
    
=head2 Seeing libevent trace messages

You can specify what kind of messages Event::Lib should dump to stderr by using
the following function:

=over

=item * event_log_level ( $loglevel )

I<$loglevel> is one of _EVENT_LOG_DEBUG, _EVENT_LOG_MSG, _EVENT_LOG_WARN,
_EVENT_LOG_ERR and _EVENT_LOG_NONE and will instruct I<Event::Lib> to only
output messages of at least that severity. C<_EVENT_LOG_NONE> will suppress any
messages. Not calling this function is equivalent to

    event_log_level( _EVENT_LOG_ERR );

=back

=head1 CONFIGURATION

I<Event::Lib> can be told which kernel notification method B<not> to use. This
happens via the use of environment variables (there is no other way due to
libevent). They have to be set in a BEGIN-block before you C<use>
I<Event::Lib>:

    BEGIN {
	$ENV{ $_ } = 1 for qw/EVENT_NOPOLL EVENT_NOEPOLL/;
    }

    use Event::Lib;

This will disable C<poll> and C<epoll> so it will use one of the remaining
methods, which could be either C<select>, C<devpoll> or C<kqueue>. 

The variables that you may set are the following:

=over 4

=item * EVENT_NOPOLL

=item * EVENT_NOSELECT

=item * EVENT_NOEPOLL

=item * EVENT_NODEVPOLL

=item * EVENT_NOKQUEUE

=back

If you set all of the above variables, it is a fatal error and you'll receive
the message C<event_init: no event mechanism available>. There is one other
variable available:

=over 4

=item * EVENT_SHOW_METHOD

This will make I<Event::Lib> emit a short message at C<use>-time telling 
you which of the available kernel notification methods it uses. This variable
may be bundled with one of the C<EVENT_NO*> variables.

=back

=head1 EXAMPLE: A SIMPLE TCP SERVER

Here's a reasonably complete example how to use this library to create a simple
TCP server serving many clients at once. It makes use of all three kinds of events:

    use POSIX qw/SIGHUP/;
    use IO::Socket::INET;
    use Event::Lib;

    $| = 1;

    # Invoked when a new client connects to us
    sub handle_incoming {
	my $e = shift;
	my $h = $e->fh;
	
	my $client = $h->accept or die "Should not happen";
	$client->blocking(0);

	# set up a new event that watches the client socket
	my $event = event_new($client, EV_READ|EV_PERSIST, \&handle_client);
	$event->add;
    }

    # Invoked when the client's socket becomes readable
    sub handle_client {
	my $e = shift;
	my $h = $e->fh;
	printf "Handling %s:%s\n", $h->peerhost, $h->peerport;
	while (<$h>) {
	    print "\t$_";
	    if (/^quit$/) {
		# this client says goodbye
		close $h;
		$e->free;
		last;
	    }
	}
    }	
	
    # This just prints the number of
    # seconds elapsed
    my $secs;
    sub show_time {
	my $e = shift;
	print "\r", $secs++;
	$e->add;
    }

    # Do something when receiving SIGHUP
    sub sighup {
	my $e = shift;
	# a common thing to do would be
	# re-reading a config-file or so
	...
    }

    # Create a listening socket
    my $server = IO::Socket::INET->new(
	LocalAddr   => 'localhost',
	LocalPort   => 9000,
	Proto	    => 'tcp',
	ReuseAddr   => SO_REUSEADDR,
	Listen	    => 1,
	Blocking    => 0,
    ) or die $!;

    my $main  = event_new($server, EV_READ|EV_PERSIST, \&handle_incoming);
    my $timer = timer_new(\&show_time);
    my $hup   = signal_new(SIGHUP, \&sighup);
   
    $_->add for $main, $timer, $hup;

    event_mainloop;

    __END__
    
You can test the above server with this little program of which you can start
a few several simultaneous instances:

    use IO::Socket::INET;

    my $server = IO::Socket::INET->new( 
	Proto	    => 'tcp',
	PeerAddr    => 'localhost',
	PeerPort    => 9000,
    );

    print $server "HI!\n";
    sleep 10;
    print $server "quit\n";

    __END__
   
=head1 OTHER EVENT MODULES

There are already a handful of similar modules on the CPAN. The two most prominent
ones are I<Event> and the venerable I<POE> framework.

=head2 Event

In its functionality it's quite close to I<Event::Lib> with some additional
features not present in this module (you can watch variables, for example).
Interface-wise, it's quite a bit heavier while I<Event::Lib> gets away with
just a handful of functions and methods. On the other hand, it has been around
for years and so you may expect I<Event> to be rock-stable.

The one main advantage of I<Event::Lib> appears to be in its innards. The
underlying I<libevent> is capable of employing not just the C<poll> and
C<select> notification mechanisms but also other and possibly better performing
ones such as C<kqueue>, C<devpoll> and C<epoll> where available.

=head2 POE

POE is definitely more than the above. It's really a threading environment in
disguise. Purely event-based techniques have limitations, most notably that an
event-handler blocks all other pending events until it is done with its work.
It's therefore not possible to write a parallel link-checker only with L<Event>
or L<Event::Lib>. You still need threads or C<fork(2)> for that.

That's where POE enters the scene. It is truely capable of running jobs in
parallel. Such jobs are usually encapsulated in C<POE::Component> objects of
which already quite a few premade ones exist on the CPAN.

This power comes at a price. I<POE> has a somewhat steep learning-curve and forces
you to think in POE concepts. For medium- and large-sized applications, this doesn't
have to be a bad thing. Once grokked, it's easy to add more components to your
project, so it's almost infinitely extensible.

=head2 Conclusion

Use the right tools for your job. I<Event::Lib> and I<Event> are good for writing
servers that serve many clients at once, or in general: Anything that requires you
to watch resources and do some work when something interesting happens with those
resources. Once the work needed to be carried out per event gets too complex, you 
may still use C<fork>.

Or you use I<POE>. You get the watching and notifying capabilities alright, but
also the power to do things in parallel without creating threads or child
processes manually.

=head1 EXPORT

This modules exports by default the following functions:
    
    event_init
    event_log_level
    priority_init
    event_register_except_handler
    
    event_new
    timer_new
    signal_new

    event_add
    event_del
    event_free
    event_mainloop
    event_one_loop
    event_one_nbloop

plus the following constants:

    EV_PERSIST
    EV_READ
    EV_SIGNAL
    EV_TIMEOUT
    EV_WRITE
    _EVENT_LOG_DEBUG
    _EVENT_LOG_MSG
    _EVENT_LOG_WARN
    _EVENT_LOG_ERR
    _EVENT_LOG_NONE
    EVENT_FREE_NOWARN

=head1 BUGS

This is a beta-release therefore there are still some unresolved issues.
However, even then it should be more stable than the previous 0.10 release.

This library is not thread-safe.

=head1 TO-DO

Not all of libevent's public interface is implemented. The buffered events are still
missing. They will be added once I grok what they are for.

Neither did I yet look into libevent's experimental thread-support. Once the
"experimental" flag is removed, I might do that.

=head1 SEE ALSO

libevent's home can be found at L<http://www.monkey.org/~provos/libevent/>. It
contains further references to event-based techniques.

Also the manpage of event(3). 

=head1 VERSION

This is beta-version 0.99_10.

=head1 AUTHOR

Tassilo von Parseval, E<lt>tassilo.von.parseval@rwth-aachen.deE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2004-2005 by Tassilo von Parseval

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.4 or,
at your option, any later version of Perl 5 you may have available.

=cut
