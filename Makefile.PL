use 5.006;
use ExtUtils::MakeMaker;
use Config;

my %args = map { split /\s*=\s*/ } @ARGV;

sub have_libevent {
    my $CC = $Config{cc}.' '.$Config{ccflags}.' ';
    my $LIBS = $args{ LIBS } || "-levent";
    my $INC = $args{ INC } || "-I/usr/include";
    if ($^O eq "freebsd") {
      $LIBS = "-L/usr/local/lib $LIBS";
      $INC  = "-I/usr/local/include $INC";
    }
    elsif ($^O eq "darwin") {
      $LIBS = "-L/sw/lib $LIBS";
      $INC  = "-I/sw/include $INC";
    }
    return 1 if system("$CC check.c $INC $LIBS") == 0;
    return 0;
}

if (! have_libevent()) {
    die <<EOD;
*******************************************
Couldn't find libevent which is required 
for this module.

To obtain it, go to
    http://www.monkey.org/~provos/libevent/
*******************************************
EOD
}

$args{LIBS} = '-levent -lm' if ! exists $args{LIBS};

WriteMakefile(
    NAME            => 'Event::Lib',
    VERSION_FROM    => 'lib/Event/Lib.pm', 
    PREREQ_PM       => {}, 
    ABSTRACT_FROM   => 'lib/Event/Lib.pm', 
    AUTHOR	    => 'Tassilo von Parseval <tassilo.von.parseval@rwth-aachen.de>',
    LIBS            => [ $args{LIBS} ], 
    DEFINE          => '-DHAVE_CONFIG_H', 
    INC             => $args{INC} ,
    clean	    => { FILES => "a.out" },
);

if  (eval {require ExtUtils::Constant; 1}) {
  # If you edit these definitions to change the constants used by this module,
  # you will need to use the generated const-c.inc and const-xs.inc
  # files to replace their "fallback" counterparts before distributing your
  # changes.
  my @names = (qw(EVBUFFER_EOF EVBUFFER_ERROR EVBUFFER_READ EVBUFFER_TIMEOUT
		 EVBUFFER_WRITE EVLIST_ACTIVE EVLIST_ALL EVLIST_INIT
		 EVLIST_INSERTED EVLIST_INTERNAL EVLIST_SIGNAL EVLIST_TIMEOUT
		 EVLOOP_NONBLOCK EVLOOP_ONCE EV_PERSIST EV_READ EV_SIGNAL
		 EV_TIMEOUT EV_WRITE));
  ExtUtils::Constant::WriteConstants(
                                     NAME         => 'Event::Lib',
                                     NAMES        => \@names,
                                     DEFAULT_TYPE => 'IV',
                                     C_FILE       => 'const-c.inc',
                                     XS_FILE      => 'const-xs.inc',
                                  );

}
else {
  use File::Copy;
  use File::Spec;
  foreach my $file ('const-c.inc', 'const-xs.inc') {
    my $fallback = File::Spec->catfile('fallback', $file);
    copy ($fallback, $file) or die "Can't copy $fallback to $file: $!";
  }
}
