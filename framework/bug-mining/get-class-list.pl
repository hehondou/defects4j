#!/usr/bin/env perl

=pod

=head1 NAME

get-class-list.pl -- Run triggerng tests in isolation, monitor class loader, and
export class names of loaded and modified classes.

=head1 SYNOPSIS

get-class-list.pl -p project_id [-v version_id] [-w work_dir]

=head1 OPTIONS

=over 4

=item B<-p C<project_id>>

The id of the project for which loaded and modified classes are determined.

=item B<-v C<version_id>>

Only analyze this version id or an interval of version ids (optional).
The version_id has to have the format B<(\d+)(:(\d+))?> -- if an interval is provided,
the interval boundaries are included in the analysis.
Per default all version ids that have reviewed triggering test(s) in $TAB_TRIGGER
are considered.

=item B<-w C<work_dir>>

Use C<work_dir> as the working directory. Defaults to F<$SCRIPT_DIR/projects/>.

=back

=head1 DESCRIPTION

Runs the following workflow for the project C<project_id> -- the loaded classes
are written to F<C<work_dir>/"project_id"/loaded_classes> and the
modified classes are written to
F<C<work_dir>/projects/"project_id"/modified_classes>.

For all revision pairs <rev1,rev2> that have reviewed triggering test(s) in $TAB_TRIGGER:

=over 4

=item 1) Checkout rev2.

=item 2) Compile src and test.

=item 3) Run triggering test(s), verify that they pass, monitor class loader,
         and export the list of class names.

=item 4) Determine modified source files from source patch and export the list
         of class names.

=back

For each loaded or modified (project-related) class, the corresponding result file contains one row
with the fully-qualified classname.

=cut
use warnings;
use strict;
use File::Basename;
use List::Util qw(all);
use Cwd qw(abs_path);
use Getopt::Std;

require PatchReader::Raw;
require PatchReader::PatchInfoGrabber;

use lib (dirname(abs_path(__FILE__)) . "/../core/");
use Constants;
use Project;
use DB;
use Utils;

############################## ARGUMENT PARSING
# Issue usage message and quit
sub _usage {
    die "usage: " . basename($0) . " -p project_id [-v version_id] [-w working_dir]";
}

my %cmd_opts;
getopts('p:v:w:', \%cmd_opts) or _usage();

my ($PID, $VID, $working) =
    ($cmd_opts{p},
     $cmd_opts{v} // undef,
     $cmd_opts{w} // "$SCRIPT_DIR/projects"
    );

_usage() unless all {defined} ($PID, $working); # $VID can be undefined

# TODO make output dir more flexible
my $db_dir = defined $cmd_opts{w} ? $working : $DB_DIR;

# Check format of target version id
if (defined $VID) {
    $VID =~ /^(\d+)(:(\d+))?$/ or die "Wrong version id format ((\\d+)(:(\\d+))?): $VID!";
}

############################### VARIABLE SETUP
# Temportary directory
my $TMP_DIR = Utils::get_tmp_dir();
system("mkdir -p $TMP_DIR");
# Set up project
my $project = Project::create_project($PID, $working);
$project->{prog_root} = $TMP_DIR;

# Set up directory for loaded and modified classes
my $LOADED = "$working/$PID/loaded_classes";
my $MODIFIED = "$working/$PID/modified_classes";
system("mkdir -p $LOADED $MODIFIED");
# Directory containing triggering tests and patches
my $TRIGGER = "$working/$PID/trigger_tests";
my $PATCHES = "$working/$PID/patches";

