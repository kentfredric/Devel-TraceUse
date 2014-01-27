package # hide package name from indexer
  DB;

# allow -d:TraceUse loading with this little C++-style no-op
sub DB {}

package Devel::TraceUse;

our $VERSION = '2.09';

BEGIN
{
    unshift @INC, \&trace_use unless grep { "$_" eq \&trace_use . '' } @INC;
}

# initialize the tree of require calls
my $root = (caller)[1];
my %used;        # track loaded modules by "filename" (parameter to require)
my %loaded;      # track "filename"s loaded  by "filepath" (value from %INC)
my %reported;    # track reported "filename"
my %loader;      # track potential proxy modules
my $rank  = 0;   # record the loading order of modules
my $quiet = 1;   # no output until decided otherwise
my $output_fh;   # optional write filehandle where results will be output

# Hide core modules (for the specified version)?
my $hide_core = 0;

sub import {
    my $class = shift;

    # ensure "use Devel::TraceUse ();" will produce no output
    $quiet = 0;

    # process options
    for(@_) {
        if(/^hidecore(?::(.*))?/) {
            $hide_core = numify( $1 ? $1 : $] );
        } elsif (/^output:(.*)$/) {
            open $output_fh, '>', $1 or die "can't open $1: $!";
        } else {
            die "Unknown argument to $class: $_\n";
        }
    }
}

my $times = {};

# The following code only functions under perl -d
# and hooks into the `require` mechanism and triggers between
# the sourced file being compiled, and the source file being run.
#
# So this encompasses `use` and `BEGIN` penalties
# but no runtime penalities.

{
    # Default code ref
    my $postponed = sub {};
    # Take original one if one is defined
    if ( 'DB'->can('postponed') ) {
        $postponed = 'DB'->can('postponed');
    }
    *DB::postponed = sub {
        # Call any existing hooks
        $postponed->(@_);
        # see perldebguts
        # $_[0] here is "*main::_<FILENAME>"
        # or "subname" if subnames are registered for postponed triggers.
        my $filename = $_[0];
        return unless $filename =~ s/^\*main::_<//;
        # Invoke Time::HiRes if and only if it is loaded.
        my $after = scalar time();
        if ('Time::HiRes'->can('gettimeofday') ) {
           $after = scalar  Time::HiRes::gettimeofday();
        }
        my $orig = $filename;
        # Try to map the final required filename
        # back to the filename that was passed to `require`
        # by iterating %INC, which contains
        #  Foo/Bar.pm => /full/path/here/Foo/Bar.pm
        # mappings and we want the left hand side.
        keyfind: for my $key ( keys %INC  ) {
            if ( $filename eq $INC{$key} ) {
                $orig = $key;
                last keyfind;
            }
        }
        if ( exists $times->{$orig} ) {
            my $t = $times->{$orig};
            $t->{finished} = $after;
            $t->{time}   = $t->{finished} - $t->{loaded};
        }
    };
}

my @caller_info = qw( package filepath line subroutine hasargs
    wantarray evaltext is_require hints bitmask hinthash );

# Keys used in the data structure:
# - filename: parameter given to use/require
# - module:   module, computed from filename
# - rank:     rank of loading
# - eval:     was this use/require done in an eval?
# - loaded:   list of files loaded from this one
# - filepath: file that was actually loaded from disk (obtained from %INC)
# - caller:   information on the caller (same keys + everything from caller())

