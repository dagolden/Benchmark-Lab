use 5.008001;
use strict;
use warnings;

package Benchmark::Lab;
# ABSTRACT: Tools for structured benchmarking and profiling

our $VERSION = '0.002';

my $PROFILING = 0;
my $CLOCK_FCN = sub { die "Benchmark::Lab not initialized with import()" };

sub import {
    my $class = shift;

    my %args = __pairs(@_);

    if ( $args{'-profile'} ) {
        $ENV{NYTPROF} ||= '';
        $ENV{NYTPROF} .= ":start=no";
        require Devel::NYTProf;
        $PROFILING = 1;
    }

    # module loads deferred until after possible Devel::NYTProf load
    require Time::HiRes;
    require List::Util;

    # choose a default clock function; prefer monotonic
    if ( eval { Time::HiRes::CLOCK_MONOTONIC(); 1 } ) {
        $CLOCK_FCN = \&__get_monotonic_time;
    }
    else {
        $CLOCK_FCN = \&__get_fallback_time;
    }

    return;
}

=method new

Returns a new Benchmark::Lab object.

Valid attributes include:

=for :list
* C<min_secs> – minimum elapsed time in seconds; default 0
* C<max_secs> – maximum elapsed time in seconds; default 300
* C<min_reps> - minimum number of task repetitions; default 1; minimum 1
* C<max_reps> - maximum number of task repetitions; default 100
* C<verbose> – when true, progress will be logged to STDERR; default false

The logic for benchmark duration is as follows:

=for :list
* benchmarking always runs until both C<min_secs> and C<min_reps> are
  satisfied
* when profiling, benchmarking stops after minimums are satisfied
* when not profiling, benchmarking stops once one of C<max_secs> or
  C<max_reps> is exceeded.

Note that "elapsed time" for the C<min_secs> and C<max_secs> is wall-clock
time, not the cumulative recorded time of the task itself.

=cut

sub new {
    my $class = shift;

    my %defaults = (
        min_secs => 0,
        max_secs => 300,
        min_reps => 1,
        max_reps => 100,
    );

    my $self = bless { %defaults, __pairs(@_) }, $class;

    $self->{min_reps} = 1 if $self->{min_reps} < 1;

    __initialize_nytprof_file( $self->{nytprof_file} )
      if $PROFILING;

    return $self;
}

=method start

    my $result = $bm->start( $package, $context, $label );

This method executes the structured benchmark from the given C<$package>.
The C<$context> parameter is passed to all task phases.  The C<$label>
is used for diagnostic output to describe the benchmark being run.

If parameters are omitted, C<$package> defaults to "main", an empty
hash reference is used for the C<$context>, and the C<$label> defaults
to the C<$package>.

It returns a hash reference with the following keys:

=for :list
* C<elapsed> – total wall clock time to execute the benchmark (including
  non-timed portions).
* C<total_time> – sum of recorded task iterations times.
* C<iterations> – total number of C<do_task> functions called.
* C<percentiles> – hash reference with 1, 5, 10, 25, 50, 75, 90, 95 and
  99th percentile iteration times.  There may be duplicates if there were
  fewer than 100 iterations.
* C<median_rate> – the inverse of the 50th percentile time.
* C<timing> – array reference with individual iteration times as (floating
  point) seconds.

=cut

sub start {
    my ( $self, $package, $context, $label ) = @_;
    $package ||= 'main';
    $context ||= {};
    $label   ||= $package;

    # build dispatch table for package
    my $dispatch = { map { $_ => ( $package->can($_) ) }
          qw( describe setup before_task do_task after_task teardown ) };

    $self->_log("Benchmarking $label");

    $dispatch->{setup}->($context) if $dispatch->{setup};
    my $result = $self->_do_loop( $dispatch, $context );
    $dispatch->{teardown}->($context) if $dispatch->{teardown};

    return $result;
}

#--------------------------------------------------------------------------#
# Private methods
#--------------------------------------------------------------------------#

sub _do_loop {
    my ( $self, $dispatch, $context ) = @_;

    my ( $wall_start, $wall_time ) = ( $CLOCK_FCN->(), 0 );
    my ( $fcn, $n ) = ( $dispatch->{do_task}, 0 );
    $fcn ||= sub () { }; # use NOP if not provided

    my ( $start_time, $end_time, $elapsed, @timing );
    while (( $wall_time < $self->{min_secs} || $n < $self->{min_reps} )
        || ( $wall_time < $self->{max_secs} && $n < $self->{max_reps} && !$PROFILING ) )
    {
        $n++;
        $self->_log("starting loop $n; elapsed time $wall_time");

        $dispatch->{before_task}->($context) if $dispatch->{before_task};

        DB::enable_profile() if $PROFILING;

        $start_time = $CLOCK_FCN->();
        $fcn->($context);
        $end_time = $CLOCK_FCN->();

        DB::disable_profile() if $PROFILING;

        $dispatch->{after_task}->($context) if $dispatch->{after_task};

        $elapsed = $end_time - $start_time;
        if ( $elapsed == 0 ) {
            __croak("Clock granularity too low for this task");
        }

        push @timing, $elapsed;

        $wall_time = $end_time - $wall_start;
    }

    DB::finish_profile() if $PROFILING;

    my $pctiles = $self->_percentiles( \@timing );

    return {
        elapsed     => $wall_time,
        total_time  => List::Util::sum( 0, @timing ),
        iterations  => scalar(@timing),
        percentiles => $pctiles,
        median_rate => 1 / $pctiles->{50},
        timing      => \@timing,
    };
}