my @ids  = _get_version_ids($VID);
foreach my $vid (@ids) {
    # Lookup revision ids
    my $v1  = $project->lookup("${vid}b");
    my $v2  = $project->lookup("${vid}f");

    my $file = "$TRIGGER/$vid";
    -e $file or die "Triggering test does not exist: $file!";

    # TODO: Skip if file already exists
    # TODO: Check whether triggering test file has been modified
    # next if -e "$LOADED/$vid.src";

    my @list = @{Utils::get_failing_tests($file)->{methods}};
    # There has to be a triggering test
    scalar(@list) > 0 or die "No triggering test: $v2";

    printf ("%4d: $project->{prog_name}\n", $vid);

    # Checkout to version 2
    $project->checkout_id("${vid}f") == 0 or die;

    # Compile sources and tests
    $project->compile() == 0 or die;
    $project->fix_tests("${vid}f");
    $project->compile_tests() == 0 or die;

    my %src;
    my %test;
    foreach my $test (@list) {
        my $log_file = "$TMP_DIR/tests.fail";
        # Run triggering test and verify that it passes
        $project->run_tests($log_file, $test) == 0 or die;
        # Get number of failing tests -> has to be 0
        my $fail = Utils::get_failing_tests($log_file);
        (scalar(@{$fail->{classes}}) + scalar(@{$fail->{methods}})) == 0 or die;

        # Run tests again and monitor class loader
        my $loaded = $project->monitor_test($test, $v2);
        die unless defined $loaded;

        foreach (@{$loaded->{src}}) {
            $src{$_} = 1;
        }
        foreach (@{$loaded->{test}}) {
            $test{$_} = 1;
        }
    }

    # Write list of loaded classes
    open(OUT, ">$LOADED/$vid.src") or die "Cannot write loaded classes!";
    foreach (keys %src) {
        print OUT "$_\n";
    }
    close(OUT);

    # Write list of loaded test classes
    open(OUT, ">$LOADED/$vid.test") or die "Cannot write loaded test classes!";
    foreach (keys %test) {
        print OUT "$_\n";
    }
    close(OUT);

    # Read patch file and determine modified files
    #
    # Note:
    # We use the source patch file instead of the Vcs-diff between
    # v1 and v2 since the patch might have been minimized
    my $filename = "$PATCHES/$vid.src.patch";
    my $reader = new PatchReader::Raw();
    my $patch_info_grabber = new PatchReader::PatchInfoGrabber();
    $reader->sends_data_to($patch_info_grabber);
    $reader->iterate_file($filename);
    my $patch_info = $patch_info_grabber->patch_info();

    # Write list of modified classes
    open(OUT, ">$MODIFIED/$vid.src") or die "Cannot write modified classes!";
    foreach (keys(%{$patch_info->{files}})) {
        # Skip modified properties and js files
        next if /^(a\/)?(.+)\.properties/;
        next if /^(a\/)?(.+)\.js/;
        s/^(a\/)?(.+)\.java/$2/ or die "Unknown file format: $_!";
        s/\//\./g;

        print OUT "$_\n";
    }
    close(OUT);
}
# Remove temporary directory
system("rm -rf $TMP_DIR");


#
# Determine all suitable version ids:
# - Source patch is reviewed
# - Triggering test exists
#    + Triggering test fails in isolation on rev1
#
sub _get_version_ids {
    my $target_vid = shift;

    my $min_id;
    my $max_id;
    if (defined($target_vid) && $target_vid =~ /(\d+)(:(\d+))?/) {
        $min_id = $max_id = $1;
        $max_id = $3 if defined $3;
    }

    # Connect to database
    my $dbh = DB::get_db_handle($TAB_TRIGGER, $db_dir);

    # Select all version ids with reviewed src patch and verified triggering test
    my $sth = $dbh->prepare("SELECT $ID FROM $TAB_TRIGGER " .
                                "WHERE $FAIL_ISO_V1>0 AND $PROJECT=?")
                            or die $dbh->errstr;
    $sth->execute($PID) or die "Cannot query database: $dbh->errstr";
    my @ids = ();
    foreach (@{$sth->fetchall_arrayref}) {
        my $vid = $_->[0];

        # Filter ids if necessary
        next if (defined $min_id && ($vid<$min_id || $vid>$max_id));

        # Add id to result array
        push(@ids, $vid);
    }
    $sth->finish();
    $dbh->disconnect();

    return @ids;
}


=pod

=head1 AUTHORS

Rene Just

=head1 SEE ALSO

All valid project_ids are listed in F<Project.pm>.
Run after getting trigger tests by executing F<get-trigger.pl>.
After running this script, you can determine the revisions that have minimized
patched. Then you can use F<promote-to-directory.pl> to merge desired
revisions with the main database.

=cut