sub trace_use
{
    my ( $code, $filename ) = @_;

    # ensure our hook remains first in @INC
    @INC = ( $code, grep { $_ ne $code } @INC )
        if $INC[0] ne $code;

    # $filename may be an actual filename, e.g. with do()
    # try to compute a module name from it
    my $module = $filename;
    $module =~ s{/}{::}g
        if $module =~ s/\.pm$//;

    # info about the module being loaded
    push @{ $used{$filename} }, my $info = {
        filename => $filename,
        module   => $module,
        rank     => ++$rank,
        eval     => '',
    };

    # info about the loading module
    my $caller = $info->{caller} = {};
    @{$caller}{@caller_info} = caller(0);

    # try to compute a "filename" (as received by require)
    $caller->{filestring} = $caller->{filename} = $caller->{filepath};

    # some values seen in the wild:
    # - "(eval $num)[$path:$line]" (debugger)
    # - "$filename (autosplit into $path)" (AutoLoader)
    if ( $caller->{filename} =~ /^(\(eval \d+\))(?:\[(.*):(\d+)\])?$/ ) {
        $info->{eval}       = $1;
        $caller->{filename} = $caller->{filepath} = $2;
        $caller->{line}     = $3;
    }

    # clean up path
    $caller->{filename}
        =~ s!^(?:@{[ join '|', map quotemeta, reverse sort @INC ]})/?!!;

    # try to compute the package associated with the file
    $caller->{filepackage} = $caller->{filename};
    $caller->{filepackage} =~ s/\.(pm|al)\s.*$/.$1/;
    $caller->{filepackage} =~ s{/}{::}g
        if $caller->{filepackage} =~ s/\.pm$//;

    # record who tried to load us
    push @{ $loaded{ $caller->{filepath} } }, $info->{filename};

    # record potential proxies
    if ( $caller->{filename} ) {
        my($subroutine, $level);
        while ( $subroutine = ( caller ++$level )[3] || '' ) {
            last if $subroutine =~ /::/;
        }
        $loader{ join "\0", @{$caller}{qw( filename line )}, $subroutine }++;
    }

    my $now = scalar time();
    # Optimistically ask for extra precision when the mechanics exist
    # already
    if ('Time::HiRes'->can('gettimeofday') ) {
        $now = scalar Time::HiRes::gettimeofday();
    }
    $times->{$info->{filename}} = {
        loaded => $now
    };

    # let Perl ultimately find the required file
    return;
}

sub show_trace_visitor
{
    my ( $mod, $pos, $output_cb, @args ) = @_;

    my $caller = $mod->{caller};
    my $message = sprintf( '%4s.', $mod->{rank} ) . '  ' x $pos;
    $message .= "$mod->{module}";
    my $version = ${"$mod->{module}\::VERSION"};
    $message .= defined $version ? " $version," : ',';
    $message .= " $caller->{filename}"
        if defined $caller->{filename};
    $message .= " line $caller->{line}"
        if defined $caller->{line};
    $message .= " $mod->{eval}"
        if $mod->{eval};
    $message .= " [$caller->{package}]"
        if $caller->{package} ne $caller->{filepackage};
    $message .= " (FAILED)"
        if !exists $INC{$mod->{filename}};

    if ( exists $times->{$mod->{filename}} ) {
        my $t = $times->{$mod->{filename}};
        if ( $t->{time} > 0 ) {
            $message .= sprintf " \e[35m%8.3fms\e[0m" , $t->{time} * 1000;
        }
    }

    $output_cb->($message, @args);
}

sub visit_trace
{
    my ( $visitor, $mod, $pos, @args ) = @_;

    my $hide = 0;

    if ( ref $mod ) {
        $mod = shift @$mod;

        if($hide_core) {
            $hide = exists $Module::CoreList::version{$hide_core}{$mod->{module}};
        }

        $visitor->( $mod, $pos, @args ) unless $hide;

        $reported{$mod->{filename}}++;
    }
    else {
        $mod = { loaded => delete $loaded{$mod} };
    }

    visit_trace( $visitor, $used{$_}, $hide ? $pos : $pos + 1, @args )
        for map { $INC{$_} || $_ } @{ $mod->{loaded} };
}

# we don't want to use version.pm on old Perls
sub numify {
    my ($version) = @_;
    $version =~ y/_//d;
    my @parts = split /\./, $version;

    # %Module::CoreList::version's keys are x.yyyzzz *numbers*
    return 0+ join '', shift @parts, '.', map sprintf( '%03s', $_ ), @parts;
}