sub _log {
    my $self = shift;
    return unless $self->{verbose};
    my @lines = map { chomp; "$_\n" } @_;
    print STDERR @lines;
    return;
}

sub _percentiles {
    my ( $self, $timing ) = @_;

    my $runs = scalar @$timing;
    my @sorted = sort { $a <=> $b } @$timing;

    my %pctiles = map { $_ => $sorted[ int( $_ / 100 * $runs ) ] } 1, 5, 10, 25, 50, 75,
      90, 95, 99;

    return \%pctiles;
}

#--------------------------------------------------------------------------#
# Private functions
#--------------------------------------------------------------------------#

sub __croak {
    require Carp;
    Carp::croak(@_);
}

sub __get_fallback_time {
    return Time::HiRes::time();
}

sub __get_monotonic_time {
    return Time::HiRes::clock_gettime( Time::HiRes::CLOCK_MONOTONIC() );
}

sub __initialize_nytprof_file {
    return if $ENV{NYTPROF} && $ENV{NYTPROF} =~ m/file=/;
    my $file = shift || "nytprof.out";
    DB::enable_profile($file);
    DB::disable_profile();
    return;
}

sub __pairs {
    if ( @_ % 2 != 0 ) {
        __croak("arguments must be key-value pairs");
    }
    return @_;
}

1;

=for Pod::Coverage BUILD

=begin :prelude

=head1 EXPERIMENTAL

This module is still in the early experiment stage.  Breaking API changes
could occur in any release before 1.000.

Use and feedback is welcome if you are willing to accept that risk.

=end :prelude

=head1 SYNOPSIS

    # Load as early as possible in case you want profiling
    use Benchmark::Lab -profile => $ENV{DO_PROFILING};

    # Define a task to benchmark as functions in a namespace
    package My::Task;

    # do once before any iterations (not timed)
    sub setup {
        my $context = shift;
        ...
    }

    # do before every iteration (not timed)
    sub before_task {
        my $context = shift;
        ...
    }

    # task being iterated and timed
    sub do_task {
        my $context = shift;
        ...
    }

    # do after every iteration (not timed)
    sub after_task {
        my $context = shift;
        ...
    }

    # do once after all iterations (not timed)
    sub teardown {
        my $context = shift;
        ...
    }

    # Run benchmarks on a namespace
    package main;

    my $context = {}; # any data needed

    my $result = Benchmark::Lab->new()->start( 'My::Task', $context );

    # XXX ... do stuff with results ...

=head1 DESCRIPTION

This module provides a harness to benchmark and profile structured tasks.

Structured tasks include a task to be benchmarked, as well as work to be
done to prepare or cleanup from benchmarking that should not be timed.

This module also allows the same structured task to be profiled with
L<Devel::NYTProf>, again with only the task under investigation being
profiled.  During prep/cleanup work, the profiler is paused.

On systems that support C<Time::HiRes::clock_gettime> and
C<CLOCK_MONOTONIC>, those will be used for timing.  On other systems, the
less precise and non-monotonic C<Time::HiRes::time> function is used
instead.

Future versions will add features for analyzing and comparing benchmarks
timing data.

=head1 USAGE

=head2 Loading and initializing

If you want to use the profiling feature, you B<MUST> load this module
as early as possible so that L<Devel::NYTProf> can instrument all subsequent
compiled code.

To correctly initialize C<Benchmark::Lab> (and possibly L<Devel::NYTProf>),
you B<MUST> ensure its C<import> method is called.  (Loading it with C<use>
is sufficient.)

Here is an example that toggles profiling based on an environment variable:

    use Benchmark::Lab -profile => $ENV{DO_PROFILING};

    # loading other modules is now OK
    use File::Spec;
    use HTTP::Tiny;
    ...

=head2 Creating a structured task

A structured task is a Perl namespace that implements some of the following
I<task phases> by providing a subroutine with the corresponding name:

=for :list
* C<setup> – run once before any iteration begins (not timed)
* C<before_task> – run before I<each> C<do_task> function (not timed)
* C<do_task> – specific task being benchmarked (timed)
* C<after_task> – run after I<each> C<do_task> function (not timed)
* C<teardown> – run after all iterations are finished (not timed)

Each task phase will be called with a I<context object>, which can be used
to pass data across phases.

    package Foo;

    sub setup {
        my $context = shift;
        $context->{filename} = "foobar.txt";
        path($context->{filename})->spew_utf8( _test_data() );
    }

    sub do_task {
        my $context = shift;
        my $file = $context->{filename};
        # ... do stuff with $file
    }

Because structured tasks are Perl namespaces, you can put them into F<.pm>
files and load them like modules. Or, you can define them on the fly.

Also, since C<Benchmark::Lab> finds task phase functions with the C<can>
method, you can use regular Perl inheritance with C<@ISA> to reuse
setup/teardown/etc. task phases for related C<do_task> functions.

    package Foo::Base;

    sub setup { ... }
    sub teardown { ... }

    package Foo::Case1

    use parent 'Foo::Base';
    sub do_task { ... }

    package Foo::Case2

    use parent 'Foo::Base';
    sub do_task { ... }

=head2 Running benchmarks

A C<Benchmark::Lab> object defines the conditions of the test – currently
just the constraints on the number of iterations or duration of the
benchmarking run.

Running a benchmark is just a matter of specifying the namespace for the
task phase functions, and a context object, if desired.

    use Benchmark::Lab -profile => $ENV{DO_PROFILE};

    sub fact { my $n = int(shift); return $n == 1 ? 1 : $n * fact( $n - 1 ) }

    *Fact::do_task = sub {
        my $context = shift;
        fact( $context->{n} );
    };

    my $bl      = Benchmark::Lab->new;
    my $context = { n => 25 };
    my $res     = $bl->start( "Fact", $context );

    printf( "Median rate: %d/sec\n", $res->{median_rate} );

=head2 Analyzing results

TBD.  Analysis will be added in a future release.

=head1 CAVEATS

If the C<do_task> executes in less time than the timer granularity, an
error will be thrown.  For benchmarks that do not have before/after functions,
just repeating the function under test in C<do_task> will be sufficient.

=head1 RATIONALE

I believe most approaches to benchmarking are flawed, primarily because
they focus on finding a I<single> measurement.  Single metrics are easy to
grok and easy to compare ("foo was 13% faster than bar!"), but they obscure
the full distribution of timing data and (as a result) are often unstable.

Most of the time, people hand-wave this issue and claim that the Central
Limit Theorem (CLT) solves the problem for a large enough sample size.
Unfortunately, the CLT holds only if means and variances are finite and
some real world distributions are not (e.g. hard drive error frequencies
best fit a Pareto distribution).

Further, we often care more about the shape of the distribution than just a
single point.  For example, I would rather have a process with mean µ that
stays within 0.9µ - 1.1µ  than one that varies from 0.5µ - 1.5µ.

And a process that is 0.1µ 90% of the time and 9.1µ 10% of the time (still
with mean µ!) might be great or terrible, depending on the application.

This module grew out of a desire for detailed benchmark timing data, plus
some additional features, which I couldn't find in existing benchmarking
modules:

=for :list
* Raw timing data – I wanted to be able to get raw timing data, to allow
  more flexible statistical analysis of timing distributions.
* Monotonic clock – I wanted times from a high-resolution monotonic clock
  (if available).
* Setup/before/after/teardown – I wanted to be able to initialize/reset
  state not just once at the start, but before each iteration and without
  it being timed.
* L<Devel::NYTProf> integration – I wanted to be able to run the B<exact>
  same code I benchmarked through L<Devel::NYTProf>, also limiting the
  profiler to the benchmark task alone, not the setup/teardown/etc. code.

Eventually, I hope to add some more robust graphic visualization and
statistical analyses of timing distributions.  This might include both
single-point estimates (like other benchmarking modules) but also more
sophisticated metrics, like non-parametric measures for comparing samples
with unequal variances.

=head1 SEE ALSO

There are many benchmarking modules on CPAN with a mix of features that
may be sufficient for your needs.  To my knowledge, none give timing
distributions or integrate with L<Devel::NYTProf>.

Here is a brief rundown of some that I am familiar with:

=for :list
* L<Benchmark> – ships with Perl, but makes it hard to get timing
  distributions in a usable form.
* L<Benchmark::Timer> – times only parts of code, targets a degree of
  statistical confidence (assuming data is normally distributed).
* L<Dumbbench> – attempts to improve on L<Benchmark> with a more robust
  statistical estimation of runtimes; no before/after capabilities.
* L<Surveyor::App> – also runs benchmarks from a package, but doesn't
  have before/after task capabilities and relies on L<Benchmark> for timing.

=cut

# vim: ts=4 sts=4 sw=4 et tw=75:
