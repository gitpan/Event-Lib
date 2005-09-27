package Event::Lib;

use 5.006;
use strict;
use warnings;
use Carp;

require Exporter;
require XSLoader;

our @ISA = qw(Exporter);
our $VERSION = '0.09';

sub import {
    my ($class) = shift;
    my @save = @_;
    local *_;

    while (defined($_ = shift @save)) {
	$ENV{ EVENT_NOPOLL }	    = 1, next	if $_ eq 'no_poll';
	$ENV{ EVENT_NOSELECT }	    = 1, next	if $_ eq 'no_select';
	$ENV{ EVENT_NOEPOLL }	    = 1, next	if $_ eq 'no_epoll';
	$ENV{ EVENT_NODEVPOLL }	    = 1, next	if $_ eq 'no_devpoll';
	$ENV{ EVENT_NOKQUEUE }	    = 1, next	if $_ eq 'no_kqueue';
	$ENV{ EVENT_SHOW_METHOD }   = 1, next	if $_ eq 'show_method';
	push @_, $_;
    }

    # We have to load the dynamic portion here
    # because otherwise event_init(), which happens
    # in a BOOT-section, runs before we have set 
    # %ENV accordingly
    XSLoader::load('Event::Lib', $VERSION);

    # otherwise Exporter exports into this and not the caller's package
    local $Exporter::ExportLevel = 1;
    
    $class->SUPER::import(@_);
}

@Event::Lib::event::ISA = @Event::Lib::signal::ISA = @Event::Lib::timer::ISA = qw/Event::Lib::base/;

# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.

# This allows declaration	use Event::Lib ':all';
# If you do not need this, moving things directly into @EXPORT or @EXPORT_OK
# will save memory.
our %EXPORT_TAGS = ( 'all' => [ qw(
	event_init
	event_dispatch
	event_new
	event_add
	event_del
	event_once
	priority_init
	signal_new
	signal_add
	signal_del
	timer_new
	timer_add
	timer_del
	bufferevent_new
	EVBUFFER_EOF
	EVBUFFER_ERROR
	EVBUFFER_READ
	EVBUFFER_TIMEOUT
	EVBUFFER_WRITE
	EVLIST_ACTIVE
	EVLIST_ALL
	EVLIST_INIT
	EVLIST_INSERTED
	EVLIST_INTERNAL
	EVLIST_SIGNAL
	EVLIST_TIMEOUT
	EVLOOP_NONBLOCK
	EVLOOP_ONCE
	EV_PERSIST
	EV_READ
	EV_SIGNAL
	EV_TIMEOUT
	EV_WRITE
) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(
    event_init
    event_dispatch
    
    event_new
    event_add
    event_del
    event_once
    
    signal_new
    signal_add
    signal_del
   
    priority_init

    timer_new
    timer_add
    timer_del

    EVBUFFER_EOF
    EVBUFFER_ERROR
    EVBUFFER_READ
    EVBUFFER_TIMEOUT
    EVBUFFER_WRITE
    EVLIST_ACTIVE
    EVLIST_ALL
    EVLIST_INIT
    EVLIST_INSERTED
    EVLIST_INTERNAL
    EVLIST_SIGNAL
    EVLIST_TIMEOUT
    EVLOOP_NONBLOCK
    EVLOOP_ONCE
    EV_PERSIST
    EV_READ
    EV_SIGNAL
    EV_TIMEOUT
    EV_WRITE

);


sub AUTOLOAD {
    # This AUTOLOAD is used to 'autoload' constants from the constant()
    # XS function.

    my $constname;
    our $AUTOLOAD;
    ($constname = $AUTOLOAD) =~ s/.*:://;
    croak "&Event::Lib::constant not defined" if $constname eq 'constant';
    my ($error, $val) = constant($constname);
    if ($error) { croak $error; }
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
    
    event_dispatch();

=head1 DESCRIPTION

This module is a Perl wrapper around libevent(3) as available from
L<http://www.monkey.org/~provos/libevent/>.  It allows to execute a function
whenever a given event on a filehandle happens, a timeout occurs or a signal is
received.

Under the hood, one of the available mechanisms for asynchronously dealing with
events is used. This could be C<select>, C<poll>, C<epoll>, C<devpoll> or
C<kqeue>. The idea is that you don't have to worry about those details and the
various interfaces they offer. I<Event::Lib> offers a unified interface  to all
of them (but see L<"CONFIGURATION"> further below).

Once you've skimmed through the next two sections (or maybe even now), you
should have a look at L<"EXAMPLE: A SIMPLE TCP SERVER"> to get a feeling about
how it all fits together.

There's also a section briefly mentioning other event modules on the CPAN
and how they differ from I<Event::Lib> further below (L<"OTHER EVENT MODULES">).

=head1 INITIALIZATION

Most of the time you don't have to do anything other than

    use Event::Lib;

However, when you spawn off new processes with C<fork> and you intend to
register and schedule events inside those child processes, you must call
C<event_init> in the spawned processes before you do anything event-related:

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

The reason for that is that the kqueue(2) mechanism doesn't inherit its queue
handles to its children.

=head1 EVENTS

The standard procedure is to create a few events and afterwards enter a loop
(using C<event_dispatch>) to wait for and handle the pending events. 

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

    event_dispatch();

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
    event_dispatch();

=item * event_add( $event, [$timeout] )

=item * $event->add( [$timeout] )

This adds the event previously created with C<event_new> to the event-loop.
I<$timeout> is an optional argument specifying a timeout given as
floating-point number. It means that the event handler is triggered either when
the event happens or when I<$timeout> seconds have passed, whichever comes
first.

=item * $event->fh

Returns the filehandle this I<$event> is supposed to watch. You will usually call
this in the event-handler.

=item * event_del( $event )

=item * $event->del

This removes an event object from the event-loop. Note that the object itself is not
destroyed and freed. It is merely disabled and you can later re-enable it by calling
C<< $event->add >>.

=item * event_free( $event )

=item * $event->free

This destroys I<$event> and frees all memory associated with it. After calling this
function/method, I<$event> is no longer an object and hence no longer usable.

It will also remove the event from the event-loop if it is still in the event-queue.
It is ok to use this function after an event has been deleted with C<event_delete>.
    
=back

=head2 Timer-based events

Sometimes you want events to happen periodically, irregardless of any filehandles.
Such events are created with C<timer_new>:

=over 4

=item * timer_new( $function, [@args] )

This is very much the same as C<event_new>, only that it lacks its first two
parameters.  I<$function> is a reference to a Perl function that should be
executed. As always, this function will receive the event object as returned by
C<timer_new> as first argument, the type of event (always EV_TIMEOUT) plus the
optional argumentlist I<@args>.

=item * event_add( $event, [$timeout] )

=item * $event->add( [$timeout] )

Adds I<$event> to the event-loop. The event is scheduled to be triggered every
I<$timeout> seconds where I<$timeout> can be any floating-point value. If
I<$timeout> is omitted, a value of one second is assumed.

Note that timer-based events are not persistent so you have to call this method/function
again in the event-handler in order to re-schedule it.

=item * event_del( $event )

=item * $event->del

This removes the timer-event I<$event> from the event-loop. Again, I<$event> remains intact
and may later be re-scheduled with C<event_add>.

=item * event_free( $event )

=item * $event->free

This removes I<$event> from the event-loop and frees any memory associated with
it. I<$event> will no longer be usable after calling this method/function.

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
integer specifying which signal to intercept and handle. For example, C<15>
is C<SIGTERM> (on most platforms, anyway). You are advised to use the symbolic names
as exported by the POSIX module:

    use Event::Lib;
    use POSIX;

    my $signal = signal_new(SIGINT, sub { print "Someone hit ctrl-c" });
    $signal->add;
    event_dispatch();

As always, I<$function> receives the event object as first argument, the
event-type (always EV_SIGNAL) as second. I<@args> specifies an option list of
values that is to be passed to the handler.

=item * event_add( $event, [$timeout] )

=item * $event->add( [$timeout] )

Adds the signal-event previously created with C<signal_new> to the event-loop.
I<$timeout> is an optional argument specifying a timeout given as
floating-point number. It means that the event handler is triggered either when
the event happens or when I<$timeout> seconds have passed, whichever comes
first.

Note that signal-events are B<always persistent> unless I<$timeout> was given.
That means that you have to delete the event manually if you want it to happen
only once:

    sub sigint {
	my $event = shift;
	print "Someone hit ctrl-c";
	$event->free;	# or maybe: $event->del
    }
    
    my $signal = signal_new(SIGINT, \&sigint);
    $signal->add;
    event_dispatch();

Subsequently, a persistent and timeouted signal-handler would read thusly:

    sub sigint {
	my $event = shift;
	print "Someone hit ctrl-c";
	$event->add(2.5);
    }

    my $signal = signal_new(SIGINT, \&sigint);
    $signal->add(2.5);
    event_dispatch();

=item * event_del( $event )

=item * $event->del

=item * $event->free

These do the same as their counterparts for filehandle- and timer-events (see above).

=back 

=head2 Priorities

Events can be assigned a priority. The lower its assigned priority is, the earlier this
event is processed. Using prioritized events in your programs requires two
steps. The first one is to set the number of available priorities. Setting
those should happen once in your script and before any events are dispatched:

=over 4

=item * priority_init( $priorities )

Sets the number of different events to I<$priorities>.

=back

Assigning a priority to each event then happens thusly:

=over 4

=item * $event->set_priority( $priority )

Gives I<$event> (which can be any of the three type of events) the priority
I<$priority>. Remember that a lower priority means the event is processed
earlier!

=back

B<Note:> If your installed version of libevent does not yet contain priorities
which happens for pre-1.0 versions, the above will become no-ops. Other than that,
your scripts will remain functional.

=head2 Common methods

There's one methode that behaves identically for each type of event:

=over 4

=item * $event->pending

This will tell you whether I<$event> is still in the event-queue waiting to be
processed.  More specifically, it returns a false value if I<$event> was
already handled (and was not either persistent or re-scheduled). In case
I<$event> is still in the queue it returns the amount of seconds as a
floating-point number until it is triggered again. If I<$event> has no attached
timeout, it returns C<0 but true>.

=back

=head1 ENTERING THE EVENT-LOOP

I<Event::Lib> offers exactly one function that is used to start the main-loop:

=over 4

=item * event_dispatch( [$flags], [$timeout] )

When called with no arguments at all, this will start the event-loop and never
return.  More precisely, it will return only if there was an error. 

I<$flags> may be one of C<EVLOOP_ONCE> and C<EVLOOP_NONBLOCK>. C<EVLOOP_ONCE> will
make your program enter the main-loop and block until an event happens. In this case,
the associated event-handler is called and the function returns.

C<EVLOOP_NONBLOCK> is just like C<EVLOOP_ONCE> only that it wont block, that is: It will
return immediately if no events are pending.

If I<$timeout> is given, the I<$flags> argument is ignored. Instead, your
program will enter the main-loop and block for I<$timeout> seconds, handling
any events occuring during that time. After the I<$timeout> seconds have
passed, it will return.

C<event_dispatch> can also be invoked as the C<dispatch> method on any event
that you previously created. It will however always affect the whole program.

=back

=head1 CONFIGURATION

I<Event::Lib> can be told which kernel notification method B<not> to use:

    use Event::Lib qw/no_devpoll no_poll/;

This disables C<devpoll> and C<poll> so it will use one of the remaining
methods, which could be either C<select>, C<epoll> or C<kqueue>. If you disable
all of the available methods, it is a fatal error and you'll receive the
message C<event_init: no event mechanism available>. The available import flags
are C<no_poll>, C<no_select>, C<no_epoll>, C<no_devpoll> and C<no_kqueue>.

If you want to find out which method I<Event::Lib> internally uses, you can do

    use Event::Lib qw/show_method/;

and it will emit something like C<libevent using: poll> or so. 

=head1 EXAMPLE: A SIMPLE TCP SERVER

Here's a reasonably complete example how to use this library to create a simple
TCP server serving many clients at once. It makes use of all three kinds of events:

    use POSIX;
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

    $main->dispatch;

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
Furthermore, you can assign priorities to your events. Interface-wise, it's
quite a bit heavier while I<Event::Lib> gets away with just a handful of
functions and methods.

The one main advantage of I<Event::Lib> appears to be in its innards. The
underlying I<libevent> is capable of employing not just the C<poll> and
C<select> notification mechanisms but also other and possibly better performing
ones such as C<kqeue>, C<devpoll> and C<epoll> where available.

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
    priority_init
    event_new
    timer_new
    signal_new
    event_add
    event_del
    event_dispatch

plus the following constants:

    EVBUFFER_EOF
    EVBUFFER_ERROR
    EVBUFFER_READ
    EVBUFFER_TIMEOUT
    EVBUFFER_WRITE
    EVLIST_ACTIVE
    EVLIST_ALL
    EVLIST_INIT
    EVLIST_INSERTED
    EVLIST_INTERNAL
    EVLIST_SIGNAL
    EVLIST_TIMEOUT
    EVLOOP_NONBLOCK
    EVLOOP_ONCE
    EV_PERSIST
    EV_READ
    EV_SIGNAL
    EV_TIMEOUT
    EV_WRITE

=head1 BUGS

Maybe.

This library is almost certainly not thread-safe.

You must include the module either via C<use> or C<require> after which you
call C<import>. Merely doing 

    require Event::Lib;

doesn't work because this module has to load its dynamic portion in the
C<import> method. So if you need to include it at runtine, this will work:

    require Event::Lib;
    Event::Lib->import;

=head1 TO-DO

Not all of libevent's public interface is implemented. The buffered events are still
missing. They will be added once I grok what they are for.

Same is true for the two mysterious static variables C<event_sigcb> and
C<event_gotsig>.

Neither did I yet look into libevent's experimental thread-support. Once the
"experimental" flag is removed, I might do that.

=head1 SEE ALSO

libevent's home can be found at L<http://www.monkey.org/~provos/libevent/>. It
contains further references to event-based techniques.

Also the manpage of event(3). Note however that I<Event::Lib> functions do not
always call their apparent libevent-counterparts. For instance,
C<Event::Lib::event_dispatch> is actually using a combination of C<int
event_loop(...)> and C<int event_loopexit(...)> to do its work.

=head1 VERSION

This is version 0.09.

=head1 AUTHOR

Tassilo von Parseval, E<lt>tassilo.von.parseval@rwth-aachen.deE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2004-2005 by Tassilo von Parseval

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.4 or,
at your option, any later version of Perl 5 you may have available.


=cut