sub dump_hot_modules {
    my ( $output ) = @_;
    my ( @hot_modules ) = sort { $times->{$b}->{time} <=> $times->{$a}->{time} }
        grep { $times->{$_}->{time} > 0 }
        keys %{$times};
    return unless @hot_modules;
    $output->("Slowest Modules (inclusive):");
    my $i = 0;
    for my $module ( @hot_modules ){
        $i++;
        last if $i > 20;
        $output->(sprintf "%8.3fms %s", $times->{$module}->{time} * 1000 , $module );
    }
}
sub dump_proxies
{
    my $output = shift;

    my @hot_loaders =
        sort { $loader{$b} <=> $loader{$a} }
        grep { $loader{$_} > 1 }
        keys %loader;

    return unless @hot_loaders;

    $output->("Possible proxies:");

    for my $loader (@hot_loaders) {
        my ( $filename, $line, $subroutine ) = split /\0/, $loader;
        $output->(sprintf("%4d %s line %d%s",
                $loader{$loader},
                $filename, $line,
                    (defined($subroutine) ? ", sub $subroutine" : '')));
    }
}

sub dump_result
{
    return if $quiet;

    # map "filename" to "filepath" for everything that was loaded
    while ( my ( $filename, $filepath ) = each %INC ) {
        if ( exists $used{$filename} ) {
            $used{$filename}[0]{loaded} = delete $loaded{$filepath} || [];
            $used{$filepath} = delete $used{$filename};
        }
    }

    # let people know more accurate information is available
    warn "Use -d:TraceUse for more accurate information.\n" if !$^P;

    # load Module::CoreList if needed
    if ($hide_core) {
        local @INC = grep { $_ ne \&trace_use } @INC;
        local %INC = %INC;    # don't report it loaded
        require Module::CoreList;
        warn sprintf "Module::CoreList %s doesn't know about Perl %s\n",
            $Module::CoreList::VERSION, $hide_core
            if !exists $Module::CoreList::version{$hide_core};
    }

    my $output = defined $output_fh
           ? sub { print $output_fh "$_[0]\n" }
           : sub { warn "$_[0]\n" };

    # output the diagnostic
    $output->("Modules used from $root:");
    visit_trace( \&show_trace_visitor, $root, 0, $output );

    # anything left?
    if (%loaded) {
        visit_trace( \&show_trace_visitor, $_, 0, $output ) for sort keys %loaded;
    }

    # did we miss some modules?
    if (my @missed
        = sort grep { !exists $reported{$_} && $_ ne 'Devel/TraceUse.pm' }
        keys %INC
        )
    {
        $output->("Modules used, but not reported:") if @missed;
        $output->("  $_") for @missed;
    }

    dump_proxies($output);
    dump_hot_modules($output);
    close $output_fh if defined $output_fh;
}

# Install the final hook
# If perl runs with -c we want to dump
CHECK {
    # "perl -c" ?
    dump_result() if $^C;
}

END { dump_result() }

1;
__END__

=encoding iso-8859-1

=head1 NAME

Devel::TraceUse - show the modules your program loads, recursively

=head1 SYNOPSIS

An apparently simple program may load a lot of modules.  That's useful, but
sometimes you may wonder exactly which part of your program loads which module.

C<Devel::TraceUse> can analyze a program to see which part used which module.
I recommend using it from the command line:

  $ perl -d:TraceUse your_program.pl

This will display a tree of the modules ultimately used to run your program.
(It also runs your program with only a little startup cost all the way through
to the end.)

  Modules used from your_program.pl:
     1.  strict 1.04, your_program.pl line 1 [main]
     2.  warnings 1.06, your_program.pl line 2 [main]
     3.  Getopt::Long 2.37, your_program.pl line 3 [main]
     4.    vars 1.01, Getopt/Long.pm line 37
     5.      warnings::register 1.01, vars.pm line 7
     6.    Exporter 5.62, Getopt/Long.pm line 43
     9.      Exporter::Heavy 5.62, Exporter.pm line 18
     7.    constant 1.13, Getopt/Long.pm line 226
     8.    overload 1.06, Getopt/Long.pm line 1487 [Getopt::Long::CallBack]

The load order is listed on the first column. The version is displayed
after the module name, if available. The calling package is
shown between square brackets if different from the package that can
be inferred from the file name. Extra information is also provided
if the module was loaded from within and C<eval>.

C<Devel::TraceUse> will also report modules that failed to be loaded,
under the modules that tried to load them.

In the very rare case when C<Devel::TraceUse> is not able to attach
a loaded module to the tree, it will be reported at the end.

If a particular line of code is used at least 2 times to load modules,
it is considered as part of a "module loading proxy subroutine", or just "proxy".
C<L<base>::import>, C<L<parent>::import>,
C<L<Module::Runtime>::require_module> are such subroutines, among others.
If proxies are found, the list is reported like this:

     <occurences> <filename> line <line>[, sub <subname>]

Example:

    Possible proxies:
      59 Module/Runtime.pm, line 317, sub require_module
      13 base.pm line 90, sub import
       3 Module/Pluggable/Object.pm line 311, sub _require

Even though using C<-MDevel::TraceUse> is possible, it is preferable to
use C<-d:TraceUse>, as the debugger will provide more accurate information.
You will be reminded in the output.

If you want to know only the modules loaded during the compile phase, use
the standard C<-c> option of perl (see L<perlrun>):

  $ perl -c -d:TraceUse your_program.pl

=head2 Parameters

You can hide the core modules that your program used by providing parameters
at C<use> time:

  $ perl -d:TraceUse[=<option1>:<value1>[,<option2>:<value2>[...]]]

=over 4

=item C<hidecore>

  $ perl -d:TraceUse=hidecore your_program.pl

This will not renumber the modules so the core module's positions will be
visible as gaps in the numbering. In some cases evidence may also be visible of
the core module's usage (e.g. a caller shown as L<base> or L<parent>).

You may also specify the version of Perl for which you want to hide the core
modules (the default is the running version):

  $ perl -d:TraceUse=hidecore:5.8.1 your_program.pl

The version string can be given as I<x.yyy.zzz> (dot-separated) or
I<x.yyyzzz> (decimal). For example, the strings C<5.8.1>, C<5.08.01>,
C<5.008.001> and C<5.008001> will all represent Perl version 5.8.1,
and C<5.5.30>, C<5.005_03> will all represent Perl version 5.005_03.

=item C<output>

  $ perl -d:TraceUse=output:out.txt your_program.pl

This will output the TraceUse result to the given file instead of warn.

Note that TraceUse warnings will still be output as warnings.

The output file is opened at initialization time, so there should be no
surprise in relative path interpretation even if your program changes
the current directory.

=back

=head1 AUTHORS

chromatic, C<< <chromatic@wgz.org> >>

Philippe Bruhat, C<< <book@cpan.org> >>

=head2 Contributors

C<hidecore> option contributed by David Leadbeater, C<< <dgl@dgl.cx> >>.

C<output> option contributed by Olivier Mengué (C<< <dolmen@cpan.org> >>).

C<perl -c> support contributed by Olivier Mengué (C<< <dolmen@cpan.org> >>).

Proxy detection owes a lot to Olivier Mengué (C<< <dolmen@cpan.org> >>),
who submitted several patches and discussed the topic with me on IRC.

=head1 BUGS

Please report any bugs or feature requests to
C<bug-devel-traceuse at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Devel-TraceUse>.  We can both track it there.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Devel::TraceUse

You can also look for information at:

=over 4

=item * I<Perl Hacks>, hack #74

O'Reilly Media, 2006.

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Devel-TraceUse>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Devel-TraceUse>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Devel-TraceUse>

=item * Search CPAN

L<http://search.cpan.org/dist/Devel-TraceUse>

=back

=head1 COPYRIGHT

Copyright 2006 chromatic, most rights reserved.

Copyright 2010-2012 Philippe Bruhat (BooK), for the rewrite.

=head1 LICENSE

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

